# 增加 D3D12 渲染后端评估

基于实际代码结构给出评估（renderer 入口 `src/win32/d3d11.zig:1` 共 822 行，子模块 `src/win32/d3d11/` 12 个文件共 3661 行，shader `src/win32/terminal.hlsl:1` 共 223 行，外部调用面散落在 14 个文件，例如 `src/win32/render.zig`、`src/win32/global.zig:11`、`src/win32/state.zig:149`、`src/win32/wnd/lifecycle.zig:26`、`src/win32/wnd/misc.zig:152,584`）。

## 与 D3D11 / Vulkan / OpenGL 对比

| 维度 | D3D11（现状） | D3D12 | Vulkan | OpenGL 4.5 |
|---|---|---|---|---|
| API 抽象层级 | 高（驱动管同步/状态/资源生命周期） | 低（手动 command list/fence/barrier/heap） | 低（与 D3D12 同档，更显式） | 高（最高，状态机古早） |
| 驱动成熟度（Win） | 最稳 | 稳，Win10 1709+ 全覆盖 | 稳 | 受厂商驱动质量影响 |
| HLSL 着色器复用 | 现状 | **可直接复用**（SM 6.x，DXC 编译成 DXIL） | 要转 SPIR-V（DXC 能输出） | 要重写 GLSL |
| DXGI swapchain | 原生 | 原生（同一套 `IDXGISwapChain*`） | 走 `VK_KHR_win32_surface` | WGL，无 DXGI |
| DirectComposition 集成 | 原生 | **原生**（DComp 接受 D3D12 资源） | 桥接困难 | NV_DX_interop2 |
| 远程桌面 / 软件渲染 | WARP 自动回退（已用） | **WARP12 自动回退**（同机制） | 基本不可用 | 基本不可用 |
| 调试工具 | PIX/RenderDoc | PIX/RenderDoc/NSight（最佳） | RenderDoc/NSight | RenderDoc |
| 性能上限 | 中 | 高 | 高 | 中 |
| CPU overhead | 高 | 低 | 低 | 高 |
| 跨平台 | Windows only | Windows only | 全平台 | 全平台（macOS 已弃） |

## 一、需要做的工作

### 1. 抽象渲染后端接口

跟 OpenGL/Vulkan 路径一样：`global.renderer` 当前直接是具体类型 `d3d11`（`src/win32/global.zig:11`），14 处调用方直接访问其字段/方法（`cell_size`、`tab_bar_height`、`render(...)`、`updateFont`、`updateDpi`、`setBackgroundImage`、`cellSizeForDpi`、`tabBarHeightForDpi`、`remote_or_software_adapter`）。要先把公共面提炼成 `Renderer` 接口（tagged union 或 vtable），让 `D3d11Renderer` / `D3d12Renderer` 各自实现。这部分代价跟换成 GL/Vulkan 是同等的。

### 2. 设备 / 命令队列 / 同步骨架（D3D12 的"样板税"）

D3D11 一个 `ID3D11Device` + `ID3D11DeviceContext` 就够了；D3D12 要：

- `ID3D12Device`、独立的 `ID3D12CommandQueue`（direct/copy/compute 至少 direct）；
- 每个 in-flight frame 一份 `ID3D12CommandAllocator`，外加共用的 `ID3D12GraphicsCommandList`；
- `ID3D12Fence` + Win32 event 做 CPU/GPU 同步，自己维护 frame index 与 `WaitForSingleObject` 流程；
- 资源 barrier（`ResourceBarrier(D3D12_RESOURCE_STATE_*)`）：从 `PRESENT` → `RENDER_TARGET` → `PRESENT`，glyph atlas 上传时 `COPY_DEST` → `PIXEL_SHADER_RESOURCE`；漏一个 transition 就是 GPU hang 或 debug layer 大红屏。

这部分在 D3D11 里完全不存在，是 D3D12 后端**主要的新增代码量**。骨架 ~600-900 行 Zig。

### 3. 描述符堆 + 根签名

- `ID3D12DescriptorHeap`：CBV/SRV/UAV 一份，sampler 一份，RTV 一份；要自己管 slot 分配与回收（glyph atlas 扩张/重建时要释放旧 SRV）。
- 根签名（root signature）：把现在的 const buffer（`StructuredBuffer<Cell>`、几个 UBO 字段）映射成 root constants / root descriptor / descriptor table；这一步会触动 `terminal.hlsl` 顶部的资源绑定声明（`register(t0)` 等），但 shader 主体不动。
- 当前 `cell_buffer.zig` 506 行的 per-row diff 上传逻辑要改成 upload heap + `CopyBufferRegion`（D3D12 没有 `UpdateSubresource`），并把 fence 等待塞进现有的 throttle 路径。

### 4. PSO（Pipeline State Object）

D3D11 里 blend/raster/depth 三个 state 各自独立绑；D3D12 全部塞进一个 `ID3D12PipelineState`。Mostty 当前只有一条 full-screen-triangle pipeline，PSO 数量不会爆炸，但每次配置变化（例如 sRGB target 切换、blend 模式切换）要重建。骨架代码量小，主要是把现有 state 描述符迁移到 `D3D12_GRAPHICS_PIPELINE_STATE_DESC`。

### 5. Swapchain + DirectComposition 桥接

**这是 D3D12 相比 Vulkan/GL 的最大优势**：DXGI swapchain 与 DirectComposition 的对接逻辑跟 D3D11 几乎一样——`CreateSwapChainForComposition` 接受 `ID3D12CommandQueue`（而非 D3D11 device），后续 `IDCompositionVisual::SetContent(swapchain)` 流程完全不变。`src/win32/d3d11/swap_chain.zig` 166 行的整套 DComp 装配逻辑可以**结构性复用**，无外观损失、无透明/模糊回归风险。

### 6. HLSL Shader

`terminal.hlsl` 223 行**几乎不用改**：DXC 编译成 DXIL（SM 6.0+），HLSL 语义、`StructuredBuffer<Cell>`、`Texture2D.Load/SampleLevel`、sRGB 自动 encode、坐标系全部不变。注释里反复强调的"sRGB 空间里的预乘 alpha"+ ClearType 三通道覆盖率合成路径**零迁移成本**。

唯一需要改的是资源绑定语法（如果用了 root signature attribute）和编译命令（`fxc` → `dxc`，build 流程改一行）。

### 7. 字体/字形栈完全保留

`d3d11/font.zig` 726 行、`d3d11/glyph.zig` 529 行、`d3d11/emoji.zig` 142 行的 DirectWrite + Direct2D 离屏渲染管线跟 GPU 后端**无关**——Direct2D 1.3 可以创建于 D3D11 device 也可以独立运行（用 WIC bitmap render target 或者保留一个用于光栅化的 D3D11 device），上传到 D3D12 atlas 时改成 upload heap 即可。**不要**为了"统一"把字体栈也迁到 D3D12 上，那是另一个量级的项目（且 Direct2D 本身就是 D3D11 接口）。

实操上有两种路径：
- **A. 双 device 共存**：保留一个 D3D11 device 仅用于 Direct2D 字形栅化，结果 CPU 端拷贝到 D3D12 atlas。简单，多一份 device 内存（~10-30 MB）。
- **B. WIC software 路径**：Direct2D 用 WIC bitmap render target，完全脱离 D3D11；省一份 device，但 D2D 软件路径性能略低（ClearType 仍可用）。

建议 A，因为代码改动小。

### 8. 持久化 grid 纹理 + 差分上传

这是当前性能能跟上 PTY 流的关键（`GridConfigSnapshot` 强制 full redraw 路径，`d3d11.zig:73` 附近）。D3D12 端：

- upload heap 持久化映射（`Map` 一次，整个生命周期不 unmap）替代 `UpdateSubresource`；
- per-row diff 拷贝改为 `CopyBufferRegion` 或 `CopyTextureRegion`；
- 用 ring buffer 切片避免与 GPU 当前帧争用，配合 fence 回收旧 region。

代码量比 D3D11 路径多一倍左右（`cell_buffer.zig` 506 行 → 估计 800-1000 行）。

### 9. 远程桌面 / WARP 路径

D3D12 有 WARP12（`D3D12CreateDevice` 拿 `IDXGIAdapter` 的 software adapter），跟 D3D11 现有的 `remote_or_software_adapter` 路径**机制完全对等**：

- `src/win32/d3d11.zig:113,358,769` 的整套 remote/software 检测与 sync_interval 调整可以原样移植；
- `src/win32/state.zig:149-165` 的 render frame interval throttle 不动；
- `src/win32/wnd/lifecycle.zig:26`、`wnd/misc.zig:153,592` 的 adapter 切换重建分支复用。

这跟 Vulkan/GL 的硬伤完全不同——**D3D12 是唯一能保住 RDP 路径的"低层"API**。

### 10. 构建 / 依赖

- `build.zig`：把 `fxc.exe` 切到 `dxc.exe`（DXC 是 Windows SDK 一部分，无新依赖）；链接 `d3d12.lib`（替换或并存 `d3d11.lib`）、`dxgi.lib`（不变）。
- `build.zig.zon`：zigwin32 已经包含 D3D12 binding（`win32.graphics.direct3d12`），**无新增第三方依赖**——这是 D3D12 比 GL/Vulkan 更友好的另一点。
- ReleaseSmall 体积：D3D12 后端代码量增加但无新动态库依赖，预期二进制 < 2 MB 仍可保住。

### 11. 配置 + 运行时切换

`Config` 加 `renderer = "d3d11" | "d3d12"`；复用 `wnd/lifecycle.zig:26` 与 `wnd/misc.zig:152,584` 现有的"销毁旧 renderer / 建新 renderer"入口，跟 GL/Vulkan 路径同。

## 二、主要困难

| 难点 | 说明 |
|---|---|
| **手动同步 / barrier 正确性** | D3D12 debug layer 会抓漏 transition，但 release 构建里漏一个 barrier 就是间歇性 GPU hang 或者画面残留。Mostty 现在只有 single pipeline，可控；如果未来加 compute（例如 GPU 端 cell diff），复杂度立刻上一个台阶 |
| **fence 与 throttle 的耦合** | 现有的 `paint.zig` throttle 是"按 wall clock 决定要不要 present"，D3D12 还要额外考虑"GPU 是不是已经消费完上一帧"，否则 upload heap ring buffer 会数据竞争。需要把 fence 等待与 throttle 决策合并 |
| **descriptor heap 容量规划** | glyph atlas 增长（`GlyphIndexCache.zig` LRU 驱逐）会导致 SRV 重新创建。Shader-visible heap 切换是高开销操作，要么预分配大 heap 一次创建到顶，要么用 non-shader-visible staging heap + `CopyDescriptors`。Mostty 的 atlas slot 数量上限相对可预测，预分配方案够用 |
| **双 device（D3D11 for D2D）** | 字形栈保留 D3D11 路径意味着同时持有两个 device、两个 device removed 事件、两次 adapter 切换响应。`adapter_info.remote_or_software` 检测要在两个 device 上都跑一遍 |
| **测试矩阵翻倍** | RDP、WARP、独显/核显切换、DPI 变更、resize 抖动、device removed（驱动崩溃恢复）每项都要双后端跑——这是引入任何第二后端的固定成本 |

## 三、主要风险

1. **价值不清，跟 Vulkan/GL 评估结论一致**：终端负载是"每帧几个 draw call、几 KB 上传"，D3D12 的优势（低 CPU overhead、并行命令录制、PSO 缓存）**全部用不上**。`d3d11/cell_buffer.zig` 已经把上传路径压到很低，CPU 瓶颈在 `vt` 解析与字体光栅化，不在驱动提交。**预期 FPS / CPU 占用提升接近 0**。

2. **代码量净增**：现在 D3D11 后端 4706 行（含 shader）。D3D12 移植后保守估计 6000-7500 行 Zig（增加 device/queue/fence/barrier/descriptor heap 骨架 ~1500-2000 行，cell_buffer diff 上传扩张 ~300-500 行，shader 几乎不变）。维护成本翻倍而功能不变。

3. **双 device 的隐性成本**：Direct2D 强制依赖 D3D11/D3D10 interface，意味着 D3D12 后端实际上仍带着一个 D3D11 device 跑（路径 A）。"换成 D3D12"在用户感知层面是个空操作，但维护负担实实在在。

4. **没有外观回归（这点比 Vulkan/GL 好）**：DComp 集成不变、HLSL 不变、sRGB / 预乘 alpha / ClearType 三通道覆盖率都不变，**外观零风险**。这是 D3D12 唯一明显的优势。

## 四、与 Vulkan / OpenGL 评估的对照

| 维度 | OpenGL 4.5 | Vulkan | **D3D12** |
|---|---|---|---|
| Shader 重写 | 全部 GLSL 重写 | DXC 输出 SPIR-V，半自动 | **零改动** |
| DComp 集成 | NV_DX_interop2 桥接，外观降级 | 桥接困难，外观降级 | **原生，零差异** |
| RDP / WARP | 不可用 | 不可用 | **WARP12，机制不变** |
| 字体栈 | DirectWrite 保留 | DirectWrite 保留 | DirectWrite + D2D 保留（需保留 D3D11 device） |
| 新增依赖 | OpenGL loader（+几百 KB） | Vulkan SDK + loader | **零新依赖**（zigwin32 已含 D3D12 binding） |
| 二进制体积 | 涨几百 KB | 涨几百 KB | 几乎不变 |
| 性能收益（终端负载） | 零 | 零 | 零 |
| 终端外观一致性 | 高风险 | 高风险 | **零风险** |
| 代码量增量 | ~1500-2000 行 | ~1500-2000 行 | ~1500-3000 行 |

D3D12 是三个候选里**唯一不引入外观回归、不丢 RDP 路径、不需重写 shader 的方案**。但它和 Vulkan/GL 的共同结论一样：**性能没收益**。

## 五、结论

- **能做，且代价比 Vulkan/OpenGL 都小**：shader 复用、DComp 原生、WARP 路径对等、无新依赖、二进制不涨。这些都是 D3D12 相对其他两个候选的硬优势。
- **不建议作为第二渲染后端**：原因跟 Vulkan 评估完全一样——终端负载下 D3D12 的低 overhead **拿不到收益**，"双后端 CI / 双后端 bug 分类 / 双后端回归测试"的维护成本是确定的负债。
- **如果一定要做**，理由只能是以下之一：
  1. **未来要做 GPU compute**（例如 GPU 端 cell diff、GPU 端 emoji 合成）—— 此时 D3D12 的 explicit pipeline 才真正有意义；
  2. **要走 DirectStorage / GPU upload heaps（D3D12 独占特性）**——但这对每帧几 KB 的终端流毫无意义；
  3. **要做 HDR scRGB swapchain + tone mapping**——D3D12 + DXGI 1.6 链路更完整；D3D11 也能做，但 D3D12 是主推路径。
- **如果动机是性能 / RDP / 跨平台**，去看 `cpu-high-usage-in-rdp-software-render.md` 里 D3D11 路径的具体优化点（present 模式、`PREVENT_INTERNAL_THREADING_OPTIMIZATIONS`、WARP 调优）。D3D11 + WARP 软件回退已经在代码里跑得很稳（`src/win32/d3d11.zig:113,358,769`，`src/win32/state.zig:149-165`），用 D3D12 替换不会让 RDP 更快——RDP 瓶颈在 RDP 协议本身，不在 D3D 版本。

**底线判断**：D3D12 是"代价最小、收益也最小"的备选后端。除非有明确的 GPU compute / DirectStorage / HDR 路线图，否则**继续单 D3D11 后端是更诚实的选择**——这跟 Vulkan/OpenGL 评估的最终结论是同一句话。

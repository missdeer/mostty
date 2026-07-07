# 渲染后端抽象总纲（研究项目立项文档）

> 本文件是 `d3d12-note.md` / `vulkan-note.md` / `opengl-note.md` 的前置总纲。
> 三份 per-backend note 现存的"是否值得做"结论是**产品化视角**下的判定；本项目
> 定位为**技术探索 / 研究**，那些结论已作废，改由本文的"研究目标"章节替代。

## 一、研究目标

不为出货，为学习与验证。四条主线：

1. **Shader single-source 验证**：HLSL 一份源码 → DXC 双输出（DXIL / SPIR-V）
   → D3D11 / D3D12 / Vulkan / GL 4.6 四个后端跑同一份 `terminal.hlsl`。SPIR-V
   路径吃到 GL 4.6 的 `GL_ARB_gl_spirv`，等于 GL 也免掉 HLSL→GLSL 手翻。
2. **Explicit sync 对比研究**：D3D12 fence + DXGI waitable、Vulkan timeline
   semaphore + `VK_KHR_present_wait`、GL 的 `glClientWaitSync` / `glFlush` +
   `WGL_EXT_swap_control`，同一套 3-buffer + frame-latency 语义在三套 API 里
   落地对比。
3. **DirectComposition 桥接极限测试**：D3D11/D3D12 原生；GL 走
   `WGL_NV_DX_interop2`（三家驱动兼容矩阵）；Vulkan 走
   `VK_KHR_external_memory_win32` + `VK_KHR_external_semaphore_win32`。允许
   在研究分支上失败（fallback 到 layered window 无 blur）。
4. **Renderer 抽象层设计**：验证 Zig 场景下 tagged-union vs vtable 两种抽象方式
   在 14+ 处调用面下的可维护性。

**明确不包含**：性能追求、RDP/WARP 全后端覆盖、二进制体积维持在 2 MB。

## 二、现状盘点：backend-agnostic vs backend-specific

### Backend-agnostic（四后端共享，不动）

| 模块 | 行数 | 说明 |
|---|---|---|
| `vt`（libghostty-vt） | — | 外部依赖，纯 CPU |
| `GlyphIndexCache.zig` | — | atlas slot LRU，纯逻辑 |
| `d3d11/font.zig` | 885 | DirectWrite text format / fallback / shaping |
| `d3d11/glyph.zig` | 907 | 字形栅化到 CPU bitmap |
| `d3d11/glyph_worker.zig` | 713 | 异步栅化 worker，产 `RasterResult` |
| `d3d11/emoji.zig` | 153 | D2D 彩色 emoji 离屏渲染 |
| `d3d11/font_state.zig` | 272 | 字体切换状态机 |
| `d3d11/color.zig` | 58 | sRGB / 预乘 alpha 工具 |
| `d3d11/cell_buffer.zig`（diff 逻辑部分） | ~400 / 642 | shadow_cells 对比 + dirty row 计算 |

> **关键判断**：字体栈永久保留在 D3D11/D2D 上，不为任何后端重写。D2D 只能挂
> D3D11/D3D10 device，四个后端都要接受"底层还有一个 D3D11 device 跑 D2D"
> 的现实。

### Backend-specific（每个后端一份）

| 模块 | D3D11 现状 | 需要抽象/重写 |
|---|---|---|
| 设备 / 队列 / 同步 | `device`, `context` | D3D12/VK 骨架大头 |
| Swapchain | `IDXGISwapChain2` + waitable | D3D12 复用 / VK `VK_KHR_swapchain` / GL WGL |
| Descriptor / Root sig | 隐式（D3D11 slot） | D3D12 root sig / VK descriptor set / GL binding |
| PSO | 三个独立 state 对象 | D3D12/VK PSO 合一 / GL 状态零散 |
| 上传路径 | `UpdateSubresource` | D3D12 upload heap + `CopyBufferRegion` / VK staging + `vkCmdCopyBuffer` / GL `glBufferSubData` 或 persistent map |
| Present 节流 | waitable + Present1 | D3D12 waitable / VK present mode / GL `wglSwapIntervalEXT` |

### 调用面（`global.renderer.*`）

35 处引用，分布于 `mosttywindows.zig`、`win32/render.zig`、`win32/tab_mgmt.zig`、
`win32/window_geom.zig`、`win32/wnd/{ime,misc,lifecycle,paint,mouse}.zig`。
暴露的公共面：

- **字段**：`cell_size`、`tab_bar_height`、`font_ligatures`、
  `remote_or_software_adapter`
- **方法**：`render(...)`、`updateFont(...)`、`updateDpi(...)`、
  `reloadBackgroundImage(...)`、`setWorkerHwnd(...)`、`cellSizeForDpi(...)`、
  `tabBarHeightForDpi(...)`、`applyDecodedBackgroundImage(...)`、
  `applyGlyphResult(...)`
- **类型再导出**：`BgImageDecoded`、`RasterResult`、`FontConfig`、
  `scrollbarWidth`、`default_primary_font_family`、`default_font_size_pt`

这是 `Renderer` 抽象接口的**完整合同**——四个后端必须实现且仅需实现这些。

## 三、Renderer 抽象方案

两个可选：

| 方案 | 描述 | 判断 |
|---|---|---|
| **A. tagged union** | `pub const Renderer = union(enum) { d3d11: D3d11, d3d12: D3d12, vulkan: Vulkan, gl: Gl };` + inline switch 分发 | 调用面无需改（Zig 的 union 方法分发能借 `switch(self.*) inline else \|impl\| impl.method(...)`）；缺点是加后端要动 union 定义，编译时全 rebuild |
| **B. vtable** | `pub const Renderer = struct { ptr: *anyopaque, vtable: *const Vtable };` + 调用点全部 `renderer.vtable.render(renderer.ptr, ...)` | 加后端零改 union；缺点是失去 comptime 内联优化，且 field 访问（`cell_size`）要变 getter |

**选 A（tagged union）**。理由：

1. Mostty 的 renderer 是**热路径且 field 访问密集**（`cell_size` 在 mouse.zig
   里就调了 8 次）。vtable getter 会污染这些代码。
2. Zig union + `inline else` 让 4 个后端的分发在优化开后完全内联，等价于 D3D11
   直接调用；vtable 版会失去这一点。
3. 后端数量固定（4 个），不需要 vtable 的可扩展性。
4. `field` 访问（`cell_size`、`tab_bar_height` 等）在 union 上要写成 getter
   方法或者移到 union 外的 `RendererCommon` 结构。选后者：把这几个共同字段提
   到 union 外的 `pub const Renderer = struct { common: RendererCommon, backend:
   RendererBackend };`，backend 是 tagged union，common 里放 `cell_size` /
   `tab_bar_height` / `font_ligatures` / `remote_or_software_adapter` 这类
   backend 无关的状态。这样调用面几乎不改（`renderer.cell_size` →
   `renderer.common.cell_size`，一次全局 rename）。

### Backend switch 生命周期

`Config.renderer = "d3d11" | "d3d12" | "vulkan" | "gl46"`。切换点复用现有的
`wnd/lifecycle.zig:26` + `wnd/misc.zig:172,626` 的"销毁旧 renderer / 建新
renderer"分支（现在为 `remote_or_software_adapter` 变化服务）。

跨切换保留（不重建）：`vt.Terminal`、字体 cache、`GlyphIndexCache` 逻辑
数据、`shadow_cells`。丢失（必须重建）：GPU 侧 atlas texture、cell buffer、
PSO / pipeline、swapchain。

## 四、Shader single-source 管线

单源 HLSL → DXC 双输出：

```
src/win32/terminal.hlsl  ─┬─ dxc -T ps_6_0 -Fo terminal.dxil    → D3D11(SM6? 用 SM5) / D3D12
                          └─ dxc -T ps_6_0 -spirv -Fo terminal.spv → Vulkan / GL 4.6
```

现有 shader 资源绑定：

- `b0` = `GridConfig` cbuffer（14 个标量）
- `t0` = `StructuredBuffer<Cell>`
- `t1` = glyph atlas `Texture2D<float4>`
- `t2` = background image `Texture2D<float4>`
- `s0` = bg sampler

四后端映射：

| 绑定 | D3D11 | D3D12 root sig | Vulkan descriptor set | GL 4.6 SPIR-V binding |
|---|---|---|---|---|
| b0 | slot 0 | root CBV | UBO binding=0 | UBO binding=0 |
| t0 | slot 0 | root SRV 或 table | storage buffer binding=1 | SSBO binding=1 |
| t1 | slot 1 | descriptor table | combined image sampler binding=2 | sampler2D binding=2 |
| t2 | slot 2 | descriptor table | combined image sampler binding=3 | sampler2D binding=3 |
| s0 | slot 0 | static sampler | 合并进 t2 | 合并进 t2 |

**注意点**：

- HLSL `register(t0)` 语义在 SPIR-V 输出下会被 DXC 映射到 `descriptor_set=0,
  binding=N`；需要显式用 `[[vk::binding(N, 0)]]` attribute 固定，否则不同
  DXC 版本编号会漂。
- `SV_POSITION.y` 在 GL 是**底部原点**，Vulkan 是顶部但 clip space
  `y` 朝下与 D3D 一致。GL 侧用 `glClipControl(GL_UPPER_LEFT,
  GL_ZERO_TO_ONE)` 拉齐（4.5 起可用），比 `-y` 补丁干净。
- sRGB 自动 encode：D3D11/D3D12/VK 都靠 RTV/framebuffer 是 sRGB 格式；GL 侧
  需要 `glEnable(GL_FRAMEBUFFER_SRGB)` + sRGB internalFormat。
- SM 版本：D3D11 现在是 SM5，D3D12 建议升 SM6.0（DXC 强制）。SM5→SM6.0 主体
  兼容，但 wave intrinsics 之类要显式启用；本 shader 没用到 wave op，无风险。

## 五、Frame-latency / Present 对等表

`f259ea4` 落地的 3-buffer swap chain + DXGI frame-latency waitable 是**本项目
必须保住的手感基线**（拖窗口不掉帧）。四个后端的对等物：

| 后端 | 交换链缓冲 | latency 等待机制 | 备注 |
|---|---|---|---|
| D3D11（现状） | 3-buffer flip | `IDXGISwapChain2::GetFrameLatencyWaitableObject` → `WaitForSingleObject` | 已实现 |
| D3D12 | 3-buffer flip | 同上（DXGI 层共用）+ 自己的 `ID3D12Fence` GPU 完成信号 | 两条同步线要合并到 `paint.zig` 的节流路径 |
| Vulkan | 3 swapchain images + `VK_PRESENT_MODE_MAILBOX_KHR` | `VK_KHR_present_wait` + `vkWaitForPresentKHR`（较新扩展，NVIDIA/Mesa 支持，AMD 驱动近期跟上） | 不支持 present_wait 时 fallback `VK_KHR_present_id` + poll，或直接 mailbox 无等待（放弃精确 latency 测量） |
| GL 4.6 | 3-buffer（WGL 无显式控制，靠 driver + `wglSwapIntervalEXT(1)`） | 无原生对等；用 `GL_ARB_sync` fence + `glClientWaitSync` 手动 gate 上一帧完成 | 手感肯定比 D3D 差，研究点之一 |

## 六、字体栈保留策略

D2D 只能挂 D3D11/D3D10 设备 → 四后端都要**同时持有一个 D3D11 device 用于
D2D**。Bitmap 移交路径：

| 后端 | 主渲染 device | D2D device | 移交方式 |
|---|---|---|---|
| D3D11 | 同一个 | 复用主 device | 直接 `CopySubresourceRegion` |
| D3D12 | D3D12 device | 独立 D3D11 device | 方案 A：D3D11 device 出 shared texture（`OpenSharedResource1`），D3D12 端 `ID3D12Device::OpenSharedHandle` 导入。方案 B：CPU staging + upload heap。**选 A**（零拷贝，D2D 输出→D3D12 atlas 一步到位） |
| Vulkan | VkDevice | 独立 D3D11 device | D3D11 shared handle → `VK_KHR_external_memory_win32` 导入 VkImage。同步用 `VK_KHR_external_semaphore_win32` 拿 D3D11 fence handle |
| GL 4.6 | GL context | 独立 D3D11 device | `WGL_NV_DX_interop2` 直接把 D3D11 texture 注册进 GL |

**双 device 的隐性成本**：两个 device removed 事件、两次 adapter 切换响应；
研究阶段可以忽略（只跑独显 baseline）。

## 七、DirectComposition 桥接矩阵

DComp 是当前透明背景 + DWM 模糊 + 自绘 tab bar 的关键路径（`d3d11.zig:98-100`
+ `swap_chain.zig` 179 行）。DComp 只吃 IDXGISwapChain*，非 D3D 后端要桥接。

| 后端 | 首选方案 | 复杂度 | Fallback |
|---|---|---|---|
| D3D11/D3D12 | `CreateSwapChainForComposition(commandQueue)` → `SetContent(swapchain)` | 零改动 | — |
| GL 4.6 | GL 渲到 FBO → 通过 `WGL_NV_DX_interop2` 把 GL renderbuffer 关联到 D3D11 shared texture → 这个 D3D11 texture 上再建 flip-model DXGI swapchain 交给 DComp | 中 | Layered window (`WS_EX_LAYERED` + `SetLayeredWindowAttributes`)，失 blur、失半透明、失自绘 tab bar 效果 |
| Vulkan | Vulkan 渲到 VkImage → `VK_KHR_external_memory_win32` 导出 D3D11 shared handle → D3D11 端建 swapchain 给 DComp。跨 API 同步走 `VK_KHR_external_semaphore_win32` ↔ D3D11 `ID3D11Fence` | 高 | 同 GL 的 layered window fallback |

**允许结果**：研究分支上 GL/Vulkan 后端接受"无 DComp"的降级（layered window，
外观显著劣化）。这不是失败，是可接受的对照数据。

## 八、异步栅化线程 × 四后端

`glyph_worker.zig` 713 行的异步栅化 worker 产 `RasterResult`，主线程通过
`applyGlyphResult` 上传到 atlas。三条移交路径：

- **D3D11**：CPU bitmap → `UpdateSubresource` 到 atlas。现状。
- **D3D12**：CPU bitmap → upload heap ring buffer → `CopyTextureRegion` 到
  atlas + resource barrier `COPY_DEST → PIXEL_SHADER_RESOURCE`。ring buffer
  切片必须与 fence 联动，否则和 GPU 当前帧数据竞争。
- **Vulkan**：CPU bitmap → `VkBuffer` staging（VMA 分配）→ `vkCmdCopyBufferToImage`
  + pipeline barrier。Ring buffer + fence 逻辑与 D3D12 对称。
- **GL 4.6**：CPU bitmap → `glTexSubImage2D`（或 persistent-mapped PBO +
  `glBufferSubData` + `glTexSubImage2D` 从 PBO）。无显式 fence，用
  `GL_ARB_sync` 挡一下。

## 九、构建 / 依赖

| 项 | 影响 |
|---|---|
| DXC | Windows SDK 自带（`dxcompiler.dll` + `dxc.exe`），无第三方依赖 |
| `build.zig` shader step | 现在只跑 `fxc`，改成"两阶段 DXC：出 DXIL + 出 SPIR-V" |
| Vulkan | 需要 Vulkan-Headers（可 vendor 进 vendor/），运行时依赖系统 `vulkan-1.dll`；不引入 loader 库 |
| GL 4.6 | `zigglgen` 生成按需 loader，链接 `opengl32.lib` |
| D3D12 | zigwin32 已包含 binding；链接 `d3d12.lib` |
| 二进制体积 | ReleaseSmall 会**明确破 2 MB**（GL loader 几百 KB + VK entry 表 + shader 双输出）。研究项目接受 |

## 十、测试矩阵（研究阶段）

只跑 **baseline**：独显 + 1080p/2160p + 默认 DPI + 默认字体。

**推后**（不进本项目 scope）：RDP、WARP/software、多 DPI 切换、device removed、
resize 抖动。这些是产品化后的补充工作。

每个后端要过的 smoke：

1. 冷启动 + 第一屏渲染正确（sRGB / ClearType / 预乘 alpha 视觉一致）；
2. PTY 高压（`yes | head -c 100M`）不丢帧、不 hang；
3. 拖窗口 30 秒无卡顿（frame-latency 手感对比是本项目主要交付物之一）；
4. Tab 切换、字体切换、DPI 切换（DComp 桥接后端可退化）。

## 十一、里程碑 / 顺序

**共享设施优先**：

| 阶段 | 交付 | 依赖 |
|---|---|---|
| **M0** | `Renderer` 抽象（tagged union + RendererCommon）+ 所有 35 处调用点迁移完成，D3D11 是唯一 variant，跑通 | 无 |
| **M1** | HLSL → DXC 双输出（DXIL + SPIR-V）落地 `build.zig`；D3D11 后端切到 DXC 编 DXIL 产物 | M0 |
| **M2** | 字体栈双 device 化：抽独立 D3D11 device 给 D2D，主 D3D11 renderer 保留（先不换后端，验证移交路径） | M1 |
| **M3** | **D3D12 后端**：shader 复用 DXIL、DComp 原生、fence + waitable 双同步；跑通 baseline smoke | M2 |
| **M4** | **Vulkan 后端**：shader 复用 SPIR-V、外部内存互操作、timeline semaphore；无 DComp 版先跑通，DComp 桥接后加 | M2, M3（借鉴 fence 设计） |
| **M5** | **GL 4.6 后端**：shader 复用 SPIR-V、`glClipControl` 拉齐坐标系；无 DComp 版先跑通，`WGL_NV_DX_interop2` 桥接后加 | M2, M4（复用 SPIR-V 管线） |
| **M6** | 三后端对比报告：wall-clock 拖窗口手感、PTY 压力 CPU 占用、代码量、DComp 兼容矩阵 | M3, M4, M5 |

**M0 是关键路径**：它决定后续三个后端的开发能否并行。若 M0 拆得对，M3/M4/M5
可以在不同分支并行推进。

## 十二、遗留决策（需要在动工前拍板）

1. D3D11 后端要不要一并切到 DXC / SM6？（省一套编译器 vs 增加 D3D11 端复杂度）
2. `RendererCommon` 字段清单是否完整？（现在识别出 4 个：`cell_size`、
   `tab_bar_height`、`font_ligatures`、`remote_or_software_adapter`；实际做
   M0 时可能发现更多）
3. Vulkan/GL 的 DComp 桥接是"必须做完才算这个后端完成"还是"可选加强"？
4. 单一 D3D11 device 给 D2D 是"全局单例"还是"每 renderer 一份"？前者省内存
   但四后端切换时不能销毁；后者干净但切一次 backend 就要重建整套字体 cache。
   建议前者。

---

## 参考

- `d3d12-note.md` §2-4：D3D12 骨架细节（本文 M3 依赖）
- `vulkan-note.md`：**需要按本文补齐 M4 骨架细节**
- `opengl-note.md`：**需要重写为 4.6（SPIR-V 输入），去掉 §3 HLSL→GLSL 手翻章节**
- `ARCHITECTURE.md`：模块布局与线程模型
- `f259ea4`：3-buffer swap chain + frame-latency waitable 实现参照

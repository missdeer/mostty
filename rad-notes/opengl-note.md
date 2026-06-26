# 增加 OpenGL 4.5 渲染后端评估

基于实际代码结构给出评估（renderer 入口 `src/win32/d3d11.zig:1`、shader `src/win32/terminal.hlsl:1`、外部调用面散落在 14 个文件，例如 `src/win32/render.zig:42`、`src/win32/global.zig:11`）。

## 一、需要做的工作

### 1. 抽象渲染后端接口

当前 `global.renderer` 直接是具体类型 `d3d11`（`src/win32/global.zig:11`），14 处调用方直接访问其字段/方法（`cell_size`、`tab_bar_height`、`render(...)`、`updateFont`、`updateDpi`、`setBackgroundImage`、`cellSizeForDpi`、`tabBarHeightForDpi`、`remote_or_software_adapter`）。需先把这套公共面提炼成 `Renderer` 接口（Zig 没有 trait，常见做法是 tagged union 或 vtable 结构），再让 `D3d11Renderer` / `GlRenderer` 各自实现。

### 2. 用 WGL 取代 DXGI 的 swap chain + DirectComposition

现在的窗口合成链是 `IDXGISwapChain2` + `IDCompositionDevice/Target/Visual`（`d3d11.zig:114-119`），承担了无边框/DWM 模糊/透明合成。OpenGL 这边要：

- 用 `wglCreateContextAttribsARB` 创建 4.5 Core context（依赖 WGL_ARB_create_context、WGL_ARB_pixel_format、WGL_EXT_swap_control）；
- 决定与 DComp 的关系——OpenGL 没法直接喂 IDCompositionVisual，要么用 `NV_DX_interop2` 把 GL 渲染结果导入 D3D 纹理再交给 DComp（仍是 NV 扩展，AMD/Intel 兼容性视驱动而定），要么放弃 DComp，回到 `SetLayeredWindowAttributes` 配 `WS_EX_LAYERED`（性能差很多、模糊/透明效果退化）。这是最大的体感落差点。

### 3. 重写 HLSL → GLSL

`terminal.hlsl` (`src/win32/terminal.hlsl:1`) 把背景渐变、滚动条、单元格网格、字形采样、emoji 反预乘、下划线/删除线、背景图采样全塞进一个 PS。整体翻译不难，但要注意：

- `StructuredBuffer<Cell>` → `SSBO`（GL 4.3+，OK）；
- `Texture2D.Load(int3)` → `texelFetch`，`SampleLevel` → `textureLod`；
- sRGB RTV 的自动 encode 行为 → 用 `GL_FRAMEBUFFER_SRGB` + sRGB internalFormat；
- 坐标系 Y 翻转（`SV_POSITION` 左上原点 vs GL 左下），影响 `sv_pos.y` 全部运算；
- HLSL `(uint)` 截断 vs GLSL 显式 `uint(...)`、整数除法语义；
- 注释里反复提到的 premultiplied alpha + sRGB 这一对，最容易在新后端踩出 emoji 边缘发暗、字形发灰的回归。

### 4. 资源管线重写

- `ID3D11Buffer` const buffer → UBO；
- 每帧 per-row `UpdateSubresource`（`d3d11.zig:44-62` 的 stats 就是为它准备的）→ `glBufferSubData` 或 persistent-mapped buffer（GL 4.4 `GL_MAP_PERSISTENT_BIT`）；
- 字形图集 `ID3D11Texture2D` → `glTexSubImage2D`，仍需保留 `GlyphIndexCache` 的 LRU 行为（`src/win32/GlyphIndexCache.zig:1`）；
- 持久化的 grid 纹理（`GridConfigSnapshot` 强制 full redraw 路径，`d3d11.zig:73`）整套差分上传逻辑要原样移植，否则性能立刻退化。

### 5. DirectWrite/Direct2D 完全保留

字体测量、shaping、ClearType mask、emoji 彩色字形（Direct2D 离屏渲染）这一整套（`d3d11/font.zig` 726 行、`d3d11/glyph.zig` 529 行、`d3d11/emoji.zig`）跟 GPU 后端无关，应当保持现状——只在最终把 CPU 端 bitmap 上传时换 API 即可。**不要**为了"统一"去引入 FreeType/HarfBuzz，那是另一个量级的项目。

### 6. 构建/依赖

`build.zig.zon` 加 OpenGL loader（`zigglgen` 或手写 `wglGetProcAddress`），`build.zig` 增加 `opengl32.lib`/`gdi32.lib` 链接；保留 MSVC ABI 约束不变。

### 7. 配置 + 运行时切换

`Config` 加 `renderer = "d3d11" | "opengl"`；`wnd/lifecycle.zig:26`、`wnd/misc.zig:152,584` 现在已有 `remote_or_software_adapter` 重建分支，可以复用同一套"销毁旧 renderer / 建新 renderer"的入口。

## 二、主要困难

| 难点 | 说明 |
|---|---|
| **无边框窗口合成** | DComp 是当前透明背景 + DWM 模糊的关键。OpenGL 这条路要么牺牲外观，要么靠 WGL_NV_DX_interop2 桥接（驱动依赖高、调试痛苦） |
| **sRGB + 预乘 alpha 一致性** | shader 注释里明确写了 D2D RT 存的是"sRGB 空间里的预乘值"，emoji 路径要先反预乘再 to_linear 再重新预乘；任何细节差异都会出现肉眼可见的字形边缘发暗 |
| **ClearType 子像素** | HLSL 里 `cov = to_linear(glyph_texel.rgb) * fg.a` 是三通道覆盖率（子像素 AA）。GL 端必须保持三通道覆盖率合成路径，不能退化成单通道 |
| **持久化 grid 纹理 + 差分上传** | 这是当前性能能跟上 PTY 流的关键。GL 端如果改成"每帧重传 cells"会立刻在大终端窗口出现 CPU 瓶颈 |
| **测试矩阵翻倍** | 远程桌面、软件渲染回退、WARP、独显/核显切换、DPI 变更、resize 抖动——每一项都要在两套后端各跑一遍 |

## 三、主要风险

1. **价值不清**：现在的 D3D11 路径在 Windows 11 + WDDM 上已经覆盖了所有目标用户。新增 OpenGL 后端解决的具体问题是什么？远程桌面？老 GPU？跨平台铺路？如果只是"多一个选项"，引入的双后端维护成本（CI、shader 两套、回归测试、bug 报告分类）会持续吃掉精力。建议先把动机写清楚再决定。

2. **DComp 替代方案落差**：很可能最后用户体验上 OpenGL 后端就是"窗口没那么漂亮、透明度怪怪的"——这是承诺路径还是临时妥协，需要在动工前确定。

3. **Zig 0.15.2 + Windows 生态绑定**：`win32` 模块由 zigwin32 提供，OpenGL 调用要么自己手写 loader，要么依赖第三方 Zig 包，跟当前"win32 lazy 依赖、二进制 < 2MB"的约束会有冲突（OpenGL loader 通常会让二进制涨几百 KB）。

## 建议

如果动机是**远程桌面/软件渲染性能**，先看 `cpu-high-usage-in-rdp-software-render.md` 列出的根因——很可能在 D3D11 路径里调 `D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS` 或换 WARP/优化 present 模式就能解决，不必引第二后端。如果是**为将来跨平台铺路**，那应该一开始就上 Vulkan 或 wgpu 抽象，而不是 OpenGL 4.5（Apple 已弃用、Linux 上也在被 Vulkan 取代）。

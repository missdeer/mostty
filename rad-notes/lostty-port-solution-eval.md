# Lostty 方案评估：Qt QML/Qt Quick + RHI 跨平台移植

> 评估对象：将当前 Mostty（Zig + libghostty-vt + D3D11）移植为基于 Qt Quick + RHI 的跨平台终端。
> 评估日期：2026-06-06

## 可行性总览

| 模块 | 现状 (Mostty) | Qt Quick + RHI 对应方案 | 难度 |
|---|---|---|---|
| VT 状态机 | `libghostty-vt` (Zig 模块) | 同库，通过 C ABI 导出供 C++ 调用 | 低 |
| 渲染 | D3D11 + HLSL 全屏三角形 + `StructuredBuffer<Cell>` | `QQuickRhiItem` (Qt 6.7+) 自定义 RHI pass | 中 |
| Shader | HLSL | `.qsb`（用 `qsb` 工具从 GLSL/HLSL 交叉编译为 SPIR-V/MSL/HLSL/GLSL） | 中 |
| 字形图集 | DirectWrite + 自管 LRU (`GlyphIndexCache`) | `QRawFont` / FreeType + `QRhiTexture` 上传 | 中 |
| PTY | ConPTY (Win) | Win: ConPTY；macOS/Linux: `openpty` + `forkpty` | 中 |
| Tab 栏 / 窗口 chrome | 手绘进 D3D11 表面 + DWM blur | QML 原生组件；blur/暗色需平台特定代码 | 低 |
| 读 PTY 线程 | `std.Thread` + `SendMessage` 给 UI 线程 | `QThread` + `Qt::QueuedConnection` 信号 | 低 |

## 推荐架构

- **核心层（Zig，静态库）**：包 `libghostty-vt` + 一个薄的 C ABI 头（`mostty_core.h`），导出 `terminal_feed_bytes()`、`terminal_get_cells()`、`terminal_resize()` 等。Zig 这边继续用 `vt.Stream(VtHandler)`，只把数据缓冲暴露给 C++。
- **应用层（Qt/C++/QML）**：
  - `TerminalItem : QQuickRhiItem` —— 持有 `QRhiBuffer`（cells SSBO）、`QRhiTexture`（atlas）、`QRhiShaderResourceBindings`，每帧 `updatePaintNode` 之前同步核心层的 cell 数据。
  - QML 负责标签栏、菜单、设置面板、分屏。
  - `PtyBackend` 抽象 ConPTY / Unix pty，分平台编译。

## 主要权衡

1. **二进制体积**：Mostty 现在 ReleaseSmall 不到 2MB；Qt 静态链接最小也 15-25MB（QtCore + QtGui + QtQuick + QtRhi）。这是 README 的卖点之一，会丢。
2. **HLSL 移植**：当前全屏三角形 shader 用了 `StructuredBuffer<Cell>`，HLSL SM5。Qt RHI 上要走 SSBO 路径（GLSL `buffer` block），`qsb` 工具可以转，但需要把 binding 显式声明出来。
3. **Win32 特性丢失**：`DwmSetWindowAttribute`、blur-behind、自绘标题栏这些目前直接调 Win32，跨平台后需要每平台一份（macOS 用 `NSVisualEffectView`、KDE 用 KWin blur 协议等）。
4. **Surrogate / IME 等键盘细节**：QML `TextInput` 处理过，但当前的 per-tab `high_surrogate` 状态机要重写成 Qt input method 事件流。
5. **构建系统**：Zig build 失去，转成 CMake + Qt6；CI 要多平台 runner。

## 建议路径（如果决定做）

1. 先把 `libghostty-vt` 用 Zig 包成纯 C ABI 静态库（`zig build-lib -dynamic=false`），写一个最小 C++ demo 把 cells 跑出来——验证 FFI 没有坑。
2. 再做单 tab 的 `QQuickRhiItem` 原型，shader 用 GLSL 重写一遍走 `qsb`，验证渲染路径。
3. 第三步才是 PTY 抽象和多 tab。
4. 平台 chrome 最后做。

## 结论

**技术上完全可行，没有 blocker**；但本质上是一个新项目，复用的主要是 `libghostty-vt` 和 shader 算法，UI/渲染/IO 层都要重写。

如果目标只是"在 macOS/Linux 上也能跑 Mostty"，工作量大约相当于现在 `src/mosttywindows.zig` + `src/win32/` 的 1.5–2 倍。

是否继续，取决于对**二进制体积**和 **Win32 原生控制权**的取舍。

---

## 补充评估：Qt Canvas Painter（Qt 6.11，Technology Preview）

> 评估日期：2026-06-13
> 参考：[Qt Canvas Painter 文档](https://doc.qt.io/qt-6/qtcanvaspainter-index.html)、[Introducing Qt Canvas Painter](https://www.qt.io/blog/2d-rendering-introducing-qt-canvas-painter)、[New Canvas Rendering Features in Qt](https://www.qt.io/blog/new-canvas-rendering-features-in-qt)

### 关键事实

| 维度 | 实际能力 |
|---|---|
| 定位 | 高层 2D 命令式 API，对标 HTML Canvas 2D context |
| 后端 | 构建在 QRhi 之上，**只有 GPU 后端**（无 CPU fallback） |
| 自定义 shader | `QCanvasCustomBrush` 支持自定义顶点/片段 shader，**但仅作为 fill/stroke 的 brush** |
| SSBO / StructuredBuffer | **未暴露** |
| 文本 | 内置 `fillText`、`line wrapping`、字距/对齐 |
| 装饰效果 | Box Gradient、Box Shadow（SDF）、Grid Pattern、Color effects |
| 稳定性 | Tech Preview，API 不在 Qt 兼容承诺范围内 |

### 与 Mostty 现状的根本错配

当前 Mostty 渲染管线是**数据驱动的单 pass**：1 个全屏三角形 + `StructuredBuffer<Cell>` 喂整个网格 + 片段 shader 自己定位 cell 并查 atlas，1 次 draw call 出整屏。

Canvas Painter 是**命令式 draw-call 驱动**（`fillRect` / `fillText` / `drawImage`）。落到 Canvas Painter 上只有两条路：

1. **走内置 `fillText`**：每个 cell 一次或批量 text 调用。失去对背景翻转、双宽、cursor 反色、半字符 atlas 复用的精确控制；`GlyphIndexCache` LRU 作废，交给 Qt 自己缓存。
2. **走 `QCanvasCustomBrush`**：自己写 shader——但 brush 绑在 fill/stroke 路径上，**不是任意 compute / SSBO 访问**。cells 数据只能塞进 uniform / texture，路径上还得画"每 cell 一矩形"或全屏矩形，比 `QQuickRhiItem` 多一层抽象，少一层灵活度。

### 对原方案表的修订

| 模块 | 原方案（QQuickRhiItem） | Canvas Painter 替代 | 是否更优 |
|---|---|---|---|
| 终端网格主 pass | 自管 RHI pass + SSBO | brush + uniform/texture，无 SSBO | ❌ 更差 |
| 字形图集 | 自管 LRU + QRhiTexture | 可用内置 text，但失控制 | ⚠️ 平手或更差 |
| Tab 栏 / 菜单 / 设置面板 | QML 原生 | QML 原生（不变） | ➖ 无差别 |
| 装饰性效果（阴影、blur、渐变） | 手写 HLSL | Box Shadow / Box Gradient 一行搞定 | ✅ 更好 |

### 结论

- **运行时性能**：核心终端网格**不会更好**，大概率略差（多一层 2D 管线开销，且失去 single-pass + SSBO 的极简路径）。
- **开发效率**：仅在窗口装饰、设置面板等**非终端区域**有收益，而那部分用普通 QML 也够省事。
- **额外风险**：Tech Preview（API 可能变）、要求 Qt 6.11+（CI/打包基线抬高）、二进制体积比 `QQuickRhiItem` 方案更大。

**建议**：`QQuickRhiItem` 仍是更合适的主路径。Canvas Painter 可作为 **UI chrome 层的可选工具**（标签栏 hover、阴影、动画），**不承载终端单元格渲染**。

# 增加 OpenGL 4.6 渲染后端评估（研究视角）

> 本文件是 `renderer-backend-abstraction.md`（总纲）的 M5 深化。共享设施
> （Renderer 抽象、shader single-source 管线、字体栈双 device、frame-latency
> 对等表、DComp 桥接矩阵、测试矩阵）见总纲，本文只写 GL 4.6 特有骨架。
>
> **相对 4.5 的关键 delta**：`GL_ARB_gl_spirv` + `GL_ARB_spirv_extensions`
> 在 4.6 已进 core，意味着可以直接吃 DXC 从 HLSL 编出来的 SPIR-V——**不再需要
> 手翻 HLSL→GLSL**（这是本 note 相对原 4.5 草案最大的改动）。
>
> 立项动机：验证"高层 API + SPIR-V ingest"这条独特组合，与 Vulkan 共享
> shader 管线但保持声明式状态机；是 GL 4.6 相对 4.5 的实用价值验证。允许
> 拖窗口手感明显差于 D3D，作为对照数据。

## 一、需要做的工作

### 1. WGL context 创建

- `wglCreateContextAttribsARB` → 4.6 Core profile。依赖扩展：
  `WGL_ARB_create_context`、`WGL_ARB_pixel_format`、`WGL_ARB_create_context_profile`、
  `WGL_EXT_swap_control`。
- 用 dummy window 走一次 `ChoosePixelFormat` + `wglCreateContext` +
  `wglMakeCurrent` 拿 loader，再真正建 4.6 context（WGL 老套路）。
- Multi-thread：GL context 每线程一份且 make-current 昂贵；本项目主渲染线程
  单持一份，异步 glyph worker 走 CPU raster（不动 GL 端），跟 D3D 现状对齐。

### 2. Loader

- 用 `zigglgen` 生成"仅本项目需要的入口"loader（预期 ~150 个 GL 函数 +
  ~10 个 WGL 扩展函数），避免全量 loader 让二进制爆胀。
- 链接 `opengl32.lib` + `gdi32.lib`。
- 运行时 `wglGetProcAddress` 拿 4.6 / SPIR-V / DSA / persistent buffer 系列
  函数指针。

### 3. Present / frame-latency 对等物

GL 是四后端里 present 手感**最弱**的一档，无 waitable 对等物：

- Baseline：`wglSwapIntervalEXT(1)` 硬 vsync，`SwapBuffers` 阻塞。
- 加强：`GL_ARB_sync` fence + `glClientWaitSync(0)` 手动 gate 上一帧 GPU 
  完成，等价于自己 rollup 一个 waitable。3 帧 in-flight 用 3 个 fence
  轮转。
- **无 mailbox 等价物**。要拿类似 DXGI waitable 的手感基本不可能——这是
  本 note 明确接受的限制。研究价值反过来在这里：**用同一份 shader、同一份
  cell buffer diff 逻辑，看 GL 手感掉多少**。

### 4. HLSL → SPIR-V → GL 4.6

**这一节完全推翻原 4.5 草案的 §3 手翻 GLSL 章节**。

- 复用总纲 M1 的 shader 管线：`dxc -T ps_6_0 -spirv -Fo terminal.spv`。
- 上传：`glShaderBinary(1, &shader, GL_SHADER_BINARY_FORMAT_SPIR_V_ARB,
  spv_blob, spv_len)` → `glSpecializeShaderARB(shader, "main", 0, NULL,
  NULL)` → `glAttachShader` + `glLinkProgram`。
- **HLSL binding attribute 必需**：DXC 输出 SPIR-V 时 `[[vk::binding(N, 0)]]`
  attribute 会成为 SPIR-V 的 `DescriptorSet`/`Binding` decoration；GL 侧
  只看 `Binding`（无 descriptor set 概念），所以 binding 号必须与 §5 对齐。
- **坐标系拉齐**：`glClipControl(GL_UPPER_LEFT, GL_ZERO_TO_ONE)`（4.5 起
  core）——把 GL 的默认底部原点/`-1..1` z 换成 D3D 语义。`SV_POSITION`
  与 `gl_Position` 现在语义完全一致，shader 主体零改动。
- **sRGB**：sRGB internalFormat（`GL_SRGB8_ALPHA8`）+ 
  `glEnable(GL_FRAMEBUFFER_SRGB)`。与 D3D RTV `_SRGB` 语义等价。
- **Blend**：`glBlendFuncSeparate` + `glEnable(GL_BLEND)` 走预乘 alpha
  路径（`GL_ONE, GL_ONE_MINUS_SRC_ALPHA`）。

### 5. Resource binding 映射

| HLSL 声明 | SPIR-V 输出 | GL 4.6 端 |
|---|---|---|
| `cbuffer GridConfig : register(b0)` | UBO, binding=0 | `glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo)` |
| `StructuredBuffer<Cell> cells : register(t0)` | SSBO (readonly), binding=1 | `glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, ssbo)` |
| `Texture2D<float4> glyph_texture : register(t1)` | sampler2D, binding=2 | `glBindTextureUnit(2, glyph_atlas)` + `glBindSampler(2, sampler)` |
| `Texture2D<float4> bg_image : register(t2)` | sampler2D, binding=3 | `glBindTextureUnit(3, bg_image)` + `glBindSampler(3, sampler)` |
| `SamplerState bg_sampler : register(s0)` | 合并进 t2 combined image sampler | 单个 `GL_LINEAR` sampler |

**用 DSA（Direct State Access，4.5 起 core）**：`glCreateBuffers`、
`glCreateTextures`、`glCreateVertexArrays`、`glTextureStorage2D` 等。省掉
bind-to-modify 的状态污染，代码干净很多。

### 6. 资源管线

- UBO（`GridConfig`）：一个 persistent-mapped 缓冲区（`GL_MAP_PERSISTENT_BIT
  | GL_MAP_COHERENT_BIT`，4.4 起 core），CPU 直接写，无 `glBufferSubData`。
- SSBO（cells）：与 D3D11 `cell_buffer.zig` 的 per-row diff 逻辑保持等价——
  persistent-mapped SSBO ring buffer（3 帧 in-flight × cells 大小），diff
  只写 dirty row 到当前 slice，`GL_ARB_sync` fence 保证 GPU 消费完再复用。
- Glyph atlas：`glTextureStorage2D`（不可变存储）+ `glTextureSubImage2D`
  局部更新。**不改动 `GlyphIndexCache` 的 LRU 逻辑**（backend-agnostic，见
  总纲）。
- Background image：同 atlas 路径。

### 7. 字体栈 + WGL_NV_DX_interop2

依赖总纲 M2 的双 device 决定：D3D11 独立 device 跑 D2D + DirectWrite。字形
bitmap 移交方案：

- **首选**：`WGL_NV_DX_interop2`——`wglDXOpenDeviceNV(d3d11_device)` +
  `wglDXRegisterObjectNV(d3d11_texture, GL_TEXTURE_2D, ...)`。D2D 直接渲染
  进 D3D11 texture，GL 端零拷贝把它当 GL texture 用。
- **驱动兼容矩阵**：
  - **NVIDIA**：长期稳定支持，是这条扩展的原厂。
  - **AMD**：Adrenalin 20.x 起支持（历史上有过 bug，新驱动稳定）。
  - **Intel**：Xe/Arc 驱动支持；老 UHD 集显的 GL 驱动实现有过问题，研究
    项目建议只测新驱动。
- **Fallback**：不支持 `NV_DX_interop2` 时退化到"D2D 渲染 → `Map`
  拿 CPU bitmap → `glTextureSubImage2D` 上传到 GL atlas"。慢但无兼容
  依赖。研究报告里三家驱动的 fallback 触发率是有效数据。

### 8. DirectComposition 桥接

GL 无法直接喂 IDCompositionVisual，桥接路径：

- GL 渲到 FBO（不直接渲到 default framebuffer）。
- 通过 `WGL_NV_DX_interop2` 把 GL FBO 的 color attachment 注册为 D3D11
  shared texture。
- 这个 D3D11 texture 上建 flip-model DXGI swapchain
  （`CreateSwapChainForComposition` 走 D3D11 device），交给 DComp
  `SetContent`。
- 每帧顺序：GL 渲到 GL renderbuffer → `wglDXLockObjectsNV` → D3D11 端
  Present1 → `wglDXUnlockObjectsNV`。
- **Fallback**：`WS_EX_LAYERED`——失 DWM blur、失半透明、自绘 tab bar 边缘
  退化。研究分支明确接受。

### 9. RDP / 软件路径

- RDP 会话下 GL 通常拿到 **GDI Generic 1.1**（Microsoft software
  implementation），完全不支持 4.6。研究项目明确放弃 RDP 硬件路径。
- **Mesa3D 的 llvmpipe** 提供软件 GL 4.6 ICD（Windows 版可通过 Mesa's
  `opengl32.dll` 替换或走 `MESA_LOADER` 环境变量），作为可选对照数据，
  不进 baseline smoke。

### 10. GL 4.6 相对 4.5 的实用 delta

| 特性 | 用途 | 本项目是否用 |
|---|---|---|
| **`GL_ARB_gl_spirv` + `GL_ARB_spirv_extensions`** | 吃 SPIR-V shader | **是**（本 note 的立项动机） |
| `GL_KHR_no_error` | 关闭 GL error 检查省一部分驱动开销 | 否（研究阶段开 debug output 更重要） |
| `GL_ARB_polygon_offset_clamp` | Z-fighting 缓解 | 否（无深度） |
| `GL_ARB_texture_filter_anisotropic` promotion | 各向异性过滤 | 否（点采样字形） |
| `GL_ARB_indirect_parameters` | Indirect draw count 参数化 | 否（1 draw call） |
| `GL_ARB_pipeline_statistics_query` | GPU 统计查询 | 可选（研究报告用） |

结论：4.6 相对 4.5 对本项目**只有 SPIR-V ingest 一条实用变化**——但这条足够
颠覆原 note §3 手翻 GLSL 的整节工作量。

### 11. Validation / debug

- `GL_ARB_debug_output`（4.3 起 core） + `glDebugMessageCallback`：GL 侧
  validation，覆盖 API 用法错误、性能警告。研究阶段全程开。
- 相比 Vulkan validation layer，GL debug output 覆盖面窄很多，但对本项目
  的简单管线够用。
- 工具：RenderDoc 对 GL 4.6 支持良好；NSight 支持；无 PIX。

### 12. 构建 / 依赖

- `zigglgen` 加入 `build.zig.zon`（生成脚本时序），或者一次性生成 checked-in
  到 `src/win32/gl46/loader.zig`。**选后者**（避免生成脚本进构建依赖，跟
  win32 lazy 依赖策略一致）。
- 链接 `opengl32.lib` + `gdi32.lib`。
- DXC 复用总纲 M1 出 SPIR-V。
- 二进制体积：预期增几百 KB（loader entry 表 + SPIR-V blob）。破 2 MB，
  研究项目接受。

## 二、主要困难

| 难点 | 说明 |
|---|---|
| **Present 手感** | 无 waitable 对等物，`GL_ARB_sync` 手动 gate 是最好也就 D3D11 60% 的手感（估计）。这是研究项目的**观测目标**，不是 bug |
| **WGL_NV_DX_interop2 三厂商兼容** | NV 稳、AMD 新驱动稳、Intel 老驱动有雷。研究报告里三家 fallback 触发率是产出物之一 |
| **SPIR-V binding 语义映射** | HLSL `register(t0)` → SPIR-V `Binding=1` → GL `binding=1` 一路走下来，GL 侧无 descriptor set 概念，`[[vk::binding(N, 0)]]` 的 set 号被忽略。要在 DXC 命令行加 `-fvk-t-shift 1 0`（把 t 空间偏移 1）或者接受 SPIR-V binding 号跳过 0，源头 HLSL 显式声明最省事 |
| **DSA 与旧代码风格混用** | GL 4.5 DSA 是新路径，与教科书上的 `glBindTexture` + `glTexSubImage2D` 混用会引状态混乱。本项目**全线 DSA**，不 fallback |
| **persistent-mapped buffer + fence** | 手动管理，比 D3D 的隐式 map/unmap 复杂；写完必须靠 `GL_ARB_sync` fence 保证 GPU 消费完再复用。跟 Vulkan 的 timeline semaphore 是同一类问题的低配版 |
| **NV_DX_interop2 与 DComp 组合** | GL renderbuffer → D3D11 shared texture → DXGI swapchain → DComp 四层桥接，任何一层 API 语义不匹配就是黑屏。**这是 M5 里最脏的一段** |

## 三、主要风险

1. **拖窗口手感明显输给 D3D**：设计预期，是本项目的对照数据。
2. **DComp 桥接失败率**：依赖 `NV_DX_interop2` 稳定性。研究分支允许退化到
   layered window。
3. **AMD/Intel 4.6 驱动质量参差**：老 UHD 集显的 GL 驱动实现 bug 历史多；
   研究测试只覆盖 NVIDIA + AMD 新驱动 + Intel Arc，Intel UHD 老驱动明确
   不测。
4. **SPIR-V ingest 在实战里可能有 corner case**：例如 DXC 输出的 SPIR-V
   带 Vulkan-only 特性、GL 驱动拒绝。研究报告里这些具体 case 是有效产出。
5. **代码量**：骨架 1000-1500 行 Zig（比 Vulkan 小，但比 D3D12 略大——D3D12
   靠 DXGI/DComp 复用省了一大块，GL 全靠自己）。

## 四、与 D3D12 / Vulkan 差异（本 note 聚焦部分）

| 维度 | D3D12 | Vulkan | **GL 4.6** |
|---|---|---|---|
| Shader source | HLSL→DXIL | HLSL→SPIR-V | **HLSL→SPIR-V（与 VK 共享管线）** |
| API 显式度 | 中 | 高 | **低（本 note 的独特点）** |
| Frame-latency | DXGI waitable + fence | present_wait + timeline + mailbox 三档 | **`GL_ARB_sync` 手动 gate（最弱）** |
| DComp 集成 | 原生 | 外部内存桥 | **WGL_NV_DX_interop2 桥（AMD/Intel 兼容变数）** |
| 字体栈移交 | D3D11 shared texture 零拷贝 | 外部内存导入 VkImage | **NV_DX_interop2 零拷贝（首选）** / CPU staging（fallback） |
| RDP | WARP12 可用 | 明确放弃 | **明确放弃**（GL RDP = GDI 1.1，不支持 4.6） |
| Debug 工具 | PIX/RenderDoc/NSight | RenderDoc/NSight | RenderDoc（弱） |
| 骨架代码量 | 1500-2000 行 | 1800-2500 行 | **1000-1500 行**（省在无 descriptor set + 无 render pass） |
| 研究学习收益 | 中 | 最高 | **中（SPIR-V ingest 实战 + NV_DX_interop2 兼容矩阵）** |

## 五、结论（研究视角）

- **值得做**，独立价值在两点：
  1. **验证 GL 4.6 SPIR-V ingest 能否在实战里替代 GLSL 手翻**——这是本 note
     从 4.5 升 4.6 的核心动机。若成功，"HLSL 一份源码打四个后端"就闭环了。
  2. **"高层 API + SPIR-V"这条独特组合**——Vulkan 是"显式 + SPIR-V"，D3D12 是
     "显式 + DXIL"，GL 4.6 是唯一"声明式 + SPIR-V"的一档，三方对照才完整。
- **预期负面结果都写在明面上**：拖窗口手感差、DComp 桥接失败率非零、
  RDP 放弃、AMD/Intel 老驱动不测。这些是研究数据，不是失败。
- **相对 Vulkan 的独立价值**：两者共享 SPIR-V 管线，但同步与内存管理完全
  不同档。GL 端"用最少的代码把同一个 shader 跑起来"是本 note 的实际交付。
- **`WGL_NV_DX_interop2` 三厂商兼容矩阵**是本项目里其他后端都拿不到的对照
  数据。

**建议里程碑**：M5 拆两阶段——**M5a** 无 DComp 版（layered window）+ 
SPIR-V ingest 跑通 baseline smoke；**M5b** 加 NV_DX_interop2 桥接 + DComp。
M5a 完成即可验证本 note 的核心动机（SPIR-V ingest 可行性），M5b 是加分项。

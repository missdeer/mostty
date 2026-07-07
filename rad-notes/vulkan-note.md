# 增加 Vulkan 渲染后端评估（研究视角）

> 本文件是 `renderer-backend-abstraction.md`（总纲）的 M4 深化。共享设施
> （Renderer 抽象、shader single-source 管线、字体栈双 device、frame-latency
> 对等表、DComp 桥接矩阵、测试矩阵）见总纲，本文只写 Vulkan 特有骨架。
>
> 立项动机：**explicit sync 学习价值最高的一档**（比 D3D12 更显式，比 GL 更严
> 苛），外部内存互操作是本项目最深的研究点。放弃 RDP 硬件路径，允许 DComp
> 桥接失败退化到 layered window。

## 一、需要做的工作

### 1. Instance / physical device / logical device

- `VkInstance`：启用 `VK_KHR_surface` + `VK_KHR_win32_surface`。研究阶段开
  `VK_LAYER_KHRONOS_validation`，release 关。
- `VkPhysicalDevice` 选择：优先 `VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU`，回落到
  integrated；软件 ICD（lavapipe/SwiftShader）作为研究阶段可选 fallback，
  跟 D3D 的 WARP 不同它不是产品级路径。
- `VkDevice`：一个 graphics queue（必须支持 `VK_QUEUE_GRAPHICS_BIT` 且 present
  能力），可选一个专用 transfer queue（`VK_QUEUE_TRANSFER_BIT` 独立 family）
  给字形上传。绝大多数桌面 GPU 有专门的 copy engine，值得用；退化到 graphics
  queue 上传也行。
- 必需扩展：`VK_KHR_swapchain`、`VK_KHR_external_memory_win32`、
  `VK_KHR_external_semaphore_win32`、`VK_KHR_dynamic_rendering`（1.3 已 core）、
  `VK_KHR_synchronization2`（1.3 已 core）。研究点扩展：`VK_KHR_present_wait`、
  `VK_KHR_present_id`（frame-latency 等价物，见 §3）。

### 2. 同步骨架（三层）

D3D11 只有一层驱动隐式同步，Vulkan 是本项目所有后端里同步最显式的：

- **Acquire semaphore**（binary）：`vkAcquireNextImageKHR` 拿下一张 swapchain
  image 的信号量，串到该帧 command buffer 的 wait stage
  `COLOR_ATTACHMENT_OUTPUT`。
- **Render finished semaphore**（binary）：submit 完成后 signal，`vkQueuePresentKHR`
  wait。
- **Timeline semaphore**（`VK_KHR_timeline_semaphore`，1.2 已 core）：跨帧
  CPU/GPU 同步，替代 D3D12 fence。上传路径 ring buffer 用它做"上一帧
  GPU 消费完 slice N 了吗"的等待。**建议全线用 timeline semaphore + `sync2`
  barrier**，别用 binary VkFence（老 API，跟 timeline 不好组合）。

三条线在 `paint.zig` 的节流路径里合并：一帧开始前要同时满足"DXGI 
waitable equivalent 允许 CPU 继续"和"timeline semaphore 上一帧 slice 已释放"。
细节见 §3。

### 3. Present / frame-latency 对等物

D3D11/D3D12 靠 `IDXGISwapChain2::GetFrameLatencyWaitableObject`，Vulkan 没有
直接对应。三条路径：

- **首选**：`VK_PRESENT_MODE_MAILBOX_KHR` 3 image + `VK_KHR_present_wait`
  + `vkWaitForPresentKHR(presentId)` 显式等上 N-1 帧完成。NVIDIA 驱动长期
  支持，Mesa 21+ 支持，AMD Windows 驱动 24.x 起支持，Intel Arc 支持
  近期跟上。这是**跟 DXGI waitable 最对等的一档**。
- **Fallback A**：不支持 `present_wait` 时用 mailbox + 应用侧 timeline
  semaphore 自己 gate（不精确，但拖窗口手感能救 80%）。
- **Fallback B**：`VK_PRESENT_MODE_FIFO_KHR`（vsync 硬阻塞），手感等同
  `wglSwapIntervalEXT(1)`。研究项目不接受，除非上面两条都失败。

**决定**：这一节是**研究项目的核心交付物之一**——出一份"三种 present 路径
的拖窗口手感 + PTY 压力下 CPU 占用"对比表。

### 4. Descriptor set / pipeline layout

- `VkDescriptorSetLayout`：一个 set，4 个 binding：
  - binding 0：`VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER`（对应 HLSL `b0`）
  - binding 1：`VK_DESCRIPTOR_TYPE_STORAGE_BUFFER`（对应 HLSL `t0` 
    StructuredBuffer<Cell>）
  - binding 2：`VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER`（glyph atlas + 
    static sampler）
  - binding 3：`VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER`（bg image + 
    static sampler，或复用 binding 2 的 sampler）
- `VkDescriptorPool`：预分配足够容纳"三帧 in-flight × 上述 4 binding"的量。
  Atlas 增长（`GlyphIndexCache` 驱逐）不改 descriptor 数量，只改 combined
  image sampler 指向的 VkImageView，用 `vkUpdateDescriptorSets` 更新即可。
- `VkPipelineLayout`：仅上述 1 个 descriptor set，无 push constant（`GridConfig`
  的 14 个标量走 UBO，不走 push constant，因为跟 D3D12 root sig 共享
  语义方便对照——push constant 会变成 D3D12 root constant 的对等物，是另一条
  路径）。

### 5. Pipeline state（PSO）

- `VkGraphicsPipelineCreateInfo`：一条 full-screen-triangle pipeline：
  - Vertex input：无（HLSL `SV_VertexID` → GLSL `gl_VertexIndex`，SPIR-V
    输出下 DXC 自动 remap）
  - Rasterization：`CULL_MODE_NONE`
  - Blend：sRGB 空间预乘 alpha（跟 D3D11 一致）
  - Depth/stencil：禁用
- **用 `VK_KHR_dynamic_rendering`**（1.3 core）：省掉 `VkRenderPass` +
  `VkFramebuffer` 的样板，直接在 command buffer 里用
  `vkCmdBeginRenderingKHR` + `VkRenderingAttachmentInfoKHR`。节省 ~150 行
  骨架代码。
- `VkPipelineCache`：持久化到 `%LOCALAPPDATA%\mostty\pipeline_cache.vk`，
  避免每次启动重编 SPIR-V→ISA。

### 6. Swapchain

- `VkSurfaceKHR`：`vkCreateWin32SurfaceKHR`，直接吃 `HWND`。
- `VkSwapchainKHR`：3 images，`VK_PRESENT_MODE_MAILBOX_KHR`，format 选
  `VK_FORMAT_B8G8R8A8_SRGB`（跟当前 D3D11 flip-model 一致），alpha
  compositing 视 DComp 桥接方案而定（见 §11）。
- Resize：`VK_ERROR_OUT_OF_DATE_KHR` 触发 `vkDestroySwapchainKHR` + 重建，
  descriptor set 不动。

### 7. HLSL → SPIR-V shader

复用总纲的 shader single-source 管线：

- `dxc -T ps_6_0 -spirv -Fo terminal.spv src/win32/terminal.hlsl`。
- `[[vk::binding(N, 0)]]` attribute 显式固定 binding，与 §4 descriptor set
  layout 对齐。
- **坐标系**：Vulkan clip space `y` 朝下与 D3D 一致（不像 GL 底部原点），
  `SV_POSITION` 零改动。
- **Viewport y-flip**：不需要，跟 D3D 语义相同。
- **sRGB**：swapchain image format 为 `_SRGB` 时驱动自动 encode，与 D3D
  RTV 语义一致。
- **StructuredBuffer<Cell>** → SPIR-V `StorageBuffer`（DXC 自动生成
  `layout(std430) readonly buffer`）。

### 8. 字体栈 + 外部内存互操作

依赖总纲 M2 的双 device 决定：D3D11 独立 device 跑 D2D，字形 bitmap 通过
shared handle 移交到 Vulkan：

- D3D11 端：`D3D11_RESOURCE_MISC_SHARED_NTHANDLE | 
  D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX` 建 shared texture，
  `IDXGIResource1::CreateSharedHandle` 拿 `HANDLE`。
- Vulkan 端：`VkImportMemoryWin32HandleInfoKHR` +
  `VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT_KHR`。
- 同步：D3D11 建 `ID3D11Fence`（D3D11.3）+
  `ID3D11Fence::CreateSharedHandle` → Vulkan `vkImportSemaphoreWin32HandleKHR`
  以 `VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D11_FENCE_BIT` 导入为 timeline
  semaphore。这是**本项目最深的一段代码**，也是研究收益最高的部分。
- **Fallback**：如果外部内存互操作在某台机器上失败，退化到"D3D11 端
  `Map` → CPU staging → Vulkan `vkCmdCopyBufferToImage`"，慢但兼容性
  最好。

### 9. 上传路径（字形 atlas + cell buffer）

- **Allocator**：手写 dedicated allocation 优先（`VK_KHR_dedicated_allocation`）
  给 large image；小 buffer 用一个自管的 arena。**不引入 VMA**（VulkanMemory
  Allocator）——研究项目不需要 VMA 的通用性，且 VMA 是 C++ 库，Zig 集成成本
  高。
- **Staging**：一个持久 mapped `HOST_VISIBLE | HOST_COHERENT` buffer（3 帧
  in-flight × 一帧上限 slice 数），slice 用 timeline semaphore
  索引回收。
- **上传**：`vkCmdCopyBufferToImage`（atlas）+ `vkCmdCopyBuffer`（cell buffer
  StorageBuffer）。Pipeline barrier 用 `sync2` 的
  `VkImageMemoryBarrier2` + `VkBufferMemoryBarrier2`，`srcStageMask =
  COPY`, `dstStageMask = FRAGMENT_SHADER`。

### 10. RDP / 软件路径

**没有对等物**。RDP 下 Vulkan ICD 通常拿不到设备。研究项目的处理：

- **明确放弃 RDP 硬件路径**（写进 Config 文档："renderer=vulkan 在 RDP 会话
  下会失败，请切 renderer=d3d11"）。
- **可选研究**：SwiftShader 或 lavapipe（软件 Vulkan）作为对照数据，但不
  进 baseline smoke。

### 11. DirectComposition 桥接

依赖总纲的桥接矩阵。Vulkan 桥的具体细节：

- Vulkan 渲到 `VkImage`（sRGB 格式，`VK_IMAGE_USAGE_TRANSFER_SRC_BIT`）。
- 通过 `VK_KHR_external_memory_win32` 导出 D3D11 shared handle。
- D3D11 端 `OpenSharedResource1` 拿到 `ID3D11Texture2D`。
- 在这个 D3D11 texture 上建 flip-model DXGI swapchain（`CreateSwapChainForComposition`
  仍需一个 `IDXGIFactory` + 一个 D3D11 command queue 等价物——这里可以复用
  §8 的 D3D11 device）交给 DComp。
- 跨 API 同步：Vulkan timeline semaphore signal 后 D3D11 端等这个 shared 
  fence 再 Present。
- **Fallback**：`WS_EX_LAYERED` + `SetLayeredWindowAttributes`，失
  DWM blur、失半透明、自绘 tab bar 边缘会退化。研究分支可接受。

### 12. 构建 / 依赖

- **Vulkan-Headers** vendor 进 `vendor/vulkan-headers/`（纯 header，不引入
  loader 静态库）。
- 运行时依赖系统 `vulkan-1.dll`（Vulkan runtime，Windows 10+ NVIDIA/AMD/Intel
  驱动都会装）。
- `build.zig`：无新增 `.lib` 链接（`vulkan-1.dll` 通过 `LoadLibrary` 
  运行时加载，仿照现在 `win32` lazy 依赖）。
- **DXC** 复用总纲 M1 管线出 SPIR-V。
- 二进制体积：预期增几百 KB（loader entry 表 + SPIR-V blob）。研究项目
  接受破 2 MB。

## 二、主要困难

| 难点 | 说明 |
|---|---|
| **三层同步的正确性** | Acquire / render-finished / timeline 三条线在 `paint.zig` 节流路径里合并，任何一条漏 wait 就是画面撕裂或 GPU hang。研究阶段开 validation layer 挡一部分 |
| **外部内存互操作的资源状态匹配** | `VkImageLayout` 与 D3D11 resource state 没有严格一一对应；shared texture 的 layout transition 必须在两边都显式走一遍（`VK_IMAGE_LAYOUT_UNDEFINED → SHADER_READ_ONLY_OPTIMAL` 对应 D3D11 `COMMON → PIXEL_SHADER_RESOURCE`），漏一步就是空白帧 |
| **`present_wait` 覆盖不齐** | 驱动依赖高。要写 runtime feature detection + 三档 fallback。这是本项目 present 手感研究的主要变量 |
| **Descriptor pool 容量规划** | Atlas 扩张不改 descriptor count（只更 image view），但 background image 切换要拿新的 combined image sampler。预分配 ~16 个 slot 够用 |
| **Validation layer 与 release 分离** | Validation 开着会显著改变时序（每次 API 调用多几百 ns）。研究报告里要标注"validation on/off" |
| **调试工具** | RenderDoc 良好，NSight 也支持，**PIX 不支持 Vulkan**——损失 D3D 侧最好的性能分析工具 |

## 三、主要风险

1. **代码量**：骨架 1800–2500 行 Zig（instance/device/queue/swapchain/sync/
   descriptor/pipeline/upload），比 D3D12 略大。
2. **DComp 桥接可能失败**：外部内存 + 外部信号量的 D3D11↔Vulkan 互操作在部分
   驱动上有 bug（历史上 AMD 的 shared fence 有过问题）。研究项目**允许失败**，
   fallback 到 layered window 记为对照数据。
3. **RDP 完全失联**：不是风险，是设计决定。
4. **present_wait 三档 fallback 的结论可能是 negative**：即"三档都拖不动
   DXGI waitable 的手感"——这本身也是有效研究结果。

## 四、与 D3D12 / GL 4.6 差异（本 note 聚焦部分）

| 维度 | D3D12 | **Vulkan** | GL 4.6 |
|---|---|---|---|
| Shader source | HLSL→DXIL | **HLSL→SPIR-V**（与 GL 共享） | HLSL→SPIR-V（与 VK 共享） |
| Frame-latency | DXGI waitable + D3D12 fence | **`present_wait` + timeline + mailbox 三档** | `GL_ARB_sync` 手动 gate（最弱） |
| DComp 集成 | 原生 | **VK_KHR_external_memory + D3D11 shared texture 桥** | WGL_NV_DX_interop2 桥 |
| RDP | WARP12 可用 | **无**（明确放弃） | 通常退化到 GDI 1.1（不可用于 4.6） |
| Sync 显式度 | 中（fence + barrier） | **高（三层 + timeline）** | 低（`glClientWaitSync`） |
| 调试工具 | PIX/RenderDoc/NSight | RenderDoc/NSight（无 PIX） | RenderDoc |
| 骨架代码量 | 1500-2000 行 | **1800-2500 行** | 1000-1500 行 |
| 研究学习收益 | 中 | **最高**（explicit sync + 外部内存） | 中（SPIR-V ingest 验证） |

## 五、结论（研究视角）

- **值得做**，且是四个后端里研究收益最高的一档：
  1. Explicit sync 三层的实战演练（其他后端只有一或两层）；
  2. 外部内存 / 外部信号量互操作是 D3D↔Vulkan 交互的最深处；
  3. `present_wait` 三档 fallback 的手感对比是本项目主要交付物之一。
- **允许失败的范围**：DComp 桥接可以退化到 layered window，RDP 明确放弃，
  软件 ICD（lavapipe）作为对照不进 baseline。
- **相对 D3D12 的独立价值**：D3D12 在 DXGI/DComp/RDP 上路径与 D3D11 高度重合，
  research delta 主要在 explicit pipeline；Vulkan 才是 explicit sync 的
  完整教科书。
- **相对 GL 4.6 的独立价值**：两者共享 SPIR-V 管线，但 GL 是"高层 API +
  SPIR-V"的组合，Vulkan 是"完全显式 + SPIR-V"，同步与内存管理完全不同档。
  两个后端跑同一个 shader 出同一个终端，是本项目最漂亮的对照。

**建议里程碑**：M4 拆两阶段——**M4a** 无 DComp 版（layered window）跑通
baseline smoke；**M4b** 加 DComp 桥接。M4a 完成后就可以进 M6 的 present
手感对比测试，不必等 M4b。

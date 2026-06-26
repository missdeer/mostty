# Windows 上 Vulkan 可行性与 DirectX 对比

可以，而且在 Windows 上 Vulkan 是一等公民——NVIDIA/AMD/Intel 三家的 Windows 驱动都长期维护 Vulkan 实现，DOOM Eternal、Red Dead Redemption 2、No Man's Sky、星际公民等大作 Windows 版都用 Vulkan 出货，生产可用性没有问题。

## 与 D3D11 / D3D12 对比

| 维度 | D3D11 | D3D12 | Vulkan (Windows) |
|---|---|---|---|
| API 抽象层级 | 高（驱动管同步、状态） | 低（手动管） | 低（手动管，比 D3D12 更显式） |
| 驱动成熟度（Win） | 最稳 | 稳 | 稳，但厂商间细节差异比 D3D12 大 |
| 性能上限 | 中 | 高 | 高（与 D3D12 同档） |
| CPU overhead | 高 | 低 | 低 |
| 调试工具 | PIX/RenderDoc | PIX/RenderDoc/NSight | RenderDoc/NSight（PIX 不支持） |
| 着色器 | HLSL 直接编 | HLSL 直接编 | GLSL/HLSL → SPIR-V（DXC 可输出 SPIR-V） |
| 与 DComp/DWM 集成 | 原生 | 原生 | **要走 `VK_KHR_win32_surface` + 自己的 swapchain，跟 DComp 桥接很别扭** |
| 远程桌面 / 软件渲染 | 自动回退 WARP | 自动回退 WARP | **基本不可用**（RDP 下通常没有 Vulkan ICD） |
| 跨平台 | Windows only | Windows only | Win/Linux/Android/macOS(MoltenVK) |

## 对本项目（Mostty）的具体含义

**性能**：跟 D3D11 比，Vulkan 在"每帧几个 draw call、几 KB 上传"的终端负载下**没有可见收益**——D3D12/Vulkan 的优势在 draw call 上万、复杂 PSO 切换的场景。终端的瓶颈在 CPU 端的 cell diff 和字体光栅化，不在 GPU 提交路径。

**远程桌面**：这是 Vulkan 的硬伤。`cpu-high-usage-in-rdp-software-render.md` 提到的 RDP 场景下，Vulkan 通常根本拿不到设备，必须保留 D3D11 路径做 fallback——也就是说**不能用 Vulkan 替换 D3D11，只能并存**，这又回到双后端维护成本的问题。

**DirectComposition 集成**：跟 OpenGL 的结论一样，Vulkan swapchain (`VK_KHR_swapchain`) 跟 DComp 的合成模型不对齐，无边框透明窗口要么换 `VK_EXT_full_screen_exclusive`（限制窗口模式），要么靠 `VK_KHR_external_memory_win32` 把图像导成 D3D 纹理交给 DComp（可行但代码量大，且对 swapchain 同步语义要求高）。

**编码代价**：Vulkan 的样板代码量是 D3D11 的 3–5 倍——instance/device/queue family/descriptor pool/pipeline layout/render pass/synchronization2 这一整套，对终端这种 single full-screen-triangle 的渲染量来说严重过度工程。当前 `terminal.hlsl` 223 行 + `d3d11.zig` 1803 行的规模，换 Vulkan 后端骨架本身就要 1500–2000 行 Zig，价值很低。

## 结论

- **能用**，Windows 上 Vulkan 完全生产可用。
- **不建议**用 Vulkan 作为 Mostty 第二渲染后端：性能没收益、RDP 不可用、DComp 集成困难、代码量翻倍。
- 如果未来真要做跨平台（Linux 终端），Vulkan 才有意义；只在 Windows 上，**继续单 D3D11 后端是更诚实的选择**。如果一定要"备用后端"挡远程桌面，D3D11 + WARP 软件回退就是答案，已经在代码里（`remote_or_software_adapter` 路径）。

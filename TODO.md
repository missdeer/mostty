# TODO

## RDP/软件适配器场景下 CPU 飙升修复

**背景**：在 RDP 会话里使用 Mostty，Claude Code 处于思考状态（spinner 动画）时，Mostty.exe 持续 20%+ CPU；思考结束立即降回 0.x%。

**环境前提**：开发机 RDP 远端主机出于兼容性考虑，已**主动关闭 RemoteFX 等硬件加速**（RemoteFX vGPU 在 Windows Server 2019+ 已被微软因 CVE-2020-1036 移除，本来也是默认状态）。所以 RDP 会话是**纯软件渲染 + 软件编码路径**——这不是意外退化，而是用户明确选择，修复必须在纯软路径下成立。

**根因**：上述环境下 D3D11 选到 `Microsoft Basic Render Driver`（WARP 软件光栅化）。当前代码用 `Present(0, 0)` 立即返回，把光栅化派给 Windows 线程池 worker 异步处理。SetTimer 节流只 cap 了 paint 的频率（producer rate），没 cap 单帧的 worker 成本（consumer cost）。spinner ~18 fps 持续派活，~20 个 TPP worker 各占 1.6–1.8% CPU，加起来 ~30%。

**仪表化证据**（已在 src/win32/state.zig 加诊断日志）：
- UI 线程 `renderWindow` 仅 ~10 ms/s
- VT `nextSlice` 仅 <1 ms/s
- Process Explorer 显示 ~20 个 `ntdll!RtlSetThreadSubProcessTag+0x1770` worker 线程吃掉绝大部分 CPU

---

### Phase 1: per-adapter Present sync_interval + OCCLUDED 处理

- [ ] **改动 1**：`src/win32/d3d11.zig:1124` 的 `Present(0, 0)` 改为按适配器选择：
  ```zig
  const sync_interval: u32 = if (self.remote_or_software_adapter) 1 else 0;
  const hr = swap_chain.IDXGISwapChain.Present(sync_interval, 0);
  ```
  原理：软件路径下 `Present(1, 0)` 让 DXGI 等上一帧 TPP worker 做完才返回，自然反压 producer rate 到 consumer 实际吞吐。

- [ ] **改动 2**：补 `DXGI_STATUS_OCCLUDED` 处理（0x087A0001，正数，当前 `if (hr < 0)` 不会触发）：
  - 收到 OCCLUDED 后，renderer 进入 occluded 状态，后续 paint 改用 `Present(0, DXGI_PRESENT_TEST)` 轮询
  - 收到 `S_OK` 时恢复正常路径
  - 窗口最小化路径（`IsIconic`）已经短路 paint，不需要额外处理

- [ ] **改动 3**：保留现有 SetTimer 节流不动。本地硬件路径它仍是 fps cap；软件路径它变成上限保护，由 Present(1) 真正反压。

- [ ] **改动 4**：commit message 解释「为什么 35d1351 review 时反对 Present(1) 的两条理由（叠加 cap 砍半 FPS / RDP vsync 阻塞 UI）在 software 路径下反而是 feature」。

#### Phase 1 验证

1. **复现基线**（修改前）：
   - 启动 Mostty（RDP 环境）
   - 启动 Claude Code，进入思考状态，保持 30+ 秒
   - Process Explorer 观察 Mostty.exe **CPU 应稳定在 15–30%**
   - 检查 `tmp/mostty.log`：render busy 应约 10 ms/s

2. **应用 Phase 1 改动，重新构建**：
   ```
   cmd.exe /c "D:\zig-x86_64-windows-0.15.2\zig.exe build --global-cache-dir D:\zig-cache"
   ```

3. **复现验证**（修改后）：
   - 同样的场景（RDP + Claude Code 思考）
   - **期望**：Mostty.exe CPU 降到 **5% 以下**（理想 1–3%）
   - **期望**：Process Explorer 里 TPP worker 线程数和 CPU 占比显著下降
   - **期望**：`tmp/mostty.log` 里 render busy 不一定降（单帧成本不变），但 renders/s 可能从 18 降到 10–15（被 vsync 反压）

4. **不能回退的对照点**：
   - 本地（非 RDP）启动 Mostty，正常使用：CPU、帧率、输入响应都不应有任何变化
   - 大块 PTY 突发（`find / 2>/dev/null` 之类）：CPU 峰值可能略低，不应更高

5. **OCCLUDED 验证**：
   - 用另一个窗口完全盖住 Mostty 窗口
   - 在底下产生 PTY 输出（`yes` 之类）
   - **期望**：Mostty CPU 接近 0（不再 paint），`tmp/mostty.log` 里 render 频次趋零
   - 切回 Mostty 窗口，渲染立即恢复正常

6. **回归检查**：
   - 多 tab 切换、resize 窗口、最大化最小化、关闭/新开 tab、改 config 热重载——所有路径都应正常工作

#### Phase 1 失败的回退条件

如果出现以下任一情况，回退并改用其他方案：
- 本地硬件路径 fps 真的被砍半且能感知（Present(1) 在某些驱动下行为不一致）
- RDP 下输入延迟明显恶化（>200ms 卡顿）
- 拖拽 resize 窗口时频繁出现 "Not Responding" 鬼影

→ 这些都是 Phase 2 要解决的问题。

---

### Phase 2: GetFrameLatencyWaitableObject 解耦 back-pressure 与 UI 阻塞

**触发条件**：仅当 Phase 1 上线后**确实观察到**输入卡顿、resize 鬼影、或多 tab 一个堵住影响其他 tab，才推进 Phase 2。否则维持 Phase 1 不动。

**目标**：把 back-pressure 从 UI 线程同步阻塞（`Present(1)` 的副作用）改成由 waitable handle 驱动，UI 线程在主循环里和 tab process handle 一起 wait，永远不在 Present 里卡住。

**好消息**：swap chain 创建时（d3d11.zig:1147）已经带了 `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT` flag 并 cast 到 `IDXGISwapChain2`，半成品基础设施已就位，Phase 2 只是把信号线接通。

#### Phase 2 改动清单

- [ ] **改动 1**：`src/win32/d3d11.zig:initSwapChain` 末尾追加：
  ```zig
  const hr = swap_chain2.SetMaximumFrameLatency(1);
  if (hr < 0) fatalHr("SetMaximumFrameLatency", hr);
  self.frame_latency_waitable = swap_chain2.GetFrameLatencyWaitableObject() orelse
      win32.panicWin32("GetFrameLatencyWaitableObject", win32.GetLastError());
  ```
  D3d11Renderer 加字段：`frame_latency_waitable: ?win32.HANDLE = null`

- [ ] **改动 2**：`src/win32/state.zig:Window` 加字段：
  ```zig
  gpu_ready: bool = true,  // 初始 true：第一帧没 backlog
  ```

- [ ] **改动 3**：改写 `requestRender` / `scheduleRender`：
  - paint 调度新增 gate：`gpu_ready == true` 才允许 InvalidateRect
  - `gpu_ready == false` 时既不 InvalidateRect 也不 SetTimer，等 waitable signal
  - `noteRender`（onPaint 末尾）里 `gpu_ready = false`

- [ ] **改动 4**：`src/mosttywindows.zig` 主循环 `MsgWaitForMultipleObjectsEx` 句柄数组加 frame_latency_waitable：
  ```
  handles = [...tab_process_handles, frame_latency_waitable]
  ```
  返回值是 waitable 的 index 时：
  ```
  window.gpu_ready = true
  if window.render_pending: window.scheduleRender()
  ```

- [ ] **改动 5**：`src/win32/d3d11.zig:1124` 回退到 `Present(0, 0)`（所有路径统一），back-pressure 完全交给 waitable。

- [ ] **改动 6**：SetTimer 节流保留不动（仍作为 fps cap）。

#### Phase 2 验证

1. **冒烟测试**（本地非 RDP）：
   - 启动 Mostty，正常使用 5 分钟
   - **期望**：行为、帧率、CPU 与 Phase 1 等价或更好
   - 检查 `tmp/mostty.log`：render 频次、render busy 应与 Phase 1 接近

2. **RDP 复现验证**（与 Phase 1 相同）：
   - **期望**：CPU 占比与 Phase 1 等价（5% 以下）

3. **关键改进点验证**（Phase 1 失败的场景应在 Phase 2 通过）：
   - **输入响应**：在 RDP 下 Claude Code 思考的同时疯狂敲键盘
     - Phase 1 期望：可能 50–200ms 卡顿
     - Phase 2 期望：键入即时响应，<16ms 延迟
   - **resize 拖拽**：RDP 下拖拽窗口边框 10 秒
     - Phase 1 期望：可能出现 "Not Responding" 鬼影
     - Phase 2 期望：窗口始终响应，无鬼影
   - **多 tab 隔离**：开 2 个 tab，A 跑 Claude Code 思考，B 空闲
     - 在 B 上按 Ctrl+Tab 切回 A 应秒切
     - Phase 2 期望：tab 切换响应无延迟

4. **waitable + DCOMP 兼容性验证**：
   - 当前 swap chain 走 `CreateSwapChainForComposition` + DCOMP 绑定
   - 文档上 waitable 与 DCOMP 兼容，**但需实测**
   - **期望**：渲染正常无花屏、无 DCOMP commit 失败、Present 不返回未预期 HRESULT
   - **不期望**：渲染撕裂、半帧、黑屏

5. **首帧 / 边界情况**：
   - 启动后第一帧能正常画出（`gpu_ready` 初始 true 的逻辑）
   - 关闭所有 tab 后新开 tab，第一帧能画
   - 窗口最小化 → 恢复，渲染正常
   - 窗口完全遮挡 → 解除遮挡，渲染正常（与 OCCLUDED 处理协同）

6. **回归检查**：同 Phase 1 第 6 条。

#### Phase 2 失败的回退条件

- waitable 与 DCOMP 不兼容（撕裂/花屏/Present 异常）
- 首帧或某种边界情况下 `gpu_ready` 永远 false 导致渲染冻结
- 主循环 wait 句柄数已接近 `MAXIMUM_WAIT_OBJECTS - 1 = 63`（当前 MAX_TABS 远低于此，但需 assert 防御）

→ 回退到 Phase 1，重新评估是否需要更大的架构调整（独立 render thread 等）。

---

### 临时诊断代码处置

修复合入后，决定如何处置当前 PR 里的诊断代码：

- [ ] `src/mosttywindows.zig` 的 `fileLogFn`：临时文件日志，**移除**（subsystem=Windows 没控制台是有意的）
- [ ] `src/win32/state.zig` 的 `qpcNow` / `qpcUsSince` / 各 `diag_*` 字段：**保留**，加 build option `-Drender-diag=true` 守起来，默认关闭。理由：以后还会复用，且开销已证实 <0.01% CPU
- [ ] `src/win32/wnd/paint.zig` / `misc.zig` 的 timing 调用：同上，build option 控制
- [ ] `tmp/mostty.log`：调试结束手动删除，加入 `.gitignore`（如未在）

# DONE
- [x]拖拽输入文件路径
- [x]输入窗口候选窗口定位
- [x]粘贴多行时只能粘贴到同一行，所有回车换行符丢了
- [x]运行时性能审计优化
- [x]换名字为`Mostty`
- [x]接入 ghostty-vt 的 write_pty 回调，把 CSI c / DECRQM 等终端查询的响应写回 PTY（当前缺失会让 nvim/fzf 等依赖查询的工具行为异常）
- [x]在标题栏右键系统菜单上添加一个`Theme`子菜单，列出所有可用的theme，点击菜单项则切换到该theme，但这个切换只是当前session热切换，程序下次启动时仍从配置文件中读取theme
- [x]git commit 5a2709b 修正了emoji彩色渲染后，似乎整体渲染性能变差了，需要调研是否可以优化
- [x]增加鼠标移动和点击事件响应，以供TUI正确渲染，比如`python -m textual`

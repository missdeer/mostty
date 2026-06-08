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

- [x] **改动 1**：`src/win32/d3d11.zig:1124` 的 `Present(0, 0)` 改为按适配器选择：
  ```zig
  const sync_interval: u32 = if (self.remote_or_software_adapter) 1 else 0;
  const hr = swap_chain.IDXGISwapChain.Present(sync_interval, 0);
  ```
  原理：软件路径下 `Present(1, 0)` 让 DXGI 等上一帧 TPP worker 做完才返回，自然反压 producer rate 到 consumer 实际吞吐。
  实现细节：sync_interval 选择与 occluded 状态联动（occluded 时强制 0 + `DXGI_PRESENT_TEST`）。

- [x] **改动 2**：补 `DXGI_STATUS_OCCLUDED` 处理（0x087A0001，正数，当前 `if (hr < 0)` 不会触发）：
  - 收到 OCCLUDED 后，renderer 进入 occluded 状态，后续 paint 改用 `Present(0, DXGI_PRESENT_TEST)` 轮询
  - 收到 `S_OK` 时恢复正常路径
  - 窗口最小化路径（`IsIconic`）已经短路 paint，不需要额外处理
  实现细节：`D3d11Renderer` 加 `occluded: bool = false` 字段；`DXGI_STATUS_OCCLUDED` 常量在 d3d11.zig 顶部手动定义（zigwin32 只导出负向 DXGI_ERROR_*，未导出该 success code）。

- [x] **改动 3**：保留现有 SetTimer 节流不动。本地硬件路径它仍是 fps cap；软件路径它变成上限保护，由 Present(1) 真正反压。

- [x] **改动 4**：commit message 解释「为什么 35d1351 review 时反对 Present(1) 的两条理由（叠加 cap 砍半 FPS / RDP vsync 阻塞 UI）在 software 路径下反而是 feature」。

---

### 增补：拖动标题栏 CPU 飙到 30%（已修）

Phase 1 部署后用户发现：拖动标题栏，即使终端只有 shell prompt + 不闪烁光标（零内容变化），CPU 也飙到 30%。停止拖动立即恢复。

**根因**：`src/win32/wnd/paint.zig:onWindowPosChanged` 在 `WM_WINDOWPOSCHANGED` 上**无条件**调用 `render.renderWindow(window)`，**绕过 SetTimer 节流**。Windows 以 60–125 Hz 节奏发送该消息，每帧做完整 render → tab bar D2D 重绘 → cell upload → Present；WARP 路径上 30% CPU 完全合理。

**修复**：纯 move 事件（`pos.flags.NOSIZE != 0`）直接 return，不触发 render。size 变化路径保留原同步 render + ValidateRect 逻辑。

#### Phase 1 验证

1. **复现基线**（修改前）：
   - 启动 Mostty（RDP 环境）
   - 启动 Claude Code，进入思考状态，保持 30+ 秒
   - Process Explorer 观察 Mostty.exe **CPU 应稳定在 15–30%**
   - 观察诊断输出：render busy 应约 10 ms/s

2. **应用 Phase 1 改动，重新构建**：
   ```
   cmd.exe /c "D:\zig-x86_64-windows-0.15.2\zig.exe build --global-cache-dir D:\zig-cache"
   ```

3. **复现验证**（修改后）：
   - 同样的场景（RDP + Claude Code 思考）
   - **期望**：Mostty.exe CPU 降到 **5% 以下**（理想 1–3%）
   - **期望**：Process Explorer 里 TPP worker 线程数和 CPU 占比显著下降
   - **期望**：render busy 不一定降（单帧成本不变），但 renders/s 可能从 18 降到 10–15（被 vsync 反压）

4. **不能回退的对照点**：
   - 本地（非 RDP）启动 Mostty，正常使用：CPU、帧率、输入响应都不应有任何变化
   - 大块 PTY 突发（`find / 2>/dev/null` 之类）：CPU 峰值可能略低，不应更高

5. **OCCLUDED 验证**：
   - 用另一个窗口完全盖住 Mostty 窗口
   - 在底下产生 PTY 输出（`yes` 之类）
   - **期望**：Mostty CPU 接近 0（不再 paint），render 频次趋零
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

### Step 0: 临时诊断日志（已完成）

为了从猜测切换到数据驱动，加了一套最小诊断 instrumentation：

- `src/mosttywindows.zig`：曾临时添加 `std_options.logFn = fileLogFn` 把 `std.log.*` 写到文件；现已移除。
- `src/win32/state.zig`：`qpcNow` / `qpcUsSince`（QPC 微秒级 wrapper，atomic 缓存 frequency）；`Window.diag_render_us` / `diag_render_max_us`；`logDiagnostics` 输出 `render stats: X fps cap, Y renders/s, busy A.B ms/s, max C us, D PTY byte/s`。
- `src/win32/wnd/paint.zig`：`timedRender(window)` 把 `renderWindow` 包了 QPC 计时。
- `src/win32/d3d11.zig`：always-on 渲染器 counters（`diag_tabbar_paints`/`rows_uploaded`/`rows_skipped`），`maybeLogDiag` 1Hz flush 输出 `renderer stats: WxH grid (XxY px), N tabbar paint(s)/s, U row(s)/s uploaded, S row(s)/s skipped`。

**首次数据采集结论**（log 见 `zig-out/bin/tmp/mostty.bak.log`）：
- UI 线程 spinner 期间 busy 仅 14–25 ms/s（≈ 2% UI thread CPU）—— Phase 1 已彻底反压住 UI 线程。
- 真正吃 CPU 的是 WARP TPP worker 线程做软件 pixel shading。
- **关键侧信道**：用户报最大化窗口 CPU 翻倍以上 → 反解 `2.5 = (4.3·N·c + f) / (N·c + f)` 得 per-pixel WARP shader cost ≈ 总 CPU 的 70%。
- 锁定瓶颈：`d3d11.zig:Draw(4, 0)` 全屏 pixel shader 跑过每个 back-buffer 像素，即使一帧只有 1 行 cell 真脏（spinner 实测 `1 row uploaded + ~46 rows skipped per render`）。

→ 切到 Step B。

### Step B: persistent grid texture + dirty-row scissor（已完成）

设计文档：`tmp/plan-step-b-persistent-grid.md`（rev 3，Codex / Gemini 两轮 review approved 后才动代码）。

**核心思路**：把"算像素"和"交给 swap chain"两步解耦。

1. 新增 owner-managed offscreen `ID3D11Texture2D`（"grid texture"），尺寸 = client area。
   - 格式 `B8G8R8A8_TYPELESS` 资源 + `B8G8R8A8_UNORM_SRGB` RTV view（**注意**：不能像 back buffer 那样用 `B8G8R8A8_UNORM` 资源 —— flip-model 给 back buffer 偷偷加了 TYPELESS 的 special concession，`CreateTexture2D` 没这特权，会返 `E_INVALIDARG = 0x80070057`）。
2. 用 `RSSetScissorRects` + `ScissorEnable=TRUE` rasterizer state，把 cell pixel shader 限制到本帧真脏的行带。
3. 每帧 `CopyResource(back_buffer, grid_texture)` 把 grid texture 拷到刚 rotate 出来的 undefined back buffer 上。
4. tab-bar D2D paint + Present 不变。
5. **删除 `ClearRenderTargetView`** —— shader 覆盖 scissor rect 内所有像素，rect 外 grid texture 保留上帧像素；clear 忽略 scissor 反而会把好像素抹掉。

**Dirty-trigger 覆盖**（rev 3 review 锁定的不变量：**任何让 glyph_cache reset 的路径都必须 set `grid_force_full = true`**）：
- 每行 `uploadCellRow` 返回 `bool`，per-row loop / blank-fill tail / resize-overlay 三处都更新 `dirty_min_row` / `dirty_max_row`。
- `GridConfigSnapshot` 缓存上帧所有非-per-cell 的 const-buffer 字段（cell_size, col/row count, cells_per_row, tab_bar_height, scrollbar geom）；不匹配 → `grid_force_full = true`。
- 显式钩子：`updateFont`、`updateDpi`、`setupGlyphAtlas`（cache reset 分支）三处都 set `grid_force_full = true`。
- `resizing` 也强制 full-redraw（覆盖底部不能整除 cell_h 的残余条带）。
- `grid_force_full` 只在真的画了一帧之后才 clear（draw 被 skip 的帧保留这个标志到下一帧）。

**Skip 路径**：`!grid_force_full && dirty_min_row == null` → 跳过 Draw，但仍然 `CopyResource` + Present（flip-model 给的 back buffer 是 undefined，必须 deliver 上一帧的 grid texture 内容）。

**Reviewer-caught corrections during implementation**:
- 启动 crash `0x80070057`：grid texture 资源最初用了 `B8G8R8A8_UNORM`，改成 `B8G8R8A8_TYPELESS`（详见上面的 special concession 说明）。
- 第一轮 review codex 找出：`setupGlyphAtlas` 也 reset glyph_cache 但漏了 `grid_force_full = true`，已补。

**待用户测试验证**：spinner CPU 从 10–45% 应降到 ~3–14%（per-pixel shader cost 占 ~70%，dirty 行只占 ~2.2% 像素 → ~68% 总 CPU 节省）。最大化窗口的 CPU scaling 也应大幅减弱。

**后续可选优化**（按 ROI 排序，等用户测了 Step B 实际效果再定）：
- **B-followup-1：true frame skip**（不 Present）—— 谓词非平凡（scrollbar/tab-bar hover 等），单独 patch。
- **B-followup-2：`Present1` + `pDirtyRects`** —— 省 DWM 合成 CPU + RDP 带宽（与 Step B 省 shader CPU 正交）。
- Tab-bar D2D paint caching：数据显示 UI 线程已健康，预期收益小。

---

### Phase 2（已搁置）: GetFrameLatencyWaitableObject 解耦 back-pressure 与 UI 阻塞

**触发条件**：仅当 Phase 1 上线后**确实观察到**输入卡顿、resize 鬼影、或多 tab 一个堵住影响其他 tab，才推进 Phase 2。否则维持 Phase 1 不动。

**当前状态**：用户未报告这三类症状；Step B 已直接砍掉了主要 CPU 成本。Phase 2 暂不推进。

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
   - 观察诊断输出：render 频次、render busy 应与 Phase 1 接近

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

- [x] `src/mosttywindows.zig` 的 `fileLogFn`：临时文件日志，**移除**（subsystem=Windows 没控制台是有意的）
- [ ] `src/win32/state.zig` 的 `qpcNow` / `qpcUsSince` / 各 `diag_*` 字段：**保留**，加 build option `-Drender-diag=true` 守起来，默认关闭。理由：以后还会复用，且开销已证实 <0.01% CPU
- [ ] `src/win32/wnd/paint.zig` / `misc.zig` 的 timing 调用：同上，build option 控制
- [x] `tmp/mostty.log`：临时文件日志已移除，不再生成

# DONE
- [x]RDP/WARP CPU 飙升：Phase 1 (Present(1) + OCCLUDED) + 拖动 NOSIZE short-circuit + Step 0 诊断日志 + Step B persistent grid + dirty-row scissor
- [x]拖拽输入文件路径
- [x]输入窗口候选窗口定位
- [x]粘贴多行时只能粘贴到同一行，所有回车换行符丢了
- [x]运行时性能审计优化
- [x]换名字为`Mostty`
- [x]接入 ghostty-vt 的 write_pty 回调，把 CSI c / DECRQM 等终端查询的响应写回 PTY（当前缺失会让 nvim/fzf 等依赖查询的工具行为异常）
- [x]在标题栏右键系统菜单上添加一个`Theme`子菜单，列出所有可用的theme，点击菜单项则切换到该theme，但这个切换只是当前session热切换，程序下次启动时仍从配置文件中读取theme
- [x]git commit 5a2709b 修正了emoji彩色渲染后，似乎整体渲染性能变差了，需要调研是否可以优化
- [x]增加鼠标移动和点击事件响应，以供TUI正确渲染，比如`python -m textual`

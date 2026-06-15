# TODO

## 性能优化(详见 `optimize.md`)

### 第三档:只在前面都不够时考虑
- VT #3 — parser 移到独立线程(~800-1500 行)
  - `vt.Terminal` 无内置线程安全,需外部 Mutex 或 snapshot 模型
  - resize / scrollback / IME / selection / hot-reload 同步契约全部要重做

### 其他
- 若动机是 RDP 性能,优化现有 D3D11 + WARP 路径(`d3d11.zig:113,358,769`)即可
- add `cursor-*` configuration items, ref https://ghostty.org/docs/config/reference#cursor-color

# DONE

- VT #2: reader → 每 tab SPSC 1 MiB byte ring + edge-triggered `PostMessage`,取代同步 `SendMessage`(`src/win32/pty_ring.zig` + child_process / tab_mgmt / wnd/misc 改动)。reader 把 `ReadFile` 输出 memcpy 进 ring;ring 满则阻塞在 auto-reset wake_event,destroyTab 用 `SetEvent + CancelIoEx` 唤醒后直接 `thread.join`(原 `MsgWaitForMultipleObjects + PeekMessage` drain 循环作废)。`posted` 原子布尔做 empty→non-empty 边沿守卫,handler 入口先清零,drain 后若 byte_count > 0 才 `requestRender`(redundant 唤醒变 no-op)。WM_APP_CHILD_PROCESS_DATA wparam 现在直接是 TabId,`ReadMsg`/`WM_APP_CHILD_PROCESS_DATA_RESULT` 删除。closing 分支仍走 drain(no-op cb)推进 tail + SetEvent,避免 closeTabByIndex 到 destroyTab 之间 reader 卡在满 ring。startConPtyWin32 错误清理路径补 `stop+SetEvent+CancelIoEx` 再 join,防止 reader 卡在 ring-full 等位
- 字体 #2: 首次 raster 异步化到 worker thread(Stages A-E,~1200 行)。Worker 自建 `ID2D1Factory(MULTI_THREADED)` + WIC bitmap RT 输出 CPU BGRA,UI thread `UpdateSubresource` 上 atlas;UI 的 D3D/D2D context 完全不动。双 generation(全局 `cache_gen` + per-slot `gen`)+ `Node.pending` 状态机让 LRU eviction 跳过 in-flight slot;空格走 sync 打破自举,wide-pair 保持 sync,queue 满返回 blank 占位等下帧重试。`unicode-test.txt` 雪崩不再卡 UI thread。`renderer.deinit` 调 `PeekMessage` drain WM_APP_GLYPH_READY 防泄漏。WIC mask RT 用 `32bppBGR + IGNORE`(`BGRA + IGNORE` 不在 D2D `CreateWicBitmapRenderTarget` 白名单,会拿 `WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT` crash 启动)
- VT #1: `ReadFile` 缓冲 4 KB → 64 KB(`child_process.zig:394`)。大量输出(`cat large.log`)时 reader 线程的 `ReadFile`/`SendMessage` 往返次数减少 16×;栈缓冲,无额外分配
- 字体 #1: `generateWidePair` sprite 分支折叠为单次 raster + 至多两次 upload(`d3d11/glyph.zig`)。新 helper `uploadSpriteWidePairToAtlas`;sprite.render 失败回退到 DirectWrite,reserve→touch→reserve 序列保留
- @src/win32/d3d11.zig is too large, is it possible to split it to several smaller files
- `background-image`: cold-start now decodes off-thread too. `setBackgroundImage`/`gpu.loadBackgroundImage`/`ensureComInit` deleted; startup calls `reloadBackgroundImage` right after `CreateWindowExW`, so the WIC decode runs in parallel with DWM setup + `ShowWindow` and presents via `WM_APP_BG_IMAGE_DECODED` once the message pump spins
- `background-image`: previous startup path dupes path before decode and bails on OOM, so a failed dupe no longer leaves `bg_image_path` empty and forces a redundant re-decode on the next reload
- `background-image`: hot-reload now decodes off the UI thread (`reloadBackgroundImage` + WM_APP_BG_IMAGE_DECODED worker); old image stays visible until the new one is ready
- add `background-image` & `background-image-*` configuration items, ref https://ghostty.org/docs/config/reference#background-image
- add `maximize` & `fullscreen` configuration items, ref https://ghostty.org/docs/config/reference#maximize

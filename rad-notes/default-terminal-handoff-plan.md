# Plan — Mostty 接入 Windows 默认终端(ConPTY Handoff)

把 Mostty 做成可被 Windows "默认终端应用" 调起的终端:当系统启动一个控制台程序
(cmd/pwsh/双击 .bat 等)时,由 conhost 通过 COM 把 ConPTY 会话交接给 Mostty 渲染。

> 本版已纳入 Codex / Antigravity 三方评审(2026-06-19),并对所有结论用
> microsoft/terminal 源码(`tmp/terminal-src`,commit `1282d56`)逐条核对。
> **评审推翻了初版两个核心假设**(见 §0.6),scope 比初版显著变大。

---

## 0. 锁定的决策

1. **激活模型:`REGCLS_MULTIPLEUSE` + 单进程**(印证 WT `CTerminalHandoff::s_StartListening`)。
2. **窗口模型:单进程单窗口,每个交接 = 新 tab**。不引入多窗口。
3. **不做** "进用户手动打开的窗口" 的单实例转发(monarch/peasant)。手动启动的
   Mostty 不注册类工厂,不接管交接。
4. **只实现终端侧 `ITerminalHandoff3`**(IID `6F23DA90-15C5-4203-9DB0-64E73F1B1B00`,
   conhost 直接 QI v3、不回退)。v1/v2 不实现。
5. **resize 走 signal 裸包(公开路径)为主**:`ConptyPackPseudoConsole` **不是公开
   SDK API**(WT 靠内部 `winconptylib.lib`),故**不依赖 HPCON**。resize = 往 signal
   管道写 `u16[3]{8,cols,rows}`(§1.3);teardown = 直接 `CloseHandle`
   server/reference/signal。HPCON 路线仅在愿意 vendor `winconptylib` 时作为备选。
6. **【评审推翻的假设,已修正】**
   - ❌ "DelegationConsole 复用 inbox conhost `{B23D10C0}`、只做终端侧" —— **错误**。
     见 §3.1,必须自备 console 委托。
   - ❌ "console 委托可指向 stock OpenConsole / inbox conhost(只换 CLSID)" ——
     **错误**,`CConsoleHandoff` 的 CLSID 是**编译期硬编码**,见 §3.1。
   - ❌ "手糊 vtable 的 LocalServer32 即可" —— **不够**,缺 proxy/stub,见 §3.2。
   - ❌ "两条匿名单向管道" —— **错误**,是 1 条 overlapped 双工命名管道,见 §3.4。
   - ❌ "resize 用 `ConptyPackPseudoConsole` 打包 HPCON" —— 该 API 非公开,见 §0.5。

---

## 1. 接口与协议(源码核对,均成立)

### 1.1 IID / 接口(`src/host/proxy/ITerminalHandoff.idl`)
| 接口 | IID | 状态 |
|---|---|---|
| `ITerminalHandoff`  | `59D55CCE-...` | DEPRECATED |
| `ITerminalHandoff2` | `AA6B364F-...` | DEPRECATED |
| **`ITerminalHandoff3`** | **`6F23DA90-15C5-4203-9DB0-64E73F1B1B00`** | **实现这个** |

conhost 调用侧 `srvinit.cpp:483`:`CoCreateInstance(delegationPair.terminal, ...,
IID_PPV_ARGS(&ITerminalHandoff3))`。

### 1.2 v3 方法签名
```c
HRESULT EstablishPtyHandoff(
    [out] HANDLE* in,        // 终端创建并回传
    [out] HANDLE* out,       // 终端创建并回传(= *in 的副本,见 §3.4)
    [in]  HANDLE  signal,    // 终端 DuplicateHandle 后持有 → resize 写此管道(§1.3)
    [in]  HANDLE  reference, // 同上
    [in]  HANDLE  server,    // 同上(conhost 进程句柄)
    [in]  HANDLE  client,    // 客户端进程句柄,DuplicateHandle 后等它退出关 tab
    [in]  const TERMINAL_STARTUP_INFO* startupInfo);
```

### 1.3 Signal 包格式(resize 主路径,见 §0.5)
`u16[3] = {PTY_SIGNAL_RESIZE_WINDOW=8, cols, rows}`,6 字节写 signal 管道
(`winconpty.cpp:_ResizePseudoConsole`)。

### 1.4 设默认的注册表(`DelegationConfig.cpp`)
- 键 `HKCU\Console\%%Startup`,值 `DelegationConsole` / `DelegationTerminal`
  (REG_SZ,`{...}` 形式)。
- 已知 CLSID:conhost `{B23D10C0-...}`;WT terminal `{E12CFF52-...}`、WT console
  `{2EACA947-...}`。
- 下拉框枚举走 `com.microsoft.windows.console.host` AppExtension,**仅 MSIX 可声明**,
  且要求 console+terminal 来自**同一个包**(`DelegationConfig.cpp:183`
  `IsFromSamePackage`)。非打包版进不了下拉框,只能写注册表设默认。

---

## 2. 现状与改造点

现状单一硬编码路径:`main()` 建窗 → `WM_CREATE` → `newTab` → `startConPtyWin32`
(建匿名管道 + reader 线程 + `CreatePseudoConsole` + `CreateProcessW` + job)。

handoff 的差异:conhost 已建好 client 进程与 console 服务器;我们建双工管道、持有
signal/server/reference(resize 走 signal 包)、回传 client 端;**不建 CreateProcess/job**。

---

## 3. Blocker(动手前必须有方案,逐条来自评审 + 源码)

### 3.1 必须用自有 CLSID 重新编译 OpenConsole 作 console 委托
- `DelegationConfig.cpp:281`:**只要 console 或 terminal 任一 == `{B23D10C0}`,整对
  被判 `ConhostDelegationPair`(legacy,根本不交接)**。故 console 必须是非 conhost、
  非默认的 CLSID,与 terminal 组成 `Custom` 对。
- console 侧需要一个 `IConsoleHandoff` 服务器 = Microsoft `OpenConsole.exe` 里的
  `CConsoleHandoff`。**关键(复审实证):其 CLSID 是编译期硬编码**
  (`CConsoleHandoff.h:22`,release 写死 `{2EACA947}`;= WT 的 console CLSID),且以
  `REGCLS_SINGLEUSE` 注册。**因此:**
  - ❌ 指向 stock `OpenConsole.exe` 换个新 CLSID —— 无效(它只认硬编码 CLSID)。
  - ❌ 指向 inbox `conhost.exe` —— 同理无效。
  - ✅ **唯一可行:从 microsoft/terminal 源码用 Mostty 自有的 `CConsoleHandoff`
    CLSID 重新编译 OpenConsole(MIT),随 Mostty 分发并注册。** 这是一个 C++/MSBuild
    构建依赖(不在 Zig build 内)。
- 自己实现 `IConsoleHandoff`(自做 console server / ConDrv)= 重写 conhost,**排除**。

### 3.2 必须自带并注册 COM proxy/stub DLL
- `ITerminalHandoff3` 的裸 `HANDLE`(`system_handle(sh_pipe/sh_process/...)`)**无法被
  通用 marshaler 编组**;跨进程(conhost→Mostty,LocalServer32)调用依赖 MIDL 生成的
  proxy/stub。WT 用 `OpenConsoleProxy.dll`(`Package.appxmanifest:201-204` 为
  IConsoleHandoff / ITerminalHandoff3 / marker 注册 ProxyStub)。
- **WT 未安装时,该 IID 无 proxy 注册 → conhost 的 QI/调用失败。** Mostty 必须从同一
  IDL 用 MIDL 生成 proxy/stub DLL,并注册到对应 IID。**这是 C/MIDL 产物,非 Zig**,
  需接入 build。

### 3.3 所有传入句柄必须 DuplicateHandle
- `signal/reference/server/client` 是 caller-owned,**COM 调用返回后即被释放**。WT
  `InitializeFromHandoff` 对四者全部 `duplicateHandle`;`client` 用
  `PROCESS_QUERY_INFORMATION|VM_READ|SET_INFORMATION|SYNCHRONIZE` 重开(失败回落普通
  dup)。Mostty 必须照做,否则返回后句柄失效 → `MsgWaitForMultipleObjectsEx` 崩。

### 3.4 管道模型:1 条 overlapped 双工命名管道
- WT:`CreateOverlappedPipe(PIPE_ACCESS_DUPLEX, 128*1024)` → 留 `server` 端(自己
  读+写),`*in = client`、`*out = dup(client)`(两个出参是同一 client 端的两份)。
- 匿名 `CreatePipe` **不支持 overlapped**,conhost 侧会失败。须用
  `CreateNamedPipeW(... FILE_FLAG_OVERLAPPED ...)`。
- **对 Mostty reader 线程的影响(复审修正)**:**不能**用"我方端非 overlapped + 同一
  句柄阻塞读 + UI 线程写"——同步双工句柄会让阻塞 `ReadFile` 与 UI 的 `WriteFile`
  串行化/互相阻塞。**`DuplicateHandle` 拆成两个句柄也无效**:副本共享同一 file object,
  仍按同步 I/O 串行。**唯一可靠修法:我方保留端设 overlapped**,reader 用 overlapped
  `ReadFile`+event、写用 overlapped `WriteFile`(贴近 WT 的 `_pipe` 用法)。现状 reader
  的同步阻塞模型需据此改造(本期 scope 内最实打实的一块改动)。

### 3.5 COM 调用内同步建立所有权,再返回
- 不可 "PostMessage 后立刻 S_OK"。若 UI 侧随后失败(MAX_TABS/OOM/HWND 失效/reader
  spawn 失败),conhost 已收下回传管道 → 不可逆。
- 句柄 dup、建 overlapped 双工管道、写 `*in/*out` **必须在 COM 方法内同步
  完成**,失败返回错误 HRESULT。STA 下该方法本就在 UI 线程执行(见 §4.2),tab 可
  直接内联创建,无需自投递。

---

## 4. Major

### 4.1 进程生命周期:CoAddRefServerProcess
- 现状关最后一个 tab 即 `PostQuitMessage`(`tab_mgmt.zig:310`)。MULTIPLEUSE 下这会在首个
  handoff tab 关闭后杀掉服务器进程,后续交接被迫新拉进程,破坏单进程多 tab。
- 方案:tab 创建时 `CoAddRefServerProcess`,销毁时 `CoReleaseServerProcess`;类工厂
  `LockServer` 计入;**仅当服务器引用计数归零才退出主循环**;退出前
  `CoRevokeClassObject`。

### 4.2 COM 套间与注册时序
- **选 STA**:`EstablishPtyHandoff` 在 UI 套间、消息泵转动时被分派 → 可内联建 tab,
  **不要自投递自等待**(会死锁)。
- 类工厂 `CoRegisterClassObject` **必须在 `global.window`/HWND 就绪之后**注册(激活可能
  在注册后立刻到达)。当前 `global.window` 在 `WM_CREATE`(`lifecycle.zig:14`)建立 →
  注册放到建窗、首个空 tab bootstrap 之后。
- 现有主循环是裸 `MsgWaitForMultipleObjectsEx`,需确认其在 STA 下能驱动 COM 调用分派
  (`QS_ALLINPUT` 含 sent-message;`flushMessages` 用 `PeekMessage` 派发)。PoC 验证。

### 4.3 resize/teardown(不依赖非公开 HPCON 打包)
- `ConptyPackPseudoConsole` 非公开 SDK 导出(WT 链 `winconptylib.lib`),**不采用**。
- handoff tab:resize = signal 裸包(§1.3);teardown = `CloseHandle`
  server/reference/signal + 双工管道端 + dup 的 client。`Pty` 用 union:
  `owned{write,hpcon}`(native) | `handoff{pipe_end(s),signal,server,reference}`。
- (可选)若日后愿 vendor `winconptylib`,可改回 HPCON 统一路径。

### 4.4 client 生命周期
- 把 dup 后的 `client` 当 `process_handle` 喂主循环等待(现有退出检测复用)。另:reader
  线程读到 EOF/BROKEN_PIPE 时也应触发关 tab(现状 reader EOF 不投递关闭)。

### 4.5 teardown 覆盖全部句柄
- handoff tab 销毁:`CloseHandle` server/reference/signal、双工管道端、dup 的 client;
  **无 job、无 CreateProcess 产物**。`destroyTab` 现无条件关 job/process/`ClosePseudoConsole`
  (`tab_mgmt.zig:300`),需按 tab 种类分派。

---

## 5. Minor
- `TERMINAL_STARTUP_INFO` 的 `pszTitle`/`pszIconPath`(BSTR)+`iconIndex`+`wShowWindow`
  **须在 COM 调用内拷贝**(返回后失效)。至少消费 title → tab 标题。
- 下拉框需 console+terminal 同包 AppExtension(§1.4);注册表可直接设 Custom 对供功能
  使用,但进不了下拉框。

---

## 6. 代码改造(修订)
1. **入口分流** `mosttywindows.zig:main`:检测 `-Embedding` → `CoInitializeEx(STA)` →
   建空窗 → 注册类工厂(时序见 §4.2)→ 消息循环。普通模式维持现状,`WM_CREATE` 首 tab
   按模式分支。
2. **proxy/stub**(§3.2):新增 IDL + MIDL 步骤,产出并注册 `MosttyHandoffProxy.dll`。
3. **console 委托**(§3.1):以自有 CLSID 重编 OpenConsole,分发 + 注册脚本。
4. **COM 终端服务器**(新 `src/win32/handoff.zig`):`IClassFactory`+`ITerminalHandoff3`
   vtable;`EstablishPtyHandoff` 内同步:dup 句柄 → 建 overlapped 双工管道 →
   (STA 内联)建 tab → 写 `*in/*out` → 返回。
5. **`ChildProcess.fromHandoff`** + `child_process.zig`:接收 overlapped 双工管道端 +
   signal/server/reference + client;spawn 改造后的 reader;无 job/CreateProcess。
   resize = signal 包(§1.3)。
6. **tab 拆分** `tab_mgmt.zig`:抽公共部分;`newTabFromHandoff`;`destroyTab` 按种类
   分派(§4.5);tab 增减处 `CoAddRef/ReleaseServerProcess`(§4.1)。
7. **生命周期**:主循环退出条件改为 COM 服务器引用计数(§4.1)。

---

## 7. 待 PoC 钉死(高优先级)
1. **重编 OpenConsole**:从 terminal 源码以 Mostty 自有 `CConsoleHandoff` CLSID 编出
   OpenConsole.exe,注册后能被 bootstrap conhost 激活并链到 Mostty 终端侧。
2. proxy/stub:MIDL 产物能否在非 Zig build 里生成并注册;最小可被 conhost QI 通过。
3. overlapped 双工管道 + reader 改造:保留端 overlapped、reader 改 overlapped `ReadFile`,
   验证与 conhost 互通。
4. STA:类工厂注册在 UI STA、该线程持续 `GetMessage`/`PeekMessage` 派发,能否正确
   分派 `EstablishPtyHandoff`(空窗 bootstrap 走 `GetMessage` 路径也要能派发)。
5. CoAddRefServerProcess 与现有 "关末 tab 即退出" 的整合。

## 8. 工作量(修订,scope 比初版大)
| 模块 | 量 | 难度 |
|---|---|---|
| COM 类工厂 + ITerminalHandoff3 vtable(同步建立) | 300–400 LoC | 高 |
| **proxy/stub DLL(IDL+MIDL+注册)** 【新增】 | 中等工程 | 高 |
| **重编 OpenConsole(自有 CLSID)+ 分发 + 注册脚本** 【新增】 | C++/MSBuild 工程 | 高 |
| `fromHandoff` + overlapped 管道 + reader 改造 | ~200 LoC | 中高 |
| tab 拆分 + 生命周期(CoAddRefServerProcess)+ teardown 分派 | ~150 LoC | 中 |
| 入口 `-Embedding` 分流 + 空窗 bootstrap + 注册时序 | ~80 LoC | 中低 |
| MSIX 打包(进下拉框,需同包双扩展) | 独立 | 中 |

## 9. 执行顺序
1. **PoC 阶段**:逐项打通 §7(尤其 1/2/3/4)。任一不通则回到方案。
2. console 委托 + proxy/stub 落地,能让 conhost 成功 QI 并调到 Mostty 的
   `EstablishPtyHandoff`(只 log 即算里程碑)。
3. 接管线:`fromHandoff` + overlapped 管道 + `newTabFromHandoff` + 同步建立。
4. 生命周期(CoAddRefServerProcess)+ teardown 分派。
5. 注册脚本设默认,真机冒烟(cmd / pwsh / 双击 .bat / resize / 多 tab / 关闭客户端)。
6. (可选)MSIX 同包双扩展进下拉框。

## 成功标准
- 设 Mostty 为默认终端后,启动 cmd/pwsh 由 Mostty 接管,输入/输出/resize 正常。
- 连开多个控制台程序 → 同一 Mostty 窗口多 tab;关首个 tab 后进程不退出、仍接管后续。
- 关闭客户端进程 → 对应 tab 正常销毁,无句柄泄漏/崩溃。
- WT **未安装**的机器上同样可用(proxy/stub 自带)。

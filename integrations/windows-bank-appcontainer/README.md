# Windows 无本地账户沙箱候选版

版本：`0.3.0-preview`。用途：带入行内 Windows 10 x64 做兼容验证、供同事集成与安全评审。**目标 VDI 尚未验收，当前不能作为生产上线结论。**

本版采用 Windows 原生 AppContainer。每个工作区拥有独立 Package SID，执行命令时不给网络能力，工作区通过 NTFS ACL 授权。它创建当前用户的 AppContainer profile，**不创建 `srt-sandbox` 或其他本地 SAM 用户**，因此避开此前行内新账户被回收这一安装前提。实际是否被行内其他终端策略限制，仍需在目标电脑验证。

## 支持范围

| 项目 | 当前状态 |
| --- | --- |
| Windows CMD、Windows PowerShell 5.1 | 本机真实执行与隔离对照已通过 |
| 直接启动本地 `.exe` | 使用同一 AppContainer 令牌、Job 和输出管道；本机对照已通过 |
| 工作区读写 | 通过当前工作区 Package SID 授权 |
| 未向 AppContainer 授权的普通外部文件 | 本机读写拒绝已验证 |
| 不同的、互不嵌套的工作区 | 使用不同 Package SID；跨工作区读取拒绝已验证；准备时拒绝父子工作区授权重叠 |
| 网络 | 不提供网络能力；本机回环拒绝已验证；内网 TCP/UDP/域名用例仍需目标 VDI 验证 |
| Git Bash / MSYS2 / Cygwin | **暂不支持**；`--shell git-bash` 明确拒绝，`--exec` 指向其程序也不算兼容承诺；原版运行时访问全局命名对象失败 |
| 网络域名白名单、代理出口 | 本版未实现；不能开启全网作为替代 |
| OpenCode / BocomWork 接入 | 本包是独立 CLI；没有修改或安装客户端插件 |

本版不是“工作区外所有字节一律不可读”的路径过滤器。Windows 系统、部分程序目录，以及明确向 `ALL APPLICATION PACKAGES` 或该 Package SID 授权的对象，仍可能可读。验收脚本专门验证并报告这项边界。敏感文件若位于这些共享路径中，本版不能直接承诺遮蔽。`--deny-read` 与原 SRT CLI 的参数不兼容，不能直接替换旧 EXE。

## 离线验证，从这里开始

1. 将整个包解压到 D 盘，在**普通宿主 PowerShell**中进入包目录。不要从另一个沙箱中启动本包。
2. 无需下载 Node、npm、Hyper-V 或其他运行时；运行使用 Windows 自带的 .NET Framework 4.x。首次设置需要当前用户能够修改工作区 ACL。
3. 先运行自动正负对照。脚本仅在包内 `test\test-runs` 新建合成数据，执行后删除对应 AppContainer profile 和测试目录：

```powershell
& '.\test\verify.ps1'
```

全部 `PASS` 且脚本没有抛错，表示**这些用例在这台机器通过**。脚本包含宿主可读/可连接对照、实际执行标记与退出码判断；初始化错误不会算隔离成功。它也验证外部共享文件可读这一明确边界。

补充回归脚本分别检查直接 EXE、准备后新增链接、工作区重叠、ACL 形状、子项授权回收和中断状态恢复。每份脚本都会创建和回收自己的 AppContainer profile；行内终端软件若弹告警，应记录脚本名、时间和原始告警，避免连续重试掩盖原因。建议按顺序执行，任何失败都保留原始输出供排查：

```powershell
& '.\test\verify-direct-exec.ps1'
& '.\test\verify-post-prepare-link.ps1'
& '.\test\verify-overlap.ps1'
& '.\test\verify-acl-shape.ps1'
& '.\test\verify-residual-acl.ps1'
& '.\test\verify-diagnostics.ps1'
```

`verify-direct-exec.ps1` 默认用本机回环端口做“宿主可连接、沙箱拒绝”对照。需要测行内网络目标时，可另加 `-NetworkHost <宿主可达的地址> -NetworkPort <端口>`；宿主连接失败会使测试失败，不会计作沙箱拒绝通过。公网不可达的行内机器，应选内部可达的测试端点。

## 手工使用

以下命令运行于包目录中的宿主 PowerShell。准备一个专用空目录，不要使用盘符根目录，不要把本工具放在可写工作区内。

```powershell
$exe = Join-Path $PWD 'dist\bank-sandbox.exe'
$work = 'D:\agent-sandbox-demo\workspace'
New-Item -ItemType Directory -Path $work -Force | Out-Null

& $exe plan --workspace $work --json
& $exe prepare --workspace $work
& $exe status --workspace $work --json
& $exe run --workspace $work --shell cmd --command 'whoami'
& $exe run --workspace $work --shell powershell --command "Set-Content -LiteralPath '.\hello.txt' -Value 'sandbox-ok'; Get-Content '.\hello.txt'"
$whoami = Join-Path $env:WINDIR 'System32\whoami.exe'
& $exe run --workspace $work --exec $whoami
```

`whoami` 会显示当前员工用户，**不会显示 `srt-sandbox`**。隔离身份在 AppContainer token 中；Runner 会在子进程仍暂停时核验 `TokenIsAppContainer`、准确的 Package SID 及零能力列表，核验通过才执行命令。只看 `whoami` 无法判断本版是否进入沙箱。

PowerShell 使用临时 `BankWorkspace:\` 驱动器作为当前位置，指向真实工作区。相对路径可正常使用；需要物理路径的程序可用 `$PWD.ProviderPath`。本工具没有给工作区父目录传播读取授权。

卸载该工作区的授权与 profile：

```powershell
& $exe remove --workspace $work
```

工作区业务文件会保留。应在工作区仍存在、任务已结束时执行 `remove`。如果工作区已移动，先移回原路径再执行 `remove`；原目录已删除时，可在原路径重建空目录后回收 profile。移动后的目录可能仍保留原 Package SID ACE，必须由管理员核对其 ACL。`status --json` 会报告原路径缺失，但 `remove` 不会盲目猜测移动后的目录。

## CLI 契约

```text
prepare|remove --workspace <absolute local directory>
plan|status --workspace <absolute local directory> [--json]
run --workspace <directory> --shell cmd|powershell --command <text> [--timeout-ms 30000]
run --workspace <directory> --exec <absolute local .exe> [--arg <value> ...] [--timeout-ms 30000]
```

`plan` 和 `status` 是只读检查，JSON 中的 `readinessKind=static` 表示 `ready` 仅为静态预检结果；它不证明每个子文件或业务程序都可访问。`plan` 要求工作区目录已存在，可查看预计增加的授权而不创建 profile；`status` 可报告原工作区路径已缺失。`prepare`、`remove` 使用当前用户的跨会话 Global 互斥锁，所有操作还持有该工作区的锁；冲突时会明确失败。

`run` 返回子命令退出码；`124` 通常表示超时，`125` 可表示参数、初始化或输出上限错误，`130` 通常表示取消。子命令也可自行返回这些码，需结合 `bank-sandbox:` 错误输出判断来源。输出限制为每个流 1 MiB。超时、取消或主命令退出时，Job 会终止后台后代。没有无沙箱回退。

## 实际修改与边界

- `prepare` 创建当前用户的 AppContainer profile，并在工作区根增加该 Package SID 的继承 `Modify` ACE；不修改本地 SAM 用户、全局防火墙或驱动。profile 通常位于当前用户 `%LOCALAPPDATA%\Packages`，一般在 C 盘，即使测试工作区放在 D 盘。终端安全软件仍可能记录 profile 创建或 EXE 启动行为，需保留原始告警日志供行内评审。
- 准备、状态和执行时检查工作区的硬链接、重解析点，以及目录和文件上的其他 Package SID、`ALL APPLICATION PACKAGES` 或 Capability SID 共享授权；父子工作区、过宽的自身授权及显式自身拒绝规则会被拒绝。工作区外显式共享的文件仍可能可读。准备后新放入链接，也不能启动命令。可信宿主同时改目录或 ACL 的竞态不属于本版已验证保证。
- 已禁用继承的子目录可能无法使用；静态 `ready=true` 不能证明每个业务文件可用，也不能替代实际命令测试。本版没有对 `.git`、`.codex` 等元数据目录实施特殊只读保护。请使用独立工作区，不要嵌套。
- 进程环境采用白名单，`TEMP` 使用该 AppContainer profile。Windows 会重定位部分已知文件夹变量；环境变量中的路径本身不授予文件权限。员工进程环境中的 API key、代理密码及自定义 PATH 不自动传入。额外语言运行时可先放入专用工作区测试；本版没有自动安装依赖。
- 回收前检查工作区及 profile 中的链接，并核对根目录及子项上自身 Package SID 的显式授权；发现不安全对象时 `remove` 会保留 profile 和根 ACL，修复后重试。`prepare` 中途失败可能留下 profile，重复 `prepare` 会尝试补齐授权；`status --json` 可区分缺失 profile、缺失工作区与不安全状态。
- 为在启动时阻止后来添加的链接或共享 ACL，`run` 会遍历工作区和 AppContainer profile 的目录与文件；启动预检耗时随文件数增加。`--timeout-ms` 仅计子进程开始后的执行等待，不包含锁等待、全树预检和 profile 检查。大型工程的时延与稳定性尚未验收。
- `--exec` 接受本地固定盘上的绝对 `.exe` 路径，重复 `--arg` 传入参数。即使 EXE 位于可写工作区，它仍以沙箱令牌运行；本版未评估该程序能否通过宿主上的特权 IPC/COM 服务获得额外能力。
- API 使用当前用户 profile 和 NTFS ACL；若行内策略阻止 profile 创建或 ACL 修改，命令会明确失败。二进制尚未做企业代码签名；批量部署仍需要行内软件发布与安全评审。

## 源码与构建

`src/` 为全部 C# 源码，`build.ps1` 使用系统 .NET Framework x64 编译器生成 `dist/bank-sandbox.exe`；测试是单独的 `test/verify*.ps1`，**没有把测试打进 EXE**。

```powershell
& '.\build.ps1'
```

本模块与现有 SRT 账户模式并列，不改动 `sandbox-runtime` 核心或原 OpenCode 集成。源码许可随包提供。技术依据：[微软 AppContainer 启动文档](https://learn.microsoft.com/en-us/windows/win32/secauthz/implementing-an-appcontainer)、[传统 Win32 应用的 AppContainer](https://learn.microsoft.com/en-us/windows/win32/secauthz/appcontainer-for-legacy-applications-)；Git Bash 的命名对象兼容问题参见 [微软 MXC 仓库的实测记录](https://github.com/microsoft/mxc/issues/1061)。

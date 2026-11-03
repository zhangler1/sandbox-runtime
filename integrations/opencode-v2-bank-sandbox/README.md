# OpenCode V2 AppContainer 适配器

本模块把受控启动器发起的 OpenCode V2 单次 `run` 接到 `windows-bank-appcontainer` 0.3.0 CLI。模型调用 `shell` 时，插件自动调用 `bank-sandbox.exe run`；模型无需在提示词里手动包裹 EXE。仅允许 `shell` 工具，其他工具请求会报错。

当前为集成与安全评审候选版。目标接口是 BocomCode V2 `2.1.4-bc.59bb7.n67`。行内 Windows 10 VDI 兼容性和终端软件告警仍需实测；本文中的命令和预期结果不是“已通过行内验收”的结论。

## 接入方式

`index.js` 是普通 JavaScript ESM 插件，`launch.ps1` 是受控启动器。它们与沙箱 CLI 分别交付。运行依赖 Windows PowerShell 5.1、已有的 OpenCode V2 原生 EXE 和已有模型配置；本模块无需额外安装 npm 依赖。

启动器为这一次运行创建私有配置和可信控制目录，复制源配置中的模型 provider 设置，只加载本插件，并禁用 OpenCode 的项目配置发现。OpenCode 服务与客户端运行在控制目录，实际模型命令由插件转入单独的沙箱工作区。控制目录和工作区互不嵌套，插件、EXE、模型源配置与输出日志也必须位于可写工作区外。

这样安排是为了让 OpenCode 的宿主配置发现、插件热加载和后台 Git 扫描接触可信控制目录。工作区内后来出现的 `bocomcode.json`、`.bocomcode` 或 `.git` 不应成为宿主加载插件或执行配置命令的入口。它不为工作区里的 `.git` 等目录增加特殊只读 ACL。

启动器先准备 AppContainer 并探测沙箱不能写入可信目录，再启动私有本机服务；确认 `/api/plugin` 中本插件为 `active` 后，才向该服务发起模型请求。插件缺失、未激活或初始化失败时，不运行模型请求，也不回退到宿主执行。直接加载 `index.js` 到普通全局配置不属于本模块支持的启动路径。

## 使用

以下均为示例路径，请改为解压后的真实位置。`OpenCodeExe` 应指向原生 `bocomcode2-node.exe`，不要传入 `.cmd` 包装脚本。

```powershell
$adapter = 'D:\bank-sandbox\opencode-v2-bank-sandbox'
$sandbox = Join-Path $adapter 'bank-sandbox.exe'
$opencode = 'D:\opencode2\cli-node-windows-x64\bin\bocomcode2-node.exe'
$work = 'D:\bank-sandbox-work\workspace'
$log = 'D:\bank-sandbox-results\workspace-write.jsonl'
New-Item -ItemType Directory -Path $work -Force | Out-Null

& (Join-Path $adapter 'launch.ps1') `
  -Workspace $work `
  -SandboxExe $sandbox `
  -OpenCodeExe $opencode `
  -Model 'zhipu/glm-5.2' `
  -Message "请只调用 shell 工具执行 Set-Content -LiteralPath '.\hello.txt' -Value 'sandbox-ok'，返回工具原始输出和退出码。" `
  -OutputLog $log
```

| 参数 | 含义 |
| --- | --- |
| `Workspace` | 已存在的独立本地 NTFS 工作区。业务文件只在这里授权读写 |
| `SandboxExe` | `bank-sandbox.exe` 的绝对路径，位于工作区外 |
| `OpenCodeExe` | 本机 OpenCode V2 原生 EXE 的绝对路径，位于工作区外 |
| `Model` | 已配置的模型 ID，例如 `zhipu/glm-5.2` |
| `Message` | 本次发给模型的完整提示词 |
| `OutputLog` | JSONL 原始事件日志的绝对路径，位于工作区外 |

`SourceConfig` 可选，默认读取当前用户 `~/.bocomcode/work/config/bocomcode.json`。源配置需为 JSON 并含 `providers` 对象；已有密钥由源配置提供，不要把密钥写进提示词或命令参数。启动器将临时 provider 配置放入限制当前用户与 SYSTEM 访问的目录，结束时回收该目录。它不会把源配置中的其他插件、MCP 或项目指令复制进本次会话。

`StartupTimeoutSeconds` 默认 60 秒，用于等待私有服务和插件就绪；`ClientTimeoutSeconds` 默认 600 秒，用于本次模型请求。单条沙箱命令还有独立的 CLI 超时。结束时启动器终止本次私有服务和客户端并删除临时控制数据，保留业务工作区与 `OutputLog`。

`ControlParent` 默认是当前用户 TEMP 下的 `bank-opencode-adapter`，通常在 C 盘用户目录；合成文件与业务工作区可放在 D 盘。控制目录必须位于所有 Git 仓库之外。启动器会实际验证沙箱无法新建控制文件、无法以写方式打开插件、执行器及配置等既有文件。`OutputLog` 必须是尚不存在的新文件。

需要只检查插件接入、不调用模型时，可在上述参数后加 `-CheckOnly`。只有出现 `SandboxPluginActive=true` 才说明插件已激活；这不能替代真实工具验收。

AppContainer profile 与工作区授权是持久设置。完成该工作区的全部任务后，在普通宿主 PowerShell 中显式回收：

```powershell
& $sandbox remove --workspace $work
```

## 验证与结果判断

验收时让模型直接调用普通 `shell`，不要在提示词里手动加入 `bank-sandbox.exe`。至少检查工作区内写入成功、普通工作区外文件读取和写入失败，以及模型请求非 `shell` 工具时被拒绝。外部文件应是专门创建的 D 盘合成探针，不应使用真实敏感文件。

还需要验证工作区写入项目配置或插件后不会触发宿主加载、尝试写控制目录失败、沙箱初始化错误没有宿主回退，以及取消/超时后没有残留命令后代。实际通过情况应以验证记录和 JSONL 原始事件为准。

OpenCode 客户端退出码为 0 只表示模型请求完成；模型调用的命令仍可能失败。应查看 JSONL 的 `tool_use` 事件中工具原始输出和退出码，不用模型最终文字代替证据。`whoami` 会显示当前员工用户，不能单凭它判断 AppContainer 是否生效。

## 当前边界

- 支持的命令解释器为 Windows CMD 和 Windows PowerShell 5.1。Git Bash/MSYS2/Cygwin 以及本机已测的 PortableGit 尚不兼容，不能把失败启动计作“Git 沙箱拒绝”性能。
- 模型只能使用 `shell` 完成文件操作。`read`、编辑、搜索、子智能体、MCP 等其他工具均拒绝；需要这些能力时，应通过沙箱内的 PowerShell/CMD 命令完成。
- 本适配器覆盖 `launch.ps1` 发起的单次模型工具路径。普通 OpenCode 启动、其他插件、独立终端/TUI 操作、直接连接其他服务或直接绕过启动器运行 CLI，需要各自的接入设计和验证。
- AppContainer 依赖真实对象 ACL。系统共享对象及显式向 `ALL APPLICATION PACKAGES` 或当前 Package SID 授权的外部文件仍可能可读；本版没有通用的路径 `denyRead` 过滤器。
- 沙箱不提供网络能力和域名放行策略。模型服务的网络连接由宿主 OpenCode 进程使用；沙箱命令的网络权限是另一条执行路径。
- 每条命令启动前扫描工作区及 profile 的链接和授权，成本随文件数量增加。大型工程性能、其他语言运行时和行内终端策略仍需专门验证。
- OpenCode 端取消、宿主崩溃和异常退出的后代清理尚未完成全部验收。当前使用进程树终止；若父进程提前消失，后代可能继续至沙箱 CLI 自身超时。需要更强生命周期保证时应增加外层 Job 管理。

沙箱核心的参数、profile 位置、ACL 清理和共享文件边界，参见兄弟模块 `integrations/windows-bank-appcontainer/README.md`。

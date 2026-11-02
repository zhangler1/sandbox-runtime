# Windows 10 无本地账户沙箱实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 在不创建本地 SAM 账户、不使用 Hyper-V 的 Windows 10 终端上，以独立 AppContainer 运行智能体命令，并提供可离线交付的 CLI 与真实正负对照验证。

**Architecture:** CLI 作为普通用户运行，为每个规范化工作区生成稳定的 AppContainer profile，给工作区授予该 Package SID 的文件访问权限。每次命令通过 `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES` 创建低权限子进程，不提供网络能力。CMD 与 Windows PowerShell 5.1 是第一阶段支持的 shell；Git Bash 因 MSYS 访问全局对象命名空间失败，明确拒绝。Runner 与 OpenCode 插件保持分离。

**Tech Stack:** C#/.NET Framework 4.x、Win32 `CreateAppContainerProfile`、`CreateProcessW`、NTFS ACL、Windows Job Object、PowerShell 5.1 验证脚本。

## Global Constraints

- 所有测试数据只在 `D:\windows沙箱` 下新建的合成目录中；外部测试目录不能继承工作区 Package SID 的授权。
- 在普通宿主令牌下验证。Codex 工具终端自身是 AppContainer，叠加运行的结果不能代替普通宿主结果。
- 正向例必须证明命令真实执行、工作区读写成功；负向例必须以宿主实际文件内容和网络对照判定。
- 启动前核对实际子进程 `TokenIsAppContainer` 和 Package SID；任何失败都终止进程并返回错误，不执行无沙箱回退。
- 目标系统为 Windows 10 x64；不依赖 Node、联网下载、管理员新建账户或内核驱动。
- 未经验证的外部文件类型、第三方程序及行内 VDI 兼容性必须在交付说明中标为待验收，不能概括为已证明安全。

---

### Task 1: 定义可执行验收

**Files:**
- Create: `integrations/windows-bank-appcontainer/test/verify.ps1`

**Interfaces:**
- Consumes: CLI `prepare|status|run|remove --workspace <absolute local path>`；`run` 还接收 `--shell cmd|powershell --command <text> --timeout-ms <1..300000>`。
- Produces: PowerShell 脚本以退出码 0 表示所有有效对照通过，否则抛出明确失败项。

- [x] 写合成工作区与兄弟外部目录的正负对照测试：宿主能读取外部密文，CMD/PowerShell 能在沙箱写工作区，不能读真实密文或写外部文件，沙箱不能连接宿主可连接的回环监听端口。
- [x] 运行脚本，确认因 CLI 尚不存在而失败。
- [x] 增加嵌套子进程测试：从 PowerShell 启动 CMD 后仍不能读取外部密文。
- [x] 增加 Git Bash 请求必须明确失败的测试，确保不静默切换为宿主执行。

### Task 2: 实现准备与身份核验

**Files:**
- Create: `integrations/windows-bank-appcontainer/src/Native.cs`
- Create: `integrations/windows-bank-appcontainer/src/Policy.cs`
- Create: `integrations/windows-bank-appcontainer/src/Program.cs`
- Create: `integrations/windows-bank-appcontainer/build.ps1`

**Interfaces:**
- `Policy.NormalizeWorkspace(string)` 返回现存、非重解析点的本地绝对目录。
- `Policy.Moniker(string)` 返回由规范化路径 SHA-256 导出的稳定 profile 名称。
- `Program.Main(string[])` 实现 `prepare/status/remove`，错误返回非零。

- [x] `prepare` 调用 `CreateAppContainerProfile`；已存在时仅派生并核对 SID，工作区 ACL 只增加该 Package SID 的 `Modify` 继承 ACE。
- [x] `status` 检查 profile 和工作区 grant，输出可机器解析的 readiness 结果；未就绪返回非零。
- [x] `remove` 只移除本工具加入的 ACE 并删除对应 profile；在任何步骤失败时明确报错。
- [x] 编译后执行 Task 1 的准备和清理子集，核对 `Get-LocalUser` 前后没有新账户。

### Task 3: 实现命令执行

**Files:**
- Modify: `integrations/windows-bank-appcontainer/src/Native.cs`
- Modify: `integrations/windows-bank-appcontainer/src/Program.cs`
- Test: `integrations/windows-bank-appcontainer/test/verify.ps1`

**Interfaces:**
- `run` 只接受 CMD 或 Windows PowerShell 5.1；传入工作区和命令，返回子进程退出码。

- [x] 使用 `CreateProcessW` 的安全能力启动属性创建暂停的子进程；打开子进程 token 验证 AppContainer 标志和预期 Package SID。
- [x] 将子进程加入 `KILL_ON_JOB_CLOSE` Job 后恢复执行；超时关闭 Job 并返回非零。
- [x] CMD 使用 `/d /s /c`，PowerShell 使用 UTF-16LE `-EncodedCommand`；拒绝 Git Bash、UNC、驱动器根目录和工作区重解析点。
- [x] 运行 Task 1 全部测试，确认 CMD/PowerShell 正向和外部读写、网络负向；修复命令输出是否能被调用方捕获。

### Task 4: 离线交付与安全边界

**Files:**
- Create: `integrations/windows-bank-appcontainer/README.md`
- Create: `integrations/windows-bank-appcontainer/验证记录.md`

- [x] 记录无需新 SAM 账户、Hyper-V、Node 和联网的安装步骤，列出工作区 ACL/profile 创建与卸载影响。
- [x] 明确 AppContainer 仍可能读取被 `ALL APPLICATION PACKAGES` 等 SID 授权的外部路径，不能宣称绝对全盘拒读；记录与终端安全软件的行内兼容性仍需 VDI 实测。
- [x] 记录 Git Bash 的 MSYS 命名对象错误和显式不支持状态，以及行内验证所需的宿主正向对照。
- [x] 编译源码、运行真实验收、核对无测试残留及 Git 状态，再形成可审阅的代码差异。

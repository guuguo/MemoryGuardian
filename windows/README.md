# 内存守卫 Windows 预览版

Windows 原生 C# / WPF 实现。首版目标 Windows 11 x64，当前未完成 Windows 实机验收。下载/构建的 ZIP 为预览包，未签名；不绕过系统安全提示。无需管理员权限、Node、MCP 服务或单独安装 .NET 运行时（self-contained 发布）。ARM64 可构建，尚未验收。

## 使用

解压后运行 `MemoryGuardian.exe`。默认每 5 秒采样，可手动刷新。输入应用名、服务名、路径或 PID 搜索，选择应用查看五分钟内真实趋势；“查看进程”窗口随主窗口持续刷新。历史只保存在内存，重新启动后从头采样。

ZIP 同时包含 `自检.ps1`。在解压目录的 PowerShell 中执行 `./自检.ps1`，会生成 `windows-self-test.json`；也可以直接运行 `./MemoryGuardian.exe --self-test ./windows-self-test.json`，无需更改系统执行策略。

最小化会隐藏到系统托盘，双击托盘恢复；托盘菜单“退出”或主窗口关闭退出整个应用，不会留后台服务。

“正常退出…”只向选定可见应用的主窗口发送关闭请求，可能出现应用自己的保存提示。不会强杀、不批量结束同名服务、不清缓存或更改系统设置。自身、无窗口及受保护进程不提供此操作。

## 数据口径

- 物理已用 = 物理总量 − 可用量；可用量包含可回收待机页。
- 系统提交量与提交上限单列。提交量不是实际驻留内存，也不是分页文件已用；不能将它叠加在物理内存上。
- 分页文件已用/已分配通过系统分页文件枚举读取；失败显示不可用，不补 0。
- 排行优先为私有工作集；整组有该指标不可用时切换工作集并标注含共享页。未知进程显示可读部分或破折号。各行不能相加当成物理内存分区。
- 余量提醒：物理使用率或提交率达到 80% 提醒、90% 余量偏低；这是本应用规则，不是 Windows 官方压力分级。
- Node 服务入口通过 WMI 按需批量读取；无权限时保留进程真实可读指标并标注。相对脚本路径没有经验证的 CWD 时不猜测目录。完整命令行不显示、保存或写入自检报告。

## 构建和验证

安装 .NET 10 SDK，在 Windows PowerShell 执行：

```powershell
./scripts/package-windows.ps1
./scripts/verify-windows.ps1
```

输出 `dist/MemoryGuardian-win-x64-preview.zip`，包含运行时。Mac/Linux 可用 `bash scripts/package-windows.sh` 交叉构建；可通过 `MEMORY_GUARDIAN_DOTNET` 指定 SDK 路径。

纯逻辑测试（可在 Mac 运行）：

```sh
cd windows
dotnet run --project MemoryGuardian.Core.Tests -c Release
```

原生自检会验证 Win32 结构布局、真实系统指标和进程读取、PID 不重复、参数解析，并记录首次采样耗时及自身内存。仍需人工核对：同口径任务管理器数据、搜索选择、实时明细、趋势、托盘恢复/退出、请求自建测试应用正常关闭、1100×740 与高 DPI、连续 10 分钟的 CPU/内存开销和受限进程状态。自检通过不等于这些检查已通过。

需求与验收：`docs/harness/specs/20261028-Windows原生版/`。macOS 源码与打包脚本独立保留。

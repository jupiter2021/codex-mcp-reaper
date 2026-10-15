# 贡献指南

欢迎 Issue 与 Pull Request。

## 兼容性约定（重要）

脚本需同时兼容 **Windows PowerShell 5.1** 与 **PowerShell 7**：

- `.ps1` 文件必须保存为 **UTF-8 with BOM**，否则 5.1 会把中文读成乱码、解析失败。
- 不要在 `param()` 默认值里用 `$PSScriptRoot`（5.1 下为空）；在脚本体中设置路径默认值。
- 避免 `@($list).Count -eq 0`（PS7 对 `List[object]` 会抛 ArgumentException）；改用 `$list.Count`。

## 验证

- 改动后先 dry-run（不加 `-Apply`）确认将回收的目标，再实跑。
- 用 `powershell.exe`（5.1）和 `pwsh`（7）各跑一次，确保两者都通过。

## 不要提交

- `*.log` / `*-state.json`：可能含本机进程 PID 与路径（已在 `.gitignore`）。

## 上游

本工具是对 codex 进程泄漏的**外部缓解**；根因跟踪见 openai/codex 的相关 issue。

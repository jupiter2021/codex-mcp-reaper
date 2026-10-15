# Changelog

本项目所有重要变更记录于此。格式参考 [Keep a Changelog](https://keepachangelog.com/)。

## [0.1.0] - 2026-10-15

首个版本。

### 新增
- 回收 codex（ChatGPT 桌面应用）app-server 泄漏的、**持续空闲**的 MCP server 进程。
- 跨运行状态追踪（比对 CPU/IO）计算持续空闲时长；回收前二次采样确认空闲。
- `install.ps1` / `uninstall.ps1`：一键注册/移除纯后台计划任务（每 20 分钟 + 登录后 5 分钟，无窗口）。
- 默认 dry-run；`-Apply` 实际回收；可配 `-IdleMinutes` / `-MinAgeMinutes` / `-KeepLatest`。
- 兼容 Windows PowerShell 5.1 与 PowerShell 7（UTF-8 BOM、脚本体设置路径默认值）。

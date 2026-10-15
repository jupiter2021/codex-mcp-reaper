# codex-mcp-reaper

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)

[English](README.md) · **简体中文**

回收 **codex(ChatGPT 桌面应用)** app-server 泄漏的、**持续空闲**的 MCP server 进程。纯进程层运作、零外部依赖、纯后台无弹窗。Windows + PowerShell 5.1/7。

> *Reclaim the idle, leaked stdio MCP server processes (node.exe, node_repl.exe, powershell.exe, python.exe, uv/uvx …) that the ChatGPT desktop app / OpenAI Codex app-server piles up on Windows — automatically, in the background.*

---

## 背景与需求(你是否遇到这些问题)

如果你在用 **ChatGPT 桌面应用 / OpenAI Codex**,并遇到以下任一情况,这个工具就是为你准备的:

- 任务管理器(Task Manager)里出现**几十上百个 `node.exe` / `node_repl.exe` / `powershell.exe` / `python.exe`** 进程。
- ChatGPT 桌面应用(Codex)**越用越占内存**,动辄十几 GB,**只有重启才释放**。
- **关闭或切换对话后**,旧对话的 MCP server 进程**不退出**、不回收。
- 一个长任务里,**每个回合(turn)都新起一整套**相同的 MCP server。
- 单个 `codex.exe app-server` 下的进程树膨胀到**几百个进程**。

**根因**:codex 为每个对话(thread)启动一整套 stdio MCP server,关闭/切换对话后旧的一套不回收,在单个 app-server 下不断累积。本工具在后台定时识别并回收其中**持续空闲**的 server,**不碰正在用的对话**,从而把内存压回正常水平——无需你手动重启 ChatGPT。

> **关键词 / keywords**: ChatGPT desktop high memory usage, OpenAI Codex app-server memory leak, `node_repl.exe` many processes, too many `node.exe` processes, MCP server processes not cleaned up / not reaped, idle stdio MCP processes accumulate, codex 内存泄漏, codex 进程过多, ChatGPT 桌面版占用内存, Windows, PowerShell, Task Scheduler.

---

## 快速开始

```powershell
# 1) 解压到任意目录, 先干跑一次(只打印将回收什么, 不动手)
powershell -ExecutionPolicy Bypass -File .\mcp-reaper.ps1

# 2) 确认无误后, 安装后台计划任务(每20分钟 + 登录后5分钟自动回收)
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 卸载
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

> 只处理当前用户自己的进程,无需管理员权限。任务纯后台运行、无任何窗口。

---

## 1. 背景:这是 codex 的已知 bug

ChatGPT 桌面应用内嵌的 codex 后端(`codex.exe ... app-server`)会**为每个对话(thread)启动一整套 stdio MCP server**;对话关闭或切换后,旧的那一套**不回收**,在单个 app-server 下累积成几百个进程、多 GB 内存。

这是官方已确认、大量用户报告的开放问题:

| Issue | 现象 |
|---|---|
| [openai/codex#53285](https://github.com/openai/codex/issues/53285) | `[Windows 26.1007]` 每线程一套 stdio MCP;单 app-server 下 13 套 / 353 进程 / ~9.6 GiB |
| [#35485](https://github.com/openai/codex/issues/35485) | Windows Desktop:`node_repl` 每线程泄漏,**直到 app-server 退出才回收** |
| [#30408](https://github.com/openai/codex/issues/30408) | MCP server 进程按线程泄漏,从不清理(9+ GB) |
| [#53664](https://github.com/openai/codex/issues/53664) | `node_repl` 子 MCP 每次调用泄漏,耗尽内存 |

### codex 自身的回收机制(为什么不够)

- **Job Object(退出兜底)**:杀 app-server / ChatGPT 主进程时,Windows Job Object 连带终止整棵树。但**只在整体退出时生效**。
- **延迟空闲回收**:社区实测存在约 30 分钟的弱回收,但"创建速度超过回收速度",持续使用仍堆积。
- **无**可配置的 idle 超时 / 实例复用 / 数量上限。

---

## 2. 本脚本做什么

每次运行:

1. 定位 `ChatGPT.exe` → `codex.exe app-server` 进程树。
2. 枚举 app-server 直接子进程里的 MCP server 根(排除 `cmd`/`conhost` 外壳),含整棵子树。
3. 用**状态文件跨运行比对 CPU/IO**,算出每个 server 的**持续空闲时长**:
   - 两次运行间 CPU 增量 > 50ms 或 IO 增量 > 256KB → "有活动",刷新最后活动时刻;否则空闲时长持续累积。
   - 首次见到某 server 时,以其**进程启动时刻**作为空闲起点。
4. 候选 = 持续空闲 ≥ `IdleMinutes` **且** 存活 ≥ `MinAgeMinutes`。
5. **空闲双采样确认**:等待 `IdleSampleSec` 再测一次,两次间仍无活动才回收(排除刚好在用的)。
6. `-Apply` 时按 PID 停止候选 server 的整棵子树;否则仅 dry-run 打印。

### 安全机制

- **保护当前对话**:`IdleMinutes`(默认 30)只停"持续空闲很久"的;当前对话很少连续 30 分钟不调工具。
- **空闲双采样**:即便判为候选,若此刻 45 秒内有任何活动也会跳过。
- **只碰 codex**:仅处理 `ChatGPT.exe → app-server` 树下、由 MCP 配置启动的进程。
- **可选数量保护**:`KeepLatest > 0` 时每种 server 最新 N 个永不回收(默认 0 = 纯按空闲)。

### 局限 / 权衡(如实说明)

- codex 运行时独占锁死其 SQLite,**拿不到对话真实的"最后活动时间"**,故无法 100% 保证"最近使用的对话绝不被碰"。本脚本用进程层 CPU/IO 空闲作为代理信号。
- **首次运行**以"进程启动时刻"近似空闲起点,可能把"存活久但刚才活跃过"的对话误判空闲;靠空闲双采样兜底。第二次起基于真实 CPU 变化追踪,更准。
- 被回收的 server,其对话再调用该工具会报 **"Transport closed"**;**重开该对话即可恢复**(codex 无法重启已停止的 server)。后果温和。

---

## 3. 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Apply` | 关(dry-run) | 实际停止;不加则只打印将回收什么 |
| `-IdleMinutes` | 30 | 持续空闲多少分钟才回收(调大 = 更保守) |
| `-KeepLatest` | 0 | 每种 server 保留最新 N 个;0 = 纯按空闲 |
| `-MinAgeMinutes` | 15 | 进程至少存活分钟数(挡掉刚启动的) |
| `-IdleSampleSec` | 45 | 两次采样间隔,确认"此刻也空闲" |
| `-NoIdleCheck` | 关 | 跳过空闲双采样(更激进,不推荐无人值守) |
| `-LogPath` | `.\mcp-reaper.log` | 日志路径 |
| `-StatePath` | `.\mcp-reaper-state.json` | 空闲追踪状态文件 |
| `-Quiet` | 关 | 不输出到控制台,只写日志(计划任务用) |

---

## 4. 运维命令

```powershell
# 查看最近日志(脚本所在目录)
Get-Content .\mcp-reaper.log -Tail 40

# 手动干跑 / 实跑
powershell -ExecutionPolicy Bypass -File .\mcp-reaper.ps1
powershell -ExecutionPolicy Bypass -File .\mcp-reaper.ps1 -Apply

# 计划任务操作
Start-ScheduledTask     -TaskName MCP-Reaper   # 立即触发一次
Disable-ScheduledTask   -TaskName MCP-Reaper   # 暂停
Enable-ScheduledTask    -TaskName MCP-Reaper   # 恢复
Get-ScheduledTaskInfo   -TaskName MCP-Reaper   # 状态与下次运行
```

### 调整激进度
- **更保守**:安装时 `install.ps1 -IdleMinutes 45`,或脚本加 `-KeepLatest 2~4` 保护多个活跃对话。
- **更激进**:`-IdleMinutes 15`。

---

## 5. 其他替代方案(备查)

- **重启 ChatGPT**:一次性清空(触发 Job Object 全清),代价是打断所有对话。
- **禁用 node_repl**:codex `config.toml` 里 `[mcp_servers.node_repl]` 设 `enabled=false`,去掉最大泄漏源,但牺牲浏览器/computer-use 功能。
- **关注上游修复**:[openai/codex#30408](https://github.com/openai/codex/issues/30408) 等。

---

## 贡献

欢迎 Issue 与 PR,详见 [CONTRIBUTING.md](CONTRIBUTING.md)。仓库:`github.com/jupiter2021/codex-mcp-reaper`。

---

*本工具仅在本机进程层操作,不读取 codex 私有数据库、不联网、不外发任何数据。遵循 [MIT](LICENSE) 许可。作者 Korben Xue。*

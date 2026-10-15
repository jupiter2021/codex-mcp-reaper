<#
.SYNOPSIS
  回收 codex (ChatGPT 桌面应用) app-server 泄漏的空闲 MCP server 进程。

.DESCRIPTION
  codex 为每个对话启动一整套 stdio MCP server, 关闭/切换对话后旧的一套不回收
  (openai/codex#30408 / #35485), 在单个 app-server 下累积成几百进程、多 GB 内存。
  本脚本只在进程层操作, 不读取 codex 被独占锁定的 SQLite, 因此采用保守策略:

    可安全回收的目标:
      1) orphan   : 父 app-server 已退出、但自身残留的 MCP 进程
      2) 旧副本    : 同一 MCP server 存在更新的实例 (codex 只用最新的那个);
                     每种 server 按启动时间保留最新 KeepLatest 个, 其余为候选
    额外保护 (默认开启):
      - 候选必须存活 >= MinAgeMinutes, 且在 IdleSampleSec 的两次采样间
        CPU 与 IO 均无变化 (确认空闲) 才会被停止
      - 永不触碰: 运行本脚本的进程自身树、非 app-server 树的进程、每种 server
        最新的 KeepLatest 个实例

  局限 (如实说明): 由于拿不到对话的 lastActivity (SQLite 被 codex 独占锁),
  无法 100% 保证"最近使用的对话"绝不被碰。若某个你仍在用、
  但长时间空闲的老对话其 server 被停, 该对话再调用该工具会报 "Transport closed",
  重开对话即可恢复。调大 -KeepLatest 可降低此风险。

.PARAMETER Apply
  实际停止进程。缺省为 dry-run (只列出将停的, 不动手)。

.PARAMETER KeepLatest
  每种 MCP server 按启动时间保留最新的几个实例。默认 2 (当前对话 + 1 缓冲)。

.PARAMETER MinAgeMinutes
  候选实例至少已存活的分钟数, 低于此值的不动 (避免停到刚起的)。默认 15。

.PARAMETER IdleSampleSec
  两次 CPU/IO 采样的间隔秒数, 用于确认候选空闲。默认 45。

.PARAMETER NoIdleCheck
  跳过空闲双采样 (更快但更激进, 不推荐无人值守时使用)。

.PARAMETER LogPath
  日志文件路径。默认脚本同目录的 mcp-reaper.log。

.EXAMPLE
  .\mcp-reaper.ps1
  dry-run, 打印将回收哪些 server, 不动手。

.EXAMPLE
  .\mcp-reaper.ps1 -Apply -KeepLatest 2 -MinAgeMinutes 20
  实际回收: 每种 server 保留最新 2 个, 其余存活超 20 分钟且空闲的停掉。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [int]$IdleMinutes = 30,
    [int]$KeepLatest = 0,
    [int]$MinAgeMinutes = 15,
    [int]$IdleSampleSec = 45,
    [switch]$NoIdleCheck,
    [string]$LogPath,
    [string]$StatePath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot 在 PS5.1 的 param 默认值里可能为空, 故在脚本体设置路径默认值
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $LogPath) { $LogPath = Join-Path $scriptDir 'mcp-reaper.log' }
if (-not $StatePath) { $StatePath = Join-Path $scriptDir 'mcp-reaper-state.json' }

# 一次系统快照: 返回 pid/ppid/name/cmd/start/cpuMs/ioBytes/memBytes 的字典 (key=pid)
function Get-ProcSnapshot {
    $map = @{}
    foreach ($p in Get-CimInstance Win32_Process) {
        $map[[int]$p.ProcessId] = [pscustomobject]@{
            Pid      = [int]$p.ProcessId
            Ppid     = [int]$p.ParentProcessId
            Name     = $p.Name
            Cmd      = [string]$p.CommandLine
            Start    = $p.CreationDate
            CpuMs    = ([double]$p.UserModeTime + [double]$p.KernelModeTime) / 10000.0
            IoBytes  = [double]$p.ReadTransferCount + [double]$p.WriteTransferCount
            MemBytes = [double]$p.WorkingSetSize
        }
    }
    return $map
}

# 返回 rootPid 的所有后代 (含自身) 的 pid 列表
function Get-Descendants {
    param([hashtable]$Snap, [int]$RootPid)
    $children = @{}
    foreach ($p in $Snap.Values) {
        if (-not $children.ContainsKey($p.Ppid)) { $children[$p.Ppid] = New-Object System.Collections.Generic.List[int] }
        $children[$p.Ppid].Add($p.Pid)
    }
    $result = New-Object System.Collections.Generic.List[int]
    $stack = New-Object System.Collections.Generic.Stack[int]
    $stack.Push($RootPid)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if (-not $Snap.ContainsKey($cur)) { continue }
        $result.Add($cur)
        if ($children.ContainsKey($cur)) {
            foreach ($c in $children[$cur]) {
                # 只收 start 不早于父的子进程, 规避 PID 重用
                if ($Snap[$c].Start -ge $Snap[$cur].Start -and $c -ne $cur) { $stack.Push($c) }
            }
        }
    }
    return $result
}

# 把一个 MCP server 根进程 (及其子树命令行) 归一成 server 名。
# 仅用于日志的友好显示, 可按需增删规则; 未匹配的 server 回退为进程名, 不影响回收逻辑。
function Get-ServerName {
    param([string]$Text, [string]$RootName)
    switch -Regex ($Text) {
        'node_repl'                               { return 'node_repl' }
        '@playwright/mcp|playwright'              { return 'playwright' }
        'server\.mjs|cua-repl|codex-computer-use' { return 'cua' }
        # 可按需为自己的 MCP server 添加显示名, 例如:
        #   '@microsoft/workiq|[\\/]workiq'  { return 'workiq' }
        #   'my-mcp-tool'                    { return 'MyTool' }
        default { return $RootName }
    }
}

# 读 session_index.jsonl, 返回 (createdMs, title) 列表, 供日志展示对话标题 (best-effort)
function Get-ThreadIndex {
    $file = Join-Path $env:USERPROFILE '.codex\session_index.jsonl'
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $file)) { return $list }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($file)) {
            if (-not $line) { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if (-not $o.id) { continue }
            $hex = ($o.id -replace '-', '')
            if ($hex.Length -lt 12) { continue }
            # UUIDv7 前 48 bit = 创建时刻的 Unix 毫秒
            try { $ms = [Convert]::ToInt64($hex.Substring(0, 12), 16) } catch { continue }
            $list.Add([pscustomobject]@{ CreatedMs = $ms; Title = [string]$o.thread_name })
        }
    } catch { }
    return $list
}

function To-UnixMs { param([datetime]$dt) [long]([DateTimeOffset]$dt.ToUniversalTime()).ToUnixTimeMilliseconds() }

function Write-Log {
    param([string]$Msg)
    $line = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $Msg"
    if (-not $Quiet) { Write-Output $line }
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch { }
}

# 状态文件: 跨运行记录每个 server 的 CPU/IO 与最后活动时刻, 据此计算持续空闲时长
function Load-State {
    param([string]$Path)
    $h = @{}
    if (-not (Test-Path $Path)) { return $h }
    try {
        $obj = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    } catch { }
    return $h
}
function Save-State {
    param([string]$Path, [hashtable]$State)
    try { ($State | ConvertTo-Json -Depth 4) | Set-Content -Path $Path -Encoding UTF8 } catch { }
}

# ---------------- 主流程 ----------------
$mode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Log "===== mcp-reaper 启动 ($mode) IdleMinutes=${IdleMinutes}m KeepLatest=$KeepLatest MinAge=${MinAgeMinutes}m IdleSample=${IdleSampleSec}s ====="

$snap = Get-ProcSnapshot

# 保护: 运行本脚本的进程及其父链 (避免误伤自身或启动它的 shell)
$selfProtected = @{}
try {
    $cur = $PID
    for ($i = 0; $i -lt 10 -and $snap.ContainsKey($cur); $i++) { $selfProtected[$cur] = $true; $cur = $snap[$cur].Ppid }
} catch { }

# 找 ChatGPT 主进程下的 codex app-server
$appServers = $snap.Values | Where-Object { $_.Name -eq 'codex.exe' -and $_.Cmd -match 'app-server' -and $snap.ContainsKey($_.Ppid) -and $snap[$_.Ppid].Name -eq 'ChatGPT.exe' }
if (-not $appServers) {
    Write-Log "未找到 ChatGPT 下的 codex app-server, 无需处理。"
    return
}

$threadIdx = Get-ThreadIndex

$candidates = New-Object System.Collections.Generic.List[object]
$allServers = New-Object System.Collections.Generic.List[object]

foreach ($app in $appServers) {
    Write-Log ("app-server PID $($app.Pid) (启动 $($app.Start.ToString('HH:mm:ss'))) 下的 MCP server:")
    # MCP server 根 = app-server 的直接子进程, 排除外壳 cmd/conhost
    $roots = $snap.Values | Where-Object { $_.Ppid -eq $app.Pid -and $_.Name -notin @('cmd.exe', 'conhost.exe') }
    foreach ($r in $roots) {
        $desc = Get-Descendants -Snap $snap -RootPid $r.Pid
        $combined = ($desc | ForEach-Object { $snap[$_].Cmd }) -join ' '
        $name = Get-ServerName -Text $combined -RootName $r.Name
        $mem = ($desc | ForEach-Object { $snap[$_].MemBytes } | Measure-Object -Sum).Sum
        $cpu = ($desc | ForEach-Object { $snap[$_].CpuMs } | Measure-Object -Sum).Sum
        $io  = ($desc | ForEach-Object { $snap[$_].IoBytes } | Measure-Object -Sum).Sum
        $ageMin = [math]::Round(([DateTime]::Now - $r.Start).TotalMinutes, 1)
        # 对话标题 (best-effort): 匹配启动时刻最接近的 thread
        $title = ''
        if ($threadIdx.Count -gt 0) {
            $startMs = To-UnixMs $r.Start
            $hit = $threadIdx | Where-Object { [math]::Abs($_.CreatedMs - $startMs) -le 15000 } | Sort-Object { [math]::Abs($_.CreatedMs - $startMs) } | Select-Object -First 1
            if ($hit) { $title = $hit.Title }
        }
        $allServers.Add([pscustomobject]@{
            App = $app.Pid; Name = $name; Pid = $r.Pid; Start = $r.Start; AgeMin = $ageMin
            Key = "$($r.Pid):$($r.Start.Ticks)"; StartMs = (To-UnixMs $r.Start)
            Procs = $desc.Count; MemMB = [math]::Round($mem / 1MB, 1); CpuMs = $cpu; IoBytes = $io
            Descendants = $desc; Title = $title
        })
    }
}

# 用状态文件追踪每个 server 的持续空闲时长 (跨运行比对 CPU/IO), 只回收持续空闲达阈值的
$nowMs = To-UnixMs ([DateTime]::Now)
$state = Load-State -Path $StatePath
$newState = @{}
$cpuDelta = 50       # ms: 两次运行间 CPU 增量超过此值视为"有活动", 刷新最后活动时刻
$ioDelta = 262144    # bytes (256KB)

# 可选数量保护: KeepLatest>0 时每种 server 最新 N 个永不回收 (默认 0 = 纯按空闲)
$protectedByKeep = @{}
if ($KeepLatest -gt 0) {
    foreach ($grp in ($allServers | Group-Object Name)) {
        foreach ($k in ($grp.Group | Sort-Object Start -Descending | Select-Object -First $KeepLatest)) { $protectedByKeep[$k.Key] = $true }
    }
}

foreach ($s in $allServers) {
    $prev = $state[$s.Key]
    if ($prev) {
        $dCpu = [math]::Abs([double]$s.CpuMs - [double]$prev.cpuMs)
        $dIo = [math]::Abs([double]$s.IoBytes - [double]$prev.ioBytes)
        if ($dCpu -gt $cpuDelta -or $dIo -gt $ioDelta) { $lastActive = $nowMs } else { $lastActive = [double]$prev.lastActiveMs }
    }
    else {
        # 首次纳入追踪: 以进程启动时刻为空闲起点, 使长期空闲的旧副本当次即可识别
        $lastActive = [double]$s.StartMs
    }
    $idleMin = [math]::Round(($nowMs - $lastActive) / 60000.0, 1)
    $s | Add-Member -NotePropertyName IdleMin -NotePropertyValue $idleMin -Force
    $newState[$s.Key] = @{ lastActiveMs = $lastActive; cpuMs = $s.CpuMs; ioBytes = $s.IoBytes }

    if ($s.AgeMin -lt $MinAgeMinutes) { continue }
    if ($selfProtected.ContainsKey($s.Pid)) { continue }
    if ($protectedByKeep.ContainsKey($s.Key)) { continue }
    if ($idleMin -ge $IdleMinutes) { $candidates.Add($s) }
}
Save-State -Path $StatePath -State $newState
Write-Log ("server 实例 {0} 个; 持续空闲 >= {1} 分钟的候选 {2} 个" -f $allServers.Count, $IdleMinutes, $candidates.Count)

if ($candidates.Count -eq 0) {
    Write-Log "无持续空闲达阈值的可回收项。"
    Write-Log "===== 完成 ($mode) ====="
    return
}

# 空闲双采样确认 (除非 -NoIdleCheck)
$toStop = $candidates
if (-not $NoIdleCheck) {
    Write-Log "等待 ${IdleSampleSec}s 做第二次采样, 确认候选空闲..."
    Start-Sleep -Seconds $IdleSampleSec
    $snap2 = Get-ProcSnapshot
    $idle = New-Object System.Collections.Generic.List[object]
    foreach ($c in $candidates) {
        $cpu2 = 0.0; $io2 = 0.0; $alive = $false
        foreach ($d in $c.Descendants) {
            if ($snap2.ContainsKey($d) -and $snap2[$d].Start -eq $snap[$d].Start) {
                $alive = $true
                $cpu2 += $snap2[$d].CpuMs; $io2 += $snap2[$d].IoBytes
            }
        }
        if (-not $alive) { continue }
        $dCpu = $cpu2 - $c.CpuMs
        $dIo  = $io2 - $c.IoBytes
        if ($dCpu -lt 50 -and $dIo -lt 102400) { $idle.Add($c) }
        else { Write-Log ("  跳过 (两次采样间有活动): {0} pid={1} dCPU={2}ms dIO={3}KB" -f $c.Name, $c.Pid, [math]::Round($dCpu), [math]::Round($dIo/1KB)) }
    }
    $toStop = $idle
}

if ($toStop.Count -eq 0) {
    Write-Log "候选均在采样间仍有活动, 无确认空闲的可回收项。"
    Write-Log "===== 完成 ($mode) ====="
    return
}
$sumMem = [math]::Round([double](($toStop | Measure-Object MemMB -Sum).Sum), 1)
$sumProc = [int]([double](($toStop | Measure-Object Procs -Sum).Sum))
Write-Log ("将回收 {0} 个空闲旧 server, {1} 进程, {2} MB:" -f $toStop.Count, $sumProc, $sumMem)
foreach ($s in $toStop) {
    $t = if ($s.Title) { " [`"$($s.Title)`"]" } else { '' }
    Write-Log ("  - {0,-16} pid={1} 子树{2}进程 {3}MB 持续空闲{4}分钟{5}" -f $s.Name, $s.Pid, $s.Procs, $s.MemMB, $s.IdleMin, $t)
}

if ($Apply) {
    $stopPids = $toStop | ForEach-Object { $_.Descendants } | Select-Object -Unique
    foreach ($sp in $stopPids) {
        try { Stop-Process -Id $sp -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 2
    $still = $stopPids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }
    Write-Log ("已停止。残留 {0} 进程。" -f ($still | Measure-Object).Count)
} else {
    Write-Log "(dry-run: 未实际停止。加 -Apply 执行回收。)"
}
Write-Log "===== 完成 ($mode) ====="

<#
.SYNOPSIS
  安装 mcp-reaper 计划任务: 纯后台、无弹窗, 每 N 分钟 + 登录后 5 分钟自动回收空闲 MCP server。
.DESCRIPTION
  在当前用户下注册计划任务 (优先 S4U 后台; 无权限则回退 Interactive+Hidden)。
  任务持久化, 重启登录后自动恢复。只处理当前用户自己的进程, 无需管理员。
.PARAMETER IdleMinutes
  持续空闲多少分钟才回收。默认 30 (调大 = 更保守)。
.PARAMETER MinAgeMinutes
  进程至少存活分钟数。默认 20。
.PARAMETER IntervalMinutes
  计划任务运行间隔。默认 20。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [int]$IdleMinutes = 30,
    [int]$MinAgeMinutes = 20,
    [int]$IntervalMinutes = 20,
    [string]$TaskName = 'MCP-Reaper'
)
$ErrorActionPreference = 'Stop'

$script = Join-Path $PSScriptRoot 'mcp-reaper.ps1'
if (-not (Test-Path $script)) { throw "找不到 mcp-reaper.ps1, 请与 install.ps1 放在同一目录后再运行。" }

$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$arg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Apply -IdleMinutes {1} -MinAgeMinutes {2} -KeepLatest 0 -Quiet' -f $script, $IdleMinutes, $MinAgeMinutes
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arg

# 时间触发 (每 N 分钟, 无限重复) + 登录触发 (延迟 5 分钟等 codex 稳定)
$timeTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$logonTrigger.Delay = 'PT5M'

$settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable

$triggers = @($timeTrigger, $logonTrigger)
try {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description "回收 codex 泄漏的持续空闲 MCP server (纯后台)" -Force -ErrorAction Stop | Out-Null
    Write-Host "[OK] 已安装任务 '$TaskName' (S4U 后台无窗口)"
}
catch {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description "回收 codex 泄漏的持续空闲 MCP server (后台)" -Force | Out-Null
    Write-Host "[OK] 已安装任务 '$TaskName' (Interactive+Hidden; S4U 因权限被拒已回退)"
}

Write-Host ("     间隔 {0} 分钟 + 登录后 5 分钟; IdleMinutes={1} MinAge={2}" -f $IntervalMinutes, $IdleMinutes, $MinAgeMinutes)
Write-Host ("     日志: {0}" -f (Join-Path $PSScriptRoot 'mcp-reaper.log'))
Write-Host ""
Write-Host "建议先手动干跑一次确认无误 (只看将回收什么, 不动手):"
Write-Host ("  powershell -ExecutionPolicy Bypass -File `"{0}`"" -f $script)

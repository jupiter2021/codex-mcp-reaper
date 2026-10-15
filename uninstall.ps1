<#
.SYNOPSIS
  卸载 mcp-reaper 计划任务。脚本文件与日志不会被删除, 可手动删除本目录。
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param([string]$TaskName = 'MCP-Reaper')

$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[OK] 已移除计划任务 '$TaskName'。"
}
else {
    Write-Host "[跳过] 未找到计划任务 '$TaskName'。"
}
Write-Host "脚本与日志文件未删除, 如不再需要可手动删除本目录。"

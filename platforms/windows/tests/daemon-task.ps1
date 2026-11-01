# Runs the daemon in the signed-in desktop session as a scheduled task (so it has windows and hooks
# and keeps running after this script ends). Usage: daemon-task.ps1 start|stop|status
param([string]$Action = 'status', [string]$Exe = 'C:\bs\baneyspaces\target\release\baneyspaces.exe')
$name = 'bs-daemon'
switch ($Action) {
  'start' {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    $a = New-ScheduledTaskAction -Execute $Exe -Argument 'daemon --background --trace --log C:\bs\daemon.log' 
    $p = New-ScheduledTaskPrincipal -UserId 'baney' -LogonType Interactive -RunLevel Limited
    $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -Action $a -Principal $p -Settings $s -Force | Out-Null
        Start-ScheduledTask -TaskName $name
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; if ((& $Exe doctor | ConvertFrom-Json).data.checks | ? { $_.check -eq 'daemon' -and $_.ok }) { 'daemon up'; break } }
  }
  'stop' { & $Exe daemon stop; Start-Sleep 1; Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
  default { Get-Process baneyspaces -ErrorAction SilentlyContinue | Select Id, StartTime | Format-Table | Out-String }
}

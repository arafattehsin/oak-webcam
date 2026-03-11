param(
    [switch]$Uninstall,
    [ValidateSet('Logon', 'Startup')][string]$Mode = 'Logon',
    [string]$TaskName = 'OAK-UVC-Tray',
    [string]$RunAsUser = $env:USERNAME,
    [string]$Script = 'start-uvc.ps1'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps = (Get-Command pwsh).Source
$targetScript = Join-Path $here $Script

if (!(Test-Path $targetScript)) { throw "Script not found: $targetScript" }

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Uninstalled scheduled task '$TaskName'"
    }
    else {
        Write-Host "Task '$TaskName' not found"
    }
    exit 0
}

# Create scheduled task trigger
$action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -File `"$targetScript`""
if ($Mode -eq 'Startup') {
    $trigger = New-ScheduledTaskTrigger -AtStartup
}
else {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $RunAsUser
}
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Run $Script at $Mode" | Out-Null
Write-Host "Installed scheduled task '$TaskName' to launch '$Script' at $Mode."

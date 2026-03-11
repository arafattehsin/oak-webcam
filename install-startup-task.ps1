param(
    [switch]$Uninstall,
    [ValidateSet('Logon', 'Startup')][string]$Mode = 'Logon',
    [string]$TaskName = 'OAK-UVC-Tray',
    [string]$RunAsUser = $env:USERNAME,
    [string]$Script = 'start-uvc.ps1'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetScript = Join-Path $here $Script
$vbsLauncher = Join-Path $here 'scripts\launch-hidden.vbs'

if (!(Test-Path $targetScript)) { throw "Script not found: $targetScript" }
if (!(Test-Path $vbsLauncher)) { throw "VBS launcher not found: $vbsLauncher" }

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

# Use wscript.exe + VBS launcher to run PowerShell with no visible window.
# Task Scheduler + pwsh -WindowStyle Hidden still flashes a console host window;
# the VBS wrapper avoids that entirely.
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$action = New-ScheduledTaskAction -Execute $wscript -Argument "`"$vbsLauncher`" `"$targetScript`""
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

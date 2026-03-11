<#
.SYNOPSIS
    Watches for OAK-D-Lite USB plug/unplug events and automatically
    starts or stops the UVC tray app.

.DESCRIPTION
    Uses WMI events to detect insertion and removal of Luxonis OAK devices
    (USB VID 03E7 / Movidius). On insertion it calls start-uvc.ps1; on
    removal it calls stop-uvc.ps1.

    Run this script in the background (or register it as a scheduled task)
    to get automatic start/stop behaviour.

.PARAMETER PollInterval
    WMI polling interval in seconds (default 2).

.PARAMETER DebounceSeconds
    Minimum gap between reacting to the same event type (default 5).

.EXAMPLE
    .\watch-usb.ps1                   # run interactively
    .\watch-usb.ps1 -PollInterval 3   # poll every 3 s
#>
param(
    [int]$PollInterval = 2,
    [int]$DebounceSeconds = 5,
    # Grace period after starting UVC to ignore disconnect events caused by
    # the device re-enumerating on USB when entering UVC mode.
    [int]$StartGraceSeconds = 15
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Logging helper --------------------------------------------------------
$baseLogDir = Join-Path $scriptDir 'logs'
$now = Get-Date
$logDir = Join-Path $baseLogDir (Join-Path $now.ToString('yyyy') (Join-Path $now.ToString('MM') $now.ToString('dd')))
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'watch-usb.log'

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "$ts  $Message"
    Write-Output $line
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

# --- Paths ------------------------------------------------------------------
$startScript = Join-Path $scriptDir 'start-uvc.ps1'
$stopScript  = Join-Path $scriptDir 'stop-uvc.ps1'

if (!(Test-Path $startScript)) { throw "start-uvc.ps1 not found at $startScript" }
if (!(Test-Path $stopScript))  { throw "stop-uvc.ps1 not found at $stopScript" }

# --- Debounce state ---------------------------------------------------------
$lastArrival = [datetime]::MinValue
$lastRemoval = [datetime]::MinValue
# Tracks last time UVC was started so we can ignore the USB re-enumeration
# disconnect that DepthAI triggers when entering UVC mode.
$lastUvcStart = [datetime]::MinValue

# --- Helper: check if OAK device is currently connected ---------------------
function Test-OakDevice {
    $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VID_03E7' }
    return ($null -ne $dev -and $dev.Count -gt 0)
}

# --- Helper: check if oak_uvc.py is already running -------------------------
function Test-UvcRunning {
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -match 'python') -and ($_.CommandLine -match 'oak_uvc\.py') }
    return ($null -ne $procs)
}

# --- Register WMI events ----------------------------------------------------
$vidFilter = "VID_03E7"
$arrivalQuery = "SELECT * FROM __InstanceCreationEvent WITHIN $PollInterval WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.DeviceID LIKE '%${vidFilter}%'"
$removalQuery = "SELECT * FROM __InstanceDeletionEvent WITHIN $PollInterval WHERE TargetInstance ISA 'Win32_PnPEntity' AND TargetInstance.DeviceID LIKE '%${vidFilter}%'"

Write-Log "Registering WMI watchers for USB VID $vidFilter (poll every ${PollInterval}s, debounce ${DebounceSeconds}s)"

Register-CimIndicationEvent -Query $arrivalQuery -SourceIdentifier 'OAK_USB_Arrival' -ErrorAction Stop
Register-CimIndicationEvent -Query $removalQuery -SourceIdentifier 'OAK_USB_Removal' -ErrorAction Stop

Write-Log "Watchers registered. Monitoring for OAK device plug/unplug events..."
Write-Log "Press Ctrl+C to stop."

# --- If device is already connected on startup, ensure UVC is running -------
if (Test-OakDevice) {
    if (!(Test-UvcRunning)) {
        Write-Log "OAK device already connected but UVC not running — starting."
        & $startScript
        $lastUvcStart = Get-Date
    } else {
        Write-Log "OAK device already connected and UVC running."
        $lastUvcStart = Get-Date
    }
} else {
    Write-Log "OAK device not detected at startup."
}

# --- Event loop -------------------------------------------------------------
# Use Continue inside the loop so transient errors don't kill the watcher.
$ErrorActionPreference = 'Continue'
try {
    while ($true) {
        try {
            # Check for arrival events (may return multiple; drain them all)
            $events = @(Get-Event -SourceIdentifier 'OAK_USB_Arrival' -ErrorAction SilentlyContinue)
            if ($events.Count -gt 0) {
                $events | ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue }
                $nowTs = Get-Date
                if (($nowTs - $lastArrival).TotalSeconds -ge $DebounceSeconds) {
                    $lastArrival = $nowTs
                    Write-Log "OAK device CONNECTED."
                    # Small delay to let the device enumerate fully
                    Start-Sleep -Seconds 2
                    if (!(Test-UvcRunning)) {
                        Write-Log "Starting UVC via start-uvc.ps1 ..."
                        try {
                            & $startScript
                            $lastUvcStart = Get-Date
                            Write-Log "start-uvc.ps1 completed."
                        } catch {
                            Write-Log "ERROR running start-uvc.ps1: $_"
                        }
                    } else {
                        Write-Log "UVC already running — skipping start."
                    }
                }
            }

            # Check for removal events (may return multiple; drain them all)
            $events = @(Get-Event -SourceIdentifier 'OAK_USB_Removal' -ErrorAction SilentlyContinue)
            if ($events.Count -gt 0) {
                $events | ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue }
                $nowTs = Get-Date

                # Ignore disconnects within the grace period after a UVC start.
                # DepthAI re-enumerates the device when entering UVC mode,
                # which causes a spurious removal event.
                $sinceStart = ($nowTs - $lastUvcStart).TotalSeconds
                if ($sinceStart -lt $StartGraceSeconds) {
                    Write-Log "Ignoring disconnect (within ${StartGraceSeconds}s grace period after UVC start, elapsed ${sinceStart}s)."
                } elseif (($nowTs - $lastRemoval).TotalSeconds -ge $DebounceSeconds) {
                    $lastRemoval = $nowTs
                    Write-Log "OAK device DISCONNECTED."
                    if (Test-UvcRunning) {
                        Write-Log "Stopping UVC via stop-uvc.ps1 ..."
                        try {
                            & $stopScript
                            Write-Log "stop-uvc.ps1 completed."
                        } catch {
                            Write-Log "ERROR running stop-uvc.ps1: $_"
                        }
                    } else {
                        Write-Log "UVC not running — nothing to stop."
                    }
                }
            }
        } catch {
            Write-Log "ERROR in event loop iteration: $_"
        }

        Start-Sleep -Milliseconds 500
    }
}
finally {
    Write-Log "Cleaning up WMI event subscriptions..."
    Unregister-Event -SourceIdentifier 'OAK_USB_Arrival' -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'OAK_USB_Removal' -ErrorAction SilentlyContinue
    Write-Log "watch-usb.ps1 stopped."
}

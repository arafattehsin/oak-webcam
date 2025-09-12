param(
    [int]$Width = 1920,
    [int]$Height = 1080,
    [int]$Fps = 30,
    [ValidateSet('NV12', 'MJPEG')][string]$Format = 'NV12'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$python = 'python'
$baseLogDir = Join-Path $scriptDir 'logs'
# Build dated log folder: logs\YYYY\MM\DD
$now = Get-Date
$year = $now.ToString('yyyy')
$month = $now.ToString('MM')
$day = $now.ToString('dd')
$logDir = Join-Path -Path $baseLogDir -ChildPath (Join-Path $year (Join-Path $month $day))
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir 'start-uvc.log'

# Ensure venv if present
$venvPython = Join-Path $scriptDir 'venv/Scripts/python.exe'
if (Test-Path $venvPython) { $python = $venvPython }

$cmd = @(
    '"' + $python + '"',
    '"' + (Join-Path $scriptDir 'oak_uvc.py') + '"',
    "--width $Width",
    "--height $Height",
    "--fps $Fps",
    "--format $Format"
) -join ' '

# Start minimized in background and log output
$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = 'pwsh'
$si.Arguments = "-NoLogo -NoProfile -WindowStyle Hidden -Command `$ErrorActionPreference='Stop'; & $cmd 2>&1 | Tee-Object -FilePath `"$log`" -Append"
$si.UseShellExecute = $false
$si.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($si)
Write-Output "Started UVC process (PID=$($proc.Id)). Logging to $log"

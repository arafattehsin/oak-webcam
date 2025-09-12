$ErrorActionPreference = 'Stop'

# Try to locate any python process running oak_uvc.py and terminate it
$procs = Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -match 'python') -and ($_.CommandLine -match 'oak_uvc.py')
}

if (-not $procs) {
    Write-Output 'No oak_uvc.py process found.'
    exit 0
}

$killed = 0
foreach ($p in $procs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        $killed++
    }
    catch {}
}
Write-Output "Stopped $killed process(es)."

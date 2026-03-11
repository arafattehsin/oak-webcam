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
        # Try graceful stop first so pystray can remove its tray icon
        Stop-Process -Id $p.ProcessId -ErrorAction Stop
        $killed++
    }
    catch {}
}

# Give the process a moment to clean up the tray icon
if ($killed -gt 0) { Start-Sleep -Seconds 2 }

# Force-kill any stragglers
$remaining = Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -match 'python') -and ($_.CommandLine -match 'oak_uvc.py')
}
foreach ($p in @($remaining)) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
    }
    catch {}
}

# Refresh the Windows notification area to remove ghost tray icons
try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TrayRefresh {
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string c, string w);
    [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string w);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
    public static void Refresh() {
        IntPtr tb = FindWindow("Shell_TrayWnd", null);
        IntPtr tn = FindWindowEx(tb, IntPtr.Zero, "TrayNotifyWnd", null);
        IntPtr sp = FindWindowEx(tn, IntPtr.Zero, "SysPager", null);
        IntPtr nw = FindWindowEx(sp, IntPtr.Zero, "ToolbarWindow32", null);
        if (nw == IntPtr.Zero) return;
        RECT r; GetClientRect(nw, out r);
        for (int x = 0; x < r.R; x += 5)
            for (int y = 0; y < r.B; y += 5)
                SendMessage(nw, 0x0200, IntPtr.Zero, (IntPtr)((y << 16) | x));
    }
}
"@
    [TrayRefresh]::Refresh()
} catch {}

Write-Output "Stopped $killed process(es)."

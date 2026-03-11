# OAK UVC Tray

Starts your OAK-D-Lite as a Windows webcam (UVC) at 1080p@30. Runs as a tray icon and auto-reconnects on disconnects.

## Drivers

No external driver installation is required for typical Windows setups. The app uses
the system USB/UVC stack together with the installed `depthai` Python package. In most
cases you can install the Python dependencies and run the app directly (see Setup).

If you run into low-level USB issues on a particular machine, the official DepthAI
releases may provide additional tooling or guidance:

- Optional: Download DepthAI releases and tools from https://github.com/luxonis/depthai/releases

Note: diagnostic scripts were removed during repository cleanup to keep only the core app
and startup helpers. If you need the original debug and recovery scripts, restore them from
version control or recreate them using the official DepthAI examples under the
`luxonis/depthai-python` repository (`examples/bootloader/` and `examples/UVC/`).

## Setup

1. (Optional) Create a virtual environment
2. Install dependencies
3. Plug in your OAK-D-Lite via USB3

```powershell
# From this folder
py -3 -m venv .\venv
. .\venv\Scripts\Activate.ps1
pip install -U pip
pip install -r requirements.txt
```

## Run on demand

```powershell
# Start tray app (default 1080p@30 NV12)
.\start-uvc.ps1

# Or directly
python .\oak_uvc.py --width 1920 --height 1080 --fps 30 --format NV12
```

Right-click the tray icon to Exit. Logs are written into dated folders under `logs/YYYY/MM/DD/` to keep files small.

To remove old logs (default: keep 3 days), there's a cleanup script under `scripts/cleanup-logs.ps1`.

Preview what would be deleted (safe):

```powershell
.\scripts\cleanup-logs.ps1 -DaysToKeep 3 -WhatIf
```

Run the cleanup (will delete):

```powershell
.\scripts\cleanup-logs.ps1 -DaysToKeep 3
```

Logs are written into dated folders under `logs/YYYY/MM/DD/` to keep files small.
To remove old logs (default: keep 3 days), there's a cleanup script under `scripts/cleanup-logs.ps1`.

Preview what would be deleted (safe):

```powershell
.\	ools\cleanup-logs.ps1 -DaysToKeep 3 -WhatIf
```

Run the cleanup (will delete):

```powershell
.\scripts\cleanup-logs.ps1 -DaysToKeep 3
```

## USB hotplug watcher

Automatically starts the UVC app when the OAK camera is plugged in and stops it
when the camera is removed. Uses WMI events to detect Luxonis/Movidius devices
(USB VID `03E7`).

```powershell
# Run interactively
.\watch-usb.ps1

# Custom poll interval and debounce
.\watch-usb.ps1 -PollInterval 3 -DebounceSeconds 10
```

Logs are written to `logs/YYYY/MM/DD/watch-usb.log`.

To have the watcher run automatically at logon, install it as a scheduled task:

```powershell
.\install-startup-task.ps1 -TaskName OAK-USB-Watcher -Script watch-usb.ps1
```

## Auto-start at logon

```powershell
# Install startup task (per-user)
.\install-startup-task.ps1

# Remove startup task
.\install-startup-task.ps1 -Uninstall
```

## Troubleshooting

### Device Not Found / Failed to Boot

- ✅ **First**: Install WinUSB drivers using Zadig (see above)
- Try different USB ports (preferably USB 3.0)
- Try different USB cables
- Power cycle the OAK device
- Check Windows Device Manager for driver issues

### Tray Shows Red Icon

- Check `oak_uvc.log` for detailed error messages
- Look for Windows toast notifications
- Try restarting the application

### Format Issues

- Format `NV12` is broadly compatible
- If your app prefers MJPEG, try `--format MJPEG`
- Autofocus/exposure remain automatic by default

## Technical Details

- Uses official DepthAI UVC pipeline approach
- Supports 1080p@30 and 4K@30 (with downscaling)
- NV12 and MJPEG output formats
- Auto-reconnection on device disconnect
- Windows toast notifications for status updates
- Comprehensive logging to `oak_uvc.log`

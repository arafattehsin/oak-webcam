#!/usr/bin/env python3
"""
OAK UVC Tray App
- Starts DepthAI UVC at 1080p@30 by default (NV12)
- Shows a system tray icon to indicate running status
- Auto-reconnects if device disconnects
- Sends Windows toast notifications on errors/restarts
- Logs to oak_uvc.log alongside this script

Usage:
  python oak_uvc.py [--width 1920 --height 1080 --fps 30 --format NV12|MJPEG]

Exit:
  Right-click tray icon -> Exit, or Ctrl+C in console
"""
import argparse
import logging
import os
import signal
import sys
import threading
import time
from contextlib import contextmanager
from typing import Optional

# Third-party
import depthai as dai
from PIL import Image, ImageDraw
import pystray
try:
    from win10toast import ToastNotifier
    TOAST = ToastNotifier()
except Exception:
    TOAST = None

DEFAULT_W = 1920
DEFAULT_H = 1080
DEFAULT_FPS = 30
DEFAULT_FMT = "NV12"  # Alternatives: MJPEG
BASE_LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")

def _dated_log_path(base_name: str) -> str:
    """Return a log path under logs/YYYY/MM/DD/<base_name> and ensure the directories exist."""
    now = time.localtime()
    year = time.strftime("%Y", now)
    month = time.strftime("m", now)
    day = time.strftime("%d", now)
    # Use zero-padded month/day via strftime: %m gives 01-12
    month = time.strftime("%m", now)
    dir_path = os.path.join(BASE_LOG_DIR, year, month, day)
    try:
        os.makedirs(dir_path, exist_ok=True)
    except Exception:
        # If we cannot create the directory, fall back to script directory
        dir_path = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(dir_path, base_name)

LOG_PATH = _dated_log_path("oak_uvc.log")

# Use default watchdog behavior (do not override). Setting custom values can cause instability.

# ------------- Logging -------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("oak_uvc")

# ------------- Tray Icon -------------

def make_icon(color: str = "#4CAF50") -> Image.Image:
    # Simple circle icon with given color
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((8, 8, 56, 56), fill=color)
    return img

ICON_OK = make_icon("#4CAF50")
ICON_WARN = make_icon("#FFC107")
ICON_ERR = make_icon("#F44336")

tray = None
tray_state_lock = threading.Lock()

_toast_enabled = True


def tray_notify(title: str, msg: str, duration: int = 5):
    global _toast_enabled
    # Allow disabling toasts via env var for troubleshooting
    if os.environ.get("OAK_DISABLE_TOAST", "0") == "1":
        return

    if TOAST is not None and _toast_enabled:
        try:
            # Use non-threaded toast to avoid Win32 callback issues with pystray
            # (some Windows callbacks can return None and raise TypeError in the
            # event loop). If this still fails, disable toasts.
            TOAST.show_toast(title, msg, duration=duration, threaded=False)
        except Exception:
            # Disable further toasts to avoid noisy Win32 callback errors
            _toast_enabled = False


def set_tray_icon(img: Image.Image, title: str = "OAK UVC"):
    global tray
    with tray_state_lock:
        if tray is not None:
            try:
                tray.icon = img
                tray.title = title
            except Exception:
                pass

# ------------- DepthAI Pipeline helpers -------------

def make_pipeline(width: int, height: int, fps: int, fmt: str) -> dai.Pipeline:
    """
    Create UVC pipeline using official DepthAI demo approach
    """
    enable_4k = False  # Will downscale 4K -> 1080p

    pipeline = dai.Pipeline()

    # Define a source - color camera (official demo style)
    cam_rgb = pipeline.createColorCamera()
    cam_rgb.setBoardSocket(dai.CameraBoardSocket.CAM_A)
    cam_rgb.setInterleaved(False)
    # cam_rgb.initialControl.setManualFocus(130)

    if enable_4k:
        cam_rgb.setResolution(dai.ColorCameraProperties.SensorResolution.THE_4_K)
        cam_rgb.setIspScale(1, 2)
    else:
        cam_rgb.setResolution(dai.ColorCameraProperties.SensorResolution.THE_1080_P)

    # Create an UVC (USB Video Class) output node
    uvc = pipeline.createUVC()
    cam_rgb.video.link(uvc.input)

    # Note: if the pipeline is sent later to device (using startPipeline()),
    # it is important to pass the device config separately when creating the device
    config = dai.Device.Config()
    # config.board.uvc = dai.BoardConfig.UVC()  # enable default 1920x1080 NV12
    config.board.uvc = dai.BoardConfig.UVC(width, height)
    if fmt.upper() == "NV12":
        config.board.uvc.frameType = dai.ImgFrame.Type.NV12
    elif fmt.upper() == "MJPEG":
        config.board.uvc.frameType = dai.ImgFrame.Type.JPEG
    else:
        raise ValueError(f"Unsupported format: {fmt}")
    # config.board.uvc.cameraName = "My Custom Cam"
    pipeline.setBoardConfig(config.board)

    return pipeline


@contextmanager
def device_context(pipeline: dai.Pipeline):
    """
    Device context using official DepthAI demo approach with enhanced error handling
    """
    device = None
    try:
        # Use official demo approach: direct device connection
        log.info("Attempting device connection using official DepthAI approach...")
        device = dai.Device(pipeline)
        yield device
    except RuntimeError as e:
        error_msg = str(e)
        if "Failed to boot device" in error_msg:
            log.error("Device boot failed - this usually indicates driver issues")
            log.error("RECOMMENDED SOLUTION: Install WinUSB drivers using Zadig")
            log.error("1. Download Zadig from https://zadig.akeo.ie/")
            log.error("2. Run as Administrator")
            log.error("3. Select your OAK device (may show as 'Movidius')")
            log.error("4. Replace driver with WinUSB")
            log.error("5. Reboot and try again")
            raise RuntimeError("Device driver issue detected. Please install WinUSB drivers using Zadig.") from e
        elif "X_LINK_UNBOOTED" in error_msg:
            log.error("Device is in unbooted state - requires proper drivers")
            log.error("This is a common Windows issue that WinUSB drivers fix")
            raise RuntimeError("Device in unbooted state. WinUSB drivers required.") from e
        else:
            # Re-raise other runtime errors
            raise
    except Exception as e:
        log.error(f"Unexpected error during device initialization: {e}")
        raise
    finally:
        if device is not None:
            try:
                device.close()
            except Exception:
                pass

# ------------- Runner -------------

stop_event = threading.Event()

def run_uvc(width: int, height: int, fps: int, fmt: str, retry_delay: float = 2.0):
    """
    Main UVC runner using official DepthAI demo approach
    """
    consecutive_failures = 0
    max_consecutive_failures = 3

    while not stop_event.is_set():
        try:
            log.info(f"Starting UVC: {width}x{height}@{fps} {fmt}")
            set_tray_icon(ICON_WARN, "OAK UVC (starting)")
            pipeline = make_pipeline(width, height, fps, fmt)
            with device_context(pipeline):
                log.info("Device started successfully! Keep this app running to maintain UVC.")
                set_tray_icon(ICON_OK, "OAK UVC (running)")
                tray_notify("OAK UVC", f"Webcam is running at {width}x{height}@{fps}.")
                consecutive_failures = 0  # Reset failure count on success
                while not stop_event.is_set():
                    time.sleep(0.2)
        except RuntimeError as ex:
            error_msg = str(ex)
            if "WinUSB drivers" in error_msg or "driver issue" in error_msg:
                # Driver-related error - show persistent notification
                log.error("Driver issue detected - providing user guidance")
                set_tray_icon(ICON_ERR, "OAK UVC (driver issue)")
                tray_notify("OAK UVC - Driver Issue",
                           "WinUSB drivers required. Check logs for Zadig instructions.")
                # Don't retry automatically for driver issues
                stop_event.wait(300)  # Wait 5 minutes before next attempt
            else:
                # Other runtime errors
                consecutive_failures += 1
                log.exception(f"UVC runtime error (attempt {consecutive_failures})")
                set_tray_icon(ICON_ERR, "OAK UVC (error)")
                tray_notify("OAK UVC error", error_msg[:200])

                if consecutive_failures >= max_consecutive_failures:
                    log.error(f"Too many consecutive failures ({consecutive_failures}). Stopping automatic retries.")
                    tray_notify("OAK UVC", "Stopped due to repeated failures. Check device connection.")
                    break

                # Retry soon unless stopping
                if stop_event.wait(retry_delay):
                    break
        except KeyboardInterrupt:
            break
        except Exception as ex:
            consecutive_failures += 1
            log.exception(f"Unexpected UVC error (attempt {consecutive_failures})")
            set_tray_icon(ICON_ERR, "OAK UVC (error)")
            tray_notify("OAK UVC error", str(ex)[:200])

            if consecutive_failures >= max_consecutive_failures:
                log.error(f"Too many consecutive failures ({consecutive_failures}). Stopping.")
                break

            # Retry soon unless stopping
            if stop_event.wait(retry_delay):
                break

    log.info("UVC loop exiting")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--width", type=int, default=DEFAULT_W)
    parser.add_argument("--height", type=int, default=DEFAULT_H)
    parser.add_argument("--fps", type=int, default=DEFAULT_FPS)
    parser.add_argument("--format", choices=["NV12", "MJPEG"], default=DEFAULT_FMT)
    parser.add_argument("--no-tray", action="store_true", help="Run headless without system tray (for debugging)")
    args = parser.parse_args()

    # Tray menu actions
    def on_exit(icon, item):
        stop_event.set()
        icon.stop()

    global tray
    if not args.no_tray:
        tray = pystray.Icon(
            name="oak_uvc",
            icon=ICON_WARN,
            title="OAK UVC",
            menu=pystray.Menu(pystray.MenuItem("Exit", on_exit)),
        )

        # Worker thread when tray is enabled
        t = threading.Thread(target=run_uvc, args=(args.width, args.height, args.fps, args.format), daemon=True)
        t.start()

        # Signal handlers
        def handle_sig(signum, frame):
            stop_event.set()
            try:
                tray.stop()
            except Exception:
                pass

        for s in (signal.SIGINT, signal.SIGTERM, getattr(signal, "SIGBREAK", signal.SIGTERM)):
            try:
                signal.signal(s, handle_sig)
            except Exception:
                pass

        # Run tray loop (blocking)
        try:
            tray.run()
        finally:
            stop_event.set()
            t.join(timeout=5)
            log.info("Tray app closed.")
    else:
        # Headless mode: run UVC loop in current thread (useful for debugging)
        try:
            run_uvc(args.width, args.height, args.fps, args.format)
        finally:
            stop_event.set()
            log.info("Headless run completed.")
    def handle_sig(signum, frame):
        stop_event.set()
        try:
            tray.stop()
        except Exception:
            pass

    for s in (signal.SIGINT, signal.SIGTERM, getattr(signal, "SIGBREAK", signal.SIGTERM)):
        try:
            signal.signal(s, handle_sig)
        except Exception:
            pass

    # Run tray loop (blocking)
    try:
        tray.run()
    finally:
        stop_event.set()
        t.join(timeout=5)
        log.info("Tray app closed.")


if __name__ == "__main__":
    main()


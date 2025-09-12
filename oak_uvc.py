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

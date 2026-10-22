#!/usr/bin/env python3
"""Keep a lightweight ChatGPT web app available from the system tray."""

from __future__ import annotations

import atexit
import os
import signal
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Keep browser WebRTC capture on normal scheduling.  RTKit 0.14's runtime
# limit kills capture clients on this system when their microphone opens.
os.environ.setdefault("DISABLE_RTKIT", "1")

from PyQt6.QtCore import QTimer
from PyQt6.QtGui import QAction, QIcon
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon


APP_DIR = Path.home() / ".local" / "share" / "chatgpt-webapp"
EXTENSION_DIR = APP_DIR / "extension"
ICON_PATH = Path.home() / ".local" / "share" / "icons" / "hicolor" / "256x256" / "apps" / "chatgpt-webapp.png"
PID_FILE = APP_DIR / "tray-supervisor.pid"
BROWSER_LOG_PATH = APP_DIR / "browser.log"
WINDOW_CLASS = "chatgpt.com.ChatGPTWebApp"

signal_pending = False
browser_process: subprocess.Popen[bytes] | None = None

BROWSER_REALTIME_ARGS = (
    # A docked/occluded app window must keep its WebRTC audio timers and
    # renderer alive for ChatGPT voice conversations.
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
)


def run_capture(*args: str) -> str:
    result = subprocess.run(
        args,
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout


def existing_supervisor_pid() -> int | None:
    try:
        pid = int(PID_FILE.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, ValueError, OSError):
        return None

    try:
        os.kill(pid, 0)
    except OSError:
        return None

    if pid == os.getpid():
        return None

    return pid


def find_window_id() -> str | None:
    output = run_capture("wmctrl", "-lx")
    for line in output.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        if parts[2] == WINDOW_CLASS or "chatgptwebapp" in parts[2].lower():
            return parts[0]
    return None


def focus_window() -> bool:
    window_id = find_window_id()
    if not window_id:
        return False
    subprocess.run(("wmctrl", "-ia", window_id), check=False)
    return True


def pick_browser() -> str:
    preferred = os.environ.get("CHATGPT_BROWSER")
    if preferred:
        if shutil.which(preferred):
            return preferred
        raise RuntimeError(f"Configured CHATGPT_BROWSER was not found: {preferred}")

    for candidate in (
        "chromium",
        "chromium-browser",
        "microsoft-edge-stable",
        "microsoft-edge",
        "google-chrome-stable",
        "google-chrome",
    ):
        path = shutil.which(candidate)
        if path:
            return candidate
    raise RuntimeError("No supported Chromium-based browser found.")


def profile_dir_for_browser(browser: str) -> Path:
    browser_name = Path(browser).name
    if browser_name in ("chromium", "chromium-browser"):
        return APP_DIR / "profile-chromium"
    if browser_name in ("microsoft-edge-stable", "microsoft-edge"):
        return APP_DIR / "profile-edge"
    if browser_name in ("google-chrome-stable", "google-chrome"):
        return APP_DIR / "profile-chrome"
    raise RuntimeError(f"Unsupported Chromium-based browser: {browser}")


def browser_command() -> list[str]:
    browser = pick_browser()
    profile_dir = profile_dir_for_browser(browser)
    profile_dir.mkdir(parents=True, exist_ok=True)
    print(f"Launching {browser} with isolated profile {profile_dir}", flush=True)
    return [
        browser,
        "--app=https://chatgpt.com/",
        f"--user-data-dir={profile_dir}",
        "--profile-directory=Default",
        f"--disable-extensions-except={EXTENSION_DIR}",
        f"--load-extension={EXTENSION_DIR}",
        "--class=ChatGPTWebApp",
        "--ozone-platform=x11",
        "--enable-logging=stderr",
        *BROWSER_REALTIME_ARGS,
        "--new-window",
    ]


def launch_or_focus() -> None:
    global browser_process

    if focus_window():
        return

    if browser_process is not None and browser_process.poll() is None:
        return

    APP_DIR.mkdir(parents=True, exist_ok=True)
    if BROWSER_LOG_PATH.exists() and BROWSER_LOG_PATH.stat().st_size > 2_000_000:
        BROWSER_LOG_PATH.replace(BROWSER_LOG_PATH.with_suffix(".log.old"))
    with BROWSER_LOG_PATH.open("ab", buffering=0) as browser_log:
        browser_process = subprocess.Popen(
            browser_command(),
            stdout=browser_log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )

    for _ in range(40):
        time.sleep(0.5)
        if focus_window():
            return


def reap_browser_process() -> None:
    """Reap a closed/crashed browser and record its exit status."""
    global browser_process

    if browser_process is None:
        return
    return_code = browser_process.poll()
    if return_code is None:
        return
    print(f"ChatGPT browser exited with status {return_code}", flush=True)
    browser_process = None


def close_window() -> None:
    window_id = find_window_id()
    if not window_id:
        return
    subprocess.run(("wmctrl", "-ic", window_id), check=False)


def on_signal(_signum: int, _frame) -> None:
    global signal_pending
    signal_pending = True


def process_signal_requests() -> None:
    global signal_pending
    if signal_pending:
        signal_pending = False
        launch_or_focus()


def write_pid() -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(f"{os.getpid()}\n", encoding="utf-8")


def cleanup_pid() -> None:
    try:
        if PID_FILE.exists() and PID_FILE.read_text(encoding="utf-8").strip() == str(os.getpid()):
            PID_FILE.unlink()
    except OSError:
        pass


def main() -> int:
    signal.signal(signal.SIGUSR1, on_signal)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

    running_pid = existing_supervisor_pid()
    if running_pid is not None:
        os.kill(running_pid, signal.SIGUSR1)
        return 0

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("ChatGPT")

    if not QSystemTrayIcon.isSystemTrayAvailable():
        return 1

    tray = QSystemTrayIcon(QIcon(str(ICON_PATH)), app)
    tray.setToolTip("ChatGPT")

    menu = QMenu()
    show_action = QAction("Open ChatGPT", tray)
    show_action.triggered.connect(launch_or_focus)
    menu.addAction(show_action)

    close_action = QAction("Close ChatGPT Window", tray)
    close_action.triggered.connect(close_window)
    menu.addAction(close_action)

    quit_action = QAction("Quit ChatGPT Tray", tray)
    quit_action.triggered.connect(app.quit)
    menu.addAction(quit_action)

    tray.setContextMenu(menu)

    def on_activated(reason: QSystemTrayIcon.ActivationReason) -> None:
        if reason in (
            QSystemTrayIcon.ActivationReason.Trigger,
            QSystemTrayIcon.ActivationReason.DoubleClick,
            QSystemTrayIcon.ActivationReason.MiddleClick,
        ):
            launch_or_focus()

    tray.activated.connect(on_activated)
    tray.show()

    write_pid()
    atexit.register(cleanup_pid)

    signal_timer = QTimer()
    signal_timer.timeout.connect(process_signal_requests)
    signal_timer.start(250)

    browser_timer = QTimer()
    browser_timer.timeout.connect(reap_browser_process)
    browser_timer.start(1000)

    QTimer.singleShot(0, launch_or_focus)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())

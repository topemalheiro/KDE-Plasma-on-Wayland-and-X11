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

from PyQt6.QtCore import QTimer
from PyQt6.QtGui import QAction, QIcon
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon


APP_DIR = Path.home() / ".local" / "share" / "chatgpt-webapp"
PROFILE_DIR = APP_DIR / "profile"
EXTENSION_DIR = APP_DIR / "extension"
ICON_PATH = Path.home() / ".local" / "share" / "icons" / "hicolor" / "256x256" / "apps" / "chatgpt-webapp.png"
PID_FILE = APP_DIR / "tray-supervisor.pid"
WINDOW_CLASS = "chatgpt.com.ChatGPTWebApp"
WINDOW_TITLE = "ChatGPT"

signal_pending = False


def run_capture(*args: str) -> str:
    result = subprocess.run(
        args,
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout


def find_window_id() -> str | None:
    output = run_capture("wmctrl", "-lx")
    for line in output.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        if parts[2] == WINDOW_CLASS or WINDOW_TITLE in line or "ChatGPTWebApp" in line:
            return parts[0]
    return None


def focus_window() -> bool:
    window_id = find_window_id()
    if not window_id:
        return False
    subprocess.run(("wmctrl", "-ia", window_id), check=False)
    return True


def pick_browser() -> str:
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


def browser_command() -> list[str]:
    browser = pick_browser()
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    return [
        browser,
        "--app=https://chatgpt.com/",
        f"--user-data-dir={PROFILE_DIR}",
        "--profile-directory=Default",
        f"--load-extension={EXTENSION_DIR}",
        "--class=ChatGPTWebApp",
        "--ozone-platform=x11",
        "--new-window",
    ]


def launch_or_focus() -> None:
    if focus_window():
        return

    subprocess.Popen(
        browser_command(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    for _ in range(40):
        time.sleep(0.5)
        if focus_window():
            return


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
    signal.signal(signal.SIGTERM, lambda _s, _f: QApplication.quit())

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("ChatGPT")
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

    QTimer.singleShot(0, launch_or_focus)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())

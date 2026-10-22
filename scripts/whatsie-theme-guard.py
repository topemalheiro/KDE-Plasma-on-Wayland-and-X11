#!/usr/bin/env python3
"""Wait for WhatsApp Web and make WhatSie's saved dark theme authoritative."""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import struct
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from urllib.request import urlopen

from PyQt6.QtCore import QSettings


DEFAULT_PORT = 9222
DEFAULT_TIMEOUT = 90.0
CONFIG_FILE = (
    Path.home()
    / ".var/app/com.ktechpit.whatsie/config/org.keshavnrj.ubuntu/WhatSie.conf"
)

APPLY_DARK_THEME = r"""(() => {
  const theme = 'dark';
  const isDark = true;

  try {
    if (typeof require === 'function') {
      try {
        const prefs = require('WAWebUserPrefsGeneral');
        if (prefs) {
          if (typeof prefs.setSystemThemeMode === 'function') prefs.setSystemThemeMode(false);
          if (typeof prefs.setTheme === 'function') prefs.setTheme(theme);
        }
      } catch (_) {}
      try {
        const context = require('WAWebThemeContext');
        if (context && typeof context.applyThemeToUI === 'function') context.applyThemeToUI(theme);
      } catch (_) {}
      try {
        const systemTheme = require('WAWebSystemTheme');
        if (systemTheme) systemTheme.theme = theme;
      } catch (_) {}
    }
  } catch (_) {}

  try {
    const wrapper = document.querySelector('.app-wrapper-web');
    const reactKey = wrapper && Object.keys(wrapper).find(key =>
      key.startsWith('__reactFiber') || key.startsWith('__reactInternalInstance'));
    let fiber = reactKey ? wrapper[reactKey] : null;
    while (fiber) {
      const node = fiber.stateNode;
      if (node && node.state && node.state.theme !== undefined &&
          node.state.systemThemeMode !== undefined && typeof node.setState === 'function') {
        node.setState({theme, systemThemeMode: false});
        break;
      }
      fiber = fiber.return;
    }
  } catch (_) {}

  localStorage.setItem('theme', theme);
  localStorage.removeItem('system-theme-mode');
  localStorage.removeItem('systemThemeMode');

  const root = document.documentElement;
  root.setAttribute('data-theme', theme);
  root.setAttribute('data-color-mode', theme);
  root.style.colorScheme = theme;
  if (document.body) document.body.classList.toggle('dark', isDark);

  return {
    ready: Boolean(document.querySelector('.app-wrapper-web')),
    localTheme: localStorage.getItem('theme'),
    systemMode: localStorage.getItem('system-theme-mode'),
    dataTheme: root.getAttribute('data-theme'),
    colorMode: root.getAttribute('data-color-mode'),
    colorScheme: root.style.colorScheme,
    bodyDark: Boolean(document.body && document.body.classList.contains('dark')),
  };
})()"""


def recv_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("DevTools closed the connection")
        data.extend(chunk)
    return bytes(data)


def send_frame(sock: socket.socket, payload: bytes) -> None:
    mask = os.urandom(4)
    size = len(payload)
    if size < 126:
        header = bytes((0x81, 0x80 | size))
    elif size <= 0xFFFF:
        header = bytes((0x81, 0x80 | 126)) + struct.pack("!H", size)
    else:
        header = bytes((0x81, 0x80 | 127)) + struct.pack("!Q", size)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    sock.sendall(header + mask + masked)


def recv_frame(sock: socket.socket) -> bytes:
    while True:
        first, second = recv_exact(sock, 2)
        opcode = first & 0x0F
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", recv_exact(sock, 2))[0]
        elif size == 127:
            size = struct.unpack("!Q", recv_exact(sock, 8))[0]
        mask = recv_exact(sock, 4) if second & 0x80 else b""
        payload = recv_exact(sock, size)
        if mask:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        if opcode == 0x8:
            raise RuntimeError("DevTools closed the connection")
        if opcode == 0x9:
            sock.sendall(b"\x8a\x00")
            continue
        if opcode == 0x1:
            return payload


def find_whatsapp_page(port: int) -> str:
    with urlopen(f"http://127.0.0.1:{port}/json/list", timeout=2) as response:
        pages = json.load(response)
    page = next(
        (
            item
            for item in pages
            if item.get("type") == "page"
            and item.get("url", "").startswith("https://web.whatsapp.com/")
            and item.get("webSocketDebuggerUrl")
        ),
        None,
    )
    if page is None:
        raise RuntimeError("WhatsApp page is not available through DevTools")
    return str(page["webSocketDebuggerUrl"])


def evaluate(websocket_url: str, expression: str) -> Any:
    parsed = urlparse(websocket_url)
    with socket.create_connection((parsed.hostname, parsed.port), timeout=4) as sock:
        sock.settimeout(5)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {parsed.path} HTTP/1.1\r\n"
            f"Host: {parsed.netloc}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        sock.sendall(request.encode())
        if b" 101 " not in sock.recv(4096).split(b"\r\n", 1)[0]:
            raise RuntimeError("DevTools rejected the WebSocket connection")

        request_id = 1
        send_frame(
            sock,
            json.dumps(
                {
                    "id": request_id,
                    "method": "Runtime.evaluate",
                    "params": {
                        "expression": expression,
                        "returnByValue": True,
                        "awaitPromise": True,
                    },
                }
            ).encode(),
        )
        while True:
            reply = json.loads(recv_frame(sock))
            if reply.get("id") != request_id:
                continue
            result = reply.get("result", {}).get("result", {})
            if "value" in result:
                return result["value"]
            details = reply.get("result", {}).get("exceptionDetails", {})
            raise RuntimeError(details.get("text", "theme evaluation failed"))


def enforce_dark_theme(port: int, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    stable_reads = 0
    last_error: Exception | None = None
    last_state: dict[str, Any] = {}

    while time.monotonic() < deadline:
        try:
            state = evaluate(find_whatsapp_page(port), APPLY_DARK_THEME)
            if not isinstance(state, dict):
                raise RuntimeError(f"unexpected theme response: {state!r}")
            last_state = state
            is_dark = (
                state.get("ready") is True
                and state.get("localTheme") == "dark"
                and state.get("dataTheme") == "dark"
                and state.get("colorMode") == "dark"
                and state.get("colorScheme") == "dark"
                and state.get("bodyDark") is True
            )
            stable_reads = stable_reads + 1 if is_dark else 0
            if stable_reads >= 3:
                return state
        except (OSError, RuntimeError, ValueError) as error:
            last_error = error
            stable_reads = 0
        time.sleep(1)

    detail = f"; last state: {last_state}" if last_state else ""
    if last_error is not None:
        detail += f"; last error: {last_error}"
    raise RuntimeError(f"Whatsie did not reach a stable dark theme within {timeout:g}s{detail}")


def ensure_saved_dark_theme() -> None:
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    settings = QSettings(str(CONFIG_FILE), QSettings.Format.IniFormat)
    settings.setValue("windowTheme", "dark")
    settings.setValue("automaticTheme", False)
    settings.sync()
    if settings.status() != QSettings.Status.NoError:
        raise RuntimeError(f"could not update {CONFIG_FILE}: {settings.status().name}")
    if settings.value("windowTheme", "").lower() != "dark":
        raise RuntimeError(f"dark theme did not persist in {CONFIG_FILE}")
    if settings.value("automaticTheme", True, type=bool):
        raise RuntimeError(f"automatic theme remained enabled in {CONFIG_FILE}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--config-only", action="store_true")
    args = parser.parse_args()

    try:
        ensure_saved_dark_theme()
        if args.config_only:
            return 0
        state = enforce_dark_theme(args.port, args.timeout)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"whatsie-theme-guard: {error}", file=sys.stderr)
        return 1

    print(json.dumps(state, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# ChatGPT Linux Wrapper

This repo contains a lightweight local ChatGPT Linux wrapper built around a Chromium app window plus a small tray supervisor.

## Where the work lives

- [`scripts/install-chatgpt-webapp.sh`](./install-chatgpt-webapp.sh)
  Installs the wrapper into `~/.local/bin`, `~/.local/share/applications`, `~/.local/share/chatgpt-webapp`, and the hicolor icon theme.
- [`scripts/chatgpt-webapp.sh`](./chatgpt-webapp.sh)
  Main launcher entrypoint used by the desktop file.
- [`scripts/chatgpt-webapp-tray.py`](./chatgpt-webapp-tray.py)
  PyQt6 tray supervisor that keeps ChatGPT reopenable from the system tray.
- [`scripts/chatgpt-webapp-extension/manifest.json`](./chatgpt-webapp-extension/manifest.json)
- [`scripts/chatgpt-webapp-extension/content.js`](./chatgpt-webapp-extension/content.js)
  Tiny wrapper-only extension used for the workspace-limit banner hide.

## Relevant commits

- `07871639b9` `feat: add chatgpt web wrapper`
- `6a9980e1dd` `feat: hide chatgpt workspace limit banner`
- `bea8a7a588` `fix: narrow chatgpt banner hider`
- `77d435fbe9` `fix: use chatgpt icon and kdocker tray`
- `5f086677ab` `checkpoint: recover chatgpt launcher and icon`
- `8c67f485ea` `fix: persist chatgpt tray supervisor`

## What it does

- Opens `https://chatgpt.com/` in Chromium app mode.
- Uses an isolated profile under `~/.local/share/chatgpt-webapp/profile`.
- Loads only the local wrapper extension with `--disable-extensions-except`.
- Installs a `ChatGPT` launcher with the cached ChatGPT favicon.
- Keeps a tray icon alive through `chatgpt-webapp-tray.py`.

## Setup on another Linux machine

### Expected tools

The wrapper assumes these are available:

- `chromium` or another Chromium-based browser in PATH
- `python3`
- `python-pyqt6`
- `sqlite3`
- `xxd`
- `magick` (ImageMagick)
- `wmctrl`
- `update-desktop-database`
- `gtk-update-icon-cache`
- `kbuildsycoca6`

On KDE/Arch, the last three are typically already present with desktop packages.

### Install flow

From this repo:

```bash
bash scripts/install-chatgpt-webapp.sh
```

That installs:

- launcher: `~/.local/bin/chatgpt-webapp`
- desktop file: `~/.local/share/applications/chatgpt-webapp.desktop`
- runtime dir: `~/.local/share/chatgpt-webapp`

### First run

Launch `ChatGPT` from the app launcher.

The wrapper will:

- create the local profile
- extract the cached ChatGPT favicon if available
- start the tray supervisor
- open the app window

If the icon cache is not there yet, open ChatGPT once, then rerun:

```bash
bash scripts/install-chatgpt-webapp.sh
```

## Runtime behavior

- Clicking the launcher starts or signals the tray supervisor.
- Closing the ChatGPT window should leave the tray icon running.
- Clicking the tray icon or launcher should reopen/focus the window.
- To fully stop it, use the tray menu: `Quit ChatGPT Tray`.

## Notes for another agent

- This is not an official OpenAI Linux desktop app.
- The live install is intentionally user-local under `~/.local`.
- If behavior changes, check the installed copies in `~/.local` before assuming the repo copy is what is running.
- If the page UI breaks after a ChatGPT frontend update, inspect `scripts/chatgpt-webapp-extension/content.js` first.

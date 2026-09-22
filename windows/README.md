# Field Command — Windows edition

The same game as the Linux edition, running on Windows. There is no separate port: Windows runs the
Python package in [`../linux/fieldcommand`](../linux/fieldcommand), which is pure Python plus pygame,
pycairo and numpy. This directory holds only what Windows needs on top of that — an entry point, an
icon, and a PyInstaller build.

Windows plays multiplayer with Linux and macOS players; the protocol is identical.

## Play from the source tree

```bat
py -m pip install -r requirements.txt
field-command.bat
```

Python 3.9 or newer. `field-command.bat` puts `..\linux` on `PYTHONPATH` and runs `python -m fieldcommand`,
so it picks up source edits immediately.

## Build the executables

```bat
py -m pip install -r requirements.txt
py build_exe.py
```

This writes into `dist\`:

| File | What it is |
| --- | --- |
| `FieldCommand.exe` | the game, no console window |
| `FieldCommandServer.exe` | the dedicated server, console attached so you can see the log |

Options: `--onedir` for a folder build (starts faster, easier to inspect), `--no-server` to build only
the game, `--clean` to wipe `build\` and `dist\` first. PyInstaller builds for the operating system it
runs on, so the .exe must be built on Windows — it cannot be cross-built from Linux or a Mac.

The icon is generated from the same procedural artwork as every other platform (`art.app_icon_surface`),
so no image files are checked in. That step needs Pillow; without it the build still succeeds, just with
PyInstaller's default icon.

## Dedicated server

```bat
FieldCommandServer.exe --server --port 47777 --name "My server"
```

From the source tree: `field-command.bat --server --port 47777`.

Windows Firewall prompts the first time the game hosts or discovers games. Allow it on private networks,
or open the ports by hand (elevated PowerShell):

```powershell
New-NetFirewallRule -DisplayName "Field Command (game)"      -Direction Inbound -Protocol TCP -LocalPort 47777 -Action Allow
New-NetFirewallRule -DisplayName "Field Command (discovery)" -Direction Inbound -Protocol UDP -LocalPort 47778 -Action Allow
```

## Where things are kept

Settings live in `%APPDATA%\FieldCommand\settings.json` (game speed, edge scrolling, sound, objectives,
fullscreen, last map and opponent count). Deleting that file resets the game to defaults. Saved games
(F5/F9, the pause menu, *Load Game* on the title screen, and the five-minute autosave) are JSON files in
`%APPDATA%\FieldCommand\saves\`, the same format as the Linux and macOS editions.

## Controls and gameplay

Identical to the other editions — see [`../linux/README.md`](../linux/README.md) for the full table of
controls, the map list and the multiplayer notes. **F11** or **Alt+Enter** toggles full screen; **Esc**
opens the menu.

## Known differences from the Linux edition

- The window icon and taskbar icon are drawn at run time from the same vector art, so they match the
  other platforms exactly.
- Fonts come from whatever the system has: Windows picks up Segoe UI (Consolas for the monospaced HUD
  readouts) instead of Noto Sans, so text is the same size but a different typeface.

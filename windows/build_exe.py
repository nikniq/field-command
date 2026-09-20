r"""Builds the Windows executables with PyInstaller.

    python build_exe.py                 # FieldCommand.exe and FieldCommandServer.exe into dist\
    python build_exe.py --no-server     # just the game
    python build_exe.py --onedir        # a folder build instead of a single file (starts faster)

The game code is the shared package in ..\linux\fieldcommand; this script only freezes it.
Run it on Windows: PyInstaller builds for the operating system it runs on.
"""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PKG_PATH = os.path.join(ROOT, "linux")           # holds the `fieldcommand` package
BUILD = os.path.join(HERE, "build")
DIST = os.path.join(HERE, "dist")


def version():
    sys.path.insert(0, PKG_PATH)
    from fieldcommand import __version__
    return __version__


def make_icon():
    """Writes build\\field-command.ico from the procedural app icon. Needs pycairo and Pillow."""
    ico = os.path.join(BUILD, "field-command.ico")
    if os.path.exists(ico):
        return ico
    os.makedirs(BUILD, exist_ok=True)
    try:
        from PIL import Image
        from fieldcommand.art import app_icon_surface
    except ImportError as e:
        print(f"note: no icon ({e}); install pillow and pycairo for a branded exe")
        return None
    pngs = []
    for px in (16, 32, 48, 64, 128, 256):
        p = os.path.join(BUILD, f"icon-{px}.png")
        app_icon_surface(px).write_to_png(p)
        pngs.append(p)
    base = Image.open(pngs[-1])
    base.save(ico, sizes=[(px, px) for px in (16, 32, 48, 64, 128, 256)])
    for p in pngs:
        os.remove(p)
    return ico


def run_pyinstaller(name, console, onedir, icon):
    cmd = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
           "--name", name,
           "--paths", PKG_PATH,
           "--distpath", DIST,
           "--workpath", os.path.join(BUILD, "work"),
           "--specpath", BUILD,
           "--collect-submodules", "fieldcommand",
           "--console" if console else "--windowed",
           "--onedir" if onedir else "--onefile"]
    if icon:
        cmd += ["--icon", icon]
    cmd.append(os.path.join(HERE, "field_command.py"))
    print("+ " + " ".join(cmd))
    subprocess.check_call(cmd, cwd=HERE)


def main():
    ap = argparse.ArgumentParser(description="Build the Windows executables")
    ap.add_argument("--no-server", action="store_true", help="skip the console server build")
    ap.add_argument("--onedir", action="store_true", help="folder build instead of one file")
    ap.add_argument("--clean", action="store_true", help="remove build\\ and dist\\ first")
    args = ap.parse_args()

    if sys.platform != "win32":
        print("error: run this on Windows — PyInstaller builds for the OS it runs on", file=sys.stderr)
        return 1
    if shutil.which("pyinstaller") is None:
        try:
            import PyInstaller  # noqa: F401
        except ImportError:
            print("error: pip install -r requirements.txt (needs pyinstaller)", file=sys.stderr)
            return 1
    if args.clean:
        shutil.rmtree(BUILD, ignore_errors=True)
        shutil.rmtree(DIST, ignore_errors=True)

    v = version()
    print(f"Field Command {v}")
    icon = make_icon()
    run_pyinstaller("FieldCommand", console=False, onedir=args.onedir, icon=icon)
    if not args.no_server:
        run_pyinstaller("FieldCommandServer", console=True, onedir=args.onedir, icon=icon)
    print(f"\nBuilt into {DIST}")
    for f in sorted(os.listdir(DIST)):
        print("  " + f)
    return 0


if __name__ == "__main__":
    sys.exit(main())

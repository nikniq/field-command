"""PyInstaller entry point for the Windows build.

The game itself is the same Python package the Linux edition runs (`../linux/fieldcommand`);
this module only puts it on the path when running from a source checkout and hands control to
`fieldcommand.main`. Nothing about the game is duplicated here.
"""
import os
import sys


def _add_source_tree():
    """When run from the checkout (not a frozen exe), make ../linux importable."""
    if getattr(sys, "frozen", False):
        return
    here = os.path.dirname(os.path.abspath(__file__))
    linux_tree = os.path.join(os.path.dirname(here), "linux")
    if os.path.isdir(os.path.join(linux_tree, "fieldcommand")):
        sys.path.insert(0, linux_tree)


def main():
    _add_source_tree()
    from fieldcommand.main import main as game_main
    return game_main()


if __name__ == "__main__":
    sys.exit(main() or 0)

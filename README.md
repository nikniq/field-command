# Field Command

A real-time strategy game: mine crystal with Engineers, build a base, train Rangers, Snipers and Siege
Tanks, and destroy every enemy building. All artwork is drawn procedurally and all sound is synthesised, so
there are no asset files anywhere in this repository.

| Edition | Language | Where |
| --- | --- | --- |
| macOS | Swift + SpriteKit | [`macos/`](macos/README.md) |
| Linux | Python + pygame | [`linux/`](linux/README.md) |
| Windows | the same Python package, frozen with PyInstaller | [`windows/`](windows/README.md) |

All three play together: up to twelve players on a LAN or over the internet, any mix of platforms,
with the same maps, units and pathfinding. The server is authoritative and enforces fog of war.

## Building and shipping

```sh
./cx.sh all          # build everything this machine can build, into dist/
./cx.sh --help       # the full list of targets
./deploy.sh staging  # ship what is in dist/ to a configured environment
```

See [`deploy.conf.example`](deploy.conf.example) for how environments are configured.

## Tests

`./cx.sh test` runs everything this machine can: the Python edition's simulation suite, the cross-edition
parity checks, and (on a Mac) the headless Swift tests. [`tests/README.md`](tests/README.md) has the
details. GitHub Actions runs all of it on Linux, Windows and macOS on every push, and builds the RPM, the
Windows executable and the Mac app as downloadable artifacts.

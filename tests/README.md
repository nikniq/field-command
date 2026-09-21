# Tests

Two suites, both run by `./cx.sh test` and by the GitHub Actions workflow on every push.

| Where | What | Needs |
| --- | --- | --- |
| `linux/tests/` | The Python edition's simulation: catalogue, Sniper and Radar, bridges, repair, teams, protocol, whole AI games on every map | `pytest`, `numpy` (no pygame, no display) |
| `tests/` | Cross-edition parity: the Swift and Python catalogues, wire order, protocol version, shared constants and app version must agree | `pytest` and the Python edition |
| macOS `FC_*TEST` hooks | The Swift simulation and client, headless: `FC_WORLDTEST`, `FC_REPAIRTEST`, `FC_TEAMSTEST`, `FC_BRIDGETEST=map` | a macOS build |

```sh
cd linux && python -m pytest tests          # about a minute
python -m pytest tests                       # from the repository root, a second
./cx.sh test                                 # everything this machine can run
```

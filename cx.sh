#!/usr/bin/env bash
#
# cx.sh — compile / package helper for Field Command.
#
# One entry point for the three editions in this repo:
#   macos/   Swift + SpriteKit app          (built with swift build / build_app.sh)
#   linux/   Python + pygame app            (byte-compiled, packaged as an RPM)
#   windows/ the same Python app, frozen    (PyInstaller; must be built on Windows)
#   ./       web edition (index.html, app.js, styles.css — nothing to compile)
#
# Usage:  ./cx.sh [options] <target>...
# Run    ./cx.sh help   for the full list.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$ROOT/linux"
MAC_DIR="$ROOT/macos"
WIN_DIR="$ROOT/windows"
DIST_DIR="$ROOT/dist"

NAME="field-command"
VERSION="$(sed -n 's/^VERSION *:*= *//p' "$LINUX_DIR/Makefile" | head -1)"
VERSION="${VERSION:-0.0.0}"

CONFIGURATION="release"
VERBOSE=0

# ---------------------------------------------------------------- output ----

is_tty() { [ -t 1 ]; }
if is_tty; then
    C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_OFF=""
fi

step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }

run() {
    [ "$VERBOSE" -eq 1 ] && printf '    + %s\n' "$*"
    "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required for this target but was not found in PATH"; }

on_macos() { [ "$(uname -s)" = "Darwin" ]; }
on_linux() { [ "$(uname -s)" = "Linux" ]; }

# ----------------------------------------------------------------- usage ----

usage() {
    cat <<USAGE
${C_BOLD}cx.sh${C_OFF} — compile and package Field Command $VERSION

  ./cx.sh [options] <target>...

${C_BOLD}Targets${C_OFF}
  mac          swift build the macOS binary
  mac-app      build "macos/build/Field Command.app" (implies mac)
  mac-zip      zip the .app into dist/ for distribution
  linux        byte-compile the Python sources (catches syntax errors)
  tarball      linux source tarball into linux/rpmbuild/SOURCES
  rpm          build the Fedora RPM (implies tarball), copy into dist/
  srpm         build the source RPM only
  exe          build the Windows executables with PyInstaller (Windows only)
  icons        regenerate the Linux hicolor icon set
  web          stage the web edition (index.html, app.js, styles.css) into dist/web
  test         run the test suites for whatever this machine can run (see tests/README.md)
  all          everything this machine is able to build
  clean        remove build output (macos/.build, linux/rpmbuild, dist, __pycache__)
  version      print the version this tree builds

${C_BOLD}Options${C_OFF}
  -d, --debug        build the macOS binary with the debug configuration
  -v, --verbose      echo each command before running it
  -h, --help         this message

${C_BOLD}Examples${C_OFF}
  ./cx.sh mac-app                 # a runnable .app on your Mac
  ./cx.sh rpm                     # an installable RPM on Fedora
  ./cx.sh clean all               # a full rebuild from scratch
  ./cx.sh --debug mac test        # debug binary, then the headless world test

Build output lands in ${C_BOLD}dist/${C_OFF}; ./deploy.sh ships what is found there.
USAGE
}

# ------------------------------------------------------------ mac targets ----

target_mac() {
    on_macos || die "the macOS edition can only be compiled on macOS"
    need swift
    step "Compiling macOS edition ($CONFIGURATION)"
    ( cd "$MAC_DIR" && run swift build -c "$CONFIGURATION" )
    local bin
    bin="$(cd "$MAC_DIR" && swift build -c "$CONFIGURATION" --show-bin-path)/FieldCommand"
    info "binary: $bin"
}

target_mac_app() {
    on_macos || die "the .app bundle can only be built on macOS"
    [ "$CONFIGURATION" = "release" ] || warn "build_app.sh always bundles the release build"
    step "Building Field Command.app"
    run "$MAC_DIR/build_app.sh"
    mkdir -p "$DIST_DIR"
    rm -rf "$DIST_DIR/Field Command.app"
    run cp -R "$MAC_DIR/build/Field Command.app" "$DIST_DIR/"
    info "bundle: $DIST_DIR/Field Command.app"
}

target_mac_zip() {
    [ -d "$DIST_DIR/Field Command.app" ] || target_mac_app
    need ditto
    step "Zipping the app bundle"
    local zip="$DIST_DIR/$NAME-$VERSION-macos.zip"
    rm -f "$zip"
    ( cd "$DIST_DIR" && run ditto -c -k --sequesterRsrc --keepParent "Field Command.app" "$zip" )
    info "archive: $zip"
}

# ---------------------------------------------------------- linux targets ----

python_bin() {
    if [ -n "${PYTHON:-}" ]; then echo "$PYTHON"
    elif command -v python3 >/dev/null 2>&1; then echo python3
    else die "python3 is required for the Linux edition"; fi
}

target_linux() {
    local py; py="$(python_bin)"
    step "Byte-compiling the Linux edition"
    ( cd "$LINUX_DIR" && run "$py" -m compileall -q fieldcommand ) \
        || die "the Python sources did not compile"
    info "$(ls "$LINUX_DIR"/fieldcommand/*.py | wc -l | tr -d ' ') modules compiled cleanly"
}

target_icons() {
    local py; py="$(python_bin)"
    step "Generating icons"
    ( cd "$LINUX_DIR" && run "$py" -m fieldcommand --make-icons data/icons/hicolor )
}

target_tarball() {
    step "Creating the source tarball"
    ( cd "$LINUX_DIR" && run make dist )
    info "tarball: linux/rpmbuild/SOURCES/$NAME-$VERSION.tar.gz"
}

rpm_build() {
    local mode="$1"          # -ba (binary+source) or -bs (source only)
    on_linux || die "RPMs must be built on Linux (try a Fedora box or a container)"
    need rpmbuild
    target_tarball
    step "Building the RPM"
    ( cd "$LINUX_DIR" && run rpmbuild --define "_topdir $LINUX_DIR/rpmbuild" "$mode" "$NAME.spec" )
    mkdir -p "$DIST_DIR"
    local found=0
    while IFS= read -r rpm; do
        run cp "$rpm" "$DIST_DIR/"
        info "$(basename "$rpm")"
        found=1
    done < <(find "$LINUX_DIR/rpmbuild/RPMS" "$LINUX_DIR/rpmbuild/SRPMS" -name '*.rpm' 2>/dev/null)
    [ "$found" -eq 1 ] || die "rpmbuild produced no packages"
}

target_rpm()  { rpm_build -ba; }
target_srpm() { rpm_build -bs; }

# -------------------------------------------------------- windows targets ----

target_exe() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) die "the Windows executables must be built on Windows (PyInstaller targets its host OS)" ;;
    esac
    local py; py="$(python_bin)"
    step "Building the Windows executables"
    run "$py" "$WIN_DIR/build_exe.py"
    mkdir -p "$DIST_DIR"
    local found=0
    while IFS= read -r exe; do
        run cp "$exe" "$DIST_DIR/"
        info "$(basename "$exe")"
        found=1
    done < <(find "$WIN_DIR/dist" -maxdepth 1 -name '*.exe' 2>/dev/null)
    [ "$found" -eq 1 ] || warn "no .exe found — check the PyInstaller output above"
}

# ------------------------------------------------------------ web target ----

target_web() {
    step "Staging the web edition"
    local out="$DIST_DIR/web"
    rm -rf "$out"; mkdir -p "$out"
    run cp "$ROOT/index.html" "$ROOT/app.js" "$ROOT/styles.css" "$out/"
    info "staged: $out"
}

# ----------------------------------------------------------- test / misc ----

target_test() {
    local py; py="$(python_bin)"
    local failed=0
    step "Python edition: simulation tests"
    if "$py" -c "import pytest, numpy" 2>/dev/null; then
        ( cd "$LINUX_DIR" && run "$py" -m pytest tests -q ) || failed=1
        step "Cross-edition parity"
        ( cd "$ROOT" && run "$py" -m pytest tests -q ) || failed=1
    else
        warn "skipping: pytest and numpy are needed ($py -m pip install pytest numpy)"
    fi
    if on_macos; then
        local bin
        bin="$(cd "$MAC_DIR" && swift build -c "$CONFIGURATION" --show-bin-path 2>/dev/null)/FieldCommand"
        if [ -x "$bin" ]; then
            for t in FC_WORLDTEST FC_REPAIRTEST FC_TEAMSTEST FC_SIEGETEST FC_UPGRADETEST FC_TOWERTEST FC_STORETEST FC_AITEST FC_AUDIOTEST FC_MEDICTEST FC_PINGTEST FC_ARTYTEST; do
                step "macOS: $t"
                run env "$t=1" "$bin" 2>&1 | grep -E "PASSED|FAILED|ok  |FAIL" || failed=1
            done
            step "macOS: FC_BRIDGETEST"
            run env FC_BRIDGETEST=river_crossing "$bin" 2>&1 | grep -E "PASSED|FAILED" || failed=1
            step "macOS: FC_SAVETEST (round trip, and a save written by the Python edition)"
            run env FC_SAVETEST=1 FC_SAVE_FIXTURE="$ROOT/tests/fixtures/save_python.json" "$bin" 2>&1 | grep -E "PASSED|FAILED|ok  |FAIL" || failed=1
        else
            warn "skipping the macOS tests: build first (./cx.sh mac)"
        fi
    fi
    [ "$failed" -eq 0 ] || die "tests failed"
}

target_all() {
    if on_macos; then
        target_mac; target_mac_app
    else
        info "skipping the macOS edition (not on macOS)"
    fi
    target_linux
    if on_linux && command -v rpmbuild >/dev/null 2>&1; then
        target_rpm
    else
        info "skipping the RPM (needs Linux with rpmbuild)"
    fi
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) target_exe ;;
        *) info "skipping the Windows executables (not on Windows)" ;;
    esac
    target_web
}

target_clean() {
    step "Cleaning"
    run rm -rf "$MAC_DIR/.build" "$MAC_DIR/build" "$LINUX_DIR/rpmbuild" \
        "$WIN_DIR/build" "$WIN_DIR/dist" "$WIN_DIR/__pycache__" "$DIST_DIR"
    find "$LINUX_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    info "build output removed"
}

# ------------------------------------------------------------------ main ----

targets=()
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--debug)   CONFIGURATION="debug" ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help|help) usage; exit 0 ;;
        -*)           die "unknown option: $1 (try ./cx.sh --help)" ;;
        *)            targets+=("$1") ;;
    esac
    shift
done

[ ${#targets[@]} -gt 0 ] || { usage; exit 1; }

for t in "${targets[@]}"; do
    case "$t" in
        mac)      target_mac ;;
        mac-app)  target_mac_app ;;
        mac-zip)  target_mac_zip ;;
        linux)    target_linux ;;
        exe)      target_exe ;;
        icons)    target_icons ;;
        tarball)  target_tarball ;;
        rpm)      target_rpm ;;
        srpm)     target_srpm ;;
        web)      target_web ;;
        test)     target_test ;;
        all)      target_all ;;
        clean)    target_clean ;;
        version)  echo "$VERSION" ;;
        *)        die "unknown target: $t (try ./cx.sh --help)" ;;
    esac
done

ok "cx: done"

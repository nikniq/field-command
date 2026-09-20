#!/usr/bin/env bash
#
# deploy.sh — ship Field Command to a target environment.
#
# Environments and their hosts live in deploy.conf (see deploy.conf.example);
# the file is not committed, so credentials and host names stay out of git.
#
# Usage:  ./deploy.sh [options] <environment> [component...]
# Run    ./deploy.sh --help   for the full list.
#
# Artifacts come from dist/, which ./cx.sh fills.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$ROOT/dist"
CONF="${FC_DEPLOY_CONF:-$ROOT/deploy.conf}"

NAME="field-command"
VERSION="$(sed -n 's/^VERSION *:*= *//p' "$ROOT/linux/Makefile" | head -1)"
VERSION="${VERSION:-0.0.0}"

DRY_RUN=0
ASSUME_YES=0
VERBOSE=0
OVERRIDE_HOST=""
OVERRIDE_USER=""

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_OFF=""
fi

step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_OFF" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }

# Runs a command, or prints it when --dry-run is in effect.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s    would run: %s%s\n' "$C_DIM" "$*" "$C_OFF"
        return 0
    fi
    [ "$VERBOSE" -eq 1 ] && printf '    + %s\n' "$*"
    "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found in PATH"; }

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -t 0 ] || die "refusing to deploy non-interactively without --yes"
    local reply
    printf '%s %s[y/N]%s ' "$1" "$C_BOLD" "$C_OFF"
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) die "cancelled" ;; esac
}

# ----------------------------------------------------------------- usage ----

usage() {
    cat <<USAGE
${C_BOLD}deploy.sh${C_OFF} — deploy Field Command $VERSION

  ./deploy.sh [options] <environment> [component...]

${C_BOLD}Components${C_OFF}   (default: every component configured for the environment)
  web        rsync the web edition (dist/web) to the target's web root
  rpm        copy dist/*.noarch.rpm to the target and install it with dnf
  server     restart the dedicated game server unit on the target
  app        install "dist/Field Command.app" into /Applications (local only)

${C_BOLD}Options${C_OFF}
  -n, --dry-run      print what would happen, change nothing
  -y, --yes          do not ask for confirmation
      --host HOST    override the configured host
      --user USER    override the configured ssh user
  -l, --list         list the environments defined in deploy.conf
  -v, --verbose      echo each command before running it
  -h, --help         this message

${C_BOLD}Configuration${C_OFF}
  $CONF
  Per environment, uppercased, e.g. for "staging":
    STAGING_HOST, STAGING_USER, STAGING_WEB_ROOT,
    STAGING_SERVER_UNIT, STAGING_COMPONENTS
  The environment named "local" deploys to this machine and needs no host.

${C_BOLD}Examples${C_OFF}
  ./cx.sh web rpm && ./deploy.sh staging      # build, then ship everything
  ./deploy.sh -n prod web                     # rehearse a web deploy
  ./deploy.sh local app                       # install the Mac app here
USAGE
}

# ---------------------------------------------------------------- config ----

load_conf() {
    if [ -f "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
    elif [ "${ENVIRONMENT:-}" != "local" ]; then
        die "no $CONF — copy deploy.conf.example and fill it in"
    fi
}

# conf <ENV> <KEY> [default] -> value of <ENV>_<KEY>
conf() {
    local var="$(printf '%s_%s' "$1" "$2" | tr '[:lower:]-' '[:upper:]_')"
    local value="${!var:-}"
    printf '%s' "${value:-${3:-}}"
}

list_environments() {
    [ -f "$CONF" ] || die "no $CONF to list"
    step "Environments in $(basename "$CONF")"
    local env host
    while IFS= read -r env; do
        host="$(conf "$env" HOST)"
        printf '    %-12s %s\n' "$(echo "$env" | tr '[:upper:]' '[:lower:]')" "${host:-(no host)}"
    done < <(grep -oE '^[A-Za-z0-9_]+_HOST=' "$CONF" | sed 's/_HOST=$//' | sort -u)
    printf '    %-12s %s\n' "local" "this machine"
}

# ------------------------------------------------------------- ssh helpers ---

SSH_TARGET=""     # user@host, empty for the local environment

remote() {
    if [ -z "$SSH_TARGET" ]; then
        run bash -lc "$*"
    else
        run ssh "$SSH_TARGET" "$*"
    fi
}

check_reachable() {
    [ -n "$SSH_TARGET" ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    step "Checking $SSH_TARGET"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" true \
        || die "cannot reach $SSH_TARGET over ssh (key-based login required)"
    info "reachable"
}

# ------------------------------------------------------------- components ----

deploy_web() {
    local src="$DIST_DIR/web"
    [ -d "$src" ] || die "no $src — run ./cx.sh web first"
    local root; root="$(conf "$ENV_KEY" WEB_ROOT)"
    [ -n "$root" ] || die "${ENV_KEY}_WEB_ROOT is not set in $(basename "$CONF")"

    step "Deploying the web edition to ${SSH_TARGET:-this machine}:$root"
    need rsync
    if [ -z "$SSH_TARGET" ]; then
        run rsync -av --delete "$src/" "$root/"
    else
        run rsync -av --delete -e ssh "$src/" "$SSH_TARGET:$root/"
    fi
    info "served from $root"
}

deploy_rpm() {
    local rpm
    rpm="$(find "$DIST_DIR" -maxdepth 1 -name "$NAME-$VERSION-*.noarch.rpm" 2>/dev/null | sort | tail -1)"
    [ -n "$rpm" ] || die "no $NAME-$VERSION RPM in dist/ — run ./cx.sh rpm on a Fedora machine first"

    step "Installing $(basename "$rpm") on ${SSH_TARGET:-this machine}"
    local remote_path="/tmp/$(basename "$rpm")"
    if [ -n "$SSH_TARGET" ]; then
        run scp "$rpm" "$SSH_TARGET:$remote_path"
    else
        remote_path="$rpm"
    fi
    remote "sudo dnf install -y '$remote_path'"
    remote "rpm -q $NAME" || true
    [ -n "$SSH_TARGET" ] && remote "rm -f '$remote_path'"
    info "installed"
}

deploy_server() {
    local unit; unit="$(conf "$ENV_KEY" SERVER_UNIT "$NAME.service")"
    step "Restarting $unit on ${SSH_TARGET:-this machine}"
    remote "sudo systemctl restart '$unit'"
    remote "systemctl is-active '$unit'" || warn "$unit is not active — check 'journalctl -u $unit'"
}

deploy_app() {
    [ -z "$SSH_TARGET" ] || die "the app component installs locally only (use: ./deploy.sh local app)"
    [ "$(uname -s)" = "Darwin" ] || die "the .app can only be installed on macOS"
    local app="$DIST_DIR/Field Command.app"
    [ -d "$app" ] || die "no bundle in dist/ — run ./cx.sh mac-app first"

    step "Installing Field Command.app into /Applications"
    run rm -rf "/Applications/Field Command.app"
    run cp -R "$app" "/Applications/"
    info "installed: /Applications/Field Command.app"
}

# ------------------------------------------------------------------ main ----

components=()
ENVIRONMENT=""

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        --host)       OVERRIDE_HOST="${2:-}"; shift ;;
        --user)       OVERRIDE_USER="${2:-}"; shift ;;
        -l|--list)    load_conf; list_environments; exit 0 ;;
        -h|--help|help) usage; exit 0 ;;
        -*)           die "unknown option: $1 (try ./deploy.sh --help)" ;;
        *)
            if [ -z "$ENVIRONMENT" ]; then ENVIRONMENT="$1"; else components+=("$1"); fi ;;
    esac
    shift
done

[ -n "$ENVIRONMENT" ] || { usage; exit 1; }

load_conf
ENV_KEY="$(echo "$ENVIRONMENT" | tr '[:lower:]-' '[:upper:]_')"

# Resolve the target host.
HOST="${OVERRIDE_HOST:-$(conf "$ENV_KEY" HOST)}"
USER_NAME="${OVERRIDE_USER:-$(conf "$ENV_KEY" USER "$(id -un)")}"
if [ "$ENVIRONMENT" = "local" ] && [ -z "$HOST" ]; then
    SSH_TARGET=""
elif [ -n "$HOST" ]; then
    SSH_TARGET="$USER_NAME@$HOST"
else
    die "unknown environment '$ENVIRONMENT' — no ${ENV_KEY}_HOST in $(basename "$CONF") (try ./deploy.sh --list)"
fi

# Resolve the components to deploy.
if [ ${#components[@]} -eq 0 ]; then
    default_components="$(conf "$ENV_KEY" COMPONENTS)"
    if [ -n "$default_components" ]; then
        read -ra components <<<"$default_components"
    elif [ "$ENVIRONMENT" = "local" ]; then
        die "say which component to deploy locally, e.g. ./deploy.sh local app"
    else
        die "${ENV_KEY}_COMPONENTS is not set — name the components, e.g. ./deploy.sh $ENVIRONMENT web rpm"
    fi
fi

for c in "${components[@]}"; do
    case "$c" in web|rpm|server|app) ;; *) die "unknown component: $c" ;; esac
done

step "Field Command $VERSION → $ENVIRONMENT (${SSH_TARGET:-this machine})"
info "components: ${components[*]}"
[ "$DRY_RUN" -eq 1 ] && info "${C_DIM}dry run — nothing will be changed${C_OFF}"

confirm "Deploy $VERSION to $ENVIRONMENT?"
check_reachable

for c in "${components[@]}"; do
    case "$c" in
        web)    deploy_web ;;
        rpm)    deploy_rpm ;;
        server) deploy_server ;;
        app)    deploy_app ;;
    esac
done

ok "deploy: $ENVIRONMENT is on $VERSION"

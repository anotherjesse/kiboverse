#!/bin/sh
# Build and release the legacy recplay/ptt runtime to the office-development Pi.
# Machine identity/configuration and secret rotation are explicit setup tasks.
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
cd "$ROOT"

PACKAGE=recplay
BINARY=ptt
TARGET=aarch64-unknown-linux-gnu.2.36
TARGET_OUTPUT=aarch64-unknown-linux-gnu
EXPECTED_HOSTNAME=kibo
EXPECTED_ROLE=office-dev
EXPECTED_USER=jesse
EXPECTED_TIMEZONE=America/Los_Angeles
REMOTE_HOME=/home/jesse

usage() {
    cat <<'EOF'
usage: ./deploy.sh [--build-only]

Builds the legacy recplay/ptt runtime from clean Git-tracked build inputs.
Without --build-only, releases it to the configured office-development Pi.

Environment overrides used by automation/tests:
  KIBO_DEPLOY_HOST        SSH destination (default: kibo.local)
  KIBO_DEPLOY_TARGET_DIR  dedicated Cargo target dir (default: target/deploy-ptt)
EOF
}

MODE=deploy
case ${1-} in
    '') ;;
    --build-only) MODE=build-only ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

CARGO=${KIBO_CARGO:-cargo}
FILE=${KIBO_FILE:-file}
SSH=${KIBO_SSH:-ssh}
SCP=${KIBO_SCP:-scp}
DEPLOY_HOST=${KIBO_DEPLOY_HOST:-kibo.local}
TARGET_DIR=${KIBO_DEPLOY_TARGET_DIR:-$ROOT/target/deploy-ptt}
ARTIFACT=$TARGET_DIR/$TARGET_OUTPUT/release/$BINARY
MANIFEST=$TARGET_DIR/$TARGET_OUTPUT/release/$BINARY.manifest

die() {
    echo "deploy: $*" >&2
    exit 1
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "neither shasum nor sha256sum is available"
    fi
}

validate_sha256() {
    case $1 in
        *[!0-9a-f]*|'') return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

source_revision() {
    revision=$(git rev-parse --verify HEAD) || die "could not identify source revision"
    case $revision in
        *[!0-9a-f]*|'') die "Git returned an invalid source revision" ;;
    esac
    [ "${#revision}" -eq 40 ] || die "Git returned an invalid source revision"

    # Cargo consumes only these repository paths for this package. Requiring
    # them clean makes the revision an exact identifier for the binary inputs,
    # while allowing this deployment machinery itself to be live-tested before
    # its checkpoint commit.
    dirty=$(git status --porcelain=v1 --untracked-files=all -- \
        Cargo.toml Cargo.lock recplay .cargo)
    [ -z "$dirty" ] || die "ptt build inputs are dirty or untracked; commit or remove them before deployment"
    printf '%s\n' "$revision"
}

SOURCE_REVISION=$(source_revision)
mkdir -p "$TARGET_DIR"
rm -f "$ARTIFACT" "$MANIFEST"
"$CARGO" zigbuild \
    --locked \
    --manifest-path "$ROOT/Cargo.toml" \
    --package "$PACKAGE" \
    --bin "$BINARY" \
    --release \
    --target "$TARGET" \
    --target-dir "$TARGET_DIR"

[ -f "$ARTIFACT" ] || die "build did not recreate $ARTIFACT"
[ -x "$ARTIFACT" ] || die "built artifact is not executable: $ARTIFACT"
ARTIFACT_KIND=$("$FILE" -b "$ARTIFACT") || die "could not inspect built artifact"
case $ARTIFACT_KIND in
    *"ELF 64-bit"*"ARM aarch64"*) ;;
    *) die "expected an aarch64 ELF, got: $ARTIFACT_KIND" ;;
esac
ARTIFACT_SHA=$(sha256_file "$ARTIFACT")
validate_sha256 "$ARTIFACT_SHA" || die "invalid SHA-256 for built artifact"

# Check again after the build so the receipt never claims a revision whose
# tracked build inputs were changed by a concurrent editor during Cargo.
[ "$(source_revision)" = "$SOURCE_REVISION" ] || die "source revision changed during build"

DEPLOY_SCRIPT_SHA=$(sha256_file "$ROOT/deploy.sh")
INSTALLER_SHA=$(sha256_file "$ROOT/pi-config/deploy-ptt-remote.sh")
SERVICE_SHA=$(sha256_file "$ROOT/pi-config/systemd/ptt.service")
WIRE_SHA=$(sha256_file "$ROOT/pi-config/wireplumber/51-disable-airhug.lua")
for digest in "$DEPLOY_SCRIPT_SHA" "$INSTALLER_SHA" "$SERVICE_SHA" "$WIRE_SHA"; do
    validate_sha256 "$digest" || die "invalid deployment/configuration SHA-256"
done

MANIFEST_TMP=$MANIFEST.tmp.$$
trap 'rm -f "$MANIFEST_TMP"' 0
umask 077
{
    printf 'format=kibo-ptt-release-v1\n'
    printf 'runtime=recplay/ptt\n'
    printf 'authority=local-flat-turns-jsonl\n'
    printf 'source_revision=%s\n' "$SOURCE_REVISION"
    printf 'source_scope=git-clean:Cargo.toml,Cargo.lock,recplay/,.cargo/\n'
    printf 'target=%s\n' "$TARGET"
    printf 'artifact_sha256=%s\n' "$ARTIFACT_SHA"
    printf 'target_role=%s\n' "$EXPECTED_ROLE"
    printf 'target_hostname=%s\n' "$EXPECTED_HOSTNAME"
    printf 'target_user=%s\n' "$EXPECTED_USER"
    printf 'target_home=%s\n' "$REMOTE_HOME"
    printf 'target_timezone=%s\n' "$EXPECTED_TIMEZONE"
    printf 'service_sha256=%s\n' "$SERVICE_SHA"
    printf 'wireplumber_sha256=%s\n' "$WIRE_SHA"
    printf 'installer_sha256=%s\n' "$INSTALLER_SHA"
    printf 'deploy_script_sha256=%s\n' "$DEPLOY_SCRIPT_SHA"
    printf 'environment=preserved-by-release\n'
} > "$MANIFEST_TMP"
chmod 0644 "$MANIFEST_TMP"
mv "$MANIFEST_TMP" "$MANIFEST"
trap - 0
MANIFEST_SHA=$(sha256_file "$MANIFEST")
validate_sha256 "$MANIFEST_SHA" || die "invalid release-manifest SHA-256"

echo "validated $ARTIFACT"
echo "artifact sha256 $ARTIFACT_SHA"
echo "manifest sha256 $MANIFEST_SHA"
[ "$MODE" = deploy ] || exit 0

REMOTE_STAGE_ROOT=$REMOTE_HOME/.kibo/staging
TAG=$(date +%Y%m%d%H%M%S).$$
REMOTE_STAGE=$REMOTE_STAGE_ROOT/ptt.$TAG
REMOTE_CLEANUP_ARMED=0

cleanup_remote() {
    status=$?
    trap - 0 1 2 15
    if [ "$REMOTE_CLEANUP_ARMED" -eq 1 ]; then
        "$SSH" "$DEPLOY_HOST" "rm -rf '$REMOTE_STAGE'" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
signal_exit() {
    exit "$1"
}
trap cleanup_remote 0
trap 'signal_exit 129' 1
trap 'signal_exit 130' 2
trap 'signal_exit 143' 15

# Target identity is checked before even non-secret release bytes are copied.
# The README's one-time setup establishes these fixed invariants explicitly.
REMOTE_PREFLIGHT='
set -eu
[ "$(hostname)" = kibo ]
[ "$(id -un)" = jesse ]
[ "$(cat /etc/kibo/device-role)" = office-dev ]
[ "$(timedatectl show --property=Timezone --value)" = America/Los_Angeles ]
[ "$(uname -m)" = aarch64 ]
[ "$(getconf GNU_LIBC_VERSION)" = "glibc 2.36" ]
systemctl is-enabled --quiet ptt
systemctl is-active --quiet ptt
'
"$SSH" "$DEPLOY_HOST" "$REMOTE_PREFLIGHT" || \
    die "$DEPLOY_HOST is not the configured office-development target; follow the README setup intentionally"

"$SSH" "$DEPLOY_HOST" \
    "set -eu; umask 077; mkdir -p '$REMOTE_STAGE_ROOT'; chmod 0700 '$REMOTE_STAGE_ROOT'; mkdir -m 0700 '$REMOTE_STAGE'"
REMOTE_CLEANUP_ARMED=1
"$SCP" "$ARTIFACT" "$DEPLOY_HOST:$REMOTE_STAGE/ptt"
"$SCP" "$MANIFEST" "$DEPLOY_HOST:$REMOTE_STAGE/manifest"
"$SCP" "$ROOT/pi-config/deploy-ptt-remote.sh" "$DEPLOY_HOST:$REMOTE_STAGE/install"

REMOTE_COMMAND="sh '$REMOTE_STAGE/install' '$REMOTE_STAGE' '$ARTIFACT_SHA' '$MANIFEST_SHA'"
"$SSH" "$DEPLOY_HOST" "$REMOTE_COMMAND"

echo "deployed legacy ptt release to office-dev. logs: ssh $DEPLOY_HOST journalctl -u ptt -f"

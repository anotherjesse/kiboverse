#!/bin/sh
# Transactionally activate one ptt binary on the configured office-development
# Pi. Machine configuration and secret rotation are deliberately out of scope.
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: deploy-ptt-remote.sh STAGE_DIR ARTIFACT_SHA256 MANIFEST_SHA256" >&2
    exit 2
fi

STAGE_DIR=$1
EXPECTED_ARTIFACT_SHA=$2
EXPECTED_MANIFEST_SHA=$3

EXPECTED_HOSTNAME=kibo
EXPECTED_ROLE=office-dev
EXPECTED_USER=jesse
EXPECTED_TIMEZONE=America/Los_Angeles
SERVICE_NAME=ptt
BUILD_TARGET=aarch64-unknown-linux-gnu.2.36

FILE=${KIBO_FILE:-file}
FLOCK=${KIBO_FLOCK:-flock}
HOSTNAME=${KIBO_HOSTNAME:-hostname}
ID=${KIBO_ID:-id}
MKTEMP=${KIBO_MKTEMP:-mktemp}
MV=${KIBO_MV:-mv}
PGREP=${KIBO_PGREP:-pgrep}
STAT=${KIBO_STAT:-stat}
SUDO=${KIBO_SUDO:-sudo}
SYSTEMCTL=${KIBO_SYSTEMCTL:-systemctl}
TIMEDATECTL=${KIBO_TIMEDATECTL:-timedatectl}
UNAME=${KIBO_UNAME:-uname}
GETCONF=${KIBO_GETCONF:-getconf}
HEALTH_ATTEMPTS=${KIBO_HEALTH_ATTEMPTS:-5}
HEALTH_DELAY=${KIBO_HEALTH_DELAY:-1}

# KIBO_TEST_ROOT is a test seam, not a deploy option. Production paths are
# fixed and match ptt.service exactly.
ROOT_PREFIX=${KIBO_TEST_ROOT:-}
HOME_DIR=$ROOT_PREFIX/home/jesse
ETC_DIR=$ROOT_PREFIX/etc
PROC_DIR=${KIBO_PROC_ROOT:-$ROOT_PREFIX/proc}
ROLE_FILE=$ETC_DIR/kibo/device-role
BINARY_DEST=$HOME_DIR/ptt
SERVICE_FILE=$ETC_DIR/systemd/system/ptt.service
WIRE_FILE=$HOME_DIR/.config/wireplumber/main.lua.d/51-disable-airhug.lua
ENV_FILE=$HOME_DIR/.env
RECEIPT_DEST=$HOME_DIR/.kibo/deployments/ptt.receipt
LOCK_FILE=$HOME_DIR/.kibo/ptt-deploy.lock

ARTIFACT=$STAGE_DIR/ptt
MANIFEST=$STAGE_DIR/manifest
INSTALLER=$STAGE_DIR/install
ROLLBACK_DIR=
BINARY_NEXT=
BINARY_RESTORE=
RECEIPT_NEXT=
RECEIPT_RESTORE=

COMMITTED=0
TRANSACTION_STARTED=0
HAD_RECEIPT=0
PREVIOUS_SHA=
ROLLBACK_CREATED=0
STAGE_VALIDATED=0
STAGE_CLEANUP=

die() {
    echo "ptt installer: $*" >&2
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "neither sha256sum nor shasum is available"
    fi
}

validate_sha256() {
    case $1 in
        *[!0-9a-f]*|'') return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

mode_of() {
    "$STAT" -c %a "$1" 2>/dev/null || "$STAT" -f %Lp "$1" 2>/dev/null
}

running_identity() {
    expected_sha=$1
    "$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" || return 1
    pid=$("$SYSTEMCTL" show --property MainPID --value "$SERVICE_NAME") || return 1
    restarts=$("$SYSTEMCTL" show --property NRestarts --value "$SERVICE_NAME") || return 1
    case $pid in
        ''|*[!0-9]*) return 1 ;;
    esac
    case $restarts in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$pid" -gt 0 ] || return 1

    # ptt owns one flat journal and one capture scratch path. A manually
    # launched sibling would survive systemd restart and violate that
    # single-writer boundary, so exact service identity also means uniqueness.
    matching_pids=$("$PGREP" -x "$SERVICE_NAME" 2>/dev/null) || return 1
    managed_pid_seen=0
    for matching_pid in $matching_pids; do
        case $matching_pid in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$matching_pid" -gt 0 ] || return 1
        [ "$matching_pid" = "$pid" ] || return 1
        managed_pid_seen=1
    done
    [ "$managed_pid_seen" -eq 1 ] || return 1

    [ -f "$PROC_DIR/$pid/exe" ] || return 1
    [ "$(sha256_file "$PROC_DIR/$pid/exe")" = "$expected_sha" ] || return 1
    printf '%s:%s\n' "$pid" "$restarts"
}

health_check() {
    expected_sha=$1
    attempt=1
    # Type=simple may report active just before its child completes execve.
    # Allow a bounded warm-up, then require the full configured number of
    # consecutive observations of one exact PID/restart/executable identity.
    while [ "$attempt" -le "$HEALTH_ATTEMPTS" ]; do
        if stable_identity=$(running_identity "$expected_sha"); then
            break
        fi
        [ "$attempt" -lt "$HEALTH_ATTEMPTS" ] || return 1
        [ "$HEALTH_DELAY" -eq 0 ] || sleep "$HEALTH_DELAY"
        attempt=$((attempt + 1))
    done

    confirmed=1
    while [ "$confirmed" -lt "$HEALTH_ATTEMPTS" ]; do
        [ "$HEALTH_DELAY" -eq 0 ] || sleep "$HEALTH_DELAY"
        identity=$(running_identity "$expected_sha") || return 1
        [ "$identity" = "$stable_identity" ] || return 1
        confirmed=$((confirmed + 1))
    done
}

restore_previous() {
    restore_failed=0
    binary_restored=0

    if cp -p "$ROLLBACK_DIR/ptt" "$BINARY_RESTORE" && \
        chmod 0755 "$BINARY_RESTORE" && \
        "$MV" -f "$BINARY_RESTORE" "$BINARY_DEST"; then
        binary_restored=1
    else
        echo "ptt installer: ERROR: could not restore the previous binary" >&2
        restore_failed=1
    fi

    if [ "$HAD_RECEIPT" -eq 1 ]; then
        if ! cp -p "$ROLLBACK_DIR/receipt" "$RECEIPT_RESTORE" || \
            ! "$MV" -f "$RECEIPT_RESTORE" "$RECEIPT_DEST"; then
            echo "ptt installer: ERROR: could not restore the previous receipt" >&2
            restore_failed=1
        fi
    elif ! rm -f "$RECEIPT_DEST" "$RECEIPT_RESTORE"; then
        echo "ptt installer: ERROR: could not remove the new receipt" >&2
        restore_failed=1
    fi

    # Process safety is independent from receipt recovery. If the binary made
    # it back to its canonical path, always try to restart and verify it.
    if [ "$binary_restored" -eq 1 ]; then
        if ! "$SUDO" -n "$SYSTEMCTL" restart "$SERVICE_NAME"; then
            echo "ptt installer: ERROR: could not restart the previous binary" >&2
            restore_failed=1
        elif ! health_check "$PREVIOUS_SHA"; then
            echo "ptt installer: ERROR: previous running executable did not recover" >&2
            restore_failed=1
        fi
    fi

    [ "$restore_failed" -eq 0 ]
}

cleanup() {
    status=$?
    trap - 0 1 2 15
    set +e
    rollback_failed=0

    if [ "$COMMITTED" -eq 0 ] && [ "$TRANSACTION_STARTED" -eq 1 ]; then
        echo "ptt installer: activation failed; restoring previous deployment" >&2
        if restore_previous; then
            echo "ptt installer: previous binary and receipt restored and verified" >&2
        else
            echo "ptt installer: ERROR: rollback could not restore the previous running executable" >&2
            rollback_failed=1
        fi
    fi

    if [ "$ROLLBACK_CREATED" -eq 1 ]; then
        if [ "$rollback_failed" -eq 0 ]; then
            rm -rf "$ROLLBACK_DIR" >/dev/null 2>&1 || true
        else
            echo "ptt installer: recovery material preserved at $ROLLBACK_DIR" >&2
        fi
    fi
    if [ "$STAGE_VALIDATED" -eq 1 ] && ! rm -rf "$STAGE_CLEANUP" >/dev/null 2>&1; then
        echo "ptt installer: WARNING: could not remove staging directory $STAGE_CLEANUP" >&2
    fi

    if [ "$rollback_failed" -eq 1 ]; then
        exit 70
    fi
    exit "$status"
}

signal_exit() {
    exit "$1"
}

# Cleanup exists before validation, lock acquisition, or any staging mutation.
trap cleanup 0
trap 'signal_exit 129' 1
trap 'signal_exit 130' 2
trap 'signal_exit 143' 15

validate_sha256 "$EXPECTED_ARTIFACT_SHA" || die "invalid expected artifact SHA-256"
validate_sha256 "$EXPECTED_MANIFEST_SHA" || die "invalid expected manifest SHA-256"
case $ROOT_PREFIX in
    ''|/*) ;;
    *) die "KIBO_TEST_ROOT must be absolute" ;;
esac
case $HEALTH_ATTEMPTS:$HEALTH_DELAY in
    *[!0-9:]*) die "health settings must be non-negative integers" ;;
esac
[ "$HEALTH_ATTEMPTS" -gt 0 ] || die "KIBO_HEALTH_ATTEMPTS must be greater than zero"

EXPECTED_STAGE_ROOT=$HOME_DIR/.kibo/staging
case $STAGE_DIR in
    "$EXPECTED_STAGE_ROOT"/ptt.*) ;;
    *) die "staging directory is outside $EXPECTED_STAGE_ROOT" ;;
esac
STAGE_NAME=${STAGE_DIR#"$EXPECTED_STAGE_ROOT/"}
case $STAGE_NAME in
    *[!A-Za-z0-9._-]*|'') die "invalid staging directory name" ;;
esac
[ -d "$EXPECTED_STAGE_ROOT" ] || die "missing staging root"
[ -d "$STAGE_DIR" ] || die "missing staging directory"
[ ! -L "$STAGE_DIR" ] || die "staging directory must not be a symlink"
CANONICAL_STAGE_ROOT=$(CDPATH= cd -P "$EXPECTED_STAGE_ROOT" && pwd) || die "could not resolve staging root"
CANONICAL_STAGE=$(CDPATH= cd -P "$STAGE_DIR" && pwd) || die "could not resolve staging directory"
[ "$(dirname "$CANONICAL_STAGE")" = "$CANONICAL_STAGE_ROOT" ] || die "staging directory escapes its configured root"
STAGE_CLEANUP=$CANONICAL_STAGE
STAGE_VALIDATED=1

[ -d "$HOME_DIR/.kibo" ] || die "target is not configured: missing $HOME_DIR/.kibo"
exec 9>"$LOCK_FILE"
"$FLOCK" -n 9 || die "another ptt deployment is active"

[ "$("$HOSTNAME")" = "$EXPECTED_HOSTNAME" ] || die "wrong hostname"
[ "$("$ID" -un)" = "$EXPECTED_USER" ] || die "wrong remote user"
[ -f "$ROLE_FILE" ] || die "missing office-development role marker"
[ "$(cat "$ROLE_FILE")" = "$EXPECTED_ROLE" ] || die "wrong target role"
[ "$("$TIMEDATECTL" show --property=Timezone --value)" = "$EXPECTED_TIMEZONE" ] || die "wrong target timezone"

REMOTE_ARCH=$("$UNAME" -m) || die "could not inspect remote architecture"
[ "$REMOTE_ARCH" = aarch64 ] || die "remote architecture is $REMOTE_ARCH, expected aarch64"
GLIBC_DESCRIPTION=$("$GETCONF" GNU_LIBC_VERSION 2>/dev/null) || die "could not inspect remote glibc"
GLIBC_VERSION=${GLIBC_DESCRIPTION#glibc }
GLIBC_MAJOR=${GLIBC_VERSION%%.*}
GLIBC_REST=${GLIBC_VERSION#*.}
GLIBC_MINOR=${GLIBC_REST%%.*}
case $GLIBC_MAJOR:$GLIBC_MINOR in
    *[!0-9:]*) die "unrecognized remote glibc version: $GLIBC_DESCRIPTION" ;;
esac
if [ "$GLIBC_MAJOR" -lt 2 ] || { [ "$GLIBC_MAJOR" -eq 2 ] && [ "$GLIBC_MINOR" -lt 36 ]; }; then
    die "remote glibc $GLIBC_VERSION is older than required 2.36"
fi

for required in "$ARTIFACT" "$MANIFEST" "$INSTALLER" "$BINARY_DEST" "$SERVICE_FILE" "$WIRE_FILE" "$ENV_FILE"; do
    [ -f "$required" ] || die "missing required file: $required"
done
[ -x "$BINARY_DEST" ] || die "installed ptt binary is not executable"
[ "$(mode_of "$ENV_FILE")" = 600 ] || die "$ENV_FILE must have mode 0600"
if [ -e "$RECEIPT_DEST" ] || [ -L "$RECEIPT_DEST" ]; then
    [ -f "$RECEIPT_DEST" ] && [ ! -L "$RECEIPT_DEST" ] || \
        die "$RECEIPT_DEST must be a regular file when it exists"
fi

"$SYSTEMCTL" is-enabled --quiet "$SERVICE_NAME" || die "$SERVICE_NAME must already be enabled"
"$SYSTEMCTL" is-active --quiet "$SERVICE_NAME" || die "$SERVICE_NAME must already be active"
PREVIOUS_SHA=$(sha256_file "$BINARY_DEST")
validate_sha256 "$PREVIOUS_SHA" || die "installed binary has invalid SHA-256"
running_identity "$PREVIOUS_SHA" >/dev/null || die "currently running executable does not match $BINARY_DEST"

[ "$(sha256_file "$ARTIFACT")" = "$EXPECTED_ARTIFACT_SHA" ] || die "staged artifact SHA-256 mismatch"
[ "$(sha256_file "$MANIFEST")" = "$EXPECTED_MANIFEST_SHA" ] || die "staged manifest SHA-256 mismatch"
ARTIFACT_KIND=$("$FILE" -b "$ARTIFACT") || die "could not inspect staged artifact"
case $ARTIFACT_KIND in
    *"ELF 64-bit"*"ARM aarch64"*) ;;
    *) die "staged artifact is not an aarch64 ELF: $ARTIFACT_KIND" ;;
esac

require_manifest_line() {
    count=$(grep -Fxc "$1" "$MANIFEST" 2>/dev/null || true)
    [ "$count" -eq 1 ] || die "release manifest is missing or duplicates: $1"
}
require_manifest_line 'format=kibo-ptt-release-v1'
require_manifest_line 'runtime=recplay/ptt'
require_manifest_line 'authority=local-flat-turns-jsonl'
require_manifest_line "target=$BUILD_TARGET"
require_manifest_line "artifact_sha256=$EXPECTED_ARTIFACT_SHA"
require_manifest_line "target_role=$EXPECTED_ROLE"
require_manifest_line "target_hostname=$EXPECTED_HOSTNAME"
require_manifest_line "target_user=$EXPECTED_USER"
require_manifest_line 'target_home=/home/jesse'
require_manifest_line "target_timezone=$EXPECTED_TIMEZONE"
require_manifest_line "service_sha256=$(sha256_file "$SERVICE_FILE")"
require_manifest_line "wireplumber_sha256=$(sha256_file "$WIRE_FILE")"
require_manifest_line "installer_sha256=$(sha256_file "$INSTALLER")"
require_manifest_line 'environment=preserved-by-release'

source_line=$(grep '^source_revision=' "$MANIFEST" || true)
[ "$(printf '%s\n' "$source_line" | grep -c '^source_revision=')" -eq 1 ] || die "release manifest has invalid source revision"
source_value=${source_line#source_revision=}
case $source_value in
    *[!0-9a-f]*|'') die "release manifest has invalid source revision" ;;
esac
[ "${#source_value}" -eq 40 ] || die "release manifest has invalid source revision"

mkdir -p "$HOME_DIR/.kibo/rollback"
chmod 0700 "$HOME_DIR/.kibo/rollback"
ROLLBACK_DIR=$("$MKTEMP" -d "$HOME_DIR/.kibo/rollback/ptt.XXXXXXXX") || \
    die "could not allocate rollback directory"
ROLLBACK_CREATED=1
chmod 0700 "$ROLLBACK_DIR"
BINARY_NEXT=$ROLLBACK_DIR/ptt.next
BINARY_RESTORE=$ROLLBACK_DIR/ptt.restore
RECEIPT_NEXT=$ROLLBACK_DIR/receipt.next
RECEIPT_RESTORE=$ROLLBACK_DIR/receipt.restore
cp -p "$BINARY_DEST" "$ROLLBACK_DIR/ptt"
if [ -f "$RECEIPT_DEST" ]; then
    cp -p "$RECEIPT_DEST" "$ROLLBACK_DIR/receipt"
    HAD_RECEIPT=1
fi
cp "$ARTIFACT" "$BINARY_NEXT"
chmod 0755 "$BINARY_NEXT"
mkdir -p "$(dirname "$RECEIPT_DEST")"
cp "$MANIFEST" "$RECEIPT_NEXT"
chmod 0644 "$RECEIPT_NEXT"

TRANSACTION_STARTED=1
"$MV" -f "$BINARY_NEXT" "$BINARY_DEST"
"$SUDO" -n "$SYSTEMCTL" restart "$SERVICE_NAME"
health_check "$EXPECTED_ARTIFACT_SHA" || die "new binary was not continuously active with the expected executable"
"$MV" -f "$RECEIPT_NEXT" "$RECEIPT_DEST"

COMMITTED=1
echo "ptt installer: binary is active and verified"

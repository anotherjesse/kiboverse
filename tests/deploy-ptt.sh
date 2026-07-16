#!/bin/sh
# Deterministic deployment tests. Every remote path is under a temporary root;
# no network connection, real service, or repository secret is used.
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kibo-deploy-test.XXXXXX")
trap 'rm -rf "$TMP"' 0 1 2 15

fail() {
    echo "deploy test: $*" >&2
    exit 1
}

assert_file_text() {
    [ -f "$1" ] || fail "missing $1"
    [ "$(cat "$1")" = "$2" ] || fail "unexpected contents in $1"
}

assert_contains() {
    grep -F -e "$2" "$1" >/dev/null || fail "$1 does not contain: $2"
}

assert_no_transaction_debris() {
    case_dir=$1
    debris=$(find "$case_dir/home/jesse" \
        \( -name '*.new.*' -o -name '*.restore.*' -o -path '*/rollback/ptt.*' -o -path '*/staging/ptt.*' \) \
        -print)
    [ -z "$debris" ] || fail "transaction debris remains under $case_dir: $debris"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

FAKE_BIN=$TMP/bin
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/file" <<'EOF'
#!/bin/sh
echo 'ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked'
EOF
cat > "$FAKE_BIN/hostname" <<'EOF'
#!/bin/sh
printf '%s\n' "${KIBO_TEST_HOSTNAME:-kibo}"
EOF
cat > "$FAKE_BIN/id" <<'EOF'
#!/bin/sh
[ "${1-}" = -un ] || exit 2
printf '%s\n' "${KIBO_TEST_USER:-jesse}"
EOF
cat > "$FAKE_BIN/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${KIBO_TEST_ARCH:-aarch64}"
EOF
cat > "$FAKE_BIN/getconf" <<'EOF'
#!/bin/sh
printf 'glibc %s\n' "${KIBO_TEST_GLIBC:-2.36}"
EOF
cat > "$FAKE_BIN/timedatectl" <<'EOF'
#!/bin/sh
[ "${1-}" = show ] || exit 2
cat "$KIBO_TEST_TIMEZONE_FILE"
EOF
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
[ "${1-}" != -n ] || shift
exec "$@"
EOF
cat > "$FAKE_BIN/stat" <<'EOF'
#!/bin/sh
# Model GNU stat: -c is the supported mode query. This pins the Linux-first
# probe order because GNU stat gives -f unrelated filesystem semantics.
[ "${1-}" = -c ] || exit 2
[ "${2-}" = %a ] || exit 2
/usr/bin/stat -f %Lp "$3"
EOF
cat > "$FAKE_BIN/flock" <<'EOF'
#!/bin/sh
[ "${KIBO_TEST_LOCKED:-0}" -eq 0 ]
EOF
cat > "$FAKE_BIN/mv" <<'EOF'
#!/bin/sh
count=0
[ ! -f "$KIBO_TEST_MV_COUNT" ] || count=$(cat "$KIBO_TEST_MV_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$KIBO_TEST_MV_COUNT"
if [ "${KIBO_TEST_MV_FAIL_AT:-0}" -eq "$count" ]; then
    exit 1
fi
exec /bin/mv "$@"
EOF
cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/bin/sh
[ "${1-}" = -x ] && [ "${2-}" = ptt ] || exit 2
printf '4242\n'
if [ "${KIBO_TEST_MODE:-stable}" = unmanaged ] || \
    { [ "${KIBO_TEST_MODE:-stable}" = unmanaged-after-restart ] && \
      [ "$(cat "$KIBO_TEST_GENERATION")" = new ]; }; then
    printf '9999\n'
fi
EOF
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$KIBO_TEST_SYSTEMCTL_LOG"
command=${1-}
case $command in
    is-enabled)
        [ "$(cat "$KIBO_TEST_ENABLED")" = enabled ]
        ;;
    is-active)
        if [ "$(cat "$KIBO_TEST_GENERATION")" = new ] && [ "${KIBO_TEST_MODE:-stable}" = unstable ]; then
            count=0
            [ ! -f "$KIBO_TEST_HEALTH_COUNT" ] || count=$(cat "$KIBO_TEST_HEALTH_COUNT")
            count=$((count + 1))
            printf '%s\n' "$count" > "$KIBO_TEST_HEALTH_COUNT"
            [ "$count" -le 1 ] || exit 3
        fi
        if [ "$(cat "$KIBO_TEST_GENERATION")" = new ] && [ "${KIBO_TEST_MODE:-stable}" = pre-exec ]; then
            count=0
            [ ! -f "$KIBO_TEST_HEALTH_COUNT" ] || count=$(cat "$KIBO_TEST_HEALTH_COUNT")
            count=$((count + 1))
            printf '%s\n' "$count" > "$KIBO_TEST_HEALTH_COUNT"
            if [ "$count" -gt 1 ]; then
                rm -f "$KIBO_TEST_PROC/4242/exe"
                ln -s "$KIBO_TEST_BINARY" "$KIBO_TEST_PROC/4242/exe"
            fi
        fi
        [ "$(cat "$KIBO_TEST_STATE")" = active ]
        ;;
    show)
        case $2 in
            --property)
                case $3 in
                    MainPID)
                        if [ "$(cat "$KIBO_TEST_GENERATION")" = new ] && [ "${KIBO_TEST_MODE:-stable}" = churn ]; then
                            count=0
                            [ ! -f "$KIBO_TEST_SHOW_COUNT" ] || count=$(cat "$KIBO_TEST_SHOW_COUNT")
                            count=$((count + 1))
                            printf '%s\n' "$count" > "$KIBO_TEST_SHOW_COUNT"
                            if [ "$count" -gt 1 ]; then printf '4243\n'; else printf '4242\n'; fi
                        else
                            printf '4242\n'
                        fi
                        ;;
                    NRestarts) cat "$KIBO_TEST_RESTARTS" ;;
                    *) exit 2 ;;
                esac
                ;;
            *) exit 2 ;;
        esac
        ;;
    restart)
        if grep -q '^new-' "$KIBO_TEST_BINARY"; then
            printf 'new\n' > "$KIBO_TEST_GENERATION"
            if [ "${KIBO_TEST_MODE:-stable}" = restart-fail ]; then
                printf 'inactive\n' > "$KIBO_TEST_STATE"
                exit 1
            fi
            executable=$KIBO_TEST_BINARY
            if [ "${KIBO_TEST_MODE:-stable}" = wrong-executable ] || \
                [ "${KIBO_TEST_MODE:-stable}" = pre-exec ]; then
                executable=$KIBO_TEST_WRONG_EXECUTABLE
            fi
        else
            printf 'old\n' > "$KIBO_TEST_GENERATION"
            executable=$KIBO_TEST_BINARY
        fi
        count=$(cat "$KIBO_TEST_RESTARTS")
        count=$((count + 1))
        printf '%s\n' "$count" > "$KIBO_TEST_RESTARTS"
        printf 'active\n' > "$KIBO_TEST_STATE"
        rm -f "$KIBO_TEST_PROC/4242/exe" "$KIBO_TEST_PROC/4243/exe"
        ln -s "$executable" "$KIBO_TEST_PROC/4242/exe"
        ln -s "$executable" "$KIBO_TEST_PROC/4243/exe"
        : > "$KIBO_TEST_HEALTH_COUNT"
        : > "$KIBO_TEST_SHOW_COUNT"
        ;;
    *)
        echo "unexpected systemctl command: $*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$FAKE_BIN"/*

write_manifest() {
    manifest=$1
    artifact_sha=$2
    service_sha=$(sha256_file "$SERVICE_FILE")
    wire_sha=$(sha256_file "$WIRE_FILE")
    installer_sha=$(sha256_file "$INSTALLER")
    cat > "$manifest" <<EOF
format=kibo-ptt-release-v1
runtime=recplay/ptt
authority=local-flat-turns-jsonl
source_revision=0123456789abcdef0123456789abcdef01234567
source_scope=git-clean:Cargo.toml,Cargo.lock,recplay/,.cargo/
target=aarch64-unknown-linux-gnu.2.36
artifact_sha256=$artifact_sha
target_role=office-dev
target_hostname=kibo
target_user=jesse
target_home=/home/jesse
target_timezone=America/Los_Angeles
service_sha256=$service_sha
wireplumber_sha256=$wire_sha
installer_sha256=$installer_sha
deploy_script_sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
environment=preserved-by-release
EOF
}

make_remote_fixture() {
    CASE_DIR=$TMP/$1
    HOME_DIR=$CASE_DIR/home/jesse
    ETC_DIR=$CASE_DIR/etc
    PROC_DIR=$CASE_DIR/proc
    STAGE_DIR=$HOME_DIR/.kibo/staging/ptt.test
    BINARY_DEST=$HOME_DIR/ptt
    SERVICE_FILE=$ETC_DIR/systemd/system/ptt.service
    WIRE_FILE=$HOME_DIR/.config/wireplumber/main.lua.d/51-disable-airhug.lua
    ENV_FILE=$HOME_DIR/.env
    ROLE_FILE=$ETC_DIR/kibo/device-role
    TIMEZONE_FILE=$ETC_DIR/timezone
    RECEIPT_DEST=$HOME_DIR/.kibo/deployments/ptt.receipt
    ARTIFACT=$STAGE_DIR/ptt
    MANIFEST=$STAGE_DIR/manifest
    INSTALLER=$STAGE_DIR/install
    STATE=$CASE_DIR/state
    ENABLED=$CASE_DIR/enabled
    GENERATION=$CASE_DIR/generation
    RESTARTS=$CASE_DIR/restarts
    HEALTH_COUNT=$CASE_DIR/health-count
    SHOW_COUNT=$CASE_DIR/show-count
    SYSTEMCTL_LOG=$CASE_DIR/systemctl.log
    MV_COUNT=$CASE_DIR/mv-count
    WRONG_EXECUTABLE=$CASE_DIR/wrong-executable

    mkdir -p "$STAGE_DIR" "$(dirname "$SERVICE_FILE")" "$(dirname "$WIRE_FILE")" \
        "$(dirname "$ROLE_FILE")" "$(dirname "$RECEIPT_DEST")" "$PROC_DIR/4242" "$PROC_DIR/4243"
    chmod 0700 "$STAGE_DIR"
    cp "$ROOT/pi-config/systemd/ptt.service" "$SERVICE_FILE"
    cp "$ROOT/pi-config/wireplumber/51-disable-airhug.lua" "$WIRE_FILE"
    cp "$ROOT/pi-config/deploy-ptt-remote.sh" "$INSTALLER"
    chmod +x "$INSTALLER"
    printf 'office-dev\n' > "$ROLE_FILE"
    printf 'America/Los_Angeles\n' > "$TIMEZONE_FILE"
    printf 'old-binary\n' > "$BINARY_DEST"
    chmod 0755 "$BINARY_DEST"
    printf 'old-receipt\n' > "$RECEIPT_DEST"
    printf 'GEMINI_API_KEY=fake\n' > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    printf 'new-binary\n' > "$ARTIFACT"
    chmod 0755 "$ARTIFACT"
    printf 'unrelated-executable\n' > "$WRONG_EXECUTABLE"
    ARTIFACT_SHA=$(sha256_file "$ARTIFACT")
    write_manifest "$MANIFEST" "$ARTIFACT_SHA"
    MANIFEST_SHA=$(sha256_file "$MANIFEST")

    printf 'active\n' > "$STATE"
    printf 'enabled\n' > "$ENABLED"
    printf 'old\n' > "$GENERATION"
    printf '0\n' > "$RESTARTS"
    : > "$HEALTH_COUNT"
    : > "$SHOW_COUNT"
    : > "$SYSTEMCTL_LOG"
    : > "$MV_COUNT"
    ln -s "$BINARY_DEST" "$PROC_DIR/4242/exe"
    ln -s "$BINARY_DEST" "$PROC_DIR/4243/exe"
}

run_remote() {
    KIBO_FILE=$FAKE_BIN/file \
    KIBO_FLOCK=$FAKE_BIN/flock \
    KIBO_HOSTNAME=$FAKE_BIN/hostname \
    KIBO_ID=$FAKE_BIN/id \
    KIBO_MV=$FAKE_BIN/mv \
    KIBO_PGREP=$FAKE_BIN/pgrep \
    KIBO_STAT=$FAKE_BIN/stat \
    KIBO_UNAME=$FAKE_BIN/uname \
    KIBO_GETCONF=$FAKE_BIN/getconf \
    KIBO_SUDO=$FAKE_BIN/sudo \
    KIBO_SYSTEMCTL=$FAKE_BIN/systemctl \
    KIBO_TIMEDATECTL=$FAKE_BIN/timedatectl \
    KIBO_TEST_ROOT=$CASE_DIR \
    KIBO_PROC_ROOT=$PROC_DIR \
    KIBO_HEALTH_ATTEMPTS=3 \
    KIBO_HEALTH_DELAY=0 \
    KIBO_TEST_SYSTEMCTL_LOG=$SYSTEMCTL_LOG \
    KIBO_TEST_STATE=$STATE \
    KIBO_TEST_ENABLED=$ENABLED \
    KIBO_TEST_GENERATION=$GENERATION \
    KIBO_TEST_RESTARTS=$RESTARTS \
    KIBO_TEST_HEALTH_COUNT=$HEALTH_COUNT \
    KIBO_TEST_SHOW_COUNT=$SHOW_COUNT \
    KIBO_TEST_BINARY=$BINARY_DEST \
    KIBO_TEST_WRONG_EXECUTABLE=$WRONG_EXECUTABLE \
    KIBO_TEST_PROC=$PROC_DIR \
    KIBO_TEST_TIMEZONE_FILE=$TIMEZONE_FILE \
    KIBO_TEST_MV_COUNT=$MV_COUNT \
    KIBO_TEST_MV_FAIL_AT=${KIBO_TEST_MV_FAIL_AT:-0} \
    KIBO_TEST_MODE=${KIBO_TEST_MODE:-stable} \
    KIBO_TEST_HOSTNAME=${KIBO_TEST_HOSTNAME:-kibo} \
    KIBO_TEST_USER=${KIBO_TEST_USER:-jesse} \
    KIBO_TEST_ARCH=${KIBO_TEST_ARCH:-aarch64} \
    KIBO_TEST_GLIBC=${KIBO_TEST_GLIBC:-2.36} \
    KIBO_TEST_LOCKED=${KIBO_TEST_LOCKED:-0} \
    sh "$ROOT/pi-config/deploy-ptt-remote.sh" "${KIBO_TEST_STAGE_OVERRIDE:-$STAGE_DIR}" "$ARTIFACT_SHA" "$MANIFEST_SHA"
}

# Stable activation publishes the exact verified manifest as the receipt and
# leaves no staging, rollback, or temporary files.
make_remote_fixture success
cp "$MANIFEST" "$CASE_DIR/expected-receipt"
run_remote >/dev/null
assert_file_text "$BINARY_DEST" new-binary
cmp "$RECEIPT_DEST" "$CASE_DIR/expected-receipt" >/dev/null || \
    fail "published receipt differs from the verified manifest"
assert_contains "$RECEIPT_DEST" "artifact_sha256=$ARTIFACT_SHA"
[ "$(cat "$GENERATION")" = new ] || fail "new process did not start"
[ "$(grep -c '^restart ptt$' "$SYSTEMCTL_LOG")" -eq 1 ] || fail "stable activation did not restart exactly once"
assert_no_transaction_debris "$CASE_DIR"

# A service that churns after activation rolls the binary and prior receipt
# back, restarts once more, and verifies the old running executable.
make_remote_fixture unstable
KIBO_TEST_MODE=unstable
export KIBO_TEST_MODE
if run_remote >/dev/null 2>&1; then fail "unstable service unexpectedly deployed"; fi
unset KIBO_TEST_MODE
assert_file_text "$BINARY_DEST" old-binary
assert_file_text "$RECEIPT_DEST" old-receipt
[ "$(cat "$GENERATION")" = old ] || fail "rollback did not restart old process"
[ "$(grep -c '^restart ptt$' "$SYSTEMCTL_LOG")" -eq 2 ] || fail "rollback restart count is wrong"
assert_no_transaction_debris "$CASE_DIR"

# Active is insufficient: the exact running executable must match both before
# and after activation.
make_remote_fixture wrong-current-executable
rm "$PROC_DIR/4242/exe"
ln -s "$WRONG_EXECUTABLE" "$PROC_DIR/4242/exe"
if run_remote >/dev/null 2>&1; then fail "wrong current executable unexpectedly passed"; fi
[ ! -s "$SYSTEMCTL_LOG" ] || {
    grep -v -E '^(is-enabled|is-active|show)' "$SYSTEMCTL_LOG" | grep . >/dev/null && fail "wrong executable touched activation"
}
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture wrong-new-executable
KIBO_TEST_MODE=wrong-executable
export KIBO_TEST_MODE
if run_remote >/dev/null 2>&1; then fail "wrong new executable unexpectedly deployed"; fi
unset KIBO_TEST_MODE
assert_file_text "$BINARY_DEST" old-binary
assert_file_text "$RECEIPT_DEST" old-receipt
assert_no_transaction_debris "$CASE_DIR"

# A Type=simple service may briefly expose its pre-exec executable. The health
# gate tolerates that bounded warm-up, then still requires three stable exact
# process observations.
make_remote_fixture pre-exec-warmup
KIBO_TEST_MODE=pre-exec
export KIBO_TEST_MODE
run_remote >/dev/null
unset KIBO_TEST_MODE
assert_file_text "$BINARY_DEST" new-binary
[ "$(cat "$HEALTH_COUNT")" -ge 4 ] || fail "pre-exec warm-up was not followed by a full stable health window"
assert_no_transaction_debris "$CASE_DIR"

# A manually launched sibling is another writer of the same flat journal.
# Reject one present before activation, and roll back if one appears during the
# stable health window.
make_remote_fixture unmanaged-current-process
KIBO_TEST_MODE=unmanaged
export KIBO_TEST_MODE
if run_remote >/dev/null 2>&1; then fail "unmanaged current ptt unexpectedly passed"; fi
unset KIBO_TEST_MODE
if grep -q '^restart ptt$' "$SYSTEMCTL_LOG"; then fail "unmanaged current ptt restarted service"; fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture unmanaged-process-after-restart
KIBO_TEST_MODE=unmanaged-after-restart
export KIBO_TEST_MODE
if run_remote >/dev/null 2>&1; then fail "unmanaged new ptt unexpectedly deployed"; fi
unset KIBO_TEST_MODE
assert_file_text "$BINARY_DEST" old-binary
assert_file_text "$RECEIPT_DEST" old-receipt
assert_no_transaction_debris "$CASE_DIR"

# A changed PID/restart identity after the first healthy observation is churn,
# not a stable activation, and must roll back.
make_remote_fixture process-churn
KIBO_TEST_MODE=churn
export KIBO_TEST_MODE
if run_remote >/dev/null 2>&1; then fail "process churn unexpectedly deployed"; fi
unset KIBO_TEST_MODE
assert_file_text "$BINARY_DEST" old-binary
assert_file_text "$RECEIPT_DEST" old-receipt
assert_no_transaction_debris "$CASE_DIR"

# Receipt publication is part of the transaction. A failure after a healthy
# restart still restores the old binary and old receipt.
make_remote_fixture receipt-failure
KIBO_TEST_MV_FAIL_AT=2
export KIBO_TEST_MV_FAIL_AT
if run_remote >/dev/null 2>&1; then fail "receipt move failure unexpectedly succeeded"; fi
unset KIBO_TEST_MV_FAIL_AT
assert_file_text "$BINARY_DEST" old-binary
assert_file_text "$RECEIPT_DEST" old-receipt
assert_no_transaction_debris "$CASE_DIR"

# Identity, configuration, checksum, service-policy, and lock failures happen
# before the binary changes or the service restarts.
make_remote_fixture wrong-role
printf 'bedroom-production\n' > "$ROLE_FILE"
if run_remote >/dev/null 2>&1; then fail "wrong role unexpectedly passed"; fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture wrong-timezone
printf 'America/New_York\n' > "$TIMEZONE_FILE"
if run_remote >/dev/null 2>&1; then fail "wrong timezone unexpectedly passed"; fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture disabled
printf 'disabled\n' > "$ENABLED"
if run_remote >/dev/null 2>&1; then fail "disabled service unexpectedly passed"; fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture inactive
printf 'inactive\n' > "$STATE"
if run_remote >/dev/null 2>&1; then fail "inactive service unexpectedly passed"; fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture blank-restart-counter
: > "$RESTARTS"
if run_remote >/dev/null 2>&1; then fail "blank NRestarts unexpectedly passed"; fi
if grep -q '^restart ptt$' "$SYSTEMCTL_LOG"; then fail "blank NRestarts restarted service"; fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture locked
KIBO_TEST_LOCKED=1
export KIBO_TEST_LOCKED
if run_remote >/dev/null 2>&1; then fail "concurrent deployment unexpectedly passed"; fi
unset KIBO_TEST_LOCKED
[ ! -s "$SYSTEMCTL_LOG" ] || fail "lock rejection touched systemd"
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture bad-env-mode
chmod 0644 "$ENV_FILE"
if run_remote >/dev/null 2>&1; then fail "world-readable environment unexpectedly passed"; fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture receipt-is-directory
rm -f "$RECEIPT_DEST"
mkdir "$RECEIPT_DEST"
if run_remote >/dev/null 2>&1; then fail "receipt directory unexpectedly passed"; fi
if grep -q '^restart ptt$' "$SYSTEMCTL_LOG"; then fail "receipt directory restarted service"; fi
[ -d "$RECEIPT_DEST" ] || fail "receipt directory was unexpectedly replaced"
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture checksum-mismatch
printf 'tampered\n' >> "$ARTIFACT"
if run_remote >/dev/null 2>&1; then fail "remote checksum mismatch unexpectedly passed"; fi
if grep -q '^restart ptt$' "$SYSTEMCTL_LOG"; then fail "checksum mismatch restarted service"; fi
assert_file_text "$BINARY_DEST" old-binary
assert_no_transaction_debris "$CASE_DIR"

# An invalid caller-supplied stage path is never a cleanup target. This pins
# cleanup authorization to successful canonical bounded-path validation.
make_remote_fixture invalid-stage-cleanup
VICTIM=$CASE_DIR/victim
mkdir -p "$VICTIM"
printf 'keep-me\n' > "$VICTIM/sentinel"
KIBO_TEST_STAGE_OVERRIDE=$VICTIM
export KIBO_TEST_STAGE_OVERRIDE
if run_remote >/dev/null 2>&1; then fail "invalid stage path unexpectedly passed"; fi
unset KIBO_TEST_STAGE_OVERRIDE
assert_file_text "$VICTIM/sentinel" keep-me

# If rollback itself cannot replace the binary, its old binary/receipt copies
# and restore temporary are retained for manual recovery instead of erased.
make_remote_fixture rollback-binary-failure
KIBO_TEST_MODE=unstable
KIBO_TEST_MV_FAIL_AT=2
export KIBO_TEST_MODE KIBO_TEST_MV_FAIL_AT
if run_remote >/dev/null 2>&1; then fail "failed rollback unexpectedly succeeded"; fi
unset KIBO_TEST_MODE KIBO_TEST_MV_FAIL_AT
assert_file_text "$BINARY_DEST" new-binary
backup=$(find "$HOME_DIR/.kibo/rollback" -path '*/ptt.*/ptt' -type f -print -quit)
[ -n "$backup" ] || fail "failed rollback erased the old binary backup"
assert_file_text "$backup" old-binary
restore=$(find "$HOME_DIR/.kibo/rollback" -path '*/ptt.*/ptt.restore' -type f -print -quit)
[ -n "$restore" ] || fail "failed rollback erased the old restore temporary"
assert_file_text "$restore" old-binary

# Receipt restoration failure must not prevent restart/verification of the
# already-restored old binary, and recovery material remains available.
make_remote_fixture rollback-receipt-failure
KIBO_TEST_MODE=unstable
KIBO_TEST_MV_FAIL_AT=3
export KIBO_TEST_MODE KIBO_TEST_MV_FAIL_AT
if run_remote >/dev/null 2>&1; then fail "receipt rollback failure unexpectedly succeeded"; fi
unset KIBO_TEST_MODE KIBO_TEST_MV_FAIL_AT
assert_file_text "$BINARY_DEST" old-binary
[ "$(cat "$GENERATION")" = old ] || fail "receipt failure prevented old-process recovery"
[ "$(grep -c '^restart ptt$' "$SYSTEMCTL_LOG")" -eq 2 ] || fail "old binary was not restarted after receipt failure"
backup=$(find "$HOME_DIR/.kibo/rollback" -path '*/ptt.*/receipt' -type f -print -quit)
[ -n "$backup" ] || fail "receipt rollback failure erased recovery material"
assert_file_text "$backup" old-receipt

# Host-side integration: fake Cargo recreates an deliberately old-mtime output,
# fake transports copy into the remote fixture, and fake SSH actually invokes
# the generated remote installer command.
TRANSPORT_LOG=$TMP/transport.log
CARGO_LOG=$TMP/cargo.log
SCP_COUNT=$TMP/scp-count
cat > "$FAKE_BIN/cargo" <<'EOF'
#!/bin/sh
printf 'pwd=%s|%s\n' "$(pwd)" "$*" >> "$KIBO_TEST_CARGO_LOG"
target_dir=
previous=
for argument do
    if [ "$previous" = --target-dir ]; then target_dir=$argument; fi
    previous=$argument
done
[ -n "$target_dir" ] || exit 2
mkdir -p "$target_dir/aarch64-unknown-linux-gnu/release"
printf 'new-host-built-binary\n' > "$target_dir/aarch64-unknown-linux-gnu/release/ptt"
chmod +x "$target_dir/aarch64-unknown-linux-gnu/release/ptt"
touch -t 200001010000 "$target_dir/aarch64-unknown-linux-gnu/release/ptt"
EOF
cat > "$FAKE_BIN/scp" <<'EOF'
#!/bin/sh
count=0
[ ! -f "$KIBO_TEST_SCP_COUNT" ] || count=$(cat "$KIBO_TEST_SCP_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$KIBO_TEST_SCP_COUNT"
printf 'scp|%s\n' "$*" >> "$KIBO_TEST_TRANSPORT_LOG"
if [ "${KIBO_TEST_SCP_FAIL_AT:-0}" -eq "$count" ]; then exit 1; fi
source=$1
remote=${2#*:}
destination=$KIBO_TEST_REMOTE_ROOT$remote
mkdir -p "$(dirname "$destination")"
cp "$source" "$destination"
EOF
cat > "$FAKE_BIN/ssh" <<'EOF'
#!/bin/sh
host=$1
command=${2-}
printf 'ssh|%s|%s\n' "$host" "$command" >> "$KIBO_TEST_TRANSPORT_LOG"

case $command in
    *'/etc/kibo/device-role'*)
        [ "${KIBO_TEST_PREFLIGHT_FAIL:-0}" -eq 0 ] || exit 1
        [ "$(cat "$KIBO_TEST_REMOTE_ROOT/etc/kibo/device-role")" = office-dev ]
        [ "$(cat "$KIBO_TEST_REMOTE_ROOT/etc/timezone")" = America/Los_Angeles ]
        [ "$(cat "$KIBO_TEST_ENABLED")" = enabled ]
        [ "$(cat "$KIBO_TEST_STATE")" = active ]
        ;;
    "set -eu; umask 077; mkdir -p "*)
        remote=$(printf '%s\n' "$command" | sed -n "s/.*mkdir -m 0700 '\([^']*\)'.*/\1/p")
        [ -n "$remote" ] || exit 2
        mkdir -p "$(dirname "$KIBO_TEST_REMOTE_ROOT$remote")"
        if [ "${KIBO_TEST_STAGE_ROOT_HARDEN_FAIL:-0}" -eq 1 ]; then
            chmod 0777 "$(dirname "$KIBO_TEST_REMOTE_ROOT$remote")"
            exit 1
        fi
        if [ "${KIBO_TEST_STAGE_CREATE_FAIL:-0}" -eq 1 ]; then
            mkdir -p "$KIBO_TEST_REMOTE_ROOT$remote"
            printf 'keep-me\n' > "$KIBO_TEST_REMOTE_ROOT$remote/sentinel"
            printf '%s\n' "$KIBO_TEST_REMOTE_ROOT$remote" > "$KIBO_TEST_STAGE_PATH_FILE"
            exit 1
        fi
        mkdir "$KIBO_TEST_REMOTE_ROOT$remote"
        chmod 0700 "$KIBO_TEST_REMOTE_ROOT$remote"
        ;;
    "sh '/home/jesse/.kibo/staging/ptt."*)
        translated=$(printf '%s\n' "$command" | sed "s|/home/jesse|$KIBO_TEST_REMOTE_ROOT/home/jesse|g")
        eval "set -- $translated"
        exec "$@"
        ;;
    "rm -rf '/home/jesse/.kibo/staging/ptt."*)
        remote=$(printf '%s\n' "$command" | sed -n "s/rm -rf '\([^']*\)'.*/\1/p")
        rm -rf "$KIBO_TEST_REMOTE_ROOT$remote"
        ;;
    *)
        echo "unexpected fake SSH command" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$FAKE_BIN/cargo" "$FAKE_BIN/scp" "$FAKE_BIN/ssh"

run_host() {
    KIBO_CARGO=$FAKE_BIN/cargo \
    KIBO_FILE=$FAKE_BIN/file \
    KIBO_SCP=$FAKE_BIN/scp \
    KIBO_SSH=$FAKE_BIN/ssh \
    KIBO_DEPLOY_HOST=fake-office-dev \
    KIBO_DEPLOY_TARGET_DIR=$TMP/host-target \
    KIBO_TEST_CARGO_LOG=$CARGO_LOG \
    KIBO_TEST_TRANSPORT_LOG=$TRANSPORT_LOG \
    KIBO_TEST_SCP_COUNT=$SCP_COUNT \
    KIBO_TEST_STAGE_PATH_FILE=$TMP/stage-path \
    KIBO_TEST_REMOTE_ROOT=$CASE_DIR \
    KIBO_FILE_REMOTE=$FAKE_BIN/file \
    KIBO_FLOCK=$FAKE_BIN/flock \
    KIBO_HOSTNAME=$FAKE_BIN/hostname \
    KIBO_ID=$FAKE_BIN/id \
    KIBO_MV=$FAKE_BIN/mv \
    KIBO_PGREP=$FAKE_BIN/pgrep \
    KIBO_STAT=$FAKE_BIN/stat \
    KIBO_UNAME=$FAKE_BIN/uname \
    KIBO_GETCONF=$FAKE_BIN/getconf \
    KIBO_SUDO=$FAKE_BIN/sudo \
    KIBO_SYSTEMCTL=$FAKE_BIN/systemctl \
    KIBO_TIMEDATECTL=$FAKE_BIN/timedatectl \
    KIBO_TEST_ROOT=$CASE_DIR \
    KIBO_PROC_ROOT=$PROC_DIR \
    KIBO_HEALTH_ATTEMPTS=3 \
    KIBO_HEALTH_DELAY=0 \
    KIBO_TEST_SYSTEMCTL_LOG=$SYSTEMCTL_LOG \
    KIBO_TEST_STATE=$STATE \
    KIBO_TEST_ENABLED=$ENABLED \
    KIBO_TEST_GENERATION=$GENERATION \
    KIBO_TEST_RESTARTS=$RESTARTS \
    KIBO_TEST_HEALTH_COUNT=$HEALTH_COUNT \
    KIBO_TEST_SHOW_COUNT=$SHOW_COUNT \
    KIBO_TEST_BINARY=$BINARY_DEST \
    KIBO_TEST_WRONG_EXECUTABLE=$WRONG_EXECUTABLE \
    KIBO_TEST_PROC=$PROC_DIR \
    KIBO_TEST_TIMEZONE_FILE=$TIMEZONE_FILE \
    KIBO_TEST_MV_COUNT=$MV_COUNT \
    sh "$ROOT/deploy.sh" "$@"
}

make_remote_fixture host-build-only
rm -rf "$STAGE_DIR"
: > "$TRANSPORT_LOG"
: > "$CARGO_LOG"
mkdir -p "$TMP/foreign-workspace"
(cd "$TMP/foreign-workspace" && run_host --build-only >/dev/null)
(cd "$TMP/foreign-workspace" && run_host --build-only >/dev/null)
[ ! -s "$TRANSPORT_LOG" ] || fail "build-only used SSH/SCP"
[ "$(grep -c -- '--manifest-path' "$CARGO_LOG")" -eq 2 ] || fail "Cargo did not receive the exact manifest twice"
assert_contains "$CARGO_LOG" "pwd=$ROOT|"
assert_contains "$CARGO_LOG" '--package recplay'
assert_contains "$CARGO_LOG" '--bin ptt'

make_remote_fixture host-success
rm -rf "$STAGE_DIR"
: > "$TRANSPORT_LOG"
: > "$CARGO_LOG"
: > "$SCP_COUNT"
run_host >/dev/null
assert_file_text "$BINARY_DEST" new-host-built-binary
assert_contains "$RECEIPT_DEST" 'source_revision='
assert_contains "$TRANSPORT_LOG" "ssh|fake-office-dev|sh '/home/jesse/.kibo/staging/ptt."
assert_no_transaction_debris "$CASE_DIR"

make_remote_fixture host-wrong-target
rm -rf "$STAGE_DIR"
: > "$TRANSPORT_LOG"
: > "$SCP_COUNT"
KIBO_TEST_PREFLIGHT_FAIL=1
export KIBO_TEST_PREFLIGHT_FAIL
if run_host >/dev/null 2>&1; then fail "wrong host preflight unexpectedly passed"; fi
unset KIBO_TEST_PREFLIGHT_FAIL
[ ! -s "$SCP_COUNT" ] || fail "wrong target received release bytes"
if grep -q "rm -rf '/home/jesse/.kibo/staging/ptt\." "$TRANSPORT_LOG"; then
    fail "failed identity preflight armed remote cleanup"
fi
assert_file_text "$BINARY_DEST" old-binary

make_remote_fixture host-stage-collision
rm -rf "$STAGE_DIR"
: > "$TRANSPORT_LOG"
: > "$SCP_COUNT"
rm -f "$TMP/stage-path"
KIBO_TEST_STAGE_CREATE_FAIL=1
export KIBO_TEST_STAGE_CREATE_FAIL
if run_host >/dev/null 2>&1; then fail "failed stage allocation unexpectedly deployed"; fi
unset KIBO_TEST_STAGE_CREATE_FAIL
allocated_stage=$(cat "$TMP/stage-path")
assert_file_text "$allocated_stage/sentinel" keep-me
[ ! -s "$SCP_COUNT" ] || fail "failed stage allocation received release bytes"
rm -rf "$allocated_stage"

make_remote_fixture host-stage-root-hardening-failure
rm -rf "$STAGE_DIR"
: > "$TRANSPORT_LOG"
: > "$SCP_COUNT"
KIBO_TEST_STAGE_ROOT_HARDEN_FAIL=1
export KIBO_TEST_STAGE_ROOT_HARDEN_FAIL
if run_host >/dev/null 2>&1; then fail "failed staging-root hardening unexpectedly deployed"; fi
unset KIBO_TEST_STAGE_ROOT_HARDEN_FAIL
[ ! -s "$SCP_COUNT" ] || fail "insecure staging root received release bytes"
[ "$(mode_of "$HOME_DIR/.kibo/staging")" = 777 ] || fail "hardening failure fixture did not remain insecure"
if grep -q "rm -rf '/home/jesse/.kibo/staging/ptt\." "$TRANSPORT_LOG"; then
    fail "failed staging-root hardening armed leaf cleanup"
fi

make_remote_fixture host-transfer-failure
rm -rf "$STAGE_DIR"
: > "$TRANSPORT_LOG"
: > "$SCP_COUNT"
KIBO_TEST_SCP_FAIL_AT=2
export KIBO_TEST_SCP_FAIL_AT
if run_host >/dev/null 2>&1; then fail "failed transfer unexpectedly deployed"; fi
unset KIBO_TEST_SCP_FAIL_AT
if grep -q '^restart ptt$' "$SYSTEMCTL_LOG"; then fail "transfer failure restarted service"; fi
assert_file_text "$BINARY_DEST" old-binary
assert_no_transaction_debris "$CASE_DIR"

echo "deploy tests passed"

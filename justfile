build:
    cargo build -p kibod

generate-types:
    cargo run --quiet -p kibo-typegen

check-generated-types:
    cargo run --quiet -p kibo-typegen -- --check

test-deploy:
    sh tests/deploy-ptt.sh

# Team ID for signing the iOS/watch apps (OU of the Apple Development cert;
# note the "(38T3238BLZ)" in the cert's common name is the cert id, NOT the team).
watch_team := "NR57ZU358K"

# Prereqs: watch unlocked, on wrist (or charging) and near this Mac; developer
# mode enabled. Signing reuses the local team provisioning profiles.
# Build the watchOS app for device and install it on the paired Apple Watch.
deploy-watch:
    #!/usr/bin/env bash
    set -euo pipefail
    cd ios
    scheme=KiboWatch
    echo "==> Building $scheme for watchOS device (team {{watch_team}})…"
    xcodebuild build -project Kibo.xcodeproj -scheme "$scheme" \
        -destination 'generic/platform=watchOS' \
        -allowProvisioningUpdates DEVELOPMENT_TEAM={{watch_team}} \
        -quiet
    app_dir=$(xcodebuild -project Kibo.xcodeproj -scheme "$scheme" \
        -destination 'generic/platform=watchOS' -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
    app="$app_dir/Kibo Watch.app"
    [ -d "$app" ] || { echo "!! build product not found: $app"; exit 1; }
    echo "==> Built: $app"
    watch=$(xcrun devicectl list devices 2>/dev/null | grep -i 'Apple Watch' \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
    [ -n "$watch" ] || { echo "!! no paired Apple Watch found via devicectl"; exit 1; }
    echo "==> Installing to watch $watch"
    echo "    Wake + UNLOCK the watch, screen on, near the Mac (paired iPhone nearby, same Wi-Fi)."
    # The install runs over a CoreDevice Wi-Fi tunnel to the watch that drops
    # when the watch sleeps/roams. Wait for the tunnel to read 'connected',
    # then retry the install a few times instead of dying on the first miss.
    attempts=6
    for n in $(seq 1 $attempts); do
        state=""
        for _ in $(seq 1 15); do
            state=$(xcrun devicectl device info details --device "$watch" 2>/dev/null \
                | awk -F': ' '/tunnelState/{gsub(/[[:space:]]/,"",$2); print $2; exit}')
            [ "$state" = "connected" ] && break
            sleep 1
        done
        echo "    attempt $n/$attempts (tunnel=${state:-unknown})…"
        if xcrun devicectl device install app --device "$watch" "$app" 2>&1 \
            | tee /tmp/kibo-watch-install.log | grep -q "App installed"; then
            echo "==> Installed. Open 'Kibo Watch' on the watch."
            exit 0
        fi
        tail -1 /tmp/kibo-watch-install.log 2>/dev/null || true
        sleep 3
    done
    echo "!! Install kept timing out after $attempts attempts — the BUILD is fine."
    echo "   This is the watch's CoreDevice tunnel, not the app. Unlock the watch,"
    echo "   keep it awake and next to the Mac (+ paired iPhone), then rerun 'just deploy-watch'."
    exit 1

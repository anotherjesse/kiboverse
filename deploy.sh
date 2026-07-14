#!/bin/sh
# Build ptt on the Mac, push the binary and Pi-side config to kibo.local,
# and (re)start the systemd service. Requires passwordless sudo on the Pi.
set -e
cd "$(dirname "$0")"

(cd recplay && cargo zigbuild --release --target aarch64-unknown-linux-gnu.2.36)

scp recplay/target/aarch64-unknown-linux-gnu/release/ptt kibo.local:ptt.new
ssh kibo.local 'mkdir -p .config/wireplumber/main.lua.d'
scp pi-config/wireplumber/51-disable-airhug.lua kibo.local:.config/wireplumber/main.lua.d/
scp pi-config/systemd/ptt.service kibo.local:/tmp/ptt.service
[ -f .env ] && scp .env kibo.local:.env

ssh kibo.local '
  sudo -n systemctl stop ptt 2>/dev/null || true
  pkill -x ptt 2>/dev/null || true
  mv ptt.new ptt
  sudo -n cp /tmp/ptt.service /etc/systemd/system/ptt.service
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable --now ptt
  sleep 1
  systemctl is-active ptt
'
echo "deployed. logs: ssh kibo.local journalctl -u ptt -f"

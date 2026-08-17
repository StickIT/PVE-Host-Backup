#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

for script in "$repo_root"/scripts/*.sh; do
  echo "bash -n: ${script#$repo_root/}"
  bash -n "$script"
done

awk '
  /^install -m 0750 \/dev\/stdin \/usr\/local\/sbin\/pve-host-backup <<.PVE_HOST_BACKUP_SCRIPT./ {
    capture=1
    next
  }
  capture && /^PVE_HOST_BACKUP_SCRIPT$/ { exit }
  capture { print }
' "$repo_root/scripts/install.sh" >"$temporary/pve-host-backup"

test -s "$temporary/pve-host-backup"
echo "bash -n: programme embarque pve-host-backup"
bash -n "$temporary/pve-host-backup"
chmod 0755 "$temporary/pve-host-backup"
"$temporary/pve-host-backup" --help >"$temporary/help.txt"
grep -q 'pve-host-backup auto-status' "$temporary/help.txt"

grep -q 'VERSION="1.0.0"' "$temporary/pve-host-backup"
grep -q 'auto-on)' "$temporary/pve-host-backup"
grep -q -- '--exclude=./var/lib/lxcfs' "$temporary/pve-host-backup"
grep -q -- '--exclude=./var/spool/postfix' "$temporary/pve-host-backup"

if command -v systemd-analyze >/dev/null 2>&1; then
  echo "systemd-analyze calendar"
  systemd-analyze calendar 'Sun *-*-* 04:15:00' >/dev/null

  sed 's#^ExecStart=.*#ExecStart=/bin/true#' \
    "$repo_root/examples/pve-host-backup.service" >"$temporary/pve-host-backup.service"
  cp "$repo_root/examples/pve-host-backup.timer" "$temporary/pve-host-backup.timer"
  echo "systemd-analyze verify: unites d'exemple"
  systemd-analyze verify \
    "$temporary/pve-host-backup.service" \
    "$temporary/pve-host-backup.timer"
fi

echo "Validation statique terminee."

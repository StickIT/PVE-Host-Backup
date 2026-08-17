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
grep -q 'pve-host-backup configure' "$temporary/help.txt"
grep -q 'pve-host-backup settings' "$temporary/help.txt"
grep -q 'pve-host-backup configure-resources' "$temporary/help.txt"
grep -q 'pve-host-backup resources' "$temporary/help.txt"

grep -q 'VERSION="1.2.0"' "$temporary/pve-host-backup"
grep -q 'auto-on)' "$temporary/pve-host-backup"
grep -q 'configure)' "$temporary/pve-host-backup"
grep -q 'NOTIFY_SUCCESS' "$temporary/pve-host-backup"
grep -q 'BACKUP_TIME' "$temporary/pve-host-backup"
grep -q 'CPU_QUOTA_PERCENT' "$temporary/pve-host-backup"
grep -q 'MEMORY_HIGH' "$temporary/pve-host-backup"
grep -q 'MEMORY_MAX' "$temporary/pve-host-backup"
grep -q 'restore-profile.txt' "$temporary/pve-host-backup"
grep -q 'date +%Y-%m-%dT%H-%M-%S%z' "$temporary/pve-host-backup"
grep -q -- '--exclude=./var/lib/lxcfs' "$temporary/pve-host-backup"
grep -q -- '--exclude=./var/spool/postfix' "$temporary/pve-host-backup"
! grep -q '^RandomizedDelaySec=' "$repo_root/examples/pve-host-backup.timer"
grep -q '^CPUQuota=200%$' "$repo_root/examples/pve-host-backup.resources.conf"
grep -q '^MemoryHigh=2G$' "$repo_root/examples/pve-host-backup.resources.conf"
grep -q '/usr/local/sbin/pve-host-restore' "$repo_root/scripts/uninstall.sh"

sed '/^main "\$@"$/d' "$temporary/pve-host-backup" >"$temporary/pve-host-backup-library"
echo "unit-tests: identifiants et tailles du programme embarque"
bash -c '
  source "$1"
  is_backup_id 2026-08-18T04-15-00+0900
  is_backup_id 2026-08-17T19-15-00Z
  ! is_backup_id ../../etc/passwd
  [[ $(size_to_bytes 1G) == 1073741824 ]]
' _ "$temporary/pve-host-backup-library"

echo "self-test: assistant de restauration"
bash "$repo_root/scripts/restore-assistant.sh" --self-test
grep -q 'VERSION="1.2.0"' "$repo_root/scripts/restore-assistant.sh"
grep -q 'verify-session' "$repo_root/scripts/restore-assistant.sh"

if command -v systemd-analyze >/dev/null 2>&1; then
  echo "systemd-analyze calendar"
  systemd-analyze calendar 'Sun *-*-* 04:15:00' >/dev/null

  sed 's#^ExecStart=.*#ExecStart=/bin/true#' \
    "$repo_root/examples/pve-host-backup.service" >"$temporary/pve-host-backup.service"
  printf '\n' >>"$temporary/pve-host-backup.service"
  cat "$repo_root/examples/pve-host-backup.resources.conf" >>"$temporary/pve-host-backup.service"
  cp "$repo_root/examples/pve-host-backup.timer" "$temporary/pve-host-backup.timer"
  echo "systemd-analyze verify: unites d'exemple"
  systemd-analyze verify \
    "$temporary/pve-host-backup.service" \
    "$temporary/pve-host-backup.timer"
fi

echo "Validation statique terminee."

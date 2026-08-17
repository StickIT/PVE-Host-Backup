#!/usr/bin/env bash
# Desinstallation propre de pve-host-backup.
# Les sauvegardes finales du NAS et le stockage PVE sont conserves.

set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then
  echo "Executer en root." >&2
  exit 1
fi

if [[ ${1:-} != "--yes" ]]; then
  echo "Cette commande supprime le programme et sa planification locale."
  echo "Elle conserve les sauvegardes finales du NAS et le stockage PVE."
  echo
  echo "Pour confirmer: $0 --yes"
  exit 2
fi

CONFIG_FILE="/etc/pve-host-backup.conf"
PVE_NFS_STORAGE="${PVE_NFS_STORAGE:-dreambox-backup}"
EXPECTED_NFS_SOURCE="${EXPECTED_NFS_SOURCE:-192.168.11.133:/volume1/Proxmox}"
STAGING_ROOT="${STAGING_ROOT:-/var/tmp/pve-host-restore}"

if [[ -r "$CONFIG_FILE" ]]; then
  [[ ! -L "$CONFIG_FILE" ]] || {
    echo "$CONFIG_FILE est un lien symbolique; desinstallation refusee." >&2
    exit 1
  }
  [[ $(stat -c '%u' "$CONFIG_FILE") == 0 ]] || {
    echo "$CONFIG_FILE n'appartient pas a root; desinstallation refusee." >&2
    exit 1
  }
  config_mode=$(stat -c '%a' "$CONFIG_FILE")
  (( (8#$config_mode & 8#022) == 0 )) || {
    echo "$CONFIG_FILE a des permissions non sures; desinstallation refusee." >&2
    exit 1
  }
  # Fichier root en mode 0600, cree par l'installateur.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

[[ "$PVE_NFS_STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "PVE_NFS_STORAGE invalide; desinstallation refusee." >&2
  exit 1
}

NFS_MOUNT_ROOT="/mnt/pve/${PVE_NFS_STORAGE}"
BACKUP_ROOT="${BACKUP_ROOT:-${NFS_MOUNT_ROOT}/backups/PVE/host/$(hostname -s)}"
BACKUP_ROOT_CANONICAL=$(readlink -m -- "$BACKUP_ROOT")

case "$BACKUP_ROOT" in
  "$NFS_MOUNT_ROOT"/backups/PVE/host/*) ;;
  *)
    echo "BACKUP_ROOT inattendu; desinstallation refusee: $BACKUP_ROOT" >&2
    exit 1
    ;;
esac
[[ "$BACKUP_ROOT_CANONICAL" == "$BACKUP_ROOT" ]] || {
  echo "BACKUP_ROOT non canonique; desinstallation refusee: $BACKUP_ROOT" >&2
  exit 1
}
[[ "$STAGING_ROOT" =~ ^/var/tmp/pve-host-restore(-[A-Za-z0-9._-]+)?$ ]] || {
  echo "STAGING_ROOT inattendu; desinstallation refusee: $STAGING_ROOT" >&2
  exit 1
}
[[ $(readlink -m -- "$STAGING_ROOT") == "$STAGING_ROOT" ]] || {
  echo "STAGING_ROOT non canonique; desinstallation refusee." >&2
  exit 1
}

echo "Desactivation de la planification..."
systemctl disable --now pve-host-backup.timer >/dev/null 2>&1 || true

if systemctl is-active --quiet pve-host-backup.service; then
  echo "Une sauvegarde est en cours; elle n'a pas ete interrompue." >&2
  echo "Attendre sa fin, puis relancer cette desinstallation." >&2
  exit 1
fi

echo "Suppression des unites systemd..."
rm -f -- \
  /etc/systemd/system/pve-host-backup.timer \
  /etc/systemd/system/pve-host-backup.service \
  /etc/systemd/system/pve-host-backup.service.d/10-resources.conf
rmdir /etc/systemd/system/pve-host-backup.service.d 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed pve-host-backup.service pve-host-backup.timer >/dev/null 2>&1 || true

echo "Suppression des extractions et temporaires locaux..."
if [[ -d "$STAGING_ROOT" ]]; then
  mountpoint -q "$STAGING_ROOT" && {
    echo "Refus: $STAGING_ROOT est un point de montage." >&2
    exit 1
  }
  rm -rf --one-file-system -- "$STAGING_ROOT"
fi

RESTORE_STATE_ROOT=/var/lib/pve-host-restore
if [[ -d "$RESTORE_STATE_ROOT" ]]; then
  mountpoint -q "$RESTORE_STATE_ROOT" && {
    echo "Refus: $RESTORE_STATE_ROOT est un point de montage." >&2
    exit 1
  }
  rm -rf --one-file-system -- "$RESTORE_STATE_ROOT"
fi

while IFS= read -r -d '' path; do
  case "$path" in
    /var/tmp/pve-host-backup.*)
      rm -rf --one-file-system -- "$path"
      ;;
  esac
done < <(find /var/tmp -mindepth 1 -maxdepth 1 -type d -name 'pve-host-backup.*' -print0)

source_nfs=$(findmnt -n -T "$NFS_MOUNT_ROOT" -o SOURCE 2>/dev/null || true)
if [[ "$source_nfs" == "$EXPECTED_NFS_SOURCE" && -d "$BACKUP_ROOT" ]]; then
  echo "Suppression des sauvegardes NFS incompletes uniquement..."
  while IFS= read -r -d '' path; do
    case "$path" in
      "$BACKUP_ROOT"/.partial-*)
        rm -rf --one-file-system -- "$path"
        ;;
    esac
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.partial-*' -print0)
else
  echo "ATTENTION: source NFS non verifiee; aucun fichier du NAS n'a ete supprime."
fi

echo "Suppression du programme et de sa configuration locale..."
rm -f -- \
  /usr/local/sbin/pve-host-backup \
  /usr/local/sbin/pve-host-restore \
  "$CONFIG_FILE" \
  /run/lock/pve-host-backup.lock

if [[ -d /usr/local/share/doc/pve-host-backup ]]; then
  rm -rf --one-file-system -- /usr/local/share/doc/pve-host-backup
fi

echo
echo "Desinstallation terminee."
echo "Conserves volontairement:"
echo "  - les sauvegardes finales sous $BACKUP_ROOT"
echo "  - LAST_RUN_STATUS.txt et LATEST.txt sur le NAS"
echo "  - les dumps VM/CT"
echo "  - le stockage PVE $PVE_NFS_STORAGE"
echo "  - les paquets sqlite3, zstd, gdisk, fdisk et dmidecode"
echo "Les anciennes lignes du journal systemd disparaitront selon la rotation normale."

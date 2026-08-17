#!/usr/bin/env bash
# Supprime uniquement les extractions de test et sauvegardes partielles.
# Les sauvegardes finales datees et les dumps VM/CT sont conserves.

set -Eeuo pipefail
umask 077

CONFIG_FILE="/etc/pve-host-backup.conf"
PVE_NFS_STORAGE="${PVE_NFS_STORAGE:-dreambox-backup}"
EXPECTED_NFS_SOURCE="${EXPECTED_NFS_SOURCE:-192.168.11.133:/volume1/Proxmox}"
STAGING_ROOT="${STAGING_ROOT:-/var/tmp/pve-host-restore}"

[[ ${EUID} -eq 0 ]] || {
  echo "Executer en root." >&2
  exit 1
}

if [[ -r "$CONFIG_FILE" ]]; then
  # Fichier root en mode 0600, cree par l'installateur.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

[[ "$PVE_NFS_STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "PVE_NFS_STORAGE invalide; nettoyage refuse." >&2
  exit 1
}

NFS_MOUNT_ROOT="/mnt/pve/${PVE_NFS_STORAGE}"
BACKUP_ROOT="${BACKUP_ROOT:-${NFS_MOUNT_ROOT}/backups/PVE/host/$(hostname -s)}"

case "$BACKUP_ROOT" in
  "$NFS_MOUNT_ROOT"/backups/PVE/host/*) ;;
  *)
    echo "BACKUP_ROOT inattendu; nettoyage refuse: $BACKUP_ROOT" >&2
    exit 1
    ;;
esac
[[ "$STAGING_ROOT" =~ ^/var/tmp/pve-host-restore(-[A-Za-z0-9._-]+)?$ ]] || {
  echo "STAGING_ROOT inattendu; nettoyage refuse: $STAGING_ROOT" >&2
  exit 1
}

if systemctl is-active --quiet pve-host-backup.service; then
  echo "La sauvegarde est en cours. Nettoyage refuse." >&2
  exit 1
fi

remove_tree_children() {
  local root=$1 path
  [[ -d "$root" ]] || return 0
  mountpoint -q "$root" && {
    echo "Refus: $root est un point de montage." >&2
    exit 1
  }
  while IFS= read -r -d '' path; do
    case "$path" in
      "$root"/*)
        echo "Suppression: $path"
        rm -rf --one-file-system -- "$path"
        ;;
      *)
        echo "Chemin inattendu refuse: $path" >&2
        exit 1
        ;;
    esac
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)
  rmdir "$root" 2>/dev/null || true
}

echo "Nettoyage des extractions de restauration..."
remove_tree_children "$STAGING_ROOT"

echo "Nettoyage des repertoires temporaires locaux..."
while IFS= read -r -d '' path; do
  case "$path" in
    /var/tmp/pve-host-backup.*)
      echo "Suppression: $path"
      rm -rf --one-file-system -- "$path"
      ;;
  esac
done < <(find /var/tmp -mindepth 1 -maxdepth 1 -type d -name 'pve-host-backup.*' -print0)

source_nfs=$(findmnt -n -T "$NFS_MOUNT_ROOT" -o SOURCE 2>/dev/null || true)
if [[ "$source_nfs" == "$EXPECTED_NFS_SOURCE" ]]; then
  echo "Nettoyage des sauvegardes NFS partielles..."
  while IFS= read -r -d '' path; do
    case "$path" in
      "$BACKUP_ROOT"/.partial-*)
        echo "Suppression: $path"
        rm -rf --one-file-system -- "$path"
        ;;
      *)
        echo "Chemin NFS inattendu refuse: $path" >&2
        exit 1
        ;;
    esac
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.partial-*' -print0)
else
  echo "ATTENTION: source NFS non verifiee; les dossiers .partial du NAS sont laisses intacts."
fi

echo
echo "Nettoyage termine. Sauvegardes finales et dumps VM/CT conserves."

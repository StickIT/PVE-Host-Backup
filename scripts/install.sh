#!/usr/bin/env bash
# Installateur autonome de la sauvegarde du host Proxmox VE.
# Peut etre colle en entier dans un shell root sur le host PVE.

set -Eeuo pipefail
umask 077

[[ ${EUID} -eq 0 ]] || {
  echo "Executer cet installateur en root sur PVE." >&2
  exit 1
}

CONFIG_FILE="/etc/pve-host-backup.conf"
OVERWRITE_CONFIG="${OVERWRITE_CONFIG:-0}"
CONFIG_PRESERVED=false
INSTALLER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RESTORE_ASSISTANT_SOURCE="$INSTALLER_DIR/restore-assistant.sh"

[[ "$OVERWRITE_CONFIG" == 0 || "$OVERWRITE_CONFIG" == 1 ]] || {
  echo "OVERWRITE_CONFIG doit valoir 0 ou 1." >&2
  exit 1
}

if [[ -r "$CONFIG_FILE" && "$OVERWRITE_CONFIG" == 0 ]]; then
  [[ ! -L "$CONFIG_FILE" ]] || {
    echo "$CONFIG_FILE est un lien symbolique; chargement refuse." >&2
    exit 1
  }
  [[ $(stat -c '%u' "$CONFIG_FILE") == 0 ]] || {
    echo "$CONFIG_FILE n'appartient pas a root; chargement refuse." >&2
    exit 1
  }
  config_mode=$(stat -c '%a' "$CONFIG_FILE")
  (( (8#$config_mode & 8#022) == 0 )) || {
    echo "$CONFIG_FILE est modifiable par le groupe ou les autres; chargement refuse." >&2
    exit 1
  }
  # Configuration creee par l'installateur et protegee en mode 0600.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  CONFIG_PRESERVED=true
fi

PVE_NFS_STORAGE="${PVE_NFS_STORAGE:-dreambox-backup}"
EXPECTED_NFS_SOURCE="${EXPECTED_NFS_SOURCE:-192.168.11.133:/volume1/Proxmox}"
NFS_MOUNT_ROOT="/mnt/pve/${PVE_NFS_STORAGE}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
MIN_FREE_KIB="${MIN_FREE_KIB:-5242880}"
ZSTD_THREADS="${ZSTD_THREADS:-2}"
CPU_QUOTA_PERCENT="${CPU_QUOTA_PERCENT:-200}"
MEMORY_HIGH="${MEMORY_HIGH:-2G}"
MEMORY_MAX="${MEMORY_MAX:-0}"
STAGING_ROOT="${STAGING_ROOT:-/var/tmp/pve-host-restore}"
MAIL_TO="${MAIL_TO:-root}"

# Migration automatique depuis la configuration 1.0.0.
if [[ -z ${BACKUP_TIME:-} && ${TIMER_CALENDAR:-} =~ ([0-9]{2}):([0-9]{2})(:[0-9]{2})?$ ]]; then
  BACKUP_TIME="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
fi
BACKUP_TIME="${BACKUP_TIME:-04:15}"
NOTIFY_SUCCESS="${NOTIFY_SUCCESS:-0}"

size_to_bytes() {
  local value=$1 number unit multiplier
  [[ "$value" == 0 ]] && { printf '0\n'; return; }
  number=${value%?}
  unit=${value: -1}
  case "$unit" in
    K) multiplier=1024 ;;
    M) multiplier=$((1024 * 1024)) ;;
    G) multiplier=$((1024 * 1024 * 1024)) ;;
    T) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$((number * multiplier))"
}

[[ -d /etc/pve ]] || {
  echo "/etc/pve est absent : ce systeme ne semble pas etre un host PVE." >&2
  exit 1
}
if systemctl is-active --quiet pve-host-backup.service 2>/dev/null; then
  echo "Une sauvegarde du host est en cours. Attendre sa fin avant la mise a jour." >&2
  exit 1
fi

HOST_SHORT=$(hostname -s)
CPU_AVAILABLE=$(nproc)
[[ "$HOST_SHORT" == nukebox ]] || {
  echo "La version 1.3.0 est personnalisee pour le host nukebox; host detecte: $HOST_SHORT" >&2
  exit 1
}
[[ ! -e /etc/pve/corosync.conf ]] || {
  echo "La version 1.3.0 personnalisee refuse une installation sur un cluster." >&2
  exit 1
}
PVE_MANAGER_DETECTED=$(pveversion -v 2>/dev/null |
  awk '$1 == "pve-manager:" && !found {print $2; found=1}') || true
[[ ${PVE_MANAGER_DETECTED%%.*} == 9 ]] || {
  echo "PVE 9 est requis pour ce profil; pve-manager detecte: ${PVE_MANAGER_DETECTED:-inconnu}" >&2
  exit 1
}
DEBIAN_DETECTED=$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")
[[ "$DEBIAN_DETECTED" == 13 ]] || {
  echo "Debian 13 est requis pour ce profil; version detectee: ${DEBIAN_DETECTED:-inconnue}" >&2
  exit 1
}
if [[ "$PVE_MANAGER_DETECTED" != 9.2.10 ]]; then
  echo "ATTENTION: l'assistant 1.3.0 est audite pour pve-manager 9.2.10; version detectee: $PVE_MANAGER_DETECTED" >&2
  echo "Les sauvegardes restent possibles, mais la restauration ne pourra pas obtenir un verdict vert sans nouvel audit." >&2
fi
BACKUP_ROOT="${BACKUP_ROOT:-${NFS_MOUNT_ROOT}/backups/PVE/host/${HOST_SHORT}}"
BACKUP_ROOT_CANONICAL=$(readlink -m -- "$BACKUP_ROOT")
[[ "$BACKUP_ROOT_CANONICAL" == "$BACKUP_ROOT" && \
  "$BACKUP_ROOT_CANONICAL" == "$NFS_MOUNT_ROOT"/backups/PVE/host/* ]] || {
  echo "BACKUP_ROOT doit etre un chemin canonique sous $NFS_MOUNT_ROOT/backups/PVE/host/." >&2
  exit 1
}

[[ "$PVE_NFS_STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "PVE_NFS_STORAGE contient des caracteres non autorises." >&2
  exit 1
}
[[ "$EXPECTED_NFS_SOURCE" =~ ^[^[:space:]:]+:/[^[:space:]]+$ ]] || {
  echo "EXPECTED_NFS_SOURCE doit avoir la forme serveur:/export." >&2
  exit 1
}
[[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || {
  echo "KEEP_BACKUPS doit etre un entier superieur a zero." >&2
  exit 1
}
[[ "$MIN_FREE_KIB" =~ ^[1-9][0-9]*$ ]] || {
  echo "MIN_FREE_KIB doit etre un entier superieur a zero." >&2
  exit 1
}
[[ "$ZSTD_THREADS" =~ ^[1-9][0-9]*$ ]] || {
  echo "ZSTD_THREADS doit etre un entier superieur a zero." >&2
  exit 1
}
(( ZSTD_THREADS <= CPU_AVAILABLE )) || {
  echo "ZSTD_THREADS ne peut pas depasser les ${CPU_AVAILABLE} coeurs logiques detectes." >&2
  exit 1
}
[[ "$CPU_QUOTA_PERCENT" =~ ^(0|[1-9][0-9]{0,4})$ ]] || {
  echo "CPU_QUOTA_PERCENT doit valoir 0 ou un pourcentage positif (100 = un coeur)." >&2
  exit 1
}
if [[ "$CPU_QUOTA_PERCENT" != 0 ]] && (( CPU_QUOTA_PERCENT > CPU_AVAILABLE * 100 )); then
  echo "CPU_QUOTA_PERCENT ne peut pas depasser $((CPU_AVAILABLE * 100))% sur ce host." >&2
  exit 1
fi
[[ "$MEMORY_HIGH" =~ ^(0|[1-9][0-9]{0,4}[KMGT])$ ]] || {
  echo "MEMORY_HIGH doit valoir 0 ou une taille comme 2G." >&2
  exit 1
}
[[ "$MEMORY_MAX" =~ ^(0|[1-9][0-9]{0,4}[KMGT])$ ]] || {
  echo "MEMORY_MAX doit valoir 0 ou une taille comme 3G." >&2
  exit 1
}
if [[ "$MEMORY_HIGH" != 0 && "$MEMORY_MAX" != 0 ]] &&
  (( $(size_to_bytes "$MEMORY_HIGH") > $(size_to_bytes "$MEMORY_MAX") )); then
  echo "MEMORY_HIGH ne peut pas depasser MEMORY_MAX." >&2
  exit 1
fi
if [[ ! "$BACKUP_TIME" =~ ^[0-9]{2}:[0-9]{2}$ ]] ||
  ((10#${BACKUP_TIME%%:*} > 23 || 10#${BACKUP_TIME##*:} > 59)); then
  echo "BACKUP_TIME doit avoir la forme HH:MM, par exemple 04:15." >&2
  exit 1
fi
[[ "$NOTIFY_SUCCESS" == 0 || "$NOTIFY_SUCCESS" == 1 ]] || {
  echo "NOTIFY_SUCCESS doit valoir 0 (erreurs uniquement) ou 1." >&2
  exit 1
}
[[ "$STAGING_ROOT" =~ ^/var/tmp/pve-host-restore(-[A-Za-z0-9._-]+)?$ ]] || {
  echo "STAGING_ROOT doit etre un repertoire dedie sous /var/tmp." >&2
  exit 1
}
[[ $(readlink -m -- "$STAGING_ROOT") == "$STAGING_ROOT" ]] || {
  echo "STAGING_ROOT ne doit pas traverser un lien symbolique." >&2
  exit 1
}
[[ -r "$RESTORE_ASSISTANT_SOURCE" ]] || {
  echo "Assistant de restauration absent: $RESTORE_ASSISTANT_SOURCE" >&2
  echo "Installer depuis le depot complet, avec les deux scripts dans le meme dossier." >&2
  exit 1
}
bash -n "$RESTORE_ASSISTANT_SOURCE"

INSTALL_CRON_FILE=/etc/cron.d/pve-host-backup
if [[ -e "$INSTALL_CRON_FILE" || -L "$INSTALL_CRON_FILE" ]]; then
  [[ -f "$INSTALL_CRON_FILE" && ! -L "$INSTALL_CRON_FILE" ]] || {
    echo "$INSTALL_CRON_FILE n'est pas un fichier regulier; installation refusee." >&2
    exit 1
  }
  [[ $(stat -c '%u' "$INSTALL_CRON_FILE") == 0 ]] || {
    echo "$INSTALL_CRON_FILE n'appartient pas a root; installation refusee." >&2
    exit 1
  }
  install_cron_mode=$(stat -c '%a' "$INSTALL_CRON_FILE")
  (( (8#$install_cron_mode & 8#022) == 0 )) || {
    echo "$INSTALL_CRON_FILE est modifiable par le groupe ou les autres; installation refusee." >&2
    exit 1
  }
  grep -Fxq '# Managed by pve-host-backup' "$INSTALL_CRON_FILE" || {
    echo "$INSTALL_CRON_FILE existe mais n'est pas gere par ce projet; installation refusee." >&2
    exit 1
  }
fi

echo "Installation des dependances..."
apt-get update
apt-get install -y sqlite3 zstd gdisk fdisk dmidecode cron

install -d -m 0755 \
  /usr/local/sbin \
  /usr/local/share/doc/pve-host-backup \
  /etc/cron.d \
  /etc/systemd/system/pve-host-backup.service.d

install_stamp=$(date +%Y%m%d-%H%M%S)
for installed_file in \
  /usr/local/sbin/pve-host-backup \
  /usr/local/sbin/pve-host-restore \
  /etc/pve-host-backup.conf \
  /etc/cron.d/pve-host-backup \
  /etc/systemd/system/pve-host-backup.service \
  /etc/systemd/system/pve-host-backup.service.d/10-resources.conf \
  /etc/systemd/system/pve-host-backup.timer; do
  if [[ -f "$installed_file" ]]; then
    installed_backup_name=${installed_file#/}
    installed_backup_name=${installed_backup_name//\//_}
    cp -a -- "$installed_file" \
      "/usr/local/share/doc/pve-host-backup/${installed_backup_name}.before-install-${install_stamp}"
  fi
done

# Neutralise l'ancienne planification avant de remplacer les programmes.
systemctl disable --now pve-host-backup.timer >/dev/null 2>&1 || true
if [[ -f "$INSTALL_CRON_FILE" ]] &&
  grep -Fxq '# Managed by pve-host-backup' "$INSTALL_CRON_FILE"; then
  rm -f -- "$INSTALL_CRON_FILE"
fi

install -m 0750 "$RESTORE_ASSISTANT_SOURCE" /usr/local/sbin/pve-host-restore

install -m 0750 /dev/stdin /usr/local/sbin/pve-host-backup <<'PVE_HOST_BACKUP_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

VERSION="1.3.0"
CONFIG_FILE="/etc/pve-host-backup.conf"
LOCK_FILE="/run/lock/pve-host-backup.lock"
RESTORE_TOOL="/usr/local/sbin/pve-host-restore"
CRON_FILE="/etc/cron.d/pve-host-backup"

PVE_NFS_STORAGE=""
EXPECTED_NFS_SOURCE=""
BACKUP_ROOT=""
KEEP_BACKUPS=""
MIN_FREE_KIB=""
ZSTD_THREADS=""
CPU_QUOTA_PERCENT=""
MEMORY_HIGH=""
MEMORY_MAX=""
STAGING_ROOT=""
MAIL_TO=""
BACKUP_TIME=""
NOTIFY_SUCCESS=""

TARGET_VERIFIED=false
RUN_ACTIVE=false
RUN_SUCCESS=false
RUN_STARTED_AT=""
RUN_DESTINATION=""
RUN_PARTIAL=""
LAST_ERROR="erreur inconnue"
CLEANUP_PATHS=()
RESOLVED_BACKUP=""

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

warn() {
  printf 'ATTENTION: %s\n' "$*" >&2
}

die() {
  LAST_ERROR=$*
  printf 'ERREUR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Executer cette commande en root."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Commande requise absente: $1"
}

load_config() {
  local canonical config_mode available_cpu
  [[ -r "$CONFIG_FILE" ]] || die "Configuration absente: $CONFIG_FILE"
  [[ ! -L "$CONFIG_FILE" ]] || die "$CONFIG_FILE est un lien symbolique."
  [[ $(stat -c '%u' "$CONFIG_FILE") == 0 ]] || die "$CONFIG_FILE n'appartient pas a root."
  config_mode=$(stat -c '%a' "$CONFIG_FILE")
  (( (8#$config_mode & 8#022) == 0 )) || die "$CONFIG_FILE a des permissions non sures."
  # Configuration creee par root et protegee en mode 0600.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  BACKUP_TIME="${BACKUP_TIME:-04:15}"
  NOTIFY_SUCCESS="${NOTIFY_SUCCESS:-0}"

  : "${PVE_NFS_STORAGE:?PVE_NFS_STORAGE absent}"
  : "${EXPECTED_NFS_SOURCE:?EXPECTED_NFS_SOURCE absent}"
  : "${BACKUP_ROOT:?BACKUP_ROOT absent}"
  : "${KEEP_BACKUPS:?KEEP_BACKUPS absent}"
  : "${MIN_FREE_KIB:?MIN_FREE_KIB absent}"
  : "${ZSTD_THREADS:?ZSTD_THREADS absent}"
  CPU_QUOTA_PERCENT="${CPU_QUOTA_PERCENT:-200}"
  MEMORY_HIGH="${MEMORY_HIGH:-2G}"
  MEMORY_MAX="${MEMORY_MAX:-0}"
  : "${STAGING_ROOT:?STAGING_ROOT absent}"
  : "${MAIL_TO:?MAIL_TO absent}"

  [[ "$PVE_NFS_STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "PVE_NFS_STORAGE invalide."
  [[ "$EXPECTED_NFS_SOURCE" =~ ^[^[:space:]:]+:/[^[:space:]]+$ ]] ||
    die "EXPECTED_NFS_SOURCE invalide."
  [[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || die "KEEP_BACKUPS invalide."
  [[ "$MIN_FREE_KIB" =~ ^[1-9][0-9]*$ ]] || die "MIN_FREE_KIB invalide."
  [[ "$ZSTD_THREADS" =~ ^[1-9][0-9]*$ ]] || die "ZSTD_THREADS invalide."
  available_cpu=$(nproc)
  (( ZSTD_THREADS <= available_cpu )) || die "ZSTD_THREADS depasse les coeurs disponibles."
  [[ "$CPU_QUOTA_PERCENT" =~ ^(0|[1-9][0-9]{0,4})$ ]] ||
    die "CPU_QUOTA_PERCENT invalide."
  if [[ "$CPU_QUOTA_PERCENT" != 0 ]] && (( CPU_QUOTA_PERCENT > available_cpu * 100 )); then
    die "CPU_QUOTA_PERCENT depasse la capacite CPU du host."
  fi
  [[ "$MEMORY_HIGH" =~ ^(0|[1-9][0-9]{0,4}[KMGT])$ ]] || die "MEMORY_HIGH invalide."
  [[ "$MEMORY_MAX" =~ ^(0|[1-9][0-9]{0,4}[KMGT])$ ]] || die "MEMORY_MAX invalide."
  if [[ "$MEMORY_HIGH" != 0 && "$MEMORY_MAX" != 0 ]] &&
    (( $(size_to_bytes "$MEMORY_HIGH") > $(size_to_bytes "$MEMORY_MAX") )); then
    die "MEMORY_HIGH ne peut pas depasser MEMORY_MAX."
  fi
  if [[ ! "$BACKUP_TIME" =~ ^[0-9]{2}:[0-9]{2}$ ]] ||
    ((10#${BACKUP_TIME%%:*} > 23 || 10#${BACKUP_TIME##*:} > 59)); then
    die "BACKUP_TIME doit avoir la forme HH:MM."
  fi
  [[ "$NOTIFY_SUCCESS" == 0 || "$NOTIFY_SUCCESS" == 1 ]] ||
    die "NOTIFY_SUCCESS doit valoir 0 ou 1."
  [[ "$STAGING_ROOT" =~ ^/var/tmp/pve-host-restore(-[A-Za-z0-9._-]+)?$ ]] ||
    die "STAGING_ROOT doit etre un repertoire dedie sous /var/tmp."
  [[ $(readlink -m -- "$STAGING_ROOT") == "$STAGING_ROOT" ]] ||
    die "STAGING_ROOT ne doit pas traverser un lien symbolique."
  canonical=$(readlink -m -- "$BACKUP_ROOT")
  [[ "$canonical" == "$BACKUP_ROOT" && \
    "$canonical" == /mnt/pve/"$PVE_NFS_STORAGE"/backups/PVE/host/* ]] ||
    die "BACKUP_ROOT n'est pas un chemin canonique autorise."
}

size_to_bytes() {
  local value=$1 number unit multiplier
  [[ "$value" == 0 ]] && { printf '0\n'; return; }
  number=${value%?}
  unit=${value: -1}
  case "$unit" in
    K) multiplier=1024 ;;
    M) multiplier=$((1024 * 1024)) ;;
    G) multiplier=$((1024 * 1024 * 1024)) ;;
    T) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$((number * multiplier))"
}

send_notification() {
  local state=$1 subject=$2 body=$3 sendmail_bin
  sendmail_bin=$(command -v sendmail 2>/dev/null || true)
  [[ -n "$sendmail_bin" ]] || {
    warn "sendmail absent; notification non remise."
    return 0
  }

  {
    printf 'To: %s\n' "$MAIL_TO"
    printf 'Subject: [%s] %s\n' "$state" "$subject"
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf '\n%s\n' "$body"
  } | "$sendmail_bin" -t
}

write_status() {
  local state=$1 backup=$2 detail=$3 temporary
  [[ "$TARGET_VERIFIED" == true ]] || return 0
  temporary="$BACKUP_ROOT/.LAST_RUN_STATUS.txt.$$"
  {
    printf 'STATUS=%s\n' "$state"
    printf 'UPDATED_AT=%s\n' "$(date -Is)"
    printf 'HOST=%s\n' "$(hostname)"
    printf 'BACKUP=%s\n' "$backup"
    printf 'DETAIL=%s\n' "$detail"
    printf 'SCRIPT_VERSION=%s\n' "$VERSION"
  } >"$temporary"
  mv -- "$temporary" "$BACKUP_ROOT/LAST_RUN_STATUS.txt"
}

cleanup() {
  local path
  for path in "${CLEANUP_PATHS[@]:-}"; do
    case "$path" in
      /var/tmp/pve-host-backup.*)
        [[ -d "$path" ]] && rm -rf --one-file-system -- "$path" || true
        ;;
    esac
  done

  if [[ -n "$RUN_PARTIAL" && -d "$RUN_PARTIAL" ]]; then
    case "$RUN_PARTIAL" in
      "$BACKUP_ROOT"/.partial-*)
        warn "Suppression de la sauvegarde temporaire incomplete: $RUN_PARTIAL"
        rm -rf --one-file-system -- "$RUN_PARTIAL" || true
        ;;
    esac
  fi
}

on_error() {
  local rc=$?
  [[ "$LAST_ERROR" != "erreur inconnue" ]] ||
    LAST_ERROR="ligne ${BASH_LINENO[0]:-inconnue}: ${BASH_COMMAND:-commande inconnue}"
  return "$rc"
}

on_exit() {
  local rc=$?
  trap - EXIT
  cleanup

  if [[ "$RUN_ACTIVE" == true ]]; then
    if ((rc == 0)) && [[ "$RUN_SUCCESS" == true ]]; then
      if [[ "$NOTIFY_SUCCESS" == 1 ]]; then
        send_notification SUCCESS "Sauvegarde du host terminee" \
          "Host=$(hostname); destination=$RUN_DESTINATION; debut=$RUN_STARTED_AT; fin=$(date -Is)" || true
      fi
    else
      write_status FAILURE "${RUN_DESTINATION:-aucun}" "$LAST_ERROR" || true
      send_notification FAILURE "Echec de la sauvegarde du host" \
        "Host=$(hostname); debut=${RUN_STARTED_AT:-inconnu}; erreur=$LAST_ERROR. Consulter journalctl -u pve-host-backup.service." || true
    fi
  fi
  exit "$rc"
}

trap on_error ERR
trap on_exit EXIT

check_target() {
  local test_write=${1:-false}
  local mount_root="/mnt/pve/${PVE_NFS_STORAGE}" fs_type source probe

  [[ -d /etc/pve ]] || die "/etc/pve est absent: ce systeme ne semble pas etre PVE."

  # Provoque le montage gere par PVE si necessaire.
  pvesm status --storage "$PVE_NFS_STORAGE" >/dev/null 2>&1 || true
  [[ -d "$mount_root" ]] || die "Point de montage absent: $mount_root"

  fs_type=$(findmnt -n -T "$mount_root" -o FSTYPE 2>/dev/null || true)
  [[ "$fs_type" == nfs || "$fs_type" == nfs4 ]] ||
    die "$mount_root n'est pas monte en NFS; refus d'ecrire sur le disque local."

  source=$(findmnt -n -T "$mount_root" -o SOURCE 2>/dev/null || true)
  [[ "$source" == "$EXPECTED_NFS_SOURCE" ]] ||
    die "Source NFS inattendue: ${source:-absente}; attendu: $EXPECTED_NFS_SOURCE"

  case "$BACKUP_ROOT" in
    "$mount_root"/backups/PVE/host/*) ;;
    *) die "BACKUP_ROOT doit rester sous $mount_root/backups/PVE/host/." ;;
  esac

  install -d -m 0700 "$BACKUP_ROOT"
  TARGET_VERIFIED=true

  if [[ "$test_write" == true ]]; then
    probe=$(mktemp "$BACKUP_ROOT/.write-test.XXXXXX")
    printf 'test %s\n' "$(date -Is)" >"$probe"
    rm -f -- "$probe"
  fi
}

check_free_space() {
  local available
  available=$(df -Pk "$BACKUP_ROOT" | awk 'NR == 2 {print $4}')
  [[ "$available" =~ ^[0-9]+$ ]] || die "Impossible de lire l'espace disponible."
  (( available >= MIN_FREE_KIB )) ||
    die "Espace insuffisant: ${available} KiB disponibles; minimum ${MIN_FREE_KIB} KiB."
}

acquire_lock() {
  install -d -m 0755 "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Une autre sauvegarde du host est deja en cours."
}

run_to_file() {
  local output=$1
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"$output" 2>&1 || true
}

copy_critical_paths() {
  local target=$1 path
  shift
  for path in "$@"; do
    [[ -e "$path" || -L "$path" ]] || continue
    cp -a --parents -- "$path" "$target/"
  done
}

create_guest_inventory() {
  local target=$1 id
  install -d -m 0700 "$target/qemu" "$target/lxc"
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    qm config "$id" >"$target/qemu/${id}.conf" 2>&1 || true
  done < <(qm list 2>/dev/null | awk 'NR > 1 {print $1}')
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    pct config "$id" >"$target/lxc/${id}.conf" 2>&1 || true
  done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1}')
}

create_partition_inventory() {
  local target=$1 disk safe_name
  install -d -m 0700 "$target"
  while read -r disk; do
    [[ -b "$disk" ]] || continue
    safe_name=${disk#/dev/}
    safe_name=${safe_name//\//_}
    sfdisk --dump "$disk" >"$target/${safe_name}.sfdisk" 2>"$target/${safe_name}.sfdisk.err" || true
    if command -v sgdisk >/dev/null 2>&1; then
      sgdisk --backup="$target/${safe_name}.gpt" "$disk" >"$target/${safe_name}.gpt.log" 2>&1 || true
    fi
  done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')
}

one_line() {
  tr '\n\r\t' '   ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//'
}

create_restore_profile() {
  local output=$1 pve_manager pve_docs debian_id cpu_model cpu_threads memory_bytes
  local dmi_product dmi_serial boot_mode boot_manager cluster_mode root_source
  local root_fstype root_uuid system_disk disk_size disk_model disk_serial
  local network_address network_gateway bridge_ports bond_slaves timezone

  pve_manager=$(pveversion -v 2>/dev/null |
    awk '$1 == "pve-manager:" && !found {print $2; found=1}') || true
  pve_docs=$(dpkg-query -W -f='${Version}' pve-docs 2>/dev/null || true)
  debian_id=$(. /etc/os-release; printf '%s' "${VERSION_ID:-inconnu}")
  cpu_threads=$(nproc 2>/dev/null || true)
  cpu_model=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1 | one_line) || true
  memory_bytes=$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)
  dmi_product=$(dmidecode -s system-product-name 2>/dev/null | head -n 1 | one_line) || true
  dmi_serial=$(dmidecode -s system-serial-number 2>/dev/null | head -n 1 | one_line) || true
  [[ -d /sys/firmware/efi ]] && boot_mode=UEFI || boot_mode=BIOS
  [[ -e /etc/kernel/proxmox-boot-uuids ]] && boot_manager=proxmox-boot-tool || boot_manager=grub
  [[ -e /etc/pve/corosync.conf ]] && cluster_mode=cluster || cluster_mode=standalone
  root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
  root_uuid=$(findmnt -n -o UUID / 2>/dev/null || true)
  system_disk=$(lsblk -snp -o PATH,TYPE "$root_source" 2>/dev/null |
    awk '$2 == "disk" {print $1; exit}') || true
  disk_size="" disk_model="" disk_serial=""
  if [[ -n "$system_disk" && -b "$system_disk" ]]; then
    disk_size=$(blockdev --getsize64 "$system_disk" 2>/dev/null || true)
    disk_model=$(lsblk -dn -o MODEL "$system_disk" 2>/dev/null | one_line) || true
    disk_serial=$(lsblk -dn -o SERIAL "$system_disk" 2>/dev/null | one_line) || true
  fi
  network_address=$(awk '$1 == "address" {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
  network_gateway=$(awk '$1 == "gateway" {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)
  bridge_ports=$(awk '$1 == "bridge-ports" {for (i=2;i<=NF;i++) printf "%s%s", (i==2?"":" "), $i; exit}' /etc/network/interfaces 2>/dev/null || true)
  bond_slaves=$(awk '$1 == "bond-slaves" {for (i=2;i<=NF;i++) printf "%s%s", (i==2?"":" "), $i; exit}' /etc/network/interfaces 2>/dev/null || true)
  timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)

  {
    printf 'FORMAT=1\n'
    printf 'CAPTURED_AT=%s\n' "$(date -Is)"
    printf 'HOSTNAME=%s\n' "$(hostname -s)"
    printf 'PVE_MANAGER=%s\n' "$pve_manager"
    printf 'PVE_DOCS=%s\n' "$pve_docs"
    printf 'DEBIAN_VERSION_ID=%s\n' "$debian_id"
    printf 'KERNEL=%s\n' "$(uname -r)"
    printf 'CLUSTER_MODE=%s\n' "$cluster_mode"
    printf 'CPU_THREADS=%s\n' "$cpu_threads"
    printf 'CPU_MODEL=%s\n' "$cpu_model"
    printf 'MEMORY_BYTES=%s\n' "$memory_bytes"
    printf 'DMI_PRODUCT=%s\n' "$dmi_product"
    printf 'DMI_SERIAL=%s\n' "$dmi_serial"
    printf 'BOOT_MODE=%s\n' "$boot_mode"
    printf 'BOOT_MANAGER=%s\n' "$boot_manager"
    printf 'ROOT_SOURCE=%s\n' "$root_source"
    printf 'ROOT_FSTYPE=%s\n' "$root_fstype"
    printf 'ROOT_UUID=%s\n' "$root_uuid"
    printf 'SYSTEM_DISK=%s\n' "$system_disk"
    printf 'SYSTEM_DISK_SIZE=%s\n' "$disk_size"
    printf 'SYSTEM_DISK_MODEL=%s\n' "$disk_model"
    printf 'SYSTEM_DISK_SERIAL=%s\n' "$disk_serial"
    printf 'NETWORK_ADDRESS=%s\n' "$network_address"
    printf 'NETWORK_GATEWAY=%s\n' "$network_gateway"
    printf 'NETWORK_BRIDGE_PORTS=%s\n' "$bridge_ports"
    printf 'NETWORK_BOND_SLAVES=%s\n' "$bond_slaves"
    printf 'TIMEZONE=%s\n' "$timezone"
    printf 'NFS_STORAGE=%s\n' "$PVE_NFS_STORAGE"
    printf 'NFS_SOURCE=%s\n' "$EXPECTED_NFS_SOURCE"
  } >"$output"
}

show_manual() {
  local nfs_server nfs_export
  nfs_server=${EXPECTED_NFS_SOURCE%%:*}
  nfs_export=${EXPECTED_NFS_SOURCE#*:}

  cat <<MANUAL
MANUEL DE RESTAURATION DU HOST PVE $(hostname -s)

Nature de la sauvegarde
-----------------------
Cette sauvegarde est autonome et lisible avec tar/zstd. Elle contient le
systeme du host, /etc/pve, le boot, une copie SQLite coherente de config.db,
les inventaires materiels et les outils de reprise. Elle ne contient pas les
disques des VM/CT ni les montages externes. Ce n'est pas une image bare-metal.

Reglages simples
----------------
Afficher les reglages :

   pve-host-backup settings

Modifier l'heure, la retention et les notifications de succes :

   pve-host-backup configure

Les erreurs restent toujours notifiees avec leur detail.

Ordre recommande apres une perte totale
----------------------------------------
1. Reinstaller PVE avec une version majeure compatible et le meme nom de node.
2. Retablir le reseau et reconnecter le stockage NFS ${PVE_NFS_STORAGE}.
   Parametres de cette installation :

   serveur : ${nfs_server}
   export  : ${nfs_export}
   montage : /mnt/pve/${PVE_NFS_STORAGE}
   host    : ${BACKUP_ROOT}

   La definition PVE du stockage guests reste une operation distincte. Dans
   cette architecture, content-dirs vaut backup=backups/PVE/guests.

3. Copier les outils du dernier dossier date vers :

   install -m 0750 pve-host-backup /usr/local/sbin/pve-host-backup
   install -m 0750 pve-host-restore /usr/local/sbin/pve-host-restore

   Copier egalement pve-host-backup.conf vers /etc/pve-host-backup.conf.

4. Verifier les archives :

   pve-host-backup verify latest

5. Extraire uniquement dans la zone de staging :

   pve-host-backup stage latest

   Puis lancer d'abord l'audit sans ecriture :

   pve-host-restore audit latest

   Le wizard prudent est disponible apres un verdict compatible :

   pve-host-restore wizard latest

6. Le chemin de staging est affiche sous /var/tmp/pve-host-restore.
   Comparer les fichiers avant toute copie vers le systeme reel.

Contenu du staging
------------------
- rootfs/    : systeme principal, dont /etc/network, /etc/fstab et /etc/apt.
- etc-pve/   : contenu sauvegarde de /etc/pve.
- boot/      : partition /boot si elle etait separee.
- boot-efi/  : partition EFI si elle etait montee separement.
- recovery/  : config.db coherent, inventaires, configurations et outils.

Regles de restauration
-----------------------
- Ne jamais extraire rootfs.tar.zst directement sur /.
- Ne jamais remplacer automatiquement config.db, le reseau, fstab ou GRUB.
- Comparer d'abord, par exemple :

  diff -ruN /etc/network <STAGING>/rootfs/etc/network
  diff -u /etc/pve/storage.cfg <STAGING>/etc-pve/storage.cfg

- Restaurer le reseau uniquement depuis la console locale; une erreur peut
  couper SSH et l'interface web.
- Si les guests sont restaures depuis leurs dumps PVE, ne pas creer leurs
  fichiers .conf avant la restauration des dumps.
- La copie coherente de config.db se trouve sous :
  recovery/critical/var/lib/pve-cluster/config.db
- Son remplacement complet est une operation avancee qui ne doit pas etre
  automatisee. Sur un cluster, demander une procedure adaptee a Proxmox.
- Apres restauration de reglages de boot, verifier puis executer si necessaire :

  update-initramfs -u -k all
  update-grub
  proxmox-boot-tool refresh

Retour arriere
--------------
Avant toute copie manuelle, conserver la version actuelle du fichier avec un
suffixe .before-restore. Restaurer un bloc a la fois, verifier PVE, puis passer
au bloc suivant.
MANUAL
}

create_recovery_metadata() {
  local target=$1 db_src=/var/lib/pve-cluster/config.db
  local db_dst="$target/critical/var/lib/pve-cluster/config.db"

  install -d -m 0700 "$target/critical/var/lib/pve-cluster" "$target/inventory" "$target/tools"
  sqlite3 "$db_src" ".backup '$db_dst'"
  sqlite3 "$db_dst" 'PRAGMA integrity_check;' >"$target/inventory/config-db-integrity.txt"
  grep -qx 'ok' "$target/inventory/config-db-integrity.txt" ||
    die "La copie SQLite de config.db n'a pas passe integrity_check."

  copy_critical_paths "$target/critical" \
    /etc/network /etc/hosts /etc/hostname /etc/resolv.conf /etc/fstab \
    /etc/modules /etc/modules-load.d /etc/modprobe.d /etc/default/grub \
    /etc/kernel /etc/apt /etc/vzdump.conf /etc/udev/rules.d \
    /etc/systemd/system /etc/cron.d /etc/cron.daily /etc/cron.weekly \
    /etc/cron.monthly /var/spool/cron /usr/local/bin /usr/local/sbin \
    "$CONFIG_FILE"

  run_to_file "$target/inventory/pveversion.txt" pveversion -v
  create_restore_profile "$target/inventory/restore-profile.txt"
  run_to_file "$target/inventory/os-release.txt" cat /etc/os-release
  run_to_file "$target/inventory/hostnamectl.txt" hostnamectl
  run_to_file "$target/inventory/systemd-version.txt" systemctl --version
  run_to_file "$target/inventory/lscpu.txt" lscpu
  run_to_file "$target/inventory/memory.txt" free -b
  run_to_file "$target/inventory/dmi-system.txt" dmidecode -t system
  run_to_file "$target/inventory/packages.txt" dpkg-query -W -f='${binary:Package}\t${Version}\n'
  run_to_file "$target/inventory/pvesm-status.txt" pvesm status
  run_to_file "$target/inventory/storage-config.txt" pvesh get /storage --output-format yaml
  run_to_file "$target/inventory/backup-jobs.txt" pvesh get /cluster/backup --output-format yaml
  run_to_file "$target/inventory/qm-list.txt" qm list
  run_to_file "$target/inventory/pct-list.txt" pct list
  run_to_file "$target/inventory/ip-address.txt" ip -details address show
  run_to_file "$target/inventory/ip-route.txt" ip route show table all
  run_to_file "$target/inventory/bridge-link.txt" bridge -details link show
  run_to_file "$target/inventory/bridge-vlan.txt" bridge vlan show
  run_to_file "$target/inventory/findmnt.txt" findmnt --all
  run_to_file "$target/inventory/lsblk.txt" lsblk -e 7 -o NAME,KNAME,PATH,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS,MODEL,SERIAL
  run_to_file "$target/inventory/blkid.txt" blkid
  run_to_file "$target/inventory/df.txt" df -hT
  run_to_file "$target/inventory/lspci.txt" lspci -nnk
  run_to_file "$target/inventory/lsusb.txt" lsusb
  run_to_file "$target/inventory/pvs.txt" pvs -a -o +devices
  run_to_file "$target/inventory/vgs.txt" vgs -a
  run_to_file "$target/inventory/lvs.txt" lvs -a -o +devices
  run_to_file "$target/inventory/zpool.txt" zpool status -v
  run_to_file "$target/inventory/zfs.txt" zfs list -t all
  run_to_file "$target/inventory/boot-tool.txt" proxmox-boot-tool status
  run_to_file "$target/inventory/timedatectl.txt" timedatectl
  run_to_file "$target/inventory/efibootmgr.txt" efibootmgr -v
  run_to_file "$target/inventory/systemctl-enabled.txt" systemctl list-unit-files --state=enabled
  run_to_file "$target/inventory/timers.txt" systemctl list-timers --all

  create_guest_inventory "$target/inventory/guest-configs"
  create_partition_inventory "$target/inventory/partition-tables"
  cp -a -- "$0" "$target/tools/pve-host-backup"
  [[ -x "$RESTORE_TOOL" ]] && cp -a -- "$RESTORE_TOOL" "$target/tools/pve-host-restore"
  show_manual >"$target/tools/RESTORE_HOST_PVE.txt"

  {
    printf 'Sauvegarde autonome du host PVE\n'
    printf 'Version du script : %s\n' "$VERSION"
    if [[ -x "$RESTORE_TOOL" ]]; then
      printf 'Assistant reprise : %s\n' "$("$RESTORE_TOOL" --help | head -n 1)"
    fi
    printf 'Cree le           : %s\n' "$(date -Is)"
    printf 'Hote              : %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'Destination       : %s\n' "$BACKUP_ROOT"
    printf 'Config DB         : %s\n' "$(<"$target/inventory/config-db-integrity.txt")"
    printf 'Profil reprise    : recovery/inventory/restore-profile.txt\n'
    printf 'Limites           : zstd=%s thread(s), CPU=%s%%, MemoryHigh=%s, MemoryMax=%s\n' \
      "$ZSTD_THREADS" "$CPU_QUOTA_PERCENT" "$MEMORY_HIGH" "$MEMORY_MAX"
    printf '\nSauvegarde a chaud; les disques VM/CT sont exclus.\n'
  } >"$target/MANIFEST.txt"
}

archive_tree() {
  local source=$1 output=$2 profile=${3:-normal}
  local -a options=(--numeric-owner --sparse --one-file-system)
  local -a pipe_rc

  # pmxcfs (/etc/pve) ne prend pas en charge les ACL/xattrs classiques.
  if [[ "$profile" != fuse ]]; then
    options+=(--acls --xattrs --xattrs-include='*')
  fi

  if [[ "$profile" == root ]]; then
    options+=(
      --exclude=./dev --exclude=./proc --exclude=./sys --exclude=./run
      --exclude=./tmp --exclude=./var/tmp --exclude=./mnt --exclude=./media
      --exclude=./lost+found --exclude=./swapfile
      --exclude=./etc/pve
      --exclude=./var/cache --exclude=./var/log
      --exclude=./var/spool/postfix
      --exclude=./var/lib/lxcfs
      --exclude=./var/lib/pve-cluster
      --exclude=./var/lib/rrdcached
      --exclude=./var/lib/vz/dump
      --exclude=./var/lib/vz/images --exclude=./var/lib/vz/private
      --exclude=./var/lib/vz/template/iso --exclude=./var/lib/vz/template/cache
      --exclude=./var/lib/lxc
    )
  fi

  set +e
  tar "${options[@]}" -C "$source" -cpf - . |
    zstd -T"$ZSTD_THREADS" -6 --quiet -o "$output"
  pipe_rc=("${PIPESTATUS[@]}")
  set -e

  (( pipe_rc[1] == 0 )) || die "La compression zstd a echoue pour $output"
  (( pipe_rc[0] == 0 )) || die "La creation tar a echoue pour $source"
}

prune_backups() {
  local -a backups
  local index path
  mapfile -t backups < <(
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' |
      awk '/\/20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}(Z|[+-][0-9]{4})$/' |
      sort -r
  )
  for ((index=KEEP_BACKUPS; index<${#backups[@]}; index++)); do
    path=${backups[$index]}
    case "$path" in
      "$BACKUP_ROOT"/*)
        is_backup_id "$(basename "$path")" || {
          warn "Retention ignore le chemin inattendu: $path"
          continue
        }
        log "Retention: suppression de $path"
        rm -rf --one-file-system -- "$path"
        ;;
      *) warn "Retention ignore le chemin inattendu: $path" ;;
    esac
  done
}

backup_run() {
  local stamp partial metadata latest_tmp file size
  local -a checksum_files

  RUN_ACTIVE=true
  RUN_STARTED_AT=$(date -Is)
  require_command tar
  require_command zstd
  require_command sha256sum
  require_command sqlite3
  acquire_lock
  check_target true
  check_free_space

  # Heure locale explicite, avec decalage UTC (ex. +0900), pour que le nom
  # corresponde a l'heure affichee par le host sans perdre l'information TZ.
  stamp=$(date +%Y-%m-%dT%H-%M-%S%z)
  partial="$BACKUP_ROOT/.partial-${stamp}-$$"
  RUN_PARTIAL="$partial"
  RUN_DESTINATION="$BACKUP_ROOT/$stamp"
  [[ ! -e "$RUN_DESTINATION" ]] || die "Destination deja existante: $RUN_DESTINATION"
  install -d -m 0700 "$partial"
  write_status RUNNING "$RUN_DESTINATION" "Sauvegarde en cours"

  metadata=$(mktemp -d /var/tmp/pve-host-backup.XXXXXX)
  CLEANUP_PATHS+=("$metadata")
  log "Creation de config.db coherent et de l'inventaire"
  create_recovery_metadata "$metadata"

  log "Archive du systeme PVE, hors disques VM/CT et montages externes"
  archive_tree / "$partial/rootfs.tar.zst" root

  log "Archive dediee de /etc/pve"
  archive_tree /etc/pve "$partial/etc-pve.tar.zst" fuse

  if mountpoint -q /boot; then
    log "Archive de /boot"
    archive_tree /boot "$partial/boot.tar.zst"
  fi
  if mountpoint -q /boot/efi; then
    log "Archive de /boot/efi"
    archive_tree /boot/efi "$partial/boot-efi.tar.zst"
  fi

  log "Archive de l'inventaire et des outils de reprise"
  archive_tree "$metadata" "$partial/recovery.tar.zst"
  cp -a "$metadata/MANIFEST.txt" "$partial/MANIFEST.txt"
  cp -a "$0" "$partial/pve-host-backup"
  [[ -x "$RESTORE_TOOL" ]] && cp -a "$RESTORE_TOOL" "$partial/pve-host-restore"
  [[ -r "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "$partial/pve-host-backup.conf"
  show_manual >"$partial/RESTORE_HOST_PVE.txt"

  while IFS= read -r -d '' file; do
    zstd -t --quiet "$file"
  done < <(find "$partial" -maxdepth 1 -type f -name '*.tar.zst' -print0)

  mapfile -d '' -t checksum_files < <(
    find "$partial" -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z
  )
  (
    cd "$partial"
    sha256sum -- "${checksum_files[@]##*/}" >SHA256SUMS
  )

  mv -- "$partial" "$RUN_DESTINATION"
  RUN_PARTIAL=""
  latest_tmp="$BACKUP_ROOT/.LATEST.txt.$$"
  printf '%s\n' "$stamp" >"$latest_tmp"
  mv -- "$latest_tmp" "$BACKUP_ROOT/LATEST.txt"
  size=$(du -sh "$RUN_DESTINATION" | awk '{print $1}')
  write_status SUCCESS "$RUN_DESTINATION" "Verification SHA-256 et zstd OK; taille=$size"
  RUN_SUCCESS=true
  log "Sauvegarde terminee et verifiee: $RUN_DESTINATION ($size)"
  prune_backups
}

resolve_backup() {
  local requested=${1:-latest} stamp
  if [[ "$requested" == latest ]]; then
    [[ -f "$BACKUP_ROOT/LATEST.txt" && ! -L "$BACKUP_ROOT/LATEST.txt" ]] ||
      die "LATEST.txt absent ou symbolique."
    stamp=$(<"$BACKUP_ROOT/LATEST.txt")
  else
    stamp=$requested
  fi
  is_backup_id "$stamp" ||
    die "Identifiant de sauvegarde invalide: $stamp"
  RESOLVED_BACKUP="$BACKUP_ROOT/$stamp"
  [[ -d "$RESOLVED_BACKUP" && ! -L "$RESOLVED_BACKUP" ]] ||
    die "Sauvegarde absente ou symbolique: $RESOLVED_BACKUP"
}

is_backup_id() {
  [[ $1 =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}(Z|[+-][0-9]{4})$ ]]
}

verify_backup() {
  local requested=${1:-latest} file
  check_target false
  resolve_backup "$requested"
  [[ -f "$RESOLVED_BACKUP/SHA256SUMS" && ! -L "$RESOLVED_BACKUP/SHA256SUMS" ]] ||
    die "SHA256SUMS absent ou symbolique."
  log "Verification SHA-256 de $RESOLVED_BACKUP"
  (cd "$RESOLVED_BACKUP" && sha256sum -c SHA256SUMS)
  log "Verification zstd"
  while IFS= read -r -d '' file; do
    zstd -t --quiet "$file"
    printf 'OK  %s\n' "$(basename "$file")"
  done < <(find "$RESOLVED_BACKUP" -maxdepth 1 -type f -name '*.tar.zst' -print0)
}

archive_is_safe() {
  local archive=$1
  tar --zstd -tf "$archive" |
    awk '
      BEGIN { bad=0 }
      /^\// { bad=1 }
      /(^|\/)\.\.($|\/)/ { bad=1 }
      END { exit bad ? 1 : 0 }
    '
}

extract_to() {
  local archive=$1 target=$2
  [[ -e "$archive" || -L "$archive" ]] || return 0
  [[ -f "$archive" && ! -L "$archive" ]] || die "Archive non reguliere ou symbolique: $archive"
  archive_is_safe "$archive" || die "Chemin dangereux detecte dans $archive"
  install -d -m 0700 "$target"
  tar --zstd -xpf "$archive" -C "$target" --no-same-owner
}

stage_backup() {
  local requested=${1:-latest} stamp target
  verify_backup "$requested"
  stamp=$(basename "$RESOLVED_BACKUP")
  target="$STAGING_ROOT/$stamp"
  [[ ! -e "$target" ]] || die "Le staging existe deja: $target"
  install -d -m 0700 "$target"
  extract_to "$RESOLVED_BACKUP/rootfs.tar.zst" "$target/rootfs"
  extract_to "$RESOLVED_BACKUP/etc-pve.tar.zst" "$target/etc-pve"
  extract_to "$RESOLVED_BACKUP/boot.tar.zst" "$target/boot"
  extract_to "$RESOLVED_BACKUP/boot-efi.tar.zst" "$target/boot-efi"
  extract_to "$RESOLVED_BACKUP/recovery.tar.zst" "$target/recovery"
  log "Extraction terminee sans modification du systeme: $target"
  warn "Lire RESTORE_HOST_PVE.txt et comparer chaque fichier avant application."
}

unstage_backup() {
  local requested=${1:-latest} stamp target
  check_target false
  resolve_backup "$requested"
  stamp=$(basename "$RESOLVED_BACKUP")
  target="$STAGING_ROOT/$stamp"
  [[ $target == "$STAGING_ROOT"/* ]] && is_backup_id "$(basename "$target")" ||
    die "Chemin de staging inattendu: $target"
  [[ -d "$target" ]] || die "Staging absent: $target"
  mountpoint -q "$target" && die "Le staging est un point de montage; suppression refusee."
  rm -rf --one-file-system -- "$target"
  rmdir "$STAGING_ROOT" 2>/dev/null || true
  log "Staging supprime: $target"
}

cleanup_partials() {
  local path
  acquire_lock
  check_target false
  while IFS= read -r -d '' path; do
    case "$path" in
      "$BACKUP_ROOT"/.partial-*)
        log "Suppression du temporaire incomplet: $path"
        rm -rf --one-file-system -- "$path"
        ;;
    esac
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.partial-*' -print0)
}

show_check() {
  local available
  check_target true
  available=$(df -h "$BACKUP_ROOT" | awk 'NR == 2 {print $4}')
  printf 'Script                 : %s\n' "$VERSION"
  printf 'Host                   : %s\n' "$(hostname)"
  printf 'Stockage PVE           : %s\n' "$PVE_NFS_STORAGE"
  printf 'Source NFS             : %s\n' "$EXPECTED_NFS_SOURCE"
  printf 'Destination            : %s\n' "$BACKUP_ROOT"
  printf 'Execution              : dimanche a %s\n' "$BACKUP_TIME"
  printf 'Copies conservees      : %s\n' "$KEEP_BACKUPS"
  printf 'Notifications succes   : %s\n' "$(success_notification_label)"
  printf 'Notifications echec    : toujours activees\n'
  printf 'Threads Zstandard      : %s\n' "$ZSTD_THREADS"
  printf 'Quota CPU              : %s\n' "$(cpu_quota_label)"
  printf 'Seuil memoire souple   : %s\n' "$(memory_limit_label "$MEMORY_HIGH")"
  printf 'Limite memoire dure    : %s\n' "$(memory_limit_label "$MEMORY_MAX")"
  printf 'Espace disponible      : %s\n' "$available"
  printf 'Notification sendmail  : %s\n' "$(command -v sendmail 2>/dev/null || printf 'absente')"
  printf 'Controle NFS/ecriture  : OK\n'
}

show_status() {
  check_target false
  printf '\nConfiguration:\n'
  show_settings
  printf '\nDernier statut:\n'
  [[ -r "$BACKUP_ROOT/LAST_RUN_STATUS.txt" ]] && cat "$BACKUP_ROOT/LAST_RUN_STATUS.txt" || printf 'Aucun statut.\n'
  printf '\nSauvegardes disponibles:\n'
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
    awk '/^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}(Z|[+-][0-9]{4})$/' |
    sort -r
  printf '\nPlanification cron:\n'
  show_cron_status
}

notify_test() {
  send_notification TEST "Test de sauvegarde du host PVE" \
    "Le systeme local de notification a accepte ce message le $(date -Is)."
  printf 'Notification de test remise au mail systeme local.\n'
}

success_notification_label() {
  if [[ "$NOTIFY_SUCCESS" == 1 ]]; then
    printf 'activees'
  else
    printf 'desactivees'
  fi
}

cpu_quota_label() {
  if [[ "$CPU_QUOTA_PERCENT" == 0 ]]; then
    printf 'sans quota systemd'
  else
    printf '%s%% (equivalent %.2f coeur(s))' \
      "$CPU_QUOTA_PERCENT" "$(awk -v value="$CPU_QUOTA_PERCENT" 'BEGIN { print value / 100 }')"
  fi
}

memory_limit_label() {
  if [[ "$1" == 0 ]]; then printf 'desactivee'; else printf '%s' "$1"; fi
}

write_managed_config() {
  local temporary
  temporary=$(mktemp /etc/pve-host-backup.conf.tmp.XXXXXX)
  {
    printf 'PVE_NFS_STORAGE=%q\n' "$PVE_NFS_STORAGE"
    printf 'EXPECTED_NFS_SOURCE=%q\n' "$EXPECTED_NFS_SOURCE"
    printf 'BACKUP_ROOT=%q\n' "$BACKUP_ROOT"
    printf 'KEEP_BACKUPS=%q\n' "$KEEP_BACKUPS"
    printf 'MIN_FREE_KIB=%q\n' "$MIN_FREE_KIB"
    printf 'ZSTD_THREADS=%q\n' "$ZSTD_THREADS"
    printf 'CPU_QUOTA_PERCENT=%q\n' "$CPU_QUOTA_PERCENT"
    printf 'MEMORY_HIGH=%q\n' "$MEMORY_HIGH"
    printf 'MEMORY_MAX=%q\n' "$MEMORY_MAX"
    printf 'STAGING_ROOT=%q\n' "$STAGING_ROOT"
    printf 'MAIL_TO=%q\n' "$MAIL_TO"
    printf 'BACKUP_TIME=%q\n' "$BACKUP_TIME"
    printf 'NOTIFY_SUCCESS=%q\n' "$NOTIFY_SUCCESS"
  } >"$temporary"
  chmod 0600 "$temporary"
  mv -- "$temporary" "$CONFIG_FILE"
}

write_resource_dropin() {
  local dropin=/etc/systemd/system/pve-host-backup.service.d/10-resources.conf
  local temporary
  install -d -m 0755 "$(dirname "$dropin")"
  temporary=$(mktemp "${dropin}.tmp.XXXXXX")
  {
    printf '[Service]\n'
    if [[ "$CPU_QUOTA_PERCENT" == 0 ]]; then
      printf 'CPUQuota=\n'
    else
      printf 'CPUQuota=%s%%\n' "$CPU_QUOTA_PERCENT"
    fi
    if [[ "$MEMORY_HIGH" == 0 ]]; then
      printf 'MemoryHigh=infinity\n'
    else
      printf 'MemoryHigh=%s\n' "$MEMORY_HIGH"
    fi
    if [[ "$MEMORY_MAX" == 0 ]]; then
      printf 'MemoryMax=infinity\n'
    else
      printf 'MemoryMax=%s\n' "$MEMORY_MAX"
    fi
  } >"$temporary"
  chmod 0644 "$temporary"
  mv -- "$temporary" "$dropin"
  systemctl daemon-reload
}

cron_file_exists() {
  [[ -e "$CRON_FILE" || -L "$CRON_FILE" ]]
}

cron_file_is_managed() {
  local mode
  [[ -f "$CRON_FILE" && ! -L "$CRON_FILE" ]] || return 1
  [[ $(stat -c '%u' "$CRON_FILE" 2>/dev/null) == 0 ]] || return 1
  mode=$(stat -c '%a' "$CRON_FILE" 2>/dev/null) || return 1
  (( (8#$mode & 8#022) == 0 )) || return 1
  grep -Fxq '# Managed by pve-host-backup' "$CRON_FILE"
}

cron_schedule_line() {
  local hour minute
  hour=$((10#${BACKUP_TIME%%:*}))
  minute=$((10#${BACKUP_TIME##*:}))
  printf '%d %d * * 0 root /usr/bin/systemctl start --no-block pve-host-backup.service\n' \
    "$minute" "$hour"
}

write_cron_file() {
  local temporary
  if cron_file_exists && ! cron_file_is_managed; then
    die "$CRON_FILE existe mais n'est pas un fichier gere et sur; modification refusee."
  fi

  install -d -m 0755 /etc/cron.d
  temporary=$(mktemp /etc/cron.d/pve-host-backup.tmp.XXXXXX)
  {
    printf '# Managed by pve-host-backup\n'
    printf '# Dimanche a %s, heure locale du host.\n' "$BACKUP_TIME"
    printf 'SHELL=/bin/sh\n'
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf 'MAILTO=""\n'
    cron_schedule_line
  } >"$temporary"
  chmod 0644 "$temporary"
  chown root:root "$temporary"
  mv -- "$temporary" "$CRON_FILE"
}

remove_cron_file() {
  if ! cron_file_exists; then
    return 0
  fi
  cron_file_is_managed ||
    die "$CRON_FILE n'est pas reconnu comme gere par pve-host-backup; suppression refusee."
  rm -f -- "$CRON_FILE"
}

show_next_run() {
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar --iterations=1 \
      "Sun *-*-* ${BACKUP_TIME}:00" 2>/dev/null || true
  else
    printf 'Dimanche a %s, heure locale du host.\n' "$BACKUP_TIME"
  fi
}

show_cron_status() {
  if cron_file_is_managed; then
    printf 'Planification           : active\n'
    printf 'Fichier cron            : %s\n' "$CRON_FILE"
    printf 'Ligne executee          : '
    cron_schedule_line
  elif cron_file_exists; then
    printf 'Planification           : ERREUR - fichier cron non reconnu\n'
    printf 'Fichier                 : %s\n' "$CRON_FILE"
  else
    printf 'Planification           : desactivee\n'
    printf 'Fichier cron            : absent\n'
  fi
  printf 'Service cron            : '
  systemctl is-active cron.service 2>/dev/null || true
  printf 'Sauvegarde en cours     : '
  systemctl is-active pve-host-backup.service 2>/dev/null || true

  if cron_file_is_managed; then
    printf '\nProchaine execution calculee :\n'
    show_next_run
    printf 'Note: cron ne rattrape pas un horaire manque si le host etait arrete.\n'
  fi
}

show_settings() {
  printf 'Heure hebdomadaire      : dimanche a %s\n' "$BACKUP_TIME"
  printf 'Sauvegardes conservees  : %s\n' "$KEEP_BACKUPS"
  printf 'Notifications de succes : %s\n' "$(success_notification_label)"
  printf 'Notifications d echec   : toujours activees\n'
  printf 'Destinataire             : %s\n' "$MAIL_TO"
}

show_resources() {
  printf 'Threads Zstandard      : %s\n' "$ZSTD_THREADS"
  printf 'Quota CPU              : %s\n' "$(cpu_quota_label)"
  printf 'Seuil memoire souple   : %s\n' "$(memory_limit_label "$MEMORY_HIGH")"
  printf 'Limite memoire dure    : %s\n' "$(memory_limit_label "$MEMORY_MAX")"
  printf '\nValeurs systemd effectives :\n'
  systemctl show pve-host-backup.service \
    -p CPUQuotaPerSecUSec -p MemoryHigh -p MemoryMax --no-pager || true
}

configure_resources() {
  local new_threads=$ZSTD_THREADS new_cpu=$CPU_QUOTA_PERCENT
  local new_high=$MEMORY_HIGH new_max=$MEMORY_MAX input available_cpu

  if (($# == 0)); then
    printf '100%% de CPU correspond a un coeur logique. 200%% correspond a deux.\n'
    printf 'MemoryHigh ralentit/reclame la memoire; MemoryMax est une limite dure.\n'
    new_threads=$(ask_resource_value "Threads de compression" "$new_threads")
    new_cpu=$(ask_resource_value "Quota CPU en pourcentage, 0=sans quota" "$new_cpu")
    new_high=$(ask_resource_value "MemoryHigh, ex. 2G, 0=desactive" "$new_high")
    new_max=$(ask_resource_value "MemoryMax, ex. 3G, 0=sans limite dure" "$new_max")
  else
    while (($#)); do
      case "$1" in
        --threads) (($# >= 2)) || die "Valeur absente apres --threads."; new_threads=$2; shift 2 ;;
        --cpu-percent) (($# >= 2)) || die "Valeur absente apres --cpu-percent."; new_cpu=$2; shift 2 ;;
        --memory-high) (($# >= 2)) || die "Valeur absente apres --memory-high."; new_high=$2; shift 2 ;;
        --memory-max) (($# >= 2)) || die "Valeur absente apres --memory-max."; new_max=$2; shift 2 ;;
        *) die "Option de ressources inconnue: $1" ;;
      esac
    done
  fi

  [[ "$new_threads" =~ ^[1-9][0-9]*$ ]] || die "Threads invalides."
  available_cpu=$(nproc)
  (( new_threads <= available_cpu )) || die "Threads superieurs aux ${available_cpu} coeurs disponibles."
  [[ "$new_cpu" =~ ^(0|[1-9][0-9]{0,4})$ ]] || die "Quota CPU invalide."
  if [[ "$new_cpu" != 0 ]] && (( new_cpu > available_cpu * 100 )); then
    die "Quota CPU superieur a $((available_cpu * 100))% sur ce host."
  fi
  [[ "$new_high" =~ ^(0|[1-9][0-9]{0,4}[KMGT])$ ]] || die "MemoryHigh invalide."
  [[ "$new_max" =~ ^(0|[1-9][0-9]{0,4}[KMGT])$ ]] || die "MemoryMax invalide."
  if [[ "$new_high" != 0 && "$new_max" != 0 ]] &&
    (( $(size_to_bytes "$new_high") > $(size_to_bytes "$new_max") )); then
    die "MemoryHigh ne peut pas depasser MemoryMax."
  fi

  ZSTD_THREADS=$new_threads
  CPU_QUOTA_PERCENT=$new_cpu
  MEMORY_HIGH=$new_high
  MEMORY_MAX=$new_max
  write_managed_config
  write_resource_dropin
  if systemctl is-active --quiet pve-host-backup.service; then
    warn "Une sauvegarde est en cours; les nouvelles limites s appliqueront au prochain lancement."
  fi
  printf '\nLimites enregistrees. Elles s appliqueront au prochain backup.\n'
  show_resources
}

ask_resource_value() {
  local prompt=$1 default=$2 value
  read -r -p "$prompt [$default] : " value || value=""
  printf '%s' "${value:-$default}"
}

configure_settings() {
  local new_time=$BACKUP_TIME new_keep=$KEEP_BACKUPS new_notify=$NOTIFY_SUCCESS
  local input notify_default cron_was_active=false

  if cron_file_exists; then
    cron_file_is_managed ||
      die "$CRON_FILE existe mais n'est pas reconnu; configuration refusee."
    cron_was_active=true
  fi

  if (($# == 0)); then
    printf 'Configuration de la sauvegarde du host PVE\n\n'
    read -r -p "Heure du dimanche, HH:MM [$new_time] : " input || true
    [[ -z "$input" ]] || new_time=$input

    input=""
    read -r -p "Nombre de sauvegardes a conserver [$new_keep] : " input || true
    [[ -z "$input" ]] || new_keep=$input

    if [[ "$new_notify" == 1 ]]; then
      notify_default=oui
    else
      notify_default=non
    fi
    input=""
    read -r -p "Notifier aussi les succes ? oui/non [$notify_default] : " input || true
    [[ -z "$input" ]] || {
      case "${input,,}" in
        oui|yes|on|1) new_notify=1 ;;
        non|no|off|0) new_notify=0 ;;
        *) die "Reponse invalide pour les notifications: $input" ;;
      esac
    }
  else
    while (($#)); do
      case "$1" in
        --time)
          (($# >= 2)) || die "Valeur absente apres --time."
          new_time=$2
          shift 2
          ;;
        --retention|--keep)
          (($# >= 2)) || die "Valeur absente apres $1."
          new_keep=$2
          shift 2
          ;;
        --notify-success)
          (($# >= 2)) || die "Valeur absente apres --notify-success."
          case "${2,,}" in
            oui|yes|on|1) new_notify=1 ;;
            non|no|off|0) new_notify=0 ;;
            *) die "Utiliser on ou off apres --notify-success." ;;
          esac
          shift 2
          ;;
        *) die "Option de configuration inconnue: $1" ;;
      esac
    done
  fi

  if [[ ! "$new_time" =~ ^[0-9]{2}:[0-9]{2}$ ]] ||
    ((10#${new_time%%:*} > 23 || 10#${new_time##*:} > 59)); then
    die "L'heure doit avoir la forme HH:MM, par exemple 03:30."
  fi
  [[ "$new_keep" =~ ^[1-9][0-9]*$ ]] ||
    die "La retention doit etre un entier superieur a zero."

  BACKUP_TIME=$new_time
  KEEP_BACKUPS=$new_keep
  NOTIFY_SUCCESS=$new_notify
  write_managed_config
  if [[ "$cron_was_active" == true ]]; then
    write_cron_file
  fi

  if systemctl is-active --quiet pve-host-backup.service; then
    warn "Une sauvegarde est en cours; elle conserve ses anciens reglages jusqu'a sa fin."
  fi

  printf '\nConfiguration enregistree.\n'
  show_settings
  printf '\nPlanification:\n'
  show_cron_status
}

auto_on() {
  show_check
  systemctl enable --now cron.service || die "Impossible d'activer cron.service."
  write_cron_file
  log "Planification automatique cron activee."
  show_cron_status
}

auto_off() {
  remove_cron_file
  log "Planification automatique cron desactivee."
  log "Le service cron reste actif car d'autres taches du systeme peuvent l'utiliser."
  if systemctl is-active --quiet pve-host-backup.service; then
    warn "Une sauvegarde est deja en cours; elle continue jusqu'a sa fin."
  fi
}

auto_status() {
  show_settings
  printf '\n'
  show_cron_status
}

start_backup_now() {
  if systemctl is-active --quiet pve-host-backup.service; then
    warn "Une sauvegarde est deja en cours."
    printf 'Suivi: pve-host-backup follow\n'
    return 0
  fi
  show_check
  systemctl start --no-block pve-host-backup.service
  log "Demarrage de la sauvegarde demande au service systemd."
  printf 'Suivi en direct : pve-host-backup follow\n'
}

show_logs() {
  journalctl -u pve-host-backup.service -n 100 --no-pager
}

follow_logs() {
  printf 'Ctrl+C quitte uniquement le journal; la sauvegarde continue.\n'
  journalctl -fu pve-host-backup.service
}

main_menu() {
  local choice
  [[ -t 0 && -t 1 ]] || die "Le menu necessite une console interactive."
  while true; do
    cat <<'MENU'

============================================================
 PVE Host Backup - menu principal
============================================================
  1) Voir l'etat general
  2) Lancer une sauvegarde maintenant
  3) Suivre le journal en direct
  4) Verifier la derniere sauvegarde
  5) Activer la sauvegarde automatique (cron)
  6) Desactiver la sauvegarde automatique
  7) Changer heure, retention et notifications
  8) Changer les limites CPU/RAM
  9) Auditer la restauration de la derniere sauvegarde
  0) Quitter
MENU
    read -r -p "Votre choix : " choice
    case "$choice" in
      1) show_status ;;
      2) start_backup_now ;;
      3) follow_logs ;;
      4) verify_backup latest ;;
      5) auto_on ;;
      6) auto_off ;;
      7) configure_settings ;;
      8) configure_resources ;;
      9)
        [[ -x "$RESTORE_TOOL" ]] || die "Assistant absent: $RESTORE_TOOL"
        "$RESTORE_TOOL" audit latest || warn "L'audit a signale un point a examiner."
        ;;
      0|q|Q) return 0 ;;
      *) warn "Choix invalide." ;;
    esac
    printf '\n'
    read -r -p "Appuyer sur Entree pour revenir au menu..." _ || true
  done
}

usage() {
  cat <<EOF
Sauvegarde autonome du host PVE - $VERSION

Usage:
  pve-host-backup menu                     Ouvrir le menu interactif
  pve-host-backup now                      Lancer un backup en arriere-plan
  pve-host-backup info                     Afficher l'etat general
  pve-host-backup logs                     Afficher les 100 dernieres lignes
  pve-host-backup follow                   Suivre le journal en direct
  pve-host-backup verify-latest            Verifier la derniere sauvegarde
  pve-host-backup on                       Activer la planification cron
  pve-host-backup off                      Desactiver la planification cron

Commandes detaillees:
  pve-host-backup check                    Verifier NFS, ecriture et configuration
  pve-host-backup run                      Creer et verifier une sauvegarde
  pve-host-backup status                   Afficher statut, sauvegardes et cron
  pve-host-backup verify [latest|DATE]     Verifier SHA-256 et zstd
  pve-host-backup stage [latest|DATE]      Extraire en staging sans appliquer
  pve-host-backup unstage [latest|DATE]    Supprimer une extraction de staging
  pve-host-backup cleanup-partials         Supprimer les sauvegardes incompletes
  pve-host-backup manual                   Afficher le manuel de restauration
  pve-host-backup notify-test              Tester le mail systeme local
  pve-host-backup configure                Modifier heure, retention et notifications
  pve-host-backup configure --time HH:MM --retention N --notify-success on|off
  pve-host-backup settings                 Afficher la configuration simple
  pve-host-backup configure-resources      Modifier threads, quota CPU et memoire
  pve-host-backup configure-resources --threads N --cpu-percent N --memory-high 2G --memory-max 0
  pve-host-backup resources                Afficher les limites de ressources
  pve-host-backup auto-on                  Activer la tache cron
  pve-host-backup auto-off                 Desactiver cron sans stopper un run actif
  pve-host-backup auto-status              Afficher l'etat de la planification
EOF
}

main() {
  local action=${1:-help}

  case "$action" in
    help|--help|-h)
      usage
      exit 0
      ;;
  esac

  require_root
  load_config
  require_command findmnt
  require_command pvesm
  require_command pvesh
  require_command qm
  require_command pct
  require_command flock

  case "$action" in
    menu) main_menu ;;
    now) start_backup_now ;;
    info) show_status ;;
    logs) show_logs ;;
    follow) follow_logs ;;
    verify-latest) verify_backup latest ;;
    on) auto_on ;;
    off) auto_off ;;
    check) show_check ;;
    run) backup_run ;;
    status) show_status ;;
    verify) verify_backup "${2:-latest}" ;;
    stage) stage_backup "${2:-latest}" ;;
    unstage) unstage_backup "${2:-latest}" ;;
    cleanup-partials) cleanup_partials ;;
    manual) show_manual ;;
    notify-test) notify_test ;;
    configure) configure_settings "${@:2}" ;;
    settings) show_settings ;;
    configure-resources) configure_resources "${@:2}" ;;
    resources) show_resources ;;
    auto-on) auto_on ;;
    auto-off) auto_off ;;
    auto-status) auto_status ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
PVE_HOST_BACKUP_SCRIPT

install -m 0600 /dev/stdin /etc/pve-host-backup.conf <<EOF
PVE_NFS_STORAGE="${PVE_NFS_STORAGE}"
EXPECTED_NFS_SOURCE="${EXPECTED_NFS_SOURCE}"
BACKUP_ROOT="${BACKUP_ROOT}"
KEEP_BACKUPS="${KEEP_BACKUPS}"
MIN_FREE_KIB="${MIN_FREE_KIB}"
ZSTD_THREADS="${ZSTD_THREADS}"
CPU_QUOTA_PERCENT="${CPU_QUOTA_PERCENT}"
MEMORY_HIGH="${MEMORY_HIGH}"
MEMORY_MAX="${MEMORY_MAX}"
STAGING_ROOT="${STAGING_ROOT}"
MAIL_TO="${MAIL_TO}"
BACKUP_TIME="${BACKUP_TIME}"
NOTIFY_SUCCESS="${NOTIFY_SUCCESS}"
EOF

install -m 0644 /dev/stdin /etc/systemd/system/pve-host-backup.service <<'PVE_HOST_BACKUP_SERVICE'
[Unit]
Description=Sauvegarde autonome et verifiee du host PVE
Wants=network-online.target
After=network-online.target remote-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-host-backup run
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
CPUSchedulingPolicy=batch
UMask=0077
TimeoutStartSec=infinity
PVE_HOST_BACKUP_SERVICE

install -m 0644 /dev/stdin \
  /etc/systemd/system/pve-host-backup.service.d/10-resources.conf <<EOF
[Service]
CPUQuota=$([[ "$CPU_QUOTA_PERCENT" == 0 ]] && printf '' || printf '%s%%' "$CPU_QUOTA_PERCENT")
MemoryHigh=$([[ "$MEMORY_HIGH" == 0 ]] && printf 'infinity' || printf '%s' "$MEMORY_HIGH")
MemoryMax=$([[ "$MEMORY_MAX" == 0 ]] && printf 'infinity' || printf '%s' "$MEMORY_MAX")
EOF

bash -n /usr/local/sbin/pve-host-backup
systemd-analyze verify /etc/systemd/system/pve-host-backup.service
systemctl disable --now pve-host-backup.timer >/dev/null 2>&1 || true
rm -f -- /etc/systemd/system/pve-host-backup.timer
if [[ -f "$INSTALL_CRON_FILE" ]] &&
  grep -Fxq '# Managed by pve-host-backup' "$INSTALL_CRON_FILE"; then
  rm -f -- "$INSTALL_CRON_FILE"
fi
systemctl daemon-reload

echo
echo "Controle de l'installation..."
/usr/local/sbin/pve-host-backup check

echo
echo "Installation terminee. La tache cron reste volontairement desactivee."
if [[ "$CONFIG_PRESERVED" == true ]]; then
  echo "La configuration existante a ete preservee."
fi
echo "Horaire prepare : dimanche a ${BACKUP_TIME}, heure locale du host."
echo "Cron             : non active; aucun fichier /etc/cron.d/pve-host-backup."
echo "Retention       : ${KEEP_BACKUPS} sauvegardes."
echo "Compression     : ${ZSTD_THREADS} thread(s) Zstandard."
if [[ "$CPU_QUOTA_PERCENT" == 0 ]]; then
  echo "Quota CPU       : desactive."
else
  echo "Quota CPU       : ${CPU_QUOTA_PERCENT}% (100% = un coeur logique)."
fi
echo "MemoryHigh      : $([[ "$MEMORY_HIGH" == 0 ]] && printf 'desactive' || printf '%s' "$MEMORY_HIGH")."
echo "MemoryMax       : $([[ "$MEMORY_MAX" == 0 ]] && printf 'desactive' || printf '%s' "$MEMORY_MAX")."
if [[ "$NOTIFY_SUCCESS" == 1 ]]; then
  echo "Notifications   : succes et echecs."
else
  echo "Notifications   : echecs uniquement."
fi
echo
echo "Modifier simplement ces reglages :"
echo "  pve-host-backup menu"
echo "  pve-host-backup configure"
echo "  pve-host-backup configure-resources"
echo
echo "Validation avant activation :"
echo "  pve-host-backup notify-test"
echo "  pve-host-backup now"
echo "  pve-host-backup follow"
echo "  pve-host-backup verify-latest"
echo "  pve-host-backup stage latest"
echo "  pve-host-backup unstage latest"
echo "  pve-host-restore audit latest"
echo
echo "Activation seulement apres ces tests :"
echo "  pve-host-backup on"
echo "  pve-host-backup auto-status"
echo
echo "Desactivation simple :"
echo "  pve-host-backup off"

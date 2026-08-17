#!/usr/bin/env bash
# Installateur autonome de la sauvegarde du host Proxmox VE.
# Peut etre colle en entier dans un shell root sur le host PVE.

set -Eeuo pipefail
umask 077

CONFIG_FILE="/etc/pve-host-backup.conf"
OVERWRITE_CONFIG="${OVERWRITE_CONFIG:-0}"
CONFIG_PRESERVED=false

[[ "$OVERWRITE_CONFIG" == 0 || "$OVERWRITE_CONFIG" == 1 ]] || {
  echo "OVERWRITE_CONFIG doit valoir 0 ou 1." >&2
  exit 1
}

if [[ -r "$CONFIG_FILE" && "$OVERWRITE_CONFIG" == 0 ]]; then
  [[ $(stat -c '%u' "$CONFIG_FILE") == 0 ]] || {
    echo "$CONFIG_FILE n'appartient pas a root; chargement refuse." >&2
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
TIMER_CALENDAR="${TIMER_CALENDAR:-Sun *-*-* 04:15:00}"
TIMER_RANDOM_DELAY="${TIMER_RANDOM_DELAY:-15m}"
STAGING_ROOT="${STAGING_ROOT:-/var/tmp/pve-host-restore}"
MAIL_TO="${MAIL_TO:-root}"

[[ ${EUID} -eq 0 ]] || {
  echo "Executer cet installateur en root sur PVE." >&2
  exit 1
}
[[ -d /etc/pve ]] || {
  echo "/etc/pve est absent : ce systeme ne semble pas etre un host PVE." >&2
  exit 1
}

HOST_SHORT=$(hostname -s)
BACKUP_ROOT="${BACKUP_ROOT:-${NFS_MOUNT_ROOT}/backups/PVE/host/${HOST_SHORT}}"

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
[[ "$STAGING_ROOT" =~ ^/var/tmp/pve-host-restore(-[A-Za-z0-9._-]+)?$ ]] || {
  echo "STAGING_ROOT doit etre un repertoire dedie sous /var/tmp." >&2
  exit 1
}
systemd-analyze calendar "$TIMER_CALENDAR" >/dev/null || {
  echo "TIMER_CALENDAR n'est pas une expression systemd valide." >&2
  exit 1
}

echo "Installation des dependances..."
apt-get update
apt-get install -y sqlite3 zstd gdisk fdisk

install -d -m 0755 /usr/local/sbin /usr/local/share/doc/pve-host-backup

install_stamp=$(date +%Y%m%d-%H%M%S)
for installed_file in \
  /usr/local/sbin/pve-host-backup \
  /etc/pve-host-backup.conf \
  /etc/systemd/system/pve-host-backup.service \
  /etc/systemd/system/pve-host-backup.timer; do
  if [[ -f "$installed_file" ]]; then
    cp -a -- "$installed_file" \
      "/usr/local/share/doc/pve-host-backup/$(basename "$installed_file").before-install-${install_stamp}"
  fi
done

install -m 0750 /dev/stdin /usr/local/sbin/pve-host-backup <<'PVE_HOST_BACKUP_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

VERSION="1.0.0"
CONFIG_FILE="/etc/pve-host-backup.conf"
LOCK_FILE="/run/lock/pve-host-backup.lock"

PVE_NFS_STORAGE=""
EXPECTED_NFS_SOURCE=""
BACKUP_ROOT=""
KEEP_BACKUPS=""
MIN_FREE_KIB=""
ZSTD_THREADS=""
STAGING_ROOT=""
MAIL_TO=""

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
  [[ -r "$CONFIG_FILE" ]] || die "Configuration absente: $CONFIG_FILE"
  # Configuration creee par root et protegee en mode 0600.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${PVE_NFS_STORAGE:?PVE_NFS_STORAGE absent}"
  : "${EXPECTED_NFS_SOURCE:?EXPECTED_NFS_SOURCE absent}"
  : "${BACKUP_ROOT:?BACKUP_ROOT absent}"
  : "${KEEP_BACKUPS:?KEEP_BACKUPS absent}"
  : "${MIN_FREE_KIB:?MIN_FREE_KIB absent}"
  : "${ZSTD_THREADS:?ZSTD_THREADS absent}"
  : "${STAGING_ROOT:?STAGING_ROOT absent}"
  : "${MAIL_TO:?MAIL_TO absent}"

  [[ "$PVE_NFS_STORAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "PVE_NFS_STORAGE invalide."
  [[ "$EXPECTED_NFS_SOURCE" =~ ^[^[:space:]:]+:/[^[:space:]]+$ ]] ||
    die "EXPECTED_NFS_SOURCE invalide."
  [[ "$KEEP_BACKUPS" =~ ^[1-9][0-9]*$ ]] || die "KEEP_BACKUPS invalide."
  [[ "$MIN_FREE_KIB" =~ ^[1-9][0-9]*$ ]] || die "MIN_FREE_KIB invalide."
  [[ "$ZSTD_THREADS" =~ ^[1-9][0-9]*$ ]] || die "ZSTD_THREADS invalide."
  [[ "$STAGING_ROOT" =~ ^/var/tmp/pve-host-restore(-[A-Za-z0-9._-]+)?$ ]] ||
    die "STAGING_ROOT doit etre un repertoire dedie sous /var/tmp."
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
      send_notification SUCCESS "Sauvegarde du host terminee" \
        "Host=$(hostname); destination=$RUN_DESTINATION; debut=$RUN_STARTED_AT; fin=$(date -Is)" || true
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

3. Copier le fichier pve-host-backup du dernier dossier date vers :

   install -m 0750 pve-host-backup /usr/local/sbin/pve-host-backup

   Copier egalement pve-host-backup.conf vers /etc/pve-host-backup.conf.

4. Verifier les archives :

   pve-host-backup verify latest

5. Extraire uniquement dans la zone de staging :

   pve-host-backup stage latest

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
  run_to_file "$target/inventory/efibootmgr.txt" efibootmgr -v
  run_to_file "$target/inventory/systemctl-enabled.txt" systemctl list-unit-files --state=enabled
  run_to_file "$target/inventory/timers.txt" systemctl list-timers --all

  create_guest_inventory "$target/inventory/guest-configs"
  create_partition_inventory "$target/inventory/partition-tables"
  cp -a -- "$0" "$target/tools/pve-host-backup"
  show_manual >"$target/tools/RESTORE_HOST_PVE.txt"

  {
    printf 'Sauvegarde autonome du host PVE\n'
    printf 'Version du script : %s\n' "$VERSION"
    printf 'Cree le           : %s\n' "$(date -Is)"
    printf 'Hote              : %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'Destination       : %s\n' "$BACKUP_ROOT"
    printf 'Config DB         : %s\n' "$(<"$target/inventory/config-db-integrity.txt")"
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
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
      -name '20??-??-??T??-??-??Z' -print | sort -r
  )
  for ((index=KEEP_BACKUPS; index<${#backups[@]}; index++)); do
    path=${backups[$index]}
    case "$path" in
      "$BACKUP_ROOT"/20??-??-??T??-??-??Z)
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

  stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
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
    [[ -r "$BACKUP_ROOT/LATEST.txt" ]] || die "LATEST.txt absent."
    stamp=$(<"$BACKUP_ROOT/LATEST.txt")
  else
    stamp=$requested
  fi
  [[ "$stamp" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$ ]] ||
    die "Identifiant de sauvegarde invalide: $stamp"
  RESOLVED_BACKUP="$BACKUP_ROOT/$stamp"
  [[ -d "$RESOLVED_BACKUP" ]] || die "Sauvegarde absente: $RESOLVED_BACKUP"
}

verify_backup() {
  local requested=${1:-latest} file
  check_target false
  resolve_backup "$requested"
  [[ -r "$RESOLVED_BACKUP/SHA256SUMS" ]] || die "SHA256SUMS absent."
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
  [[ -r "$archive" ]] || return 0
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
  case "$target" in
    "$STAGING_ROOT"/20??-??-??T??-??-??Z) ;;
    *) die "Chemin de staging inattendu: $target" ;;
  esac
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
  printf 'Copies conservees      : %s\n' "$KEEP_BACKUPS"
  printf 'Threads Zstandard      : %s\n' "$ZSTD_THREADS"
  printf 'Espace disponible      : %s\n' "$available"
  printf 'Notification sendmail  : %s\n' "$(command -v sendmail 2>/dev/null || printf 'absente')"
  printf 'Controle NFS/ecriture  : OK\n'
}

show_status() {
  check_target false
  printf '\nDernier statut:\n'
  [[ -r "$BACKUP_ROOT/LAST_RUN_STATUS.txt" ]] && cat "$BACKUP_ROOT/LAST_RUN_STATUS.txt" || printf 'Aucun statut.\n'
  printf '\nSauvegardes disponibles:\n'
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name '20??-??-??T??-??-??Z' -printf '%f\n' | sort -r
  printf '\nTimer:\n'
  systemctl list-timers --all pve-host-backup.timer --no-pager || true
}

notify_test() {
  send_notification TEST "Test de sauvegarde du host PVE" \
    "Le systeme local de notification a accepte ce message le $(date -Is)."
  printf 'Notification de test remise au mail systeme local.\n'
}

auto_on() {
  show_check
  systemctl enable --now pve-host-backup.timer
  log "Planification automatique activee."
  systemctl list-timers --all pve-host-backup.timer --no-pager
}

auto_off() {
  systemctl disable --now pve-host-backup.timer
  log "Planification automatique desactivee."
  if systemctl is-active --quiet pve-host-backup.service; then
    warn "Une sauvegarde est deja en cours; elle continue jusqu'a sa fin."
  fi
}

auto_status() {
  printf 'Activation au demarrage : '
  systemctl is-enabled pve-host-backup.timer 2>/dev/null || true
  printf 'Etat du timer           : '
  systemctl is-active pve-host-backup.timer 2>/dev/null || true
  printf 'Etat de la sauvegarde   : '
  systemctl is-active pve-host-backup.service 2>/dev/null || true
  printf '\nProchaine execution:\n'
  systemctl list-timers --all pve-host-backup.timer --no-pager || true
}

usage() {
  cat <<EOF
Sauvegarde autonome du host PVE - $VERSION

Usage:
  pve-host-backup check                    Verifier NFS, ecriture et configuration
  pve-host-backup run                      Creer et verifier une sauvegarde
  pve-host-backup status                   Afficher statut, sauvegardes et timer
  pve-host-backup verify [latest|DATE]     Verifier SHA-256 et zstd
  pve-host-backup stage [latest|DATE]      Extraire en staging sans appliquer
  pve-host-backup unstage [latest|DATE]    Supprimer une extraction de staging
  pve-host-backup cleanup-partials         Supprimer les sauvegardes incompletes
  pve-host-backup manual                   Afficher le manuel de restauration
  pve-host-backup notify-test              Tester le mail systeme local
  pve-host-backup auto-on                  Activer le timer systemd
  pve-host-backup auto-off                 Desactiver le timer sans stopper un run actif
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
    check) show_check ;;
    run) backup_run ;;
    status) show_status ;;
    verify) verify_backup "${2:-latest}" ;;
    stage) stage_backup "${2:-latest}" ;;
    unstage) unstage_backup "${2:-latest}" ;;
    cleanup-partials) cleanup_partials ;;
    manual) show_manual ;;
    notify-test) notify_test ;;
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
STAGING_ROOT="${STAGING_ROOT}"
MAIL_TO="${MAIL_TO}"
TIMER_CALENDAR="${TIMER_CALENDAR}"
TIMER_RANDOM_DELAY="${TIMER_RANDOM_DELAY}"
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

install -m 0644 /dev/stdin /etc/systemd/system/pve-host-backup.timer <<EOF
[Unit]
Description=Planification hebdomadaire de la sauvegarde du host PVE

[Timer]
OnCalendar=${TIMER_CALENDAR}
Persistent=true
RandomizedDelaySec=${TIMER_RANDOM_DELAY}
AccuracySec=1m
Unit=pve-host-backup.service

[Install]
WantedBy=timers.target
EOF

bash -n /usr/local/sbin/pve-host-backup
systemd-analyze verify \
  /etc/systemd/system/pve-host-backup.service \
  /etc/systemd/system/pve-host-backup.timer
systemctl daemon-reload
systemctl disable --now pve-host-backup.timer >/dev/null 2>&1 || true

echo
echo "Controle de l'installation..."
/usr/local/sbin/pve-host-backup check

echo
echo "Installation terminee. Le timer reste volontairement desactive."
if [[ "$CONFIG_PRESERVED" == true ]]; then
  echo "La configuration existante a ete preservee."
fi
echo "Horaire prepare : ${TIMER_CALENDAR}, heure locale du host, avec delai aleatoire ${TIMER_RANDOM_DELAY}."
echo
echo "Validation avant activation :"
echo "  pve-host-backup notify-test"
echo "  systemctl start --no-block pve-host-backup.service"
echo "  journalctl -fu pve-host-backup.service"
echo "  pve-host-backup verify latest"
echo "  pve-host-backup stage latest"
echo "  pve-host-backup unstage latest"
echo
echo "Activation seulement apres ces tests :"
echo "  pve-host-backup auto-on"
echo "  pve-host-backup auto-status"
echo
echo "Desactivation simple :"
echo "  pve-host-backup auto-off"

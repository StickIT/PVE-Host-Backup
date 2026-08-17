#!/usr/bin/env bash
# Assistant de restauration prudent pour les sauvegardes PVE-Host-Backup.
# Profil initial valide sur nukebox; les operations critiques restent manuelles.

set -Eeuo pipefail
umask 077

VERSION="1.2.0"
AUDITED_PVE_MANAGER="9.2.10"
AUDITED_PVE_DOCS="9.2.4"
SUPPORTED_PVE_MAJOR="9"
AUDIT_DATE="2026-08-18"
PROFILE_NAME="nukebox-pve9"
PROFILE_HOST="nukebox"
PROFILE_DEBIAN_MAJOR="13"
PROFILE_KERNEL="7.0.14-11-pve"
PROFILE_CPU_THREADS="24"
PROFILE_MEMORY_GIB="30"

CONFIG_FILE="/etc/pve-host-backup.conf"
STATE_ROOT="/var/lib/pve-host-restore"
SESSION_ID=""
SESSION_DIR=""
ROLLBACK_DIR=""
REPORT_FILE=""
ACTIONS_FILE=""
BACKUP_DIR=""
BACKUP_ID=""
STAGE_DIR=""
MODE="audit"
SAME_MACHINE="unknown"
COMPATIBILITY="UNKNOWN"
WRITE_ALLOWED=false
REBOOT_REQUIRED=false
SYSTEMD_CHANGED=false
NETWORK_CHANGED=false
PROFILE_COMPLETE=false
HARDWARE_MISMATCH=false
HARDWARE_EVIDENCE=true
SOFTWARE_MISMATCH=false
COMPARE_DIFFERENCES=0
COMPARE_UNKNOWNS=0

PVE_NFS_STORAGE="dreambox-backup"
EXPECTED_NFS_SOURCE="192.168.11.133:/volume1/Proxmox"
BACKUP_ROOT="/mnt/pve/dreambox-backup/backups/PVE/host/nukebox"
STAGING_ROOT="/var/tmp/pve-host-restore"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BLUE=$'\033[34m'
else
  C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_BLUE=""
fi

say() { printf '%s\n' "$*"; }
info() { printf '%sINFO%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%sOK%s    %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%sATTENTION%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%sERREUR%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

banner() {
  local title=$1
  printf '\n%s╔══════════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_RESET"
  printf '%s║ %-60s ║%s\n' "$C_BOLD" "$title" "$C_RESET"
  printf '%s╚══════════════════════════════════════════════════════════════╝%s\n\n' "$C_BOLD" "$C_RESET"
}

step() {
  printf '\n%s[%s]%s %s%s%s\n' "$C_BLUE" "$1" "$C_RESET" "$C_BOLD" "$2" "$C_RESET"
}

risk_low() {
  printf '%s🟢 RISQUE FAIBLE%s — %s\n' "$C_GREEN" "$C_RESET" "$*"
}

risk_medium() {
  printf '%s🟠 RISQUE MODÉRÉ%s — %s\n' "$C_YELLOW" "$C_RESET" "$*"
}

risk_high() {
  printf '%s🔴 RISQUE ÉLEVÉ%s — %s\n' "$C_RED" "$C_RESET" "$*"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || fail "Exécuter cet assistant en root depuis la console PVE."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Commande requise absente : $1"
}

is_backup_id() {
  [[ $1 =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}(Z|[+-][0-9]{4})$ ]]
}

is_session_id() {
  [[ $1 =~ ^20[0-9]{6}-[0-9]{6}-[0-9]+$ ]]
}

is_ipv4() {
  local ip=$1 a b c d
  IFS=. read -r a b c d <<<"$ip"
  [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

is_ipv4_cidr() {
  local value=$1 ip prefix
  [[ $value == */* ]] || return 1
  ip=${value%/*}
  prefix=${value##*/}
  is_ipv4 "$ip" && [[ $prefix =~ ^[0-9]+$ ]] && ((10#$prefix <= 32))
}

is_safe_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

ask_yes_no() {
  local prompt=$1 default=${2:-no} answer suffix
  if [[ $default == yes ]]; then suffix='[O/n]'; else suffix='[o/N]'; fi
  while true; do
    if [[ -r /dev/tty ]]; then
      read -r -p "$prompt $suffix : " answer </dev/tty || answer=""
    else
      read -r -p "$prompt $suffix : " answer || answer=""
    fi
    answer=${answer,,}
    [[ -n $answer ]] || answer=$default
    case "$answer" in
      o|oui|y|yes) return 0 ;;
      n|non|no) return 1 ;;
      *) warn "Répondre par oui ou non." ;;
    esac
  done
}

ask_value() {
  local prompt=$1 default=$2 value
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt [$default] : " value </dev/tty || value=""
  else
    read -r -p "$prompt [$default] : " value || value=""
  fi
  printf '%s' "${value:-$default}"
}

confirm_phrase() {
  local phrase=$1 explanation=$2 answer
  warn "$explanation"
  if [[ -r /dev/tty ]]; then
    read -r -p "Taper exactement « $phrase » pour continuer : " answer </dev/tty || answer=""
  else
    read -r -p "Taper exactement « $phrase » pour continuer : " answer || answer=""
  fi
  [[ $answer == "$phrase" ]]
}

load_config() {
  local canonical config_mode
  if [[ -r $CONFIG_FILE ]]; then
    [[ ! -L $CONFIG_FILE ]] || fail "$CONFIG_FILE est un lien symbolique."
    [[ $(stat -c '%u' "$CONFIG_FILE") == 0 ]] || fail "$CONFIG_FILE n'appartient pas à root."
    config_mode=$(stat -c '%a' "$CONFIG_FILE")
    (( (8#$config_mode & 8#022) == 0 )) || fail "$CONFIG_FILE a des permissions non sûres."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  : "${PVE_NFS_STORAGE:=dreambox-backup}"
  : "${EXPECTED_NFS_SOURCE:=192.168.11.133:/volume1/Proxmox}"
  : "${BACKUP_ROOT:=/mnt/pve/dreambox-backup/backups/PVE/host/nukebox}"
  : "${STAGING_ROOT:=/var/tmp/pve-host-restore}"
  is_safe_name "$PVE_NFS_STORAGE" || fail "Identifiant de stockage invalide."
  [[ $BACKUP_ROOT == /mnt/pve/"$PVE_NFS_STORAGE"/backups/PVE/host/* ]] ||
    fail "BACKUP_ROOT inattendu : $BACKUP_ROOT"
  canonical=$(readlink -m -- "$BACKUP_ROOT")
  [[ $canonical == "$BACKUP_ROOT" ]] || fail "BACKUP_ROOT doit être un chemin canonique sans lien ni '..'."
  [[ $STAGING_ROOT =~ ^/var/tmp/pve-host-restore(-[A-Za-z0-9._-]+)?$ ]] ||
    fail "STAGING_ROOT inattendu."
  [[ $(readlink -m -- "$STAGING_ROOT") == "$STAGING_ROOT" ]] ||
    fail "STAGING_ROOT ne doit pas traverser un lien symbolique."
  [[ ! -L $STATE_ROOT ]] || fail "$STATE_ROOT ne doit pas être un lien symbolique."
}

create_session() {
  SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
  SESSION_DIR="$STATE_ROOT/sessions/$SESSION_ID"
  ROLLBACK_DIR="$SESSION_DIR/rollback"
  REPORT_FILE="$SESSION_DIR/REPORT.txt"
  ACTIONS_FILE="$SESSION_DIR/actions.tsv"
  install -d -m 0700 "$ROLLBACK_DIR" "$SESSION_DIR/proposals"
  : >"$ACTIONS_FILE"
  {
    printf 'PVE Host Restore Assistant\n'
    printf 'Session=%s\nMode=%s\nStarted=%s\n' "$SESSION_ID" "$MODE" "$(date -Is)"
    printf 'Assistant=%s\nProfile=%s\nAuditedPVE=%s\nAuditDate=%s\n' \
      "$VERSION" "$PROFILE_NAME" "$AUDITED_PVE_MANAGER" "$AUDIT_DATE"
  } >"$REPORT_FILE"
}

report() {
  [[ -n $REPORT_FILE ]] && printf '%s\n' "$*" >>"$REPORT_FILE"
}

resolve_backup() {
  local requested=${1:-latest} id
  if [[ $requested == latest ]]; then
    [[ -f $BACKUP_ROOT/LATEST.txt && ! -L $BACKUP_ROOT/LATEST.txt ]] ||
      fail "LATEST.txt absent ou symbolique sous $BACKUP_ROOT."
    id=$(<"$BACKUP_ROOT/LATEST.txt")
    BACKUP_DIR="$BACKUP_ROOT/$id"
  elif [[ -d $requested ]]; then
    BACKUP_DIR=$(readlink -f -- "$requested")
    id=$(basename "$BACKUP_DIR")
    case "$BACKUP_DIR" in
      "$BACKUP_ROOT"/*|/mnt/*|/media/*|/run/media/*) ;;
      *) fail "Le dossier explicite doit se trouver sous BACKUP_ROOT, /mnt, /media ou /run/media." ;;
    esac
  else
    id=$requested
    BACKUP_DIR="$BACKUP_ROOT/$id"
  fi
  is_backup_id "$id" || fail "Identifiant de sauvegarde invalide : $id"
  [[ -d $BACKUP_DIR && ! -L $BACKUP_DIR ]] || fail "Sauvegarde absente ou symbolique : $BACKUP_DIR"
  BACKUP_ID=$id
}

archive_is_safe() {
  local archive=$1
  tar --zstd -tf "$archive" | awk '
    BEGIN { bad=0 }
    /^\// { bad=1 }
    /(^|\/)\.\.($|\/)/ { bad=1 }
    END { exit bad ? 1 : 0 }
  '
}

verify_backup() {
  local file
  step "1/9" "Vérification cryptographique et structurelle"
  [[ -f $BACKUP_DIR/SHA256SUMS && ! -L $BACKUP_DIR/SHA256SUMS ]] ||
    fail "SHA256SUMS absent ou symbolique."
  (cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS)
  while IFS= read -r -d '' file; do
    zstd -t --quiet "$file"
    archive_is_safe "$file" || fail "Chemin dangereux détecté dans $(basename "$file")."
    ok "$(basename "$file") : zstd et chemins internes valides"
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.zst' -print0)
  report "VERIFY=OK"
}

extract_archive() {
  local archive=$1 destination=$2
  [[ -e $archive || -L $archive ]] || return 0
  [[ -f $archive && ! -L $archive ]] || fail "Archive non régulière ou symbolique : $archive"
  install -d -m 0700 "$destination"
  tar --zstd -xpf "$archive" -C "$destination" --no-same-owner
}

prepare_stage() {
  # Une extraction neuve par session évite de réutiliser un ancien staging
  # qui aurait pu être modifié après la vérification des archives.
  STAGE_DIR="$STAGING_ROOT/assistant-$BACKUP_ID-$SESSION_ID"
  [[ ! -e $STAGE_DIR ]] || fail "Staging de session déjà présent : $STAGE_DIR"
  install -d -m 0700 "$STAGE_DIR"
  extract_archive "$BACKUP_DIR/rootfs.tar.zst" "$STAGE_DIR/rootfs"
  extract_archive "$BACKUP_DIR/etc-pve.tar.zst" "$STAGE_DIR/etc-pve"
  extract_archive "$BACKUP_DIR/boot.tar.zst" "$STAGE_DIR/boot"
  extract_archive "$BACKUP_DIR/boot-efi.tar.zst" "$STAGE_DIR/boot-efi"
  extract_archive "$BACKUP_DIR/recovery.tar.zst" "$STAGE_DIR/recovery"
  ok "Extraction isolée terminée : $STAGE_DIR"
}

pve_manager_version_from_file() {
  awk '$1 == "pve-manager:" { print $2; exit }' "$1" 2>/dev/null || true
}

major_of() { printf '%s' "${1%%.*}"; }

current_pve_version() {
  pveversion -v 2>/dev/null |
    awk '$1 == "pve-manager:" && !found {print $2; found=1}'
}

backup_hostname() {
  local file="$STAGE_DIR/rootfs/etc/hostname"
  [[ -r $file ]] && tr -d '[:space:]' <"$file" || true
}

profile_value() {
  local file=$1 key=$2
  [[ -r $file ]] || return 0
  awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      print substr($0, length(wanted) + 2)
      exit
    }
  ' "$file"
}

one_line() {
  tr '\n\r\t' '   ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//'
}

current_system_disk() {
  local root_source
  root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  lsblk -snp -o PATH,TYPE "$root_source" 2>/dev/null |
    awk '$2 == "disk" {print $1; exit}' || true
}

write_current_profile() {
  local output=$1 system_disk disk_size="" disk_model="" disk_serial=""
  local dmi_product="" dmi_serial="" boot_mode boot_manager cluster_mode
  local root_source cpu_model timezone
  system_disk=$(current_system_disk)
  if [[ -n $system_disk && -b $system_disk ]]; then
    disk_size=$(blockdev --getsize64 "$system_disk" 2>/dev/null || true)
    disk_model=$(lsblk -dn -o MODEL "$system_disk" 2>/dev/null | one_line) || true
    disk_serial=$(lsblk -dn -o SERIAL "$system_disk" 2>/dev/null | one_line) || true
  fi
  if command -v dmidecode >/dev/null 2>&1; then
    dmi_product=$(dmidecode -s system-product-name 2>/dev/null | head -n 1 | one_line) || true
    dmi_serial=$(dmidecode -s system-serial-number 2>/dev/null | head -n 1 | one_line) || true
  fi
  cpu_model=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1 | one_line) || true
  [[ -d /sys/firmware/efi ]] && boot_mode=UEFI || boot_mode=BIOS
  [[ -e /etc/kernel/proxmox-boot-uuids ]] && boot_manager=proxmox-boot-tool || boot_manager=grub
  [[ -e /etc/pve/corosync.conf ]] && cluster_mode=cluster || cluster_mode=standalone
  root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  {
    printf 'FORMAT=1\n'
    printf 'CAPTURED_AT=%s\n' "$(date -Is)"
    printf 'HOSTNAME=%s\n' "$(hostname -s)"
    printf 'PVE_MANAGER=%s\n' "$(current_pve_version)"
    printf 'PVE_DOCS=%s\n' "$(dpkg-query -W -f='${Version}' pve-docs 2>/dev/null || true)"
    printf 'DEBIAN_VERSION_ID=%s\n' "$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
    printf 'KERNEL=%s\n' "$(uname -r)"
    printf 'CLUSTER_MODE=%s\n' "$cluster_mode"
    printf 'CPU_THREADS=%s\n' "$(nproc 2>/dev/null || true)"
    printf 'CPU_MODEL=%s\n' "$cpu_model"
    printf 'MEMORY_BYTES=%s\n' "$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)"
    printf 'DMI_PRODUCT=%s\n' "$dmi_product"
    printf 'DMI_SERIAL=%s\n' "$dmi_serial"
    printf 'BOOT_MODE=%s\n' "$boot_mode"
    printf 'BOOT_MANAGER=%s\n' "$boot_manager"
    printf 'ROOT_SOURCE=%s\n' "$root_source"
    printf 'ROOT_FSTYPE=%s\n' "$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    printf 'ROOT_UUID=%s\n' "$(findmnt -n -o UUID / 2>/dev/null || true)"
    printf 'SYSTEM_DISK=%s\n' "$system_disk"
    printf 'SYSTEM_DISK_SIZE=%s\n' "$disk_size"
    printf 'SYSTEM_DISK_MODEL=%s\n' "$disk_model"
    printf 'SYSTEM_DISK_SERIAL=%s\n' "$disk_serial"
    printf 'NETWORK_ADDRESS=%s\n' "$(awk '$1 == "address" {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)"
    printf 'NETWORK_GATEWAY=%s\n' "$(awk '$1 == "gateway" {print $2; exit}' /etc/network/interfaces 2>/dev/null || true)"
    printf 'NETWORK_BRIDGE_PORTS=%s\n' "$(awk '$1 == "bridge-ports" {for (i=2;i<=NF;i++) printf "%s%s", (i==2?"":" "), $i; exit}' /etc/network/interfaces 2>/dev/null || true)"
    printf 'NETWORK_BOND_SLAVES=%s\n' "$(awk '$1 == "bond-slaves" {for (i=2;i<=NF;i++) printf "%s%s", (i==2?"":" "), $i; exit}' /etc/network/interfaces 2>/dev/null || true)"
    printf 'TIMEZONE=%s\n' "$timezone"
  } >"$output"
}

compare_row() {
  local label=$1 saved=$2 current=$3 severity=${4:-normal} marker
  if [[ -z $saved || -z $current ]]; then
    marker='?'
    ((COMPARE_UNKNOWNS+=1))
  elif [[ $saved == "$current" ]]; then
    marker='OK'
  else
    marker='DIFF'
    ((COMPARE_DIFFERENCES+=1))
    [[ $severity == hardware && $SAME_MACHINE == yes ]] && HARDWARE_MISMATCH=true
    [[ $severity == software ]] && SOFTWARE_MISMATCH=true
  fi
  printf '│ %-18.18s │ %-24.24s │ %-24.24s │ %-4s │\n' \
    "$label" "${saved:-inconnu}" "${current:-inconnu}" "$marker"
  report "COMPARE_${label// /_}=${saved:-unknown}|${current:-unknown}|$marker"
}

choose_machine_identity() {
  local answer
  step "2/9" "Machine cible et identité matérielle"
  say "La sauvegarde provient du nœud $PROFILE_HOST."
  say "Un nouveau NVMe n'est PAS considéré comme le même disque : ses UUID changent."
  say "En revanche, carte mère, CPU, interfaces et périphériques PCI peuvent être identiques."
  say
  say "1. Même machine physique, seul le NVMe a été remplacé"
  say "2. Machine physique différente"
  say "3. Je ne suis pas certain"
  while true; do
    if [[ -r /dev/tty ]]; then
      read -r -p "Votre choix [1-3] : " answer </dev/tty || answer=""
    else
      read -r -p "Votre choix [1-3] : " answer || answer=""
    fi
    case "$answer" in
      1) SAME_MACHINE=yes; break ;;
      2) SAME_MACHINE=no; break ;;
      3) SAME_MACHINE=unknown; break ;;
      *) warn "Choisir 1, 2 ou 3." ;;
    esac
  done
  report "SAME_MACHINE=$SAME_MACHINE"
}

compare_versions() {
  local backup_file="$STAGE_DIR/recovery/inventory/pveversion.txt"
  local backup_profile="$STAGE_DIR/recovery/inventory/restore-profile.txt"
  local current_profile="$SESSION_DIR/current-profile.txt"
  local backup_version current_version backup_major current_major current_host saved_host
  local backup_docs current_docs saved_kernel current_kernel saved_memory current_memory
  local saved_timezone current_timezone
  local backup_debian current_debian backup_cluster current_cluster
  local saved_dmi_product current_dmi_product saved_dmi_serial current_dmi_serial
  local saved_boot current_boot saved_boot_manager current_boot_manager
  local saved_cpu current_cpu saved_cpu_model current_cpu_model
  local saved_disk_model current_disk_model saved_disk_serial current_disk_serial
  local saved_disk_size current_disk_size saved_root_fs current_root_fs
  local saved_root_uuid current_root_uuid saved_address current_address
  local saved_gateway current_gateway saved_ports current_ports saved_slaves current_slaves evidence
  step "3/9" "Compatibilité Proxmox VE"
  write_current_profile "$current_profile"
  [[ $(profile_value "$backup_profile" FORMAT) == 1 ]] && PROFILE_COMPLETE=true

  backup_version=$(profile_value "$backup_profile" PVE_MANAGER)
  [[ -n $backup_version ]] || backup_version=$(pve_manager_version_from_file "$backup_file")
  current_version=$(profile_value "$current_profile" PVE_MANAGER)
  backup_docs=$(profile_value "$backup_profile" PVE_DOCS)
  current_docs=$(profile_value "$current_profile" PVE_DOCS)
  saved_kernel=$(profile_value "$backup_profile" KERNEL)
  current_kernel=$(profile_value "$current_profile" KERNEL)
  saved_memory=$(profile_value "$backup_profile" MEMORY_BYTES)
  current_memory=$(profile_value "$current_profile" MEMORY_BYTES)
  saved_timezone=$(profile_value "$backup_profile" TIMEZONE)
  current_timezone=$(profile_value "$current_profile" TIMEZONE)
  saved_host=$(profile_value "$backup_profile" HOSTNAME)
  [[ -n $saved_host ]] || saved_host=$(backup_hostname)
  current_host=$(profile_value "$current_profile" HOSTNAME)
  backup_debian=$(profile_value "$backup_profile" DEBIAN_VERSION_ID)
  if [[ -z $backup_debian && -r $STAGE_DIR/rootfs/etc/os-release ]]; then
    backup_debian=$(sed -n 's/^VERSION_ID=["'"']\{0,1\}\([^"'"']*\)["'"']\{0,1\}$/\1/p' \
      "$STAGE_DIR/rootfs/etc/os-release" | head -n 1)
  fi
  current_debian=$(profile_value "$current_profile" DEBIAN_VERSION_ID)
  backup_cluster=$(profile_value "$backup_profile" CLUSTER_MODE)
  [[ -n $backup_cluster ]] || backup_cluster=standalone
  current_cluster=$(profile_value "$current_profile" CLUSTER_MODE)
  saved_dmi_product=$(profile_value "$backup_profile" DMI_PRODUCT)
  current_dmi_product=$(profile_value "$current_profile" DMI_PRODUCT)
  saved_dmi_serial=$(profile_value "$backup_profile" DMI_SERIAL)
  current_dmi_serial=$(profile_value "$current_profile" DMI_SERIAL)
  saved_boot=$(profile_value "$backup_profile" BOOT_MODE)
  current_boot=$(profile_value "$current_profile" BOOT_MODE)
  saved_boot_manager=$(profile_value "$backup_profile" BOOT_MANAGER)
  current_boot_manager=$(profile_value "$current_profile" BOOT_MANAGER)
  saved_cpu=$(profile_value "$backup_profile" CPU_THREADS)
  current_cpu=$(profile_value "$current_profile" CPU_THREADS)
  saved_cpu_model=$(profile_value "$backup_profile" CPU_MODEL)
  current_cpu_model=$(profile_value "$current_profile" CPU_MODEL)
  saved_disk_model=$(profile_value "$backup_profile" SYSTEM_DISK_MODEL)
  current_disk_model=$(profile_value "$current_profile" SYSTEM_DISK_MODEL)
  saved_disk_serial=$(profile_value "$backup_profile" SYSTEM_DISK_SERIAL)
  current_disk_serial=$(profile_value "$current_profile" SYSTEM_DISK_SERIAL)
  saved_disk_size=$(profile_value "$backup_profile" SYSTEM_DISK_SIZE)
  current_disk_size=$(profile_value "$current_profile" SYSTEM_DISK_SIZE)
  saved_root_fs=$(profile_value "$backup_profile" ROOT_FSTYPE)
  current_root_fs=$(profile_value "$current_profile" ROOT_FSTYPE)
  saved_root_uuid=$(profile_value "$backup_profile" ROOT_UUID)
  current_root_uuid=$(profile_value "$current_profile" ROOT_UUID)
  saved_address=$(profile_value "$backup_profile" NETWORK_ADDRESS)
  current_address=$(profile_value "$current_profile" NETWORK_ADDRESS)
  saved_gateway=$(profile_value "$backup_profile" NETWORK_GATEWAY)
  current_gateway=$(profile_value "$current_profile" NETWORK_GATEWAY)
  saved_ports=$(profile_value "$backup_profile" NETWORK_BRIDGE_PORTS)
  current_ports=$(profile_value "$current_profile" NETWORK_BRIDGE_PORTS)
  saved_slaves=$(profile_value "$backup_profile" NETWORK_BOND_SLAVES)
  current_slaves=$(profile_value "$current_profile" NETWORK_BOND_SLAVES)
  for evidence in "$saved_dmi_product" "$current_dmi_product" \
    "$saved_dmi_serial" "$current_dmi_serial" "$saved_cpu" "$current_cpu" \
    "$saved_cpu_model" "$current_cpu_model" "$saved_boot" "$current_boot"; do
    [[ -n $evidence ]] || HARDWARE_EVIDENCE=false
  done
  for evidence in "$backup_docs" "$current_docs" "$saved_kernel" "$current_kernel" \
    "$saved_root_fs" "$current_root_fs" "$saved_boot_manager" "$current_boot_manager"; do
    [[ -n $evidence ]] || PROFILE_COMPLETE=false
  done

  printf '┌────────────────────┬──────────────────────────┬──────────────────────────┬──────┐\n'
  printf '│ Élément            │ Sauvegarde               │ PVE actuel               │ État │\n'
  printf '├────────────────────┼──────────────────────────┼──────────────────────────┼──────┤\n'
  compare_row "PVE manager" "$backup_version" "$current_version"
  compare_row "PVE docs" "$backup_docs" "$current_docs" software
  compare_row "Debian" "$backup_debian" "$current_debian"
  compare_row "Kernel" "$saved_kernel" "$current_kernel" software
  compare_row "Hostname" "$saved_host" "$current_host"
  compare_row "Mode cluster" "$backup_cluster" "$current_cluster"
  compare_row "Produit DMI" "$saved_dmi_product" "$current_dmi_product" hardware
  compare_row "Série machine" "$saved_dmi_serial" "$current_dmi_serial" hardware
  compare_row "CPU threads" "$saved_cpu" "$current_cpu" hardware
  compare_row "Modèle CPU" "$saved_cpu_model" "$current_cpu_model" hardware
  compare_row "Mémoire octets" "$saved_memory" "$current_memory"
  compare_row "Boot" "$saved_boot" "$current_boot" hardware
  compare_row "Gestion boot" "$saved_boot_manager" "$current_boot_manager" software
  compare_row "FS racine" "$saved_root_fs" "$current_root_fs" software
  compare_row "Modèle NVMe" "$saved_disk_model" "$current_disk_model"
  compare_row "Taille NVMe" "$saved_disk_size" "$current_disk_size"
  compare_row "Série NVMe" "$saved_disk_serial" "$current_disk_serial"
  compare_row "UUID racine" "$saved_root_uuid" "$current_root_uuid"
  compare_row "Adresse" "$saved_address" "$current_address"
  compare_row "Passerelle" "$saved_gateway" "$current_gateway"
  compare_row "Bridge ports" "$saved_ports" "$current_ports"
  compare_row "Bond slaves" "$saved_slaves" "$current_slaves"
  compare_row "Fuseau" "$saved_timezone" "$current_timezone"
  printf '└────────────────────┴──────────────────────────┴──────────────────────────┴──────┘\n'
  say "Même matériel déclaré : $SAME_MACHINE"
  say "Profil détaillé backup : $PROFILE_COMPLETE"
  say "Preuves matérielles      : $HARDWARE_EVIDENCE"
  say "Profil courant conservé : $current_profile"

  [[ -n $backup_version && -n $current_version ]] || {
    COMPATIBILITY=RED
    WRITE_ALLOWED=false
    risk_high "Version PVE impossible à déterminer : audit uniquement."
    return
  }
  backup_major=$(major_of "$backup_version")
  current_major=$(major_of "$current_version")

  if [[ $current_cluster == cluster || $backup_cluster == cluster ]]; then
    COMPATIBILITY=RED
    WRITE_ALLOWED=false
    risk_high "Un cluster est détecté. Cet assistant est limité au nœud autonome nukebox."
  elif [[ $backup_major != "$current_major" || $current_major != "$SUPPORTED_PVE_MAJOR" ]]; then
    COMPATIBILITY=RED
    WRITE_ALLOWED=false
    risk_high "Versions majeures différentes ou non auditées : aucune écriture autorisée."
  elif [[ $current_host != "${saved_host:-$PROFILE_HOST}" ]]; then
    COMPATIBILITY=RED
    WRITE_ALLOWED=false
    risk_high "Le nom du nœud diffère. Réinstaller avec le même hostname avant de continuer."
  elif [[ $backup_debian != "$PROFILE_DEBIAN_MAJOR" || $current_debian != "$PROFILE_DEBIAN_MAJOR" ]]; then
    COMPATIBILITY=RED
    WRITE_ALLOWED=false
    risk_high "Base Debian différente du profil audité : aucune écriture autorisée."
  elif ! dpkg --compare-versions "$current_version" ge "$backup_version"; then
    COMPATIBILITY=RED
    WRITE_ALLOWED=false
    risk_high "Le PVE réinstallé est plus ancien que celui du backup : mettre PVE à niveau d'abord."
  elif [[ $HARDWARE_MISMATCH == true ]]; then
    COMPATIBILITY=RED
    WRITE_ALLOWED=false
    risk_high "Le matériel déclaré identique ne correspond pas aux preuves DMI/CPU/boot."
  elif [[ $backup_version == "$AUDITED_PVE_MANAGER" && \
    $current_version == "$AUDITED_PVE_MANAGER" && $SAME_MACHINE == yes && \
    $PROFILE_COMPLETE == true && $HARDWARE_EVIDENCE == true && \
    $SOFTWARE_MISMATCH == false ]]; then
    COMPATIBILITY=GREEN
    WRITE_ALLOWED=true
    risk_low "Même PVE, profil détaillé présent et matériel cohérent. Le wizard prudent est autorisé."
  else
    COMPATIBILITY=ORANGE
    WRITE_ALLOWED=true
    risk_medium "Même base majeure, mais profil ou valeurs différents. Confirmation par lot obligatoire."
  fi
  report "BACKUP_PVE=$backup_version"
  report "CURRENT_PVE=$current_version"
  report "COMPATIBILITY=$COMPATIBILITY"
  report "PROFILE_COMPLETE=$PROFILE_COMPLETE"
  report "HARDWARE_EVIDENCE=$HARDWARE_EVIDENCE"
  report "SOFTWARE_MISMATCH=$SOFTWARE_MISMATCH"
  report "COMPARE_DIFFERENCES=$COMPARE_DIFFERENCES"
  report "COMPARE_UNKNOWNS=$COMPARE_UNKNOWNS"
}

show_protected_zones() {
  step "4/9" "Zones protégées"
  risk_high "Toujours exclues de l'automatisation :"
  say "  • config.db et remplacement global de pmxcfs"
  say "  • table GPT, LVM, thin-pool et UUID du nouveau NVMe"
  say "  • /etc/fstab"
  say "  • /boot, EFI, GRUB et initramfs"
  say "  • certificats et clés générés par le nouveau PVE"
  say "  • copie récursive de /etc/pve"
  say "  • démarrage automatique des VM/CT restaurés"
  report "PROTECTED_ZONES=ENFORCED"
}

backup_current_file() {
  local target=$1 relative backup
  relative=${target#/}
  backup="$ROLLBACK_DIR/files/$relative"
  install -d -m 0700 "$(dirname "$backup")"
  if [[ -e $target || -L $target ]]; then
    cp -a -- "$target" "$backup"
    printf 'FILE\t%s\t%s\texisting\n' "$target" "$backup" >>"$ACTIONS_FILE"
  else
    printf 'FILE\t%s\t-\tcreated\n' "$target" >>"$ACTIONS_FILE"
  fi
}

copy_verified_file() {
  local source=$1 target=$2 checksum
  [[ -f $source && ! -L $source ]] || fail "Source non régulière refusée : $source"
  [[ ! -L $target ]] || fail "Cible symbolique refusée : $target"
  backup_current_file "$target"
  install -d -m 0755 "$(dirname "$target")"
  cp -a -- "$source" "$target"
  cmp -s -- "$source" "$target" || fail "La vérification après copie a échoué : $target"
  checksum=$(sha256sum "$source" | awk '{print $1}')
  printf 'VERIFY\t%s\t%s\t%s\n' "$target" "$checksum" "$source" >>"$ACTIONS_FILE"
  ok "Copie et comparaison réussies : $target"
  report "RESTORED_FILE=$target"
  if [[ $target == /etc/systemd/system/* ]]; then
    SYSTEMD_CHANGED=true
  fi
}

replace_first_directive() {
  local input=$1 output=$2 directive=$3 value=$4
  awk -v key="$directive" -v val="$value" '
    BEGIN { done=0 }
    $1 == key && !done {
      match($0, /^[[:space:]]*/)
      indent=substr($0, RSTART, RLENGTH)
      print indent key " " val
      done=1
      next
    }
    { print }
    END { if (!done) exit 3 }
  ' "$input" >"$output"
}

network_workflow() {
  local source="$STAGE_DIR/rootfs/etc/network/interfaces"
  local current=/etc/network/interfaces candidate="$SESSION_DIR/proposals/interfaces"
  local old_address old_gateway new_address new_gateway temp slaves nic missing=false
  local -a slave_array=()
  step "5/9" "Configuration réseau"
  risk_medium "Une erreur peut couper l'interface web et SSH. Console locale obligatoire pour appliquer."
  [[ -r $source ]] || { warn "Configuration réseau absente du backup."; return 0; }
  old_address=$(awk '$1 == "address" {print $2; exit}' "$source")
  old_gateway=$(awk '$1 == "gateway" {print $2; exit}' "$source")
  slaves=$(awk '$1 == "bond-slaves" {for (i=2;i<=NF;i++) printf "%s%s", (i==2?"":" "), $i; exit}' "$source")
  say "Topologie sauvegardée détectée : bond0 en 802.3ad → vmbr0."
  say "Interfaces attendues pour nukebox : ${slaves:-nic0 nic1}."
  read -r -a slave_array <<<"${slaves:-nic0 nic1}"
  for nic in "${slave_array[@]}"; do
    is_safe_name "$nic" || {
      risk_high "Nom d'interface invalide dans le backup : $nic"
      missing=true
      continue
    }
    if ip link show dev "$nic" >/dev/null 2>&1; then
      ok "Interface présente : $nic"
    else
      risk_high "Interface absente : $nic"
      missing=true
    fi
  done
  printf '\nDifférences actuelles :\n'
  diff -u "$current" "$source" || true

  new_address=$(ask_value "Adresse IPv4/CIDR souhaitée" "${old_address:-192.168.11.104/24}")
  is_ipv4_cidr "$new_address" || { warn "Adresse CIDR invalide; lot réseau ignoré."; return 0; }
  new_gateway=$(ask_value "Passerelle IPv4 souhaitée" "${old_gateway:-192.168.11.1}")
  is_ipv4 "$new_gateway" || { warn "Passerelle invalide; lot réseau ignoré."; return 0; }

  cp -a -- "$source" "$candidate"
  temp=$(mktemp "$SESSION_DIR/proposals/interfaces.XXXXXX")
  replace_first_directive "$candidate" "$temp" address "$new_address" || {
    warn "Directive address introuvable; candidat non généré."
    rm -f -- "$temp"
    return 0
  }
  mv -- "$temp" "$candidate"
  temp=$(mktemp "$SESSION_DIR/proposals/interfaces.XXXXXX")
  replace_first_directive "$candidate" "$temp" gateway "$new_gateway" || {
    warn "Directive gateway introuvable; candidat non généré."
    rm -f -- "$temp"
    return 0
  }
  mv -- "$temp" "$candidate"
  chmod 0600 "$candidate"

  if command -v ifquery >/dev/null 2>&1; then
    if ifquery -i "$candidate" -a >/dev/null 2>"$SESSION_DIR/proposals/interfaces.check.log"; then
      ok "Le parseur ifupdown2 accepte le fichier candidat."
    else
      risk_high "Le parseur ifupdown2 refuse le candidat. Aucune application possible."
      return 0
    fi
  else
    warn "ifquery absent : candidat créé mais non validé."
    return 0
  fi

  printf '\nCandidat proposé :\n'
  sed -n '1,240p' "$candidate"
  printf '\nDifférence candidat → système actuel :\n'
  diff -u "$current" "$candidate" || true
  if [[ -r $STAGE_DIR/rootfs/etc/hosts ]]; then
    printf '\nComparaison informative de /etc/hosts (jamais copié automatiquement) :\n'
    diff -u /etc/hosts "$STAGE_DIR/rootfs/etc/hosts" || true
  fi
  report "NETWORK_CANDIDATE=$candidate"

  if cmp -s -- "$current" "$candidate"; then
    ok "Le réseau actuel correspond déjà au candidat; aucune écriture nécessaire."
    report "NETWORK=ALREADY_IDENTICAL"
    return 0
  fi

  [[ $MODE != audit && $WRITE_ALLOWED == true ]] || {
    info "Audit uniquement : aucun fichier réseau n'a été modifié."
    return 0
  }
  [[ $SAME_MACHINE == yes ]] || {
    risk_high "Ce profil réseau personnalisé n'est applicable automatiquement que sur la même machine physique."
    return 0
  }
  [[ $missing == false ]] || {
    risk_high "Au moins une interface physique manque : application refusée."
    return 0
  }
  [[ -z ${SSH_CONNECTION:-} ]] || {
    risk_high "Session SSH détectée : application du réseau refusée."
    return 0
  }
  if confirm_phrase "APPLIQUER RESEAU" \
    "Le fichier sera installé mais le réseau ne sera pas rechargé automatiquement."; then
    copy_verified_file "$candidate" "$current"
    chmod 0644 "$current"
    REBOOT_REQUIRED=true
    NETWORK_CHANGED=true
  else
    info "Configuration réseau laissée inchangée."
  fi
}

storage_workflow() {
  local storage server export source current=""
  step "6/9" "Stockage NFS des sauvegardes"
  risk_medium "Le stockage est recréé par pvesm; storage.cfg n'est jamais copié en bloc."
  storage=$(ask_value "Identifiant du stockage" "$PVE_NFS_STORAGE")
  is_safe_name "$storage" || { warn "Identifiant invalide; lot ignoré."; return 0; }
  source=$EXPECTED_NFS_SOURCE
  server=$(ask_value "Serveur NFS" "${source%%:*}")
  export=$(ask_value "Export NFS" "${source#*:}")
  [[ $server =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && \
    $export =~ ^/[A-Za-z0-9._/-]+$ && "/$export/" != *"/../"* ]] || {
    warn "Serveur ou export invalide; lot ignoré."
    return 0
  }

  if pvesm status --storage "$storage" >/dev/null 2>&1; then
    current=$(pvesh get "/storage/$storage" --output-format yaml 2>&1 || true)
    say "Le stockage existe déjà :"
    say "$current"
    pvesm status --storage "$storage" || true
    report "STORAGE_$storage=ALREADY_PRESENT"
    return 0
  fi

  say "Proposition :"
  say "  pvesm add nfs $storage --server $server --export $export"
  say "  contenu guests : backups/PVE/guests"
  [[ $MODE != audit && $WRITE_ALLOWED == true ]] || {
    info "Audit uniquement : stockage non créé."
    return 0
  }
  if confirm_phrase "AJOUTER STOCKAGE" "Cette action ajoute uniquement la définition PVE; elle ne supprime aucun fichier NAS."; then
    pvesm add nfs "$storage" \
      --server "$server" \
      --export "$export" \
      --path "/mnt/pve/$storage" \
      --content backup \
      --content-dirs 'backup=backups/PVE/guests' \
      --options 'vers=4.1' \
      --prune-backups 'keep-last=3,keep-weekly=4,keep-monthly=3'
    printf 'STORAGE\t%s\t-\tcreated\n' "$storage" >>"$ACTIONS_FILE"
    pvesm status --storage "$storage"
    report "STORAGE_$storage=CREATED"
  else
    info "Stockage non créé."
  fi
}

collect_files() {
  local base=$1
  shift
  local relative
  for relative in "$@"; do
    [[ -e $base/$relative ]] || continue
    if [[ -f $base/$relative && ! -L $base/$relative ]]; then
      printf '%s\0' "$base/$relative"
    elif [[ -d $base/$relative ]]; then
      find "$base/$relative" -type f ! -type l -print0
    fi
  done
}

restore_file_group() {
  local title=$1 risk=$2 behavior=$3
  shift 3
  local source relative target answer_default=no
  local -a files=()
  mapfile -d '' -t files < <(collect_files "$STAGE_DIR/rootfs" "$@")
  ((${#files[@]})) || { info "$title : aucun fichier sauvegardé."; return 0; }
  printf '\n%s — %s\n' "$title" "$risk"
  if [[ $MODE == wizard && $behavior == low && $COMPATIBILITY == GREEN ]]; then
    answer_default=yes
  fi
  ask_yes_no "Examiner ce lot (${#files[@]} fichier(s)) ?" "$answer_default" || return 0

  for source in "${files[@]}"; do
    relative=${source#"$STAGE_DIR/rootfs"}
    target=$relative
    case "$target" in
      /etc/modules|/etc/modules-load.d/*|/etc/modprobe.d/*|/usr/local/bin/*|/usr/local/sbin/*|/etc/systemd/system/*|/etc/cron.d/*)
        ;;
      *) warn "Chemin hors liste sûre ignoré : $target"; continue ;;
    esac
    case "$target" in
      /usr/local/sbin/pve-host-backup|/usr/local/sbin/pve-host-restore)
        info "Outil du projet ignoré pour ne pas remplacer la version courante : $target"
        continue
        ;;
      /etc/systemd/system/pve-host-backup.*|/etc/systemd/system/pve-host-backup.service.d/*)
        info "Unité du projet ignorée pour ne pas remplacer la version courante : $target"
        continue
        ;;
    esac
    if [[ -e $target ]] && cmp -s -- "$source" "$target"; then
      ok "Déjà identique : $target"
      report "IDENTICAL_FILE=$target"
      continue
    fi
    printf '\nFichier : %s\n' "$target"
    if [[ -r $target ]]; then
      diff -u "$target" "$source" | sed -n '1,160p' || true
    else
      say "Nouveau fichier absent du système réinstallé."
    fi
    [[ $MODE != audit && $WRITE_ALLOWED == true ]] || continue
    ask_yes_no "Restaurer ce fichier ?" no || continue
    copy_verified_file "$source" "$target"
    case "$target" in
      /etc/modules|/etc/modules-load.d/*|/etc/modprobe.d/*) REBOOT_REQUIRED=true ;;
    esac
  done
}

package_review() {
  local saved="$STAGE_DIR/recovery/inventory/packages.txt"
  local saved_normalized="$SESSION_DIR/proposals/packages-backup.tsv"
  local current="$SESSION_DIR/proposals/packages-current.tsv"
  local missing="$SESSION_DIR/proposals/packages-missing.txt"
  local different="$SESSION_DIR/proposals/packages-version-differences.tsv"
  [[ -r $saved ]] || { info "Inventaire des paquets absent du backup."; return 0; }
  awk -F '\t' 'NF >= 2 && $1 !~ /^\$/ {print $1 "\t" $2}' "$saved" |
    sort -u >"$saved_normalized"
  dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null |
    sort -u >"$current"
  comm -23 <(cut -f1 "$saved_normalized") <(cut -f1 "$current") >"$missing"
  join -t $'\t' "$saved_normalized" "$current" |
    awk -F '\t' '$2 != $3 {print $1 "\tbackup=" $2 "\tactuel=" $3}' >"$different"

  say
  risk_medium "Les paquets sont comparés mais jamais installés automatiquement."
  printf 'Paquets présents dans le backup et absents actuellement : %s\n' \
    "$(wc -l <"$missing")"
  sed -n '1,80p' "$missing"
  printf 'Paquets avec une version différente : %s\n' "$(wc -l <"$different")"
  sed -n '1,80p' "$different"
  if [[ -d $STAGE_DIR/rootfs/etc/apt ]]; then
    printf '\nDifférences des sources APT (référence uniquement) :\n'
    diff -ruN /etc/apt "$STAGE_DIR/rootfs/etc/apt" | sed -n '1,160p' || true
  fi
  say "Listes complètes : $missing et $different"
  report "PACKAGE_REVIEW=$missing|$different"
}

timezone_workflow() {
  local backup_profile="$STAGE_DIR/recovery/inventory/restore-profile.txt"
  local saved current
  saved=$(profile_value "$backup_profile" TIMEZONE)
  current=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [[ -n $saved ]] || { info "Fuseau du backup inconnu."; return 0; }
  if [[ $saved == "$current" ]]; then
    ok "Fuseau déjà identique : $current"
    return 0
  fi
  risk_low "Fuseau différent : backup=$saved, actuel=${current:-inconnu}."
  timedatectl list-timezones | awk -v zone="$saved" '$0 == zone {found=1} END {exit !found}' || {
    warn "Fuseau sauvegardé inconnu de cette installation; aucune application."
    return 0
  }
  [[ $MODE != audit && $WRITE_ALLOWED == true ]] || return 0
  ask_yes_no "Rétablir le fuseau $saved ?" no || return 0
  timedatectl set-timezone "$saved"
  [[ $(timedatectl show -p Timezone --value) == "$saved" ]] || fail "Échec du changement de fuseau."
  printf 'TIMEZONE\t%s\t%s\tchanged\n' "${current:-inconnu}" "$saved" >>"$ACTIONS_FILE"
  ok "Fuseau rétabli : $saved"
  report "TIMEZONE_RESTORED=$saved"
}

host_files_workflow() {
  step "7/9" "Fichiers du host restaurables par lots"
  timezone_workflow
  package_review
  restore_file_group "Modules et passthrough" "RISQUE MODÉRÉ" medium \
    etc/modules etc/modules-load.d etc/modprobe.d
  restore_file_group "Scripts personnalisés" "RISQUE FAIBLE À MODÉRÉ" low \
    usr/local/bin usr/local/sbin
  if [[ $MODE == guided ]]; then
    restore_file_group "Unités systemd personnalisées" "RISQUE MODÉRÉ" medium \
      etc/systemd/system
    restore_file_group "Tâches cron personnalisées" "RISQUE MODÉRÉ" medium \
      etc/cron.d
  else
    info "Wizard : unités systemd et cron laissées pour le mode guidé."
  fi
  if [[ $SYSTEMD_CHANGED == true ]]; then
    systemctl daemon-reload
    ok "Configuration systemd rechargée après les copies sélectionnées."
  fi
}

pve_configuration_review() {
  local old="$STAGE_DIR/etc-pve" path relative current
  step "8/9" "Configurations propres à PVE"
  risk_high "Aucune copie récursive de /etc/pve. Les fichiers sont comparés et classés."
  [[ -d $old ]] || { warn "Archive /etc/pve absente."; return 0; }

  for relative in storage.cfg datacenter.cfg user.cfg jobs.cfg notifications.cfg; do
    path="$old/$relative"
    [[ -f $path ]] || continue
    current="/etc/pve/$relative"
    printf '\n%s\n' "$relative"
    case "$relative" in
      storage.cfg) risk_medium "Recréer les stockages avec pvesm; ne pas copier ce fichier." ;;
      datacenter.cfg|jobs.cfg|notifications.cfg) risk_medium "Comparer puis recréer les réglages dans PVE." ;;
      user.cfg) risk_high "Peut modifier authentification, ACL et jetons. Copie automatique interdite." ;;
    esac
    if [[ -r $current ]]; then
      diff -u "$current" "$path" | sed -n '1,200p' || true
    else
      sed -n '1,200p' "$path"
    fi
    cp -a -- "$path" "$SESSION_DIR/proposals/etc-pve-${relative//\//_}.saved"
  done

  if [[ -d $old/firewall ]]; then
    risk_high "Les règles firewall peuvent couper l'accès; elles sont exportées pour revue uniquement."
    tar -C "$old" -czf "$SESSION_DIR/proposals/etc-pve-firewall.tgz" firewall
  fi
  if [[ -d $old/nodes/$PROFILE_HOST/qemu-server || -d $old/nodes/$PROFILE_HOST/lxc ]]; then
    info "Configurations VM/CT détectées : référence uniquement; qmrestore/pct restore les recréeront."
  fi
  report "ETC_PVE=REVIEW_ONLY"
}

guest_restore_workflow() {
  local volid guest_id target_storage command_type phrase
  say
  risk_medium "Les dumps sont restaurés par les outils PVE natifs; aucun guest ne sera démarré."
  pvesm list "$PVE_NFS_STORAGE" --content backup 2>/dev/null || {
    warn "Impossible de lister les dumps du stockage $PVE_NFS_STORAGE."
    return 0
  }
  [[ $MODE != audit && $WRITE_ALLOWED == true ]] || return 0
  ask_yes_no "Restaurer maintenant un guest depuis un dump ?" no || return 0
  volid=$(ask_value "VOLID complet affiché ci-dessus" "-")
  [[ $volid == "$PVE_NFS_STORAGE":backup/* ]] || {
    warn "VOLID hors du stockage attendu; restauration refusée."
    return 0
  }
  guest_id=$(ask_value "VMID/CTID cible" "-")
  [[ $guest_id =~ ^[1-9][0-9]*$ ]] || { warn "Identifiant invalide."; return 0; }
  target_storage=$(ask_value "Stockage disque cible (ex. local-lvm)" "local-lvm")
  is_safe_name "$target_storage" || { warn "Stockage cible invalide."; return 0; }
  case "$volid" in
    *vzdump-qemu-*) command_type=qmrestore ;;
    *vzdump-lxc-*) command_type=pct ;;
    *) warn "Type de dump non reconnu."; return 0 ;;
  esac
  phrase="RESTAURER GUEST $guest_id"
  confirm_phrase "$phrase" "Vérifier le VMID et le stockage cible. Le guest restera arrêté." || return 0
  if [[ $command_type == qmrestore ]]; then
    qmrestore "$volid" "$guest_id" --storage "$target_storage"
  else
    pct restore "$guest_id" "$volid" --storage "$target_storage"
  fi
  report "RESTORED_GUEST=$guest_id:$volid"
}

health_check() {
  local failed=0 mount_source="" service failed_units
  step "9/9" "Contrôle final"
  say "Version PVE : $(pveversion 2>/dev/null || true)"
  failed_units=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)
  if [[ -n $failed_units ]]; then
    risk_medium "Des unités systemd sont en échec :"
    say "$failed_units"
    failed=1
  else
    ok "Aucune unité systemd en échec."
  fi
  for service in pve-cluster.service pvedaemon.service pveproxy.service pvestatd.service; do
    if systemctl is-active --quiet "$service"; then
      ok "Service actif : $service"
    else
      warn "Service PVE inactif : $service"
      ((failed+=1))
    fi
  done
  if pvesm status --storage "$PVE_NFS_STORAGE"; then
    ok "Stockage de sauvegarde visible par PVE."
  else
    warn "Le stockage $PVE_NFS_STORAGE n'est pas actif."
    ((failed+=1))
  fi
  say "Vue de tous les stockages (les erreurs d'un ancien PBS sont informatives) :"
  pvesm status || true
  mount_source=$(findmnt -n -T "/mnt/pve/$PVE_NFS_STORAGE" -o SOURCE 2>/dev/null || true)
  if [[ $mount_source == "$EXPECTED_NFS_SOURCE" ]]; then
    ok "Montage NFS attendu actif : $mount_source"
  else
    warn "Montage NFS inattendu ou absent : ${mount_source:-absent}"
    failed=1
  fi
  if command -v ifquery >/dev/null 2>&1; then
    if ifquery -i /etc/network/interfaces -a >/dev/null 2>&1; then
      ok "Configuration réseau acceptée par ifupdown2."
    else
      warn "Configuration réseau refusée par ifupdown2."
      ((failed+=1))
    fi
  fi
  if findmnt -n -o OPTIONS / | tr ',' '\n' | grep -qx rw; then
    ok "Système racine monté en lecture/écriture."
  else
    warn "Le système racine ne semble pas monté en lecture/écriture."
    ((failed+=1))
  fi
  lvs -a 2>/dev/null || true
  ip -br address show || true
  ip route show || true
  qm list || true
  pct list || true
  journalctl -p err -b --no-pager -n 80 || true
  if [[ $REBOOT_REQUIRED == true ]]; then
    risk_medium "Un redémarrage de contrôle est requis. Ne pas démarrer les guests avant validation."
  fi
  report "HEALTH_FAILED=$failed"
  report "REBOOT_REQUIRED=$REBOOT_REQUIRED"
  report "FINISHED=$(date -Is)"
  say
  say "Rapport : $REPORT_FILE"
  say "Retour arrière : $ROLLBACK_DIR"
  say "Recontrôle après redémarrage : pve-host-restore verify-session $SESSION_ID"
}

pause_for_network_reboot() {
  say
  risk_medium "Le fichier réseau a changé. La session s'arrête volontairement avant toute autre restauration."
  say "1. Relire /etc/network/interfaces depuis la console locale."
  say "2. Redémarrer le host sans démarrer les guests."
  say "3. Vérifier bond0, vmbr0, l'adresse et la route."
  say "4. Relancer ensuite : pve-host-restore audit $BACKUP_DIR"
  say "5. Puis reprendre : pve-host-restore wizard $BACKUP_DIR"
  say
  say "Session : $SESSION_ID"
  say "Rapport : $REPORT_FILE"
  say "Rollback disponible : pve-host-restore rollback $SESSION_ID"
  report "PAUSED_FOR_NETWORK_REBOOT=true"
}

run_audit() {
  choose_machine_identity
  compare_versions
  show_protected_zones
  network_workflow
  storage_workflow
  host_files_workflow
  pve_configuration_review
  health_check
}

run_wizard() {
  choose_machine_identity
  compare_versions
  show_protected_zones
  [[ $WRITE_ALLOWED == true ]] || {
    warn "Le verdict interdit l'écriture. Le wizard continue en audit."
    MODE=audit
  }
  network_workflow
  if [[ $NETWORK_CHANGED == true ]]; then
    pause_for_network_reboot
    return 0
  fi
  storage_workflow
  host_files_workflow
  pve_configuration_review
  guest_restore_workflow
  health_check
}

run_guided() {
  local choice
  choose_machine_identity
  compare_versions
  show_protected_zones
  while true; do
    banner "RESTAURATION GUIDÉE — choisir un lot"
    say "1. Réseau"
    say "2. Stockage NFS"
    say "3. Fichiers du host"
    say "4. Comparaison /etc/pve"
    say "5. Restaurer un guest"
    say "6. Contrôle final"
    say "7. Quitter"
    if [[ -r /dev/tty ]]; then
      read -r -p "Choix [1-7] : " choice </dev/tty || choice=7
    else
      read -r -p "Choix [1-7] : " choice || choice=7
    fi
    case "$choice" in
      1)
        network_workflow
        if [[ $NETWORK_CHANGED == true ]]; then
          pause_for_network_reboot
          break
        fi
        ;;
      2) storage_workflow ;;
      3) host_files_workflow ;;
      4) pve_configuration_review ;;
      5) guest_restore_workflow ;;
      6) health_check ;;
      7) break ;;
      *) warn "Choix invalide." ;;
    esac
  done
}

rollback_session() {
  local id=$1 dir actions type target saved state
  is_session_id "$id" || fail "Identifiant de session invalide : $id"
  dir="$STATE_ROOT/sessions/$id"
  actions="$dir/actions.tsv"
  [[ -r $actions ]] || fail "Session ou manifeste absent : $id"
  confirm_phrase "RETOUR ARRIERE $id" \
    "Les fichiers sauvegardés avant cette session vont être rétablis. Le réseau ne sera pas rechargé." ||
    fail "Retour arrière annulé."
  tac "$actions" | while IFS=$'\t' read -r type target saved state; do
    case "$type:$state" in
      FILE:existing)
        [[ -e $saved || -L $saved ]] || fail "Sauvegarde de retour absente : $saved"
        rm -f -- "$target"
        install -d -m 0755 "$(dirname "$target")"
        cp -a -- "$saved" "$target"
        ok "Rétabli : $target"
        ;;
      FILE:created)
        rm -f -- "$target"
        ok "Fichier créé supprimé : $target"
        ;;
      STORAGE:created)
        warn "Stockage ajouté pendant la session : $target"
        if ask_yes_no "Retirer uniquement sa définition PVE ?" no; then
          pvesm remove "$target"
        fi
        ;;
      TIMEZONE:changed)
        if timedatectl list-timezones | awk -v zone="$target" '$0 == zone {found=1} END {exit !found}'; then
          timedatectl set-timezone "$target"
          ok "Fuseau rétabli : $target"
        else
          warn "Ancien fuseau non reconnu : $target"
        fi
        ;;
    esac
  done
  systemctl daemon-reload
  warn "Redémarrer et contrôler le réseau, les stockages et systemctl --failed."
}

verify_session() {
  local id=$1 dir actions output type target expected source actual failed=0 failed_units
  local mount_source service
  is_session_id "$id" || fail "Identifiant de session invalide : $id"
  dir="$STATE_ROOT/sessions/$id"
  actions="$dir/actions.tsv"
  [[ -r $actions ]] || fail "Session ou manifeste absent : $id"
  output="$dir/VERIFY-$(date +%Y%m%d-%H%M%S).txt"
  banner "VÉRIFICATION DE SESSION $id"
  {
    printf 'Session=%s\nChecked=%s\n' "$id" "$(date -Is)"
    while IFS=$'\t' read -r type target expected source; do
      case "$type" in
        VERIFY)
          if [[ -f $target && ! -L $target ]]; then
            actual=$(sha256sum "$target" | awk '{print $1}')
            if [[ $actual == "$expected" ]]; then
              printf 'OK\t%s\n' "$target"
            else
              printf 'DIFF\t%s\tattendu=%s\tactuel=%s\n' "$target" "$expected" "$actual"
              ((failed+=1))
            fi
          else
            printf 'ABSENT\t%s\n' "$target"
            ((failed+=1))
          fi
          ;;
        STORAGE)
          if [[ $source == created ]]; then
            if pvesm status --storage "$target" >/dev/null 2>&1; then
              printf 'OK_STORAGE\t%s\n' "$target"
            else
              printf 'FAILED_STORAGE\t%s\n' "$target"
              ((failed+=1))
            fi
          fi
          ;;
        TIMEZONE)
          actual=$(timedatectl show -p Timezone --value 2>/dev/null || true)
          if [[ $actual == "$expected" ]]; then
            printf 'OK_TIMEZONE\t%s\n' "$actual"
          else
            printf 'FAILED_TIMEZONE\tattendu=%s\tactuel=%s\n' "$expected" "${actual:-absent}"
            ((failed+=1))
          fi
          ;;
      esac
    done <"$actions"
    if command -v ifquery >/dev/null 2>&1; then
      if ifquery -i /etc/network/interfaces -a >/dev/null 2>&1; then
        printf 'OK_NETWORK_PARSE\t/etc/network/interfaces\n'
      else
        printf 'FAILED_NETWORK_PARSE\t/etc/network/interfaces\n'
        ((failed+=1))
      fi
    fi
    mount_source=$(findmnt -n -T "/mnt/pve/$PVE_NFS_STORAGE" -o SOURCE 2>/dev/null || true)
    if [[ $mount_source == "$EXPECTED_NFS_SOURCE" ]]; then
      printf 'OK_NFS\t%s\n' "$mount_source"
    else
      printf 'FAILED_NFS\tattendu=%s\tactuel=%s\n' \
        "$EXPECTED_NFS_SOURCE" "${mount_source:-absent}"
      ((failed+=1))
    fi
    for service in pve-cluster.service pvedaemon.service pveproxy.service pvestatd.service; do
      if systemctl is-active --quiet "$service"; then
        printf 'OK_SERVICE\t%s\n' "$service"
      else
        printf 'FAILED_SERVICE\t%s\n' "$service"
        ((failed+=1))
      fi
    done
    failed_units=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)
    if [[ -n $failed_units ]]; then
      printf 'FAILED_SYSTEMD_UNITS\n'
      printf '%s\n' "$failed_units"
      ((failed+=1))
    else
      printf 'OK_SYSTEMD\n'
    fi
    printf 'RESULT=%s\n' "$([[ $failed == 0 ]] && printf OK || printf FAILED)"
  } >"$output"
  cat "$output"
  say
  say "Rapport de vérification : $output"
  if ((failed > 0)); then
    risk_high "$failed contrôle(s) ont échoué. Ne pas démarrer les guests; examiner ou effectuer le rollback."
    return 1
  fi
  ok "Tous les éléments effectivement appliqués par la session correspondent."
}

self_test() {
  local temporary candidate
  is_ipv4 192.168.11.104
  ! is_ipv4 999.1.1.1
  is_ipv4_cidr 192.168.11.104/24
  ! is_ipv4_cidr 192.168.11.104/99
  is_backup_id 2026-08-17T13-40-37Z
  is_backup_id 2026-08-17T22-40-37+0900
  ! is_backup_id ../../etc/passwd
  [[ $(major_of 9.2.10) == 9 ]]
  is_safe_name dreambox-backup
  ! is_safe_name '../bad'
  is_session_id 20260818-120000-1234
  ! is_session_id ../../etc
  temporary=$(mktemp -d /tmp/pve-host-restore-selftest.XXXXXX)
  printf 'FORMAT=1\nPVE_MANAGER=9.2.10\n' >"$temporary/profile.txt"
  [[ $(profile_value "$temporary/profile.txt" PVE_MANAGER) == 9.2.10 ]]
  printf 'iface vmbr0 inet static\n        address 192.168.11.104/24\n' >"$temporary/interfaces"
  candidate="$temporary/candidate"
  replace_first_directive "$temporary/interfaces" "$candidate" address 192.168.11.105/24
  grep -q 'address 192.168.11.105/24' "$candidate"
  rm -rf --one-file-system -- "$temporary"
  say "Self-test restore-assistant : OK"
}

usage() {
  cat <<EOF
PVE Host Restore Assistant $VERSION

Audité pour : PVE $AUDITED_PVE_MANAGER, documentation $AUDITED_PVE_DOCS
Date d'audit : $AUDIT_DATE
Profil       : $PROFILE_NAME, Debian $PROFILE_DEBIAN_MAJOR, host $PROFILE_HOST
Référence    : kernel $PROFILE_KERNEL, $PROFILE_CPU_THREADS threads, ${PROFILE_MEMORY_GIB} Gio RAM

Usage:
  pve-host-restore audit [latest|DATE]      Vérification et comparaison sans écriture
  pve-host-restore audit /mnt/usb/DATE      Audit depuis une copie USB hors NFS
  pve-host-restore wizard [latest|DATE]     Parcours sûr avec propositions automatiques
  pve-host-restore guided [latest|DATE]     Choix manuel de chaque lot
  pve-host-restore verify-session SESSION   Comparaison après application/redémarrage
  pve-host-restore rollback SESSION         Retour arrière des fichiers d'une session
  pve-host-restore --self-test              Tests internes sans PVE
EOF
}

main() {
  local action=${1:-help} requested=${2:-latest}
  case "$action" in
    help|-h|--help) usage; exit 0 ;;
    --self-test) self_test; exit 0 ;;
  esac
  require_root
  require_command tar
  require_command zstd
  require_command sha256sum
  require_command pveversion
  require_command pvesm
  require_command pvesh
  require_command systemctl
  require_command findmnt
  require_command qm
  require_command pct
  require_command ip
  require_command lsblk
  require_command blockdev
  require_command lscpu
  require_command dpkg-query
  require_command timedatectl
  require_command comm
  require_command join
  load_config

  case "$action" in
    verify-session)
      [[ -n ${2:-} ]] || fail "Indiquer l'identifiant de session."
      verify_session "$2"
      exit 0
      ;;
    rollback)
      [[ -n ${2:-} ]] || fail "Indiquer l'identifiant de session."
      rollback_session "$2"
      exit 0
      ;;
    audit|wizard|guided) MODE=$action ;;
    *) usage >&2; exit 2 ;;
  esac

  banner "PVE HOST RESTORE ASSISTANT $VERSION"
  say "Profil audité : PVE $AUDITED_PVE_MANAGER / Debian $PROFILE_DEBIAN_MAJOR / $PROFILE_HOST"
  say "Date d'audit  : $AUDIT_DATE"
  say "Mode demandé  : $MODE"
  resolve_backup "$requested"
  create_session
  verify_backup
  prepare_stage

  case "$MODE" in
    audit) run_audit ;;
    wizard) run_wizard ;;
    guided) run_guided ;;
  esac
}

main "$@"

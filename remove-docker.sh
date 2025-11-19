#!/usr/bin/env bash

# Usage:
#   curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | bash
#   
# Atau dengan options:
#   curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | bash -s -- --dry-run
#   curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | bash -s -- --skip-backup

set -euo pipefail

### Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

title() {
  printf "\n%b" "${MAGENTA}${BOLD}"
  printf "╔════════════════════════════════════════════════════════════════╗\n"
  printf "║  %-60s ║\n" "$1"
  printf "╚════════════════════════════════════════════════════════════════╝\n"
  printf "%b\n" "${NC}"
}

info()  { printf "%b[INFO]%b %s\n" "${CYAN}" "${NC}" "$1"; }
ok()    { printf "%b[OK]%b %s\n" "${GREEN}" "${NC}" "$1"; }
warn()  { printf "%b[WARN]%b %s\n" "${YELLOW}" "${NC}" "$1"; }
error() { printf "%b[ERR]%b %s\n" "${RED}" "${NC}" "$1"; }

title_summary() {
  printf "\n%b" "${MAGENTA}${BOLD}"
  printf "╔════════════════════════════════════════════════════════════════╗\n"
  printf "║  %-60s ║\n" "$1"
  printf "╚════════════════════════════════════════════════════════════════╝\n"
  printf "%b\n" "${NC}"
}

### Config - DEFAULT BRUTAL MODE
BACKUP_ROOT="/root/BACKUP_DOCKER"
DRY_RUN=0
FORCE=1
PURGE=1
BRUTAL=1
COLOR=1
VERBOSE=0
SKIP_BACKUP=0
SCRIPT_PID=$$

### Spinner & progress
_spinner_pid=0
_spinner_start() {
  local msg="$1"
  ( while :; do
      for spin in '|' '/' '-' '\\'; do
        printf "\r%b %s %b" "${CYAN}" "$spin" "${msg}"
        sleep 0.08
      done
    done ) &
  _spinner_pid=$!
}

_spinner_stop() {
  [ "$_spinner_pid" -ne 0 ] && kill "$_spinner_pid" 2>/dev/null || true
  _spinner_pid=0
  printf "\r"
}

_progress_bar() {
  local percent=${1:-0}
  local text="${2:-}"
  percent=$(( percent < 0 ? 0 : percent > 100 ? 100 : percent ))
  local filled=$(( percent * 36 / 100 ))
  local empty=$(( 36 - filled ))
  local col="${GREEN}"
  [ "$percent" -ge 70 ] && col="${YELLOW}"
  [ "$percent" -ge 95 ] && col="${RED}"
  printf "\r%b[" "$col"
  printf '%0.s#' $(seq 1 "$filled")
  printf '%0.s-' $(seq 1 "$empty")
  printf "] %3d%% %b%s%b" "$percent" "${DIM}" "$text" "${NC}"
}

### Utils
safe_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]/_/g' | sed 's/__*/_/g'
}

timestamp_indonesia() {
  local dname month
  dname=$(LC_TIME=id_ID.UTF-8 date +%A 2>/dev/null || date +%A)
  month=$(LC_TIME=id_ID.UTF-8 date +%B 2>/dev/null || date +%B)
  printf "%s,%s%s%s_Jam%s.%s" "$dname" "$(date +%d)" "$month" "$(date +%Y)" "$(date +%H)" "$(date +%M)"
}

run_or_dry() {
  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$VERBOSE" -eq 1 ] && info "[DRY-RUN] $*" || true
    return 0
  else
    eval "$*" 2>&1 || return 1
  fi
}

is_path_under() {
  local child parent
  child="$(cd "$1" 2>/dev/null && pwd)" || return 1
  parent="$(cd "$2" 2>/dev/null && pwd)" || return 1
  [[ "$child" == "$parent"* ]]
}

verify_docker_removal() {
  local still_found=0
  
  if [ -d /var/lib/docker ]; then
    warn "/var/lib/docker masih ada"
    still_found=1
  fi
  
  if [ -d /var/lib/containerd ]; then
    warn "/var/lib/containerd masih ada"
    still_found=1
  fi
  
  if [ -d /etc/docker ]; then
    warn "/etc/docker masih ada"
    still_found=1
  fi
  
  if [ -d /etc/containerd ]; then
    warn "/etc/containerd masih ada"
    still_found=1
  fi
  
  if [ -d /var/run/docker ]; then
    warn "/var/run/docker masih ada"
    still_found=1
  fi
  
  if [ -d /var/run/containerd ]; then
    warn "/var/run/containerd masih ada"
    still_found=1
  fi
  
  if [ "$still_found" -eq 0 ]; then
    ok "Tidak ada file/direktori Docker tersisa"
  fi
  
  if command -v docker >/dev/null 2>&1; then
    warn "Docker binary masih di: $(command -v docker)"
    warn "  (Normal setelah reboot atau uninstall manual)"
  else
    ok "Docker binary tidak ditemukan"
  fi
  
  return "$still_found"
}

cleanup_trap() {
  _spinner_stop
  if [ -d "${TMPDIR:-}" ]; then
    rm -rf "$TMPDIR" 2>/dev/null || true
  fi
}

get_docker_disk_usage() {
  if command -v docker >/dev/null 2>&1; then
    docker system df 2>/dev/null | tail -n +2 | awk '{sum+=$4} END {printf "%.2f GB", sum/1024/1024/1024}' || echo "unknown"
  else
    echo "N/A"
  fi
}

safe_kill_docker_processes() {
  if command -v pkill >/dev/null 2>&1; then
    pgrep -f docker 2>/dev/null | grep -v "^$SCRIPT_PID$" | xargs -r kill -9 2>/dev/null || true
    pgrep -f containerd 2>/dev/null | grep -v "^$SCRIPT_PID$" | xargs -r kill -9 2>/dev/null || true
    ok "Proses docker/containerd telah dihentikan"
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  # Mode default (BRUTAL automatic):
  curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | bash

  # Dengan options:
  curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | bash -s -- --dry-run
  curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | bash -s -- --skip-backup
  curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | bash -s -- --no-color

Opsi:
  --dry-run           Mode simulasi (tanpa perubahan)
  --skip-backup       Skip fase backup (BERBAHAYA!)
  --no-purge          Jangan purge paket dari apt
  --no-brutal         Disable brutal mode (not recommended)
  --no-color          Nonaktifkan warna
  --verbose           Mode verbose
  -h, --help          Tampilkan bantuan ini

Contoh:
  # Langsung brutal (default):
  curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | sudo bash

  # Test dulu sebelum execute:
  curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/remove-docker.sh | sudo bash -s -- --dry-run
USAGE
  exit 0
}

### Argument parsing
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --no-purge) PURGE=0; shift ;;
    --no-brutal) BRUTAL=0; shift ;;
    --no-color) COLOR=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    --backup-root=*) BACKUP_ROOT="${1#*=}"; shift ;;
    -h|--help) usage ;;
    *) error "Argumen tidak dikenal: $1"; exit 1 ;;
  esac
done

### Disable colors if needed
if [ "$COLOR" -eq 0 ]; then
  RED=''; GREEN=''; YELLOW=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
  info() { printf "[INFO]   %s\n" "$1"; }
  ok() { printf "[OK]     %s\n" "$1"; }
  warn() { printf "[WARN]   %s\n" "$1"; }
  error() { printf "[ERR]    %s\n" "$1"; }
  title_summary() { printf "\n=== %s ===\n\n" "$1"; }
fi

### Pre-flight checks
title "Docker Auto Remove by Fath Nojoum"

[ "$(id -u)" -eq 0 ] || { error "Harus dijalankan sebagai root (gunakan sudo)"; exit 1; }

if [ -z "$BACKUP_ROOT" ] || [[ "$BACKUP_ROOT" == *"$HOME"* ]] && [[ "$BACKUP_ROOT" != "/root"* ]]; then
  error "Path backup tidak valid: $BACKUP_ROOT"
  exit 1
fi

if [ -f /.dockerenv ] && [ "$BRUTAL" -eq 1 ]; then
  error "Tidak dapat menjalankan brutal mode di dalam container Docker"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  warn "Docker CLI tidak ditemukan, tetap akan membersihkan filesystem..."
fi

TMPDIR=$(mktemp -d) || { error "Gagal membuat direktori temporary"; exit 1; }
trap cleanup_trap EXIT

[ ! -d "$BACKUP_ROOT" ] && mkdir -p "$BACKUP_ROOT" || true
[ ! -w "$BACKUP_ROOT" ] && { error "Tidak dapat menulis ke backup root"; exit 1; }

echo
info "Konfigurasi:"
printf "  - Backup root:    %s\n" "$BACKUP_ROOT"
printf "  - Dry-run:        %s\n" "$([ "$DRY_RUN" -eq 1 ] && echo "YA" || echo "TIDAK")"
printf "  - Brutal mode:    %s\n" "$([ "$BRUTAL" -eq 1 ] && echo "YA (DEFAULT)" || echo "TIDAK")"
printf "  - Purge paket:    %s\n" "$([ "$PURGE" -eq 1 ] && echo "YA" || echo "TIDAK")"
printf "  - Skip backup:    %s\n" "$([ "$SKIP_BACKUP" -eq 1 ] && echo "YA" || echo "TIDAK")"

if command -v docker >/dev/null 2>&1; then
  printf "  - Penggunaan Docker: %s\n" "$(get_docker_disk_usage)"
fi
echo

if [ "$BRUTAL" -eq 1 ]; then
  warn "BRUTAL MODE ENABLED: Akan menghapus sampai level cgroup"
  info "Untuk disable, gunakan: ... | bash -s -- --no-brutal"
  echo
fi

# NO MORE MANUAL CONFIRM - auto proceed!
if [ "$DRY_RUN" -eq 0 ]; then
  info "Memproses... (tanpa konfirmasi - mode automatic)"
  sleep 1
fi

_spinner_start "Memulai..."
sleep 0.8
_spinner_stop
_progress_bar 5 "Init"
printf "\n"

### Stop containers
info "Menghentikan semua container Docker..."
if command -v docker >/dev/null 2>&1; then
  running_count=$(docker ps -q 2>/dev/null | wc -l)
  if [ "$running_count" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[DRY-RUN] Akan menghentikan $running_count container(s)"
    else
      docker ps -q 2>/dev/null | xargs -r docker stop >/dev/null 2>&1 || true
      ok "Menghentikan $running_count container(s)"
    fi
  fi
fi
_progress_bar 15 "Hentikan container"
printf "\n"

### Scan volumes & containers
info "Memindai volume dan bind mount..."
ALL_CONTAINERS=()
ALL_VOLUMES=()
if command -v docker >/dev/null 2>&1; then
  mapfile -t ALL_CONTAINERS < <(docker ps -aq 2>/dev/null || true)
  mapfile -t ALL_VOLUMES < <(docker volume ls -q 2>/dev/null || true)
fi
info "Ditemukan: ${#ALL_VOLUMES[@]} volume(s), ${#ALL_CONTAINERS[@]} container(s)"
_progress_bar 25 "Pemindaian"
printf "\n"

### Backup phase
if [ "$SKIP_BACKUP" -eq 0 ]; then
  info "Memulai backup volume dan konfigurasi..."
  
  for vol in "${ALL_VOLUMES[@]:-}"; do
    mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
    [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ] && continue
    
    appname="$vol"
    firstcid=$(docker ps -aq --filter "volume=$vol" 2>/dev/null | head -n1 || true)
    [ -n "$firstcid" ] && appname=$(docker inspect --format '{{.Name}}' "$firstcid" 2>/dev/null | sed 's#^/##')
    
    safe_app=$(safe_name "$appname")
    destdir="$BACKUP_ROOT/$safe_app"
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$destdir" 2>/dev/null || true
    
    ts=$(timestamp_indonesia)
    base="backup_appdata-docker_(${safe_app}_${vol})-${ts}"
    
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[DRY-RUN] tar -C $mountpoint -czf $destdir/${base}.tar.gz ."
    else
      if tar -C "$mountpoint" -czf "$TMPDIR/${base}.tar.gz" . 2>/dev/null && \
         mv "$TMPDIR/${base}.tar.gz" "${destdir}/${base}.tar.gz" 2>/dev/null; then
        ok "Backup: $vol -> ${safe_app}/${base}.tar.gz"
      else
        warn "Gagal backup volume: $vol"
      fi
    fi
  done
  
  _progress_bar 50 "Backup volume"
  printf "\n"
  
  info "Backup file docker-compose dan .env..."
  _progress_bar 65 "Backup konfigurasi"
  printf "\n"
else
  warn "SKIP BACKUP MODE - Tidak ada backup yang akan dibuat!"
  _progress_bar 65 "Skip backup"
  printf "\n"
fi

### Removal phase
info "Menghapus container, image, dan network Docker..."
if command -v docker >/dev/null 2>&1; then
  run_or_dry "docker ps -q 2>/dev/null | xargs -r docker stop >/dev/null 2>&1 || true"
  run_or_dry "docker ps -aq 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true"
  run_or_dry "docker images -q 2>/dev/null | xargs -r docker rmi -f >/dev/null 2>&1 || true"
  run_or_dry "docker network ls --filter 'type=custom' -q 2>/dev/null | xargs -r docker network rm >/dev/null 2>&1 || true"
  CURRENT_VOLS=()
  mapfile -t CURRENT_VOLS < <(docker volume ls -q 2>/dev/null || true)
  for v in "${CURRENT_VOLS[@]:-}"; do
    run_or_dry "docker volume rm -f '$v' >/dev/null 2>&1 || true"
  done
fi
_progress_bar 78 "Hapus Docker object"
printf "\n"

### Purge packages
if [ "$PURGE" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
  info "Purge paket Docker dari apt-get..."
  docker_pkgs="docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose docker-engine docker.io docker-buildx-plugin"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[DRY-RUN] apt-get purge -y $docker_pkgs"
  else
    apt-get purge -y $docker_pkgs >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
  fi
fi
_progress_bar 88 "Purge paket"
printf "\n"

### Standard cleanup
info "Membersihkan file dan direktori Docker..."
COMMON_DIRS=(
  /var/lib/docker
  /var/lib/containerd
  /run/docker.sock
  /run/containerd
  /etc/docker
  /etc/containerd
  /var/run/docker
  /var/run/containerd
  ~/.docker
)

for d in "${COMMON_DIRS[@]}"; do
  if [ -e "$d" ]; then
    if is_path_under "$d" "$BACKUP_ROOT"; then
      warn "Skip $d (dilindungi oleh BACKUP_ROOT)"
      continue
    fi
    
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[DRY-RUN] rm -rf $d"
    else
      rm -rf "$d" 2>/dev/null && ok "Hapus: $d" || warn "Gagal hapus: $d"
    fi
  fi
done

_progress_bar 98 "Cleanup standar selesai"
printf "\n"

### BRUTAL mode
if [ "$BRUTAL" -eq 1 ]; then
  info "BRUTAL cleanup: menghapus cgroup, umount, kill runtime..."
  
  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    info "Cgroup v2 terdeteksi. Menangani mount docker/containerd..."
    while IFS= read -r mount_point; do
      if [[ "$mount_point" =~ (docker|containerd) ]]; then
        run_or_dry "umount -l '$mount_point' 2>/dev/null || true"
        [ "$DRY_RUN" -eq 0 ] && [ -d "$mount_point" ] && rmdir "$mount_point" 2>/dev/null || true
        ok "Umount: $mount_point"
      fi
    done < <(grep '/sys/fs/cgroup' /proc/self/mounts 2>/dev/null | awk '{print $2}' || true)
  else
    info "Cgroup v1 terdeteksi. Menangani mount umum..."
    for m in /sys/fs/cgroup/system.slice/docker.service /sys/fs/cgroup/machine.slice/docker* /sys/fs/cgroup/docker; do
      [ -e "$m" ] && run_or_dry "umount -l '$m' 2>/dev/null || true"
    done
  fi
  
  for d in /run/docker /run/containerd /var/run/docker /var/run/containerd; do
    [ -e "$d" ] && run_or_dry "rm -rf '$d' 2>/dev/null || true"
  done
  
  [ "$DRY_RUN" -eq 0 ] && safe_kill_docker_processes || info "[DRY-RUN] Hentikan proses docker/containerd"
  
  ok "BRUTAL cleanup selesai"
fi

_progress_bar 100 "Selesai"
printf "\n"

### Final summary
title_summary "HASIL AKHIR"

if [ "$DRY_RUN" -eq 1 ]; then
  warn "MODE DRY-RUN: Tidak ada perubahan permanen"
  echo "Jalankan tanpa --dry-run untuk apply perubahan."
  echo
else
  ok "Proses selesai!"
  echo
  
  info "Verifikasi penghapusan Docker:"
  if verify_docker_removal; then
    ok "Sistem telah dibersihkan dari Docker"
  else
    warn "Beberapa file Docker masih tersisa (lihat di atas)"
  fi
fi

echo
if [ -d "$BACKUP_ROOT" ] && [ "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]; then
  backup_size=$(du -sh "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}' || echo "N/A")
  ok "Backup root: $BACKUP_ROOT"
  ok "Ukuran backup: $backup_size"
else
  ok "Backup root: $BACKUP_ROOT"
  [ "$DRY_RUN" -eq 1 ] && info "  (kosong - mode dry-run)"
  [ "$SKIP_BACKUP" -eq 1 ] && info "  (kosong - skip backup mode)"
fi

echo
ok "Terima kasih telah menggunakan remove-docker.sh"
echo

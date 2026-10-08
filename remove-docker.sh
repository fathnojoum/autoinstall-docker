#!/usr/bin/env bash
#
# Docker Engine remover — Ubuntu & Debian
# Versi: 3.0 FINAL | Docs checked: 2026-10-09
# Author: Fath Nojoum
#
# Usage:
#   curl -fsSL .../remove-docker.sh | sudo bash
#   curl -fsSL .../remove-docker.sh | sudo bash -s -- --dry-run
#   curl -fsSL .../remove-docker.sh | sudo bash -s -- --keep-data
#   curl -fsSL .../remove-docker.sh | sudo bash -s -- --user fath
#   curl -fsSL .../remove-docker.sh | sudo bash -s -- --quiet
#
# Perubahan v3.0:
#   - FIX: Deteksi awal apakah Docker benar-benar terinstal
#   - FIX: safe_kill_docker_processes verifikasi via /proc/<pid>/exe
#   - FIX: Rootless cleanup tanpa ketergantungan 'sudo' (fallback runuser/su)
#   - FIX: wait_for_apt dengan /proc scan (bootstrap-safe)
#   - FIX: Verifikasi residue lengkap (termasuk /run/docker, sources.list.d)
#   - FIX: Konfirmasi eksplisit di mode brutal (kecuali --yes)
#   - FIX: is_path_under validasi hasil readlink (cegah false-positive)
#   - FIX: Backup verifikasi integritas (size > 0)
#   - NEW: --quiet untuk CI/CD
#   - NEW: --yes untuk non-interaktif
#   - NEW: Docker Desktop context cleanup
#

set -euo pipefail

REMOVER_VERSION="3.0"
DOCS_CHECKED="2026-10-09"

### ── Colors ──
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'; BOLD=$'\033[1m'
  DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
fi

### ── Config ──
BACKUP_ROOT="/root/BACKUP_DOCKER"
DRY_RUN=0
PURGE=1
BRUTAL=1
SKIP_BACKUP=0
KEEP_DATA=0
VERBOSE=0
QUIET=0
AUTO_YES=0
TARGET_USER=""
SCRIPT_PID=$$

### ── Spinner ──
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

### ── Progress bar (bash murni) ──
_progress_bar() {
  local percent=${1:-0} text="${2:-}"
  percent=$(( percent < 0 ? 0 : percent > 100 ? 100 : percent ))
  local width=36
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local col="${GREEN}"
  [ "$percent" -ge 70 ] && col="${YELLOW}"
  [ "$percent" -ge 95 ] && col="${RED}"
  local bar_fill="" bar_empty="" i
  for (( i=0; i<filled; i++ )); do bar_fill+="#"; done
  for (( i=0; i<empty; i++ ));  do bar_empty+="-"; done
  [ "$QUIET" -eq 1 ] && return 0
  printf "\r%b[%s%s] %3d%% %b%s%b" "$col" "$bar_fill" "$bar_empty" "$percent" "${DIM}" "$text" "${NC}"
}

### ── Logging ──
info()  { [ "$QUIET" -eq 1 ] && return 0; printf "%b[INFO]%b %s\n" "${CYAN}" "${NC}" "$1"; }
ok()    { [ "$QUIET" -eq 1 ] && return 0; printf "%b[OK]%b %s\n" "${GREEN}" "${NC}" "$1"; }
warn()  { printf "%b[WARN]%b %s\n" "${YELLOW}" "${NC}" "$1"; }
error() { printf "%b[ERR]%b %s\n" "${RED}" "${NC}" "$1" >&2; }
die()   { error "$1"; exit 1; }

### ── Utils ──
safe_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]/_/g' | sed 's/__*/_/g'
}

timestamp_indonesia() {
  LC_TIME=id_ID.UTF-8 date '+%A,%d%B%Y_Jam%H.%M' 2>/dev/null || date '+%A,%d%B%Y_Jam%H.%M'
}

run_or_dry() {
  if [ "$DRY_RUN" -eq 1 ]; then
    [ "$VERBOSE" -eq 1 ] && info "[DRY-RUN] $*" || true
    return 0
  fi
  "$@" 2>&1 || return 1
}

# Cek apakah path di bawah parent — validasi readlink (cegah false-positive)
is_path_under() {
  local child="$1" parent="$2"
  child="$(readlink -f -- "$child" 2>/dev/null)" || return 1
  parent="$(readlink -f -- "$parent" 2>/dev/null)" || return 1
  [ -n "$child" ] && [ -n "$parent" ] || return 1
  [[ "$child" == "$parent"/* ]] || [ "$child" = "$parent" ]
}

# ── Deteksi proses apt/dpkg via /proc (tidak butuh fuser) ──
_apt_process_running() {
  local proc comm
  for proc in /proc/[0-9]*/comm; do
    [ -r "$proc" ] || continue
    comm="$(cat "$proc" 2>/dev/null || true)"
    case "$comm" in
      apt|apt-get|dpkg|dpkg-deb|unattended-upgrade|apt-helper|aptd)
        return 0 ;;
    esac
  done
  return 1
}

_apt_process_info() {
  local proc pid comm
  for proc in /proc/[0-9]*/comm; do
    [ -r "$proc" ] || continue
    comm="$(cat "$proc" 2>/dev/null || true)"
    case "$comm" in
      apt|apt-get|dpkg|dpkg-deb|unattended-upgrade|apt-helper|aptd)
        pid="$(basename "$(dirname "$proc")")"
        printf '   PID %s: %s\n' "$pid" "$comm" >&2
        ;;
    esac
  done
}

wait_for_apt() {
  local max_wait="${1:-120}" waited=0
  if command -v fuser >/dev/null 2>&1; then
    log_debug "Menggunakan 'fuser' untuk deteksi lock."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1
    do
      [ "$waited" -ge "$max_wait" ] && { warn "Timeout lock apt (>${max_wait}s)."; _apt_process_info; return 1; }
      sleep 2; waited=$((waited+2))
    done
    return 0
  fi
  while _apt_process_running; do
    [ "$waited" -ge "$max_wait" ] && { warn "Timeout menunggu proses apt/dpkg (>${max_wait}s)."; _apt_process_info; return 1; }
    sleep 2; waited=$((waited+2))
  done
  return 0
}

# ── Kill docker/containerd (verifikasi via /proc/<pid>/exe) ──
safe_kill_docker_processes() {
  command -v pgrep >/dev/null 2>&1 || { warn "pgrep tidak ada, skip kill."; return 0; }
  local killed=0
  for name in dockerd containerd docker-proxy containerd-shim dockerd-rootless; do
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      [ "$pid" -eq "$SCRIPT_PID" ] && continue
      local exe
      exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
      case "$exe" in
        */dockerd|*/containerd|*/docker-proxy|*/containerd-shim*|*/dockerd-rootless*)
          kill -9 "$pid" 2>/dev/null && killed=$((killed+1))
          ;;
        *) continue ;;
      esac
    done < <(pgrep -x "$name" 2>/dev/null || true)
  done
  [ "$killed" -gt 0 ] && ok "Menghentikan $killed proses Docker." || info "Tidak ada proses Docker."
}

# ── Rootless cleanup tanpa ketergantungan sudo ──
_run_as_user() {
  local user="$1"; shift
  if command -v runuser >/dev/null 2>&1; then
    runuser -u "$user" -- "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u "$user" "$@"
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/bash "$user" -c "$(printf '%q ' "$@")"
  else
    return 1
  fi
}

cleanup_rootless() {
  local user="$1"
  [ -z "$user" ] || [ "$user" = "root" ] && return 0
  local user_home
  user_home="$(getent passwd "$user" | cut -d: -f6)"
  [ -z "$user_home" ] && return 0

  info "Membersihkan rootless Docker untuk user: $user"

  local setuptool="/usr/bin/dockerd-rootless-setuptool.sh"
  if [ -x "$setuptool" ] && [ "$DRY_RUN" -eq 0 ]; then
    if XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
       _run_as_user "$user" "$setuptool" uninstall --force 2>/dev/null; then
      ok "Uninstall rootless systemd unit untuk $user."
    else
      warn "dockerd-rootless-setuptool.sh uninstall gagal (mungkin belum terinstal)."
    fi
  elif [ -x "$setuptool" ]; then
    info "[DRY-RUN] $setuptool uninstall --force (as $user)"
  fi

  local rootless_dirs=(
    "$user_home/.local/share/docker"
    "$user_home/.config/systemd/user/docker.service"
    "$user_home/.config/systemd/user/docker.socket"
    "$user_home/.docker"
  )
  for d in "${rootless_dirs[@]}"; do
    [ -e "$d" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[DRY-RUN] rm -rf $d"
    else
      rm -rf "$d" 2>/dev/null && ok "Hapus rootless: $d" || warn "Gagal hapus: $d"
    fi
  done

  for f in /etc/subuid /etc/subgid; do
    if grep -q "^${user}:" "$f" 2>/dev/null; then
      if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY-RUN] hapus entry $user dari $f"
      else
        sed -i "/^${user}:/d" "$f" 2>/dev/null && ok "Hapus entry $user dari $f" || true
      fi
    fi
  done
}

# ── Backup ──
backup_volumes() {
  local -a volumes=("$@")
  [ "${#volumes[@]}" -eq 0 ] && { info "Tidak ada volume untuk di-backup."; return 0; }
  for vol in "${volumes[@]}"; do
    local mountpoint
    mountpoint="$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
    [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ] && continue
    local appname="$vol"
    local firstcid
    firstcid="$(docker ps -aq --filter "volume=$vol" 2>/dev/null | head -n1 || true)"
    [ -n "$firstcid" ] && appname="$(docker inspect --format '{{.Name}}' "$firstcid" 2>/dev/null | sed 's#^/##')"
    local safe_app destdir ts base
    safe_app="$(safe_name "$appname")"
    destdir="$BACKUP_ROOT/$safe_app"
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$destdir" 2>/dev/null || true
    ts="$(timestamp_indonesia)"
    base="backup_appdata-docker_(${safe_app}_${vol})-${ts}"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[DRY-RUN] tar -C $mountpoint -czf $destdir/${base}.tar.gz ."
    else
      if tar -C "$mountpoint" -czf "$TMPDIR/${base}.tar.gz" . 2>/dev/null; then
        local size
        size="$(stat -c '%s' "$TMPDIR/${base}.tar.gz" 2>/dev/null || echo 0)"
        if [ "$size" -gt 0 ]; then
          mv "$TMPDIR/${base}.tar.gz" "${destdir}/${base}.tar.gz" && \
            ok "Backup: $vol ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B"))"
        else
          warn "Backup $vol kosong (0 byte) — volume mungkin kosong."
          rm -f "$TMPDIR/${base}.tar.gz"
        fi
      else
        warn "Gagal backup volume: $vol"
      fi
    fi
  done
}

backup_compose_files() {
  [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ] && return 0
  local user_home
  user_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [ -z "$user_home" ] && return 0
  local found=0
  local compose_dest="$BACKUP_ROOT/${TARGET_USER}_compose"
  [ "$DRY_RUN" -eq 0 ] && mkdir -p "$compose_dest"
  while IFS= read -r -d '' f; do
    found=1
    local rel="${f#$user_home/}"
    local safe_rel
    safe_rel="$(echo "$rel" | tr '/' '_')"
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[DRY-RUN] cp $f -> $compose_dest/$safe_rel"
    else
      cp -p "$f" "$compose_dest/$safe_rel" 2>/dev/null && ok "Backup: $rel" || warn "Gagal: $rel"
    fi
  done < <(find "$user_home" -maxdepth 3 \
             \( -name "docker-compose*.yml" -o -name "docker-compose*.yaml" -o -name ".env" \) \
             -type f -print0 2>/dev/null || true)
  [ "$found" -eq 0 ] && info "Tidak ada docker-compose.yml / .env di home $TARGET_USER."
}

### ── Usage ──
usage() {
  cat <<'USAGE'
Usage:
  curl -fsSL .../remove-docker.sh | sudo bash
  curl -fsSL .../remove-docker.sh | sudo bash -s -- --dry-run
  curl -fsSL .../remove-docker.sh | sudo bash -s -- --keep-data
  curl -fsSL .../remove-docker.sh | sudo bash -s -- --user fath
  curl -fsSL .../remove-docker.sh | sudo bash -s -- --quiet

Opsi:
  --dry-run              Mode simulasi (tanpa perubahan)
  --skip-backup          Skip fase backup (BERBAHAYA!)
  --keep-data            Hapus paket & service, TAPI pertahankan /var/lib/docker
  --no-purge             Jangan purge paket dari apt
  --no-brutal            Disable brutal mode (cgroup cleanup dilewati)
  --user USER            User non-root yang datanya ikut dibersihkan (rootless)
  --backup-root PATH     Lokasi backup (default: /root/BACKUP_DOCKER)
  --yes                  Non-interaktif (skip konfirmasi)
  --quiet                Mode senyap (hanya error yang ditampilkan)
  --no-color             Nonaktifkan warna
  --verbose              Mode verbose
  -h, --help             Bantuan ini

Contoh:
  # Simulasi dulu sebelum eksekusi:
  curl ... | sudo bash -s -- --dry-run

  # Uninstall Docker untuk user 'fath' (termasuk rootless data):
  curl ... | sudo bash -s -- --user fath

  # Uninstall TAPI pertahankan data volume:
  curl ... | sudo bash -s -- --keep-data

  # Uninstall tanpa konfirmasi (CI/CD):
  curl ... | sudo bash -s -- --yes --quiet
USAGE
  exit 0
}

### ── Argument parsing ──
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --skip-backup)    SKIP_BACKUP=1; shift ;;
    --keep-data)      KEEP_DATA=1; shift ;;
    --no-purge)       PURGE=0; shift ;;
    --no-brutal)      BRUTAL=0; shift ;;
    --user)           [ $# -ge 2 ] || die "--user butuh nilai."
                      TARGET_USER="$2"; shift 2 ;;
    --user=*)         TARGET_USER="${1#*=}"; shift ;;
    --backup-root)    [ $# -ge 2 ] || die "--backup-root butuh nilai."
                      BACKUP_ROOT="$2"; shift 2 ;;
    --backup-root=*)  BACKUP_ROOT="${1#*=}"; shift ;;
    --yes)            AUTO_YES=1; shift ;;
    --quiet)          QUIET=1; shift ;;
    --no-color)       RED=''; GREEN=''; YELLOW=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC='' ;;
    --verbose)        VERBOSE=1; shift ;;
    -h|--help)        usage ;;
    *) die "Argumen tidak dikenal: $1" ;;
  esac
done

### ── Pre-flight ──
[ "$QUIET" -eq 0 ] && title "Docker Auto Remove — v${REMOVER_VERSION} (docs ${DOCS_CHECKED})"

[ "$(id -u)" -eq 0 ] || die "Harus dijalankan sebagai root (gunakan sudo)."

# Auto-detect user via SUDO_USER
if [ -z "$TARGET_USER" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  TARGET_USER="$SUDO_USER"
  info "Auto-deteksi user: $TARGET_USER (via SUDO_USER)"
fi

[ -z "$BACKUP_ROOT" ] && die "Path backup tidak valid: kosong."
[[ "$BACKUP_ROOT" == "$HOME"* ]] && die "BACKUP_ROOT tidak boleh di dalam HOME."

if [ -f /.dockerenv ] && [ "$BRUTAL" -eq 1 ]; then
  die "Tidak dapat menjalankan brutal mode di dalam container Docker."
fi

# ── Deteksi apakah Docker benar-benar terinstal (BARU) ──
DOCKER_INSTALLED=0
if command -v docker >/dev/null 2>&1; then
  DOCKER_INSTALLED=1
elif dpkg -l 2>/dev/null | grep -qE '^ii\s+(docker-ce|docker.io|containerd)'; then
  DOCKER_INSTALLED=1
elif [ -d /var/lib/docker ] || [ -d /etc/docker ]; then
  DOCKER_INSTALLED=1
  warn "Docker binary tidak ada, tapi residu filesystem ditemukan."
fi

if [ "$DOCKER_INSTALLED" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  warn "Docker tidak terdeteksi di sistem ini."
  if [ "$AUTO_YES" -eq 0 ] && [ -t 0 ]; then
    read -r -p "Tetap jalankan cleanup residu? [y/N]: " ans
    case "$ans" in [Yy]*) ;; *) exit 0 ;; esac
  else
    info "Mode non-interaktif — lanjut cleanup residu."
  fi
fi

TMPDIR="$(mktemp -d)" || die "Gagal membuat direktori temporary."
cleanup_trap() { _spinner_stop; [ -d "$TMPDIR" ] && rm -rf "$TMPDIR" 2>/dev/null || true; }
trap cleanup_trap EXIT

[ ! -d "$BACKUP_ROOT" ] && mkdir -p "$BACKUP_ROOT"
[ ! -w "$BACKUP_ROOT" ] && die "Tidak dapat menulis ke backup root: $BACKUP_ROOT"

echo
[ "$QUIET" -eq 0 ] && {
  info "Konfigurasi:"
  printf "  %-22s %s\n" "Backup root:"   "$BACKUP_ROOT"
  printf "  %-22s %s\n" "Target user:"   "${TARGET_USER:-<tidak ada>}"
  printf "  %-22s %s\n" "Dry-run:"       "$([ "$DRY_RUN" -eq 1 ] && echo "YA" || echo "TIDAK")"
  printf "  %-22s %s\n" "Brutal mode:"   "$([ "$BRUTAL" -eq 1 ] && echo "YA (DEFAULT)" || echo "TIDAK")"
  printf "  %-22s %s\n" "Purge paket:"   "$([ "$PURGE" -eq 1 ] && echo "YA" || echo "TIDAK")"
  printf "  %-22s %s\n" "Keep data:"     "$([ "$KEEP_DATA" -eq 1 ] && echo "YA" || echo "TIDAK")"
  printf "  %-22s %s\n" "Skip backup:"   "$([ "$SKIP_BACKUP" -eq 1 ] && echo "YA" || echo "TIDAK")"
}

if command -v docker >/dev/null 2>&1; then
  [ "$QUIET" -eq 0 ] && printf "  %-22s %s\n" "Penggunaan Docker:" "$(docker system df 2>/dev/null | tail -n +2 | awk '{sum+=$4} END {printf "%.2f GB", sum/1024/1024/1024}' || echo "N/A")"
fi
echo

if [ "$BRUTAL" -eq 1 ]; then
  warn "BRUTAL MODE ENABLED — cgroup cleanup akan dijalankan."
  info "Untuk disable: ... | bash -s -- --no-brutal"
  echo
fi

# ── Konfirmasi eksplisit (kecuali --yes / --dry-run) ──
if [ "$DRY_RUN" -eq 0 ] && [ "$AUTO_YES" -eq 0 ] && [ -t 0 ]; then
  echo
  warn "⚠️  MODE BRUTAL akan menghapus:"
  log_note "  • Semua container, image, volume Docker"
  log_note "  • Paket docker-ce, containerd, dll"
  log_note "  • /var/lib/docker, /etc/docker, /etc/containerd"
  log_note "  • Rootless data (jika --user diberikan)"
  [ "$KEEP_DATA" -eq 0 ] && log_note "  • Data volume di /var/lib/docker (TIDAK ADA BACKUP selain fase backup)"
  echo
  read -r -p "Lanjutkan? [y/N]: " ans
  case "$ans" in [Yy]*) ;; *) info "Dibatalkan."; exit 0 ;; esac
fi

if [ "$DRY_RUN" -eq 0 ]; then
  info "Memproses... (mode automatic)"
  sleep 1
fi

_spinner_start "Memulai..."; sleep 0.8; _spinner_stop
_progress_bar 5 "Init"; printf "\n"

### ── 1. Stop containers ──
info "Menghentikan semua container Docker..."
if command -v docker >/dev/null 2>&1; then
  running_count=$(docker ps -q 2>/dev/null | wc -l || echo 0)
  if [ "$running_count" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[DRY-RUN] Akan menghentikan $running_count container(s)"
    else
      docker ps -q 2>/dev/null | xargs -r docker stop >/dev/null 2>&1 || true
      ok "Menghentikan $running_count container(s)"
    fi
  fi
fi
_progress_bar 15 "Hentikan container"; printf "\n"

### ── 2. Scan volumes & containers ──
info "Memindai volume dan bind mount..."
ALL_CONTAINERS=(); ALL_VOLUMES=()
if command -v docker >/dev/null 2>&1; then
  mapfile -t ALL_CONTAINERS < <(docker ps -aq 2>/dev/null || true)
  mapfile -t ALL_VOLUMES < <(docker volume ls -q 2>/dev/null || true)
fi
info "Ditemukan: ${#ALL_VOLUMES[@]} volume(s), ${#ALL_CONTAINERS[@]} container(s)"
_progress_bar 25 "Pemindaian"; printf "\n"

### ── 3. Backup ──
if [ "$SKIP_BACKUP" -eq 0 ]; then
  info "Memulai backup volume dan konfigurasi..."
  backup_volumes "${ALL_VOLUMES[@]}"
  _progress_bar 50 "Backup volume"; printf "\n"

  info "Backup docker-compose.yml dan .env..."
  backup_compose_files
  _progress_bar 65 "Backup konfigurasi"; printf "\n"
else
  warn "SKIP BACKUP MODE — tidak ada backup yang dibuat!"
  _progress_bar 65 "Skip backup"; printf "\n"
fi

### ── 4. Remove containers/images/networks/volumes ──
info "Menghapus container, image, dan network Docker..."
if command -v docker >/dev/null 2>&1; then
  run_or_dry docker ps -q 2>/dev/null | xargs -r docker stop >/dev/null 2>&1 || true
  run_or_dry docker ps -aq 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
  run_or_dry docker images -q 2>/dev/null | xargs -r docker rmi -f >/dev/null 2>&1 || true
  run_or_dry docker network ls --filter 'type=custom' -q 2>/dev/null | xargs -r docker network rm >/dev/null 2>&1 || true
  CURRENT_VOLS=()
  mapfile -t CURRENT_VOLS < <(docker volume ls -q 2>/dev/null || true)
  for v in "${CURRENT_VOLS[@]:-}"; do
    [ -n "$v" ] && run_or_dry docker volume rm -f "$v" >/dev/null 2>&1 || true
  done
fi
_progress_bar 78 "Hapus Docker object"; printf "\n"

### ── 5. Rootless cleanup ──
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
  cleanup_rootless "$TARGET_USER"
fi
_progress_bar 82 "Rootless cleanup"; printf "\n"

### ── 6. Purge packages (lengkap + wait_for_apt) ──
if [ "$PURGE" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
  info "Purge paket Docker dari apt-get..."
  wait_for_apt 120 || warn "Lock apt tidak lepas, purge mungkin gagal."

  docker_pkgs=(
    docker-ce docker-ce-cli containerd.io
    docker-buildx-plugin docker-compose-plugin
    docker-ce-rootless-extras
    docker-compose docker-compose-v2
    docker-engine docker.io docker-doc
    podman-docker containerd runc
  )

  if [ "$DRY_RUN" -eq 1 ]; then
    info "[DRY-RUN] apt-get purge -y ${docker_pkgs[*]}"
  else
    apt-get purge -y "${docker_pkgs[@]}" >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
    ok "Purge paket selesai."
  fi
fi
_progress_bar 88 "Purge paket"; printf "\n"

### ── 7. Standard cleanup ──
info "Membersihkan file dan direktori Docker..."

COMMON_DIRS=(
  /run/docker.sock
  /run/docker
  /run/containerd
  /etc/docker
  /etc/containerd
  /var/run/docker
  /var/run/containerd
  /etc/apt/sources.list.d/docker.list
  /etc/apt/sources.list.d/docker.sources
  /etc/apt/keyrings/docker.gpg
  /etc/apt/keyrings/docker.asc
)

if [ "$KEEP_DATA" -eq 0 ]; then
  COMMON_DIRS+=( /var/lib/docker /var/lib/containerd )
else
  warn "--keep-data: /var/lib/docker & /var/lib/containerd DIPERTAHANKAN."
fi

# User-level ~/.docker + Docker Desktop context
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [ -n "$USER_HOME" ] && COMMON_DIRS+=(
    "$USER_HOME/.docker"
    "$USER_HOME/.docker/contexts"
    "$USER_HOME/.docker/desktop"
  )
fi

for d in "${COMMON_DIRS[@]}"; do
  [ -e "$d" ] || continue
  if is_path_under "$d" "$BACKUP_ROOT"; then
    warn "Skip $d (dilindungi oleh BACKUP_ROOT)"
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[DRY-RUN] rm -rf $d"
  else
    rm -rf "$d" 2>/dev/null && ok "Hapus: $d" || warn "Gagal hapus: $d"
  fi
done

_progress_bar 98 "Cleanup standar"; printf "\n"

### ── 8. BRUTAL mode ──
if [ "$BRUTAL" -eq 1 ]; then
  info "BRUTAL cleanup: cgroup, umount, kill runtime..."
  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    info "Cgroup v2 terdeteksi."
    while IFS= read -r mount_point; do
      if [[ "$mount_point" =~ (docker|containerd) ]]; then
        run_or_dry umount -l "$mount_point" 2>/dev/null || true
        [ "$DRY_RUN" -eq 0 ] && [ -d "$mount_point" ] && rmdir "$mount_point" 2>/dev/null || true
        ok "Umount: $mount_point"
      fi
    done < <(grep '/sys/fs/cgroup' /proc/self/mounts 2>/dev/null | awk '{print $2}' || true)
  else
    info "Cgroup v1 terdeteksi."
    for m in /sys/fs/cgroup/system.slice/docker.service /sys/fs/cgroup/machine.slice/docker* /sys/fs/cgroup/docker; do
      [ -e "$m" ] && run_or_dry umount -l "$m" 2>/dev/null || true
    done
  fi
  for d in /run/docker /run/containerd /var/run/docker /var/run/containerd; do
    [ -e "$d" ] && run_or_dry rm -rf "$d" 2>/dev/null || true
  done
  [ "$DRY_RUN" -eq 0 ] && safe_kill_docker_processes || info "[DRY-RUN] kill docker/containerd"
  ok "BRUTAL cleanup selesai."
fi

_progress_bar 100 "Selesai"; printf "\n"

### ── 9. Final summary ──
[ "$QUIET" -eq 0 ] && title "HASIL AKHIR"

if [ "$DRY_RUN" -eq 1 ]; then
  warn "MODE DRY-RUN: Tidak ada perubahan permanen."
  echo "Jalankan tanpa --dry-run untuk apply."
else
  ok "Proses selesai!"
  echo

  info "Verifikasi penghapusan Docker:"
  still_found=0

  check_residue() {
    local label="$1" path="$2"
    if [ -e "$path" ]; then
      warn "  Masih ada: $label ($path)"
      still_found=1
    fi
  }

  check_residue "/var/lib/docker"            "/var/lib/docker"
  check_residue "/var/lib/containerd"        "/var/lib/containerd"
  check_residue "/etc/docker"                "/etc/docker"
  check_residue "/etc/containerd"            "/etc/containerd"
  check_residue "/run/docker"                "/run/docker"
  check_residue "/run/containerd"            "/run/containerd"
  check_residue "/run/docker.sock"           "/run/docker.sock"
  check_residue "/var/run/docker"            "/var/run/docker"
  check_residue "/var/run/containerd"        "/var/run/containerd"
  check_residue "docker.sources"             "/etc/apt/sources.list.d/docker.sources"
  check_residue "docker.list"                "/etc/apt/sources.list.d/docker.list"
  check_residue "GPG key"                    "/etc/apt/keyrings/docker.asc"

  if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
    local_user_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [ -n "$local_user_home" ] && check_residue "rootless data ($TARGET_USER)" "$local_user_home/.local/share/docker"
  fi

  if command -v docker >/dev/null 2>&1; then
    warn "  Docker binary masih ada: $(command -v docker)"
    warn "  (Normal setelah reboot atau uninstall manual)"
  else
    ok "  Docker binary tidak ditemukan."
  fi

  if [ "$still_found" -eq 0 ]; then
    ok "Sistem telah dibersihkan dari Docker."
  else
    warn "Beberapa file Docker masih tersisa (lihat di atas)."
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
ok "Terima kasih telah menggunakan remove-docker.sh v${REMOVER_VERSION}"
echo

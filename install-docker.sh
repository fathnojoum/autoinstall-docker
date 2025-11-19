#!/usr/bin/env bash
#
# Docker Auto-Installer (Ubuntu/Debian) — stable
#
set -euo pipefail

# -----------------------------
# Pretty logging helpers
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}" ; exit 1; }
log_step()  { echo -e "${BLUE}=== $1 ===${NC}"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# Defaults & args
# -----------------------------
AUTO_YES=0
NO_START=0
CHANNEL="stable"   # stable | test | nightly (user may change if needed)
PIN_VERSION=""     # exact docker version to install (optional)
SKIP_ROOTLESS=0

# Use robust arg parsing
PARAMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) AUTO_YES=1 ;;
    --no-start) NO_START=1 ;;
    --channel) CHANNEL="$2"; shift ;;
    --channel=*) CHANNEL="${1#*=}" ;;
    --version) PIN_VERSION="$2"; shift ;;
    --version=*) PIN_VERSION="${1#*=}" ;;
    --skip-rootless) SKIP_ROOTLESS=1 ;;
    --) shift; break ;;
    -h|--help)
      cat <<'USAGE'
Usage: install-docker.sh [options]

Options:
  -y, --yes            Non-interactive (accept prompts)
  --no-start           Do not enable/start services (useful for containers/CI)
  --channel CHANNEL    Docker Apt channel: stable (default), test, nightly
  --version VERSION    Pin to a specific docker-ce version (eg "5:24.0.5~3-0~ubuntu-jammy")
  --skip-rootless      Skip installing rootless extras
  -h, --help           Show this help

Note: This variant ALWAYS runs a hello-world functional test after install and will
      attempt to remove the hello-world image afterwards to keep the system clean.
USAGE
      exit 0
      ;;
    *)
      PARAMS+=("$1")
      ;;
  esac
  shift
done
set -- "${PARAMS[@]:-}"

# -----------------------------
# Re-exec with sudo if necessary (supports piped input)
# -----------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command_exists sudo; then
    if [ ! -t 0 ]; then
      tmp_script="$(mktemp -t install-docker.XXXXXX.sh)" || log_error "Gagal buat temp file."
      cat >"$tmp_script"
      chmod +x "$tmp_script"
      exec sudo -E bash "$tmp_script" "$@"
    else
      exec sudo -E bash "$0" "$@"
    fi
  else
    log_error "Script memerlukan hak root dan 'sudo' tidak tersedia. Jalankan sebagai root."
  fi
fi

cleanup_tmp() {
  [ -n "${tmp_script:-}" ] && [ -f "${tmp_script:-}" ] && rm -f "$tmp_script" || true
}
trap cleanup_tmp EXIT

# -----------------------------
# Real user & home (handle sudo)
# -----------------------------
REAL_USER="${SUDO_USER:-${USER:-root}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"
if [ -z "$REAL_HOME" ]; then
  if [ "$REAL_USER" = "root" ]; then
    REAL_HOME="/root"
  else
    REAL_HOME="/home/$REAL_USER"
  fi
fi
umask 022

cat <<'BANNER'

[0;34m==============================================[0m
[0;34m  Docker Auto-Installer - Ubuntu/Debian       [0m
[0;34m  Version: 1.0 by Fath Nojoum                 [0m
[0;34m==============================================[0m

BANNER

# -----------------------------
# Detect OS and codename
# -----------------------------
log_step "Deteksi OS"
[ -f /etc/os-release ] || log_error "Tidak bisa mendeteksi OS (file /etc/os-release tidak ditemukan)."
. /etc/os-release

case "${ID,,}" in
  debian)
    DOCKER_DISTRO="debian"
    DOCKER_KEY_URL="https://download.docker.com/linux/debian/gpg"
    OS_INFO="Debian ${VERSION_ID}"
    ;;
  ubuntu)
    DOCKER_DISTRO="ubuntu"
    DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
    OS_INFO="Ubuntu ${VERSION_ID}"
    ;;
  *)
    log_error "OS terdeteksi: ${ID}. Script hanya mendukung Ubuntu dan Debian."
    ;;
esac

CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ]; then
  if command_exists lsb_release; then
    CODENAME="$(lsb_release -cs)"
  else
    log_error "Tidak bisa menentukan codename rilis. Pastikan 'lsb-release' terpasang."
  fi
fi

log_info "OS terdeteksi: $OS_INFO (codename: $CODENAME)"
log_info "User: $REAL_USER ($REAL_HOME)"
log_info "Channel Docker: $CHANNEL"
[ -n "$PIN_VERSION" ] && log_info "Pin version: $PIN_VERSION"
log_info "Functional test: ALWAYS RUN (hello-world) — image akan dihapus setelah tes."

# -----------------------------
# If Docker exists, ask before reinstall (unless --yes)
# -----------------------------
if command_exists docker; then
  CURRENT_VERSION="$(docker --version 2>/dev/null || echo 'unknown')"
  log_warn "Docker sudah terinstal: $CURRENT_VERSION"
  if [ "${AUTO_YES}" -ne 1 ]; then
    if [ -t 0 ]; then
      echo -n "Lanjutkan untuk update/reinstall? [y/N]: "
      read -r REPLY
    else
      if [ -r /dev/tty ]; then
        read -r REPLY </dev/tty || REPLY=""
      else
        REPLY="n"
      fi
    fi
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      log_info "Instalasi dibatalkan oleh pengguna."
      exit 0
    fi
  fi
fi

# -----------------------------
# Remove old docker packages (best-effort)
# -----------------------------
log_step "Hapus versi lama Docker (jika ada)"
apt-get remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true
log_info "Cleanup paket lama selesai (jika ada)."

# -----------------------------
# Install dependencies (robust & portable)
# -----------------------------
log_step "Update dan instal dependensi (robust & portable)"
export DEBIAN_FRONTEND=noninteractive

# Retry helpers
retry_cmd() {
  # usage: retry_cmd <tries> <sleep_seconds> -- <command...>
  local tries=$1; shift
  local sleep_sec=$1; shift
  # jika ada pemisah '--', buang agar tidak dieksekusi
  if [ "${1:-}" = "--" ]; then shift; fi
  local attempt=1
  while [ $attempt -le "$tries" ]; do
    if "$@"; then
      return 0
    fi
    log_warn "Perintah gagal (attempt $attempt/$tries). Retrying in ${sleep_sec}s..."
    sleep "$sleep_sec"
    attempt=$((attempt + 1))
    sleep_sec=$((sleep_sec * 2)) # exponential backoff
  done
  return 1
}

# Wait for apt/dpkg lock to be free
wait_for_apt() {
  local max_wait=${1:-60} # seconds
  local waited=0
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    if [ "$waited" -ge "$max_wait" ]; then
      log_error "Timeout menunggu lock apt/dpkg (menunggu > ${max_wait}s)."
    fi
    log_warn "Menunggu proses apt/dpkg lain selesai..."
    sleep 2
    waited=$((waited + 2))
  done
}

# Ensure system can resolve & access repos: retry apt-get update a few times
wait_for_apt 120
if ! retry_cmd 4 2 -- apt-get update -o Acquire::Retries=3; then
  log_error "Gagal melakukan 'apt-get update' setelah beberapa percobaan. Periksa koneksi/repo."
fi

# Define package lists: core (required), extra (try if present), optional (best-effort)
CORE_DEPS=(ca-certificates curl gnupg lsb-release uidmap)
EXTRA_DEPS=(software-properties-common)   # often absent on minimal/Armbian mirrors
OPTIONAL_DEPS=(dbus-user-session fuse-overlayfs slirp4netns)

# Helper: is package available in current apt cache?
pkg_available() {
  # apt-cache show returns 0 if package metadata exists
  apt-cache show "$1" >/dev/null 2>&1
}

# Install a list, with retry & fixed-missing fallback
_install_pkgs() {
  local -n pkgs=$1
  local to_install=()
  for p in "${pkgs[@]}"; do
    if pkg_available "$p"; then
      to_install+=("$p")
    else
      log_warn "Paket tidak tersedia di repo saat ini: $p (akan dilewati)."
    fi
  done

  if [ "${#to_install[@]}" -eq 0 ]; then
    return 0
  fi

  wait_for_apt 120
  # first try: normal install with retries
  if retry_cmd 3 2 -- apt-get install -y --no-install-recommends "${to_install[@]}"; then
    return 0
  fi

  # second attempt with --fix-missing (best-effort)
  log_warn "Percobaan install gagal, mencoba lagi dengan --fix-missing..."
  if apt-get install -y --no-install-recommends --fix-missing "${to_install[@]}"; then
    return 0
  fi

  return 1
}

# Install core packages (fail if not possible)
if ! _install_pkgs CORE_DEPS; then
  log_error "Gagal install paket inti: ${CORE_DEPS[*]}"
fi
log_info "Paket inti berhasil diinstal."

# Try install extra deps (non-fatal if absent)
if pkg_available "${EXTRA_DEPS[0]}"; then
  if _install_pkgs EXTRA_DEPS; then
    log_info "Paket ekstra terpasang: ${EXTRA_DEPS[*]}"
  else
    log_warn "Gagal menginstal paket ekstra: ${EXTRA_DEPS[*]} (non-fatal)."
  fi
else
  log_warn "Paket ekstra tidak ditemukan, dilewati: ${EXTRA_DEPS[*]}"
fi

# Try install optional deps individually (non-fatal)
for p in "${OPTIONAL_DEPS[@]}"; do
  if pkg_available "$p"; then
    log_step "Installing optional package: $p"
    wait_for_apt 120
    if ! retry_cmd 2 2 -- apt-get install -y --no-install-recommends "$p"; then
      log_warn "Gagal install optional package $p (non-fatal)."
    else
      log_info "Optional package terpasang: $p"
    fi
  else
    log_warn "Optional package tidak tersedia, dilewati: $p"
  fi
done

log_info "Dependensi (yang tersedia) berhasil diinstal."

# -----------------------------
# Add Docker official GPG key (to keyrings)
# -----------------------------
log_step "Tambahkan GPG key resmi Docker"
install -d -m 0755 /etc/apt/keyrings
KEYRING_PATH="/etc/apt/keyrings/docker.gpg"
if [ -f "$KEYRING_PATH" ]; then
  rm -f "$KEYRING_PATH"
  log_warn "GPG key lama dihapus."
fi

curl -fsSL "$DOCKER_KEY_URL" | gpg --batch --yes --dearmor -o "$KEYRING_PATH" || log_error "Gagal unduh/convert GPG key."
chmod a+r "$KEYRING_PATH"
log_info "GPG key Docker berhasil ditambahkan ke $KEYRING_PATH."

# -----------------------------
# Add Docker APT repository (channel-aware)
# -----------------------------
log_step "Tambahkan repository Docker ($CHANNEL)"
ARCH="$(dpkg --print-architecture)"
REPO_LINE="deb [arch=${ARCH} signed-by=${KEYRING_PATH}] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} ${CHANNEL}"
echo "$REPO_LINE" | tee /etc/apt/sources.list.d/docker.list >/dev/null || log_error "Gagal menambahkan repository."
log_info "Repository Docker ditambahkan: ${CODENAME} (${CHANNEL})"

# -----------------------------
# Update & install Docker Engine + plugins
# -----------------------------
log_step "Update repository dan instal Docker Engine"
apt-get update || log_error "Gagal update setelah menambahkan repo Docker."

CORE_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
if [ "$SKIP_ROOTLESS" -eq 0 ]; then
  CORE_PKGS+=(docker-ce-rootless-extras)
fi

if [ -n "$PIN_VERSION" ]; then
  INSTALL_LIST=()
  for pkg in "${CORE_PKGS[@]}"; do
    INSTALL_LIST+=("${pkg}=${PIN_VERSION}")
  done
  apt-get install -y --allow-downgrades --no-install-recommends "${INSTALL_LIST[@]}" || log_error "Gagal install paket Docker (pinned version)."
else
  REQ_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  apt-get install -y --no-install-recommends "${REQ_PKGS[@]}" || log_error "Gagal install paket Docker inti."
  if [ "$SKIP_ROOTLESS" -eq 0 ]; then
    if apt-cache show docker-ce-rootless-extras >/dev/null 2>&1; then
      apt-get install -y docker-ce-rootless-extras || log_warn "Gagal install docker-ce-rootless-extras (opsional)."
    else
      log_warn "docker-ce-rootless-extras tidak tersedia untuk rilis ini; lewati."
    fi
  fi
fi

log_info "Docker Engine dan plugin berhasil diinstal (atau sudah tersedia)."

# -----------------------------
# Configure user & group
# -----------------------------
log_step "Konfigurasi user dan grup"
if [ "$REAL_USER" != "root" ] && id -u "$REAL_USER" >/dev/null 2>&1; then
  if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
    log_warn "User $REAL_USER sudah ada di grup docker."
  else
    usermod -aG docker "$REAL_USER" || log_warn "Gagal menambahkan user ke grup docker; jalankan 'usermod -aG docker $REAL_USER' secara manual."
    log_info "User $REAL_USER ditambahkan ke grup docker (perlu relogin agar berlaku)."
  fi
else
  log_warn "Lewati penambahan grup docker untuk user root atau user tidak ditemukan."
fi

if [ "$REAL_USER" != "root" ]; then
  if [ ! -d "$REAL_HOME/.docker" ]; then
    mkdir -p "$REAL_HOME/.docker"
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.docker"
    log_info "Folder konfigurasi dibuat: $REAL_HOME/.docker"
  fi
fi

# -----------------------------
# Enable & start services (if systemd present)
# -----------------------------
log_step "Enable dan start Docker service (jika cocok)"
SYSTEMD_AVAILABLE=0
if command_exists systemctl && systemctl list-unit-files >/dev/null 2>&1; then
  SYSTEMD_AVAILABLE=1
fi

WSL_ENV=0
if [ -f /proc/sys/kernel/osrelease ] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
  WSL_ENV=1
fi

if [ "${SYSTEMD_AVAILABLE}" -eq 1 ] && [ "${WSL_ENV}" -eq 0 ] && [ "${NO_START:-0}" -eq 0 ]; then
  systemctl enable docker.service containerd.service || log_warn "Gagal enable service Docker (non-fatal)."
  systemctl start docker.service || log_warn "Gagal start service Docker (non-fatal)."
  log_info "Permintaan aktivasi Docker service telah dikirim ke systemd."
else
  if [ "${WSL_ENV}" -eq 1 ]; then
    log_warn "Terdeteksi WSL: Lewati enable/start service. Gunakan pengelolaan service WSL/distro Anda."
  elif [ "${NO_START:-0}" -eq 1 ]; then
    log_warn "Lewati start service sesuai flag --no-start."
  else
    log_warn "Systemd tidak tersedia; lewati enable/start service."
  fi
fi

# -----------------------------
# Verify installation
# -----------------------------
log_step "Verifikasi instalasi"
if command_exists docker; then
  echo "Docker version:" && docker --version || true
else
  log_error "Docker CLI tidak ditemukan setelah instalasi."
fi

if command_exists docker; then
  echo ""; echo "Docker Compose (plugin) version:" && docker compose version || log_warn "Docker Compose plugin tidak ditemukan."
  echo ""; echo "Docker Buildx version:" && docker buildx version || log_warn "Docker Buildx plugin tidak ditemukan."
fi

if [ "${SYSTEMD_AVAILABLE}" -eq 1 ]; then
  echo ""; echo "Docker service status:"
  if systemctl is-active --quiet docker.service; then
    log_info "Docker daemon running"
  else
    log_warn "Docker daemon tidak running saat ini"
  fi
fi

# -----------------------------
# ALWAYS RUN functional test (hello-world) and CLEANUP
# -----------------------------
log_step "Menjalankan tes fungsional (hello-world) — akan selalu dicoba"

# helper: try docker info; optionally attempt to start daemon once if possible
try_docker_info() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

if try_docker_info; then
  DOCKER_READY=1
else
  DOCKER_READY=0
  # If systemd available and user didn't request --no-start, try start once
  if [ "${SYSTEMD_AVAILABLE}" -eq 1 ] && [ "${NO_START:-0}" -eq 0 ] && [ "${WSL_ENV}" -eq 0 ]; then
    log_info "Docker daemon tidak responsif — mencoba start docker.service sekali..."
    if systemctl start docker.service >/dev/null 2>&1; then
      sleep 1
      if try_docker_info; then
        DOCKER_READY=1
      fi
    else
      log_warn "Gagal memulai docker.service (non-fatal)."
    fi
  fi
fi

if [ "${DOCKER_READY}" -eq 1 ]; then
  if ( docker run --rm hello-world >/dev/null 2>&1 ); then
    log_info "Tes container hello-world: sukses"
  else
    log_warn "Tes hello-world gagal (mungkin kebijakan jaringan/registri atau pull error)."
  fi

  # Clean up any hello-world image that may have been pulled
  IMAGE_ID="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep '^hello-world:latest ' | awk '{print $2; exit}')"
  if [ -n "$IMAGE_ID" ]; then
    if docker image rm -f "$IMAGE_ID" >/dev/null 2>&1; then
      log_info "Image hello-world dihapus (bersih)."
    else
      log_warn "Gagal menghapus image hello-world (non-fatal)."
    fi
  else
    log_info "Tidak ada image hello-world untuk dihapus."
  fi
else
  log_warn "Docker daemon belum siap; lewati tes hello-world untuk menghindari gangguan."
fi

# -----------------------------
# Post steps & cleanup
# -----------------------------
apt-get autoremove -y >/dev/null 2>&1 || true

log_step "Membersihkan paket yang tidak diperlukan (autoremove)"
log_info "Cleanup selesai."

log_step "Menampilkan versi Docker & Docker Compose"

# Tampilkan versi Docker
if command_exists docker; then
  echo ""
  echo "🐳 Docker version:"
  docker --version || log_warn "Gagal menampilkan versi Docker."
else
  log_warn "Docker CLI tidak ditemukan."
fi

# Tampilkan versi Docker Compose (plugin modern)
if docker compose version >/dev/null 2>&1; then
  echo ""
  echo "🧩 Docker Compose version:"
  docker compose version || log_warn "Docker Compose plugin tidak ditemukan."
else
  # Coba versi legacy (docker-compose binary lama)
  if command_exists docker-compose; then
    echo ""
    echo "🧩 Docker Compose (legacy binary) version:"
    docker-compose --version || log_warn "Gagal menampilkan versi docker-compose lama."
  else
    log_warn "Docker Compose plugin tidak ditemukan."
  fi
fi

echo ""
log_info "✅ Proses instalasi Docker selesai dengan sukses!"
log_info "Silakan logout & login kembali agar grup 'docker' aktif."
echo ""
log_info "Untuk mulai: jalankan 'docker run --rm hello-world' untuk tes manual."
echo ""

exit 0
EOF

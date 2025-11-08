#!/usr/bin/env bash
#
# Docker Auto-Installer (Ubuntu/Debian) — latest **stable** channel
# Usage examples:
#   curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/install-docker.sh | sudo bash -s -- --yes
#   wget -qO- https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/install-docker.sh | sudo bash -s -- --yes
#   # Or save locally and run:
#   #   chmod +x install-docker.sh && sudo ./install-docker.sh --yes
#
# Author: fathnojoum (refactor by assistant)
# Repository: https://github.com/fathnojoum/autoinstall-docker
# Version: 2.2 (Nov 2025)
# Notes:
# - Installs from Docker's official **stable** APT repo to always get latest stable releases.
# - Works when executed as a file or via `curl | bash` / `wget | bash`.
# - Safe on systems without systemd (e.g., containers/WSL): service steps are skipped with warnings.
# - Supports non-interactive mode via --yes / -y.

set -euo pipefail

# -----------------------------
# Pretty logging
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; exit 1; }
log_step() { echo -e "${BLUE}=== $1 ===${NC}"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# -----------------------------
# Parse flags
# -----------------------------
AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=1 ;;
    --no-start) NO_START=1 ;;   # optional: skip starting services
    --) shift; break ;;
  esac
  shift || true
done

# -----------------------------
# Sudo elevation that works for file AND piped execution
# -----------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command_exists sudo; then
    # If stdin is a pipe (curl|bash), re-exec from a temp file
    if [ -p /proc/$$/fd/0 ]; then
      tmp_script="$(mktemp)"
      cat >"$tmp_script"
      exec sudo -E bash "$tmp_script" "$@"
    else
      exec sudo -E bash "$0" "$@"
    fi
  else
    log_error "Script ini memerlukan root privileges dan 'sudo' tidak tersedia. Jalankan sebagai root."
  fi
fi

# -----------------------------
# Real user & home (handle sudo)
# -----------------------------
REAL_USER="${SUDO_USER:-${USER:-root}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

umask 022

cat <<'BANNER'

\x1b[0;34m╔════════════════════════════════════════════════╗\x1b[0;34m╔════════════════════════════════════════════════╗\x1b[0m
\x1b[0;34m║   Docker Auto-Installer - Ubuntu/Debian       ║\x1b[0;34m║   Docker Auto-Installer - Ubuntu/Debian       ║\x1b[0m
\x1b[0;34m║   Version: 2.2 (Nov 2025, stable channel)     ║\x1b[0;34m║   Version: 2.2 (Nov 2025, stable channel)     ║\x1b[0m
\x1b[0;34m╚════════════════════════════════════════════════╝\x1b[0;34m╚════════════════════════════════════════════════╝\x1b[0m

BANNER

# -----------------------------
# Detect OS and codename
# -----------------------------
log_step "Deteksi OS"
[ -f /etc/os-release ] || log_error "Tidak bisa mendeteksi OS (file /etc/os-release tidak ditemukan)."
. /etc/os-release

case "${ID,,}" in
  debian)
    DOCKER_DISTRO="debian"; DOCKER_KEY_URL="https://download.docker.com/linux/debian/gpg"; OS_INFO="Debian ${VERSION_ID}" ;;
  ubuntu)
    DOCKER_DISTRO="ubuntu"; DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"; OS_INFO="Ubuntu ${VERSION_ID}" ;;
  *)
    log_error "OS terdeteksi: ${ID}. Script hanya mendukung Ubuntu dan Debian."
    ;;
esac

CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ]; then
  if command_exists lsb_release; then
    CODENAME="$(lsb_release -cs)"
  else
    log_error "Tidak bisa menentukan codename rilis. Pastikan 'lsb-release' terpasang atau VARIABLE VERSION_CODENAME tersedia."
  fi
fi

log_info "OS terdeteksi: $OS_INFO (codename: $CODENAME)"
log_info "User: $REAL_USER ($REAL_HOME)"

# -----------------------------
# If Docker exists, ask before reinstall (unless --yes)
# -----------------------------
if command_exists docker; then
  CURRENT_VERSION="$(docker --version 2>/dev/null || echo 'unknown')"
  log_warn "Docker sudah terinstal: $CURRENT_VERSION"
  if [ "${AUTO_YES}" -ne 1 ]; then
    echo -n "Lanjutkan untuk update/reinstall? [y/N]: "
    if [ -t 0 ]; then
      read -r REPLY
    else
      # Try to read from TTY; if not possible, default to no
      if [ -r /dev/tty ]; then
        read -r REPLY </dev/tty || REPLY=""
      else
        REPLY=""
      fi
    fi
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      log_info "Instalasi dibatalkan oleh pengguna."
      exit 0
    fi
  fi
fi

# -----------------------------
# Remove old docker packages
# -----------------------------
log_step "Hapus versi lama Docker (jika ada)"
apt-get remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true
log_info "Cleanup paket lama selesai."

# -----------------------------
# Dependencies
# -----------------------------
log_step "Update dan instal dependensi"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || log_error "Gagal update repository. Periksa koneksi internet."
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg \
  lsb-release software-properties-common \
  uidmap dbus-user-session fuse-overlayfs slirp4netns || log_error "Gagal install dependensi."
log_info "Dependensi berhasil diinstal."

# -----------------------------
# Add Docker official GPG key
# -----------------------------
log_step "Tambahkan GPG key resmi Docker"
install -d -m 0755 /etc/apt/keyrings
if [ -f /etc/apt/keyrings/docker.gpg ]; then
  rm -f /etc/apt/keyrings/docker.gpg
  log_warn "GPG key lama dihapus."
fi
curl -fsSL "$DOCKER_KEY_URL" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || log_error "Gagal unduh GPG key."
chmod a+r /etc/apt/keyrings/docker.gpg
log_info "GPG key Docker berhasil ditambahkan."

# -----------------------------
# Add Docker APT repository (stable channel)
# -----------------------------
log_step "Tambahkan repository Docker (stable)"
ARCH="$(dpkg --print-architecture)"
REPO_LINE="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable"
echo "$REPO_LINE" | tee /etc/apt/sources.list.d/docker.list >/dev/null || log_error "Gagal menambahkan repository."
log_info "Repository Docker ditambahkan: ${CODENAME} (stable)"

# -----------------------------
# Install Docker Engine + plugins (latest stable)
# -----------------------------
log_step "Update repository dan instal Docker Engine (stable)"
apt-get update -y || log_error "Gagal update setelah menambahkan repo Docker."
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  docker-ce-rootless-extras || log_error "Gagal install paket Docker."
log_info "Docker Engine dan plugin berhasil diinstal."

# -----------------------------
# User & group config
# -----------------------------
log_step "Konfigurasi user dan grup"
if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
  log_warn "User $REAL_USER sudah ada di grup docker."
else
  usermod -aG docker "$REAL_USER" || log_error "Gagal menambahkan user ke grup docker."
  log_info "User $REAL_USER ditambahkan ke grup docker."
fi

# Docker config directory
if [ ! -d "$REAL_HOME/.docker" ]; then
  mkdir -p "$REAL_HOME/.docker"
  chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.docker"
  log_info "Folder konfigurasi dibuat: $REAL_HOME/.docker"
fi

# -----------------------------
# Enable & start services (if systemd present)
# -----------------------------
log_step "Enable dan start Docker service"
SYSTEMD_AVAILABLE=0
if command_exists systemctl && systemctl list-unit-files >/dev/null 2>&1; then
  SYSTEMD_AVAILABLE=1
fi

# WSL detection
WSL_ENV=0
if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
  WSL_ENV=1
fi

if [ "${SYSTEMD_AVAILABLE}" -eq 1 ] && [ "${WSL_ENV}" -eq 0 ] && [ "${NO_START:-0}" -eq 0 ]; then
  systemctl enable docker.service containerd.service || log_warn "Gagal enable service Docker."
  systemctl start docker.service || log_warn "Gagal start service Docker."
  log_info "Docker service dicoba untuk diaktifkan."
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
echo "Docker version:" && docker --version || log_error "Docker CLI tidak ditemukan."
echo ""; echo "Docker Compose version:" && docker compose version || log_warn "Docker Compose plugin tidak ditemukan."
echo ""; echo "Docker Buildx version:" && docker buildx version || log_warn "Docker Buildx plugin tidak ditemukan."

# Service status (only if systemd)
if [ "${SYSTEMD_AVAILABLE}" -eq 1 ]; then
  echo ""; echo "Docker service status:"
  if systemctl is-active --quiet docker.service; then
    log_info "Docker daemon running"
  else
    log_warn "Docker daemon tidak running saat ini"
  fi
fi

# Optional functional test (only if daemon reachable)
if docker info >/dev/null 2>&1; then
  ( docker run --rm hello-world >/dev/null 2>&1 && log_info "Tes container hello-world: sukses" ) || \
  log_warn "Tes hello-world gagal (mungkin kebijakan jaringan/registri)."
else
  log_warn "Docker daemon belum siap atau user perlu re-login agar grup docker berlaku."
fi

# -----------------------------
# Post steps & cleanup
# -----------------------------
apt-get autoremove -y >/dev/null 2>&1 || true

cat <<"POST"

\x1b[0;34m╔════════════════════════════════════════════════╗\x1b[0;34m╔════════════════════════════════════════════════╗\x1b[0m
\x1b[0;34m║           Post-Installation Steps             ║\x1b[0;34m║           Post-Installation Steps             ║\x1b[0m
\x1b[0;34m╚════════════════════════════════════════════════╝\x1b[0;34m╚════════════════════════════════════════════════╝\x1b[0m

1️⃣  PENTING: Logout dan login kembali agar membership grup docker aktif
    (atau jalankan: su - "$REAL_USER")
2️⃣  Jalankan tes cepat:   docker run --rm hello-world
3️⃣  Cek info:             docker info

POST

log_info "Docker berhasil diinstal dari channel stable!"

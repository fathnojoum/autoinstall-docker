#!/bin/bash
#
# Docker Auto-Installer untuk Ubuntu/Debian
# Pemakaian: curl -fsSL https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/install-docker.sh | bash
# Atau: wget -qO- https://raw.githubusercontent.com/fathnojoum/autoinstall-docker/main/install-docker.sh | bash
#
# Author: fathnojoum
# Repository: https://github.com/fathnojoum/autoinstall-docker
# Updated: October 2025
#

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Color codes for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function untuk logging
log_info() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; exit 1; }
log_step() { echo -e "${BLUE}=== $1 ===${NC}"; }

# Function untuk check command existence
command_exists() { command -v "$1" &> /dev/null; }

# Auto-elevate to sudo if not running as root
if [ "$EUID" -ne 0 ]; then
    if command_exists sudo; then
        log_warn "Script memerlukan sudo privileges. Requesting elevated access..."
        exec sudo bash "$0" "$@"
    else
        log_error "Script ini memerlukan root privileges dan 'sudo' tidak tersedia."
    fi
fi

# Get the real user (not root if using sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Docker Auto-Installer - Ubuntu/Debian       ║${NC}"
echo -e "${BLUE}║   Version: 2.1 (October 2025)                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

log_step "Deteksi OS"
if [ ! -f /etc/os-release ]; then
    log_error "Tidak bisa mendeteksi OS (file /etc/os-release tidak ditemukan)."
fi

. /etc/os-release

if [[ "$ID" == "debian" ]]; then
    DOCKER_DISTRO="debian"
    DOCKER_KEY_URL="https://download.docker.com/linux/debian/gpg"
    OS_INFO="Debian $VERSION_ID"
elif [[ "$ID" == "ubuntu" ]]; then
    DOCKER_DISTRO="ubuntu"
    DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
    OS_INFO="Ubuntu $VERSION_ID"
else
    log_error "OS terdeteksi: $ID. Script hanya mendukung Ubuntu dan Debian."
fi

log_info "OS terdeteksi: $OS_INFO (codename: $VERSION_CODENAME)"
log_info "User: $REAL_USER"

# Check if Docker already installed
if command_exists docker; then
    CURRENT_VERSION=$(docker --version 2>/dev/null || echo "unknown")
    log_warn "Docker sudah terinstal: $CURRENT_VERSION"
    echo -n "Lanjutkan untuk update/reinstall? [y/N]: "
    read -r REPLY
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Instalasi dibatalkan."
        exit 0
    fi
fi

log_step "Hapus versi lama Docker (jika ada)"
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
log_info "Cleanup versi lama selesai."

log_step "Update dan instal dependensi"
export DEBIAN_FRONTEND=noninteractive
apt-get update || log_error "Gagal update repository. Periksa koneksi internet."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    uidmap \
    dbus-user-session \
    fuse-overlayfs \
    slirp4netns || log_error "Gagal install dependensi."
log_info "Dependensi berhasil diinstal."

log_step "Tambahkan GPG key resmi Docker"
mkdir -p /etc/apt/keyrings
if [ -f /etc/apt/keyrings/docker.gpg ]; then
    rm /etc/apt/keyrings/docker.gpg
    log_warn "GPG key lama dihapus."
fi
curl -fsSL "$DOCKER_KEY_URL" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || log_error "Gagal download GPG key."
chmod a+r /etc/apt/keyrings/docker.gpg
log_info "GPG key Docker berhasil ditambahkan."

log_step "Tambahkan repository Docker"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DOCKER_DISTRO $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null || log_error "Gagal tambah repository."
log_info "Repository Docker berhasil ditambahkan."

log_step "Update repository dan instal Docker Engine"
apt-get update || log_error "Gagal update setelah tambah repository Docker."
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  docker-ce-rootless-extras || log_error "Gagal install Docker packages."
log_info "Docker Engine dan plugins berhasil diinstal."

log_step "Konfigurasi user dan grup"
if groups "$REAL_USER" | grep -q docker; then
    log_warn "User $REAL_USER sudah ada di grup docker."
else
    usermod -aG docker "$REAL_USER" || log_error "Gagal tambahkan user ke grup docker."
    log_info "User $REAL_USER ditambahkan ke grup docker."
fi

log_step "Enable dan start Docker service"
systemctl enable docker.service containerd.service || log_warn "Gagal enable Docker service."
systemctl start docker.service || log_warn "Gagal start Docker service."
log_info "Docker service aktif dan running."

log_step "Verifikasi instalasi"
echo "Docker version:"
docker --version || log_error "Docker CLI tidak ditemukan."
echo ""
echo "Docker Compose version:"
docker compose version || log_warn "Docker Compose plugin tidak ditemukan."
echo ""
echo "Docker Buildx version:"
docker buildx version || log_warn "Docker Buildx plugin tidak ditemukan."
echo ""

# Test Docker (akan gagal jika user belum logout/login)
echo "Docker service status:"
systemctl is-active docker.service && log_info "Docker daemon running" || log_warn "Docker daemon not running"

log_step "Konfigurasi tambahan"
# Create docker config directory for user
if [ ! -d "$REAL_HOME/.docker" ]; then
    mkdir -p "$REAL_HOME/.docker"
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.docker"
    log_info "Docker config directory dibuat di $REAL_HOME/.docker"
fi

# Enable Docker service to start on boot
systemctl enable docker.service
log_info "Docker akan auto-start saat boot."

echo ""
log_step "Instalasi Selesai! 🎉"
echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Post-Installation Steps             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo "1️⃣  PENTING: Logout dan login kembali agar grup docker berlaku"
echo "    Atau jalankan: su - $REAL_USER"
echo ""
log_info "Instalasi Docker berhasil dikomplesi!"
echo ""

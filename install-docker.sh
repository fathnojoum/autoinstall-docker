#!/usr/bin/env bash

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Color Codes & Loading Spinner
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Loading spinner state
SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_DELAY=0.1

# Pretty logging helpers
log_info() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}" ; exit 1; }
log_step() { echo -e "${BLUE}=== $1 ===${NC}"; }
log_debug() { if [ "${DEBUG:-0}" = "1" ]; then echo -e "${CYAN}🔍 $1${NC}"; fi; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Show loading spinner with background process
show_loading() {
    local pid=$1
    local msg=$2
    local idx=0
    
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}${SPINNER_CHARS[$idx]} $msg${NC}"
        idx=$(( (idx + 1) % ${#SPINNER_CHARS[@]} ))
        sleep "$SPINNER_DELAY"
    done
    
    wait "$pid"
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        printf "\r${GREEN}✅ $msg${NC}\n"
    else
        printf "\r${RED}❌ $msg${NC}\n"
        return $exit_code
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Defaults & Arguments
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

AUTO_YES=0
NO_START=0
CHANNEL="stable"
PIN_VERSION=""
SKIP_ROOTLESS=0
DEBUG=0

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
        --debug) DEBUG=1 ;;
        --) shift; break ;;
        -h|--help)
            cat <<'USAGE'
Usage: autoinstal-dc.sh [options]

Options:
  -y, --yes              Non-interactive (accept prompts)
  --no-start             Do not enable/start services (useful for containers/CI)
  --channel CHANNEL      Docker Apt channel: stable (default), test, nightly
  --version VERSION      Pin to a specific docker-ce version
  --skip-rootless        Skip installing rootless extras
  --debug                Enable debug output
  -h, --help             Show this help

Note: This script always runs hello-world functional test after install
      and removes the image afterwards to keep the system clean.
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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Re-exec with sudo if necessary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Real user & home (handle sudo)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Banner
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

cat <<'BANNER'

╔═══════════════════════════════════════════════════════╗
║  🐳  Docker Auto-Installer                          ║
║  By: Fath Nojoum                                    ║
╚═══════════════════════════════════════════════════════╝

BANNER

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Detect OS and codename
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Deteksi OS dan Environment"

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
log_info "Functional test: ALWAYS RUN (hello-world)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Check if Docker exists
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if command_exists docker; then
    CURRENT_VERSION="$(docker --version 2>/dev/null || echo 'unknown')"
    log_warn "Docker sudah terinstal: $CURRENT_VERSION"
    
    if [ "${AUTO_YES}" -ne 1 ]; then
        if [ -t 0 ]; then
            echo -n "Lanjutkan untuk update/reinstall? [y/N]: "
            read -r REPLY
        else
            if [ -r /dev/tty ]; then
                read -r REPLY </dev/tty 2>&1 || true
            fi
        fi
        
        [[ "$REPLY" =~ ^[Yy]$ ]] || { log_info "Dibatalkan."; exit 0; }
    fi
    
    log_step "Cleanup paket Docker lama"
    (
        apt-get remove -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
    ) &
    show_loading $! "Cleanup paket Docker lama"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Retry command helper
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

retry_cmd() {
    local tries=$1; shift
    local sleep_sec=$1; shift
    
    if [ "${1:-}" = "--" ]; then shift; fi
    
    local attempt=1
    while [ $attempt -le "$tries" ]; do
        if "$@"; then
            return 0
        fi
        
        if [ $attempt -lt "$tries" ]; then
            log_debug "Perintah gagal (attempt $attempt/$tries). Retry in ${sleep_sec}s..."
            sleep "$sleep_sec"
            attempt=$((attempt + 1))
            sleep_sec=$((sleep_sec * 2))
        else
            return 1
        fi
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Wait for apt/dpkg lock
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

wait_for_apt() {
    local max_wait=${1:-60}
    local waited=0
    
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        
        if [ "$waited" -ge "$max_wait" ]; then
            log_error "Timeout menunggu lock apt/dpkg (>${max_wait}s)."
        fi
        
        log_debug "Menunggu proses apt/dpkg lain selesai..."
        sleep 2
        waited=$((waited + 2))
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Check package availability
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

pkg_available() {
    apt-cache show "$1" >/dev/null 2>&1
    return $?
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Install packages helper
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

_install_pkgs() {
    local -n pkgs=$1
    local msg=$2
    local to_install=()
    
    for p in "${pkgs[@]}"; do
        if pkg_available "$p"; then
            to_install+=("$p")
        else
            log_debug "Paket tidak tersedia: $p (dilewati)."
        fi
    done
    
    if [ "${#to_install[@]}" -eq 0 ]; then
        return 0
    fi
    
    wait_for_apt 120
    
    (
        if retry_cmd 3 2 -- apt-get install -y --no-install-recommends "${to_install[@]}" >/dev/null 2>&1; then
            return 0
        fi
        
        apt-get install -y --no-install-recommends --fix-missing "${to_install[@]}" >/dev/null 2>&1
    ) &
    show_loading $! "$msg"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Install dependencies
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Update dan instal dependensi"

export DEBIAN_FRONTEND=noninteractive

wait_for_apt 120

(
    retry_cmd 4 2 -- apt-get update -o Acquire::Retries=3 >/dev/null 2>&1
) &
show_loading $! "Update repository sistem" || log_error "Gagal melakukan 'apt-get update'."

CORE_DEPS=(ca-certificates curl gnupg lsb-release)
_install_pkgs CORE_DEPS "Instalasi paket inti" || log_error "Gagal install paket inti: ${CORE_DEPS[*]}"

EXTRA_DEPS=(software-properties-common)
if pkg_available "${EXTRA_DEPS[0]}"; then
    _install_pkgs EXTRA_DEPS "Instalasi paket ekstra" || log_warn "Gagal menginstal paket ekstra (non-fatal)."
else
    log_debug "Paket ekstra tidak ditemukan, dilewati."
fi

# Install optional deps silently
for p in dbus-user-session fuse-overlayfs slirp4netns uidmap; do
    if pkg_available "$p"; then
        (
            retry_cmd 2 2 -- apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1
        ) &
        show_loading $! "Instalasi $p" || true
    fi
done

log_info "Dependensi berhasil diinstal."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Add Docker GPG key
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Tambahkan GPG key resmi Docker"

install -d -m 0755 /etc/apt/keyrings

KEYRING_PATH="/etc/apt/keyrings/docker.gpg"

if [ -f "$KEYRING_PATH" ]; then
    rm -f "$KEYRING_PATH"
    log_debug "GPG key lama dihapus."
fi

(
    curl -fsSL "$DOCKER_KEY_URL" | gpg --batch --yes --dearmor -o "$KEYRING_PATH" 2>/dev/null
) &
show_loading $! "Download & import GPG key Docker" || log_error "Gagal unduh/convert GPG key dari $DOCKER_KEY_URL"

chmod a+r "$KEYRING_PATH"
log_info "GPG key Docker berhasil ditambahkan."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Add Docker APT repository
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Tambahkan repository Docker ($CHANNEL)"

ARCH="$(dpkg --print-architecture)"
REPO_LINE="deb [arch=${ARCH} signed-by=${KEYRING_PATH}] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} ${CHANNEL}"

echo "$REPO_LINE" | tee /etc/apt/sources.list.d/docker.list >/dev/null || log_error "Gagal menambahkan repository."

log_info "Repository Docker ditambahkan: ${CODENAME} (${CHANNEL})"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Update dan install Docker Engine
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Update repository dan instal Docker Engine"

(
    apt-get update >/dev/null 2>&1
) &
show_loading $! "Update repository Docker" || log_error "Gagal update setelah menambahkan repo Docker."

CORE_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

if [ "$SKIP_ROOTLESS" -eq 0 ]; then
    CORE_PKGS+=(docker-ce-rootless-extras)
fi

if [ -n "$PIN_VERSION" ]; then
    INSTALL_LIST=()
    for pkg in "${CORE_PKGS[@]}"; do
        INSTALL_LIST+=("${pkg}=${PIN_VERSION}")
    done
    (
        apt-get install -y --allow-downgrades --no-install-recommends "${INSTALL_LIST[@]}" >/dev/null 2>&1
    ) &
    show_loading $! "Instalasi Docker Engine (pinned version)" || log_error "Gagal install paket Docker (pinned version)."
else
    REQ_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
    (
        apt-get install -y --no-install-recommends "${REQ_PKGS[@]}" >/dev/null 2>&1
    ) &
    show_loading $! "Instalasi Docker Engine & plugins" || log_error "Gagal install paket Docker inti."
    
    if [ "$SKIP_ROOTLESS" -eq 0 ] && pkg_available "docker-ce-rootless-extras"; then
        (
            apt-get install -y --no-install-recommends docker-ce-rootless-extras >/dev/null 2>&1
        ) &
        show_loading $! "Instalasi rootless extras" || log_warn "Gagal install rootless extras (non-fatal)."
    fi
fi

log_info "Docker Engine dan plugin berhasil diinstal."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Configure user & group
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Konfigurasi user dan grup"

if [ "$REAL_USER" != "root" ] && id -u "$REAL_USER" >/dev/null 2>&1; then
    if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
        log_warn "User $REAL_USER sudah ada di grup docker."
    else
        usermod -aG docker "$REAL_USER" || log_warn "Gagal menambahkan user ke grup docker."
        log_info "User $REAL_USER ditambahkan ke grup docker (perlu relogin)."
    fi
else
    log_debug "Lewati penambahan grup docker untuk user root."
fi

if [ "$REAL_USER" != "root" ]; then
    if [ ! -d "$REAL_HOME/.docker" ]; then
        mkdir -p "$REAL_HOME/.docker"
        chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.docker"
        log_info "Folder konfigurasi dibuat: $REAL_HOME/.docker"
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Enable & start services
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Enable dan start Docker service"

SYSTEMD_AVAILABLE=0
if command_exists systemctl && systemctl list-unit-files >/dev/null 2>&1; then
    SYSTEMD_AVAILABLE=1
fi

WSL_ENV=0
if [ -f /proc/sys/kernel/osrelease ] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    WSL_ENV=1
fi

if [ "${SYSTEMD_AVAILABLE}" -eq 1 ] && [ "${WSL_ENV}" -eq 0 ] && [ "${NO_START:-0}" -eq 0 ]; then
    systemctl enable docker.service containerd.service 2>/dev/null || log_warn "Gagal enable service (non-fatal)."
    systemctl start docker.service 2>/dev/null || log_warn "Gagal start service (non-fatal)."
    log_info "Docker service diaktifkan."
else
    if [ "${WSL_ENV}" -eq 1 ]; then
        log_warn "WSL terdeteksi: Lewati enable/start service."
    elif [ "${NO_START:-0}" -eq 1 ]; then
        log_warn "Lewati start service sesuai flag --no-start."
    else
        log_warn "Systemd tidak tersedia; lewati enable/start service."
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Functional test (hello-world)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Menjalankan tes fungsional (hello-world)"

DOCKER_READY=0
if docker info >/dev/null 2>&1; then
    DOCKER_READY=1
else
    if [ "${SYSTEMD_AVAILABLE}" -eq 1 ] && [ "${NO_START:-0}" -eq 0 ] && [ "${WSL_ENV}" -eq 0 ]; then
        log_debug "Daemon belum responsif — mencoba start..."
        if systemctl start docker.service >/dev/null 2>&1; then
            sleep 1
            if docker info >/dev/null 2>&1; then
                DOCKER_READY=1
            fi
        fi
    fi
fi

if [ "${DOCKER_READY}" -eq 1 ]; then
    (
        docker run --rm hello-world >/dev/null 2>&1
    ) &
    show_loading $! "Test container hello-world" || log_warn "Tes hello-world gagal (mungkin issue registri/network)."
    
    # Clean up hello-world image
    sleep 1
    IMAGE_ID="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep '^hello-world:latest ' | awk '{print $2; exit}' 2>/dev/null || true)"
    if [ -n "$IMAGE_ID" ]; then
        docker image rm -f "$IMAGE_ID" 2>/dev/null || true
        log_debug "Image hello-world dihapus (cleanup)."
    fi
else
    log_warn "Docker daemon tidak responsif; lewati tes hello-world."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Cleanup & completion
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Cleanup paket yang tidak diperlukan"

(
    apt-get autoremove -y >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
) &
show_loading $! "Cleanup paket tidak diperlukan" || true

if [ "${SYSTEMD_AVAILABLE}" -eq 1 ]; then
    echo "📊 Docker service status:"
    if systemctl is-active --quiet docker.service 2>/dev/null; then
        log_info "Docker daemon running"
    else
        log_warn "Docker daemon belum running"
    fi
    echo ""
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Final Verification - dengan warna KUNING untuk version info
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
log_step "Verifikasi instalasi final"
echo ""

if command_exists docker; then
    echo "🐳 Docker version:"
    docker --version | sed "s/^/${YELLOW}/; s/$/${NC}/"
    echo ""
fi

if docker compose version >/dev/null 2>&1; then
    echo "🧩 Docker Compose (plugin):"
    docker compose version | sed "s/^/${YELLOW}/; s/$/${NC}/"
    echo ""
fi

if docker buildx version >/dev/null 2>&1; then
    echo "🔨 Docker Buildx:"
    docker buildx version | head -1 | sed "s/^/${YELLOW}/; s/$/${NC}/"
    echo ""
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
log_info "💡 Proses instalasi Docker SUKSES!"
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

exit 0

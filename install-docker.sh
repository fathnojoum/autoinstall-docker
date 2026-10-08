#!/usr/bin/env bash
#
# Docker Engine installer — Ubuntu & Debian
#
# Mengikuti:
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/install/ubuntu/
#   https://docs.docker.com/engine/install/linux-postinstall/
# Panduan diverifikasi ulang: 9 Oktober 2026
# Author: Fath Nojoum
#
# shellcheck disable=SC2317   # log_* dipanggil dari subshell/fungsi lain -> diduga "unreachable"

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Konstanta
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTALLER_VERSION="2.1"
DOCS_CHECKED="2026-10-09"

# Fingerprint resmi GPG key Docker (SHA1)
DOCKER_GPG_FINGERPRINT="9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"

# Arsitektur yang didukung resmi (docs, 9 Okt 2026)
#   Debian : amd64, armhf, arm64, ppc64el
#   Ubuntu : amd64, armhf, arm64, s390x, ppc64el
SUPPORTED_ARCH_DEBIAN="amd64 armhf arm64 ppc64el"
SUPPORTED_ARCH_UBUNTU="amd64 armhf arm64 s390x ppc64el"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Output
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ -t 1 ]; then
    RED=$'\033[0;31m';    GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m';   NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log_info()  { printf '%s✅ %s%s\n' "$GREEN" "$1" "$NC"; }
log_warn()  { printf '%s⚠️  %s%s\n' "$YELLOW" "$1" "$NC"; }
log_note()  { printf '   %s\n' "$1"; }
log_step()  { printf '\n%s=== %s ===%s\n' "$BLUE" "$1" "$NC"; }
log_error() { printf '%s❌ %s%s\n' "$RED" "$1" "$NC" >&2; exit 1; }
log_debug() { if [ "${DEBUG:-0}" = "1" ]; then printf '   %s[debug]%s %s\n' "$BLUE" "$NC" "$1"; fi; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Argument parsing
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ORIG_ARGS=("$@")

AUTO_YES=0
NO_START=0
CHANNEL="stable"
PIN_VERSION=""
SKIP_ROOTLESS=0
DEBUG=0

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)        AUTO_YES=1 ;;
        --no-start)      NO_START=1 ;;
        --channel)       [ $# -ge 2 ] || log_error "--channel butuh nilai."
                         CHANNEL="$2"; shift ;;
        --channel=*)     CHANNEL="${1#*=}" ;;
        --version)       [ $# -ge 2 ] || log_error "--version butuh nilai."
                         PIN_VERSION="$2"; shift ;;
        --version=*)     PIN_VERSION="${1#*=}" ;;
        --skip-rootless) SKIP_ROOTLESS=1 ;;
        --debug)         DEBUG=1 ;;
        --)              shift; break ;;
        -h|--help)
            cat <<'USAGE'
Usage: install-docker.sh [options]

Options:
  -y, --yes              Non-interaktif (asumsikan "ya" untuk prompt yang aman)
  --no-start             Jangan enable/start service (container/CI)
  --channel CHANNEL      Channel repo Docker: stable (default) | test | nightly
  --version VERSION      Pin docker-ce & docker-ce-cli. Terima:
                           29.8.2                              (versi saja)
                           5:29.8.2                            (epoch:versi)
                           5:29.8.2-1~debian.12~bookworm       (string lengkap)
  --skip-rootless        Jangan install docker-ce-rootless-extras
  --debug                Tampilkan output apt/curl secara live
  -h, --help             Bantuan ini

Catatan:
  - Selalu menjalankan tes fungsional hello-world lalu menghapus image-nya.
  - Grup 'docker' = hak setara root; TIDAK ditambahkan otomatis pada mode -y.
  - /etc/docker/daemon.json hanya ditulis bila belum ada.
USAGE
            exit 0
            ;;
        *) log_error "Argumen tidak dikenal: '$1' (lihat --help)" ;;
    esac
    shift
done

case "$CHANNEL" in
    stable|test|nightly) ;;
    *) log_error "Channel tidak valid: '$CHANNEL'. Pilihan: stable | test | nightly" ;;
esac

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Escalasi root
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command_exists sudo || log_error "Butuh hak root dan 'sudo' tidak ada. Jalankan: sudo $0 ${ORIG_ARGS[*]-}"

    SELF="$0"
    if [ -r "$SELF" ] && [ -f "$SELF" ]; then
        exec sudo -E bash "$SELF" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    log_error "Script dibaca dari stdin/pipe, tidak bisa di-re-exec."
    log_error "Simpan ke file lalu jalankan: sudo bash install-docker.sh ${ORIG_ARGS[*]-}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# User & home
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -n "$REAL_HOME" ] || REAL_HOME="/home/$SUDO_USER"
else
    REAL_USER="root"
    REAL_HOME="/root"
fi

umask 022

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Deteksi OS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

cat <<'BANNER'

╔═══════════════════════════════════════════════════════╗
║  🐳  Docker Auto-Installer                            ║
║  By: Fath Nojoum                                      ║
╚═══════════════════════════════════════════════════════╝
BANNER

log_step "Deteksi OS"

[ -f /etc/os-release ] || log_error "Tidak bisa deteksi OS (/etc/os-release tidak ada)."

# shellcheck disable=SC1091
. /etc/os-release

case "${ID,,}" in
    debian)
        DOCKER_DISTRO="debian"
        DOCKER_KEY_URL="https://download.docker.com/linux/debian/gpg"
        SUPPORTED_ARCHES="$SUPPORTED_ARCH_DEBIAN"
        OS_INFO="Debian ${VERSION_ID} (${VERSION_CODENAME:-?})"
        ;;
    ubuntu)
        DOCKER_DISTRO="ubuntu"
        DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
        SUPPORTED_ARCHES="$SUPPORTED_ARCH_UBUNTU"
        OS_INFO="Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-?})"
        ;;
    *)
        log_error "OS '${ID}' tidak didukung. Script ini hanya untuk Ubuntu dan Debian."
        ;;
esac

# Docs menulis: Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
if [ -z "$CODENAME" ] && command_exists lsb_release; then
    CODENAME="$(lsb_release -cs)"
fi
[ -n "$CODENAME" ] || log_error "Tidak bisa menentukan codename. Pastikan VERSION_CODENAME ada di /etc/os-release."

ARCH="$(dpkg --print-architecture)"

log_info "OS: $OS_INFO | codename: $CODENAME | arch: $ARCH"
log_info "Channel: $CHANNEL${PIN_VERSION:+ | pin: $PIN_VERSION}"

# Validasi arsitektur.
case " $SUPPORTED_ARCHES " in
    *" $ARCH "*) ;;
    *)
        log_error "Arsitektur '$ARCH' tidak didukung untuk $DOCKER_DISTRO."
        log_note "Didukung: $SUPPORTED_ARCHES"
        exit 1
        ;;
esac

# Validasi codename: probe Release file repo Docker.
CODENAME_RELEASE_URL="https://download.docker.com/linux/${DOCKER_DISTRO}/dists/${CODENAME}/Release"

if curl -fsI "$CODENAME_RELEASE_URL" >/dev/null 2>&1; then
    log_info "Repo Docker tersedia untuk ${DOCKER_DISTRO}/${CODENAME}."
else
    log_error "Repo Docker tidak punya suite '${CODENAME}' untuk $DOCKER_DISTRO."
    log_note "Dicek: $CODENAME_RELEASE_URL"
    log_note "Docs (Debian): untuk Debian testing, ganti codename dengan rilis yang sesuai."
    log_note "Suite yang tersedia:"
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/dists/" 2>/dev/null \
        | grep -oE 'href="[^"]+/"' | sed 's/href="//;s/\/"//' \
        | grep -vE '^\.\.?$' | tr '\n' ' ' | fold -s -w 70 \
        | while IFS= read -r line; do log_note "  $line"; done
    exit 1
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Konfirmasi bila Docker sudah terpasang
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

REINSTALL=0
if command_exists docker; then
    log_warn "Docker sudah terinstal: $(docker --version 2>/dev/null || echo unknown)"

    if [ "$AUTO_YES" -eq 1 ]; then
        REINSTALL=1
        log_info "Mode -y: lanjut. Container, image, dan volume di /var/lib/docker tidak dihapus."
    elif [ -t 0 ]; then
        printf 'Lanjutkan update/reinstall? Data lama tidak dihapus. [y/N]: '
        REPLY=""
        read -r REPLY || true
        case "$REPLY" in
            [Yy]*) REINSTALL=1 ;;
            *) log_info "Dibatalkan."; exit 0 ;;
        esac
    else
        log_error "Docker sudah terpasang dan mode non-interaktif tanpa -y."
        log_note "Jalankan ulang dengan -y bila ingin reinstall."
        exit 1
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Helper eksekusi + log
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export DEBIAN_FRONTEND=noninteractive

RUN_TMPDIR=""
RUN_LOG=""

cleanup() {
    if [ -n "$RUN_TMPDIR" ] && [ -d "$RUN_TMPDIR" ]; then
        rm -rf "$RUN_TMPDIR"
    fi
}
trap cleanup EXIT

run_step() {
    local msg="$1"; shift

    if [ -z "$RUN_TMPDIR" ]; then
        RUN_TMPDIR="$(mktemp -d -t docker-installer.XXXXXX)"
        RUN_LOG="$RUN_TMPDIR/step.log"
    fi

    if [ "$DEBUG" = "1" ]; then
        if ! "$@" 2>&1 | tee "$RUN_LOG"; then
            printf '%s❌ GAGAL: %s%s\n' "$RED" "$msg" "$NC" >&2
            printf '%s--- 20 baris terakhir ---%s\n' "$YELLOW" "$NC" >&2
            tail -n 20 "$RUN_LOG" >&2 || true
            exit 1
        fi
    else
        if ! "$@" >"$RUN_LOG" 2>&1; then
            printf '%s❌ GAGAL: %s%s\n' "$RED" "$msg" "$NC" >&2
            printf '%s--- 20 baris terakhir ---%s\n' "$YELLOW" "$NC" >&2
            tail -n 20 "$RUN_LOG" >&2 || true
            printf '%s--- log lengkap: %s ---%s\n' "$YELLOW" "$RUN_LOG" "$NC" >&2
            exit 1
        fi
    fi
    log_info "$msg"
}

pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }

retry_cmd() {
    local tries="$1"; shift
    local sleep_sec="$1"; shift
    if [ "${1:-}" = "--" ]; then shift; fi

    local attempt=1
    while [ "$attempt" -le "$tries" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$tries" ]; then
            log_debug "Gagal (percobaan $attempt/$tries), ulangi dalam ${sleep_sec}s..."
            sleep "$sleep_sec"
            attempt=$(( attempt + 1 ))
            sleep_sec=$(( sleep_sec * 2 ))
        else
            return 1
        fi
    done
}

# Tunggu lock apt/dpkg.
# REVISI v2.1: Jika 'fuser' tidak tersedia, ini adalah hard failure karena
# melewati penungguan lock bisa menyebabkan kegagalan apt yang tidak jelas.
wait_for_apt() {
    local max_wait="${1:-120}"
    local waited=0

    if ! command_exists fuser; then
        log_error "FATAL: 'fuser' (dari paket psmisc) tidak tersedia."
        log_note "Tidak bisa menunggu lock apt dengan aman. Instal 'psmisc' secara manual lalu jalankan ulang."
        exit 1
    fi

    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1
    do
        if [ "$waited" -ge "$max_wait" ]; then
            log_error "Timeout menunggu lock apt/dpkg (>${max_wait}s). Proses apt lain masih jalan?"
        fi
        log_debug "Menunggu lock apt/dpkg..."
        sleep 2
        waited=$(( waited + 2 ))
    done
}

install_pkgs_if_available() {
    local msg="$1"; shift
    local to_install=()
    local p

    for p in "$@"; do
        if pkg_available "$p"; then
            to_install+=("$p")
        else
            log_warn "Paket '$p' tidak ada di repo ini, dilewati."
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        log_warn "Tidak ada paket yang bisa diinstal untuk: $msg"
        return 0
    fi

    wait_for_apt 120
    run_step "$msg" apt-get install -y --no-install-recommends "${to_install[@]}"
}

# Normalisasi versi Debian.
normalize_version() {
    local v="${1#*:}"             # buang epoch "5:"
    v="${v%%+ds*}"                # buang "+dsN" (repack Debian)
    printf '%s' "${v%%-[0-9]*~*}" # buang "-N~distro"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Dependensi
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Update repo sistem"

wait_for_apt 120
run_step "apt-get update" retry_cmd 4 2 -- apt-get update -o Acquire::Retries=3

log_step "Instal dependensi"

install_pkgs_if_available "Dependensi inti" \
    ca-certificates curl lsb-release psmisc gnupg

if [ "$SKIP_ROOTLESS" -eq 0 ]; then
    install_pkgs_if_available "Dependensi rootless" \
        dbus-user-session fuse-overlayfs slirp4netns uidmap
fi

command_exists fuser || log_warn "'fuser' (psmisc) tidak ada — deteksi lock apt dilewati."

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Hentikan service sebelum mencabut paket
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

HAVE_SYSTEMD=0
if command_exists systemctl && systemctl list-unit-files >/dev/null 2>&1; then
    HAVE_SYSTEMD=1
fi

WSL_ENV=0
if [ -f /proc/sys/kernel/osrelease ] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    WSL_ENV=1
fi

log_step "Hentikan service Docker"

if [ "$HAVE_SYSTEMD" -eq 1 ]; then
    for svc in docker.socket docker.service containerd.service; do
        if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
            if systemctl stop "$svc" >/dev/null 2>&1; then
                log_info "Stop $svc"
            else
                log_debug "$svc tidak aktif."
            fi
        fi
    done
else
    log_debug "systemd tidak tersedia, lewati."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Hapus paket konflik
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Hapus paket Docker lama & konflik"

CONFLICT_PKGS="docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc"
if [ "$DOCKER_DISTRO" = "ubuntu" ]; then
    CONFLICT_PKGS="$CONFLICT_PKGS docker-compose-v2"
fi
if [ "$REINSTALL" -eq 1 ]; then
    CONFLICT_PKGS="$CONFLICT_PKGS docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras"
fi

wait_for_apt 120

# shellcheck disable=SC2086
INSTALLED_CONFLICTS="$(dpkg --get-selections $CONFLICT_PKGS 2>/dev/null | awk '$2=="install"{print $1}' || true)"

if [ -n "$INSTALLED_CONFLICTS" ]; then
    log_info "Terpasang & akan dicabut: $INSTALLED_CONFLICTS"
    # shellcheck disable=SC2086
    run_step "Hapus paket konflik" apt-get remove -y $INSTALLED_CONFLICTS
    run_step "Autoremove paket yatim" apt-get autoremove -y
else
    log_info "Tidak ada paket konflik yang terpasang."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Repo Docker: GPG key + Deb822 docker.sources
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Tambahkan GPG key resmi Docker"

install -d -m 0755 /etc/apt/keyrings
KEYRING_PATH="/etc/apt/keyrings/docker.asc"

rm -f /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list

run_step "Download GPG key Docker" curl -fsSL "$DOCKER_KEY_URL" -o "$KEYRING_PATH"
chmod a+r "$KEYRING_PATH"

# REVISI v2.1: Verifikasi fingerprint GPG key untuk mencegah serangan MITM.
log_info "Memverifikasi fingerprint GPG key..."
ACTUAL_FP="$(gpg --show-keys --with-fingerprint --with-colons "$KEYRING_PATH" 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}' || true)"

if [ -z "$ACTUAL_FP" ]; then
    log_error "Gagal membaca fingerprint dari $KEYRING_PATH. File key mungkin korup."
    exit 1
fi

if [ "$ACTUAL_FP" != "${DOCKER_GPG_FINGERPRINT// /}" ]; then
    log_error "Fingerprint GPG key TIDAK COCOK!"
    log_note "Diharapkan: $DOCKER_GPG_FINGERPRINT"
    log_note "Ditemukan : $ACTUAL_FP"
    log_note "Kemungkinan serangan MITM atau file key telah dimodifikasi. Instalasi dibatalkan."
    exit 1
fi

log_info "Fingerprint GPG key terverifikasi: $DOCKER_GPG_FINGERPRINT"
log_info "GPG key: $KEYRING_PATH"

log_step "Tambahkan repository Docker ($CHANNEL)"

DOCKER_SOURCES_FILE="/etc/apt/sources.list.d/docker.sources"

cat > "$DOCKER_SOURCES_FILE" <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_DISTRO}
Suites: ${CODENAME}
Components: ${CHANNEL}
Architectures: ${ARCH}
Signed-By: ${KEYRING_PATH}
EOF

log_info "Ditulis: $DOCKER_SOURCES_FILE"
log_note "URIs: https://download.docker.com/linux/${DOCKER_DISTRO}"
log_note "Suites: ${CODENAME} | Components: ${CHANNEL} | Architectures: ${ARCH}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Instalasi paket
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Update repo & instal Docker Engine"

run_step "apt-get update (setelah repo Docker)" retry_cmd 4 2 -- apt-get update -o Acquire::Retries=3

BASE_PKGS=(containerd.io docker-buildx-plugin docker-compose-plugin)
ENGINE_PKGS=(docker-ce docker-ce-cli)

if [ -n "$PIN_VERSION" ]; then
    AVAILABLE_RAW="$(apt-cache madison docker-ce | awk '{print $3}' || true)"
    [ -n "$AVAILABLE_RAW" ] || log_error "Repo Docker tidak punya docker-ce. Cek konektivitas: curl -I $DOCKER_KEY_URL"

    WANT_NORM="$(normalize_version "$PIN_VERSION")"
    RESOLVED=""

    while IFS= read -r v; do
        [ -n "$v" ] || continue
        if [ "$v" = "$PIN_VERSION" ]; then
            RESOLVED="$v"
            break
        fi
    done <<< "$AVAILABLE_RAW"

    if [ -z "$RESOLVED" ]; then
        while IFS= read -r v; do
            [ -n "$v" ] || continue
            if [ "$(normalize_version "$v")" = "$WANT_NORM" ]; then
                RESOLVED="$v"
                break
            fi
        done <<< "$AVAILABLE_RAW"
    fi

    if [ -z "$RESOLVED" ]; then
        log_error "Versi '$PIN_VERSION' tidak ada di repo ${DOCKER_DISTRO}/${CODENAME} (${CHANNEL})."
        log_note "Dicoba cari: $WANT_NORM"
        log_note "Tersedia (10 terbaru):"
        printf '%s\n' "$AVAILABLE_RAW" | head -n 10 | sed 's/^/   /'
        exit 1
    fi

    log_info "Pin versi: $PIN_VERSION -> $RESOLVED"

    INSTALL_LIST=("${BASE_PKGS[@]}" "docker-ce=$RESOLVED" "docker-ce-cli=$RESOLVED")

    if [ "$SKIP_ROOTLESS" -eq 0 ] && pkg_available docker-ce-rootless-extras; then
        if printf '%s\n' "$(apt-cache madison docker-ce-rootless-extras | awk '{print $3}' || true)" \
           | grep -Fxq "$RESOLVED"; then
            INSTALL_LIST+=("docker-ce-rootless-extras=$RESOLVED")
        else
            log_warn "rootless-extras tidak punya versi $RESOLVED — pasang versi terbaru."
            INSTALL_LIST+=(docker-ce-rootless-extras)
        fi
    fi

    run_step "Instalasi Docker Engine (pinned $RESOLVED)" \
        apt-get install -y --allow-downgrades --no-install-recommends "${INSTALL_LIST[@]}"
else
    INSTALL_LIST=("${BASE_PKGS[@]}" "${ENGINE_PKGS[@]}")

    if [ "$SKIP_ROOTLESS" -eq 0 ] && pkg_available docker-ce-rootless-extras; then
        INSTALL_LIST+=(docker-ce-rootless-extras)
    fi

    run_step "Instalasi Docker Engine & plugin" \
        apt-get install -y --no-install-recommends "${INSTALL_LIST[@]}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# subuid/subgid untuk rootless
# REVISI v2.1: Verifikasi rentang minimal 65.536 sesuai dokumentasi resmi.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$SKIP_ROOTLESS" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
    log_step "Siapkan subuid/subgid untuk rootless"

    SUBUID_LINE="$(grep "^${REAL_USER}:" /etc/subuid 2>/dev/null || true)"
    SUBGID_LINE="$(grep "^${REAL_USER}:" /etc/subgid 2>/dev/null || true)"

    if [ -n "$SUBUID_LINE" ] && [ -n "$SUBGID_LINE" ]; then
        # Ekstrak rentang: "user:100000:65536" -> 65536
        SUBUID_RANGE="$(echo "$SUBUID_LINE" | cut -d: -f3)"
        SUBGID_RANGE="$(echo "$SUBGID_LINE" | cut -d: -f3)"

        if [ "${SUBUID_RANGE:-0}" -ge 65536 ] && [ "${SUBGID_RANGE:-0}" -ge 65536 ]; then
            log_info "subuid/subgid untuk $REAL_USER sudah ada dengan rentang memadai (${SUBUID_RANGE}/${SUBGID_RANGE})."
        else
            log_warn "Rentang subuid/subgid untuk $REAL_USER kurang dari 65.536."
            log_note "Rootless mode membutuhkan minimal 65.536 subordinate UID/GID."
            log_note "Perbaiki manual: usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $REAL_USER"
        fi
    elif usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$REAL_USER"; then
        log_info "subuid/subgid 100000-165535 untuk $REAL_USER."
    else
        log_warn "Gagal menambah subuid/subgid — rootless mode tidak akan berfungsi."
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Logging driver
# REVISI v2.1: Beri peringatan jika daemon.json ada tapi tidak punya log-driver.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DAEMON_JSON="/etc/docker/daemon.json"

log_step "Konfigurasi logging driver"

if [ -f "$DAEMON_JSON" ]; then
    log_warn "$DAEMON_JSON sudah ada — tidak ditimpa."
    if grep -q '"log-driver"' "$DAEMON_JSON" 2>/dev/null; then
        log_info "Konfigurasi log-driver terdeteksi di daemon.json."
    else
        log_warn "daemon.json TIDAK memiliki konfigurasi log-driver."
        log_note "Rekomendasi: tambahkan rotasi log untuk mencegah disk penuh, misalnya:"
        log_note '{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }'
    fi
elif [ "$NO_START" -eq 1 ]; then
    log_warn "Mode --no-start: daemon.json tidak ditulis. Tambahkan manual sebelum start:"
    log_note '{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }'
else
    install -d -m 0755 /etc/docker
    cat > "$DAEMON_JSON" <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    chmod 0644 "$DAEMON_JSON"
    log_info "Ditulis $DAEMON_JSON — log-driver: local (rotasi 10m x 3)"
    log_note "Driver 'local' rotasi otomatis; json-file tidak."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Grup docker
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Konfigurasi user & grup"

in_docker_group() {
    case " $(id -nG "$1" 2>/dev/null) " in
        *" docker "*) return 0 ;;
        *)            return 1 ;;
    esac
}

if [ "$REAL_USER" = "root" ]; then
    log_info "Dijalankan sebagai root — grup docker tidak diperlukan."
else
    if in_docker_group "$REAL_USER"; then
        log_info "User $REAL_USER sudah ada di grup docker."
    else
        ADD_USER=0
        if [ "$AUTO_YES" -eq 1 ]; then
            log_warn "Grup 'docker' memberi akses setara root — TIDAK ditambahkan otomatis pada mode -y."
            log_note "Bila perlu: sudo usermod -aG docker $REAL_USER  (lalu logout/login)"
        elif [ -t 0 ]; then
            printf 'Tambahkan %s ke grup docker (setara root)? [y/N]: ' "$REAL_USER"
            REPLY=""
            read -r REPLY || true
            case "$REPLY" in
                [Yy]*) ADD_USER=1 ;;
                *)     log_info "Dilewati." ;;
            esac
        else
            log_warn "Non-interaktif tanpa -y — grup docker dilewati."
            log_note "Bila perlu: sudo usermod -aG docker $REAL_USER"
        fi

        if [ "$ADD_USER" -eq 1 ]; then
            if usermod -aG docker "$REAL_USER"; then
                log_info "$REAL_USER ditambahkan ke grup docker (perlu logout/login)."
            else
                log_warn "Gagal menambah $REAL_USER ke grup docker."
            fi
            log_warn "Grup 'docker' memberi akses setara root — hanya user tepercaya."
        fi
    fi

    if [ ! -d "$REAL_HOME/.docker" ]; then
        mkdir -p "$REAL_HOME/.docker"
        chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.docker"
        log_info "Dibuat: $REAL_HOME/.docker"
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Enable & start service
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Enable dan start service Docker"

if [ "$NO_START" -eq 1 ]; then
    log_warn "Mode --no-start: service tidak di-enable/di-start (sesuai permintaan)."
elif [ "$WSL_ENV" -eq 1 ]; then
    log_warn "WSL terdeteksi — lewati enable/start (di-handle WSL)."
elif [ "$HAVE_SYSTEMD" -eq 1 ]; then
    run_step "systemctl enable + restart docker" bash -c '
        set -e
        systemctl enable docker.service containerd.service
        systemctl restart docker.service
    '
else
    log_warn "systemd tidak tersedia — lewati enable/start."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tes fungsional: hello-world
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Tes fungsional (hello-world)"

DOCKER_READY=0
if docker info >/dev/null 2>&1; then
    DOCKER_READY=1
elif [ "$HAVE_SYSTEMD" -eq 1 ] && [ "$NO_START" -eq 0 ] && [ "$WSL_ENV" -eq 0 ]; then
    log_debug "Daemon belum responsif, mencoba start..."
    systemctl start docker.service >/dev/null 2>&1 || true
    sleep 2
    if docker info >/dev/null 2>&1; then
        DOCKER_READY=1
    fi
fi

if [ "$DOCKER_READY" -eq 1 ]; then
    if docker run --rm hello-world >/dev/null 2>&1; then
        log_info "hello-world berhasil dijalankan."
    else
        log_warn "hello-world GAGAL — cek registry/daemon."
        log_note "Diagnostik: journalctl -u docker -n 50 --no-pager"
    fi

    IMAGE_ID="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null \
        | awk '$1=="hello-world:latest"{print $2; exit}' || true)"
    if [ -n "$IMAGE_ID" ]; then
        if docker image rm -f "$IMAGE_ID" >/dev/null 2>&1; then
            log_debug "Image hello-world dibersihkan."
        fi
    fi
else
    log_warn "Docker daemon tidak responsif — tes hello-world dilewati."
    log_note "Diagnostik: systemctl status docker / journalctl -u docker -n 50 --no-pager"
fi

log_step "Bersihkan cache paket"
run_step "apt-get clean" apt-get clean

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Ringkasan
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

get_version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }

DOCKER_VER="$(docker --version 2>/dev/null | get_version || true)"
COMPOSE_VER="$(docker compose version 2>/dev/null | get_version || true)"
BUILDX_VER="$(docker buildx version 2>/dev/null | get_version || true)"

LOG_DRIVER="—"
if [ -f "$DAEMON_JSON" ]; then
    while IFS= read -r line; do
        case "$line" in
            *'"log-driver"'*)
                LOG_DRIVER="${line##*:}"
                LOG_DRIVER="${LOG_DRIVER//\"/}"
                LOG_DRIVER="${LOG_DRIVER// /}"
                LOG_DRIVER="${LOG_DRIVER%,}"
                break
                ;;
        esac
    done < "$DAEMON_JSON"
fi

echo
printf '%s──────────────────────────────────────────%s\n' "$BLUE" "$NC"
printf '  %-16s %s\n' "Docker Engine"   "${DOCKER_VER:-n/a}"
printf '  %-16s %s\n' "Docker Compose"  "${COMPOSE_VER:-n/a}"
printf '  %-16s %s\n' "Docker Buildx"   "${BUILDX_VER:-n/a}"
printf '  %-16s %s\n' "Release channel" "$CHANNEL"
printf '  %-16s %s\n' "Log driver"      "$LOG_DRIVER"
printf '  %-16s %s\n' "Installer"       "v${INSTALLER_VERSION} (docs ${DOCS_CHECKED})"

printf '  %-16s ' "Daemon status"
if [ "$DOCKER_READY" -eq 1 ]; then
    printf '%s● running%s\n' "$GREEN" "$NC"
else
    printf '%s○ not running%s\n' "$YELLOW" "$NC"
fi

printf '  %-16s ' "Docker group"
if [ "$REAL_USER" != "root" ] && in_docker_group "$REAL_USER"; then
    printf '%s✔ %s%s\n' "$GREEN" "$REAL_USER" "$NC"
else
    printf '%s—%s\n' "$YELLOW" "$NC"
fi
printf '%s──────────────────────────────────────────%s\n' "$BLUE" "$NC"
echo
printf '%s✅  Instalasi Docker selesai.%s\n' "$GREEN" "$NC"

exit 0

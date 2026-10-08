#!/usr/bin/env bash
#
# Docker Engine installer — Ubuntu & Debian
# Versi: 3.0 FINAL | Docs checked: 2026-10-09
# Author: Fath Nojoum
#
# shellcheck disable=SC2317
#
# Perubahan v3.0:
#   - FIX: wait_for_apt tidak lagi hard-fail saat bootstrap (chicken-and-egg
#     dengan psmisc/fuser). Sekarang pakai /proc scan sebagai fallback.
#   - wait_for_apt berlapis: fuser → /proc scan → no-op.
#   - Timeout menampilkan nama proses pemegang lock.
#

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Konstanta
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTALLER_VERSION="3.0"
DOCS_CHECKED="2026-10-09"

DOCKER_GPG_FINGERPRINT="9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"

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
TARGET_USER=""

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
        --user)          [ $# -ge 2 ] || log_error "--user butuh nilai."
                         TARGET_USER="$2"; shift ;;
        --user=*)        TARGET_USER="${1#*=}" ;;
        --debug)         DEBUG=1 ;;
        --)              shift; break ;;
        -h|--help)
            cat <<'USAGE'
Usage: install-docker.sh [options]

Options:
  -y, --yes              Non-interaktif
  --no-start             Jangan enable/start service (container/CI)
  --channel CHANNEL      stable (default) | test | nightly
  --version VERSION      Pin docker-ce & docker-ce-cli
  --skip-rootless        Jangan install docker-ce-rootless-extras
  --user USER            User non-root untuk setup grup docker & rootless
  --debug                Tampilkan output apt/curl live
  -h, --help             Bantuan ini

Catatan:
  - v3.0: wait_for_apt tidak butuh 'fuser' saat bootstrap (fix Debian minimal).
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

# Prioritas: --user > SUDO_USER > root
if [ -n "$TARGET_USER" ]; then
    REAL_USER="$TARGET_USER"
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="root"
fi

if [ "$REAL_USER" = "root" ]; then
    REAL_HOME="/root"
else
    REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || true)"
    [ -n "$REAL_HOME" ] || REAL_HOME="/home/$REAL_USER"
    # Validasi user benar-benar ada
    if ! getent passwd "$REAL_USER" >/dev/null 2>&1; then
        log_error "User '$REAL_USER' tidak ditemukan."
    fi
fi

umask 022

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Banner
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

cat <<'BANNER'

╔═══════════════════════════════════════════════════════╗
║  🐳  Docker Auto-Installer  v3.0 FINAL                ║
║  By: Fath Nojoum                                      ║
╚═══════════════════════════════════════════════════════╝
BANNER

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Deteksi OS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
if [ -z "$CODENAME" ] && command_exists lsb_release; then
    CODENAME="$(lsb_release -cs)"
fi
[ -n "$CODENAME" ] || log_error "Tidak bisa menentukan codename."

ARCH="$(dpkg --print-architecture)"

log_info "OS: $OS_INFO | codename: $CODENAME | arch: $ARCH"
log_info "Channel: $CHANNEL${PIN_VERSION:+ | pin: $PIN_VERSION}"
log_info "Target user: $REAL_USER"

case " $SUPPORTED_ARCHES " in
    *" $ARCH "*) ;;
    *)
        log_error "Arsitektur '$ARCH' tidak didukung untuk $DOCKER_DISTRO."
        log_note "Didukung: $SUPPORTED_ARCHES"
        exit 1
        ;;
esac

# Validasi codename via probe ke Release file
CODENAME_RELEASE_URL="https://download.docker.com/linux/${DOCKER_DISTRO}/dists/${CODENAME}/Release"

if curl -fsI "$CODENAME_RELEASE_URL" >/dev/null 2>&1; then
    log_info "Repo Docker tersedia untuk ${DOCKER_DISTRO}/${CODENAME}."
else
    log_error "Repo Docker tidak punya suite '${CODENAME}' untuk $DOCKER_DISTRO."
    log_note "Dicek: $CODENAME_RELEASE_URL"
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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FIX v3.0: wait_for_apt tanpa ketergantungan 'fuser'
#
# Masalah v2.1: 'fuser' disediakan paket 'psmisc' yang BARU diinstal di step
# berikutnya. Saat Debian minimal, fuser belum ada → hard-fail sebelum
# sempat instal psmisc. Chicken-and-egg.
#
# Solusi v3.0: tiga lapis deteksi lock
#   1. fuser (jika tersedia)   — presisi, cek lock file spesifik
#   2. /proc scan              — selalu ada di Linux, cek nama proses apt/dpkg
#   3. no-op                   — kalau dua-duanya gagal (sangat jarang)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Deteksi proses apt/dpkg via /proc — tidak butuh tools eksternal
_apt_process_running() {
    local proc comm
    for proc in /proc/[0-9]*/comm; do
        [ -r "$proc" ] || continue
        comm="$(cat "$proc" 2>/dev/null || true)"
        case "$comm" in
            apt|apt-get|dpkg|dpkg-deb|unattended-upgrade|apt-helper|aptd)
                return 0
                ;;
        esac
    done
    return 1
}

# Tampilkan nama proses apt yang sedang berjalan (untuk diagnostik timeout)
_apt_process_info() {
    local proc pid comm
    for proc in /proc/[0-9]*/comm; do
        [ -r "$proc" ] || continue
        comm="$(cat "$proc" 2>/dev/null || true)"
        case "$comm" in
            apt|apt-get|dpkg|dpkg-deb|unattended-upgrade|apt-helper|aptd)
                pid="$(basename "$(dirname "$proc")")"
                printf '   PID %s: %s\n' "$pid" "$comm"
                ;;
        esac
    done
}

wait_for_apt() {
    local max_wait="${1:-120}"
    local waited=0

    # ── Tier 1: fuser (paling presisi, cek lock file spesifik) ──
    if command_exists fuser; then
        log_debug "Menggunakan 'fuser' untuk deteksi lock apt."
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
              fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
              fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
              fuser /var/cache/apt/archives/lock >/dev/null 2>&1
        do
            if [ "$waited" -ge "$max_wait" ]; then
                log_error "Timeout menunggu lock apt/dpkg (>${max_wait}s)."
                log_note "Proses yang memegang lock:"
                _apt_process_info >&2 || true
                exit 1
            fi
            log_debug "Menunggu lock apt/dpkg (fuser)... ${waited}s"
            sleep 2
            waited=$(( waited + 2 ))
        done
        return 0
    fi

    # ── Tier 2: /proc scan (fallback, selalu ada) ──
    log_debug "fuser tidak tersedia, fallback ke /proc scan."
    while _apt_process_running; do
        if [ "$waited" -ge "$max_wait" ]; then
            log_error "Timeout menunggu proses apt/dpkg selesai (>${max_wait}s)."
            log_note "Proses yang masih berjalan:"
            _apt_process_info >&2 || true
            exit 1
        fi
        log_debug "Menunggu proses apt/dpkg selesai... ${waited}s"
        sleep 2
        waited=$(( waited + 2 ))
    done
    return 0
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

# Normalisasi versi Debian
normalize_version() {
    local v="${1#*:}"             # buang epoch "5:"
    v="${v%%+ds*}"                # buang "+dsN"
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
    ca-certificates curl lsb-release gnupg psmisc

if [ "$SKIP_ROOTLESS" -eq 0 ]; then
    install_pkgs_if_available "Dependensi rootless" \
        dbus-user-session fuse-overlayfs slirp4netns uidmap
fi

# Setelah psmisc terinstal, cek apakah fuser sekarang tersedia
if command_exists fuser; then
    log_debug "'fuser' tersedia — deteksi lock presisi aktif."
else
    log_warn "'fuser' tidak tersedia — deteksi lock pakai /proc scan (tetap aman)."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Deteksi systemd & WSL
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

HAVE_SYSTEMD=0
if command_exists systemctl && systemctl list-unit-files >/dev/null 2>&1; then
    HAVE_SYSTEMD=1
fi

WSL_ENV=0
if [ -f /proc/sys/kernel/osrelease ] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    WSL_ENV=1
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Hentikan service sebelum mencabut paket
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
# GPG key + verifikasi fingerprint
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Tambahkan GPG key resmi Docker"

install -d -m 0755 /etc/apt/keyrings
KEYRING_PATH="/etc/apt/keyrings/docker.asc"

rm -f /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list

run_step "Download GPG key Docker" curl -fsSL "$DOCKER_KEY_URL" -o "$KEYRING_PATH"
chmod a+r "$KEYRING_PATH"

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
    log_note "Kemungkinan serangan MITM. Instalasi dibatalkan."
    exit 1
fi

log_info "Fingerprint terverifikasi: $DOCKER_GPG_FINGERPRINT"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Repo Docker (Deb822)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
    [ -n "$AVAILABLE_RAW" ] || log_error "Repo Docker tidak punya docker-ce."

    WANT_NORM="$(normalize_version "$PIN_VERSION")"
    RESOLVED=""

    while IFS= read -r v; do
        [ -n "$v" ] || continue
        if [ "$v" = "$PIN_VERSION" ]; then
            RESOLVED="$v"; break
        fi
    done <<< "$AVAILABLE_RAW"

    if [ -z "$RESOLVED" ]; then
        while IFS= read -r v; do
            [ -n "$v" ] || continue
            if [ "$(normalize_version "$v")" = "$WANT_NORM" ]; then
                RESOLVED="$v"; break
            fi
        done <<< "$AVAILABLE_RAW"
    fi

    if [ -z "$RESOLVED" ]; then
        log_error "Versi '$PIN_VERSION' tidak ada di repo ${DOCKER_DISTRO}/${CODENAME} (${CHANNEL})."
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
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [ "$SKIP_ROOTLESS" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
    log_step "Siapkan subuid/subgid untuk rootless"

    SUBUID_LINE="$(grep "^${REAL_USER}:" /etc/subuid 2>/dev/null || true)"
    SUBGID_LINE="$(grep "^${REAL_USER}:" /etc/subgid 2>/dev/null || true)"

    if [ -n "$SUBUID_LINE" ] && [ -n "$SUBGID_LINE" ]; then
        SUBUID_RANGE="$(echo "$SUBUID_LINE" | cut -d: -f3)"
        SUBGID_RANGE="$(echo "$SUBGID_LINE" | cut -d: -f3)"
        if [ "${SUBUID_RANGE:-0}" -ge 65536 ] && [ "${SUBGID_RANGE:-0}" -ge 65536 ]; then
            log_info "subuid/subgid OK (${SUBUID_RANGE}/${SUBGID_RANGE})."
        else
            log_warn "Rentang subuid/subgid < 65.536 — rootless mungkin gagal."
            log_note "Perbaiki: usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $REAL_USER"
        fi
    elif usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$REAL_USER"; then
        log_info "subuid/subgid 100000-165535 untuk $REAL_USER."
    else
        log_warn "Gagal menambah subuid/subgid — rootless mode tidak akan berfungsi."
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Logging driver
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DAEMON_JSON="/etc/docker/daemon.json"

log_step "Konfigurasi logging driver"

if [ -f "$DAEMON_JSON" ]; then
    log_warn "$DAEMON_JSON sudah ada — tidak ditimpa."
    if grep -q '"log-driver"' "$DAEMON_JSON" 2>/dev/null; then
        log_info "log-driver terdeteksi di daemon.json."
    else
        log_warn "daemon.json TIDAK punya log-driver."
        log_note 'Rekomendasi: { "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }'
    fi
elif [ "$NO_START" -eq 1 ]; then
    log_warn "Mode --no-start: daemon.json tidak ditulis."
    log_note 'Manual: { "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }'
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
            log_warn "Grup 'docker' = setara root — TIDAK ditambahkan otomatis pada mode -y."
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
        chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.docker" 2>/dev/null || true
        log_info "Dibuat: $REAL_HOME/.docker"
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Enable & start service
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "Enable dan start service Docker"

if [ "$NO_START" -eq 1 ]; then
    log_warn "Mode --no-start: service tidak di-enable/start."
elif [ "$WSL_ENV" -eq 1 ]; then
    log_warn "WSL terdeteksi — lewati enable/start."
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
printf '  %-16s %s\n' "Target user"     "$REAL_USER"
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

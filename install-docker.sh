#!/bin/bash

set -e

echo "=== Deteksi OS ==="
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "❌ Tidak bisa mendeteksi OS (Debian/Ubuntu)."
    exit 1
fi

if [[ "$ID" == "debian" ]]; then
    DOCKER_DISTRO="debian"
    DOCKER_KEY_URL="https://download.docker.com/linux/debian/gpg"
    OS_INFO="Debian"
elif [[ "$ID" == "ubuntu" ]]; then
    DOCKER_DISTRO="ubuntu"
    DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
    OS_INFO="Ubuntu"
else
    echo "❌ Deteksi OS: $ID. Script hanya mendukung Ubuntu dan Debian."
    exit 1
fi

echo "✅ OS terdeteksi: $OS_INFO"

echo "=== Update dan instal dependensi ==="
sudo apt update && sudo apt install -y \
    apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
echo "✅ Update dan instal dependensi selesai."

echo "=== Tambahkan GPG key resmi Docker ==="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL $DOCKER_KEY_URL | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "✅ GPG key Docker berhasil ditambahkan."

echo "=== Tambahkan repository Docker ==="
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DOCKER_DISTRO $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
echo "✅ Repository Docker berhasil ditambahkan."

echo "=== Update repository dan instal Docker + Compose plugin + recommended ==="
sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-compose-plugin \
  docker-ce-rootless-extras \
  pigz \
  docker-buildx-plugin
echo "✅ Semua paket utama & rekomendasi Docker sudah diinstal."

echo "=== (Opsional) Menambahkan user ke grup docker ==="
sudo usermod -aG docker $USER
echo "✅ User sudah ditambahkan ke grup docker (logout/login agar efek berlaku)."

echo "=== Verifikasi versi docker, compose, dan buildx ==="
docker --version
docker compose version
docker buildx version || echo "buildx belum tersedia (aktifkan dulu dengan 'docker buildx create --use')"
echo "✅ Verifikasi versi selesai."

echo "=== Selesai! Silakan logout/login agar bisa menjalankan docker tanpa sudo ✅==="

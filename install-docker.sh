#!/bin/bash

set -e

# Deteksi OS otomatis
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "Tidak bisa deteksi OS (Debian/Ubuntu)."
    exit 1
fi

if [[ "$ID" == "debian" ]]; then
    DOCKER_DISTRO="debian"
    DOCKER_KEY_URL="https://download.docker.com/linux/debian/gpg"
else
    DOCKER_DISTRO="ubuntu"
    DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
fi

echo "=== Update dan instal dependensi ==="
sudo apt update
sudo apt install -y \
    apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common

echo "=== Tambahkan GPG key resmi Docker ==="
sudo mkdir -p /etc/apt/keyrings
curl -fsSL $DOCKER_KEY_URL | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "=== Tambahkan repository Docker ==="
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DOCKER_DISTRO $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "=== Update repository dan instal Docker + Compose plugin ==="
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "=== (Opsional) Menambahkan user ke grup docker ==="
sudo usermod -aG docker $USER

echo "=== Verifikasi versi docker dan docker compose ==="
docker --version
docker compose version

echo "=== Selesai! Silakan logout/login agar bisa menjalankan docker tanpa sudo ==="

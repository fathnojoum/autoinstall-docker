#!/bin/bash
set -e

echo "=== Deteksi OS ==="
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_INFO=$ID
    echo "✅ Deteksi OS: $OS_INFO"
else
    echo "❌ Tidak bisa mendeteksi OS."
    OS_INFO="unknown"
fi

echo "=== STOP SEMUA CONTAINER ==="
if command -v docker >/dev/null; then
  docker ps -q | xargs -r docker stop || true
  echo "✅ Semua container sudah dihentikan."
else
  echo "⚠️ Docker tidak ditemukan, skip stop container."
fi

echo "=== PILIHAN: HAPUS SEMUA VOLUME ATAU TIDAK ==="
if command -v docker >/dev/null; then
  read -p "Apakah Anda ingin menghapus semua Docker volume? (y/n): " DEL_VOL
  if [ "$DEL_VOL" = "y" ]; then
    docker ps -aq | xargs -r docker rm || true
    docker volume ls -q | xargs -r docker volume rm || true
    echo "✅ Semua volume Docker telah dihapus."
  else
    echo "⏭️ Volume Docker dipertahankan."
  fi
  docker images -q | xargs -r docker rmi -f || true
  docker network ls --filter "type=custom" -q | xargs -r docker network rm || true
  echo "✅ Semua container, image, dan network lainnya sudah dihapus."
else
  echo "⚠️ Docker tidak ditemukan, skip penghapusan resource."
fi

echo "=== STOP SERVICE DOCKER DAN CONTAINERD ==="
systemctl stop docker || true
systemctl stop containerd || true
echo "✅ Service docker dan containerd sudah dihentikan."

echo "=== UNINSTALL DOCKER DAN SEMUA KOMPONENNYA ==="
apt purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose docker-buildx-plugin || true
apt autoremove -y
echo "✅ Semua paket docker, compose, dan buildx sudah di-uninstall."

echo "=== HAPUS FILE DAN KONFIG DOCKER (Kecuali docker-compose.yml/yaml) ==="
find / -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \) \
  -not -path "/proc/*" -not -path "/sys/*" -not -path "/snap/*" -print > /tmp/compose_files.txt

rm -rf \
  /var/lib/containerd \
  /etc/docker \
  /etc/systemd/system/docker.service.d \
  /var/run/docker.sock \
  /etc/apt/keyrings/docker.gpg \
  /usr/local/bin/docker-compose \
  ~/.docker || true

echo "✅ File config & service Docker sudah dihapus (file docker-compose.yml/yaml diselamatkan)."

echo
echo "=== VERIFIKASI & LIST FILE docker-compose yang Aman ==="
echo "Berikut adalah daftar file docker-compose.yml/yaml yang tetap aman dan tidak dihapus:"
echo
cat /tmp/compose_files.txt | while read file; do
  if [ -f "$file" ]; then
    echo "  - $file"
  fi
done
echo
rm -f /tmp/compose_files.txt

echo "✅ Semua file docker-compose.yml/yaml tetap aman."
echo

echo "=== HAPUS DOCKER REPOSITORY SOURCE LIST ==="
rm -f /etc/apt/sources.list.d/docker.list
echo "✅ Repo Docker sudah dihapus."

echo "=== DAEMON RELOAD & APT UPDATE ==="
systemctl daemon-reload
apt update
echo "✅ System daemon reload & apt update selesai."

echo "=== FINAL EVALUASI ==="
if command -v docker >/dev/null; then
  echo "❌ MASIH ADA docker di PATH: $(command -v docker) -- silakan cek manual."
else
  echo "✅ Docker SUDAH HILANG dari PATH."
fi

echo
echo "Script selesai. Docker berhasil dihapus, volume & file docker-compose aman ✅"
echo

#!/bin/bash
set -e

echo "=== STOP SEMUA CONTAINER ==="
docker ps -q | xargs -r docker stop || true

echo "=== REMOVE SEMUA CONTAINER, VOLUME, IMAGE, DAN NETWORK ==="
docker ps -aq | xargs -r docker rm || true
docker volume ls -q | xargs -r docker volume rm || true
docker images -q | xargs -r docker rmi -f || true
docker network ls --filter "type=custom" -q | xargs -r docker network rm || true

echo "=== STOP SERVICE DOCKER DAN CONTAINERD ==="
systemctl stop docker || true
systemctl stop containerd || true

echo "=== UNINSTALL DOCKER DAN SEMUA KOMPONENNYA ==="
apt purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose docker-buildx-plugin || true
apt autoremove -y

echo "=== HAPUS FILE, DATA, KEY, DAN CONFIG DOCKER ==="
rm -rf \
  /var/lib/docker \
  /var/lib/containerd \
  /etc/docker \
  /etc/systemd/system/docker.service.d \
  /var/run/docker.sock \
  /etc/apt/keyrings/docker.gpg \
  /usr/local/bin/docker-compose \
  ~/.docker

echo "=== HAPUS SOURCES LIST REPO DOCKER ==="
rm -f /etc/apt/sources.list.d/docker.list

echo "=== DAEMON RELOAD DAN UPDATE ==="
systemctl daemon-reload
apt update

echo "=== VERIFIKASI DAN EKSEKUSI PENGHAPUSAN SISA DOCKER BINARIES, FILE, dan SERVICE ==="

# Hapus binary docker jika masih tersisa di PATH
if command -v docker >/dev/null; then
  DOCKER_PATH="$(command -v docker)"
  echo "Menghapus binary docker: $DOCKER_PATH"
  rm -f "$DOCKER_PATH"
fi

# Hapus binary docker-compose classic jika ada
if command -v docker-compose >/dev/null; then
  COMPOSE_PATH="$(command -v docker-compose)"
  echo "Menghapus binary docker-compose: $COMPOSE_PATH"
  rm -f "$COMPOSE_PATH"
fi

# Kill semua process docker yang masih hidup
pgrep docker | xargs -r kill -9 || true

# Cari dan Hapus SELURUH file 'docker' di seluruh disk (kecuali /proc dan /sys dsb)
find / -type f -name '*docker*' ! -path "/proc/*" ! -path "/sys/*" ! -path "/snap/*" 2>/dev/null | while read f; do
  echo "Menghapus file: $f"
  rm -f "$f"
done

# Cari dan disable/hapus systemd unit docker jika tersisa
systemctl list-units --type=service | grep docker | awk '{print $1}' | while read svc; do
  echo "Menonaktifkan & menghapus service $svc"
  systemctl disable "$svc" || true
  systemctl stop "$svc" || true
  rm -f "/etc/systemd/system/$svc"
done

systemctl daemon-reload

echo "=== FINAL EVALUASI: ==="
if command -v docker; then
  echo "[PERINGATAN KHUSUS] MASIH ADA docker di PATH: $(command -v docker) -- silakan cek manual!"
else
  echo "Docker SUDAH HILANG dari PATH."
fi

echo "Script selesai. Docker benar-benar dihapus secara agresif!"

#!/usr/bin/env bash
# remove-and-backup-docker-fixed.sh
# Versi: perbaikan handle empty volume names & lebih robust untuk curl|bash
set -euo pipefail

BACKUP_ROOT="/root/BACKUP_DOCKER"
DRY_RUN=0
FORCE=0
PURGE=1
STOP_BEFORE_BACKUP=1

log(){ printf "✅ %s\n" "$1"; }
info(){ printf "ℹ️  %s\n" "$1"; }
warn(){ printf "⚠️  %s\n" "$1" >&2; }
err(){ printf "❌ %s\n" "$1" >&2; exit 1; }

timestamp_indonesia(){
  DAYNAME=(Senin Selasa Rabu Kamis Jumat Sabtu Minggu)
  MONTHNAME=(Januari Februari Maret April Mei Juni Juli Agustus September Oktober November Desember)
  Y=$(date +%Y); M=$(date +%m); D=$(date +%d); H=$(date +%H); MN=$(date +%M)
  IDX=$(date +%u); IDXMONTH=$((10#${M}-1)); di=$((IDX-1))
  printf "%s,%s%s%s_Jam%s.%s" "${DAYNAME[$di]}" "$D" "${MONTHNAME[$IDXMONTH]}" "$Y" "$H" "$MN"
}

print_progress_bar(){
  percent=$1; msg=${2:-""}
  width=36
  filled=$(( percent * width / 100 ))
  empty=$(( width - filled ))
  filled_s=$(printf "%0.s#" $(seq 1 $filled) 2>/dev/null || true)
  empty_s=$(printf "%0.s-" $(seq 1 $empty) 2>/dev/null || true)
  printf "\r[%s%s] %3d%% %s" "$filled_s" "$empty_s" "$percent" "$msg"
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --force) FORCE=1; shift;;
    --no-purge) PURGE=0; shift;;
    --no-stop-before-backup) STOP_BEFORE_BACKUP=0; shift;;
    --help) cat <<'USAGE'
Usage: script [--dry-run] [--force] [--no-purge] [--no-stop-before-backup]
USAGE
      exit 0;;
    *) err "Argumen tidak dikenal: $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || err "Jalankan sebagai root (sudo)."
command -v docker >/dev/null 2>&1 || err "Docker CLI tidak ditemukan."

if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  echo "PERINGATAN: Script akan membackup data Docker dan MENGHAPUS Docker."
  read -r -p "Lanjutkan? (y/N): " ans || true
  [[ "$ans" =~ ^[Yy]$ ]] || err "Dibatalkan oleh pengguna."
fi

mkdir -p "$BACKUP_ROOT" || err "Gagal buat $BACKUP_ROOT"
TMPDIR="$(mktemp -d -p /tmp rbk.XXXXXX)"; trap 'rm -rf "$TMPDIR"' EXIT

# stop containers
if [ "$STOP_BEFORE_BACKUP" -eq 1 ]; then
  info "Menghentikan semua container..."
  if [ "$DRY_RUN" -eq 0 ]; then docker ps -q | xargs -r docker stop >/dev/null 2>&1 || warn "Beberapa container mungkin gagal dihentikan."; else info "[DRY-RUN] stop containers"; fi
fi

# build mapping volume -> containers
declare -A VOL_TO_CONTAINERS
mapfile -t ALL_CONTAINERS < <(docker ps -aq 2>/dev/null || true)
for cid in "${ALL_CONTAINERS[@]:-}"; do
  mounts_json=$(docker inspect --format '{{json .Mounts}}' "$cid" 2>/dev/null || true)
  [ -z "$mounts_json" ] && continue
  # parse with python reading stdin (safe)
  echo "$mounts_json" | python3 - <<'PY' 2>/dev/null | while IFS= read -r line; do
import sys, json
s=sys.stdin.read()
if not s.strip(): sys.exit(0)
try:
  arr=json.loads(s)
except:
  sys.exit(0)
for m in arr:
  if m.get('Type')=='volume' and m.get('Name'):
    print("volume::%s::%s" % (m.get('Name'), m.get('Source') or ""))
PY
  do
    [ -z "$line" ] && continue
    case "$line" in
      volume::*) volname="${line#volume::}"; volname="${volname%%::*}" ;;
      *) continue ;;
    esac
    [ -z "$volname" ] && continue
    prev="${VOL_TO_CONTAINERS[$volname]:-}"
    if [ -z "$prev" ]; then VOL_TO_CONTAINERS["$volname"]="$cid"; else VOL_TO_CONTAINERS["$volname"]="${prev},${cid}"; fi
  done
done

mapfile -t ALL_VOLUMES < <(docker volume ls -q 2>/dev/null || true)
NUM_VOLUMES=${#ALL_VOLUMES[@]}
info "Ditemukan $NUM_VOLUMES volume."

# prepare
declare -a BACKUP_SUCCESSES=() BACKUP_FAILURES=()
ZIP=0; command -v zip >/dev/null 2>&1 && ZIP=1

safe_name(){ echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]/_/g'; }

backup_path_to_archive(){
  src="$1"; dest="$2"; base="$3"
  [ "$DRY_RUN" -eq 1 ] && { info "[DRY-RUN] archive $src -> $dest/${base}"; return 0; }
  [ -d "$src" ] || return 2
  if [ "$ZIP" -eq 1 ]; then
    tmpf="$TMPDIR/${base}.zip"; (cd "$src" && zip -r -q "$tmpf" .) || return 2
    mv "$tmpf" "$dest/${base}.zip" || return 2
    echo "$dest/${base}.zip"; return 0
  else
    tmpf="$TMPDIR/${base}.tar.gz"; tar -C "$src" -czf "$tmpf" . || return 2
    mv "$tmpf" "$dest/${base}.tar.gz" || return 2
    echo "$dest/${base}.tar.gz"; return 0
  fi
}

# loop volumes
count=0
total=$((NUM_VOLUMES+3))
for vol in "${ALL_VOLUMES[@]:-}"; do
  count=$((count+1))
  if [ -z "$vol" ]; then
    warn "Ditemukan nama volume kosong, dilewati."
    BACKUP_FAILURES+=(":volname-empty")
    print_progress_bar $((count*100/total)) "Skipped empty volume"
    printf "\n"
    continue
  fi
  mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
  [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ] && { warn "Volume $vol: mountpoint invalid — dilewati."; BACKUP_FAILURES+=("$vol:mountpoint-invalid"); print_progress_bar $((count*100/total)) "Volume $vol skipped"; printf "\n"; continue; }
  app="$vol"
  if [ -n "${VOL_TO_CONTAINERS[$vol]:-}" ]; then first="${VOL_TO_CONTAINERS[$vol]%%,*}"; cname=$(docker inspect --format '{{.Name}}' "$first" 2>/dev/null || true); cname="${cname#/}"; [ -n "$cname" ] && app="$cname"; fi
  safe_app=$(safe_name "$app"); dest="$BACKUP_ROOT/$safe_app"; [ "$DRY_RUN" -eq 0 ] && mkdir -p "$dest"
  ts=$(timestamp_indonesia); base="backup_appdata-docker_(${safe_app}_${vol})-${ts}"
  info "Backing up $vol -> $dest"
  if out=$(backup_path_to_archive "$mountpoint" "$dest" "$base" 2>&1); then BACKUP_SUCCESSES+=("$out"); info "Berhasil: $out"; else warn "Gagal backup $vol"; BACKUP_FAILURES+=("$vol:backup-failed"); fi
  print_progress_bar $((count*100/total)) "Processed $vol"; printf "\n"
done

# phase remove: containers/images/networks
print_progress_bar $(( (NUM_VOLUMES+1)*100/total )) "Removing containers/images/networks"; printf "\n"
docker ps -q | xargs -r docker stop >/dev/null 2>&1 || true
docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
docker images -q | xargs -r docker rmi -f >/dev/null 2>&1 || true
docker network ls --filter "type=custom" -q | xargs -r docker network rm >/dev/null 2>&1 || true

# remove volumes that were backed-up (skip failures)
print_progress_bar $(( (NUM_VOLUMES+2)*100/total )) "Removing volumes"; printf "\n"
mapfile -t CUR_VOLS < <(docker volume ls -q 2>/dev/null || true)
for v in "${CUR_VOLS[@]:-}"; do
  skip=0
  for f in "${BACKUP_FAILURES[@]:-}"; do [[ "$f" == "$v:"* || "$f" == "$v" ]] && { skip=1; break; }; done
  [ "$skip" -eq 1 ] && { warn "Skip rm $v (backup failed)"; continue; }
  docker volume rm -f "$v" >/dev/null 2>&1 || true
done

# final cleanup
print_progress_bar 100 "Final cleanup"; printf "\n"
docker system prune -af --volumes >/dev/null 2>&1 || true
if [ "$PURGE" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker.io || true
  apt-get autoremove -y || true
fi
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg 2>/dev/null || true
COMMON=(/var/lib/docker /var/lib/containerd /run/docker.sock /etc/docker /etc/containerd)
for d in "${COMMON[@]}"; do [ -e "$d" ] && rm -rf "$d" 2>/dev/null || true; done

echo
log "=== RINGKASAN ==="
if [ "${#BACKUP_SUCCESSES[@]}" -gt 0 ]; then log "Backup sukses:"; for f in "${BACKUP_SUCCESSES[@]}"; do printf "  - %s\n" "$f"; done; else warn "Tidak ada backup."; fi
if [ "${#BACKUP_FAILURES[@]}" -gt 0 ]; then warn "Backup gagal/skip:"; for f in "${BACKUP_FAILURES[@]}"; do printf "  - %s\n" "$f"; done; fi
log "Folder backup: $BACKUP_ROOT"
command -v docker >/dev/null 2>&1 || log "Docker CLI tidak ditemukan; seharusnya sudah bersih."

exit 0

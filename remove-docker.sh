#!/usr/bin/env bash
# remove-and-backup-docker.sh
# Versi: 1.1 — menambahkan progress/animasi
# Fungsi: stop -> backup volumes + compose/.env -> remove Docker -> ringkasan
# Semua pesan berbahasa Indonesia
set -euo pipefail

# -------------------------
# Konfigurasi default
# -------------------------
BACKUP_ROOT_DEFAULT="/root/BACKUP_DOCKER"
DRY_RUN=0
FORCE=0
PURGE=1
STOP_BEFORE_BACKUP=1

# -------------------------
# Helper: logging (Bahasa Indonesia)
# -------------------------
log()  { printf "✅ %s
" "$1"; }
info() { printf "ℹ️  %s
" "$1"; }
warn() { printf "⚠️  %s
" "$1" >&2; }
err()  { printf "❌ %s
" "$1" >&2; exit 1; }

# -------------------------
# Format timestamp (Bahasa Indonesia)
# -------------------------
DAYNAME=(Senin Selasa Rabu Kamis Jumat Sabtu Minggu)
MONTHNAME=(Januari Februari Maret April Mei Juni Juli Agustus September Oktober November Desember)
timestamp_indonesia() {
  local Y M D H MN IDXDAYNAME IDXMONTH dayname_idx
  Y=$(date +%Y); M=$(date +%m); D=$(date +%d)
  H=$(date +%H); MN=$(date +%M)
  IDXDAYNAME=$(date +%u)
  IDXMONTH=$((10#${M}-1))
  dayname_idx=$((IDXDAYNAME-1))
  printf "%s,%s%s%s_Jam%s.%s" "${DAYNAME[$dayname_idx]}" "$D" "${MONTHNAME[$IDXMONTH]}" "$Y" "$H" "$MN"
}

# -------------------------
# Progress UI helpers
# -------------------------
# print progress bar based on percent (0..100)
print_progress_bar() {
  local percent=$1
  local message=${2:-""}
  local width=40
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local bar=$(printf '%0.s#' $(seq 1 $filled))
  local spaces=$(printf '%0.s-' $(seq 1 $empty))
  printf '
[%s%s] %3d%% %s' "$bar" "$spaces" "$percent" "$message"
}

# spinner shown while a long-running command runs (PID passed)
spinner_start() {
  local pid=$1
  local msg="$2"
  local delay=0.1
  local spin='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    for i in $(seq 0 3); do
      printf '
%s %s' "${spin:i:1}" "$msg"
      sleep $delay
    done
  done
}

# wrapper to run a command and show spinner
run_with_spinner() {
  local msg="$1"
  shift
  ("$@") &
  local pid=$!
  spinner_start "$pid" "$msg"
  wait "$pid"
  return $?
}

# -------------------------
# Parse CLI args
# -------------------------
BACKUP_ROOT="$BACKUP_ROOT_DEFAULT"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-purge) PURGE=0; shift ;;
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    --backup-root=*) BACKUP_ROOT="${1#*=}"; shift ;;
    --no-stop-before-backup) STOP_BEFORE_BACKUP=0; shift ;;
    --stop-before-backup) STOP_BEFORE_BACKUP=1; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: remove-and-backup-docker.sh [options]

Options:
  --dry-run                Tampilkan apa yang akan dilakukan, tanpa eksekusi
  --force                  Jalankan tanpa konfirmasi interaktif
  --no-purge               Jangan purge paket docker dari apt
  --backup-root PATH       Lokasi tempat menyimpan backup (default /root/BACKUP_DOCKER)
  --no-stop-before-backup  Jangan hentikan container sebelum backup
  --stop-before-backup     Hentikan container sebelum backup (default)
  --help                   Tampilkan pesan ini
USAGE
      exit 0 ;;
    *) err "Argumen tidak dikenal: $1" ;;
  esac
done

# -------------------------
# Safety & prechecks
# -------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  err "Script harus dijalankan sebagai root (gunakan sudo)."
fi

if ! command -v docker >/dev/null 2>&1; then
  err "Docker CLI tidak ditemukan. Pastikan Docker terinstal sebelum menjalankan script ini."
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  echo "PERINGATAN: Script ini akan membackup data Docker dan MENGHAPUS resource Docker dari sistem."
  echo "Jika Anda yakin, jalankan kembali dengan --force atau gunakan --dry-run untuk simulasi."
  read -r -p "Lanjutkan? (y/N): " ans || true
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    err "Dibatalkan oleh pengguna."
  fi
fi

mkdir -p "$BACKUP_ROOT" || err "Gagal membuat folder backup: $BACKUP_ROOT"
TMPDIR="$(mktemp -d -p /tmp remove-docker-backup.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# -------------------------
# STOP phase (1 step)
# -------------------------
TOTAL_STEPS=1
# we will add number of volumes & bind-only groups later to TOTAL_STEPS
COMPLETED_STEPS=0

if [ "$STOP_BEFORE_BACKUP" -eq 1 ]; then
  info "Menghentikan semua container Docker untuk konsistensi..."
  if [ "$DRY_RUN" -eq 0 ]; then
    docker ps -q | xargs -r docker stop >/dev/null 2>&1 || warn "Beberapa container mungkin gagal dihentikan."
  else
    info "[DRY-RUN] docker ps -q | xargs -r docker stop"
  fi
  COMPLETED_STEPS=$((COMPLETED_STEPS+1))
  pct=$(( COMPLETED_STEPS * 100 / TOTAL_STEPS ))
  print_progress_bar $pct "Stop containers"
  printf '
'
fi

# -------------------------
# Build mapping volume -> containers
# -------------------------
info "Membangun peta volume -> container..."
declare -A VOL_TO_CONTAINERS
mapfile -t ALL_CONTAINERS < <(docker ps -aq 2>/dev/null || true)
for cid in "${ALL_CONTAINERS[@]:-}"; do
  mounts_json=$(docker inspect --format '{{json .Mounts}}' "$cid" 2>/dev/null || true)
  [ -z "$mounts_json" ] && continue
  while IFS= read -r line; do
    if [ -z "$line" ]; then continue; fi
    case "$line" in
      volume::*) volname="${line#volume::}"; volname="${volname%%::*}"; ;;
      *) continue ;;
    esac
    prev="${VOL_TO_CONTAINERS[$volname]:-}"
    if [ -z "$prev" ]; then VOL_TO_CONTAINERS["$volname"]="$cid"; else VOL_TO_CONTAINERS["$volname"]="${prev},${cid}"; fi
  done < <(echo "$mounts_json" | python3 - <<'PY' 2>/dev/null || true
import sys,json
s=sys.stdin.read()
if not s.strip(): sys.exit(0)
arr=json.loads(s)
for m in arr:
    t=m.get('Type')
    if t=='volume':
        name=m.get('Name') or ''
        src=m.get('Source') or ''
        if name:
            print('volume::'+name+'::'+src)
PY
)
done

mapfile -t ALL_VOLUMES < <(docker volume ls -q 2>/dev/null || true)
NUM_VOLUMES=${#ALL_VOLUMES[@]}

# Count bind-only compose files (containers with bind mounts that contain compose/.env)
mapfile -t ALL_CONTAINERS2 < <(docker ps -aq 2>/dev/null || true)
BIND_COMPOSE_COUNT=0
for cid in "${ALL_CONTAINERS2[@]:-}"; do
  mapfile -t binds < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}::{{.Destination}}{{"
"}}{{end}}{{end}}' "$cid" 2>/dev/null || true)
  for b in "${binds[@]:-}"; do
    src="${b%%::*}"
    for f in docker-compose.yml docker-compose.yaml .env; do
      if [ -f "${src}/${f}" ]; then BIND_COMPOSE_COUNT=$((BIND_COMPOSE_COUNT+1)); break 2; fi
    done
  done
done

# Recompute TOTAL_STEPS = stop(1 if applied) + volumes + bind-only groups + removal phases (3)
REMOVAL_PHASES=3
TOTAL_STEPS=$(( (STOP_BEFORE_BACKUP==1?1:0) + NUM_VOLUMES + BIND_COMPOSE_COUNT + REMOVAL_PHASES ))
COMPLETED_STEPS=0

info "Total langkah yang akan dijalankan (estimasi): $TOTAL_STEPS"

# -------------------------
# Backup volumes
# -------------------------
declare -a BACKUP_SUCCESSES=()
declare -a BACKUP_FAILURES=()

# Choose archiver
ZIP_CMD=0
if command -v zip >/dev/null 2>&1; then ZIP_CMD=1; fi

safe_name() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]/_/g'; }

backup_path_to_archive() {
  local path="$1"; local dest_dir="$2"; local base="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[DRY-RUN] archive: $path -> $dest_dir/${base}.$([ $ZIP_CMD -eq 1 ] && echo zip || echo tar.gz)"
    return 0
  fi
  if [ ! -d "$path" ]; then return 2; fi
  if [ "$ZIP_CMD" -eq 1 ]; then
    tmpf="$TMPDIR/${base}.zip"
    (cd "$path" && zip -r -q "$tmpf" .) || return 2
    mv "$tmpf" "${dest_dir}/${base}.zip" || return 2
    echo "${dest_dir}/${base}.zip"
    return 0
  else
    tmpf="$TMPDIR/${base}.tar.gz"
    tar -C "$path" -czf "$tmpf" . || return 2
    mv "$tmpf" "${dest_dir}/${base}.tar.gz" || return 2
    echo "${dest_dir}/${base}.tar.gz"
    return 0
  fi
}

info "Memulai backup volume Docker (jumlah: $NUM_VOLUMES)..."
for vol in "${ALL_VOLUMES[@]:-}"; do
  mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
  if [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ]; then
    warn "Volume $vol: mountpoint invalid/absent — dilewati."
    BACKUP_FAILURES+=("$vol:mountpoint-invalid")
    COMPLETED_STEPS=$((COMPLETED_STEPS+1))
    pct=$(( COMPLETED_STEPS * 100 / TOTAL_STEPS ))
    print_progress_bar $pct "Volume $vol skipped"
    printf '
'
    continue
  fi
  appname="$vol"
  if [ -n "${VOL_TO_CONTAINERS[$vol]:-}" ]; then
    first_cid="${VOL_TO_CONTAINERS[$vol]%%,*}"
    cname=$(docker inspect --format '{{.Name}}' "$first_cid" 2>/dev/null || true)
    cname="${cname#/}"
    [ -n "$cname" ] && appname="$cname"
  fi
  safe_app="$(safe_name "$appname")"
  dest_dir="$BACKUP_ROOT/$safe_app"
  [ "$DRY_RUN" -eq 0 ] && mkdir -p "$dest_dir"
  ts="$(timestamp_indonesia)"
  base="backup_appdata-docker_(${safe_app}_${vol})-${ts}"

  info "Backing up volume: $vol (app: $safe_app)"
  if out=$(backup_path_to_archive "$mountpoint" "$dest_dir" "$base" 2>&1); then
    BACKUP_SUCCESSES+=("$out")
    info "Berhasil: $out"
  else
    warn "Gagal backup volume $vol"
    BACKUP_FAILURES+=("$vol:backup-failed")
  fi

  # update progress
  COMPLETED_STEPS=$((COMPLETED_STEPS+1))
  pct=$(( COMPLETED_STEPS * 100 / TOTAL_STEPS ))
  print_progress_bar $pct "Processed volume $vol"
  printf '
'

  # copy compose/.env from bind mounts of containers using this volume
  if [ -n "${VOL_TO_CONTAINERS[$vol]:-}" ]; then
    IFS=',' read -ra CIDSARR <<< "${VOL_TO_CONTAINERS[$vol]}"
    extras_dir="$dest_dir/extra_files_${ts}"
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$extras_dir"
    for cid in "${CIDSARR[@]}"; do
      mapfile -t binds < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}::{{.Destination}}{{"
"}}{{end}}{{end}}' "$cid" 2>/dev/null || true)
      for b in "${binds[@]:-}"; do
        src="${b%%::*}"
        for f in docker-compose.yml docker-compose.yaml .env; do
          if [ -f "${src}/${f}" ]; then
            [ "$DRY_RUN" -eq 0 ] && cp -a "${src}/${f}" "$extras_dir/" 2>/dev/null || true
            info "Menyalin ${f} dari ${src} ke ${extras_dir}"
          fi
        done
      done
    done
    if [ "$DRY_RUN" -eq 0 ] && [ -d "$extras_dir" ] && [ "$(ls -A "$extras_dir" 2>/dev/null || true)" ]; then
      if [ "$ZIP_CMD" -eq 1 ]; then
        final="${dest_dir}/${base}.zip"
        (cd "$extras_dir" && zip -r -q "$final" .) || warn "Gagal menambahkan extra files ke $final"
      else
        tmp_pack="$TMPDIR/pack_${base}"
        rm -rf "$tmp_pack" || true
        mkdir -p "$tmp_pack"
        (cd "$mountpoint" && tar -cf - .) | tar -C "$tmp_pack" -xf - || true
        cp -a "$extras_dir/." "$tmp_pack/" 2>/dev/null || true
        tmpf="$TMPDIR/${base}.tar.gz"
        tar -C "$tmp_pack" -czf "$tmpf" . || warn "Gagal membuat tar dengan extras"
        mv "$tmpf" "${dest_dir}/${base}.tar.gz" || warn "Gagal memindahkan tar final"
        rm -rf "$tmp_pack" || true
      fi
      rm -rf "$extras_dir" || true
    fi
  fi

done

# -------------------------
# Backup bind-only compose/.env
# -------------------------
info "Mencari dan membackup file docker-compose/.env dari bind mounts (non-volume)..."
for cid in "${ALL_CONTAINERS2[@]:-}"; do
  mapfile -t binds < <(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}::{{.Destination}}{{"
"}}{{end}}{{end}}' "$cid" 2>/dev/null || true)
  found_any=0
  for b in "${binds[@]:-}"; do
    src="${b%%::*}"
    for f in docker-compose.yml docker-compose.yaml .env; do
      if [ -f "${src}/${f}" ]; then
        found_any=1
        break 2
      fi
    done
  done
  if [ "$found_any" -eq 1 ]; then
    # one step per found container group
    COMPLETED_STEPS=$((COMPLETED_STEPS+1))
    pct=$(( COMPLETED_STEPS * 100 / TOTAL_STEPS ))
    print_progress_bar $pct "Backing up bind-compose for container $cid"
    printf '
'
    # perform actual copy/archive similar to above
    cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null || true)
    cname="${cname#/}"
    safe_app="$(safe_name "${cname:-bindfiles}")"
    dest_dir="$BACKUP_ROOT/$safe_app"
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$dest_dir"
    ts="$(timestamp_indonesia)"
    base="backup_appdata-docker_(${safe_app}_bindfiles)-${ts}"
    extras_dir="$TMPDIR/extras_${safe_app}_${ts}"
    [ "$DRY_RUN" -eq 0 ] && mkdir -p "$extras_dir"
    for b in "${binds[@]:-}"; do
      src="${b%%::*}"
      for f in docker-compose.yml docker-compose.yaml .env; do
        if [ -f "${src}/${f}" ]; then
          [ "$DRY_RUN" -eq 0 ] && cp -a "${src}/${f}" "$extras_dir/" 2>/dev/null || true
          info "Menyalin ${f} dari ${src} ke ${extras_dir}"
        fi
      done
    done
    if [ "$DRY_RUN" -eq 0 ] && [ -d "$extras_dir" ] && [ "$(ls -A "$extras_dir" 2>/dev/null || true)" ]; then
      if [ "$ZIP_CMD" -eq 1 ]; then
        tmpzip="$TMPDIR/${base}.zip"
        (cd "$extras_dir" && zip -r -q "$tmpzip" .) || true
        mv "$tmpzip" "$dest_dir/${base}.zip" || true
        BACKUP_SUCCESSES+=("$dest_dir/${base}.zip")
      else
        tmptar="$TMPDIR/${base}.tar.gz"
        tar -C "$extras_dir" -czf "$tmptar" . || true
        mv "$tmptar" "$dest_dir/${base}.tar.gz" || true
        BACKUP_SUCCESSES+=("$dest_dir/${base}.tar.gz")
      fi
    fi
    rm -rf "$extras_dir" || true
  fi
done

# -------------------------
# Removal steps (3 phases) -> update progress per phase
# -------------------------
info "Memulai penghapusan resource Docker yang sudah dibackup..."
# Phase 1: stop & remove containers, images, networks
if [ "$DRY_RUN" -eq 0 ]; then
  docker ps -q | xargs -r docker stop >/dev/null 2>&1 || true
  docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker images -q | xargs -r docker rmi -f >/dev/null 2>&1 || true
  docker network ls --filter "type=custom" -q | xargs -r docker network rm >/dev/null 2>&1 || true
else
  info "[DRY-RUN] stop/remove containers/images/networks"
fi
COMPLETED_STEPS=$((COMPLETED_STEPS+1))
pct=$(( COMPLETED_STEPS * 100 / TOTAL_STEPS ))
print_progress_bar $pct "Removed containers/images/networks"
printf '
'

# Phase 2: remove volumes (skip failed)
if [ "$DRY_RUN" -eq 0 ]; then
  mapfile -t CURRENT_VOLS < <(docker volume ls -q 2>/dev/null || true)
  for v in "${CURRENT_VOLS[@]:-}"; do
    skip=0
    for ff in "${BACKUP_FAILURES[@]:-}"; do
      if [[ "$ff" == "$v:"* || "$ff" == "$v" ]]; then skip=1; break; fi
    done
    if [ "$skip" -eq 1 ]; then
      warn "Melewatkan penghapusan volume $v karena backup gagal/tidak valid."
      continue
    fi
    docker volume rm -f "$v" >/dev/null 2>&1 || true
  done
else
  info "[DRY-RUN] remove backed-up volumes"
fi
COMPLETED_STEPS=$((COMPLETED_STEPS+1))
pct=$(( COMPLETED_STEPS * 100 / TOTAL_STEPS ))
print_progress_bar $pct "Removed volumes"
printf '
'

# Phase 3: purge packages, remove dirs, cleanup
if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$PURGE" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose docker-engine docker.io docker-buildx-plugin || true
    apt-get autoremove -y || true
    apt-get update -y >/dev/null 2>&1 || true
  fi
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker*.list || true
  rm -f /etc/apt/keyrings/docker.gpg /etc/apt/trusted.gpg.d/docker*.gpg 2>/dev/null || true
  COMMON=(/var/lib/docker /var/lib/containerd /run/docker.sock /run/containerd /etc/docker /etc/containerd /var/run/docker)
  for d in "${COMMON[@]}"; do
    if [ -e "$d" ]; then
      d_abs="$(readlink -f "$d" 2>/dev/null || true)"
      br_abs="$(readlink -f "$BACKUP_ROOT" 2>/dev/null || true)"
      if [ -n "$br_abs" ] && [[ "$d_abs" == "$br_abs"* ]]; then
        info "Melewatkan penghapusan $d (terlindungi oleh BACKUP_ROOT)."
      else
        rm -rf "$d" 2>/dev/null || true
        info "Menghapus $d"
      fi
    fi
  done
  for b in /usr/bin/docker /usr/local/bin/docker /usr/bin/docker-compose /usr/local/bin/docker-compose /usr/bin/dockerd /usr/bin/containerd; do
    [ -e "$b" ] && rm -f "$b" || true
  done
  if getent group docker >/dev/null 2>&1; then groupdel docker 2>/dev/null || true; fi
else
  info "[DRY-RUN] purge packages & cleanup dirs"
fi
COMPLETED_STEPS=$((COMPLETED_STEPS+1))
pct=$(( COMPLETED_STEPS * 100 / TOTAL_STEPS ))
print_progress_bar $pct "Final cleanup"
printf '
'

# Final prune
if [ "$DRY_RUN" -eq 0 ]; then
docker system prune -af --volumes >/dev/null 2>&1 || true
fi

# -------------------------
# Final summary
# -------------------------
echo
log "=== RINGKASAN BACKUP & PENGHAPUSAN ==="
if [ "${#BACKUP_SUCCESSES[@]}" -gt 0 ]; then
  log "Backup berhasil:"
  for f in "${BACKUP_SUCCESSES[@]}"; do printf "  - %s
" "$f"; done
else
  warn "Tidak ada backup berhasil tercatat."
fi
if [ "${#BACKUP_FAILURES[@]}" -gt 0 ]; then
  warn "Backup gagal / dilewati (periksa pesan di atas):"
  for f in "${BACKUP_FAILURES[@]}"; do printf "  - %s
" "$f"; done
fi
log "Folder backup utama: $BACKUP_ROOT"
if [ -d "$BACKUP_ROOT" ]; then
  info "Contoh struktur folder backup (beberapa file):"
  find "$BACKUP_ROOT" -maxdepth 3 -type f -printf '  - %p
' 2>/dev/null | sed -n '1,40p' || true
fi

if [ "$DRY_RUN" -eq 1 ]; then
  info "DRY-RUN selesai. Tidak ada yang dihapus."
else
  if command -v docker >/dev/null 2>&1; then
    warn "Docker masih ditemukan di PATH: $(command -v docker) — periksa sisa manual."
  else
    log "Docker CLI tidak ditemukan di PATH. Sistem seharusnya bersih dari Docker." 
  fi
fi

log "Selesai. Periksa folder backup dan simpan arsip di lokasi lain jika diperlukan."
exit 0

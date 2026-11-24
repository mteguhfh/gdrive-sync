#!/usr/bin/env bash
# gdrive-sync — sync folder laptop <-> Google Drive pakai rclone + systemd user timer.
#
# Usage: gdrive-sync.sh <command> [options]
#   setup               Buat config, hubungkan akun Google Drive (OAuth via browser), bikin folder
#   sync [--dry-run] [--resync] [--force]
#                       Jalankan satu kali sync sekarang (--force: izinkan hapus massal)
#   install             Pasang systemd user timer (auto sync tiap INTERVAL)
#   uninstall           Copot systemd user timer
#   add-folder <path>   Tambah folder ke backup (otomatis MODE=backup)
#   remove-folder <path> Hapus folder dari daftar backup
#   folders             Lihat daftar folder backup
#   status              Lihat status timer + log terakhir
#   logs                Ikuti log (tail -f)
#   config              Tampilkan config yang aktif
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
APP="gdrive-sync"

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP"
CONF_FILE="${GDRIVE_SYNC_CONF:-$CONF_DIR/$APP.conf}"
STATE_DIR="${GDRIVE_SYNC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$APP}"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LOG_FILE="$STATE_DIR/$APP.log"
LOCK_FILE="$STATE_DIR/$APP.lock"
LOG_MAX_BYTES=$((10 * 1024 * 1024))
RCLONE_MIN_VERSION="1.66.0"

die()  { echo "[$APP] ERROR: $*" >&2; exit 1; }
info() { echo "[$APP] $*"; }

notify_fail() {
    # Best-effort desktop notification; never fail the script because of it.
    if [[ -z "${GDRIVE_SYNC_NO_NOTIFY:-}" ]] && command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "Google Drive sync gagal" "$1" >/dev/null 2>&1 || true
    fi
}

load_config() {
    # Defaults (bisa di-override di config file)
    LOCAL_DIR="$HOME/GDrive"
    SOURCE_DIRS=()
    REMOTE_NAME="gdrive"
    REMOTE_PATH=""
    MODE="bisync"
    INTERVAL="5min"
    FILTER_FILE="$SCRIPT_DIR/filters.txt"
    SOURCES_FILE="$(dirname "$CONF_FILE")/sources.txt"
    PARALLEL_JOBS=4
    EXTRA_FLAGS=()

    if [[ -f "$CONF_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi

    # Relative FILTER_FILE paths resolve against the script dir, not the caller's cwd.
    # Manual runs and the systemd timer must read the same file.
    if [[ -n "$FILTER_FILE" && "$FILTER_FILE" != /* ]]; then
        FILTER_FILE="$SCRIPT_DIR/$FILTER_FILE"
    fi
    if [[ -n "$SOURCES_FILE" && "$SOURCES_FILE" != /* ]]; then
        SOURCES_FILE="$(dirname "$CONF_FILE")/$SOURCES_FILE"
    fi

    # Folder backup dibaca dari file teks: satu path per baris, '#' untuk komentar.
    # File ini dikelola lewat 'add-folder' / 'remove-folder', bukan sintaks bash.
    if [[ -f "$SOURCES_FILE" ]]; then
        local line d
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            case "$line" in
                "~") line="$HOME" ;;
                "~/"*) line="$HOME/${line:2}" ;;
            esac
            [[ "$line" = /* ]] || line="$(dirname "$SOURCES_FILE")/$line"
            line="$(realpath -m -- "$line")" || die "path tidak valid di $SOURCES_FILE: $line"
            SOURCE_DIRS+=("$line")
        done <"$SOURCES_FILE"
    fi

    if ((${#SOURCE_DIRS[@]})); then
        local d b seen
        local -a clean_sources=()
        for d in "${SOURCE_DIRS[@]}"; do
            [[ "$d" != "$HOME" && "$d" != "/" ]] \
                || die "folder backup tidak boleh \$HOME atau / (terlalu berbahaya): $d"
            b="${d##*/}"
            for seen in "${clean_sources[@]}"; do
                if [[ "${seen##*/}" == "$b" ]]; then
                    die "dua folder punya nama sama ('$b'): $seen dan $d. Rename salah satu dulu."
                fi
            done
            clean_sources+=("$d")
        done
        SOURCE_DIRS=("${clean_sources[@]}")
    else
        LOCAL_DIR="${LOCAL_DIR%/}"
        [[ -n "$LOCAL_DIR" ]] || die "LOCAL_DIR kosong di $CONF_FILE"
        [[ "$LOCAL_DIR" = /* ]] || die "LOCAL_DIR harus absolute path (sekarang: '$LOCAL_DIR')"
        [[ "$LOCAL_DIR" != "$HOME" && "$LOCAL_DIR" != "/" ]] \
            || die "LOCAL_DIR tidak boleh \$HOME atau / (terlalu berbahaya). Pakai subfolder, misal \$HOME/GDrive"
    fi
    [[ -n "$REMOTE_NAME" ]] || die "REMOTE_NAME kosong di $CONF_FILE"
    case "$MODE" in bisync|push|backup) ;; *) die "MODE harus 'bisync', 'push', atau 'backup' (sekarang: '$MODE')";; esac
    [[ "$INTERVAL" =~ ^[0-9]+(s|sec|min|m|h)$ ]] || die "INTERVAL tidak valid: '$INTERVAL' (contoh: 5min, 30min, 1h)"
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] && (( PARALLEL_JOBS >= 1 && PARALLEL_JOBS <= 16 )) \
        || die "PARALLEL_JOBS harus angka 1-16 (sekarang: '$PARALLEL_JOBS')"

    # REMOTE_NAME boleh berupa nama remote rclone ("gdrive") atau path lokal absolut (dipakai untuk testing).
    if [[ "$REMOTE_NAME" = /* ]]; then
        REMOTE="${REMOTE_NAME%/}${REMOTE_PATH:+/${REMOTE_PATH#/}}"
    else
        REMOTE="${REMOTE_NAME%:}:${REMOTE_PATH#/}"
    fi
}

ensure_dirs() { mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true; }

rotate_log() {
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE") > LOG_MAX_BYTES )); then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
    fi
}

need_rclone() {
    command -v rclone >/dev/null 2>&1 \
        || die "rclone belum terinstall. Install: 'sudo apt install rclone' atau 'curl https://rclone.org/install.sh | sudo bash'"
    [[ -n "${GDRIVE_SYNC_SKIP_VERSION_CHECK:-}" ]] && return 0
    local v
    v="$(rclone version 2>/dev/null | sed -n '1s/^rclone v//p')"
    [[ -n "$v" ]] || die "tidak bisa membaca versi rclone. Cek: 'rclone version'"
    if [[ "$(printf '%s\n%s\n' "$RCLONE_MIN_VERSION" "$v" | sort -V | head -n1)" != "$RCLONE_MIN_VERSION" ]]; then
        die "rclone $v terlalu tua; script ini butuh rclone >= $RCLONE_MIN_VERSION. Upgrade: https://rclone.org/install/"
    fi
}

remote_exists() {
    [[ "$REMOTE_NAME" = /* ]] && return 0
    local remotes
    remotes="$(rclone listremotes 2>/dev/null)" || return 1
    grep -qxF -- "${REMOTE_NAME%:}:" <<<"$remotes"
}

# True if the directory contains no entries at all.
dir_is_empty() { [[ -z "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]]; }

# Marker that records a successful bisync baseline for this LOCAL/REMOTE pair + filter content.
# If the filter file changes, rclone bisync itself demands --resync, so we track that too.
state_key() { printf '%s|%s' "$LOCAL_DIR" "$REMOTE" | sha1sum | cut -c1-16; }
filters_sum() { if [[ -f "$FILTER_FILE" ]]; then md5sum "$FILTER_FILE" | cut -d' ' -f1; else echo none; fi; }
marker_file() { echo "$STATE_DIR/baseline-$(state_key)"; }

needs_resync() {
    local m; m="$(marker_file)"
    [[ ! -f "$m" ]] && return 0
    [[ "$(cat "$m")" != "$(filters_sum)" ]]
}

cmd_sync() {
    local dry_run=0 force_resync=0 force=0
    while (($#)); do
        case "$1" in
            --dry-run|-n) dry_run=1 ;;
            --resync) force_resync=1 ;;
            --force) force=1 ;;
            *) die "opsi tidak dikenal untuk sync: $1" ;;
        esac
        shift
    done

    need_rclone
    ensure_dirs
    remote_exists || die "remote rclone '$REMOTE_NAME' belum ada. Jalankan: $SCRIPT_PATH setup"

    local -a sources=()
    if [[ "$MODE" == "backup" && -f "$SOURCES_FILE" && ${#SOURCE_DIRS[@]} -eq 0 ]]; then
        die "belum ada folder di $SOURCES_FILE. Tambah: $SCRIPT_PATH add-folder ~/Documents"
    fi
    if ((${#SOURCE_DIRS[@]})); then
        sources=("${SOURCE_DIRS[@]}")
    else
        sources=("$LOCAL_DIR")
    fi
    if ((${#SOURCE_DIRS[@]})) && [[ "$MODE" != "backup" ]]; then
        die "daftar folder ($SOURCES_FILE) hanya untuk MODE=backup. Set MODE=\"backup\" di $CONF_FILE."
    fi
    local src
    for src in "${sources[@]}"; do
        [[ -d "$src" ]] || die "folder lokal $src tidak ada. Jalankan: $SCRIPT_PATH setup"
    done

    if [[ "$MODE" == "bisync" && "$REMOTE_NAME" != /* && -z "${REMOTE_PATH#/}" \
        && -z "${GDRIVE_SYNC_ALLOW_ROOT:-}" ]]; then
        die "MODE=bisync ke root My Drive diblokir (seluruh Drive ikut dua arah). Set REMOTE_PATH ke subfolder (mis. \"Laptop\") atau GDRIVE_SYNC_ALLOW_ROOT=1 kalau memang mau."
    fi

    if [[ "$MODE" == "push" ]]; then
        # Mirroring onto the Drive root would trash everything in My Drive that isn't on the laptop.
        if [[ "$REMOTE_NAME" != /* && -z "${REMOTE_PATH#/}" ]]; then
            die "MODE=push butuh REMOTE_PATH (subfolder). Push ke root Drive akan membuang semua file Drive lain ke Trash."
        fi
        # An empty local folder (emptied by accident, unmounted disk, ...) would wipe the Drive copy.
        if (( ! force && ! dry_run )) && dir_is_empty "$LOCAL_DIR"; then
            local remote_listing
            remote_listing="$(rclone lsf --max-depth 1 "$REMOTE" 2>/dev/null)" || remote_listing=""
            if [[ -n "$remote_listing" ]]; then
                notify_fail "folder lokal kosong, push ditahan supaya Drive tidak ikut terhapus"
                die "folder lokal $LOCAL_DIR kosong tapi $REMOTE berisi file; push ditahan supaya Drive tidak ikut terhapus. Kalau memang sengaja: $SCRIPT_PATH sync --force"
            fi
        fi
    fi

    # Single-instance guard: timer run + manual run must not overlap.
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        info "sync lain masih berjalan, skip."
        return 0
    fi

    # systemctl stop sends SIGTERM. Without a trap the script dies with 143 and systemd
    # records the unit as "failed", which looks like a real error to the user.
    trap 'pkill -TERM -P $$ 2>/dev/null || true; info "sync dihentikan (SIGTERM)."; exit 0' TERM INT

    rotate_log
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    local -a common=(--log-file "$LOG_FILE" --log-level INFO --stats-one-line --stats 0
                     --drive-skip-gdocs
                     --transfers 4 --checkers 8 --drive-chunk-size 32M --buffer-size 32M --fast-list)
    [[ -f "$FILTER_FILE" ]] || FILTER_FILE=""
    (( dry_run )) && common+=(--dry-run)

    if [[ "$MODE" == "backup" ]]; then
        # backup: laptop -> Drive (copy only). Nothing on Drive is ever deleted by this mode.
        # Each source folder is mirrored under its own basename so multiple folders can coexist.
        #
        # rclone creates Drive directories one at a time inside a single process (~1.2 dirs/s
        # on a real account), so one big copy can take tens of hours on a folder tree with
        # thousands of directories. Splitting the tree into one job per top-level folder and
        # running PARALLEL_JOBS of them at once scales almost linearly (measured ~4x at 4 jobs).
        local rc=0 dest
        local -a jobs=()
        local -a bcmd

        for src in "${sources[@]}"; do
            if ((${#sources[@]} == 1)); then
                dest="$REMOTE"
            else
                dest="$REMOTE/${src##*/}"
            fi
            info "mulai backup: $src -> $dest$( ((dry_run)) && echo ' [dry-run]')"
            echo "=== $(date -Is) backup src=$src dest=$dest dry_run=$dry_run ===" >>"$LOG_FILE"
            jobs+=("$src|$dest|top")
            while IFS= read -r -d '' child; do
                # rclone copy of a completely empty dir does nothing, so create it explicitly.
                if [[ -z "$(find "$child" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
                    jobs+=("$child|$dest/${child##*/}|empty")
                else
                    jobs+=("$child|$dest/${child##*/}|sub")
                fi
            done < <(find "$src" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
        done

        local job jsrc jdest jkind rest
        local -a pids=()
        for job in "${jobs[@]}"; do
            jsrc="${job%%|*}"; rest="${job#*|}"; jdest="${rest%%|*}"; jkind="${rest##*|}"
            if [[ "$jkind" == "empty" ]]; then
                bcmd=(rclone mkdir "$jdest")
                (( dry_run )) && bcmd+=(--dry-run)
            else
                bcmd=(rclone copy "$jsrc" "$jdest" "${common[@]}" --create-empty-src-dirs)
                # Top-level files only; each subdirectory gets its own job below.
                [[ "$jkind" == "top" ]] && bcmd+=(--max-depth 1 --exclude "*/**")
                [[ -n "$FILTER_FILE" ]] && bcmd+=(--filter-from "$FILTER_FILE")
                ((${#EXTRA_FLAGS[@]})) && bcmd+=("${EXTRA_FLAGS[@]}")
            fi
            "${bcmd[@]}" &
            pids+=("$!")
            while (($(jobs -rp | wc -l) >= PARALLEL_JOBS)); do
                wait -n || rc=1
            done
        done
        local pid
        for pid in "${pids[@]}"; do
            wait "$pid" || rc=1
        done

        if (( rc == 0 )); then
            echo "=== $(date -Is) done OK ===" >>"$LOG_FILE"
            info "selesai OK."
            return 0
        fi
        echo "=== $(date -Is) FAILED ===" >>"$LOG_FILE"
        notify_fail "backup gagal; cek log: $LOG_FILE"
        die "backup gagal. cek log: $LOG_FILE"
    fi

    local -a cmd
    local did_resync=0
    if [[ "$MODE" == "bisync" ]]; then
        cmd=(rclone bisync "$LOCAL_DIR" "$REMOTE" "${common[@]}"
             --workdir "$STATE_DIR/bisync"
             --create-empty-src-dirs
             --resilient --recover --max-lock 2m
             --conflict-resolve newer --conflict-loser num)
        [[ -n "$FILTER_FILE" ]] && cmd+=(--filters-file "$FILTER_FILE")
        (( force )) && cmd+=(--force)
        if (( force_resync )) || needs_resync; then
            # Initial/explicit baseline: union of both sides, newer version wins, nothing is deleted.
            cmd+=(--resync --resync-mode newer)
            did_resync=1
        fi
    elif [[ "$MODE" == "push" ]]; then
        # push: laptop -> Drive (mirror). Files removed on the laptop go to the Drive trash.
        cmd=(rclone sync "$LOCAL_DIR" "$REMOTE" "${common[@]}" --create-empty-src-dirs --drive-use-trash)
        [[ -n "$FILTER_FILE" ]] && cmd+=(--filter-from "$FILTER_FILE")
    else
        die "mode tidak dikenal: $MODE"
    fi
    ((${#EXTRA_FLAGS[@]})) && cmd+=("${EXTRA_FLAGS[@]}")

    info "mulai $MODE: $LOCAL_DIR <-> $REMOTE$( ((did_resync)) && echo ' (resync/baseline)')$( ((dry_run)) && echo ' [dry-run]')"
    echo "=== $(date -Is) $MODE start resync=$did_resync dry_run=$dry_run ===" >>"$LOG_FILE"
    local log_start; log_start=$(wc -l <"$LOG_FILE")

    local rc=0
    "${cmd[@]}" || rc=$?

    if (( rc == 0 )); then
        if [[ "$MODE" == "bisync" ]] && (( did_resync )) && (( ! dry_run )); then
            filters_sum >"$(marker_file)"
        fi
        info "selesai OK."
        echo "=== $(date -Is) done OK ===" >>"$LOG_FILE"
        return 0
    fi

    echo "=== $(date -Is) FAILED rc=$rc ===" >>"$LOG_FILE"
    local hint="cek log: $LOG_FILE"
    local run_log; run_log="$(tail -n "+$((log_start + 1))" "$LOG_FILE")"
    # bisync aborts "critically" on persistent errors and then refuses every later run until
    # --resync. Left alone, the timer would fail forever. Drop the baseline marker so the next
    # run re-baselines with --resync-mode newer (union of both sides, nothing deleted).
    if [[ "$MODE" == "bisync" ]] && (( ! dry_run )) \
        && grep -qiE "Must run --resync|cannot find prior Path1 or Path2 listings" <<<"$run_log"; then
        rm -f "$(marker_file)"
        hint="bisync abort; run berikutnya otomatis resync (file yang dihapus bisa muncul lagi). Cek log: $LOG_FILE"
    elif grep -qi "too many deletes" <<<"$run_log"; then
        # Safety abort (>50% deleted on one side). It repeats on every run until confirmed.
        hint="lebih dari 50% file terhapus di satu sisi, sync ditahan. Kalau memang sengaja: $SCRIPT_PATH sync --force"
    elif grep -qiE "Empty current Path[12] listing" <<<"$run_log"; then
        hint="salah satu sisi kosong total, sync ditahan supaya sisi lain tidak ikut terhapus. Cek $LOCAL_DIR dan $REMOTE. Log: $LOG_FILE"
    fi
    notify_fail "$hint"
    die "sync gagal (rc=$rc). $hint"
}

resolve_folder_path() {
    local p="$1"
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p:2}" ;;
    esac
    [[ "$p" = /* ]] || p="$PWD/$p"
    realpath -m -- "$p" 2>/dev/null || die "path tidak valid: $1"
}

cmd_add_folder() {
    load_config
    (($# == 1)) || die "pakai: $SCRIPT_PATH add-folder /path/ke/folder"
    [[ -f "$CONF_FILE" ]] || die "config belum ada. Jalankan dulu: $SCRIPT_PATH setup"
    local p; p="$(resolve_folder_path "$1")"
    [[ -d "$p" ]] || die "folder tidak ada: $p"
    [[ "$p" != "$HOME" && "$p" != "/" ]] || die "folder tidak boleh \$HOME atau /"

    mkdir -p "$(dirname "$SOURCES_FILE")"
    touch "$SOURCES_FILE"
    chmod 600 "$SOURCES_FILE" 2>/dev/null || true

    if grep -qxF -- "$p" "$SOURCES_FILE"; then
        info "sudah ada: $p"
        return 0
    fi

    local b="${p##*/}" existing
    while IFS= read -r existing; do
        existing="${existing%$'\r'}"
        [[ -z "$existing" || "$existing" == \#* ]] && continue
        if [[ "${existing##*/}" == "$b" ]]; then
            die "sudah ada folder bernama '$b': $existing. Rename salah satu folder dulu."
        fi
    done <"$SOURCES_FILE"

    printf '%s\n' "$p" >>"$SOURCES_FILE"

    if ! grep -qE '^[[:space:]]*MODE="?backup"?[[:space:]]*$' "$CONF_FILE"; then
        if grep -qE '^[[:space:]]*MODE=' "$CONF_FILE"; then
            sed -i 's|^[[:space:]]*MODE=.*|MODE="backup"|' "$CONF_FILE"
        else
            printf '\nMODE="backup"\n' >>"$CONF_FILE"
        fi
        info "MODE diubah ke backup di $CONF_FILE"
    fi

    info "folder ditambahkan: $p"
    info "tujuan di Drive : $REMOTE/${p##*/}"
    info "Cek dengan: '$SCRIPT_PATH sync --dry-run', lalu '$SCRIPT_PATH install'"
}

cmd_remove_folder() {
    load_config
    (($# == 1)) || die "pakai: $SCRIPT_PATH remove-folder /path/ke/folder"
    local p; p="$(resolve_folder_path "$1")"
    [[ -f "$SOURCES_FILE" ]] || die "belum ada daftar folder di $SOURCES_FILE"
    grep -qxF -- "$p" "$SOURCES_FILE" || die "folder tidak ada di daftar: $p"

    local tmp; tmp="$(mktemp "${SOURCES_FILE}.XXXXXX")"
    chmod 600 "$tmp" 2>/dev/null || true
    awk -v p="$p" '$0 != p' "$SOURCES_FILE" >"$tmp"
    mv -f "$tmp" "$SOURCES_FILE"
    info "folder dihapus dari daftar: $p"
    if [[ -z "$(grep -vE '^[[:space:]]*(#|$)' "$SOURCES_FILE" || true)" ]]; then
        info "daftar folder kosong. Backup akan berhenti sampai ada folder ditambahkan lagi."
    fi
}

cmd_folders() {
    load_config
    if ((${#SOURCE_DIRS[@]})); then
        printf '%s\n' "${SOURCE_DIRS[@]}"
    elif [[ -f "$SOURCES_FILE" ]]; then
        info "daftar folder kosong: $SOURCES_FILE"
    else
        echo "$LOCAL_DIR (folder tunggal, LOCAL_DIR)"
    fi
}

cmd_setup() {
    need_rclone
    if [[ ! -f "$CONF_FILE" ]]; then
        mkdir -p "$(dirname "$CONF_FILE")"
        cp "$SCRIPT_DIR/gdrive-sync.conf.example" "$CONF_FILE"
        chmod 600 "$CONF_FILE" 2>/dev/null || true
        info "config dibuat: $CONF_FILE (edit kalau mau ganti folder/remote/mode)"
    else
        info "config sudah ada: $CONF_FILE"
    fi
    load_config

    if remote_exists; then
        info "remote rclone '$REMOTE_NAME' sudah ada."
    else
        info "menghubungkan Google Drive -> remote '$REMOTE_NAME'. Browser akan terbuka untuk login Google..."
        rclone config create "${REMOTE_NAME%:}" drive scope=drive config_is_local=true
        remote_exists || die "gagal membuat remote '$REMOTE_NAME'"
    fi

    local -a sources=()
    if ((${#SOURCE_DIRS[@]})); then
        sources=("${SOURCE_DIRS[@]}")
    else
        sources=("$LOCAL_DIR")
    fi
    local src
    for src in "${sources[@]}"; do
        mkdir -p "$src"
    done
    if [[ -n "$REMOTE_PATH" ]]; then
        if [[ "$MODE" == "backup" ]] && ((${#sources[@]} > 1)); then
            for src in "${sources[@]}"; do
                rclone mkdir "$REMOTE/${src##*/}"
            done
        else
            rclone mkdir "$REMOTE"
        fi
    fi
    info "folder lokal :"
    for src in "${sources[@]}"; do
        info "  - $src"
    done
    info "remote       : $REMOTE"
    info "mode         : $MODE"
    info "Langkah berikut: '$SCRIPT_PATH sync --dry-run' untuk cek, lalu '$SCRIPT_PATH install' untuk auto-sync."
}

cmd_install() {
    load_config
    command -v systemctl >/dev/null 2>&1 || die "systemctl tidak ada; pakai cron: */5 * * * * $SCRIPT_PATH sync"
    need_rclone
    remote_exists || die "remote rclone '$REMOTE_NAME' belum ada. Jalankan dulu: $SCRIPT_PATH setup"
    local -a sources=()
    if ((${#SOURCE_DIRS[@]})); then
        [[ "$MODE" == "backup" ]] || die "daftar folder ($SOURCES_FILE) hanya untuk MODE=backup. Set MODE=\"backup\" di $CONF_FILE."
        sources=("${SOURCE_DIRS[@]}")
    else
        sources=("$LOCAL_DIR")
    fi
    local src
    for src in "${sources[@]}"; do
        [[ -d "$src" ]] || die "folder lokal $src tidak ada. Jalankan dulu: $SCRIPT_PATH setup"
    done
    local unit_path; unit_path="$(dirname "$(command -v rclone)"):/usr/local/bin:/usr/bin:/bin"
    mkdir -p "$SYSTEMD_DIR"
    cat >"$SYSTEMD_DIR/$APP.service" <<EOF
[Unit]
Description=Google Drive sync (${sources[*]} -> $REMOTE)
Documentation=file://$SCRIPT_DIR/README.md

[Service]
Type=oneshot
ExecStart="$SCRIPT_PATH" sync
Environment="GDRIVE_SYNC_CONF=$CONF_FILE"
Environment="PATH=$unit_path"
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=6h
EOF
    cat >"$SYSTEMD_DIR/$APP.timer" <<EOF
[Unit]
Description=Run Google Drive sync every $INTERVAL

[Timer]
OnBootSec=2min
OnUnitInactiveSec=$INTERVAL
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$APP.timer"
    info "timer terpasang. Auto sync tiap $INTERVAL. Cek: $SCRIPT_PATH status"
}

cmd_uninstall() {
    systemctl --user disable --now "$APP.timer" 2>/dev/null || true
    systemctl --user stop "$APP.service" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$APP.service" "$SYSTEMD_DIR/$APP.timer"
    systemctl --user daemon-reload 2>/dev/null || true
    info "timer dicopot. File di laptop & Drive tidak disentuh."
}

cmd_status() {
    load_config
    echo "config : $CONF_FILE"
    if ((${#SOURCE_DIRS[@]})); then
        echo "folders:"
        printf '  - %s\n' "${SOURCE_DIRS[@]}"
    else
        echo "local  : $LOCAL_DIR"
    fi
    echo "remote : $REMOTE  (mode=$MODE, interval=$INTERVAL)"
    echo
    local st=0
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active --quiet "$APP.timer" 2>/dev/null; then
            echo "timer  : aktif"
        else
            echo "timer  : tidak aktif"
            st=1
        fi
        systemctl --user list-timers "$APP.timer" --no-pager 2>/dev/null || true
    else
        echo "timer  : systemctl tidak tersedia"
        st=1
    fi
    echo
    if [[ -f "$LOG_FILE" ]]; then
        echo "--- log terakhir ($LOG_FILE) ---"
        tail -n 20 "$LOG_FILE"
    else
        echo "(belum ada log)"
    fi
    return $st
}

cmd_logs() { ensure_dirs; touch "$LOG_FILE"; tail -n 50 -f "$LOG_FILE"; }

cmd_config() {
    load_config
    printf 'CONF_FILE=%s\nLOCAL_DIR=%s\nSOURCES_FILE=%s\nREMOTE=%s\nMODE=%s\nINTERVAL=%s\nPARALLEL_JOBS=%s\nFILTER_FILE=%s\nSTATE_DIR=%s\n' \
        "$CONF_FILE" "$LOCAL_DIR" "$SOURCES_FILE" "$REMOTE" "$MODE" "$INTERVAL" "$PARALLEL_JOBS" "$FILTER_FILE" "$STATE_DIR"
    if ((${#SOURCE_DIRS[@]})); then
        printf 'SOURCE_DIR=%s\n' "${SOURCE_DIRS[@]}"
    fi
}

usage() { sed -n '2,/^set -Eeuo pipefail$/p' "$SCRIPT_PATH" | sed '$d' | sed 's/^# \{0,1\}//'; }

main() {
    local cmd="${1:-}"; (($#)) && shift
    case "$cmd" in
        setup)     cmd_setup "$@" ;;
        sync)      load_config; cmd_sync "$@" ;;
        add-folder) cmd_add_folder "$@" ;;
        remove-folder) cmd_remove_folder "$@" ;;
        folders)   cmd_folders ;;
        install)   cmd_install ;;
        uninstall) cmd_uninstall ;;
        status)    cmd_status ;;
        logs)      cmd_logs ;;
        config)    cmd_config ;;
        -h|--help|help|"") usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

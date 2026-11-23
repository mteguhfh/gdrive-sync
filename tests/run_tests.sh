#!/usr/bin/env bash
# Integration tests for gdrive-sync.sh using a local directory as the "remote"
# (rclone treats absolute paths as a local backend), so no Google account is needed.
# Run: ./tests/run_tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/gdrive-sync.sh"
PASS=0; FAIL=0
export GDRIVE_SYNC_NO_NOTIFY=1

TMP="$(mktemp -d)"
trap 'chmod -R u+w -- "$TMP" 2>/dev/null; rm -rf -- "$TMP"' EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# new_env <name> <mode>  -> sets L, R, export GDRIVE_SYNC_CONF / STATE_DIR
new_env() {
    local base="$TMP/$1"
    L="$base/local"; R="$base/remote"
    mkdir -p "$L" "$R" "$base/state"
    export GDRIVE_SYNC_CONF="$base/conf"
    export GDRIVE_SYNC_STATE_DIR="$base/state"
    cat >"$GDRIVE_SYNC_CONF" <<EOF
LOCAL_DIR="$L"
REMOTE_NAME="$R"
REMOTE_PATH=""
MODE="$2"
INTERVAL="5min"
FILTER_FILE="$base/filters.txt"
EOF
    cp "$ROOT/filters.txt" "$base/filters.txt"
}
last_start() { grep " start resync=" "$GDRIVE_SYNC_STATE_DIR/gdrive-sync.log" | tail -n 1; }
run() { "$SCRIPT" "$@" >"$TMP/out" 2>&1; }

# expect_fail <desc> <pattern> <script args...>: must exit non-zero AND print pattern
expect_fail() {
    local d="$1" p="$2"; shift 2
    if run "$@"; then bad "$d (unexpectedly succeeded)"
    elif grep -q -- "$p" "$TMP/out"; then ok "$d"
    else bad "$d (wrong message: $(head -c 200 "$TMP/out"))"; fi
}

echo "# bisync: initial baseline merges both sides"
new_env bisync bisync
echo local-a >"$L/a.txt"
echo remote-b >"$R/b.txt"
echo junk >"$L/x.tmp"
mkdir -p "$L/node_modules/pkg"; echo n >"$L/node_modules/pkg/i.js"
mkdir -p "$L/app/.next/server" "$L/app/build/out" "$L/app/dist/out" "$L/app/node_modules/pkg" "$L/app/vendor/pkg"
echo n >"$L/app/.next/server/x.js"; echo b >"$L/app/build/out/x.js"
echo d >"$L/app/dist/out/x.js"; echo n >"$L/app/node_modules/pkg/x.js"
echo v >"$L/app/vendor/pkg/x.php"
check "first sync exits 0" run sync
check "local file pushed"  test "$(cat "$R/a.txt" 2>/dev/null)" = local-a
check "remote file pulled" test "$(cat "$L/b.txt" 2>/dev/null)" = remote-b
check "*.tmp excluded"     test ! -e "$R/x.tmp"
check "node_modules excluded" test ! -e "$R/node_modules"
check "nested .next excluded" test ! -e "$R/app/.next"
check "nested build excluded" test ! -e "$R/app/build"
check "nested dist excluded" test ! -e "$R/app/dist"
check "nested node_modules excluded" test ! -e "$R/app/node_modules"
check "nested vendor excluded" test ! -e "$R/app/vendor"
check "baseline marker written" compgen -G "$GDRIVE_SYNC_STATE_DIR/baseline-*" >/dev/null
grep -q "resync=1" "$GDRIVE_SYNC_STATE_DIR/gdrive-sync.log" && ok "first run was resync" || bad "first run was resync"

echo "# bisync: incremental changes both directions"
sleep 1
echo local-a-v2 >"$L/a.txt"
rm "$R/b.txt"
echo remote-c >"$R/c.txt"
mkdir -p "$L/sub"; echo deep >"$L/sub/d.txt"
check "second sync exits 0" run sync
last_start | grep -q "resync=0" && ok "second run not resync" || bad "second run not resync"
check "local edit propagated"   test "$(cat "$R/a.txt")" = local-a-v2
check "remote delete propagated" test ! -e "$L/b.txt"
check "remote new file pulled"  test "$(cat "$L/c.txt" 2>/dev/null)" = remote-c
check "nested dir pushed"       test "$(cat "$R/sub/d.txt" 2>/dev/null)" = deep

echo "# bisync: conflict keeps both versions"
sleep 1
echo L-conf >"$L/a.txt"; sleep 1; echo R-conf-newer >"$R/a.txt"
check "conflict sync exits 0" run sync
check "newer (remote) version wins on a.txt" test "$(cat "$L/a.txt")" = R-conf-newer
check "loser kept as a renamed copy" bash -c "grep -rqs L-conf '$L' '$R'"

echo "# bisync: dry-run changes nothing"
echo dry >"$L/dry.txt"
check "dry-run exits 0" run sync --dry-run
check "dry-run did not copy" test ! -e "$R/dry.txt"
run sync; check "real run after dry-run copies" test -e "$R/dry.txt"

echo "# bisync: filter change triggers automatic resync"
echo "- *.log" >>"$(dirname "$GDRIVE_SYNC_CONF")/filters.txt"
check "sync after filter change exits 0" run sync
last_start | grep -q "resync=1" && ok "filter change -> resync" || bad "filter change -> resync"
check "following run is incremental again" run sync
last_start | grep -q "resync=0" && ok "back to incremental" || bad "back to incremental"

echo "# bisync: initial baseline with empty local folder"
new_env emptylocal bisync
echo r >"$R/only-remote.txt"
check "empty-local first sync exits 0" run sync || cat "$TMP/out"
check "remote file pulled into empty local" test -e "$L/only-remote.txt"

echo "# lock: concurrent run is skipped"
new_env lock bisync
echo a >"$L/a"
exec 8>"$GDRIVE_SYNC_STATE_DIR/gdrive-sync.lock"; flock -n 8
check "locked run exits 0" run sync
check "locked run reports skip" grep -q "skip" "$TMP/out"
check "locked run copied nothing" test ! -e "$R/a"
exec 8>&-
check "unlocked run works" run sync
check "unlocked run copied" test -e "$R/a"

echo "# push mode: one-way mirror"
new_env push push
echo 1 >"$L/keep.txt"; echo old >"$R/stale.txt"
check "push exits 0" run sync
check "push copied local file" test -e "$R/keep.txt"
check "push removed remote-only file (mirror)" test ! -e "$R/stale.txt"
echo r >"$R/new-on-remote.txt"; run sync
check "push never writes to local" test ! -e "$L/new-on-remote.txt"

echo "# push mode: empty local folder is blocked unless forced"
new_env pushempty push
echo keep >"$R/onremote.txt"
if run sync; then bad "empty local push -> non-zero exit"; else ok "empty local push -> non-zero exit"; fi
check "empty local push is reported" grep -q "ditahan" "$TMP/out"
check "blocked push kept remote file" test -f "$R/onremote.txt"
check "dry-run previews without deleting" run sync --dry-run
check "dry-run kept remote file" test -f "$R/onremote.txt"
check "--force allows the push" run sync --force
check "--force removed remote file (mirror)" test ! -e "$R/onremote.txt"

echo "# backup mode: copy only, never deletes on the remote"
new_env backup backup
echo local >"$L/local.txt"; echo remote-only >"$R/keep.txt"
check "backup exits 0" run sync
check "backup copied local file" test -e "$R/local.txt"
check "backup kept remote-only file" test -f "$R/keep.txt"
rm "$L/local.txt"; run sync
check "backup keeps file deleted locally" test -f "$R/local.txt"
check "backup never writes to local" test ! -e "$L/keep.txt"

echo "# backup mode: multiple folders from sources.txt"
new_env multi backup
mkdir -p "$TMP/multi/docs" "$TMP/multi/pics"
mkdir -p "$TMP/multi/docs/empty"
echo doc >"$TMP/multi/docs/a.txt"
echo pic >"$TMP/multi/pics/b.jpg"
printf '%s\n%s\n' "$TMP/multi/docs" "$TMP/multi/pics" >"$TMP/multi/sources.txt"
check "multi-folder backup exits 0" run sync
check "first folder copied" test "$(cat "$R/docs/a.txt" 2>/dev/null)" = doc
check "second folder copied" test "$(cat "$R/pics/b.jpg" 2>/dev/null)" = pic
check "empty dir copied" test -d "$R/docs/empty"
check "no duplicate copy at remote root" test ! -e "$R/a.txt"

echo "# add-folder / remove-folder commands"
new_env folders bisync
mkdir -p "$TMP/folders/Docs" "$TMP/folders/Pics" "$TMP/folders/other/Docs"
check "add-folder exits 0" run add-folder "$TMP/folders/Docs"
check "add-folder switches MODE to backup" grep -q '^MODE="backup"' "$GDRIVE_SYNC_CONF"
check "folder saved in sources.txt" grep -qxF "$TMP/folders/Docs" "$TMP/folders/sources.txt"
check "add-folder is idempotent" run add-folder "$TMP/folders/Docs"
check "folder not duplicated" test "$(grep -cxF "$TMP/folders/Docs" "$TMP/folders/sources.txt")" = 1
run folders
check "folders command lists the folder" grep -qxF "$TMP/folders/Docs" "$TMP/out"
if run add-folder "$TMP/folders/other/Docs"; then bad "duplicate basename rejected"; else ok "duplicate basename rejected"; fi
check "duplicate basename message" grep -q "nama" "$TMP/out"
check "remove-folder exits 0" run remove-folder "$TMP/folders/Docs"
check "folder removed from sources.txt" bash -c "! grep -qxF '$TMP/folders/Docs' '$TMP/folders/sources.txt'"
run folders
check "empty list is reported" grep -q "kosong" "$TMP/out"
expect_fail "empty sources.txt blocks backup" "belum ada folder" sync

echo "# rclone failure is reported (non-zero exit + log marker)"
new_env rofail bisync
echo a >"$L/a"; run sync
chmod a-w "$R"; echo b >"$L/b"
if run sync; then bad "rclone failure -> non-zero exit"; else ok "rclone failure -> non-zero exit"; fi
check "failure message printed" grep -q "sync gagal" "$TMP/out"
check "failure logged" grep -q "FAILED rc=" "$GDRIVE_SYNC_STATE_DIR/gdrive-sync.log"
chmod u+w "$R"
check "recovers after fixing permissions" run sync
last_start | grep -q "resync=1" && ok "recovery run auto-resynced" || bad "recovery run auto-resynced"
check "file copied after recovery" test -e "$R/b"
check "next run incremental again" run sync
last_start | grep -q "resync=0" && ok "incremental after recovery" || bad "incremental after recovery"

echo "# log rotation"
new_env rot bisync
echo a >"$L/a"
truncate -s 11000000 "$GDRIVE_SYNC_STATE_DIR/gdrive-sync.log"
check "sync rotates an oversized log" run sync
check "old log kept as .1" test -f "$GDRIVE_SYNC_STATE_DIR/gdrive-sync.log.1"
check "new log created" test -f "$GDRIVE_SYNC_STATE_DIR/gdrive-sync.log"

echo "# install: generates valid systemd units (systemctl stubbed)"
new_env inst bisync
mkdir -p "$TMP/bin" "$TMP/xdg"
printf '#!/bin/sh\necho "systemctl $*" >>"%s/systemctl.calls"\n' "$TMP" >"$TMP/bin/systemctl"; chmod +x "$TMP/bin/systemctl"
PATH="$TMP/bin:$PATH" XDG_CONFIG_HOME="$TMP/xdg" "$SCRIPT" install >"$TMP/out" 2>&1
U="$TMP/xdg/systemd/user"
check "service unit written" grep -qF "ExecStart=\"$SCRIPT\" sync" "$U/gdrive-sync.service"
check "service carries conf path" grep -qF "Environment=\"GDRIVE_SYNC_CONF=$GDRIVE_SYNC_CONF\"" "$U/gdrive-sync.service"
check "timer uses INTERVAL" grep -q "OnUnitInactiveSec=5min" "$U/gdrive-sync.timer"
check "timer enabled" grep -q "enable --now gdrive-sync.timer" "$TMP/systemctl.calls"
if command -v systemd-analyze >/dev/null; then
    check "systemd-analyze verify passes" systemd-analyze verify "$U/gdrive-sync.service" "$U/gdrive-sync.timer"
fi
PATH="$TMP/bin:$PATH" XDG_CONFIG_HOME="$TMP/xdg" "$SCRIPT" uninstall >"$TMP/out" 2>&1
check "uninstall removes units" test ! -e "$U/gdrive-sync.service" -a ! -e "$U/gdrive-sync.timer"

echo "# validation / error paths"
new_env val bisync
sed -i "s|^LOCAL_DIR=.*|LOCAL_DIR=\"\$HOME\"|" "$GDRIVE_SYNC_CONF"
expect_fail "LOCAL_DIR=\$HOME rejected" "tidak boleh" sync
sed -i "s|^LOCAL_DIR=.*|LOCAL_DIR=\"/\"|" "$GDRIVE_SYNC_CONF"
expect_fail "LOCAL_DIR=/ rejected" "LOCAL_DIR" sync
sed -i "s|^LOCAL_DIR=.*|LOCAL_DIR=\"relative/dir\"|" "$GDRIVE_SYNC_CONF"
expect_fail "relative LOCAL_DIR rejected" "absolute" sync
new_env val2 bisync
sed -i 's|^MODE=.*|MODE="mirror"|' "$GDRIVE_SYNC_CONF"
expect_fail "bad MODE rejected" "MODE harus" sync
new_env val3 bisync
sed -i 's|^INTERVAL=.*|INTERVAL="5 minutes"|' "$GDRIVE_SYNC_CONF"
expect_fail "bad INTERVAL rejected" "INTERVAL" sync
new_env val4 bisync
rmdir "$L"
expect_fail "missing local dir -> error" "tidak ada" sync
new_env val5 bisync
sed -i 's|^REMOTE_NAME=.*|REMOTE_NAME="no-such-remote-xyz"|' "$GDRIVE_SYNC_CONF"
expect_fail "unknown rclone remote -> error" "belum ada" sync
expect_fail "unknown sync option -> error" "tidak dikenal" sync --bogus
run config; check "config cmd prints remote" grep -q "REMOTE=no-such-remote-xyz:" "$TMP/out"
run help;  check "help prints usage" grep -q "setup" "$TMP/out"
check "help omits shell code" bash -c "! grep -q '^set -Eeuo pipefail$' '$TMP/out'"

echo "# config: relative FILTER_FILE is resolved against the script dir"
new_env relf bisync
sed -i 's|^FILTER_FILE=.*|FILTER_FILE="filters.txt"|' "$GDRIVE_SYNC_CONF"
run config
check "relative FILTER_FILE made absolute" grep -qF "FILTER_FILE=$ROOT/filters.txt" "$TMP/out"

echo "# safety: rclone too old is rejected"
new_env oldrclone bisync
mkdir -p "$TMP/oldbin"
printf '#!/bin/sh\necho "rclone v1.50.0"\nexit 0\n' >"$TMP/oldbin/rclone"; chmod +x "$TMP/oldbin/rclone"
if PATH="$TMP/oldbin:$PATH" "$SCRIPT" sync >"$TMP/out" 2>&1; then bad "old rclone -> non-zero exit"; else ok "old rclone -> non-zero exit"; fi
check "old rclone message" grep -q "terlalu tua" "$TMP/out"

echo "# safety: bisync to the Drive root is blocked"
new_env root bisync
sed -i 's|^REMOTE_NAME=.*|REMOTE_NAME="gdrive"|' "$GDRIVE_SYNC_CONF"
sed -i 's|^REMOTE_PATH=.*|REMOTE_PATH=""|' "$GDRIVE_SYNC_CONF"
mkdir -p "$TMP/rootbin"
cat >"$TMP/rootbin/rclone" <<'EOF'
#!/bin/sh
case "$1" in
    version) echo "rclone v1.76.0" ;;
    listremotes) echo "gdrive:" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP/rootbin/rclone"
if PATH="$TMP/rootbin:$PATH" "$SCRIPT" sync >"$TMP/out" 2>&1; then bad "root bisync -> non-zero exit"; else ok "root bisync -> non-zero exit"; fi
check "root bisync is reported" grep -q "root My Drive diblokir" "$TMP/out"
if GDRIVE_SYNC_ALLOW_ROOT=1 PATH="$TMP/rootbin:$PATH" "$SCRIPT" sync >"$TMP/out" 2>&1; then
    bad "root opt-in should fail on stub rclone"
elif grep -q "diblokir" "$TMP/out"; then
    bad "root opt-in bypasses the guard"
else
    ok "root opt-in bypasses the guard"
fi

echo "# status: timer state is reported"
new_env stat bisync
mkdir -p "$TMP/statbin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/statbin/systemctl"; chmod +x "$TMP/statbin/systemctl"
if PATH="$TMP/statbin:$PATH" "$SCRIPT" status >"$TMP/out" 2>&1; then bad "inactive timer -> non-zero exit"; else ok "inactive timer -> non-zero exit"; fi
check "inactive timer is reported" grep -q "timer  : tidak aktif" "$TMP/out"
printf '#!/bin/sh\nexit 0\n' >"$TMP/statbin/systemctl"
if PATH="$TMP/statbin:$PATH" "$SCRIPT" status >"$TMP/out" 2>&1; then ok "active timer -> zero exit"; else bad "active timer -> zero exit"; fi

echo
echo "passed=$PASS failed=$FAIL"
((FAIL == 0))

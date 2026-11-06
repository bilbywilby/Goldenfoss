#!/data/data/com.termux/files/usr/bin/bash
# tm-smoke.sh: fail-fast smoke test for Termux Master Ultra.
# Every step checks its own prerequisites, reports ok/FAIL/skip, and the run
# ends with one verdict line: ok | incomplete | error.
#
# Env overrides: TM_INSTALL TM_MASTER TM_DASH TM_PORT TM_TASK TM_TOKEN
#                MASTER_STORAGE  TM_REAL_INSTALL=1 (actually run the installer)
set -uo pipefail

INSTALL="${TM_INSTALL:-$HOME/install.sh}"
MASTER_STORAGE="${MASTER_STORAGE:-$HOME/.termux_master}"
MASTER="${TM_MASTER:-$MASTER_STORAGE/bin/master}"
DASH="${TM_DASH:-$MASTER_STORAGE/lib/ultra/dashboard.py}"
PORT="${TM_PORT:-8080}"   # must match the port dashboard.py really binds
TASK="${TM_TASK:-sample_task}"
TOKEN="${TM_TOKEN:-smoke-$(date +%s)-$$}"
export MASTER_STORAGE

PASS=0; FAIL=0; SKIP=0
ok()   { echo "ok    $*";   PASS=$((PASS+1)); }
bad()  { echo "FAIL  $*";   FAIL=$((FAIL+1)); }
skip() { echo "skip  $*";   SKIP=$((SKIP+1)); }
where() { find "$HOME" -maxdepth 6 -type f -name "$1" -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | head -n 5 | tr '\n' ' '; }
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

SPID=""; WORK="$(mktemp -d)"
cleanup() {
  [ -n "$SPID" ] && { pkill -P "$SPID" 2>/dev/null; kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; }
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# 1. --dry-run must not touch the package manager. pkg/apt/dpkg are shimmed and
#    pip is blocked via PIP_REQUIRE_VIRTUALENV. File writes and git are NOT intercepted.
t_dryrun() {
  [ -f "$INSTALL" ] || { skip "dry-run: $INSTALL not found (set TM_INSTALL; candidates: $(where install.sh))"; return; }
  local shim="$WORK/shim" log="$WORK/calls.log" out="$WORK/dry.out" c rc hits
  mkdir -p "$shim"; : > "$log"
  for c in pkg apt apt-get dpkg; do
    printf '#!/bin/sh\necho "$(basename "$0") $*" >> "%s"\nexit 0\n' "$log" > "$shim/$c"
    chmod +x "$shim/$c"
  done
  PATH="$shim:$PATH" PIP_REQUIRE_VIRTUALENV=1 bash "$INSTALL" --dry-run > "$out" 2>&1; rc=$?
  hits="$(grep -Eh '^(pkg|apt|apt-get|dpkg) (install|upgrade|update|remove|-i)' "$log" | head -n 3 | tr '\n' ';')"
  if [ -n "$hits" ]; then
    bad "dry-run NOT honored: installer ran: $hits"
  elif grep -q 'activated virtualenv' "$out"; then
    bad "dry-run NOT honored: installer tried a pip install"
  elif [ "$rc" -ne 0 ]; then
    bad "dry-run exited rc=$rc: $(tail -n 3 "$out" | tr '\n' ' ')"
  else
    ok "dry-run honored (no pkg/apt/dpkg/pip mutations)"
  fi
}

# 2. Real install, opt-in only (it upgrades Termux packages).
t_install() {
  [ "${TM_REAL_INSTALL:-0}" = 1 ] || { echo "note  install not run (opt-in: TM_REAL_INSTALL=1 runs $INSTALL for real)"; return; }
  [ -f "$INSTALL" ] || { bad "install: $INSTALL not found"; return; }
  if bash "$INSTALL" > "$WORK/install.out" 2>&1; then ok "install rc=0"
  else bad "install failed: $(tail -n 3 "$WORK/install.out" | tr '\n' ' ')"; fi
}

# 3. Did the installer actually deploy what the tests need?
LAYOUT_MASTER=0; LAYOUT_DASH=0
t_layout() {
  if [ -x "$MASTER" ]; then ok "master present: $MASTER"; LAYOUT_MASTER=1
  else bad "master missing or not executable: $MASTER (found elsewhere: $(where master))"; fi
  if [ -f "$DASH" ]; then ok "dashboard present: $DASH"; LAYOUT_DASH=1
  else bad "dashboard missing: $DASH (found elsewhere: $(where dashboard.py))"; fi
}

# 4. DAG run from the CLI.
t_task() {
  [ "$LAYOUT_MASTER" = 1 ] || { skip "task: no master binary"; return; }
  if timeout 60 "$MASTER" run "$TASK" > "$WORK/task.out" 2>&1; then ok "master run $TASK rc=0"
  else bad "master run $TASK rc=$?: $(tail -n 3 "$WORK/task.out" | tr '\n' ' ')"; fi
}

# 5. Auth-protected API: readiness wait, then assert real status codes.
code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$@"; }
t_api() {
  [ "$LAYOUT_DASH" = 1 ] || { skip "api: no dashboard.py"; return; }
  command -v curl >/dev/null || { bad "api: curl missing (pkg install curl)"; return; }
  if listening "$PORT"; then bad "api: port $PORT already in use (stale server?)"; return; fi
  local url="http://127.0.0.1:$PORT/api/dags" i up=0 c
  MASTER_AUTH_TOKEN="$TOKEN" python3 "$DASH" > "$WORK/dash.out" 2>&1 &
  SPID=$!
  for i in $(seq 1 20); do
    kill -0 "$SPID" 2>/dev/null || { bad "api: dashboard exited early: $(tail -n 3 "$WORK/dash.out" | tr '\n' ' ')"; SPID=""; return; }
    if listening "$PORT"; then up=1; break; fi
    sleep 1
  done
  [ "$up" = 1 ] || { bad "api: nothing listening on $PORT after 20s: $(tail -n 3 "$WORK/dash.out" | tr '\n' ' ')"; return; }
  c="$(code "$url")"
  [ "$c" = 401 ] && ok "api no token -> 401" || bad "api no token -> $c (want 401)"
  c="$(code -H "X-API-Token: wrong-$TOKEN" "$url")"
  { [ "$c" = 401 ] || [ "$c" = 403 ]; } && ok "api wrong token -> $c" || bad "api wrong token -> $c (want 401/403)"
  c="$(code -H "X-API-Token: $TOKEN" "$url")"
  [ "$c" = 200 ] && ok "api valid token -> 200" || bad "api valid token -> $c (want 200)"
}

t_dryrun
t_install
t_layout
t_task
t_api

echo "-- pass=$PASS fail=$FAIL skip=$SKIP"
if [ "$FAIL" -gt 0 ]; then echo error; exit 1
elif [ "$SKIP" -gt 0 ]; then echo incomplete; exit 2
else echo ok; fi

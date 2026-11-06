#!/data/data/com.termux/files/usr/bin/bash
# install-trp-v2.sh: hardened TRP suite (guest-side pidfile + PID-reuse guard,
# process-tree shutdown, TCP readiness probe, private state dir).
set -euo pipefail

# --- Prefix and paths ---
PFX="${PREFIX:-/data/data/com.termux/files/usr}"
DISTRO="${TRP_DISTRO:-debian}"
GU="${TRP_USER:-droid}"
RF="$PFX/var/lib/proot-distro/installed-rootfs/$DISTRO"

echo "==> Preparing target directories..."
mkdir -p "$PFX/bin"
mkdir -p "$RF/usr/local/bin" 2>/dev/null || true
mkdir -p "$RF/home/$GU/.trp" 2>/dev/null || true
chmod 700 "$RF/home/$GU/.trp" 2>/dev/null || true

# --- 1. trp-up ---
echo "==> Creating $PFX/bin/trp-up..."
cat > "$PFX/bin/trp-up" <<'TRP_UP_EOF'
#!/data/data/com.termux/files/usr/bin/bash
DISTRO="${TRP_DISTRO:-debian}"
GU="${TRP_USER:-droid}"
ST="$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO/home/$GU/.trp"
umask 077
mkdir -p "$ST"; chmod 700 "$ST"

Q=0
[ "${1:-}" = "--quiet" ] && Q=1
say() { [ "$Q" = 1 ] || echo "$@"; }

# pidfile = "<pid> <starttime>", written INSIDE the guest right before exec,
# so <pid> is the real npm process. starttime guards against PID reuse.
pt() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }
alive() {
  local p t
  [ -f "$ST/$1.pid" ] || return 1
  read -r p t < "$ST/$1.pid"
  [ -n "${p:-}" ] && [ -n "${t:-}" ] && [ "$(pt "$p")" = "$t" ]
}
booting() { local w; w="$(cat "$ST/$1.wrap" 2>/dev/null)"; [ -n "$w" ] && kill -0 "$w" 2>/dev/null; }
url_of() { sed 's/\x1b\[[0-9;]*m//g' "$ST/$1.log" 2>/dev/null | grep -oE "$2" | head -n1; }
probe() { local hp="${1#*://}"; hp="${hp%%/*}"; ( exec 3<>"/dev/tcp/${hp%:*}/${hp##*:}" ) 2>/dev/null; }

# $1 = name, $2 = command (both passed as positional args, no re-quoting games)
GUEST='. "$HOME/.nvm/nvm.sh" >/dev/null 2>&1; cd "$HOME/tech-ref-portal" || exit 1; export NO_COLOR=1; mkdir -p "$HOME/.trp"; echo "$$ $(sed "s/.*) //" /proc/$$/stat | cut -d" " -f20)" > "$HOME/.trp/$1.pid"; exec $2'

start() {
  local name="$1" cmd="$2" pat="$3" u="" i
  if alive "$name"; then
    say "$name up:$(url_of "$name" "$pat")"
    return 0
  fi
  rm -f "$ST/$name.pid" "$ST/$name.wrap"
  : > "$ST/$name.log"
  nohup proot-distro login "$DISTRO" --user "$GU" -- bash -c "$GUEST" trp-guest "$name" "$cmd" >> "$ST/$name.log" 2>&1 &
  echo $! > "$ST/$name.wrap"
  if [ "$Q" = 1 ]; then
    echo "trp: starting $name (log: ~/.trp/$name.log in $DISTRO)"
    return 0
  fi
  for i in $(seq 1 90); do
    u="$(url_of "$name" "$pat")"
    if [ -n "$u" ] && probe "$u"; then
      echo "$name up:$u"
      return 0
    fi
    alive "$name" || booting "$name" || break
    sleep 1
  done
  echo "error: $name failed to start"
  tail -n 15 "$ST/$name.log"
  return 1
}

command -v termux-wake-lock >/dev/null && termux-wake-lock

DEVCMD="npm run dev"
[ "${TRP_STRICT:-0}" = 1 ] && DEVCMD="npm run dev -- --strictPort"
start dev "$DEVCMD" 'http://localhost:[0-9]+' || exit 1

if [ "${TRP_STUDIO:-0}" = 1 ]; then
  start studio "npm --prefix studio run dev" 'http://[0-9.]+:3333'
fi
exit 0
TRP_UP_EOF

# --- 2. trp-down ---
echo "==> Creating $PFX/bin/trp-down..."
cat > "$PFX/bin/trp-down" <<'TRP_DOWN_EOF'
#!/data/data/com.termux/files/usr/bin/bash
DISTRO="${TRP_DISTRO:-debian}"
GU="${TRP_USER:-droid}"
ST="$PREFIX/var/lib/proot-distro/installed-rootfs/$DISTRO/home/$GU/.trp"

pt() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }
kids() { cat /proc/[0-9]*/stat 2>/dev/null | awk -v p="$1" '{ pid=$1; sub(/^.*\) /,""); if ($2==p) print pid }'; }
tree() { local c; echo "$1"; for c in $(kids "$1"); do tree "$c"; done; }

stop() {
  local name="$1" p="" t="" pids q i left=""
  [ -f "$ST/$name.pid" ] || return 0
  read -r p t < "$ST/$name.pid"
  if [ -n "$p" ] && [ -n "$t" ] && [ "$(pt "$p")" = "$t" ]; then
    pids="$(tree "$p")"
    kill $pids 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
      left=""
      for q in $pids; do kill -0 "$q" 2>/dev/null && left="$left $q"; done
      [ -z "$left" ] && break
      sleep 0.5
    done
    [ -n "$left" ] && kill -9 $left 2>/dev/null
    echo "$name stopped"
  else
    echo "$name: stale pidfile (process gone or PID reused); nothing signalled"
  fi
  rm -f "$ST/$name.pid" "$ST/$name.wrap"
}

for n in dev studio; do stop "$n"; done

if [ "${TRP_FORCE:-0}" = 1 ]; then
  pkill -f 'node.*tech-ref-portal' 2>/dev/null || true
  echo "TRP_FORCE: pkill sweep done"
fi

if [ "${TRP_UNLOCK:-0}" = 1 ]; then
  command -v termux-wake-unlock >/dev/null && termux-wake-unlock
  echo "portal stopped (wake lock released)"
else
  echo "portal stopped (wake lock kept; TRP_UNLOCK=1 trp-down releases it)"
fi
exit 0
TRP_DOWN_EOF

# --- 3. trp ---
echo "==> Creating $PFX/bin/trp..."
cat > "$PFX/bin/trp" <<'TRP_ENTER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
trp-up || exit 1
exec proot-distro login "${TRP_DISTRO:-debian}" --user "${TRP_USER:-droid}" -- bash -lc 'cd ~/tech-ref-portal 2>/dev/null; echo "droid ready. trp-w3m opens the portal in w3m"; exec bash -l'
TRP_ENTER_EOF

# --- 4. trp-w3m (inside the proot rootfs) ---
echo "==> Creating $RF/usr/local/bin/trp-w3m..."
cat > "$RF/usr/local/bin/trp-w3m" <<'TRP_W3M_EOF'
#!/usr/bin/env bash
command -v w3m >/dev/null 2>&1 || { echo "error: w3m missing (apt install w3m, as root)"; exit 1; }
url="${1:-}"
if [ -z "$url" ]; then
  url="$(sed 's/\x1b\[[0-9;]*m//g' "$HOME/.trp/dev.log" 2>/dev/null | grep -oE 'http://localhost:[0-9]+' | head -n1)"
  [ -n "$url" ] || { echo "error: no URL in ~/.trp/dev.log. In Termux run: trp-up"; exit 1; }
  hp="${url#*://}"; hp="${hp%%/*}"
  ( exec 3<>"/dev/tcp/${hp%:*}/${hp##*:}" ) 2>/dev/null || { echo "error: $url not responding. In Termux run: trp-up"; exit 1; }
  echo "note: w3m has no JavaScript, so React UI renders blank. Use Chrome at $url for full UI."
  sleep 2
fi
exec w3m "$url"
TRP_W3M_EOF

chmod +x "$PFX/bin/trp-up" "$PFX/bin/trp-down" "$PFX/bin/trp" "$RF/usr/local/bin/trp-w3m"

# --- Shell autostart hook ---
BLOCK='# >>> trp-autostart >>>
case $- in *i*) [ -z "${TRP_NO_AUTOSTART:-}" ] && command -v trp-up >/dev/null 2>&1 && trp-up --quiet;; esac
# <<< trp-autostart <<<'

did=0
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  grep -qF '>>> trp-autostart >>>' "$rc" || printf '\n%s\n' "$BLOCK" >> "$rc"
  did=1
done
[ "$did" = 1 ] || printf '%s\n' "$BLOCK" >> "$HOME/.bashrc"

# --- Self-verification ---
echo "==> Running self-verification..."
bad=0
chk() {
  f="$1"; min="$2"; shift 2
  [ -x "$f" ] || { echo "error: not executable: $f"; bad=1; return; }
  bash -n "$f" || { echo "error: syntax error in $f"; bad=1; }
  n=$(wc -l < "$f"); [ "$n" -ge "$min" ] || { echo "error: $f only $n lines (<$min)"; bad=1; }
  for p in "$@"; do grep -qF -- "$p" "$f" || { echo "error: $f missing pattern: $p"; bad=1; }; done
}

chk "$PFX/bin/trp-up" 40 'proot-distro login' 'npm run dev' 'TRP_STRICT' 'DEVCMD' '/dev/tcp' 'NO_COLOR'
chk "$PFX/bin/trp-down" 30 'TRP_UNLOCK' 'TRP_FORCE' 'tree' 'kill -9'
chk "$PFX/bin/trp" 3 'trp-up' 'exec proot-distro login'
chk "$RF/usr/local/bin/trp-w3m" 10 'w3m' '.trp/dev.log' '/dev/tcp'

if [ "$bad" = 0 ]; then
  echo "SUCCESS: TRP suite v2 installed and patched successfully!"
else
  echo "FAILURE: Installation verification found errors."
  exit 1
fi

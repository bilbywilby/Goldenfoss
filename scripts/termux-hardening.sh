#!/data/data/com.termux/files/usr/bin/bash
# termux-hardening.sh - Termux baseline. The app sandbox is the perimeter:
# no root, no firewall, no systemd. Idempotent: re-running rewrites one managed block.
set -euo pipefail

BEGIN="#BEGIN-TRP-HARDENING"
END="#END-TRP-HARDENING"
SSHD_CFG="$PREFIX/etc/ssh/sshd_config"
REPO="$HOME/tech-ref-portal"
ARCHIVE="$HOME/env-audit-archive"

echo "==> [1/4] Packages"
pkg update -y && pkg upgrade -y
pkg install -y openssh

echo "==> [2/4] sshd: key-only, port 8022"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if ! grep -qE '^(ssh-|ecdsa-)' "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  echo "ABORT: no public key in ~/.ssh/authorized_keys. Install one first:"
  echo "  cat mykey.pub >> ~/.ssh/authorized_keys"
  exit 1
fi
chmod 600 "$HOME/.ssh/authorized_keys"
cp -n "$SSHD_CFG" "$SSHD_CFG.bak" 2>/dev/null || true

# sshd is FIRST-MATCH-WINS and Termux ships PasswordAuthentication yes, so the
# managed block must sit at the TOP of the file. Appending would be ignored.
tmp="$(mktemp)"
{
  printf '%s\n' "$BEGIN" "Port 8022" "PasswordAuthentication no" \
    "KbdInteractiveAuthentication no" "PubkeyAuthentication yes" \
    "PermitRootLogin no" "X11Forwarding no" "AllowTcpForwarding no" \
    "MaxAuthTries 4" "$END"
  sed "/^$BEGIN\$/,/^$END\$/d" "$SSHD_CFG"
} > "$tmp"
cat "$tmp" > "$SSHD_CFG"
rm -f "$tmp"

ssh-keygen -A          # fresh installs lack host keys; sshd -t fails without them
sshd -t
effective="$(sshd -T)"
if ! grep -qi '^passwordauthentication no' <<<"$effective"; then
  echo "ABORT: PasswordAuthentication is still enabled. Restore: cp $SSHD_CFG.bak $SSHD_CFG"
  exit 1
fi
echo "sshd config valid, password auth off"

echo "==> [3/4] Storage reclamation"
pip cache purge >/dev/null 2>&1 || true
npm cache clean --force >/dev/null 2>&1 || true
rm -rf "$HOME/.cache/go-build" "$HOME/.npm" 2>/dev/null || true

# Archive audit dumps BEFORE any deletion: they may hold live tokens and may be
# evidence. Archived, not deleted. mtime alone is never a safe deletion rule.
if compgen -G "$REPO/env_audit_*.txt" >/dev/null; then
  mkdir -p "$ARCHIVE"
  chmod 700 "$ARCHIVE"
  mv "$REPO"/env_audit_*.txt "$ARCHIVE"/
  chmod 600 "$ARCHIVE"/env_audit_*.txt
  echo "archived env_audit dumps -> $ARCHIVE"
fi
# -delete + -prune conflict in GNU find, so node_modules is excluded with ! -path
if [ -d "$REPO" ]; then
  find "$REPO" -type f -name '*.log.*' -mtime +3 ! -path '*/node_modules/*' -delete 2>/dev/null || true
fi
find "$HOME/.termux_master" "$REPO" -type f -name '.aw-*' -mtime +1 ! -path '*/node_modules/*' -delete 2>/dev/null || true

echo "==> [4/4] Permissions sweep"
chmod 700 "$HOME/.termux_master" "$REPO" 2>/dev/null || true
find "$HOME/.termux_master" -type f -name '.auth_token' -exec chmod 600 {} + 2>/dev/null || true

echo "==> Done. Free space:"
df -h "$HOME" | tail -n 1
echo "    Start: sshd && termux-wake-lock"
echo "    Test from another device: ssh -p 8022 <user>@<pixel-ip>"

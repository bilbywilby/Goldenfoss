#!/usr/bin/env bash
# hardening-bootstrap.sh - baseline hardening for Debian/Ubuntu.
# Run as your normal admin user (it calls sudo itself), NOT via `sudo bash`.
# Aborts BEFORE touching sshd unless that user already has a public key installed.
# Env: ADMIN_SUBNET (default 192.168.1.0/24) = the only range allowed to reach SSH.
set -euo pipefail

ADMIN_SUBNET="${ADMIN_SUBNET:-192.168.1.0/24}"
DROPIN="/etc/ssh/sshd_config.d/00-hardening.conf"
TARGET_USER="${SUDO_USER:-$(id -un)}"

if [ "$TARGET_USER" = "root" ]; then
  echo "ABORT: run as your admin user, not root (the script calls sudo itself)."
  exit 1
fi
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "==> [1/5] LOCKOUT GUARD: public key for $TARGET_USER"
if ! grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9-]+) ' "$HOME_DIR/.ssh/authorized_keys" 2>/dev/null; then
  echo "ABORT: no public key in $HOME_DIR/.ssh/authorized_keys"
  echo "Install one first, or PasswordAuthentication no WILL lock you out."
  exit 1
fi

echo "==> [2/5] Packages"
sudo apt update && sudo apt upgrade -y
sudo apt install -y openssh-server htop smartmontools ufw fail2ban
sudo systemctl enable --now fail2ban

echo "==> [3/5] sshd drop-in: $DROPIN"
[ -f /etc/ssh/sshd_config.bak ] || sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
# sshd is FIRST-MATCH-WINS. 00- loads before 50-cloud-init.conf, which on cloud
# images sets PasswordAuthentication yes and would silently beat a 99- file.
sudo tee "$DROPIN" >/dev/null <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 4
LoginGraceTime 30
AllowUsers $TARGET_USER
EOF
if ! sudo sshd -t; then
  sudo rm -f "$DROPIN"
  echo "ABORT: sshd -t failed; drop-in removed, sshd untouched."
  exit 1
fi
# reload keeps live sessions; restart can drop them
sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd
effective="$(sudo sshd -T)"
if grep -qi '^passwordauthentication yes' <<<"$effective"; then
  echo "WARN: PasswordAuthentication is still yes - another file wins. Check: sudo sshd -T"
fi

echo "==> [4/5] UFW baseline (SSH only from $ADMIN_SUBNET)"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "$ADMIN_SUBNET" to any port 22 proto tcp comment "Admin SSH"
sudo ufw --force enable

echo "==> [5/5] Storage directories"
sudo mkdir -p /srv/appdata /srv/backups /srv/media /srv/shared
sudo chown -R "$(id -u "$TARGET_USER")":"$(id -g "$TARGET_USER")" /srv/media /srv/appdata
sudo chmod 700 /srv/appdata /srv/backups
sudo chmod 750 /srv/media /srv/shared

echo "==> Done. BEFORE closing this session: open a 2nd terminal and SSH in."
echo "    Rollback: sudo rm $DROPIN && sudo systemctl reload ssh"

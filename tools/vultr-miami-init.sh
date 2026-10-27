#!/usr/bin/env bash
# vultr-miami-free one-shot init: SSH key, ksoul user, hardening, swap, tz.
# Idempotent. Run as root. Logs go to stdout (caller tees to /root/init.log).
set -x
export DEBIAN_FRONTEND=noninteractive

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII1EP9kfGo7M+eBU9/OOVbfdBpVKfObADGTT95aw+X0V vultr-miami-free'

# --- timezone / hostname ---
timedatectl set-timezone Asia/Shanghai || true
hostnamectl set-hostname vultr-miami-free || true

# --- packages ---
apt-get update
apt-get -y upgrade
apt-get -y install curl sudo ca-certificates ufw unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades || true

# --- root key ---
mkdir -p /root/.ssh && chmod 700 /root/.ssh
grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$PUBKEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# --- user ksoul (key-only, passwordless sudo) ---
id ksoul >/dev/null 2>&1 || adduser --disabled-password --gecos '' ksoul
usermod -aG sudo ksoul
echo 'ksoul ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ksoul && chmod 440 /etc/sudoers.d/ksoul
mkdir -p /home/ksoul/.ssh
cp /root/.ssh/authorized_keys /home/ksoul/.ssh/authorized_keys
chown -R ksoul:ksoul /home/ksoul/.ssh && chmod 700 /home/ksoul/.ssh && chmod 600 /home/ksoul/.ssh/authorized_keys

# --- sshd hardening (key only) ---
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
sshd -t && systemctl restart ssh

# --- firewall: ssh only ---
ufw allow 22/tcp
ufw --force enable

# --- 1G swap ---
if ! swapon --show | grep -q .; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -qxF '/swapfile none swap sw 0 0' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf && sysctl -w vm.swappiness=10
fi

# --- BBR ---
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p /etc/sysctl.d/99-bbr.conf || true

# --- journald cap ---
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=100M\n' > /etc/systemd/journald.conf.d/99-cap.conf
systemctl restart systemd-journald || true

echo '=== VERIFY ==='
id ksoul
cat /root/.ssh/authorized_keys
sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|pubkeyauthentication'
swapon --show
timedatectl | head -3
ufw status | head -5
sysctl net.ipv4.tcp_congestion_control
echo '=== INIT DONE ==='

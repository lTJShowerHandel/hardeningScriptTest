#!/bin/bash
# ==============================================================================
# BLUE TEAM COMPETITION MASTER - UBUNTU 14.04 (LEGACY)
# Usage: curl -sSL [URL] | sudo bash -s [GRADER_IP] [YOUR_USER]
# ==============================================================================

GRADER_IP=$1
KEEP_USER=$2

if [ -z "$GRADER_IP" ] || [ -z "$KEEP_USER" ]; then
    echo "ERROR: Missing arguments."
    echo "Usage: curl -sSL [URL] | sudo bash -s [GRADER_IP] [YOUR_USER]"
    exit 1
fi

set -e

echo "--- [1/12] Repository Fix & Tool Install ---"
sed -i 's/archive.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
sed -i 's/security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
apt-get update && apt-get install -y ufw fail2ban knockd rkhunter aide

echo "--- [2/12] USER AUDIT & LOCKDOWN ---"
for user in $(awk -F: '$3 >= 1000 && $3 <= 60000 {print $1}' /etc/passwd); do
    if [ "$user" != "$KEEP_USER" ]; then
        echo "Locking user: $user"
        passwd -l "$user"
    fi
done

echo "--- [3/12] PURGING CRON JOBS (Persistence Kill) ---"
# Clear all user crontabs
for user in $(cut -f1 -d: /etc/passwd); do
    crontab -u "$user" -r 2>/dev/null || true
done
# Clear system-wide crontab (Leaving the header only)
echo "SHELL=/bin/sh" > /etc/crontab
echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin" >> /etc/crontab
# Empty the cron directories
rm -rf /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/* /etc/cron.monthly/* /etc/cron.weekly/*

echo "--- [4/12] Auto-Detecting Web Server ---"
if pgrep apache2 > /dev/null; then
    ufw allow 80/tcp && ufw allow 443/tcp
elif pgrep nginx > /dev/null; then
    ufw allow 80/tcp && ufw allow 443/tcp
fi

echo "--- [5/12] Firewall & Grader Whitelist ---"
ufw default deny incoming
ufw default allow outgoing
ufw allow from $GRADER_IP
ufw allow 21/tcp   # FTP
ufw --force enable

echo "--- [6/12] Port Knocking (SSH Stealth) ---"
#password auth allows for passwords, change this to no if you only want keys
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
service ssh restart

cat <<EOF > /etc/knockd.conf
[options]
    UseSyslog
[openSSH]
    sequence    = 7000,8000,9000
    seq_timeout = 5
    command     = /sbin/iptables -I INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
    tcpflags    = syn
[closeSSH]
    sequence    = 9000,8000,7000
    seq_timeout = 5
    command     = /sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT
    tcpflags    = syn
EOF
sed -i 's/START_KNOCKD=0/START_KNOCKD=1/' /etc/default/knockd
service knockd restart
ufw allow 7000:9000/tcp

echo "--- [7/12] Fail2Ban (Active Defense) ---"
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 $GRADER_IP
bantime  = 3600
maxretry = 5
[sshd]
enabled = true
[apache-auth]
enabled = true
[vsftpd]
enabled = true
EOF
service fail2ban restart

echo "--- [8/12] Persistence Watchdog ---"
# This is our "internal cron" that the Red Team won't easily see
cat <<EOF > /usr/local/bin/watchdog.sh
#!/bin/bash
while true; do
  for srv in apache2 vsftpd ssh mysql; do
    if ! service \$srv status > /dev/null 2>&1; then
      service \$srv start
    fi
  done
  sleep 30
done
EOF
chmod +x /usr/local/bin/watchdog.sh
/usr/local/bin/watchdog.sh &

echo "--- [9/12] System Hardening (sysctl) ---"
cat <<EOF >> /etc/sysctl.conf
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
sysctl -p

echo "--- [10/12] Security Baselines ---"
rkhunter --propupd > /dev/null 2>&1 || true
aideinit --force > /dev/null 2>&1 || true
[ -f /var/lib/aide/aide.db.new ] && cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db

echo "--- [11/12] Cleaning SUID Binaries ---"
chmod u-s /usr/bin/traceroute6 /usr/bin/at /usr/bin/newgrp || true

echo "=========================================="
echo "DEPLOYMENT COMPLETE"
echo "USER KEPT: $KEEP_USER | CRON: Purged"
echo "GRADER: $GRADER_IP | SSH: Knocking"
echo "=========================================="

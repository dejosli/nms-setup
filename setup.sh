#!/bin/bash

# Ensure the script runs with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use: sudo ./setup.sh"
    exit 1
fi

# Setup logging
LOG_FILE="/var/log/setup_script.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting system setup..."

# Configure APT sources list (Backup and Replace)
echo "Configuring APT sources list..."
cp /etc/apt/sources.list /etc/apt/sources.list.bak

cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF

# Disable extra repositories
if [ -d "/etc/apt/sources.list.d" ]; then
    echo "Disabling additional repositories..."
    find /etc/apt/sources.list.d/ -type f -name "*.list" -exec sed -i 's/^deb/#deb/g' {} +
fi

# Update and Upgrade with Retry (in case of network failures)
echo "Updating and upgrading system..."
for i in {1..3}; do
    apt update && apt upgrade -y && break || sleep 10
done

# Remove unnecessary packages and clean up
echo "Cleaning up the system..."
apt autoremove -y && apt autoclean -y

# Install Required Packages
REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "zram-tools" "ffmpeg")

for PKG in "${REQUIRED_PKGS[@]}"; do
    if ! command -v $PKG &> /dev/null; then
        echo "Installing missing package: $PKG..."
        apt install -y $PKG
    else
        echo "$PKG is already installed."
    fi
done

# Configure Persistent systemd Journal Logs
echo "Configuring systemd journaling..."
mkdir -p /var/log/journal
systemctl restart systemd-journald

JOURNAL_CONF="/etc/systemd/journald.conf"
sed -i '/^#Storage=/c\Storage=persistent' $JOURNAL_CONF
sed -i '/^#SystemMaxUse=/c\SystemMaxUse=200M' $JOURNAL_CONF
sed -i '/^#SystemMaxFileSize=/c\SystemMaxFileSize=50M' $JOURNAL_CONF
sed -i '/^#SystemMaxFiles=/c\SystemMaxFiles=5' $JOURNAL_CONF
sed -i '/^#MaxRetentionSec=/c\MaxRetentionSec=30day' $JOURNAL_CONF
sed -i '/^#Compress=/c\Compress=yes' $JOURNAL_CONF
sed -i '/^#SyncIntervalSec=/c\SyncIntervalSec=5m' $JOURNAL_CONF
sed -i '/^#RateLimitInterval=/c\RateLimitInterval=30s' $JOURNAL_CONF
sed -i '/^#RateLimitBurst=/c\RateLimitBurst=500' $JOURNAL_CONF
sed -i '/^#ForwardToSyslog=/c\ForwardToSyslog=no' $JOURNAL_CONF

systemctl restart systemd-journald
journalctl --disk-usage

# Configure Cron Job for Auto Log Cleanup
CRON_JOB="0 3 * * 7 root journalctl --vacuum-time=30d"
(crontab -l 2>/dev/null | grep -Fq "$CRON_JOB") || (echo "$CRON_JOB" | crontab -)

# Configure ZRAM Swap
echo "Configuring ZRAM swap..."
ZRAM_CONF="/etc/default/zramswap"
echo -e "ALGO=zstd\nPERCENT=50" > $ZRAM_CONF
systemctl restart zramswap
free -h

# Enable systemd-resolved
echo "Enabling systemd-resolved..."
systemctl enable systemd-resolved --now

# Configure DNS settings
RESOLVED_CONF="/etc/systemd/resolved.conf"
sed -i '/^#DNS=/c\DNS=1.1.1.1 8.8.8.8' $RESOLVED_CONF
sed -i '/^#FallbackDNS=/c\FallbackDNS=9.9.9.9' $RESOLVED_CONF
systemctl restart systemd-resolved
systemd-resolve --status | grep 'DNS Servers'

# Install NVM, Node.js, and Yarn (Only if not already installed)
echo "Installing NVM..."
if [ ! -d "/home/administrator/.nvm" ]; then
    sudo -u administrator bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
fi

sudo -u administrator bash -c 'source ~/.nvm/nvm.sh && nvm install 18'
sudo -u administrator bash -c 'source ~/.nvm/nvm.sh && node -v'
sudo -u administrator bash -c 'source ~/.nvm/nvm.sh && npm -v'
sudo -u administrator bash -c 'corepack enable yarn && yarn -v'

# Install Node Media Server
echo "Setting up Node Media Server..."
sudo -u administrator mkdir -p /home/administrator/Node-Media-Server
cd /home/administrator/Node-Media-Server
sudo -u administrator npm i node-media-server@2.7.0

# Download app.js
echo "Downloading app.js..."
wget -qO /home/administrator/Node-Media-Server/app.js https://raw.githubusercontent.com/dejosli/boilerplates/refs/heads/main/docker-compose/node-media-server/app.js

# Create systemd service for Node Media Server
echo "Creating systemd service for NMS..."
NMS_SERVICE="/etc/systemd/system/nms.service"
cat > $NMS_SERVICE <<EOF
[Unit]
Description=Node Media Server
After=network.target

[Service]
ExecStart=/bin/bash -c '. /home/administrator/.nvm/nvm.sh && exec node /home/administrator/Node-Media-Server/app.js'
Restart=always
RestartSec=5s
User=administrator
Group=administrator
WorkingDirectory=/home/administrator/Node-Media-Server
StandardOutput=append:/var/log/nms.log
StandardError=append:/var/log/nms.log

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable the service
systemctl daemon-reload
systemctl enable --now nms.service

# Configure logrotate for NMS logs
echo "Setting up log rotation for NMS logs..."
LOGROTATE_CONF="/etc/logrotate.d/nms"
cat > $LOGROTATE_CONF <<EOF
/var/log/nms.log {
    weekly
    rotate 2
    size 10M
    missingok
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

# Final Checks and System Optimization
echo "Final system checks..."
systemctl status nms.service --no-pager
systemctl status systemd-journald --no-pager
journalctl --verify
free -h

# Enable automatic security updates
echo "Enabling automatic security updates..."
apt install unattended-upgrades -y
dpkg-reconfigure -plow unattended-upgrades

# Optimize SSD performance (if applicable)
echo "Optimizing SSD performance..."
systemctl enable fstrim.timer

# Disable unnecessary services
echo "Disabling unused services..."
systemctl disable bluetooth.service --now 2>/dev/null

echo "Setup complete! Rebooting in 10 seconds..."
sleep 10
reboot
#!/bin/bash

# Ensure the script runs with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo ./setup.sh"
    exit 1
fi

echo "Starting system setup..."

# Configure APT sources list
echo "Configuring APT sources list..."

# Backup current sources.list
cp /etc/apt/sources.list /etc/apt/sources.list.bak

# Overwrite sources.list with only the required repositories
sudo tee /etc/apt/sources.list > /dev/null <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF

# Comment out any other repositories in sources.list.d
if [ -d "/etc/apt/sources.list.d" ]; then
    echo "Disabling additional repositories in /etc/apt/sources.list.d/..."
    sudo find /etc/apt/sources.list.d/ -type f -name "*.list" -exec sed -i 's/^deb/#deb/g' {} +
fi

# Update and Upgrade System
echo "Updating and upgrading system..."
apt update && apt upgrade -y

# Remove unnecessary packages and clean up
echo "Cleaning up the system..."
apt autoremove -y && apt autoclean -y

# Ensure required packages are installed
REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "zram-tools" "ffmpeg")

for PKG in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -l | grep -q "^ii  $PKG "; then
        echo "Installing missing package: $PKG..."
        apt install -y $PKG
    else
        echo "$PKG is already installed."
    fi
done

# Configure persistent systemd journal logs
echo "Configuring persistent systemd journal logs..."
mkdir -p /var/log/journal
systemctl restart systemd-journald

# Configure journald settings
echo "Updating journald.conf..."
JOURNAL_CONF="/etc/systemd/journald.conf"
sed -i 's/^#Storage=.*/Storage=persistent/' $JOURNAL_CONF
sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=200M/' $JOURNAL_CONF
sed -i 's/^#SystemMaxFileSize=.*/SystemMaxFileSize=50M/' $JOURNAL_CONF
sed -i 's/^#SystemMaxFiles=.*/SystemMaxFiles=5/' $JOURNAL_CONF
sed -i 's/^#MaxRetentionSec=.*/MaxRetentionSec=30day/' $JOURNAL_CONF
sed -i 's/^#Compress=.*/Compress=yes/' $JOURNAL_CONF
sed -i 's/^#SyncIntervalSec=.*/SyncIntervalSec=5m/' $JOURNAL_CONF
sed -i 's/^#RateLimitInterval=.*/RateLimitInterval=30s/' $JOURNAL_CONF
sed -i 's/^#RateLimitBurst=.*/RateLimitBurst=500/' $JOURNAL_CONF
sed -i 's/^#ForwardToSyslog=.*/ForwardToSyslog=no/' $JOURNAL_CONF

# Restart journald
systemctl restart systemd-journald

# Check current journal disk usage
journalctl --disk-usage

# Configure cron job for auto log cleanup
echo "Setting up weekly log cleanup in crontab..."
CRON_JOB="0 3 * * 7 root journalctl --vacuum-time=30d"
(crontab -l 2>/dev/null | grep -Fq "$CRON_JOB") || (echo "$CRON_JOB" | crontab -)

# Configure ZRAM Swap
echo "Configuring ZRAM swap..."
ZRAM_CONF="/etc/default/zramswap"
echo "ALGO=zstd" > $ZRAM_CONF
echo "PERCENT=50" >> $ZRAM_CONF
systemctl restart zramswap
free -h

# Enable systemd-resolved
echo "Enabling systemd-resolved..."
systemctl enable systemd-resolved --now

# Configure DNS settings
echo "Configuring DNS settings..."
RESOLVED_CONF="/etc/systemd/resolved.conf"
sed -i 's/^#DNS=.*/DNS=1.1.1.1 8.8.8.8/' $RESOLVED_CONF
sed -i 's/^#FallbackDNS=.*/FallbackDNS=9.9.9.9/' $RESOLVED_CONF
systemctl restart systemd-resolved
systemd-resolve --status | grep 'DNS Servers'

# Install and configure Node.js with NVM
echo "Installing NVM..."
sudo -u administrator bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
sudo -u administrator bash -c 'source ~/.nvm/nvm.sh && nvm install 18'
sudo -u administrator bash -c 'source ~/.nvm/nvm.sh && node -v'
sudo -u administrator bash -c 'source ~/.nvm/nvm.sh && npm -v'
sudo -u administrator bash -c 'corepack enable yarn && yarn -v'

# Install Node Media Server
echo "Setting up Node Media Server..."
sudo -u administrator mkdir -p /home/administrator/Node-Media-Server
cd /home/administrator/Node-Media-Server
sudo -u administrator npm i node-media-server@2.7.0

# Download app.js from provided link
echo "Downloading app.js..."
wget https://raw.githubusercontent.com/dejosli/boilerplates/refs/heads/main/docker-compose/node-media-server/app.js -O /home/administrator/Node-Media-Server/app.js

# Create systemd service for Node Media Server
echo "Creating systemd service for NMS..."
NMS_SERVICE="/etc/systemd/system/nms.service"
sudo tee $NMS_SERVICE > /dev/null <<EOF
[Unit]
Description=Node Media Server
After=network.target

[Service]
ExecStart=/bin/bash -c 'source /home/administrator/.nvm/nvm.sh && node /home/administrator/Node-Media-Server/app.js'
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
sudo tee $LOGROTATE_CONF > /dev/null <<EOF
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

echo "Setup complete!"
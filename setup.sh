#!/bin/bash

# Configuration file (optional)
CONFIG_FILE="/etc/setup_script.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Default configurations (can be overridden in config file)
DRY_RUN=${DRY_RUN:-0}
MIN_DISK_SPACE_MB=${MIN_DISK_SPACE_MB:-1000}
NODE_VERSION=${NODE_VERSION:-18}
SERVICE_USER=${SERVICE_USER:-administrator}
CLEANUP_PREVIOUS=${CLEANUP_PREVIOUS:-0}

# Check for --force flag
FORCE_CLEANUP=0
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE_CLEANUP=1
        break
    fi
done

# Ensure the script runs with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use: sudo ./setup.sh"
    exit 1
fi

# Setup logging
LOG_FILE="/var/log/setup_script.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting system setup at $(date)"

# Function to run commands with dry-run support
run_command() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Command: $@"
    else
        echo "Executing: $@"
        "$@"
        if [[ $? -ne 0 ]]; then
            echo "Error: Command failed: $@"
            exit 1
        fi
    fi
}

# Function to check if a user exists
user_exists() {
    id "$1" &>/dev/null
    return $?
}

# Function to detect if the system uses an SSD
is_ssd() {
    if [[ -e /sys/block/sda/queue/rotational ]]; then
        [[ $(cat /sys/block/sda/queue/rotational) -eq 0 ]]
    else
        return 1
    fi
}

# Function to check disk space
check_disk_space() {
    local required_mb=$1
    local available_mb=$(df -BM / | tail -1 | awk '{print $4}' | sed 's/M//')
    if [[ $available_mb -lt $required_mb ]]; then
        echo "Error: Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB"
        exit 1
    fi
    echo "Disk space check passed: ${available_mb}MB available"
}

# Function to validate username
validate_username() {
    local username=$1
    if [[ -z "$username" || ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Error: Invalid username '$username'. Must start with a letter or underscore, followed by letters, numbers, underscores, or hyphens."
        exit 1
    fi
    if [[ "$username" == "root" ]]; then
        echo "Error: SERVICE_USER cannot be 'root'. Node.js and service components must run as a non-root user."
        exit 1
    fi
    echo "Username '$username' is valid"
}

# Function to cleanup previous user data with confirmation and root protection
cleanup_previous_user() {
    local old_user=$1
    if [[ "$old_user" == "root" ]]; then
        echo "Error: Attempted to clean up root user. This is not allowed."
        exit 1
    fi
    if user_exists "$old_user" && [[ "$old_user" != "$SERVICE_USER" ]]; then
        echo "WARNING: Previous user '$old_user' detected. Cleanup will remove:"
        echo "- User account and home directory (/home/$old_user)"
        echo "- Node Media Server files and service"
        echo "- Log rotation configuration"
        if [[ $FORCE_CLEANUP -eq 1 ]]; then
            echo "Force cleanup enabled (--force flag detected)"
            proceed="y"
        else
            read -p "Are you sure you want to proceed with cleanup? (y/N): " proceed
        fi
        if [[ "$proceed" =~ ^[Yy]$ ]]; then
            echo "Cleaning up previous user data for '$old_user'..."
            run_command systemctl disable nms.service 2>/dev/null
            run_command rm -f /etc/systemd/system/nms.service
            run_command rm -f /etc/logrotate.d/nms
            run_command rm -rf "/home/$old_user/Node-Media-Server"
            run_command rm -rf "/home/$old_user/.nvm"
            run_command userdel -r "$old_user" 2>/dev/null
            echo "Cleanup completed for '$old_user'"
        else
            echo "Cleanup aborted. Proceeding with setup using new user '$SERVICE_USER'."
        fi
    fi
}

# Function to verify log rotation
verify_logrotate() {
    echo "Verifying log rotation configuration..."
    if [[ $DRY_RUN -eq 0 ]]; then
        run_command logrotate -d /etc/logrotate.d/nms 2>&1 | grep -v "log does not exist"
        if [[ $? -eq 0 ]]; then
            echo "Log rotation configuration verified successfully"
        else
            echo "Warning: Log rotation configuration may have issues"
        fi
    fi
}

# Validate SERVICE_USER
validate_username "$SERVICE_USER"

# Check for previous user cleanup with enhanced detection
if [[ $CLEANUP_PREVIOUS -eq 1 ]]; then
    OLD_USER=""
    if [[ -f /etc/systemd/system/nms.service ]]; then
        OLD_USER=$(grep "^User=" /etc/systemd/system/nms.service | cut -d= -f2)
    elif [[ -d "/home/$SERVICE_USER/Node-Media-Server" ]]; then
        OLD_USER=$(stat -c '%U' "/home/$SERVICE_USER/Node-Media-Server" 2>/dev/null)
    else
        # Enhanced detection: Check all home directories for Node-Media-Server
        for dir in /home/*; do
            if [[ -d "$dir/Node-Media-Server" ]]; then
                OLD_USER=$(basename "$dir")
                break
            fi
        done
    fi
    if [[ -n "$OLD_USER" ]]; then
        cleanup_previous_user "$OLD_USER"
    else
        echo "No previous user data detected for cleanup"
    fi
fi

# Check initial disk space
check_disk_space "$MIN_DISK_SPACE_MB"

# Configure APT sources list
echo "Configuring APT sources list..."
if [[ -f /etc/apt/sources.list ]]; then
    run_command cp /etc/apt/sources.list /etc/apt/sources.list.bak
    if [[ ! -f /etc/apt/sources.list.bak && $DRY_RUN -eq 0 ]]; then
        echo "Error: Backup of sources.list failed"
        exit 1
    fi
fi

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

# Update and Upgrade with Retry
echo "Updating and upgrading system..."
for i in {1..3}; do
    run_command apt update && run_command apt upgrade -y && break || sleep 10
done

# Clean up
echo "Cleaning up the system..."
run_command apt autoremove -y
run_command apt autoclean -y

# Install Required Packages with version checking
REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "zram-tools" "ffmpeg")
for PKG in "${REQUIRED_PKGS[@]}"; do
    if ! command -v $PKG &> /dev/null; then
        echo "Installing missing package: $PKG..."
        run_command apt install -y $PKG
    else
        VERSION=$(dpkg -l | grep "^ii\s*$PKG" | awk '{print $3}')
        echo "$PKG is already installed (version: $VERSION)"
    fi
done

# Configure Persistent systemd Journal Logs
echo "Configuring systemd journaling..."
run_command mkdir -p /var/log/journal
run_command systemctl restart systemd-journald

JOURNAL_CONF="/etc/systemd/journald.conf"
[ ! -f "$JOURNAL_CONF" ] && echo "Error: journald.conf not found" && exit 1

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

run_command systemctl restart systemd-journald
run_command journalctl --disk-usage

# Configure Cron Job for Auto Log Cleanup
CRON_JOB="0 3 * * 7 root journalctl --vacuum-time=30d"
if ! crontab -l 2>/dev/null | grep -Fq "$CRON_JOB"; then
    echo "Adding cron job for log cleanup..."
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
fi

# Configure ZRAM Swap
echo "Configuring ZRAM swap..."
ZRAM_CONF="/etc/default/zramswap"
echo -e "ALGO=zstd\nPERCENT=50" > $ZRAM_CONF
run_command systemctl restart zramswap
run_command free -h

# Enable systemd-resolved
echo "Enabling systemd-resolved..."
run_command systemctl enable systemd-resolved --now

# Configure DNS settings
RESOLVED_CONF="/etc/systemd/resolved.conf"
sed -i '/^#DNS=/c\DNS=1.1.1.1 8.8.8.8' $RESOLVED_CONF
sed -i '/^#FallbackDNS=/c\FallbackDNS=9.9.9.9' $RESOLVED_CONF
run_command systemctl restart systemd-resolved
run_command systemd-resolve --status | grep 'DNS Servers'

# Create service user if it doesn't exist
if ! user_exists "$SERVICE_USER"; then
    echo "Creating service user: $SERVICE_USER..."
    run_command useradd -m -s /bin/bash "$SERVICE_USER"
    echo "Please set a password for $SERVICE_USER:"
    run_command passwd "$SERVICE_USER"
fi

# Install NVM, Node.js, and Yarn for SERVICE_USER (never root)
echo "Installing NVM for $SERVICE_USER..."
if [ ! -d "/home/$SERVICE_USER/.nvm" ]; then
    check_disk_space 500
    sudo -u "$SERVICE_USER" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
fi

sudo -u "$SERVICE_USER" bash -c "source ~/.nvm/nvm.sh && nvm install $NODE_VERSION"
sudo -u "$SERVICE_USER" bash -c 'source ~/.nvm/nvm.sh && corepack enable yarn'
NODE_VER=$(sudo -u "$SERVICE_USER" bash -c "source ~/.nvm/nvm.sh && node -v")
echo "Installed Node.js version: $NODE_VER"

# Install Node Media Server
echo "Setting up Node Media Server for $SERVICE_USER..."
check_disk_space "$MIN_DISK_SPACE_MB"
sudo -u "$SERVICE_USER" mkdir -p "/home/$SERVICE_USER/Node-Media-Server"
cd "/home/$SERVICE_USER/Node-Media-Server"
sudo -u "$SERVICE_USER" npm i node-media-server@2.7.0

# Download app.js
echo "Downloading app.js..."
run_command wget -qO "/home/$SERVICE_USER/Node-Media-Server/app.js" https://raw.githubusercontent.com/dejosli/boilerplates/refs/heads/main/docker-compose/node-media-server/app.js

# Create systemd service for Node Media Server
echo "Creating systemd service for NMS..."
NMS_SERVICE="/etc/systemd/system/nms.service"
cat > $NMS_SERVICE <<EOF
[Unit]
Description=Node Media Server
After=network.target

[Service]
ExecStart=/bin/bash -c '. /home/$SERVICE_USER/.nvm/nvm.sh && exec node /home/$SERVICE_USER/Node-Media-Server/app.js'
Restart=always
RestartSec=5s
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=/home/$SERVICE_USER/Node-Media-Server
StandardOutput=append:/var/log/nms.log
StandardError=append:/var/log/nms.log

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable the service
run_command systemctl daemon-reload
run_command systemctl enable --now nms.service

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
    create 640 $SERVICE_USER $SERVICE_USER
}
EOF

# Verify log rotation configuration
verify_logrotate

# Final Checks and System Optimization
echo "Final system checks..."
run_command systemctl status nms.service --no-pager
run_command systemctl status systemd-journald --no-pager
run_command journalctl --verify
run_command free -h

# Enable automatic security updates
echo "Enabling automatic security updates..."
run_command apt install unattended-upgrades -y
run_command dpkg-reconfigure -plow unattended-upgrades

# Optimize SSD performance (if applicable)
if is_ssd; then
    echo "Optimizing SSD performance..."
    run_command systemctl enable fstrim.timer
else
    echo "No SSD detected. Skipping SSD optimization."
fi

# Disable unnecessary services
echo "Disabling unused services..."
run_command systemctl disable bluetooth.service --now 2>/dev/null

echo "Setup complete!"
echo "System status:"
echo "Node.js version: $NODE_VER"
echo "Service user: $SERVICE_USER"
echo "Disk space: $(df -h / | tail -1)"
echo "Memory: $(free -h | grep Mem:)"

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] Script completed in dry-run mode. No changes were made."
else
    echo "Rebooting in 10 seconds..."
    sleep 10
    run_command reboot
fi
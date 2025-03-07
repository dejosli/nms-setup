#!/bin/bash

# Configuration file (optional)
CONFIG_FILE="/etc/setup_script.conf"
if [ ! -f "$CONFIG_FILE" ] && [[ $EUID -eq 0 ]]; then
    echo "Creating default config file at $CONFIG_FILE..."
    cat > "$CONFIG_FILE" <<EOF
# Dry run mode (0 = execute commands, 1 = simulate without changes)
DRY_RUN=0
# Minimum disk space required in MB (setup aborts if below this)
MIN_DISK_SPACE_MB=1000
# Node.js version to install (e.g., 18, 20)
NODE_VERSION=18
# Service user to run NMS (must not be root)
SERVICE_USER=mediauser
# Cleanup previous user data (0 = no, 1 = yes with prompt or --force)
CLEANUP_PREVIOUS=1
# Log file location for NMS output
NMS_LOG_FILE=/var/log/nms.log
# Start the service immediately (0 = configure only, 1 = start after setup)
START_SERVICE=1
# Health check URL for NMS (HTTP endpoint to verify service)
HEALTH_CHECK_URL=http://localhost:8000/api/server
# Ports for NMS (space-separated: RTMP, HTTP, etc., e.g., "1935 8000")
NMS_PORTS="1935 8000"
# URL or local path to NMS app.js (default fetches from GitHub)
NMS_APP_URL=https://raw.githubusercontent.com/dejosli/boilerplates/refs/heads/main/docker-compose/node-media-server/app.js
# Version of node-media-server package to install via npm (e.g., 2.7.0, latest)
NMS_VERSION=2.7.0
EOF
    chmod 644 "$CONFIG_FILE" 2>/dev/null || echo "Warning: Could not set config file permissions"
fi
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Default configurations (can be overridden in config file)
DRY_RUN=${DRY_RUN:-0}
MIN_DISK_SPACE_MB=${MIN_DISK_SPACE_MB:-1000}
NODE_VERSION=${NODE_VERSION:-18}
SERVICE_USER=${SERVICE_USER:-administrator}
CLEANUP_PREVIOUS=${CLEANUP_PREVIOUS:-0}
NMS_LOG_FILE=${NMS_LOG_FILE:-/var/log/nms.log}
START_SERVICE=${START_SERVICE:-1}
HEALTH_CHECK_URL=${HEALTH_CHECK_URL:-http://localhost:8000/api/server}
NMS_PORTS=${NMS_PORTS:-"1935 8000"}
NMS_APP_URL=${NMS_APP_URL:-"https://raw.githubusercontent.com/dejosli/boilerplates/refs/heads/main/docker-compose/node-media-server/app.js"}
NMS_VERSION=${NMS_VERSION:-"2.7.0"}

# Check for command-line flags
FORCE_CLEANUP=0
QUIET=0
NO_ROLLBACK=0
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE_CLEANUP=1
    elif [[ "$arg" == "--quiet" ]]; then
        QUIET=1
    elif [[ "$arg" == "--no-rollback" ]]; then
        NO_ROLLBACK=1
    fi
done

# Ensure the script runs with root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use: sudo ./setup.sh"
    exit 1
fi

# Setup logging
LOG_FILE="/var/log/setup_script.log"
if [[ $QUIET -eq 1 ]]; then
    exec > "$LOG_FILE" 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi
chmod 640 "$LOG_FILE" 2>/dev/null || touch "$LOG_FILE" && chmod 640 "$LOG_FILE"
chown root:root "$LOG_FILE" 2>/dev/null
ERRORS=()

# Detect OS and set package manager
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    echo "Warning: Could not detect OS. Assuming generic Linux."
    DISTRO="unknown"
fi

# SELinux detection (only for RHEL-based distros or if explicitly enabled)
SELINUX_ENABLED=0
case "$DISTRO" in
    centos|rhel|fedora)
        if command -v sestatus >/dev/null 2>&1 && sestatus | grep -q "SELinux status:.*enabled"; then
            SELINUX_ENABLED=1
            [[ $QUIET -eq 0 ]] && echo "SELinux detected and enabled on $DISTRO. Adjusting contexts accordingly."
        fi
        ;;
    *)
        if command -v sestatus >/dev/null 2>&1 && sestatus | grep -q "SELinux status:.*enabled"; then
            SELINUX_ENABLED=1
            [[ $QUIET -eq 0 ]] && echo "SELinux detected and enabled on $DISTRO (non-standard). Adjusting contexts."
        fi
        ;;
esac

case "$DISTRO" in
    debian|ubuntu)
        PKG_MANAGER="apt"
        PKG_UPDATE="$PKG_MANAGER update"
        PKG_UPGRADE="$PKG_MANAGER upgrade -y"
        PKG_INSTALL="$PKG_MANAGER install -y"
        PKG_CLEAN="$PKG_MANAGER autoremove -y && $PKG_MANAGER autoclean"
        REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "zram-tools" "ffmpeg" "net-tools" "ufw")
        ;;
    fedora)
        PKG_MANAGER="dnf"
        PKG_UPDATE="$PKG_MANAGER check-update"
        PKG_UPGRADE="$PKG_MANAGER upgrade -y"
        PKG_INSTALL="$PKG_MANAGER install -y"
        PKG_CLEAN="$PKG_MANAGER autoremove -y"
        REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "zram-generator" "ffmpeg" "net-tools" "firewalld")
        ;;
    centos|rhel)
        PKG_MANAGER="yum"
        PKG_UPDATE="$PKG_MANAGER check-update"
        PKG_UPGRADE="$PKG_MANAGER upgrade -y"
        PKG_INSTALL="$PKG_MANAGER install -y"
        PKG_CLEAN="$PKG_MANAGER autoremove -y"
        REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "zram-generator" "ffmpeg" "net-tools" "firewalld")
        ;;
    arch)
        PKG_MANAGER="pacman"
        PKG_UPDATE="$PKG_MANAGER -Syy"
        PKG_UPGRADE="$PKG_MANAGER -Syu --noconfirm"
        PKG_INSTALL="$PKG_MANAGER -S --noconfirm"
        PKG_CLEAN="$PKG_MANAGER -Rns \$(pacman -Qdtq) --noconfirm"
        REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "zram-generator" "ffmpeg" "net-tools" "iptables")
        ;;
    *)
        echo "Unsupported distro: $DISTRO. Attempting generic setup."
        PKG_MANAGER=""
        REQUIRED_PKGS=("curl" "git" "vim" "wget" "logrotate" "ffmpeg" "net-tools")
        ;;
esac

[[ $QUIET -eq 0 ]] && echo "Starting system setup on $DISTRO at $(date)"

# Total steps for progress tracking
TOTAL_STEPS=18
CURRENT_STEP=0

# Function to update progress
update_progress() {
    ((CURRENT_STEP++))
    local percent=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    [[ $QUIET -eq 0 ]] && echo "Progress: $percent% ($CURRENT_STEP/$TOTAL_STEPS steps completed)"
}

# Function to run commands with dry-run support and detailed error logging
run_command() {
    if [[ $DRY_RUN -eq 1 ]]; then
        [[ $QUIET -eq 0 ]] && echo "[DRY-RUN] Command: $@"
    else
        [[ $QUIET -eq 0 ]] && echo "Executing: $@"
        OUTPUT=$(eval "$@" 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "Error: Command failed: $@" >&2
            echo "Output: $OUTPUT" >&2
            ERRORS+=("Command failed: $@ - Output: $OUTPUT")
            [[ $NO_ROLLBACK -eq 0 ]] && rollback
            exit 1
        fi
    fi
}

# Function to set SELinux context if applicable
set_selinux_context() {
    local file=$1
    local context=$2
    if [[ $SELINUX_ENABLED -eq 1 && -f "$file" && -n "$context" ]]; then
        if command -v chcon >/dev/null 2>&1; then
            chcon -t "$context" "$file" 2>/dev/null || echo "Warning: Failed to set SELinux context $context on $file"
        fi
        if command -v restorecon >/dev/null 2>&1; then
            restorecon "$file" 2>/dev/null
        fi
    fi
}

# Function to configure firewall
configure_firewall() {
    [[ $QUIET -eq 0 ]] && echo "Configuring firewall for NMS ports: $NMS_PORTS..."
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            for port in $NMS_PORTS; do
                run_command ufw allow "$port/tcp"
            done
            run_command ufw reload
        else
            [[ $QUIET -eq 0 ]] && echo "UFW installed but not active. Skipping firewall config."
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active firewalld >/dev/null 2>&1; then
            for port in $NMS_PORTS; do
                run_command firewall-cmd --permanent --add-port="$port/tcp"
            done
            run_command firewall-cmd --reload
            if [[ $SELINUX_ENABLED -eq 1 ]]; then
                for port in $NMS_PORTS; do
                    if command -v semanage >/dev/null 2>&1; then
                        semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || echo "Warning: SELinux port $port already defined or semanage failed"
                    fi
                done
            fi
        else
            [[ $QUIET -eq 0 ]] && echo "Firewalld installed but not active. Skipping firewall config."
        fi
    elif command -v iptables >/dev/null 2>&1; then
        if iptables -L -n | grep -q "ACCEPT"; then
            for port in $NMS_PORTS; do
                run_command iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            done
            [[ $QUIET -eq 0 ]] && echo "Note: iptables rules applied but not persisted. Save manually if needed."
        else
            [[ $QUIET -eq 0 ]] && echo "iptables detected but not configured. Skipping firewall config."
        fi
    else
        echo "Warning: No firewall tool detected (ufw, firewalld, iptables). Skipping firewall config."
        ERRORS+=("No firewall tool detected")
    fi
}

# Function to check port conflicts
check_port_conflicts() {
    [[ $QUIET -eq 0 ]] && echo "Checking for port conflicts..."
    if command -v netstat >/dev/null 2>&1; then
        for port in $NMS_PORTS; do
            if netstat -tuln | grep -q ":$port"; then
                echo "Error: Port $port is already in use."
                ERRORS+=("Port conflict on $port")
                exit 1
            fi
        done
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
        ERRORS+=("Insufficient disk space")
        exit 1
    fi
    [[ $QUIET -eq 0 ]] && echo "Disk space check passed: ${available_mb}MB available"
}

# Function to validate username
validate_username() {
    local username=$1
    if [[ -z "$username" || ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Error: Invalid username '$username'. Must start with a letter or underscore, followed by letters, numbers, underscores, or hyphens."
        ERRORS+=("Invalid username: $username")
        exit 1
    fi
    if [[ "$username" == "root" ]]; then
        echo "Error: SERVICE_USER cannot be 'root'. Node.js and service components must run as a non-root user."
        ERRORS+=("SERVICE_USER cannot be root")
        exit 1
    fi
    [[ $QUIET -eq 0 ]] && echo "Username '$username' is valid"
}

# Function to cleanup previous user data with confirmation and root protection
cleanup_previous_user() {
    local old_user=$1
    if [[ "$old_user" == "root" ]]; then
        echo "Error: Attempted to clean up root user. This is not allowed."
        ERRORS+=("Attempted to clean up root user")
        exit 1
    fi
    if user_exists "$old_user" && [[ "$old_user" != "$SERVICE_USER" ]]; then
        [[ $QUIET -eq 0 ]] && echo "WARNING: Previous user '$old_user' detected. Cleanup will remove:"
        [[ $QUIET -eq 0 ]] && echo "- User account and home directory (/home/$old_user)"
        [[ $QUIET -eq 0 ]] && echo "- Node Media Server files and service"
        [[ $QUIET -eq 0 ]] && echo "- Log rotation configuration"
        if [[ $FORCE_CLEANUP -eq 1 ]]; then
            [[ $QUIET -eq 0 ]] && echo "Force cleanup enabled (--force flag detected)"
            proceed="y"
        else
            [[ $QUIET -eq 0 ]] && read -p "Are you sure you want to proceed with cleanup? (y/N): " proceed
            [[ $QUIET -eq 1 ]] && proceed="n"
        fi
        if [[ "$proceed" =~ ^[Yy]$ ]]; then
            [[ $QUIET -eq 0 ]] && echo "Cleaning up previous user data for '$old_user'..."
            run_command systemctl disable nms.service 2>/dev/null
            run_command rm -f /etc/systemd/system/nms.service
            run_command rm -f /etc/logrotate.d/nms
            run_command rm -rf "/home/$old_user/Node-Media-Server"
            run_command rm -rf "/home/$old_user/.nvm"
            run_command userdel -r "$old_user" 2>/dev/null
            [[ $QUIET -eq 0 ]] && echo "Cleanup completed for '$old_user'"
        else
            [[ $QUIET -eq 0 ]] && echo "Cleanup aborted. Proceeding with setup using new user '$SERVICE_USER'."
        fi
    fi
}

# Function to verify log rotation
verify_logrotate() {
    [[ $QUIET -eq 0 ]] && echo "Verifying log rotation configuration..."
    if [[ $DRY_RUN -eq 0 ]]; then
        run_command logrotate -d /etc/logrotate.d/nms 2>&1 | grep -v "log does not exist"
        if [[ $? -eq 0 ]]; then
            [[ $QUIET -eq 0 ]] && echo "Log rotation configuration verified successfully"
        else
            echo "Warning: Log rotation configuration may have issues"
            ERRORS+=("Log rotation configuration issue")
        fi
    fi
}

# Function to rollback on failure
rollback() {
    if [[ $NO_ROLLBACK -eq 1 ]]; then
        echo "Rollback skipped due to --no-rollback flag."
    else
        echo "Rolling back changes due to setup failure..."
        run_command systemctl stop nms.service 2>/dev/null
        run_command systemctl disable nms.service 2>/dev/null
        run_command rm -f /etc/systemd/system/nms.service
        run_command rm -f /etc/logrotate.d/nms
        run_command systemctl daemon-reload
        echo "Rollback completed. Check logs at $LOG_FILE for details."
    fi
}

# Validate SERVICE_USER
validate_username "$SERVICE_USER"
update_progress

# Check for previous user cleanup with enhanced detection
if [[ $CLEANUP_PREVIOUS -eq 1 ]]; then
    OLD_USER=""
    if [[ -f /etc/systemd/system/nms.service ]]; then
        OLD_USER=$(grep "^User=" /etc/systemd/system/nms.service | cut -d= -f2)
    elif [[ -d "/home/$SERVICE_USER/Node-Media-Server" ]]; then
        OLD_USER=$(stat -c '%U' "/home/$SERVICE_USER/Node-Media-Server" 2>/dev/null)
    else
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
        [[ $QUIET -eq 0 ]] && echo "No previous user data detected for cleanup"
    fi
fi
update_progress

# Check initial disk space
check_disk_space "$MIN_DISK_SPACE_MB"
update_progress

# Configure package sources and update
if [[ -n "$PKG_MANAGER" ]]; then
    [[ $QUIET -eq 0 ]] && echo "Configuring package sources for $DISTRO..."
    case "$DISTRO" in
        debian|ubuntu)
            run_command cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || echo "No sources.list to backup"
            cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF
            chmod 644 /etc/apt/sources.list 2>/dev/null
            ;;
        fedora)
            if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
                run_command "$PKG_INSTALL https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
            fi
            ;;
        centos|rhel)
            if ! rpm -q epel-release >/dev/null 2>&1; then
                run_command "$PKG_INSTALL epel-release"
            fi
            if [[ "$DISTRO" == "centos" ]]; then
                run_command "$PKG_MANAGER config-manager --set-enabled crb"
            fi
            ;;
        arch)
            if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
                echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
                chmod 644 /etc/pacman.conf 2>/dev/null
            fi
            ;;
    esac
    run_command "$PKG_UPDATE"
    run_command "$PKG_UPGRADE"
    run_command "$PKG_INSTALL ${REQUIRED_PKGS[*]}"
    run_command "$PKG_CLEAN"
else
    echo "Warning: No package manager detected. Skipping package updates."
    ERRORS+=("No package manager detected")
fi
update_progress

# Configure Persistent systemd Journal Logs (if systemd exists)
if command -v systemctl >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && echo "Configuring systemd journaling..."
    run_command mkdir -p /var/log/journal
    chmod 755 /var/log/journal 2>/dev/null
    set_selinux_context /var/log/journal var_log_t
    JOURNAL_CONF="/etc/systemd/journald.conf"
    if [ -f "$JOURNAL_CONF" ]; then
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
        chmod 644 "$JOURNAL_CONF" 2>/dev/null
        set_selinux_context "$JOURNAL_CONF" systemd_unit_file_t
        run_command systemctl restart systemd-journald
        run_command journalctl --disk-usage
    else
        echo "Warning: journald.conf not found. Skipping journal config."
        ERRORS+=("journald.conf not found")
    fi
else
    echo "Warning: systemd not detected. Skipping journal configuration."
    ERRORS+=("systemd not detected")
fi
update_progress

# Configure Cron Job for Auto Log Cleanup (if cron exists)
if command -v crontab >/dev/null 2>&1; then
    CRON_JOB="0 3 * * 7 root journalctl --vacuum-time=30d"
    if ! crontab -l 2>/dev/null | grep -Fq "$CRON_JOB"; then
        [[ $QUIET -eq 0 ]] && echo "Adding cron job for log cleanup..."
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    fi
else
    echo "Warning: crontab not available. Skipping log cleanup cron job."
    ERRORS+=("crontab not available")
fi
update_progress

# Configure ZRAM Swap (if supported)
if [[ -d /sys/block/zram0 || -f /etc/default/zramswap || -f /etc/zram-generator.conf ]]; then
    [[ $QUIET -eq 0 ]] && echo "Configuring ZRAM swap..."
    ZRAM_CONF=""
    if [ -f /etc/default/zramswap ]; then
        ZRAM_CONF="/etc/default/zramswap"
        echo -e "ALGO=zstd\nPERCENT=50" > "$ZRAM_CONF"
        run_command systemctl restart zramswap 2>/dev/null || echo "Warning: zramswap service not found"
    elif [ -f /etc/zram-generator.conf ]; then
        ZRAM_CONF="/etc/zram-generator.conf"
        echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd" > "$ZRAM_CONF"
        run_command systemctl restart systemd-zram-setup@zram0 2>/dev/null || echo "Warning: zram service not found"
    fi
    if [[ -n "$ZRAM_CONF" ]]; then
        chmod 644 "$ZRAM_CONF" 2>/dev/null
        set_selinux_context "$ZRAM_CONF" etc_t
    fi
    run_command free -h
else
    echo "Warning: ZRAM not supported on this system. Skipping."
    ERRORS+=("ZRAM not supported")
fi
update_progress

# Enable systemd-resolved (if systemd exists)
if command -v systemctl >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && echo "Enabling systemd-resolved..."
    run_command systemctl enable systemd-resolved --now 2>/dev/null || echo "Warning: systemd-resolved not available"
    RESOLVED_CONF="/etc/systemd/resolved.conf"
    if [ -f "$RESOLVED_CONF" ]; then
        sed -i '/^#DNS=/c\DNS=1.1.1.1 8.8.8.8' "$RESOLVED_CONF"
        sed -i '/^#FallbackDNS=/c\FallbackDNS=9.9.9.9' "$RESOLVED_CONF"
        chmod 644 "$RESOLVED_CONF" 2>/dev/null
        set_selinux_context "$RESOLVED_CONF" systemd_unit_file_t
        run_command systemctl restart systemd-resolved
        run_command systemd-resolve --status | grep 'DNS Servers' 2>/dev/null
    fi
fi
update_progress

# Create service user if it doesn't exist
if ! user_exists "$SERVICE_USER"; then
    [[ $QUIET -eq 0 ]] && echo "Creating service user: $SERVICE_USER..."
    run_command useradd -m -s /bin/bash "$SERVICE_USER"
    [[ $QUIET -eq 0 ]] && echo "Please set a password for $SERVICE_USER:"
    run_command passwd "$SERVICE_USER"
fi
chmod 700 "/home/$SERVICE_USER" 2>/dev/null
set_selinux_context "/home/$SERVICE_USER" user_home_dir_t
update_progress

# Backup existing NVM setup if it exists
[[ $QUIET -eq 0 ]] && echo "Checking for existing NVM setup for $SERVICE_USER..."
NVM_DIR="/home/$SERVICE_USER/.nvm"
if [ -d "$NVM_DIR" ] && [[ $DRY_RUN -eq 0 ]]; then
    BACKUP_DIR="/home/$SERVICE_USER/.nvm_backup_$(date +%Y%m%d_%H%M%S)"
    [[ $QUIET -eq 0 ]] && echo "Backing up existing NVM directory to $BACKUP_DIR..."
    run_command cp -r "$NVM_DIR" "$BACKUP_DIR"
    chmod -R 700 "$BACKUP_DIR" 2>/dev/null
    chown -R "$SERVICE_USER:$SERVICE_USER" "$BACKUP_DIR" 2>/dev/null
    set_selinux_context "$BACKUP_DIR" user_home_t
fi

# Install NVM, Node.js, and Yarn for SERVICE_USER
[[ $QUIET -eq 0 ]] && echo "Installing NVM for $SERVICE_USER..."
if [ ! -d "$NVM_DIR" ]; then
    check_disk_space 500
    sudo -u "$SERVICE_USER" bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
fi
sudo -u "$SERVICE_USER" bash -c "source ~/.nvm/nvm.sh && nvm install $NODE_VERSION"
sudo -u "$SERVICE_USER" bash -c 'source ~/.nvm/nvm.sh && corepack enable yarn'
NODE_VER=$(sudo -u "$SERVICE_USER" bash -c "source ~/.nvm/nvm.sh && node -v")
NPM_VER=$(sudo -u "$SERVICE_USER" bash -c "source ~/.nvm/nvm.sh && npm -v")
[[ $QUIET -eq 0 ]] && echo "Installed Node.js version: $NODE_VER"
[[ $QUIET -eq 0 ]] && echo "Installed npm version: $NPM_VER"
if [[ "$NODE_VER" < "v18" || "$NPM_VER" < "8" ]]; then
    echo "Warning: Node.js ($NODE_VER) or npm ($NPM_VER) version may be too old for NMS."
    ERRORS+=("Node.js/npm version potentially incompatible")
fi
chmod -R 700 "$NVM_DIR" 2>/dev/null
chown -R "$SERVICE_USER:$SERVICE_USER" "$NVM_DIR" 2>/dev/null
set_selinux_context "$NVM_DIR" user_home_t
update_progress

# Install Node Media Server
[[ $QUIET -eq 0 ]] && echo "Setting up Node Media Server for $SERVICE_USER (version: $NMS_VERSION)..."
check_disk_space "$MIN_DISK_SPACE_MB"
NMS_DIR="/home/$SERVICE_USER/Node-Media-Server"
sudo -u "$SERVICE_USER" mkdir -p "$NMS_DIR"
chmod 700 "$NMS_DIR" 2>/dev/null
chown "$SERVICE_USER:$SERVICE_USER" "$NMS_DIR" 2>/dev/null
set_selinux_context "$NMS_DIR" user_home_t
cd "$NMS_DIR"
sudo -u "$SERVICE_USER" npm i "node-media-server@$NMS_VERSION"
if [[ "$NMS_APP_URL" =~ ^http ]]; then
    run_command wget -qO "$NMS_DIR/app.js" "$NMS_APP_URL"
else
    run_command cp "$NMS_APP_URL" "$NMS_DIR/app.js"
fi
chmod 644 "$NMS_DIR/app.js" 2>/dev/null
chown "$SERVICE_USER:$SERVICE_USER" "$NMS_DIR/app.js" 2>/dev/null
set_selinux_context "$NMS_DIR/app.js" user_home_t
update_progress

# Check for existing NMS service
[[ $QUIET -eq 0 ]] && echo "Checking for existing NMS service..."
NMS_SERVICE="/etc/systemd/system/nms.service"
if [[ -f "$NMS_SERVICE" && $DRY_RUN -eq 0 ]]; then
    CURRENT_USER=$(grep "^User=" "$NMS_SERVICE" | cut -d= -f2)
    if [[ "$CURRENT_USER" != "$SERVICE_USER" ]]; then
        [[ $QUIET -eq 0 ]] && echo "Warning: NMS service exists with user '$CURRENT_USER'. Overwriting with '$SERVICE_USER'."
        run_command systemctl stop nms.service 2>/dev/null
    fi
fi

# Create systemd service for Node Media Server
if command -v systemctl >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && echo "Creating systemd service for NMS..."
    cat > "$NMS_SERVICE" <<EOF
[Unit]
Description=Node Media Server
After=network.target

[Service]
ExecStart=/bin/bash -c '. /home/$SERVICE_USER/.nvm/nvm.sh && exec node $NMS_DIR/app.js'
Restart=always
RestartSec=5s
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$NMS_DIR
StandardOutput=append:$NMS_LOG_FILE
StandardError=append:$NMS_LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$NMS_SERVICE" 2>/dev/null
    set_selinux_context "$NMS_SERVICE" systemd_unit_file_t
    run_command systemctl daemon-reload
    run_command systemctl enable nms.service
    check_port_conflicts
    if [[ $START_SERVICE -eq 1 ]]; then
        run_command systemctl start nms.service
    elif [[ $QUIET -eq 0 ]]; then
        read -p "Start NMS service now? (y/N): " start_now
        if [[ "$start_now" =~ ^[Yy]$ ]]; then
            run_command systemctl start nms.service
        else
            [[ $QUIET -eq 0 ]] && echo "Service configured but not started."
        fi
    else
        [[ $QUIET -eq 0 ]] && echo "Service configured but not started (START_SERVICE=0)"
    fi
else
    echo "Warning: systemd not available. Skipping service setup."
    ERRORS+=("systemd not available")
fi
touch "$NMS_LOG_FILE" 2>/dev/null
chmod 640 "$NMS_LOG_FILE" 2>/dev/null
chown "$SERVICE_USER:$SERVICE_USER" "$NMS_LOG_FILE" 2>/dev/null
set_selinux_context "$NMS_LOG_FILE" var_log_t
update_progress

# Configure logrotate for NMS logs
if command -v logrotate >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && echo "Setting up log rotation for NMS logs..."
    LOGROTATE_CONF="/etc/logrotate.d/nms"
    cat > "$LOGROTATE_CONF" <<EOF
$NMS_LOG_FILE {
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
    chmod 644 "$LOGROTATE_CONF" 2>/dev/null
    set_selinux_context "$LOGROTATE_CONF" etc_t
    verify_logrotate
else
    echo "Warning: logrotate not available. Skipping log rotation setup."
    ERRORS+=("logrotate not available")
fi
update_progress

# Configure firewall
configure_firewall
update_progress

# Post-setup validation
[[ $QUIET -eq 0 ]] && echo "Validating Node Media Server setup..."
if [[ $DRY_RUN -eq 0 && -f "$NMS_SERVICE" && ($START_SERVICE -eq 1 || "$start_now" =~ ^[Yy]$) ]]; then
    sleep 2
    if systemctl is-active nms.service >/dev/null 2>&1; then
        if command -v netstat >/dev/null 2>&1; then
            PORTS_LISTENING=0
            for port in $NMS_PORTS; do
                if netstat -tuln | grep -q ":$port"; then
                    [[ $QUIET -eq 0 ]] && echo "Validation: NMS is listening on port $port"
                    ((PORTS_LISTENING++))
                fi
            done
            if [[ $PORTS_LISTENING -eq 0 ]]; then
                echo "Warning: NMS is running but not listening on any configured ports ($NMS_PORTS)"
                ERRORS+=("NMS not listening on any ports")
            elif [[ $PORTS_LISTENING -lt $(echo "$NMS_PORTS" | wc -w) ]]; then
                echo "Warning: NMS is running but not listening on all configured ports ($NMS_PORTS)"
                ERRORS+=("NMS missing some ports")
            fi
        fi
        if command -v curl >/dev/null 2>&1; then
            if curl -s "$HEALTH_CHECK_URL" >/dev/null 2>&1; then
                [[ $QUIET -eq 0 ]] && echo "Validation: NMS health check at $HEALTH_CHECK_URL succeeded"
            else
                echo "Error: NMS health check at $HEALTH_CHECK_URL failed"
                ERRORS+=("NMS health check failed")
                rollback
                exit 1
            fi
        fi
    else
        echo "Error: Node Media Server service failed to start"
        ERRORS+=("NMS service failed to start")
        rollback
        exit 1
    fi
fi
update_progress

# Final Checks and System Optimization
[[ $QUIET -eq 0 ]] && echo "Final system checks..."
if command -v systemctl >/dev/null 2>&1; then
    run_command systemctl status nms.service --no-pager 2>/dev/null
    run_command systemctl status systemd-journald --no-pager 2>/dev/null
fi
run_command free -h

if [[ -n "$PKG_MANAGER" ]]; then
    [[ $QUIET -eq 0 ]] && echo "Enabling automatic security updates..."
    case "$DISTRO" in
        debian|ubuntu)
            run_command "$PKG_INSTALL unattended-upgrades"
            run_command dpkg-reconfigure -plow unattended-upgrades
            ;;
        fedora|centos|rhel)
            run_command "$PKG_INSTALL dnf-automatic"
            run_command systemctl enable --now dnf-automatic-install.timer 2>/dev/null
            ;;
        arch)
            echo "Note: Arch uses rolling updates. Skipping unattended-upgrades."
            ;;
    esac
fi

if is_ssd && command -v systemctl >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && echo "Optimizing SSD performance..."
    run_command systemctl enable fstrim.timer 2>/dev/null || echo "Warning: fstrim not available"
else
    [[ $QUIET -eq 0 ]] && echo "No SSD detected or systemd unavailable. Skipping SSD optimization."
fi

if command -v systemctl >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && echo "Disabling unused services..."
    run_command systemctl disable bluetooth.service --now 2>/dev/null
fi
update_progress

# Summary
[[ $QUIET -eq 0 ]] && echo "Setup complete!"
[[ $QUIET -eq 0 ]] && echo "System status:"
[[ $QUIET -eq 0 ]] && echo "Node.js version: $NODE_VER"
[[ $QUIET -eq 0 ]] && echo "npm version: $NPM_VER"
[[ $QUIET -eq 0 ]] && echo "Service user: $SERVICE_USER"
[[ $QUIET -eq 0 ]] && echo "NMS version: $NMS_VERSION"
[[ $QUIET -eq 0 ]] && echo "NMS log file: $NMS_LOG_FILE"
[[ $QUIET -eq 0 ]] && echo "NMS ports: $NMS_PORTS"
[[ $QUIET -eq 0 ]] && echo "Disk space: $(df -h / | tail -1)"
[[ $QUIET -eq 0 ]] && echo "Memory: $(free -h | grep Mem:)"
[[ $QUIET -eq 0 ]] && echo "Firewall status:"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    [[ $QUIET -eq 0 ]] && ufw status | grep -E "$(echo $NMS_PORTS | tr ' ' '|')"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && firewall-cmd --list-ports
elif command -v iptables >/dev/null 2>&1; then
    [[ $QUIET -eq 0 ]] && iptables -L -n | grep -E "$(echo $NMS_PORTS | tr ' ' '|')"
else
    [[ $QUIET -eq 0 ]] && echo "No active firewall detected."
fi
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "Errors encountered during setup:"
    for err in "${ERRORS[@]}"; do
        echo "- $err"
    done
fi

if [[ $DRY_RUN -eq 1 ]]; then
    [[ $QUIET -eq 0 ]] && echo "[DRY-RUN] Script completed in dry-run mode. No changes were made."
else
    [[ $QUIET -eq 0 ]] && echo "Rebooting in 10 seconds..."
    sleep 10
    run_command reboot
fi

# Set script permissions (manual step after saving)
# chmod 755 "$0"
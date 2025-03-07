# Node Media Server Setup Script

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Supported OS](https://img.shields.io/badge/OS-Linux-green.svg)
![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)

A robust, cross-distribution Bash script to automate the setup of [Node Media Server (NMS)](https://github.com/illuspas/Node-Media-Server) on Linux systems. This script handles everything from system updates to firewall configuration, SELinux contexts, and service deployment with customizable options.

## Features

- **Cross-Distro Compatibility**: Works on Debian, Ubuntu, Fedora, CentOS, RHEL, Arch, and more.
- **Customizable**: Configurable via `/etc/setup_script.conf` for Node.js version, NMS version, ports, and more.
- **Firewall Support**: Configures `ufw`, `firewalld`, or `iptables` based on the distro.
- **SELinux Aware**: Applies contexts on RHEL-based systems where enabled.
- **Multi-Port Support**: Supports multiple ports (e.g., RTMP, HTTP) for NMS.
- **Error Handling**: Detailed logging, rollback on failure (optional), and port conflict detection.
- **System Optimization**: Sets up ZRAM, SSD trim, journald, and automatic updates.
- **User-Friendly**: Progress tracking, interactive prompts, and a detailed summary.

## Prerequisites

- **Root Access**: Must run with `sudo` or as root.
- **Internet Connection**: Required for package downloads and updates.
- **Supported OS**: Any Linux distro with `bash` (systemd recommended for full functionality).

## Installation

1. **Clone or Download**:
   ```bash
   git clone https://github.com/yourusername/nms-setup.git
   cd nms-setup

2. **Set Permissions**:
   ```bash
   chmod 755 setup.sh

3. **Run the Script**:
   ```bash
   sudo ./setup.sh



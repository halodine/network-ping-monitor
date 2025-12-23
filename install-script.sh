#!/bin/bash

# Network Ping Monitor - Proxmox LXC Install Script
# Usage: bash -c "$(wget -qLO - https://raw.githubusercontent.com/YOUR_USERNAME/network-ping-monitor/main/install.sh)"

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CTID=""
HOSTNAME="ping-monitor"
DISK_SIZE="4"
RAM="512"
SWAP="512"
CORES="1"
BRIDGE="vmbr0"
STORAGE=""
TEMPLATE_STORAGE=""
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
PORT="3000"

# Helper functions
msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if running on Proxmox
check_proxmox() {
    if ! command -v pveversion &> /dev/null; then
        msg_error "This script must be run on a Proxmox host"
        exit 1
    fi
    msg_ok "Running on Proxmox $(pveversion | cut -d'/' -f2)"
}

# Get next available CT ID
get_next_ctid() {
    CTID=$(pvesh get /cluster/nextid)
    msg_info "Using CT ID: $CTID"
}

# Detect available storage for templates and containers
detect_storage() {
    msg_info "Detecting available storage..."
    
    # Templates require directory-based storage (dir) or ZFS storage (zfspool)
    # Containers can use lvmthin, dir, or zfspool (prefer lvmthin for efficiency)
    
    # First, find storage for templates (must be dir or zfspool)
    while IFS= read -r storage_line; do
        # Skip header line
        [[ "$storage_line" =~ ^NAME ]] && continue
        
        storage_name=$(echo "$storage_line" | awk '{print $1}')
        storage_type=$(echo "$storage_line" | awk '{print $2}')
        
        # Templates need dir or zfspool
        if [[ "$storage_type" == "dir" ]] || [[ "$storage_type" == "zfspool" ]]; then
            # Prefer common storage names first
            if [[ "$storage_name" == "local" ]] || [[ "$storage_name" == "local-lxc" ]] || [[ "$storage_name" == "local-zfs" ]]; then
                TEMPLATE_STORAGE=$storage_name
                break
            fi
        fi
    done < <(pvesm status)
    
    # If no preferred template storage found, use first available dir/zfspool
    if [ -z "$TEMPLATE_STORAGE" ]; then
        while IFS= read -r storage_line; do
            # Skip header line
            [[ "$storage_line" =~ ^NAME ]] && continue
            
            storage_name=$(echo "$storage_line" | awk '{print $1}')
            storage_type=$(echo "$storage_line" | awk '{print $2}')
            
            if [[ "$storage_type" == "dir" ]] || [[ "$storage_type" == "zfspool" ]]; then
                TEMPLATE_STORAGE=$storage_name
                break
            fi
        done < <(pvesm status)
    fi
    
    # Now find storage for containers (prefer lvmthin, fallback to template storage)
    while IFS= read -r storage_line; do
        # Skip header line
        [[ "$storage_line" =~ ^NAME ]] && continue
        
        storage_name=$(echo "$storage_line" | awk '{print $1}')
        storage_type=$(echo "$storage_line" | awk '{print $2}')
        
        # Prefer lvmthin for containers (more efficient)
        if [[ "$storage_type" == "lvmthin" ]]; then
            if [[ "$storage_name" == "local-lvm" ]] || [[ "$storage_name" == "local-zfs" ]]; then
                STORAGE=$storage_name
                msg_ok "Using container storage: $STORAGE (type: $storage_type)"
                msg_ok "Using template storage: $TEMPLATE_STORAGE"
                return 0
            fi
        fi
    done < <(pvesm status)
    
    # If no lvmthin found, use template storage for both
    if [ -z "$STORAGE" ]; then
        STORAGE=$TEMPLATE_STORAGE
        msg_ok "Using storage: $STORAGE (for both templates and containers)"
    fi
    
    if [ -z "$TEMPLATE_STORAGE" ]; then
        msg_error "No suitable storage found that supports templates."
        msg_info "Templates require directory-based storage (dir) or ZFS storage (zfspool)."
        msg_info ""
        msg_info "Available storages:"
        pvesm status
        exit 1
    fi
}

# Interactive setup
interactive_setup() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Network Ping Monitor - Installation     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    
    read -p "Container ID (press Enter for auto: $CTID): " input_ctid
    CTID=${input_ctid:-$CTID}
    
    read -p "Hostname (default: $HOSTNAME): " input_hostname
    HOSTNAME=${input_hostname:-$HOSTNAME}
    
    read -p "Disk size in GB (default: $DISK_SIZE): " input_disk
    DISK_SIZE=${input_disk:-$DISK_SIZE}
    
    read -p "RAM in MB (default: $RAM): " input_ram
    RAM=${input_ram:-$RAM}
    
    read -p "CPU cores (default: $CORES): " input_cores
    CORES=${input_cores:-$CORES}
    
    read -p "Network bridge (default: $BRIDGE): " input_bridge
    BRIDGE=${input_bridge:-$BRIDGE}
    
    read -p "Container storage (default: $STORAGE): " input_storage
    STORAGE=${input_storage:-$STORAGE}
    
    read -p "Template storage (default: $TEMPLATE_STORAGE): " input_template_storage
    TEMPLATE_STORAGE=${input_template_storage:-$TEMPLATE_STORAGE}
    
    read -p "Application port (default: $PORT): " input_port
    PORT=${input_port:-$PORT}
    
    echo ""
    msg_info "Creating container with following specs:"
    echo "  CT ID: $CTID"
    echo "  Hostname: $HOSTNAME"
    echo "  Disk: ${DISK_SIZE}GB"
    echo "  RAM: ${RAM}MB"
    echo "  Cores: $CORES"
    echo "  Bridge: $BRIDGE"
    echo "  Container storage: $STORAGE"
    echo "  Template storage: $TEMPLATE_STORAGE"
    echo "  Port: $PORT"
    echo ""
    
    read -p "Continue with installation? (y/n): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        msg_warn "Installation cancelled"
        exit 0
    fi
}

# Download template if not exists
download_template() {
    msg_info "Checking for Ubuntu template..."
    
    if ! pveam list $TEMPLATE_STORAGE | grep -q "$TEMPLATE"; then
        msg_info "Downloading Ubuntu 22.04 template..."
        pveam download $TEMPLATE_STORAGE $TEMPLATE
        msg_ok "Template downloaded"
    else
        msg_ok "Template already exists"
    fi
}

# Create LXC container
create_container() {
    msg_info "Creating LXC container..."
    
    pct create $CTID $TEMPLATE_STORAGE:vztmpl/$TEMPLATE \
        --hostname $HOSTNAME \
        --memory $RAM \
        --swap $SWAP \
        --cores $CORES \
        --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
        --storage $STORAGE \
        --rootfs $STORAGE:$DISK_SIZE \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 1
    
    msg_ok "Container created with ID $CTID"
    
    # Wait for container to start
    msg_info "Waiting for container to start..."
    sleep 5
}

# Install application in container
install_application() {
    msg_info "Installing Node.js and dependencies..."
    
    pct exec $CTID -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get upgrade -y -qq
        apt-get install -y -qq curl iputils-ping
        
        # Install Node.js
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y -qq nodejs
        
        # Create application directory
        mkdir -p /opt/ping-monitor/public
        cd /opt/ping-monitor
    "
    
    msg_ok "Dependencies installed"
    
    msg_info "Downloading application files..."
    
    pct exec $CTID -- bash -c "
        cd /opt/ping-monitor
        
        # Download from GitHub
        curl -sL https://raw.githubusercontent.com/halodine/network-ping-monitor/main/server.js -o server.js
        curl -sL https://raw.githubusercontent.com/halodine/network-ping-monitor/main/package.json -o package.json
        curl -sL https://raw.githubusercontent.com/halodine/network-ping-monitor/main/public/index.html -o public/index.html
        curl -sL https://raw.githubusercontent.com/halodine/network-ping-monitor/main/public/app.js -o public/app.js
        
        # Install npm packages
        npm install --silent
    "
    
    msg_ok "Application files installed"
}

# Create systemd service
create_service() {
    msg_info "Creating systemd service..."
    
    pct exec $CTID -- bash -c "
        cat > /etc/systemd/system/ping-monitor.service << 'EOF'
[Unit]
Description=Network Ping Monitor
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ping-monitor
Environment=PORT=$PORT
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable ping-monitor
        systemctl start ping-monitor
    "
    
    msg_ok "Service created and started"
}

# Get container IP
get_container_ip() {
    msg_info "Retrieving container IP address..."
    sleep 3
    
    CONTAINER_IP=$(pct exec $CTID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    if [ -z "$CONTAINER_IP" ]; then
        msg_warn "Could not retrieve IP automatically"
        msg_info "Check IP with: pct exec $CTID -- ip addr"
    else
        msg_ok "Container IP: $CONTAINER_IP"
    fi
}

# Display completion message
show_completion() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         Installation Complete!             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Container Details:${NC}"
    echo "  CT ID: $CTID"
    echo "  Hostname: $HOSTNAME"
    if [ -n "$CONTAINER_IP" ]; then
        echo "  IP Address: $CONTAINER_IP"
        echo ""
        echo -e "${GREEN}Access your monitor at:${NC}"
        echo -e "  ${YELLOW}http://$CONTAINER_IP:$PORT${NC}"
    else
        echo "  IP Address: Run 'pct exec $CTID -- ip addr' to find"
    fi
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "  View logs: pct exec $CTID -- journalctl -u ping-monitor -f"
    echo "  Restart service: pct exec $CTID -- systemctl restart ping-monitor"
    echo "  Enter container: pct enter $CTID"
    echo "  Stop container: pct stop $CTID"
    echo "  Start container: pct start $CTID"
    echo ""
}

# Cleanup on error
cleanup() {
    if [ $? -ne 0 ]; then
        msg_error "Installation failed!"
        if [ -n "$CTID" ] && pct status $CTID &>/dev/null; then
            read -p "Delete failed container $CTID? (y/n): " delete_confirm
            if [[ $delete_confirm =~ ^[Yy]$ ]]; then
                pct stop $CTID 2>/dev/null || true
                pct destroy $CTID
                msg_ok "Container $CTID removed"
            fi
        fi
    fi
}

trap cleanup EXIT

# Main installation flow
main() {
    check_proxmox
    get_next_ctid
    detect_storage
    interactive_setup
    download_template
    create_container
    install_application
    create_service
    get_container_ip
    show_completion
}

main

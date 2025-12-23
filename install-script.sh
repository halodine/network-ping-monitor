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
    msg_info "Scanning Proxmox storage pools..."
    
    # Show available storages for debugging
    msg_info "Available storages:"
    pvesm status | while IFS= read -r line; do
        if [[ ! "$line" =~ ^NAME ]]; then
            storage_name=$(echo "$line" | awk '{print $1}')
            storage_type=$(echo "$line" | awk '{print $2}')
            msg_info "  - $storage_name (type: $storage_type)"
        fi
    done
    
    # Templates require directory-based storage (dir) or ZFS storage (zfspool)
    # Containers can use lvmthin, dir, or zfspool (prefer lvmthin for efficiency)
    
    # First, find storage for templates (must be dir or zfspool)
    msg_info "Searching for template storage (dir or zfspool)..."
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
                msg_info "Found template storage: $TEMPLATE_STORAGE (type: $storage_type)"
                break
            fi
        fi
    done < <(pvesm status)
    
    # If no preferred template storage found, use first available dir/zfspool
    if [ -z "$TEMPLATE_STORAGE" ]; then
        msg_info "No preferred template storage found, searching for any dir/zfspool storage..."
        while IFS= read -r storage_line; do
            # Skip header line
            [[ "$storage_line" =~ ^NAME ]] && continue
            
            storage_name=$(echo "$storage_line" | awk '{print $1}')
            storage_type=$(echo "$storage_line" | awk '{print $2}')
            
            if [[ "$storage_type" == "dir" ]] || [[ "$storage_type" == "zfspool" ]]; then
                TEMPLATE_STORAGE=$storage_name
                msg_info "Found template storage: $TEMPLATE_STORAGE (type: $storage_type)"
                break
            fi
        done < <(pvesm status)
    fi
    
    if [ -z "$TEMPLATE_STORAGE" ]; then
        msg_error "No template storage found (requires dir or zfspool type)"
        pvesm status
        exit 1
    fi
    
    # Now find storage for containers (prefer lvmthin, fallback to zfspool, then dir)
    # First, try to find lvmthin storage (best for containers)
    msg_info "Searching for container storage (preferring lvmthin)..."
    while IFS= read -r storage_line; do
        # Skip header line
        [[ "$storage_line" =~ ^NAME ]] && continue
        
        storage_name=$(echo "$storage_line" | awk '{print $1}')
        storage_type=$(echo "$storage_line" | awk '{print $2}')
        
        # Prefer lvmthin for containers (more efficient)
        if [[ "$storage_type" == "lvmthin" ]]; then
            STORAGE=$storage_name
            msg_ok "Found container storage: $STORAGE (type: $storage_type)"
            msg_ok "Template storage: $TEMPLATE_STORAGE"
            return 0
        fi
    done < <(pvesm status)
    
    # If no lvmthin found, try zfspool (supports both templates and containers)
    if [ -z "$STORAGE" ]; then
        msg_info "No lvmthin storage found, searching for zfspool storage..."
        while IFS= read -r storage_line; do
            # Skip header line
            [[ "$storage_line" =~ ^NAME ]] && continue
            
            storage_name=$(echo "$storage_line" | awk '{print $1}')
            storage_type=$(echo "$storage_line" | awk '{print $2}')
            
            # zfspool supports both templates and containers
            if [[ "$storage_type" == "zfspool" ]] && [[ "$storage_name" != "$TEMPLATE_STORAGE" ]]; then
                STORAGE=$storage_name
                msg_ok "Found container storage: $STORAGE (type: $storage_type)"
                msg_ok "Template storage: $TEMPLATE_STORAGE"
                return 0
            fi
        done < <(pvesm status)
    fi
    
    # If still no container storage found, check if template storage supports containers
    # Some dir storage supports containers, but 'local' typically doesn't
    # Try to use template storage, but warn if it might not work
    if [ -z "$STORAGE" ]; then
        msg_info "No separate container storage found, checking if template storage supports containers..."
        # Check if template storage is zfspool (supports containers)
        template_type=$(pvesm status | grep "^$TEMPLATE_STORAGE " | awk '{print $2}')
        if [[ "$template_type" == "zfspool" ]]; then
            STORAGE=$TEMPLATE_STORAGE
            msg_ok "Using storage: $STORAGE (zfspool - supports both templates and containers)"
        else
            # For dir storage, we need to check if it supports containers
            # Most 'local' dir storage doesn't support containers, so we should error
            msg_error "No suitable container storage found!"
            msg_info ""
            msg_info "Template storage found: $TEMPLATE_STORAGE (type: $template_type)"
            msg_info "But this storage type does NOT support container directories."
            msg_info ""
            msg_info "You need storage that supports containers:"
            msg_info "  - lvmthin (recommended for containers)"
            msg_info "  - zfspool (supports both templates and containers)"
            msg_info "  - dir storage with container support (most 'local' dir storage does NOT)"
            msg_info ""
            msg_info "Available storages:"
            pvesm status
            msg_info ""
            msg_error "Please configure a storage pool that supports containers (lvmthin or zfspool)."
            exit 1
        fi
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
    
    echo ""
    msg_info "Storage Configuration:"
    echo "  Template storage: $TEMPLATE_STORAGE (for downloading templates)"
    echo "  Container storage: $STORAGE (for creating containers)"
    echo ""
    read -p "Container storage (press Enter for default: $STORAGE): " input_storage
    STORAGE=${input_storage:-$STORAGE}
    
    read -p "Template storage (press Enter for default: $TEMPLATE_STORAGE): " input_template_storage
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
    
    # Validate storage before attempting to create container
    container_storage_type=$(pvesm status | grep "^$STORAGE " | awk '{print $2}')
    if [[ "$container_storage_type" == "dir" ]] && [[ "$STORAGE" == "local" ]]; then
        msg_error "Container storage '$STORAGE' (type: $container_storage_type) does not support container directories!"
        msg_info "Please use lvmthin or zfspool storage for containers."
        msg_info "Available storages:"
        pvesm status
        exit 1
    fi
    
    msg_info "Using template: $TEMPLATE_STORAGE:vztmpl/$TEMPLATE"
    msg_info "Using container storage: $STORAGE (type: $container_storage_type)"
    
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
    
    # Use a more robust approach - download the single file and extract/create needed files
    pct exec $CTID -- bash -c "
        set -e
        cd /opt/ping-monitor
        
        # Download the main file
        if ! curl -fsSL https://raw.githubusercontent.com/halodine/network-ping-monitor/main/ping-monitor-nodejs.js -o ping-monitor-nodejs.js; then
            echo 'ERROR: Failed to download ping-monitor-nodejs.js' >&2
            exit 1
        fi
        
        # Extract server.js (everything before the package.json comment section, line 119)
        head -n 118 ping-monitor-nodejs.js > server.js
        
        # Create package.json
        cat > package.json << 'PKGEOF'
{
  \"name\": \"network-ping-monitor\",
  \"version\": \"1.0.0\",
  \"description\": \"Real-time network ping monitoring tool\",
  \"main\": \"server.js\",
  \"scripts\": {
    \"start\": \"node server.js\"
  },
  \"dependencies\": {
    \"express\": \"^4.18.2\",
    \"ws\": \"^8.14.2\"
  }
}
PKGEOF
        
        # Create public/index.html
        cat > public/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Network Ping Monitor</title>
  <script src=\"https://cdn.tailwindcss.com\"></script>
  <style>
    .grid-15 { display: grid; grid-template-columns: repeat(15, minmax(0, 1fr)); }
  </style>
</head>
<body class=\"bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 min-h-screen\">
  <div id=\"app\" class=\"p-8\"></div>
  <script src=\"app.js\"></script>
</body>
</html>
HTMLEOF
        
        # Extract app.js from the comments (lines 168-390, skip first and last line which are /* and */)
        sed -n '168,390p' ping-monitor-nodejs.js | sed '1s|^/\*||' | sed '$s|\*/$||' > public/app.js 2>/dev/null || {
            echo 'WARNING: Could not extract app.js from comments, creating basic version' >&2
            # Fallback: create a basic working version
            cat > public/app.js << 'APPEOF'
let ws = null;
let networks = [];
let scanning = false;

function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(\`\${protocol}//\${window.location.host}\`);
  ws.onopen = () => console.log('Connected');
  ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    if (data.type === 'progress') updateProgress(data);
    else if (data.type === 'complete') updateNetworkResults(data);
  };
  ws.onclose = () => setTimeout(connectWebSocket, 3000);
}

function loadNetworks() {
  const saved = localStorage.getItem('networks');
  networks = saved ? JSON.parse(saved) : [{ id: 1, base: '192.168.50', hosts: Array(255).fill(null).map(() => ({ online: false, latency: 0 })), lastScan: 'Never' }];
}

function saveNetworks() {
  localStorage.setItem('networks', JSON.stringify(networks));
}

function updateProgress(data) {
  const network = networks.find(n => n.base === data.baseIp);
  if (network) {
    data.results.forEach(result => {
      network.hosts[result.index] = { online: result.online, latency: result.latency };
    });
    render();
  }
}

function updateNetworkResults(data) {
  const network = networks.find(n => n.base === data.baseIp);
  if (network) {
    data.results.forEach(result => {
      network.hosts[result.index] = { online: result.online, latency: result.latency };
    });
    network.lastScan = new Date(data.timestamp).toLocaleTimeString();
    saveNetworks();
    scanning = false;
    render();
  }
}

function scanNetworks() {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    alert('Not connected to server');
    return;
  }
  scanning = true;
  networks.forEach(n => n.lastScan = 'Scanning...');
  render();
  ws.send(JSON.stringify({ type: 'scan', networks: networks.map(n => ({ base: n.base })) }));
}

function addNetwork(base) {
  if (!base.trim()) return;
  networks.push({
    id: Date.now(),
    base: base,
    hosts: Array(255).fill(null).map(() => ({ online: false, latency: 0 })),
    lastScan: 'Never'
  });
  saveNetworks();
  render();
}

function removeNetwork(id) {
  networks = networks.filter(n => n.id !== id);
  saveNetworks();
  render();
}

function render() {
  const app = document.getElementById('app');
  app.innerHTML = \`
    <div class=\"max-w-7xl mx-auto\">
      <h1 class=\"text-4xl font-bold text-white mb-8\">Network Ping Monitor</h1>
      <div class=\"mb-6\">
        <input type=\"text\" id=\"newNetwork\" placeholder=\"e.g., 192.168.1\" class=\"px-4 py-2 bg-slate-900 border border-slate-600 rounded text-white\" onkeypress=\"if(event.key==='Enter') addNetwork(document.getElementById('newNetwork').value); document.getElementById('newNetwork').value='';\">
        <button onclick=\"addNetwork(document.getElementById('newNetwork').value); document.getElementById('newNetwork').value='';\" class=\"px-6 py-2 bg-green-600 text-white rounded ml-2\">Add Network</button>
        <button onclick=\"scanNetworks()\" class=\"px-6 py-2 bg-blue-600 text-white rounded ml-2\" \${scanning ? 'disabled' : ''}>Scan Now</button>
      </div>
      \${networks.map(n => \`
        <div class=\"bg-slate-800 rounded p-6 mb-4\">
          <h2 class=\"text-2xl text-white mb-4\">\${n.base}.1-255</h2>
          <div class=\"grid-15 gap-1\">
            \${n.hosts.map((h, idx) => \`<div class=\"aspect-square rounded \${h.online ? 'bg-green-500 border-2 border-solid border-green-500' : 'bg-red-500/30 border-2 border-dashed border-red-500'}\" title=\"\${n.base}.\${idx+1}\${h.online ? ' - ' + h.latency + 'ms' : ''}\">\${idx+1}</div>\`).join('')}
          </div>
          <div class=\"mt-4 text-sm text-white\">
            Online: \${n.hosts.filter(h => h.online).length} | Offline: \${n.hosts.filter(h => !h.online).length} | Last scan: \${n.lastScan}
          </div>
        </div>
      \`).join('')}
    </div>
  \`;
}

loadNetworks();
connectWebSocket();
render();
APPEOF
        }
        
        # Clean up
        rm -f ping-monitor-nodejs.js
        
        # Install npm packages
        if ! npm install --silent 2>&1; then
            echo 'ERROR: Failed to install npm packages' >&2
            exit 1
        fi
    " || {
        msg_error "Failed to download or configure application files"
        exit 1
    }
    
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

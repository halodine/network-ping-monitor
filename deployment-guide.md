# Network Ping Monitor - Proxmox LXC Deployment Guide

## Step 1: Create LXC Container in Proxmox

1. In Proxmox web UI, click **Create CT**
2. Configure the container:
   - **CT ID**: Choose available ID (e.g., 100)
   - **Hostname**: `ping-monitor`
   - **Password**: Set root password
   - **Template**: Ubuntu 22.04 (or Debian 12)
   - **Disk**: 4GB is plenty
   - **CPU**: 1 core
   - **Memory**: 512MB RAM, 512MB Swap
   - **Network**: Bridge, DHCP or static IP
3. Click **Create**
4. Start the container

## Step 2: Access Container and Install Dependencies

SSH into your Proxmox host, then enter the container:

```bash
pct enter 100  # Replace 100 with your CT ID
```

Update and install Node.js:

```bash
apt update
apt upgrade -y
apt install -y curl

# Install Node.js 20.x (LTS)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Verify installation
node --version
npm --version
```

## Step 3: Create Application Directory

```bash
mkdir -p /opt/ping-monitor
cd /opt/ping-monitor
```

## Step 4: Create Application Files

### Create package.json

```bash
cat > package.json << 'EOF'
{
  "name": "network-ping-monitor",
  "version": "1.0.0",
  "description": "Real-time network ping monitoring tool",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "ws": "^8.14.2"
  }
}
EOF
```

### Create server.js

Copy the entire server.js code from the previous artifact into this file:

```bash
nano server.js
# Paste the server.js code, then Ctrl+X, Y, Enter
```

### Create public directory and files

```bash
mkdir -p public
cd public
```

Create **index.html**:

```bash
cat > index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Network Ping Monitor</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    .grid-15 { display: grid; grid-template-columns: repeat(15, minmax(0, 1fr)); }
  </style>
</head>
<body class="bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 min-h-screen">
  <div id="app" class="p-8"></div>
  <script src="app.js"></script>
</body>
</html>
EOF
```

Create **app.js** (copy from the artifact comments section)

```bash
nano app.js
# Paste the app.js code from the artifact
```

## Step 5: Install Node Modules

```bash
cd /opt/ping-monitor
npm install
```

## Step 6: Test the Application

```bash
node server.js
```

You should see: `Network Ping Monitor running on port 3000`

Test by visiting: `http://YOUR_CONTAINER_IP:3000`

Press Ctrl+C to stop.

## Step 7: Create systemd Service (Auto-start)

```bash
cat > /etc/systemd/system/ping-monitor.service << 'EOF'
[Unit]
Description=Network Ping Monitor
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ping-monitor
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

Enable and start the service:

```bash
systemctl daemon-reload
systemctl enable ping-monitor
systemctl start ping-monitor
systemctl status ping-monitor
```

## Step 8: Configure Firewall (if needed)

```bash
# If using ufw
apt install -y ufw
ufw allow 3000/tcp
ufw enable
```

## Step 9: Access Your Monitor

Open your browser and navigate to:

```
http://YOUR_CONTAINER_IP:3000
```

## Optional: Use Different Port

To use port 80 (standard HTTP):

1. Edit the service file:
```bash
nano /etc/systemd/system/ping-monitor.service
```

2. Add environment variable:
```
Environment=PORT=80
```

3. Restart:
```bash
systemctl daemon-reload
systemctl restart ping-monitor
```

## Management Commands

```bash
# View logs
journalctl -u ping-monitor -f

# Restart service
systemctl restart ping-monitor

# Stop service
systemctl stop ping-monitor

# Check status
systemctl status ping-monitor
```

## Troubleshooting

**Can't ping hosts?**
- Ensure the container has network access
- Some hosts may have ICMP blocked by firewall
- Try pinging from container CLI: `ping 192.168.1.1`

**Port already in use?**
- Check what's using the port: `netstat -tulpn | grep 3000`
- Change PORT in service file

**Service won't start?**
- Check logs: `journalctl -u ping-monitor -n 50`
- Verify Node.js installed: `node --version`
- Check file permissions in `/opt/ping-monitor`

## Backup

To backup your networks configuration:
- Networks are stored in browser localStorage
- To export: Open browser console and run:
  ```javascript
  console.log(localStorage.getItem('networks'))
  ```
- Copy the output and save it

## Security Notes

- This tool sends ICMP packets - ensure your security policies allow this
- By default, accessible from any IP on your network
- Consider using a reverse proxy (nginx) for HTTPS
- Change default port if exposing outside your local network

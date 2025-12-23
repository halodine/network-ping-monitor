```markdown
# Network Ping Monitor

A real-time network monitoring tool that displays the ping status of up to 255 hosts per subnet in an intuitive 15×17 grid layout.

![Network Ping Monitor](https://via.placeholder.com/800x400?text=Add+Screenshot+Here)

## Features

- 🎯 **Real-time Monitoring** - Scan entire /24 subnets (255 hosts)
- 📊 **Visual Grid Layout** - 15×17 responsive grid with color-coded status
- ♿ **Accessibility** - Solid borders for online, dashed for offline (colorblind-friendly)
- 💾 **Persistent Storage** - Networks saved in browser localStorage
- ⚡ **WebSocket Updates** - Live progress during scans
- 🐳 **Lightweight** - Runs on minimal resources (512MB RAM)

## License

This project is released under CC0 (Public Domain).

### AI Generation Notice
This software was created with assistance from Claude AI (Anthropic). 
No copyright is claimed on any portion. Use freely.

## Quick Install on Proxmox

Run this single command on your Proxmox host:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/YOUR_USERNAME/network-ping-monitor/main/install.sh)"
```

The script will:
1. Create an LXC container
2. Install Node.js and dependencies
3. Download and configure the application
4. Set up auto-start on boot
5. Display access URL

### Manual Installation

#### Prerequisites
- Ubuntu/Debian system
- Node.js 18+ 
- Network access with ICMP (ping) capability

#### Steps

1. Clone the repository:
```bash
git clone https://github.com/YOUR_USERNAME/network-ping-monitor.git
cd network-ping-monitor
```

2. Install dependencies:
```bash
npm install
```

3. Start the server:
```bash
node server.js
```

4. Access the web interface:
```
http://localhost:3000
```

#### Run as a Service (systemd)

```bash
sudo cp ping-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ping-monitor
sudo systemctl start ping-monitor
```

## Usage

1. **Add a Network**: Enter a network prefix (e.g., `192.168.1`) and click "Add Network"
2. **Scan**: Click "Scan Now" to ping all hosts on all configured networks
3. **View Results**: 
   - Green solid border = Online
   - Red dashed border = Offline
   - Hover over any box to see IP and latency
4. **Networks Persist**: Your configured networks are saved automatically

## Configuration

### Change Port

Set the `PORT` environment variable:

```bash
PORT=8080 node server.js
```

Or in systemd service:
```
Environment=PORT=8080
```

### Performance Tuning

Edit `server.js` to adjust batch size (default: 50 hosts at a time):

```javascript
const batchSize = 50; // Increase for faster scans, decrease for slower networks
```

## Architecture

- **Backend**: Node.js + Express + WebSocket
- **Frontend**: Vanilla JavaScript + Tailwind CSS
- **Ping Method**: Native `ping` command via child_process
- **Real-time**: WebSocket for live scan progress

## Browser Compatibility

- Chrome/Edge 90+
- Firefox 88+
- Safari 14+

## Troubleshooting

### Hosts not responding to ping?
- Some devices block ICMP by default
- Check firewall rules on target hosts
- Verify network connectivity from the container/server

### Service won't start?
```bash
# Check logs
journalctl -u ping-monitor -f

# Verify Node.js
node --version

# Check port availability
netstat -tulpn | grep 3000
```

### Can't access web interface?
- Ensure firewall allows incoming connections on the port
- Check the container/server IP: `ip addr`
- Verify service is running: `systemctl status ping-monitor`

## Development

### Local Development

```bash
npm install
node server.js
```

Visit `http://localhost:3000`


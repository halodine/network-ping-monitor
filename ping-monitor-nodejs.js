// server.js - Main application file
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const { exec } = require('child_process');
const { promisify } = require('util');
const path = require('path');

const execAsync = promisify(exec);
const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

const PORT = process.env.PORT || 3000;

// Serve static files
app.use(express.static('public'));
app.use(express.json());

// Store active scan state
let activeScans = new Map();

// Ping a single host
async function pingHost(ip) {
  try {
    const { stdout } = await execAsync(`ping -c 1 -W 1 ${ip}`);
    const match = stdout.match(/time=([\d.]+)/);
    const latency = match ? parseFloat(match[1]) : 0;
    return { online: true, latency: Math.round(latency) };
  } catch (error) {
    return { online: false, latency: 0 };
  }
}

// Scan entire network
async function scanNetwork(baseIp, ws) {
  const results = [];
  const batchSize = 50; // Scan 50 hosts at a time
  
  for (let i = 1; i <= 255; i += batchSize) {
    const batch = [];
    const end = Math.min(i + batchSize - 1, 255);
    
    for (let j = i; j <= end; j++) {
      const ip = `${baseIp}.${j}`;
      batch.push(pingHost(ip).then(result => ({ index: j - 1, ...result })));
    }
    
    const batchResults = await Promise.all(batch);
    results.push(...batchResults);
    
    // Send progress update
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: 'progress',
        baseIp,
        progress: Math.round((end / 255) * 100),
        results: batchResults
      }));
    }
  }
  
  return results;
}

// WebSocket connection handler
wss.on('connection', (ws) => {
  console.log('Client connected');
  
  ws.on('message', async (message) => {
    try {
      const data = JSON.parse(message);
      
      if (data.type === 'scan') {
        const { networks } = data;
        
        for (const network of networks) {
          const { base } = network;
          console.log(`Scanning network: ${base}`);
          
          const results = await scanNetwork(base, ws);
          
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({
              type: 'complete',
              baseIp: base,
              results,
              timestamp: new Date().toISOString()
            }));
          }
        }
      }
    } catch (error) {
      console.error('WebSocket error:', error);
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          type: 'error',
          message: error.message
        }));
      }
    }
  });
  
  ws.on('close', () => {
    console.log('Client disconnected');
  });
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Network Ping Monitor running on port ${PORT}`);
  console.log(`Access at http://localhost:${PORT}`);
});

// =============================================================================
// package.json
// =============================================================================
/*
{
  "name": "network-ping-monitor",
  "version": "1.0.0",
  "description": "Real-time network ping monitoring tool",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "ws": "^8.14.2"
  },
  "devDependencies": {
    "nodemon": "^3.0.1"
  }
}
*/

// =============================================================================
// public/index.html
// =============================================================================
/*
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
*/

// =============================================================================
// public/app.js - Frontend JavaScript
// =============================================================================
/*
let ws = null;
let networks = [];
let scanning = false;

function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${protocol}//${window.location.host}`);
  
  ws.onopen = () => {
    console.log('Connected to server');
  };
  
  ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    
    if (data.type === 'progress') {
      updateProgress(data);
    } else if (data.type === 'complete') {
      updateNetworkResults(data);
    } else if (data.type === 'error') {
      console.error('Scan error:', data.message);
      scanning = false;
      render();
    }
  };
  
  ws.onclose = () => {
    console.log('Disconnected from server');
    setTimeout(connectWebSocket, 3000);
  };
}

function loadNetworks() {
  const saved = localStorage.getItem('networks');
  if (saved) {
    networks = JSON.parse(saved);
  } else {
    networks = [
      { id: 1, base: '192.168.50', hosts: Array(255).fill(null).map(() => ({ online: false, latency: 0 })), lastScan: 'Never' }
    ];
  }
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
    
    // Check if all networks are done
    const allDone = networks.every(n => n.lastScan !== 'Scanning...');
    if (allDone) {
      scanning = false;
    }
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
  
  ws.send(JSON.stringify({
    type: 'scan',
    networks: networks.map(n => ({ base: n.base }))
  }));
}

function addNetwork(base) {
  if (!base.trim()) return;
  
  const newNet = {
    id: Date.now(),
    base: base,
    hosts: Array(255).fill(null).map(() => ({ online: false, latency: 0 })),
    lastScan: 'Never'
  };
  
  networks.push(newNet);
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
  
  const html = `
    <div class="max-w-7xl mx-auto">
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 class="text-4xl font-bold text-white mb-2">Network Ping Monitor</h1>
          <p class="text-slate-400">Real-time network host availability monitoring</p>
        </div>
        <button 
          onclick="scanNetworks()" 
          ${scanning ? 'disabled' : ''}
          class="flex items-center gap-2 px-6 py-3 bg-blue-600 hover:bg-blue-700 disabled:bg-slate-600 text-white rounded-lg transition-colors"
        >
          <svg class="w-5 h-5 ${scanning ? 'animate-spin' : ''}" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
          </svg>
          ${scanning ? 'Scanning...' : 'Scan Now'}
        </button>
      </div>
      
      <div class="bg-slate-800/50 backdrop-blur rounded-lg p-6 mb-6 border border-slate-700">
        <div class="flex gap-3">
          <input 
            type="text" 
            id="newNetwork" 
            placeholder="e.g., 192.168.1"
            class="flex-1 px-4 py-2 bg-slate-900 border border-slate-600 rounded-lg text-white placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-blue-500"
            onkeypress="if(event.key==='Enter') { addNetwork(document.getElementById('newNetwork').value); document.getElementById('newNetwork').value=''; }"
          />
          <button 
            onclick="addNetwork(document.getElementById('newNetwork').value); document.getElementById('newNetwork').value='';"
            class="px-6 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg transition-colors flex items-center gap-2"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
            </svg>
            Add Network
          </button>
        </div>
      </div>
      
      <div class="space-y-6">
        ${networks.map(network => `
          <div class="bg-slate-800/50 backdrop-blur rounded-lg p-6 border border-slate-700 hover:border-slate-600 transition-colors">
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center gap-3">
                <svg class="w-6 h-6 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
                </svg>
                <h2 class="text-2xl font-mono font-bold text-white">${network.base}.1-255</h2>
                <span class="text-sm text-slate-400 ml-4">Last scan: ${network.lastScan}</span>
              </div>
              <button 
                onclick="removeNetwork(${network.id})"
                class="p-2 text-slate-400 hover:text-red-400 hover:bg-slate-700 rounded-lg transition-colors"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                </svg>
              </button>
            </div>
            
            <div class="grid-15 gap-1 mb-4">
              ${network.hosts.map((host, idx) => `
                <div class="relative group">
                  <div class="aspect-square rounded flex items-center justify-center transition-all text-xs font-mono ${
                    host.online
                      ? 'bg-green-500/30 border-2 border-solid border-green-500 hover:bg-green-500/40 text-green-100'
                      : 'bg-red-500/30 border-2 border-dashed border-red-500 hover:bg-red-500/40 text-red-300'
                  }">
                    ${idx + 1}
                  </div>
                  <div class="absolute bottom-full left-1/2 transform -translate-x-1/2 mb-2 px-2 py-1 bg-slate-900 text-white text-xs rounded opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none whitespace-nowrap border border-slate-700 z-10">
                    ${network.base}.${idx + 1}${host.online ? ` - ${host.latency}ms` : ''}
                  </div>
                </div>
              `).join('')}
            </div>
            
            <div class="flex items-center justify-between text-sm">
              <div class="flex gap-6">
                <span class="text-green-400">● Online: ${network.hosts.filter(h => h.online).length}</span>
                <span class="text-red-400">● Offline: ${network.hosts.filter(h => !h.online).length}</span>
              </div>
            </div>
          </div>
        `).join('')}
      </div>
      
      ${networks.length === 0 ? `
        <div class="text-center py-16 text-slate-400">
          <svg class="w-12 h-12 mx-auto mb-4 opacity-50" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
          </svg>
          <p class="text-lg">No networks added yet</p>
          <p class="text-sm mt-2">Add a network subnet above to start monitoring</p>
        </div>
      ` : ''}
    </div>
  `;
  
  app.innerHTML = html;
}

// Initialize
loadNetworks();
connectWebSocket();
render();
*/

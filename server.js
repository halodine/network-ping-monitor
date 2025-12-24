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


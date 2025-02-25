const express = require('express');
const os = require('os');
const app = express();
const port = 3000;

app.get('/', (req, res) => {
    const localIP = getLocalIP();
    res.send(`
        <html>
            <body>
                <h1>Node.js App</h1>
                <p>IP Address: ${localIP}</p>
                <button onclick="fetch('/shutdown', { method: 'POST' })">Shutdown</button>
            </body>
        </html>
    `);
});

app.post('/shutdown', (req, res) => {
    res.send('Shutting down...');
    process.exit();
});

function getLocalIP() {
    const interfaces = os.networkInterfaces();
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name]) {
            if (iface.family === 'IPv4' && !iface.internal) {
                return iface.address;
            }
        }
    }
    return '127.0.0.1';
}

app.listen(port, () => {
    const localIP = getLocalIP();
    console.log(`App listening at http://${localIP}:${port}`);
}); 
// A WebSocket server over TLS that asks for a client certificate, for the engine's tests.
// Usage: node wss-test-server.js KEY.pem CERT.pem
// Prints "PORT n" once listening. On connecting, it sends one message naming the client
// certificate it was shown ("client: NAME", or "client: none"), then echoes messages.
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');

const server = https.createServer({
  key: fs.readFileSync(process.argv[2]),
  cert: fs.readFileSync(process.argv[3]),
  requestCert: true,
  rejectUnauthorized: false,
});

const frame = (text) => {
  const payload = Buffer.from(text);
  return Buffer.concat([Buffer.from([0x81, payload.length]), payload]);
};

server.on('upgrade', (request, socket) => {
  const accept = crypto.createHash('sha1')
    .update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const peer = socket.getPeerCertificate();
  socket.write(frame(`client: ${peer && peer.subject ? peer.subject.CN : 'none'}`));
  socket.on('data', (data) => {
    // Short masked text frames only, which is all the tests send.
    if ((data[0] & 0x0f) !== 1) return;
    const length = data[1] & 0x7f;
    const mask = data.subarray(2, 6);
    const text = Buffer.from(data.subarray(6, 6 + length).map((byte, i) => byte ^ mask[i % 4]));
    socket.write(frame(`echo: ${text}`));
  });
  socket.on('error', () => {});
});

server.listen(0, '127.0.0.1', () => console.log(`PORT ${server.address().port}`));

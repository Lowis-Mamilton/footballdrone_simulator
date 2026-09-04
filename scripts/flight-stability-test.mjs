import assert from 'node:assert/strict';

const baseUrl = process.env.SIM_HTTP_URL || 'http://127.0.0.1:41730';
const token = process.env.SIM_PAIRING_TOKEN || '0123456789abcdef0123456789abcdef';
const durationMs = Number(process.env.SIM_STABILITY_DURATION_MS || 2500);

const config = await fetch(`${baseUrl}/config.json`).then(response => response.json());
const statuses = [];

await new Promise((resolve, reject) => {
  const socket = new WebSocket(`ws://127.0.0.1:${config.ws_port}`);
  let sequence = 0;
  let sendTimer;
  const timeout = setTimeout(() => reject(new Error('Stability test timed out')), durationMs + 1500);

  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({ type: 'hello', protocol_version: 1, token }));
  });
  socket.addEventListener('message', async event => {
    const raw = typeof event.data === 'string' ? event.data : await event.data.text();
    const message = JSON.parse(raw);
    if (message.type === 'hello_ack') {
      sendTimer = setInterval(() => {
        socket.send(JSON.stringify({
          type: 'input',
          protocol_version: 1,
          session_id: message.session_id,
          sequence,
          client_time_ms: Math.round(performance.now()),
          axes: { throttle: sequence === 0 ? 0 : 0.55, yaw: 0, pitch: 0, roll: 0 },
          buttons: { arm: sequence === 0, reset: false, turtle: false },
          flight_mode: 'angle'
        }));
        sequence += 1;
      }, 1000 / 60);
      setTimeout(() => {
        clearTimeout(timeout);
        clearInterval(sendTimer);
        socket.close();
        resolve();
      }, durationMs);
    } else if (message.type === 'status') {
      statuses.push(message);
    }
  });
  socket.addEventListener('error', () => reject(new Error('WebSocket connection failed')));
});

assert.ok(statuses.length > 0, 'Expected simulator status samples');
const peakAltitude = Math.max(...statuses.map(status => status.altitude_m));
assert.ok(
  peakAltitude >= 0.15,
  `Expected a gentle 55% throttle takeoff, but peak altitude was ${peakAltitude.toFixed(2)} m`
);
assert.ok(
  peakAltitude <= 1.5,
  `Expected a controllable takeoff below 1.5 m, but peak altitude was ${peakAltitude.toFixed(2)} m`
);
console.log(`PASS: gentle takeoff remained controllable (peak ${peakAltitude.toFixed(2)} m)`);

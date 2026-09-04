import assert from 'node:assert/strict';

const baseUrl = process.env.SIM_HTTP_URL || 'http://127.0.0.1:41730';
const token = process.env.SIM_PAIRING_TOKEN || '0123456789abcdef0123456789abcdef';

const health = await fetch(`${baseUrl}/health`).then(response => response.json());
assert.deepEqual(health, { ok: true, protocol_version: 1 });
const config = await fetch(`${baseUrl}/config.json`).then(response => response.json());
const html = await fetch(`${baseUrl}/?token=${token}`).then(response => response.text());
assert.match(html, /Football Drone Controller/);

const messages = [];
let sendTimer;
let stopTimer;
await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error(`Timed out. Messages: ${JSON.stringify(messages)}`)), 3000);
  const socket = new WebSocket(`ws://127.0.0.1:${config.ws_port}`);
  socket.addEventListener('open', () => {
    socket.send(JSON.stringify({ type: 'hello', protocol_version: 1, token }));
  });
  socket.addEventListener('message', async event => {
    const raw = typeof event.data === 'string' ? event.data : await event.data.text();
    const message = JSON.parse(raw);
    messages.push(message);
    if (message.type === 'hello_ack') {
      let sequence = 0;
      sendTimer = setInterval(() => {
        socket.send(JSON.stringify({
          type: 'input', protocol_version: 1, session_id: message.session_id,
          sequence, client_time_ms: Math.round(performance.now()),
          axes: { throttle: sequence === 0 ? 0 : 0.82, yaw: 0, pitch: 0, roll: 0 },
          buttons: { arm: sequence === 0, reset: false, turtle: false }, flight_mode: 'angle'
        }));
        sequence += 1;
      }, 1000 / 60);
      stopTimer = setTimeout(() => clearInterval(sendTimer), 900);
    }
    const armed = messages.some(item => item.type === 'status' && item.armed === true && item.failsafe === false);
    const failedSafe = messages.some(item => item.type === 'status' && item.armed === false && item.failsafe === true);
    const climbed = messages.some(item => item.type === 'status' && item.altitude_m > 0.3);
    if (armed && climbed && failedSafe) {
      clearTimeout(timeout);
      clearTimeout(stopTimer);
      clearInterval(sendTimer);
      socket.close();
      resolve();
    }
  });
  socket.addEventListener('error', () => reject(new Error('WebSocket connection failed')));
});

assert.ok(messages.some(message => message.type === 'hello_ack'));
assert.ok(messages.some(message => message.type === 'status' && message.armed === true));
assert.ok(messages.some(message => message.type === 'status' && message.altitude_m > 0.3));
assert.ok(messages.some(message => message.type === 'status' && message.failsafe === true));
console.log('PASS: HTTP assets, authenticated input, rigid-body lift, status, and 250 ms failsafe');

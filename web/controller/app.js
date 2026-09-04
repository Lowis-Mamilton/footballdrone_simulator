(() => {
  'use strict';
  const PROTOCOL_VERSION = 1;
  const SEND_INTERVAL_MS = 1000 / 60;
  const params = new URLSearchParams(location.search);
  const token = params.get('token') || '';
  const state = {
    socket: null, sessionId: '', sequence: 0, flightMode: 'angle', armed: false,
    axes: { throttle: 0, yaw: 0, pitch: 0, roll: 0 },
    physical: { left_x: 0, left_y: 1, right_x: 0, right_y: 0 },
    inputConfig: { mode: 2, mapping: { throttle: 'left_y', yaw: 'left_x', pitch: 'right_y', roll: 'right_x' } },
    inputConfigSignature: '',
    buttons: { arm: false, reset: false, turtle: false }, reconnectMs: 500,
    lastPing: 0, latency: null
  };
  const $ = id => document.getElementById(id);
  const connection = $('connection');
  const message = $('message');

  class VirtualStick {
    constructor(zoneId, knobId, onValue, holdX = false, holdY = false) {
      this.zone = $(zoneId); this.knob = $(knobId); this.onValue = onValue;
      this.holdX = holdX; this.holdY = holdY; this.pointerId = null; this.x = holdX ? 1 : 0; this.y = holdY ? 1 : 0;
      this.zone.addEventListener('pointerdown', event => this.start(event));
      this.zone.addEventListener('pointermove', event => this.move(event));
      this.zone.addEventListener('pointerup', event => this.end(event));
      this.zone.addEventListener('pointercancel', event => this.end(event));
      this.render();
    }
    start(event) { if (this.pointerId !== null) return; this.pointerId = event.pointerId; this.zone.setPointerCapture(event.pointerId); this.update(event); }
    move(event) { if (event.pointerId === this.pointerId) this.update(event); }
    end(event) { if (event.pointerId !== this.pointerId) return; this.pointerId = null; if (!this.holdX) this.x = 0; if (!this.holdY) this.y = 0; this.emit(); }
    update(event) {
      const base = this.knob.parentElement.getBoundingClientRect();
      const radius = base.width / 2; let x = (event.clientX - (base.left + radius)) / radius; let y = (event.clientY - (base.top + radius)) / radius;
      const magnitude = Math.hypot(x, y); if (magnitude > 1) { x /= magnitude; y /= magnitude; }
      this.x = x; this.y = y; this.emit();
    }
    emit() { this.render(); this.onValue(this.x, this.y); }
    render() { this.knob.style.transform = `translate(${this.x * 70}%,${this.y * 70}%)`; }
  }

  const leftStick = new VirtualStick('leftZone', 'leftStick', (x, y) => { state.physical.left_x = x; state.physical.left_y = y; mapSticks(); }, false, true);
  const rightStick = new VirtualStick('rightZone', 'rightStick', (x, y) => { state.physical.right_x = x; state.physical.right_y = y; mapSticks(); });

  $('armButton').addEventListener('click', () => pulse('arm'));
  $('resetButton').addEventListener('click', () => pulse('reset'));
  $('turtleButton').addEventListener('click', () => pulse('turtle'));
  $('modeButton').addEventListener('click', () => { state.flightMode = state.flightMode === 'angle' ? 'acro' : 'angle'; $('modeReadout').textContent = state.flightMode.toUpperCase(); });

  function pulse(button) { state.buttons[button] = true; setTimeout(() => { state.buttons[button] = false; }, 100); if (navigator.vibrate) navigator.vibrate(25); }
  function mapSticks() {
    const mapping = state.inputConfig.mapping || { throttle: 'left_y', yaw: 'left_x', pitch: 'right_y', roll: 'right_x' };
    for (const channel of ['throttle', 'yaw', 'pitch', 'roll']) {
      const source = mapping[channel]; const raw = state.physical[source] ?? 0;
      state.axes[channel] = channel === 'throttle' ? clamp((1 - raw) / 2, 0, 1) : deadzone(source.endsWith('_y') ? -raw : raw);
    }
  }
  function applyInputConfig(config) {
    if (!config) return;
    const signature = JSON.stringify(config);
    if (signature === state.inputConfigSignature) return;
    state.inputConfigSignature = signature;
    state.inputConfig = config;
    const mapping = config.mode === 1
      ? { throttle: 'right_y', yaw: 'left_x', pitch: 'left_y', roll: 'right_x' }
      : config.mode === 3 ? config.mapping : { throttle: 'left_y', yaw: 'left_x', pitch: 'right_y', roll: 'right_x' };
    state.inputConfig.mapping = mapping;
    leftStick.holdX = mapping.throttle === 'left_x'; leftStick.holdY = mapping.throttle === 'left_y';
    rightStick.holdX = mapping.throttle === 'right_x'; rightStick.holdY = mapping.throttle === 'right_y';
    state.physical = { left_x: 0, left_y: 0, right_x: 0, right_y: 0 };
    state.physical[mapping.throttle] = 1;
    leftStick.x = state.physical.left_x; leftStick.y = state.physical.left_y; leftStick.render();
    rightStick.x = state.physical.right_x; rightStick.y = state.physical.right_y; rightStick.render();
    document.querySelector('#leftZone .axis-label.top').textContent = channelFor('left_y').toUpperCase();
    document.querySelector('#leftZone .axis-label.side').textContent = channelFor('left_x').toUpperCase();
    document.querySelector('#rightZone .axis-label.top').textContent = channelFor('right_y').toUpperCase();
    document.querySelector('#rightZone .axis-label.side').textContent = channelFor('right_x').toUpperCase();
    mapSticks();
  }
  function channelFor(source) { return Object.entries(state.inputConfig.mapping).find(([, value]) => value === source)?.[0] || source; }
  function deadzone(value) { const dz = .03; return Math.abs(value) < dz ? 0 : Math.sign(value) * (Math.abs(value) - dz) / (1 - dz); }
  function clamp(value, low, high) { return Math.max(low, Math.min(high, value)); }
  function setConnection(ok, text) { connection.classList.toggle('connected', ok); connection.classList.toggle('disconnected', !ok); connection.querySelector('span').textContent = text; }

  async function connect() {
    if (!token) { setConnection(false, 'No pairing token'); message.textContent = 'Scan the QR code shown by the simulator.'; return; }
    try {
      const config = await fetch('/config.json', { cache: 'no-store' }).then(response => response.json());
      const socket = new WebSocket(`ws://${location.hostname}:${config.ws_port}`);
      state.socket = socket;
      socket.addEventListener('open', () => socket.send(JSON.stringify({ type: 'hello', protocol_version: PROTOCOL_VERSION, token })));
      socket.addEventListener('message', event => receive(JSON.parse(event.data)));
      socket.addEventListener('close', () => { setConnection(false, 'Disconnected'); state.sessionId = ''; setTimeout(connect, state.reconnectMs); state.reconnectMs = Math.min(5000, state.reconnectMs * 1.5); });
      socket.addEventListener('error', () => setConnection(false, 'Connection error'));
    } catch { setConnection(false, 'Simulator unavailable'); setTimeout(connect, state.reconnectMs); }
  }

  function receive(data) {
    if (data.type === 'hello_ack') { state.sessionId = data.session_id; state.reconnectMs = 500; setConnection(true, 'Connected'); message.textContent = 'Disarmed — tap ARM when ready.'; }
    if (data.type === 'status') {
      state.armed = Boolean(data.armed); $('armButton').classList.toggle('armed', state.armed); $('armButton').textContent = state.armed ? 'DISARM' : 'ARM';
      $('modeReadout').textContent = String(data.flight_mode || state.flightMode).toUpperCase();
      applyInputConfig(data.input_config);
      message.textContent = data.pause_reason || data.lesson_objective || (state.armed ? 'Live control' : 'Disarmed');
    }
    if (data.type === 'pong') { state.latency = Math.round(performance.now() - data.client_time_ms); $('latency').textContent = `${state.latency} ms RTT`; }
    if (data.type === 'error') { message.textContent = data.message; if (['invalid_token','controller_in_use','protocol_mismatch'].includes(data.code)) state.socket.close(); }
  }

  function sendInput() {
    if (!state.socket || state.socket.readyState !== WebSocket.OPEN || !state.sessionId) return;
    state.socket.send(JSON.stringify({ type: 'input', protocol_version: PROTOCOL_VERSION, session_id: state.sessionId, sequence: state.sequence++, client_time_ms: Math.round(performance.now()), axes: state.axes, buttons: state.buttons, flight_mode: state.flightMode }));
    if (performance.now() - state.lastPing > 1000) { state.lastPing = performance.now(); state.socket.send(JSON.stringify({ type: 'ping', client_time_ms: state.lastPing })); }
  }

  document.addEventListener('visibilitychange', () => {
    if (state.socket?.readyState !== WebSocket.OPEN) return;
    state.socket.send(JSON.stringify({ type: document.hidden ? 'background' : 'foreground' }));
  });
  window.addEventListener('pagehide', () => { if (state.socket?.readyState === WebSocket.OPEN) state.socket.send(JSON.stringify({ type: 'background' })); });
  setInterval(sendInput, SEND_INTERVAL_MS);
  connect();
})();

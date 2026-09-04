extends Node

signal connection_changed(connected: bool)
signal failsafe_triggered(reason: String)
signal command_received(command: StringName)

const PROTOCOL_VERSION := 1
const HTTP_PORT := 41730
const WS_PORT := 41731
const FAILSAFE_MS := 250
const STATUS_INTERVAL_MS := 100

var http := LocalHttpServer.new()
var websocket := BrowserWebSocketServer.new()
var session_token := ""
var session_id := ""
var pairing_url := ""
var local_address := "127.0.0.1"
var connected_peer := 0
var authenticated_peers: Dictionary = {}
var backgrounded_peers: Dictionary = {}
var latest_frame := DroneInputFrame.neutral()
var last_input_ms := 0
var last_sequence := -1
var previous_buttons := {"arm": false, "reset": false, "turtle": false}
var last_status_ms := 0
var failsafe_active := true
var status_provider: Callable
var startup_error := ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	rotate_session()
	_start_servers()

func _process(_delta: float) -> void:
	http.poll()
	websocket.poll()
	var now := Time.get_ticks_msec()
	if connected_peer != 0 and now - last_input_ms > FAILSAFE_MS and not failsafe_active:
		_activate_failsafe("Controller input timed out")
	if connected_peer != 0 and now - last_status_ms >= STATUS_INTERVAL_MS:
		_send_status(connected_peer)
		last_status_ms = now

func rotate_session() -> void:
	var crypto := Crypto.new()
	session_token = crypto.generate_random_bytes(16).hex_encode()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--pairing-token="):
			var requested := argument.trim_prefix("--pairing-token=").to_lower()
			if requested.length() == 32 and requested.is_valid_hex_number(false):
				session_token = requested
	session_id = crypto.generate_random_bytes(8).hex_encode()
	http.debug_token = session_token
	http.debug_session_id = session_id
	var addresses := private_addresses()
	local_address = addresses[0] if not addresses.is_empty() else "127.0.0.1"
	pairing_url = "http://%s:%d/?token=%s" % [local_address, http.port, session_token]

func private_addresses() -> PackedStringArray:
	var result := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.contains(":") or address.begins_with("127."):
			continue
		if _is_private_ipv4(address):
			result.append(address)
	return result

func select_address(address: String) -> void:
	if address in private_addresses():
		local_address = address
		pairing_url = "http://%s:%d/?token=%s" % [local_address, http.port, session_token]

func set_status_provider(provider: Callable) -> void:
	status_provider = provider

func get_input_frame() -> DroneInputFrame:
	if failsafe_active:
		return DroneInputFrame.neutral()
	return latest_frame

func is_controller_connected() -> bool:
	return connected_peer != 0 and not failsafe_active

func force_failsafe(reason: String) -> void:
	_activate_failsafe(reason)

func _start_servers() -> void:
	var ws_error := ERR_CANT_CREATE
	for candidate in range(WS_PORT, WS_PORT + 10):
		ws_error = websocket.start(candidate)
		if ws_error == OK:
			http.ws_port = candidate
			break
	if ws_error != OK:
		startup_error = "Could not start WebSocket control server."
		return
	var http_error := http.start(HTTP_PORT, http.ws_port)
	if http_error != OK:
		startup_error = "Could not start mobile controller web server."
		return
	rotate_session()
	websocket.text_received.connect(_on_text_received)
	websocket.peer_disconnected.connect(_on_peer_disconnected)
	if OS.is_debug_build():
		print("PAIRING_URL=", pairing_url)

func _on_text_received(peer_id: int, raw: String) -> void:
	var message: Variant = JSON.parse_string(raw)
	if not message is Dictionary:
		_send_error(peer_id, "invalid_json", "Message must be a JSON object.")
		return
	_handle_message(peer_id, message)

func _handle_message(peer_id: int, message: Dictionary) -> void:
	var message_type := String(message.get("type", ""))
	if message_type == "hello":
		_authenticate(peer_id, message)
		return
	if not authenticated_peers.has(peer_id):
		_send_error(peer_id, "not_authenticated", "Send a valid hello message first.")
		return
	if message_type == "input":
		_handle_input(peer_id, message)
	elif message_type == "background":
		backgrounded_peers[peer_id] = true
		_activate_failsafe("Controller moved to the background")
	elif message_type == "foreground":
		backgrounded_peers[peer_id] = false
		last_input_ms = Time.get_ticks_msec()
	elif message_type == "ping":
		_send(peer_id, {"type": "pong", "client_time_ms": int(message.get("client_time_ms", 0)), "server_time_ms": Time.get_ticks_msec()})
	else:
		_send_error(peer_id, "unknown_type", "Unknown message type.")

func _authenticate(peer_id: int, message: Dictionary) -> void:
	var peer_address := websocket.get_peer_address(peer_id)
	if peer_address != "127.0.0.1" and not _is_private_ipv4(peer_address):
		_send_error(peer_id, "non_private_network", "Controllers are accepted only from the local private network.")
		return
	if int(message.get("protocol_version", -1)) != PROTOCOL_VERSION:
		_send_error(peer_id, "protocol_mismatch", "Controller protocol is not supported.")
		return
	if not constant_time_equal(String(message.get("token", "")), session_token):
		_send_error(peer_id, "invalid_token", "Pairing code is invalid or expired.")
		return
	if connected_peer != 0 and connected_peer != peer_id:
		_send_error(peer_id, "controller_in_use", "Another controller is already connected.")
		return
	authenticated_peers[peer_id] = true
	backgrounded_peers[peer_id] = false
	connected_peer = peer_id
	last_input_ms = Time.get_ticks_msec()
	last_sequence = -1
	previous_buttons = {"arm": false, "reset": false, "turtle": false}
	failsafe_active = true
	_send(peer_id, {"type": "hello_ack", "protocol_version": PROTOCOL_VERSION, "session_id": session_id, "failsafe_ms": FAILSAFE_MS})
	connection_changed.emit(true)

func _handle_input(peer_id: int, message: Dictionary) -> void:
	if bool(backgrounded_peers.get(peer_id, false)):
		return
	if int(message.get("protocol_version", -1)) != PROTOCOL_VERSION or String(message.get("session_id", "")) != session_id:
		_send_error(peer_id, "invalid_session", "Reconnect using the current QR code.")
		return
	var sequence := int(message.get("sequence", -1))
	if sequence <= last_sequence:
		return
	last_sequence = sequence
	last_input_ms = Time.get_ticks_msec()
	latest_frame = DroneInputFrame.from_wire(message, last_input_ms)
	if latest_frame.reset_pressed and not previous_buttons.reset:
		command_received.emit(&"reset")
	if latest_frame.turtle_pressed and not previous_buttons.turtle:
		command_received.emit(&"turtle")
	if latest_frame.arm_pressed and not previous_buttons.arm:
		command_received.emit(&"toggle_arm")
	previous_buttons = {
		"arm": latest_frame.arm_pressed,
		"reset": latest_frame.reset_pressed,
		"turtle": latest_frame.turtle_pressed,
	}
	failsafe_active = false

func _activate_failsafe(reason: String) -> void:
	if failsafe_active:
		return
	failsafe_active = true
	latest_frame = DroneInputFrame.neutral()
	failsafe_triggered.emit(reason)
	if connected_peer != 0:
		_send_status(connected_peer, reason)

func _send_status(peer_id: int, pause_reason := "") -> void:
	var payload: Dictionary = {
		"type": "status",
		"server_time_ms": Time.get_ticks_msec(),
		"connected": true,
		"failsafe": failsafe_active,
		"pause_reason": pause_reason,
	}
	if status_provider.is_valid():
		payload.merge(status_provider.call(), true)
	_send(peer_id, payload)

func _send_error(peer_id: int, code: String, message: String) -> void:
	_send(peer_id, {"type": "error", "code": code, "message": message})

func _send(peer_id: int, payload: Dictionary) -> void:
	websocket.send_text(peer_id, JSON.stringify(payload))

func _on_peer_disconnected(peer_id: int) -> void:
	authenticated_peers.erase(peer_id)
	backgrounded_peers.erase(peer_id)
	if connected_peer == peer_id:
		connected_peer = 0
		_activate_failsafe("Controller disconnected")
		connection_changed.emit(false)

func _is_private_ipv4(address: String) -> bool:
	if address.begins_with("10.") or address.begins_with("192.168."):
		return true
	if address.begins_with("172."):
		var parts := address.split(".")
		return parts.size() == 4 and int(parts[1]) >= 16 and int(parts[1]) <= 31
	return false

func constant_time_equal(left: String, right: String) -> bool:
	var left_bytes := left.to_utf8_buffer()
	var right_bytes := right.to_utf8_buffer()
	var difference := left_bytes.size() ^ right_bytes.size()
	var length := maxi(left_bytes.size(), right_bytes.size())
	for index in length:
		var a := left_bytes[index] if index < left_bytes.size() else 0
		var b := right_bytes[index] if index < right_bytes.size() else 0
		difference |= a ^ b
	return difference == 0

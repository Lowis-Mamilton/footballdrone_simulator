class_name BrowserWebSocketServer
extends RefCounted

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal text_received(peer_id: int, text: String)

const MAX_MESSAGE_BYTES := 65535
const WEBSOCKET_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

var server := TCPServer.new()
var clients: Dictionary = {}
var next_peer_id := 1
var port := 0

func start(preferred_port: int) -> Error:
	var error := server.listen(preferred_port, "0.0.0.0")
	if error == OK:
		port = preferred_port
	return error

func stop() -> void:
	for peer_id in clients.keys():
		_disconnect(int(peer_id), false)
	clients.clear()
	server.stop()

func poll() -> void:
	while server.is_connection_available():
		var peer := server.take_connection()
		if peer:
			peer.set_no_delay(true)
			var peer_id := next_peer_id
			next_peer_id += 1
			clients[peer_id] = {"peer": peer, "buffer": PackedByteArray(), "upgraded": false, "started_ms": Time.get_ticks_msec()}
	for peer_id_value in clients.keys():
		var peer_id := int(peer_id_value)
		if not clients.has(peer_id):
			continue
		var client: Dictionary = clients[peer_id]
		var peer: StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var available := peer.get_available_bytes()
			if available > 0:
				var result := peer.get_data(available)
				if result[0] != OK:
					_disconnect(peer_id)
					continue
				client.buffer.append_array(result[1])
				clients[peer_id] = client
				if not client.upgraded:
					_try_upgrade(peer_id)
				else:
					_parse_frames(peer_id)
		elif peer.get_status() in [StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE]:
			_disconnect(peer_id)
		elif not bool(client.upgraded) and Time.get_ticks_msec() - int(client.started_ms) > 3000:
			_disconnect(peer_id)

func send_text(peer_id: int, text: String) -> Error:
	return _send_frame(peer_id, 0x1, text.to_utf8_buffer())

func get_peer_address(peer_id: int) -> String:
	if not clients.has(peer_id):
		return ""
	var peer: StreamPeerTCP = clients[peer_id].peer
	return peer.get_connected_host()

func _try_upgrade(peer_id: int) -> void:
	var client: Dictionary = clients[peer_id]
	var request_bytes: PackedByteArray = client.buffer
	var request := request_bytes.get_string_from_utf8()
	var header_end := request.find("\r\n\r\n")
	if header_end < 0:
		if request_bytes.size() > 8192:
			_disconnect(peer_id)
		return
	var headers := _parse_headers(request.substr(0, header_end))
	var key := String(headers.get("sec-websocket-key", ""))
	if String(headers.get(":method", "")) != "GET" or key.is_empty() or String(headers.get("upgrade", "")).to_lower() != "websocket":
		_disconnect(peer_id)
		return
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA1)
	hashing.update((key + WEBSOCKET_GUID).to_utf8_buffer())
	var accept := Marshalls.raw_to_base64(hashing.finish())
	var response := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept
	var peer: StreamPeerTCP = client.peer
	peer.put_data(response.to_utf8_buffer())
	var consumed := header_end + 4
	client.buffer = request_bytes.slice(consumed)
	client.upgraded = true
	clients[peer_id] = client
	peer_connected.emit(peer_id)
	if not client.buffer.is_empty():
		_parse_frames(peer_id)

func _parse_headers(request: String) -> Dictionary:
	var result := {}
	var lines := request.split("\r\n")
	if lines.is_empty():
		return result
	var request_line := lines[0].split(" ")
	if request_line.size() >= 1:
		result[":method"] = request_line[0]
	for index in range(1, lines.size()):
		var separator := lines[index].find(":")
		if separator > 0:
			result[lines[index].substr(0, separator).strip_edges().to_lower()] = lines[index].substr(separator + 1).strip_edges()
	return result

func _parse_frames(peer_id: int) -> void:
	while clients.has(peer_id):
		var client: Dictionary = clients[peer_id]
		var buffer: PackedByteArray = client.buffer
		if buffer.size() < 2:
			return
		var first := int(buffer[0])
		var second := int(buffer[1])
		var finished := (first & 0x80) != 0
		var opcode := first & 0x0f
		var masked := (second & 0x80) != 0
		var payload_length := second & 0x7f
		var cursor := 2
		if payload_length == 126:
			if buffer.size() < 4:
				return
			payload_length = (int(buffer[2]) << 8) | int(buffer[3])
			cursor = 4
		elif payload_length == 127:
			if buffer.size() < 10:
				return
			payload_length = 0
			for index in range(2, 10):
				payload_length = (payload_length << 8) | int(buffer[index])
			cursor = 10
		if not finished or not masked or payload_length > MAX_MESSAGE_BYTES:
			_send_close(peer_id, 1009 if payload_length > MAX_MESSAGE_BYTES else 1003)
			return
		if buffer.size() < cursor + 4 + payload_length:
			return
		var mask := buffer.slice(cursor, cursor + 4)
		cursor += 4
		var payload := buffer.slice(cursor, cursor + payload_length)
		for index in payload.size():
			payload[index] = payload[index] ^ mask[index % 4]
		client.buffer = buffer.slice(cursor + payload_length)
		clients[peer_id] = client
		match opcode:
			0x1:
				text_received.emit(peer_id, payload.get_string_from_utf8())
			0x8:
				_send_frame(peer_id, 0x8, payload)
				_disconnect(peer_id)
				return
			0x9:
				_send_frame(peer_id, 0xA, payload)
			0xA:
				pass
			_:
				_send_close(peer_id, 1003)
				return

func _send_frame(peer_id: int, opcode: int, payload: PackedByteArray) -> Error:
	if not clients.has(peer_id) or not bool(clients[peer_id].upgraded):
		return ERR_DOES_NOT_EXIST
	var frame := PackedByteArray([0x80 | opcode])
	if payload.size() < 126:
		frame.append(payload.size())
	else:
		frame.append(126)
		frame.append((payload.size() >> 8) & 0xff)
		frame.append(payload.size() & 0xff)
	frame.append_array(payload)
	var peer: StreamPeerTCP = clients[peer_id].peer
	return peer.put_data(frame)

func _send_close(peer_id: int, code: int) -> void:
	var payload := PackedByteArray([(code >> 8) & 0xff, code & 0xff])
	_send_frame(peer_id, 0x8, payload)
	_disconnect(peer_id)

func _disconnect(peer_id: int, notify := true) -> void:
	if not clients.has(peer_id):
		return
	var was_upgraded := bool(clients[peer_id].upgraded)
	var peer: StreamPeerTCP = clients[peer_id].peer
	peer.disconnect_from_host()
	clients.erase(peer_id)
	if notify and was_upgraded:
		peer_disconnected.emit(peer_id)


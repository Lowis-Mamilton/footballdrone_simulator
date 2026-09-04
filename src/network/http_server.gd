class_name LocalHttpServer
extends RefCounted

const MIME_TYPES := {
	"html": "text/html; charset=utf-8",
	"css": "text/css; charset=utf-8",
	"js": "text/javascript; charset=utf-8",
	"svg": "image/svg+xml",
	"png": "image/png",
	"json": "application/json; charset=utf-8",
}

var server := TCPServer.new()
var clients: Array[Dictionary] = []
var port := 41730
var ws_port := 41731
var debug_token := ""
var debug_session_id := ""

func start(preferred_port: int, websocket_port: int) -> Error:
	ws_port = websocket_port
	for candidate in range(preferred_port, preferred_port + 10):
		var error := server.listen(candidate, "0.0.0.0")
		if error == OK:
			port = candidate
			return OK
	return ERR_CANT_CREATE

func stop() -> void:
	for client in clients:
		var peer: StreamPeerTCP = client.peer
		peer.disconnect_from_host()
	clients.clear()
	server.stop()

func poll() -> void:
	while server.is_connection_available():
		var peer := server.take_connection()
		if peer:
			peer.set_no_delay(true)
			clients.append({"peer": peer, "request": PackedByteArray(), "started": Time.get_ticks_msec()})
	for index in range(clients.size() - 1, -1, -1):
		var client: Dictionary = clients[index]
		var peer: StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var available := peer.get_available_bytes()
			if available > 0:
				var read_result := peer.get_data(available)
				if read_result[0] == OK:
					client.request.append_array(read_result[1])
					clients[index] = client
					if client.request.get_string_from_utf8().contains("\r\n\r\n"):
						_serve(peer, client.request.get_string_from_utf8())
						clients.remove_at(index)
		elif peer.get_status() in [StreamPeerTCP.STATUS_ERROR, StreamPeerTCP.STATUS_NONE] or Time.get_ticks_msec() - int(client.started) > 3000:
			peer.disconnect_from_host()
			clients.remove_at(index)

func _serve(peer: StreamPeerTCP, request: String) -> void:
	var first_line := request.split("\r\n", false, 1)[0]
	var pieces := first_line.split(" ")
	if pieces.size() < 2 or pieces[0] != "GET":
		_send(peer, 405, "text/plain; charset=utf-8", "Method not allowed".to_utf8_buffer())
		return
	var route := pieces[1].split("?", true, 1)[0]
	if route == "/health":
		_send(peer, 200, MIME_TYPES.json, JSON.stringify({"ok": true, "protocol_version": 1}).to_utf8_buffer())
		return
	if route == "/config.json":
		_send(peer, 200, MIME_TYPES.json, JSON.stringify({"protocol_version": 1, "ws_port": ws_port}).to_utf8_buffer())
		return
	if route == "/debug/pairing.json" and OS.is_debug_build():
		_send(peer, 200, MIME_TYPES.json, JSON.stringify({"token": debug_token, "session_id": debug_session_id, "ws_port": ws_port}).to_utf8_buffer())
		return
	if route == "/":
		route = "/index.html"
	if ".." in route or not route.begins_with("/"):
		_send(peer, 400, "text/plain; charset=utf-8", "Bad request".to_utf8_buffer())
		return
	var path := "res://web/controller" + route
	if not FileAccess.file_exists(path):
		_send(peer, 404, "text/plain; charset=utf-8", "Not found".to_utf8_buffer())
		return
	var extension := route.get_extension().to_lower()
	_send(peer, 200, String(MIME_TYPES.get(extension, "application/octet-stream")), FileAccess.get_file_as_bytes(path))

func _send(peer: StreamPeerTCP, status: int, content_type: String, body: PackedByteArray) -> void:
	var reason := "OK" if status == 200 else ("Not Found" if status == 404 else "Error")
	var headers := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n" % [status, reason, content_type, body.size()]
	var response := headers.to_utf8_buffer()
	response.append_array(body)
	peer.put_data(response)
	peer.disconnect_from_host()

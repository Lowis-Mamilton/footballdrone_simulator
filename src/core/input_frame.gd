class_name DroneInputFrame
extends RefCounted

const AXES := [&"throttle", &"yaw", &"pitch", &"roll"]

var sequence: int = -1
var client_time_ms: int = 0
var received_time_ms: int = 0
var throttle: float = 0.0
var yaw: float = 0.0
var pitch: float = 0.0
var roll: float = 0.0
var arm_pressed: bool = false
var reset_pressed: bool = false
var turtle_pressed: bool = false
var requested_mode: StringName = &"angle"

static func neutral() -> DroneInputFrame:
	return DroneInputFrame.new()

static func from_wire(message: Dictionary, now_ms: int) -> DroneInputFrame:
	var frame := DroneInputFrame.new()
	frame.sequence = int(message.get("sequence", -1))
	frame.client_time_ms = int(message.get("client_time_ms", 0))
	frame.received_time_ms = now_ms
	var axes: Dictionary = message.get("axes", {})
	frame.throttle = clampf(float(axes.get("throttle", 0.0)), 0.0, 1.0)
	frame.yaw = clampf(float(axes.get("yaw", 0.0)), -1.0, 1.0)
	frame.pitch = clampf(float(axes.get("pitch", 0.0)), -1.0, 1.0)
	frame.roll = clampf(float(axes.get("roll", 0.0)), -1.0, 1.0)
	var buttons: Dictionary = message.get("buttons", {})
	frame.arm_pressed = bool(buttons.get("arm", false))
	frame.reset_pressed = bool(buttons.get("reset", false))
	frame.turtle_pressed = bool(buttons.get("turtle", false))
	frame.requested_mode = StringName(message.get("flight_mode", "angle"))
	if frame.requested_mode not in [&"angle", &"acro"]:
		frame.requested_mode = &"angle"
	return frame

func to_dictionary() -> Dictionary:
	return {
		"sequence": sequence,
		"client_time_ms": client_time_ms,
		"received_time_ms": received_time_ms,
		"axes": {"throttle": throttle, "yaw": yaw, "pitch": pitch, "roll": roll},
		"buttons": {"arm": arm_pressed, "reset": reset_pressed, "turtle": turtle_pressed},
		"flight_mode": String(requested_mode),
	}


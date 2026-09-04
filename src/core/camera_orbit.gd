class_name CameraOrbit
extends RefCounted

static func rotate(current: Vector2, mouse_delta: Vector2, sensitivity: float, minimum_pitch: float, maximum_pitch: float) -> Vector2:
	return Vector2(
		wrapf(current.x - mouse_delta.x * sensitivity, -PI, PI),
		clampf(current.y - mouse_delta.y * sensitivity, minimum_pitch, maximum_pitch)
	)

static func offset(yaw: float, pitch: float, distance: float) -> Vector3:
	var horizontal_distance := cos(pitch) * distance
	return Vector3(
		sin(yaw) * horizontal_distance,
		sin(pitch) * distance,
		cos(yaw) * horizontal_distance
	)

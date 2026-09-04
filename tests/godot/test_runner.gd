extends SceneTree

const ProfileStoreScript := preload("res://src/data/profile_store.gd")
const ControlServerScript := preload("res://src/network/control_server.gd")
const QRCodeGenerator := preload("res://addons/kenyoni/qr_code/qr_code.gd")
const CameraOrbitScript := preload("res://src/core/camera_orbit.gd")

var failures := PackedStringArray()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_input_frame()
	_test_pid_axis()
	_test_flight_controller()
	_test_profiles()
	_test_pairing_comparison()
	_test_qr_generation()
	_test_camera_orbit()
	await _test_physics_lift()
	await _test_angle_self_leveling()
	await _test_yaw_disturbance_stability()
	await _test_ui_drag_routing()
	if failures.is_empty():
		print("PASS: 11 Godot test groups")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("FAIL: %d assertion(s)" % failures.size())
		quit(1)

func _test_input_frame() -> void:
	var frame := DroneInputFrame.from_wire({
		"sequence": 9,
		"client_time_ms": 100,
		"axes": {"throttle": 2.0, "yaw": -2.0, "pitch": 0.25, "roll": 0.5},
		"buttons": {"arm": true, "reset": false, "turtle": true},
		"flight_mode": "not-a-mode",
	}, 200)
	_check(frame.throttle == 1.0, "Throttle must clamp to 1")
	_check(frame.yaw == -1.0, "Yaw must clamp to -1")
	_check(frame.requested_mode == &"angle", "Invalid mode must fall back to Angle")
	_check(frame.arm_pressed and frame.turtle_pressed, "Buttons must decode")

func _test_pid_axis() -> void:
	var pid := PIDAxis.new(0.2, 0.1, 0.01, 0.3, 0.5)
	var output := pid.step(1.0, 0.0, 0.01)
	_check(output > 0.0 and output <= 0.5, "PID output must be positive and bounded")
	for _index in 2000:
		pid.step(10.0, 0.0, 0.01)
	_check(absf(pid.integral) <= 0.30001, "PID integral must be bounded")
	pid.reset()
	_check(pid.integral == 0.0, "PID reset must clear integral")

func _test_flight_controller() -> void:
	var profile: Dictionary = _read_profile("res://config/profiles/standard.json")
	var controller := FlightController.new(profile)
	var frame := DroneInputFrame.new()
	frame.throttle = 0.62
	frame.roll = 0.2
	frame.requested_mode = &"acro"
	var disarmed := controller.compute(frame, Vector3.ZERO, Vector3.ZERO, 1.0 / 240.0, false)
	_check(_all_zero(disarmed), "Disarmed controller must output zero motors")
	var armed := controller.compute(frame, Vector3.ZERO, Vector3.ZERO, 1.0 / 240.0, true)
	_check(armed.size() == 4, "Controller must produce four motor outputs")
	for value in armed:
		_check(is_finite(value) and value >= 0.0 and value <= 1.0, "Motor output must be finite and normalized")
	_check(not is_equal_approx(armed[0], armed[1]), "Roll input must produce differential thrust")

func _test_profiles() -> void:
	var store := ProfileStoreScript.new()
	for profile_path in ["res://config/profiles/stable.json", "res://config/profiles/standard.json", "res://config/profiles/responsive.json"]:
		var profile := _read_profile(profile_path)
		_check(store.validate_profile(profile).is_empty(), "%s must validate" % profile_path)
	var invalid: Dictionary = _read_profile("res://config/profiles/standard.json")
	invalid.drone.mass_kg = 2.0
	_check(not store.validate_profile(invalid).is_empty(), "Unsafe mass must be rejected")
	store.free()

func _test_pairing_comparison() -> void:
	var server := ControlServerScript.new()
	_check(server.constant_time_equal("abc123", "abc123"), "Equal pairing tokens must compare equal")
	_check(not server.constant_time_equal("abc123", "abc124"), "Different pairing tokens must compare unequal")
	_check(not server.constant_time_equal("short", "longer"), "Different token lengths must compare unequal")
	server.free()

func _test_qr_generation() -> void:
	var qr := QRCodeGenerator.new()
	qr.put_byte("http://192.168.1.10:41730/?token=abc".to_utf8_buffer())
	var encoded: PackedByteArray = qr.encode()
	var image: Image = QRCodeGenerator.generate_image(encoded, 2)
	_check(not encoded.is_empty(), "QR payload must encode")
	_check(image.get_width() > 40 and image.get_width() == image.get_height(), "QR image must be square")

func _test_camera_orbit() -> void:
	_check(CameraOrbitScript.offset(0.0, 0.0, 2.0).is_equal_approx(Vector3(0.0, 0.0, 2.0)), "Camera orbit must preserve radius and face the target")
	var orbit := CameraOrbitScript.rotate(Vector2.ZERO, Vector2(-100.0, -40.0), 0.005, -PI / 12.0, PI * 4.0 / 9.0)
	var moved_offset: Vector3 = CameraOrbitScript.offset(orbit.x, orbit.y, 2.0)
	_check(is_equal_approx(moved_offset.length(), 2.0), "Mouse orbit must preserve camera distance")
	_check(moved_offset.x > 0.0 and moved_offset.y > 0.0, "Dragging left and up must rotate the camera horizontally and vertically")
	orbit = CameraOrbitScript.rotate(orbit, Vector2(0.0, -10000.0), 0.005, -PI / 12.0, PI * 4.0 / 9.0)
	_check(is_equal_approx(orbit.y, PI * 4.0 / 9.0), "Camera pitch must clamp before flipping over")

func _test_physics_lift() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var test_drone := DroneBall.new()
	test_drone.profile = _read_profile("res://config/profiles/standard.json")
	test_drone.spawn_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	world.add_child(test_drone)
	var frame := DroneInputFrame.new()
	frame.throttle = 0.82
	frame.requested_mode = &"angle"
	test_drone.set_input(frame)
	test_drone.set_armed(true)
	var start_height := test_drone.position.y
	for _index in 120:
		await physics_frame
	_check(test_drone.position.y > start_height + 0.25, "Armed drone with high throttle must generate lift (start=%.3f end=%.3f motors=%s)" % [start_height, test_drone.position.y, test_drone.motor_outputs])
	test_drone.set_armed(false)
	world.queue_free()
	await process_frame

func _test_angle_self_leveling() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var test_drone := DroneBall.new()
	var test_profile: Dictionary = _read_profile("res://config/profiles/standard.json")
	test_drone.profile = test_profile
	var initial_tilt := deg_to_rad(8.0)
	test_drone.spawn_transform = Transform3D(Basis.from_euler(Vector3(initial_tilt, 0.0, 0.0)), Vector3(0.0, 1.0, 0.0))
	world.add_child(test_drone)
	var frame := DroneInputFrame.new()
	frame.throttle = sqrt(1.0 / float(test_profile.drone.thrust_to_weight))
	frame.requested_mode = &"angle"
	test_drone.set_input(frame)
	test_drone.set_armed(true)
	for _index in 240:
		await physics_frame
	var final_tilt := absf(test_drone.transform.basis.get_euler().x)
	_check(final_tilt < initial_tilt * 0.5, "Angle mode must correct a small pitch disturbance (start=%.2f deg end=%.2f deg)" % [rad_to_deg(initial_tilt), rad_to_deg(final_tilt)])
	test_drone.set_armed(false)
	world.queue_free()
	await process_frame

func _test_yaw_disturbance_stability() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var test_drone := DroneBall.new()
	var test_profile: Dictionary = _read_profile("res://config/profiles/standard.json")
	test_drone.profile = test_profile
	test_drone.spawn_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 3.0, 0.0))
	world.add_child(test_drone)
	var frame := DroneInputFrame.new()
	frame.throttle = sqrt(1.0 / float(test_profile.drone.thrust_to_weight))
	frame.requested_mode = &"angle"
	test_drone.set_input(frame)
	test_drone.set_armed(true)
	for _index in 30:
		await physics_frame
	frame.yaw = 0.01
	test_drone.set_input(frame)
	await physics_frame
	frame.yaw = 0.0
	test_drone.set_input(frame)
	var max_tilt := 0.0
	var max_yaw_rate := absf(test_drone.angular_velocity.y)
	for _index in 300:
		await physics_frame
		var up := test_drone.global_transform.basis.y.normalized()
		max_tilt = maxf(max_tilt, acos(clampf(up.dot(Vector3.UP), -1.0, 1.0)))
		max_yaw_rate = maxf(max_yaw_rate, absf(test_drone.angular_velocity.y))
	_check(max_yaw_rate > deg_to_rad(0.01), "Yaw disturbance test must produce measurable yaw motion")
	_check(max_tilt < deg_to_rad(10.0), "A one-frame 1%% yaw input must not destabilize Angle mode (max tilt=%.2f deg)" % rad_to_deg(max_tilt))
	test_drone.set_armed(false)
	world.queue_free()
	await process_frame

func _test_ui_drag_routing() -> void:
	var main_scene: PackedScene = load("res://src/main.tscn")
	var main := main_scene.instantiate()
	root.add_child(main)
	await process_frame
	var initial_yaw: float = main.camera_orbit_yaw
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(800.0, 400.0)
	Input.parse_input_event(press)
	await process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(860.0, 400.0)
	motion.relative = Vector2(60.0, 0.0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(motion)
	await process_frame
	_check(absf(main.camera_orbit_yaw - initial_yaw) > 0.1, "Dragging an empty part of the flight view must rotate the camera")
	main.queue_free()
	await process_frame

func _read_profile(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(file.get_as_text())

func _all_zero(values: PackedFloat32Array) -> bool:
	for value in values:
		if value != 0.0:
			return false
	return true

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

class_name FlightController
extends RefCounted

var profile: Dictionary
var pitch_pid: PIDAxis
var roll_pid: PIDAxis
var yaw_pid: PIDAxis

func _init(initial_profile: Dictionary) -> void:
	configure(initial_profile)

func configure(next_profile: Dictionary) -> void:
	profile = next_profile.duplicate(true)
	var pid: Dictionary = profile.get("pid", {})
	pitch_pid = _make_axis(pid.get("pitch", {}))
	roll_pid = _make_axis(pid.get("roll", {}))
	yaw_pid = _make_axis(pid.get("yaw", {}))

func reset() -> void:
	pitch_pid.reset()
	roll_pid.reset()
	yaw_pid.reset()

func compute(frame: DroneInputFrame, attitude: Vector3, local_rates: Vector3, dt: float, armed: bool) -> PackedFloat32Array:
	if not armed:
		reset()
		return PackedFloat32Array([0.0, 0.0, 0.0, 0.0])

	var rates: Dictionary = profile.get("rates", {})
	var pitch_setpoint := _rate_setpoint(frame.pitch, rates.get("pitch", {}))
	var roll_setpoint := _rate_setpoint(frame.roll, rates.get("roll", {}))
	var yaw_setpoint := _rate_setpoint(frame.yaw, rates.get("yaw", {}))
	if frame.requested_mode == &"angle":
		var angle_limit := deg_to_rad(float(profile.get("angle_limit_deg", 45.0)))
		var level_gain := float(profile.get("angle_level_gain", 5.0))
		pitch_setpoint = clampf((frame.pitch * angle_limit - attitude.x) * level_gain, -12.0, 12.0)
		roll_setpoint = clampf((-frame.roll * angle_limit - attitude.z) * level_gain, -12.0, 12.0)

	var pitch_correction := pitch_pid.step(pitch_setpoint, local_rates.x, dt)
	var yaw_correction := yaw_pid.step(yaw_setpoint, local_rates.y, dt)
	var roll_correction := roll_pid.step(roll_setpoint, local_rates.z, dt)
	var collective := frame.throttle

	# Motor order: front-left, front-right, rear-left, rear-right.
	return PackedFloat32Array([
		clampf(collective + pitch_correction - roll_correction - yaw_correction, 0.0, 1.0),
		clampf(collective + pitch_correction + roll_correction + yaw_correction, 0.0, 1.0),
		clampf(collective - pitch_correction - roll_correction + yaw_correction, 0.0, 1.0),
		clampf(collective - pitch_correction + roll_correction - yaw_correction, 0.0, 1.0),
	])

func _make_axis(values: Dictionary) -> PIDAxis:
	return PIDAxis.new(
		float(values.get("p", 0.12)),
		float(values.get("i", 0.08)),
		float(values.get("d", 0.002)),
		float(values.get("integral_limit", 0.3)),
		float(values.get("output_limit", 0.32))
	)

func _rate_setpoint(stick: float, rate_config: Dictionary) -> float:
	var expo := clampf(float(rate_config.get("expo", 0.25)), 0.0, 1.0)
	var max_rate := deg_to_rad(float(rate_config.get("max_deg_s", 480.0)))
	var shaped := (1.0 - expo) * stick + expo * stick * stick * stick
	return shaped * max_rate

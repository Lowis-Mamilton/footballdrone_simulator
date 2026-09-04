class_name DroneBall
extends RigidBody3D

signal collision_happened(speed: float)
signal armed_changed(value: bool)
signal mode_changed(value: StringName)
signal reset_performed()
signal arm_rejected(reason: String)

const GRAVITY := 9.80665
const MOTOR_POSITIONS := [
	Vector3(-0.055, 0.0, -0.055),
	Vector3(0.055, 0.0, -0.055),
	Vector3(-0.055, 0.0, 0.055),
	Vector3(0.055, 0.0, 0.055),
]
const YAW_DIRECTIONS := [-1.0, 1.0, 1.0, -1.0]

var profile: Dictionary
var controller: FlightController
var input_frame := DroneInputFrame.neutral()
var motor_outputs := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var armed := false
var flight_mode: StringName = &"angle"
var spawn_transform := Transform3D(Basis.IDENTITY, Vector3(-1.9, 0.22, 0.0))
var last_collision_ms := 0
var turtle_until_ms := 0
var motor_audio: AudioStreamPlayer3D
var audio_playback: AudioStreamGeneratorPlayback
var audio_phase := 0.0
var impact_envelope := 0.0

func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 8
	continuous_cd = true
	can_sleep = false
	body_entered.connect(_on_body_entered)
	_build_visuals()
	_build_audio()
	if profile.is_empty():
		var file := FileAccess.open("res://config/profiles/standard.json", FileAccess.READ)
		if file:
			profile = JSON.parse_string(file.get_as_text())
	apply_profile(profile)
	reset_to_spawn()

func _process(delta: float) -> void:
	_fill_audio()
	impact_envelope = maxf(0.0, impact_envelope - delta * 4.0)

func _exit_tree() -> void:
	if motor_audio:
		motor_audio.stop()
		motor_audio.stream = null
	audio_playback = null

func apply_profile(next_profile: Dictionary) -> void:
	profile = next_profile.duplicate(true)
	var drone: Dictionary = profile.get("drone", {})
	mass = float(drone.get("mass_kg", 0.28))
	linear_damp = 0.02
	angular_damp = 0.02
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = float(drone.get("collision_friction", 0.42))
	physics_material_override.bounce = float(drone.get("collision_restitution", 0.36))
	controller = FlightController.new(profile)

func set_input(frame: DroneInputFrame) -> void:
	input_frame = frame
	if frame.requested_mode != flight_mode:
		flight_mode = frame.requested_mode
		mode_changed.emit(flight_mode)

func toggle_arm() -> void:
	if not armed and input_frame.throttle > 0.05:
		arm_rejected.emit("Lower throttle before arming")
		return
	set_armed(not armed)

func set_armed(next_armed: bool) -> void:
	if armed == next_armed:
		return
	armed = next_armed
	if not armed:
		motor_outputs.fill(0.0)
		if controller:
			controller.reset()
	armed_changed.emit(armed)

func reset_to_spawn() -> void:
	set_armed(false)
	freeze = true
	global_transform = spawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	motor_outputs.fill(0.0)
	freeze = false
	reset_performed.emit()

func activate_turtle() -> void:
	if armed:
		return
	turtle_until_ms = Time.get_ticks_msec() + 700
	freeze = false

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not controller:
		return
	var drone: Dictionary = profile.get("drone", {})
	var sub_dt := state.step * 0.5
	var local_rates := state.transform.basis.inverse() * state.angular_velocity
	var attitude := state.transform.basis.get_euler()
	var requested := motor_outputs
	for _substep in 2:
		requested = controller.compute(input_frame, attitude, local_rates, sub_dt, armed)
		var response := maxf(float(drone.get("motor_time_constant_s", 0.042)), 0.005)
		var blend := 1.0 - exp(-sub_dt / response)
		for index in 4:
			motor_outputs[index] = lerpf(motor_outputs[index], requested[index], blend)

	var max_total_thrust: float = mass * GRAVITY * float(drone.get("thrust_to_weight", 2.5))
	var basis: Basis = state.transform.basis.orthonormalized()
	var up: Vector3 = basis.y
	var total_force := Vector3.ZERO
	var total_torque := Vector3.ZERO
	for index in 4:
		var thrust: float = motor_outputs[index] * motor_outputs[index] * max_total_thrust * 0.25
		var force: Vector3 = up * thrust
		var arm: Vector3 = basis * MOTOR_POSITIONS[index]
		total_force += force
		total_torque += arm.cross(force)
		total_torque += up * thrust * 0.011 * YAW_DIRECTIONS[index]

	var speed := state.linear_velocity.length()
	var linear_drag_force := -state.linear_velocity * (float(drone.get("linear_drag", 0.065)) + float(drone.get("quadratic_drag", 0.038)) * speed)
	var angular_drag_torque := -state.angular_velocity * float(drone.get("angular_drag", 0.014))
	state.apply_central_force(total_force + linear_drag_force)
	state.apply_torque(total_torque + angular_drag_torque)

	if Time.get_ticks_msec() < turtle_until_ms:
		var local_up := basis.y
		var recovery_axis := local_up.cross(Vector3.UP)
		if recovery_axis.length_squared() > 0.0001:
			state.apply_torque(recovery_axis.normalized() * 0.055)

func _build_visuals() -> void:
	var collision := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = 0.10
	collision.shape = sphere_shape
	add_child(collision)

	var cage_material := StandardMaterial3D.new()
	cage_material.albedo_color = Color("41d9c5")
	cage_material.metallic = 0.35
	cage_material.roughness = 0.35
	cage_material.emission_enabled = true
	cage_material.emission = Color("0b594f")
	for rotation in [Vector3.ZERO, Vector3(PI * 0.5, 0.0, 0.0), Vector3(0.0, 0.0, PI * 0.5)]:
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.092
		torus.outer_radius = 0.10
		torus.rings = 24
		torus.ring_segments = 8
		ring.mesh = torus
		ring.rotation = rotation
		ring.material_override = cage_material
		add_child(ring)

	var body_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.07, 0.025, 0.07)
	body_mesh.mesh = box
	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = Color("172f48")
	body_material.metallic = 0.6
	body_mesh.material_override = body_material
	add_child(body_mesh)

	for index in 4:
		var motor := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.012
		cylinder.bottom_radius = 0.012
		cylinder.height = 0.018
		cylinder.radial_segments = 12
		motor.mesh = cylinder
		motor.position = MOTOR_POSITIONS[index]
		motor.material_override = body_material
		add_child(motor)

	var nose := MeshInstance3D.new()
	var nose_mesh := SphereMesh.new()
	nose_mesh.radius = 0.012
	nose_mesh.height = 0.024
	nose.mesh = nose_mesh
	nose.position = Vector3(0.0, 0.0, -0.102)
	var nose_material := StandardMaterial3D.new()
	nose_material.albedo_color = Color("ff5577")
	nose_material.emission_enabled = true
	nose_material.emission = Color("9b1538")
	nose.material_override = nose_material
	add_child(nose)

func _build_audio() -> void:
	if DisplayServer.get_name() == "headless":
		return
	motor_audio = AudioStreamPlayer3D.new()
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 22050.0
	generator.buffer_length = 0.18
	motor_audio.stream = generator
	motor_audio.unit_size = 1.4
	motor_audio.max_distance = 12.0
	motor_audio.volume_db = -10.0
	add_child(motor_audio)
	motor_audio.play()
	audio_playback = motor_audio.get_stream_playback()

func _fill_audio() -> void:
	if not audio_playback:
		return
	var frames := mini(audio_playback.get_frames_available(), 768)
	var mean_motor := 0.0
	for value in motor_outputs:
		mean_motor += value * 0.25
	var frequency := 85.0 + mean_motor * 430.0
	var amplitude := (0.012 + mean_motor * 0.095) if armed else 0.0
	for _index in frames:
		audio_phase = fmod(audio_phase + frequency / 22050.0, 1.0)
		var motor_sample := sin(audio_phase * TAU) + 0.26 * sin(audio_phase * TAU * 2.03)
		var impact_sample := sin(audio_phase * TAU * 7.7) * impact_envelope
		var sample := clampf(motor_sample * amplitude + impact_sample * 0.16, -0.8, 0.8)
		audio_playback.push_frame(Vector2(sample, sample))

func _on_body_entered(_body: Node) -> void:
	var now := Time.get_ticks_msec()
	if now - last_collision_ms < 120:
		return
	last_collision_ms = now
	impact_envelope = clampf(linear_velocity.length() / 5.0, 0.0, 1.0)
	collision_happened.emit(linear_velocity.length())

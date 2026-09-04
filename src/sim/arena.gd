class_name DroneSoccerArena
extends Node3D

const LENGTH := 6.0
const WIDTH := 3.0
const HEIGHT := 3.0

func _ready() -> void:
	_build_environment()
	_build_floor()
	_build_cage()
	_build_markings()
	_build_goals()

func _build_environment() -> void:
	var environment := WorldEnvironment.new()
	var resource := Environment.new()
	resource.background_mode = Environment.BG_COLOR
	resource.background_color = Color("071426")
	resource.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	resource.ambient_light_color = Color("b9d8ef")
	resource.ambient_light_energy = 0.62
	resource.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = resource
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -28.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)
	for x in [-2.0, 0.0, 2.0]:
		var light := OmniLight3D.new()
		light.position = Vector3(x, 2.7, 0.0)
		light.omni_range = 4.0
		light.light_energy = 2.0
		light.light_color = Color("d8efff")
		add_child(light)

func _build_floor() -> void:
	add_child(_static_box("Floor", Vector3(LENGTH + 1.0, 0.1, WIDTH + 1.0), Vector3(0.0, -0.05, 0.0), Color("173451"), true))

func _build_cage() -> void:
	var net_color := Color(0.25, 0.65, 0.72, 0.14)
	add_child(_static_box("Ceiling", Vector3(LENGTH, 0.035, WIDTH), Vector3(0.0, HEIGHT, 0.0), net_color, true))
	add_child(_static_box("NorthNet", Vector3(LENGTH, HEIGHT, 0.035), Vector3(0.0, HEIGHT * 0.5, -WIDTH * 0.5), net_color, true))
	add_child(_static_box("SouthNet", Vector3(LENGTH, HEIGHT, 0.035), Vector3(0.0, HEIGHT * 0.5, WIDTH * 0.5), net_color, true))
	add_child(_static_box("WestNet", Vector3(0.035, HEIGHT, WIDTH), Vector3(-LENGTH * 0.5, HEIGHT * 0.5, 0.0), net_color, true))
	add_child(_static_box("EastNet", Vector3(0.035, HEIGHT, WIDTH), Vector3(LENGTH * 0.5, HEIGHT * 0.5, 0.0), net_color, true))
	var beam_color := Color("35627b")
	for x in [-LENGTH * 0.5, LENGTH * 0.5]:
		for z in [-WIDTH * 0.5, WIDTH * 0.5]:
			add_child(_visual_box(Vector3(0.055, HEIGHT, 0.055), Vector3(x, HEIGHT * 0.5, z), beam_color))

func _build_markings() -> void:
	var white := Color("b9d8e8")
	add_child(_visual_box(Vector3(0.025, 0.006, WIDTH), Vector3(0.0, 0.006, 0.0), white))
	for x in [-2.55, 2.55]:
		add_child(_visual_box(Vector3(0.02, 0.007, 0.9), Vector3(x, 0.008, 0.0), Color("41d9c5")))

func _build_goals() -> void:
	_create_goal(-2.0, Color("4da8ff"), 1.0)
	_create_goal(2.0, Color("ff5577"), -1.0)

func _create_goal(x: float, color: Color, facing: float) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.20
	torus.outer_radius = 0.35
	# Torus starts with its opening normal on Y; rotate it to face the arena center on X.
	ring.mesh = torus
	ring.rotation_degrees.z = 90.0
	ring.position = Vector3(x, 1.55, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color * 0.38
	ring.material_override = material
	add_child(ring)
	# Eight padded segments approximate the physical goal collision while leaving the opening clear.
	for index in 8:
		var angle := TAU * float(index) / 8.0
		var segment_position := Vector3(x, 1.55 + cos(angle) * 0.275, sin(angle) * 0.275)
		var segment := _static_box("GoalSegment", Vector3(0.10, 0.11, 0.11), segment_position, color, false)
		add_child(segment)

func _static_box(node_name: String, size: Vector3, position: Vector3, color: Color, visible: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	if visible:
		var visual := _box_mesh(size, color)
		body.add_child(visual)
	return body

func _visual_box(size: Vector3, position: Vector3, color: Color) -> MeshInstance3D:
	var visual := _box_mesh(size, color)
	visual.position = position
	return visual

func _box_mesh(size: Vector3, color: Color) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	visual.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	visual.material_override = material
	return visual


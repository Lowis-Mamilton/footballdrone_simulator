extends Node

const PANEL_WIDTH := 390.0
const PANEL_TOGGLE_WIDTH := 36.0
const CameraOrbitMath := preload("res://src/core/camera_orbit.gd")
const LOS_CAMERA_TARGET := Vector3(0.1, 1.25, 0.0)
const LOS_CAMERA_POSITION := Vector3(-3.72, 1.72, 3.35)
const FOLLOW_CAMERA_DISTANCE := 1.66
const CAMERA_DRAG_SENSITIVITY := 0.005
const CAMERA_MIN_PITCH := -PI / 12.0
const CAMERA_MAX_PITCH := PI * 4.0 / 9.0
const QRCodeGenerator := preload("res://addons/kenyoni/qr_code/qr_code.gd")
const COLORS := {
	"background": Color("071426"),
	"panel": Color("10243d"),
	"panel_alt": Color("17324f"),
	"line": Color("2c4968"),
	"mint": Color("41d9c5"),
	"blue": Color("4da8ff"),
	"red": Color("ff5577"),
	"text": Color("eaf6ff"),
	"muted": Color("88a3ba"),
}

var arena: DroneSoccerArena
var drone: DroneBall
var lessons: LessonManager
var los_camera: Camera3D
var follow_camera: Camera3D
var lesson_markers: Node3D
var active_camera_mode := "los"
var camera_dragging := false
var camera_orbit_yaw := 0.0
var camera_orbit_pitch := 0.0
var keyboard_throttle := 0.0
var panel: PanelContainer
var panel_content: VBoxContainer
var panel_toggle_button: Button
var connection_label: Label
var armed_label: Label
var mode_label: Label
var objective_label: Label
var timer_label: Label
var toast_label: Label
var profile_label: Label
var tuning_controls: Array[Control] = []

func _ready() -> void:
	_build_world()
	_build_ui()
	lessons.bind_drone(drone)
	ProfileStore.profile_changed.connect(_on_profile_changed)
	ControlServer.connection_changed.connect(_on_connection_changed)
	ControlServer.failsafe_triggered.connect(_on_failsafe)
	ControlServer.command_received.connect(_on_remote_command)
	ControlServer.set_status_provider(_network_status)
	drone.armed_changed.connect(_on_armed_changed)
	drone.arm_rejected.connect(func(reason: String): toast_label.text = reason)
	drone.mode_changed.connect(func(mode: StringName): mode_label.text = String(mode).to_upper())
	drone.collision_happened.connect(_on_collision)
	lessons.objective_changed.connect(func(text: String): objective_label.text = text)
	lessons.lesson_started.connect(_show_lesson_markers)
	lessons.lesson_finished.connect(_on_lesson_finished)
	_show_panel("pair")

func _process(delta: float) -> void:
	var frame := ControlServer.get_input_frame() if ControlServer.is_controller_connected() else _keyboard_frame(delta)
	drone.set_input(_apply_input_profile(frame))
	_update_cameras(delta)
	_update_hud()
	if Input.is_action_just_pressed("arm"):
		drone.toggle_arm()
	if Input.is_action_just_pressed("reset_drone"):
		drone.reset_to_spawn()
	if Input.is_action_just_pressed("toggle_camera"):
		_toggle_camera()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		camera_dragging = event.pressed
		Input.set_default_cursor_shape(Input.CURSOR_DRAG if camera_dragging else Input.CURSOR_ARROW)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and camera_dragging:
		_rotate_camera_orbit(event.relative)
		get_viewport().set_input_as_handled()

func _build_world() -> void:
	arena = DroneSoccerArena.new()
	add_child(arena)
	drone = DroneBall.new()
	drone.name = "DroneBall"
	drone.profile = ProfileStore.active_profile
	add_child(drone)
	lessons = LessonManager.new()
	add_child(lessons)
	lesson_markers = Node3D.new()
	lesson_markers.name = "LessonMarkers"
	add_child(lesson_markers)

	los_camera = Camera3D.new()
	los_camera.position = LOS_CAMERA_POSITION
	los_camera.fov = 54.0
	add_child(los_camera)
	los_camera.look_at_from_position(los_camera.position, LOS_CAMERA_TARGET, Vector3.UP)
	los_camera.current = true
	var initial_offset := LOS_CAMERA_POSITION - LOS_CAMERA_TARGET
	camera_orbit_yaw = atan2(initial_offset.x, initial_offset.z)
	camera_orbit_pitch = asin(initial_offset.y / initial_offset.length())
	follow_camera = Camera3D.new()
	follow_camera.fov = 62.0
	add_child(follow_camera)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(root)

	var top_bar := PanelContainer.new()
	top_bar.position = Vector2(18, 16)
	top_bar.size = Vector2(1244, 54)
	top_bar.add_theme_stylebox_override("panel", _style(COLORS.panel, 12, COLORS.line))
	root.add_child(top_bar)
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 10)
	top_bar.add_child(top_row)
	var title := Label.new()
	title.text = "  FOOTBALL DRONE  /  TRAINING SIMULATOR"
	title.add_theme_color_override("font_color", COLORS.text)
	title.add_theme_font_size_override("font_size", 17)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(title)
	for definition in [["PAIR", "pair"], ["FLIGHT", "flight"], ["LESSONS", "lessons"], ["TUNING", "tuning"], ["CONTROLLER", "controller"], ["RESULTS", "results"]]:
		var button := _button(definition[0])
		button.pressed.connect(_show_panel.bind(definition[1]))
		top_row.add_child(button)

	panel = PanelContainer.new()
	panel.position = Vector2(18, 82)
	panel.size = Vector2(PANEL_WIDTH, 620)
	panel.add_theme_stylebox_override("panel", _style(Color(0.04, 0.09, 0.15, 0.96), 14, COLORS.line))
	root.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)
	panel_content = VBoxContainer.new()
	panel_content.add_theme_constant_override("separation", 12)
	margin.add_child(panel_content)
	panel_toggle_button = _button("<")
	panel_toggle_button.position = Vector2(panel.position.x + PANEL_WIDTH - PANEL_TOGGLE_WIDTH, panel.position.y + 10.0)
	panel_toggle_button.size = Vector2(PANEL_TOGGLE_WIDTH, 42.0)
	panel_toggle_button.tooltip_text = "Collapse side panel"
	panel_toggle_button.pressed.connect(_toggle_panel)
	root.add_child(panel_toggle_button)

	var hud := PanelContainer.new()
	hud.position = Vector2(424, 82)
	hud.size = Vector2(838, 48)
	hud.add_theme_stylebox_override("panel", _style(Color(0.03, 0.07, 0.12, 0.88), 10, Color.TRANSPARENT))
	root.add_child(hud)
	var hud_row := HBoxContainer.new()
	hud_row.add_theme_constant_override("separation", 20)
	hud.add_child(hud_row)
	connection_label = _badge("NO CONTROLLER", COLORS.red)
	armed_label = _badge("DISARMED", COLORS.muted)
	mode_label = _badge("ANGLE", COLORS.blue)
	profile_label = _badge("STANDARD", COLORS.mint)
	objective_label = Label.new()
	objective_label.text = "Free flight"
	objective_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	objective_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer_label = Label.new()
	timer_label.text = "00:00.0"
	timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	for node in [connection_label, armed_label, mode_label, profile_label, objective_label, timer_label]:
		hud_row.add_child(node)

	toast_label = Label.new()
	toast_label.position = Vector2(450, 650)
	toast_label.size = Vector2(780, 42)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.add_theme_color_override("font_color", COLORS.text)
	toast_label.add_theme_stylebox_override("normal", _style(Color(0.03, 0.07, 0.12, 0.88), 9, COLORS.line))
	toast_label.text = "Keyboard: R/F throttle · WASD pitch/roll · Q/E yaw · Space arm · C camera · Drag scene to orbit"
	root.add_child(toast_label)

	var camera_button := _button("LOS / FOLLOW  [C]")
	camera_button.position = Vector2(1050, 142)
	camera_button.size = Vector2(212, 42)
	camera_button.pressed.connect(_toggle_camera)
	root.add_child(camera_button)

func _show_panel(panel_name: String) -> void:
	_set_panel_collapsed(false)
	for child in panel_content.get_children():
		child.queue_free()
	tuning_controls.clear()
	match panel_name:
		"pair": _build_pair_panel()
		"flight": _build_flight_panel()
		"lessons": _build_lessons_panel()
		"tuning": _build_tuning_panel()
		"controller": _build_controller_panel()
		"results": _build_results_panel()

func _toggle_panel() -> void:
	_set_panel_collapsed(panel.visible)

func _set_panel_collapsed(collapsed: bool) -> void:
	panel.visible = not collapsed
	panel_toggle_button.text = ">" if collapsed else "<"
	panel_toggle_button.tooltip_text = "Expand side panel" if collapsed else "Collapse side panel"
	panel_toggle_button.position.x = panel.position.x if collapsed else panel.position.x + PANEL_WIDTH - PANEL_TOGGLE_WIDTH

func _build_pair_panel() -> void:
	_add_heading("PAIR YOUR PHONE", "Both devices must be on the same Wi-Fi network.")
	if not ControlServer.startup_error.is_empty():
		_add_notice(ControlServer.startup_error, COLORS.red)
		return
	var qr_container := CenterContainer.new()
	qr_container.custom_minimum_size = Vector2(0, 248)
	panel_content.add_child(qr_container)
	var qr_texture := TextureRect.new()
	qr_texture.custom_minimum_size = Vector2(232, 232)
	qr_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_container.add_child(qr_texture)
	qr_texture.texture = _make_qr_texture(ControlServer.pairing_url)
	if qr_texture.texture == null:
		var fallback := Label.new()
		fallback.text = "QR module unavailable\nOpen the address below"
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.add_theme_color_override("font_color", COLORS.muted)
		qr_container.add_child(fallback)
	var address := LineEdit.new()
	address.text = ControlServer.pairing_url
	address.editable = false
	address.select_all_on_focus = true
	panel_content.add_child(address)
	var adapters := ControlServer.private_addresses()
	if adapters.size() > 1:
		var adapter_option := OptionButton.new()
		for item in adapters:
			adapter_option.add_item(item)
		adapter_option.item_selected.connect(func(index: int): ControlServer.select_address(adapters[index]); _show_panel("pair"))
		panel_content.add_child(_labeled("Network adapter", adapter_option))
	var rotate := _button("GENERATE NEW PAIRING CODE")
	rotate.pressed.connect(func(): ControlServer.rotate_session(); _show_panel("pair"))
	panel_content.add_child(rotate)
	_add_notice("The browser page is served locally. No account, cloud service, or Internet connection is used.", COLORS.muted)

func _build_flight_panel() -> void:
	_add_heading("FREE FLIGHT", "Tune your feel, practise safely, and reset without penalty.")
	var arm_button := _button("ARM / DISARM  [SPACE]")
	arm_button.pressed.connect(drone.toggle_arm)
	panel_content.add_child(arm_button)
	var mode_button := _button("SWITCH ANGLE / ACRO")
	mode_button.pressed.connect(func(): drone.flight_mode = &"acro" if drone.flight_mode == &"angle" else &"angle"; mode_label.text = String(drone.flight_mode).to_upper())
	panel_content.add_child(mode_button)
	var reset_button := _button("RESET TO SPAWN  [R]")
	reset_button.pressed.connect(drone.reset_to_spawn)
	panel_content.add_child(reset_button)
	var turtle_button := _button("TURTLE RECOVERY")
	turtle_button.pressed.connect(drone.activate_turtle)
	panel_content.add_child(turtle_button)
	_add_notice("Angle commands tilt and self-levels. Acro commands rotation rate and does not self-level.", COLORS.muted)

func _build_lessons_panel() -> void:
	_add_heading("BASIC LESSONS", "Repeat each drill to improve your personal best.")
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_content.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 9)
	scroll.add_child(list)
	for lesson in LessonManager.LESSONS:
		var best := ProfileStore.get_lesson_result(lesson.id)
		var suffix := ""
		if not best.is_empty():
			suffix = "  ·  %s  %d pts" % [best.get("medal", ""), best.get("points", 0)]
		var button := _button(String(lesson.name).to_upper() + suffix)
		button.tooltip_text = lesson.description
		button.pressed.connect(_start_lesson.bind(String(lesson.id)))
		list.add_child(button)
	var free := _button("RETURN TO FREE FLIGHT")
	free.pressed.connect(func(): lessons.stop_lesson(); _clear_lesson_markers(); drone.reset_to_spawn())
	panel_content.add_child(free)

func _build_tuning_panel() -> void:
	_add_heading("PID & RATES", "Changes apply while disarmed. Save custom profiles to keep them.")
	var presets := OptionButton.new()
	var profile_names := ProfileStore.list_profiles()
	for index in profile_names.size():
		presets.add_item(profile_names[index])
		if profile_names[index] == ProfileStore.active_profile_name:
			presets.select(index)
	presets.item_selected.connect(func(index: int): ProfileStore.load_profile(profile_names[index]); _show_panel("tuning"))
	panel_content.add_child(_labeled("Profile", presets))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_content.add_child(scroll)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_theme_constant_override("separation", 8)
	scroll.add_child(fields)
	_add_numeric_field(fields, "Angle limit", ["angle_limit_deg"], 10, 80, 1, "°")
	_add_numeric_field(fields, "Thrust / weight", ["drone", "thrust_to_weight"], 1.05, 6, 0.05, "×")
	_add_numeric_field(fields, "Motor response", ["drone", "motor_time_constant_s"], 0.005, 0.25, 0.001, " s")
	for axis in ["pitch", "roll", "yaw"]:
		var separator := HSeparator.new()
		fields.add_child(separator)
		var axis_label := Label.new()
		axis_label.text = axis.to_upper()
		axis_label.add_theme_color_override("font_color", COLORS.mint)
		fields.add_child(axis_label)
		_add_numeric_field(fields, "P", ["pid", axis, "p"], 0, 2, 0.001)
		_add_numeric_field(fields, "I", ["pid", axis, "i"], 0, 2, 0.001)
		_add_numeric_field(fields, "D", ["pid", axis, "d"], 0, 0.5, 0.0001)
		_add_numeric_field(fields, "Maximum rate", ["rates", axis, "max_deg_s"], 30, 1500, 10, " °/s")
		_add_numeric_field(fields, "Expo", ["rates", axis, "expo"], 0, 1, 0.01)
	var save_row := HBoxContainer.new()
	var name_input := LineEdit.new()
	name_input.placeholder_text = "Custom profile name"
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_row.add_child(name_input)
	var save := _button("SAVE AS")
	save.pressed.connect(func():
		var result := ProfileStore.save_profile(name_input.text, ProfileStore.active_profile)
		toast_label.text = "Profile saved" if result.ok else ", ".join(result.errors)
	)
	save_row.add_child(save)
	panel_content.add_child(save_row)
	var transfer_row := HBoxContainer.new()
	transfer_row.add_theme_constant_override("separation", 8)
	var import_button := _button("IMPORT JSON")
	import_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_button.pressed.connect(_open_import_dialog)
	transfer_row.add_child(import_button)
	var export_button := _button("EXPORT JSON")
	export_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	export_button.pressed.connect(_open_export_dialog)
	transfer_row.add_child(export_button)
	panel_content.add_child(transfer_row)
	_set_tuning_enabled(not drone.armed)

func _build_controller_panel() -> void:
	_add_heading("CONTROLLER", "Shared input settings are ready for the phase-two gamepad adapter.")
	var input_config: Dictionary = ProfileStore.active_profile.get("input", {})
	var mode := OptionButton.new()
	mode.add_item("Mode 1", 1)
	mode.add_item("Mode 2", 2)
	mode.add_item("Custom", 3)
	var configured_mode := int(input_config.get("mode", 2))
	mode.select(clampi(configured_mode - 1, 0, 2))
	mode.item_selected.connect(func(index: int): input_config["mode"] = mode.get_item_id(index); _commit_profile_preview(); _show_panel("controller"))
	panel_content.add_child(_labeled("Stick mode", mode))
	if configured_mode == 3:
		var mapping: Dictionary = input_config.get("mapping", {})
		var sources := ["left_x", "left_y", "right_x", "right_y"]
		for channel in ["throttle", "yaw", "pitch", "roll"]:
			var source_option := OptionButton.new()
			for source in sources:
				source_option.add_item(String(source).replace("_", " ").capitalize())
			if String(mapping.get(channel, "")) in sources:
				source_option.select(sources.find(String(mapping[channel])))
			source_option.item_selected.connect(func(index: int, target: String = channel): mapping[target] = sources[index]; input_config["mapping"] = mapping; _commit_profile_preview())
			panel_content.add_child(_labeled(channel.capitalize() + " axis", source_option))
	_add_numeric_field(panel_content, "Deadzone", ["input", "deadzone"], 0, 0.25, 0.005)
	_add_numeric_field(panel_content, "Sensitivity", ["input", "sensitivity"], 0.25, 2.0, 0.05, "×")
	var reverse: Dictionary = input_config.get("reverse", {})
	for axis in ["throttle", "yaw", "pitch", "roll"]:
		var checkbox := CheckBox.new()
		checkbox.text = "Reverse " + axis.capitalize()
		checkbox.button_pressed = bool(reverse.get(axis, false))
		checkbox.toggled.connect(func(value: bool): reverse[axis] = value; input_config["reverse"] = reverse; _commit_profile_preview())
		panel_content.add_child(checkbox)
	_add_notice("Mode 2 uses a non-spring throttle. Releasing the left stick keeps its vertical position while yaw recentres.", COLORS.muted)

func _build_results_panel() -> void:
	_add_heading("PERSONAL BESTS", "Stored only on this computer.")
	var any_result := false
	for lesson in LessonManager.LESSONS:
		var result := ProfileStore.get_lesson_result(lesson.id)
		if result.is_empty():
			continue
		any_result = true
		var row := Label.new()
		row.text = "%s\n%s · %.2f s · %d pts · %d collisions" % [lesson.name, result.medal, result.elapsed_s, result.points, result.collisions]
		row.add_theme_stylebox_override("normal", _style(COLORS.panel_alt, 8, COLORS.line))
		row.add_theme_constant_override("outline_size", 0)
		row.add_theme_color_override("font_color", COLORS.text)
		panel_content.add_child(row)
	if not any_result:
		_add_notice("No completed lessons yet. Choose LESSONS and start training.", COLORS.muted)

func _add_heading(title_text: String, subtitle: String) -> void:
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COLORS.text)
	panel_content.add_child(title)
	var sub := Label.new()
	sub.text = subtitle
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_color_override("font_color", COLORS.muted)
	panel_content.add_child(sub)
	panel_content.add_child(HSeparator.new())

func _add_notice(text: String, color: Color) -> void:
	var notice := Label.new()
	notice.text = text
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.add_theme_color_override("font_color", color)
	panel_content.add_child(notice)

func _add_numeric_field(parent: Container, label_text: String, path: Array, minimum: float, maximum: float, step: float, suffix := "") -> void:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.suffix = suffix
	spin.value = float(_get_nested(ProfileStore.active_profile, path))
	spin.value_changed.connect(func(value: float):
		_set_nested(ProfileStore.active_profile, path, value)
		_commit_profile_preview()
	)
	tuning_controls.append(spin)
	parent.add_child(_labeled(label_text, spin))

func _labeled(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	control.custom_minimum_size.x = 145
	row.add_child(control)
	return row

func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 40)
	button.add_theme_stylebox_override("normal", _style(COLORS.panel_alt, 8, COLORS.line))
	button.add_theme_stylebox_override("hover", _style(Color("214565"), 8, COLORS.mint))
	button.add_theme_color_override("font_color", COLORS.text)
	return button

func _badge(text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	return label

func _style(color: Color, radius: int, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = border
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _keyboard_frame(delta: float) -> DroneInputFrame:
	var frame := DroneInputFrame.new()
	if Input.is_key_pressed(KEY_F): keyboard_throttle -= delta * 0.35
	if Input.is_key_pressed(KEY_R): keyboard_throttle += delta * 0.35
	keyboard_throttle = clampf(keyboard_throttle, 0.0, 1.0)
	frame.throttle = keyboard_throttle
	frame.pitch = float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S))
	frame.roll = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
	frame.yaw = float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
	frame.requested_mode = drone.flight_mode
	return frame

func _apply_input_profile(frame: DroneInputFrame) -> DroneInputFrame:
	var config: Dictionary = ProfileStore.active_profile.get("input", {})
	var deadzone := float(config.get("deadzone", 0.03))
	var sensitivity := float(config.get("sensitivity", 1.0))
	var reverse: Dictionary = config.get("reverse", {})
	var adjusted := DroneInputFrame.from_wire(frame.to_dictionary(), frame.received_time_ms)
	for axis in ["yaw", "pitch", "roll"]:
		var value: float = adjusted.get(axis)
		value = 0.0 if absf(value) <= deadzone else signf(value) * (absf(value) - deadzone) / (1.0 - deadzone)
		value = clampf(value * sensitivity, -1.0, 1.0)
		if bool(reverse.get(axis, false)): value *= -1.0
		adjusted.set(axis, value)
	if bool(reverse.get("throttle", false)):
		adjusted.throttle = 1.0 - adjusted.throttle
	return adjusted

func _update_cameras(delta: float) -> void:
	if active_camera_mode == "los":
		var los_distance := (LOS_CAMERA_POSITION - LOS_CAMERA_TARGET).length()
		los_camera.global_position = LOS_CAMERA_TARGET + _camera_orbit_offset(los_distance)
		los_camera.look_at(LOS_CAMERA_TARGET, Vector3.UP)
		return
	var desired := drone.global_position + _camera_orbit_offset(FOLLOW_CAMERA_DISTANCE)
	follow_camera.global_position = follow_camera.global_position.lerp(desired, 1.0 - exp(-delta * 5.0))
	follow_camera.look_at(drone.global_position + Vector3(0.0, 0.08, 0.0), Vector3.UP)

func _rotate_camera_orbit(mouse_delta: Vector2) -> void:
	var orbit := CameraOrbitMath.rotate(
		Vector2(camera_orbit_yaw, camera_orbit_pitch),
		mouse_delta,
		CAMERA_DRAG_SENSITIVITY,
		CAMERA_MIN_PITCH,
		CAMERA_MAX_PITCH
	)
	camera_orbit_yaw = orbit.x
	camera_orbit_pitch = orbit.y

func _camera_orbit_offset(distance: float) -> Vector3:
	return CameraOrbitMath.offset(camera_orbit_yaw, camera_orbit_pitch, distance)

func _update_hud() -> void:
	connection_label.text = "PHONE LIVE" if ControlServer.is_controller_connected() else "KEYBOARD / NO PHONE"
	connection_label.add_theme_color_override("font_color", COLORS.mint if ControlServer.is_controller_connected() else COLORS.red)
	armed_label.text = "ARMED" if drone.armed else "DISARMED"
	armed_label.add_theme_color_override("font_color", COLORS.red if drone.armed else COLORS.muted)
	mode_label.text = String(drone.flight_mode).to_upper()
	profile_label.text = ProfileStore.active_profile_name.to_upper()
	if lessons.running:
		timer_label.text = "%02d:%04.1f" % [int(lessons.elapsed) / 60, fmod(lessons.elapsed, 60.0)]
	else:
		timer_label.text = "ALT %.2f m" % maxf(0.0, drone.position.y - 0.1)

func _toggle_camera() -> void:
	active_camera_mode = "follow" if active_camera_mode == "los" else "los"
	los_camera.current = active_camera_mode == "los"
	follow_camera.current = active_camera_mode == "follow"
	if active_camera_mode == "follow":
		follow_camera.global_position = drone.global_position + _camera_orbit_offset(FOLLOW_CAMERA_DISTANCE)

func _start_lesson(lesson_id: String) -> void:
	drone.reset_to_spawn()
	lessons.start_lesson(lesson_id)
	_set_panel_collapsed(true)
	toast_label.text = "Lesson started — connect your phone, arm, and follow the objective."

func _on_profile_changed(profile: Dictionary) -> void:
	drone.apply_profile(profile)
	profile_label.text = ProfileStore.active_profile_name.to_upper()

func _commit_profile_preview() -> void:
	if drone.armed:
		toast_label.text = "Disarm before changing tuning values."
		return
	drone.apply_profile(ProfileStore.active_profile)

func _set_tuning_enabled(enabled: bool) -> void:
	for control in tuning_controls:
		control.editable = enabled if control is SpinBox else enabled

func _open_import_dialog() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.json ; Simulator profiles"])
	dialog.file_selected.connect(func(path: String):
		var result := ProfileStore.import_profile(path)
		toast_label.text = "Profile imported" if result.ok else ", ".join(result.errors)
		if result.ok: _show_panel("tuning")
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)

func _open_export_dialog() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.current_file = ProfileStore.active_profile_name.to_lower().replace(" ", "-") + ".json"
	dialog.filters = PackedStringArray(["*.json ; Simulator profiles"])
	dialog.file_selected.connect(func(path: String):
		var result := ProfileStore.export_profile(path)
		toast_label.text = "Profile exported to " + path if result.ok else "Could not export profile"
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)

func _on_connection_changed(connected: bool) -> void:
	toast_label.text = "Phone controller connected." if connected else "Phone controller disconnected. Simulation disarmed."

func _on_failsafe(reason: String) -> void:
	drone.set_armed(false)
	lessons.pause_for_failsafe()
	toast_label.text = "FAILSAFE · " + reason + " · Re-arm manually after reconnecting."

func _on_remote_command(command: StringName) -> void:
	match command:
		&"toggle_arm": drone.toggle_arm()
		&"reset": drone.reset_to_spawn()
		&"turtle": drone.activate_turtle()

func _on_armed_changed(value: bool) -> void:
	_set_tuning_enabled(not value)

func _on_collision(speed: float) -> void:
	if speed > 1.0:
		toast_label.text = "Impact %.1f m/s" % speed

func _on_lesson_finished(result: Dictionary) -> void:
	_clear_lesson_markers()
	panel.visible = true
	toast_label.text = "%s · %s · %d points%s" % [result.lesson_name, result.medal, result.points, " · NEW BEST" if result.personal_best else ""]
	_show_panel("results")
	drone.set_armed(false)

func _network_status() -> Dictionary:
	return {
		"armed": drone.armed,
		"flight_mode": String(drone.flight_mode),
		"altitude_m": maxf(0.0, drone.position.y - 0.1),
		"lesson_objective": objective_label.text,
		"input_config": ProfileStore.active_profile.get("input", {}),
	}

func _show_lesson_markers(definition: Dictionary) -> void:
	_clear_lesson_markers()
	match String(definition.id):
		"takeoff_land":
			_add_marker(Vector3(-1.9, 1.05, 0.0), 0.28, COLORS.mint)
		"hover", "yaw":
			_add_marker(Vector3(0.0, 1.5, 0.0), 0.35, COLORS.blue)
		"slalom":
			for point in [Vector3(-1.7, 0.8, -0.65), Vector3(-0.8, 1.4, 0.65), Vector3(0.0, 1.0, -0.65), Vector3(0.8, 1.6, 0.65), Vector3(1.65, 1.1, 0.0)]:
				_add_marker(point, 0.25, COLORS.mint)
		"goal":
			_add_marker(Vector3(2.0, 1.55, 0.0), 0.24, COLORS.red)

func _add_marker(marker_position: Vector3, radius: float, color: Color) -> void:
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	marker.mesh = mesh
	marker.position = marker_position
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color.r, color.g, color.b, 0.16)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.emission_enabled = true
	material.emission = color * 0.32
	marker.material_override = material
	lesson_markers.add_child(marker)

func _clear_lesson_markers() -> void:
	for child in lesson_markers.get_children():
		child.queue_free()

func _get_nested(dictionary: Dictionary, path: Array) -> Variant:
	var current: Variant = dictionary
	for key in path:
		current = current.get(key)
	return current

func _set_nested(dictionary: Dictionary, path: Array, value: Variant) -> void:
	var current := dictionary
	for index in range(path.size() - 1):
		current = current[path[index]]
	current[path[-1]] = value

func _make_qr_texture(data: String) -> Texture2D:
	var qr := QRCodeGenerator.new()
	qr.put_byte(data.to_utf8_buffer())
	var qr_data: PackedByteArray = qr.encode()
	var image: Image = QRCodeGenerator.generate_image(qr_data, 6, Color.WHITE, Color("071426"), 4)
	return ImageTexture.create_from_image(image)

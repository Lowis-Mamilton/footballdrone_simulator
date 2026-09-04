extends Node

signal profile_changed(profile: Dictionary)
signal results_changed()

const SCHEMA_VERSION := 1
const USER_ROOT := "user://football_drone"
const PROFILE_DIR := USER_ROOT + "/profiles"
const RESULTS_PATH := USER_ROOT + "/results.json"
const SETTINGS_PATH := USER_ROOT + "/settings.json"
const BUILTIN_PATHS := {
	"Stable": "res://config/profiles/stable.json",
	"Standard": "res://config/profiles/standard.json",
	"Responsive": "res://config/profiles/responsive.json",
}

var active_profile: Dictionary = {}
var active_profile_name := "Standard"
var results: Dictionary = {"schema_version": SCHEMA_VERSION, "lessons": {}}
var settings: Dictionary = {
	"schema_version": SCHEMA_VERSION,
	"active_profile": "Standard",
	"graphics_quality": "medium",
	"master_volume": 0.8,
	"camera_mode": "los",
}

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PROFILE_DIR))
	_load_settings()
	_load_results()
	load_profile(String(settings.get("active_profile", "Standard")))

func list_profiles() -> PackedStringArray:
	var names := PackedStringArray(BUILTIN_PATHS.keys())
	var directory := DirAccess.open(PROFILE_DIR)
	if directory:
		for file_name in directory.get_files():
			if file_name.ends_with(".json"):
				var candidate := file_name.trim_suffix(".json")
				if candidate not in names:
					names.append(candidate)
	return names

func load_profile(profile_name: String) -> Dictionary:
	var path := String(BUILTIN_PATHS.get(profile_name, PROFILE_DIR + "/" + _safe_name(profile_name) + ".json"))
	var loaded: Variant = _read_json(path)
	var validation: PackedStringArray = validate_profile(loaded)
	if not validation.is_empty():
		push_warning("Invalid profile '%s': %s" % [profile_name, ", ".join(validation)])
		if profile_name != "Standard":
			return load_profile("Standard")
		return {}
	active_profile = loaded.duplicate(true)
	active_profile_name = profile_name
	settings["active_profile"] = profile_name
	_save_json_atomic(SETTINGS_PATH, settings)
	profile_changed.emit(active_profile)
	return active_profile

func save_profile(profile_name: String, profile: Dictionary) -> Dictionary:
	var candidate := profile.duplicate(true)
	candidate["schema_version"] = SCHEMA_VERSION
	candidate["name"] = profile_name.strip_edges()
	var errors := validate_profile(candidate)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	if candidate["name"] in BUILTIN_PATHS:
		return {"ok": false, "errors": ["Built-in profiles cannot be overwritten; choose another name."]}
	var path := PROFILE_DIR + "/" + _safe_name(candidate["name"]) + ".json"
	if not _save_json_atomic(path, candidate):
		return {"ok": false, "errors": ["Could not write the profile."]}
	active_profile = candidate
	active_profile_name = candidate["name"]
	settings["active_profile"] = active_profile_name
	_save_json_atomic(SETTINGS_PATH, settings)
	profile_changed.emit(active_profile)
	return {"ok": true, "path": ProjectSettings.globalize_path(path)}

func import_profile(source_path: String) -> Dictionary:
	var candidate: Variant = _read_json(source_path)
	var errors: PackedStringArray = validate_profile(candidate)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	return save_profile(String(candidate.get("name", "Imported profile")), candidate)

func export_profile(destination_path: String) -> Dictionary:
	if active_profile.is_empty():
		return {"ok": false, "errors": ["No active profile."]}
	return {"ok": _save_json_atomic(destination_path, active_profile), "path": destination_path}

func validate_profile(candidate: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not candidate is Dictionary:
		errors.append("Root must be an object.")
		return errors
	if int(candidate.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("Unsupported schema_version.")
	if String(candidate.get("name", "")).strip_edges().is_empty():
		errors.append("name is required.")
	var drone: Variant = candidate.get("drone")
	if not drone is Dictionary:
		errors.append("drone must be an object.")
	else:
		_validate_number(errors, drone, "mass_kg", 0.05, 0.3)
		_validate_number(errors, drone, "cage_diameter_m", 0.15, 0.22)
		_validate_number(errors, drone, "thrust_to_weight", 1.05, 6.0)
		_validate_number(errors, drone, "motor_time_constant_s", 0.005, 0.25)
		_validate_number(errors, drone, "linear_drag", 0.0, 1.0)
		_validate_number(errors, drone, "quadratic_drag", 0.0, 1.0)
		_validate_number(errors, drone, "angular_drag", 0.0, 1.0)
	var pid: Variant = candidate.get("pid")
	if not pid is Dictionary:
		errors.append("pid must be an object.")
	else:
		for axis in ["pitch", "roll", "yaw"]:
			var values: Variant = pid.get(axis)
			if not values is Dictionary:
				errors.append("pid.%s must be an object." % axis)
			else:
				_validate_number(errors, values, "p", 0.0, 2.0, "pid.%s." % axis)
				_validate_number(errors, values, "i", 0.0, 2.0, "pid.%s." % axis)
				_validate_number(errors, values, "d", 0.0, 0.5, "pid.%s." % axis)
	var rates: Variant = candidate.get("rates")
	if not rates is Dictionary:
		errors.append("rates must be an object.")
	else:
		for axis in ["pitch", "roll", "yaw"]:
			var values: Variant = rates.get(axis)
			if not values is Dictionary:
				errors.append("rates.%s must be an object." % axis)
			else:
				_validate_number(errors, values, "max_deg_s", 30.0, 1500.0, "rates.%s." % axis)
				_validate_number(errors, values, "expo", 0.0, 1.0, "rates.%s." % axis)
	var input: Variant = candidate.get("input")
	if not input is Dictionary:
		errors.append("input must be an object.")
	else:
		_validate_number(errors, input, "mode", 1.0, 3.0, "input.")
		_validate_number(errors, input, "deadzone", 0.0, 0.25, "input.")
		_validate_number(errors, input, "sensitivity", 0.25, 2.0, "input.")
		var mapping: Variant = input.get("mapping")
		if not mapping is Dictionary:
			errors.append("input.mapping must be an object.")
		else:
			var used := PackedStringArray()
			for channel in ["throttle", "yaw", "pitch", "roll"]:
				var source := String(mapping.get(channel, ""))
				if source not in ["left_x", "left_y", "right_x", "right_y"]:
					errors.append("input.mapping.%s is invalid." % channel)
				elif source in used:
					errors.append("input.mapping must assign each physical axis once.")
				else:
					used.append(source)
	return errors

func record_lesson_result(lesson_id: String, score: Dictionary) -> bool:
	var lessons: Dictionary = results.get("lessons", {})
	var previous: Dictionary = lessons.get(lesson_id, {})
	var is_best := previous.is_empty() or int(score.get("points", 0)) > int(previous.get("points", 0))
	if is_best:
		lessons[lesson_id] = score.duplicate(true)
		results["lessons"] = lessons
		_save_json_atomic(RESULTS_PATH, results)
		results_changed.emit()
	return is_best

func get_lesson_result(lesson_id: String) -> Dictionary:
	return results.get("lessons", {}).get(lesson_id, {})

func _validate_number(errors: PackedStringArray, values: Dictionary, key: String, minimum: float, maximum: float, prefix := "drone.") -> void:
	var value: Variant = values.get(key)
	if not (value is float or value is int) or not is_finite(float(value)):
		errors.append("%s%s must be a finite number." % [prefix, key])
	elif float(value) < minimum or float(value) > maximum:
		errors.append("%s%s must be between %s and %s." % [prefix, key, minimum, maximum])

func _load_settings() -> void:
	var loaded: Variant = _read_json(SETTINGS_PATH)
	if loaded is Dictionary and int(loaded.get("schema_version", -1)) == SCHEMA_VERSION:
		settings.merge(loaded, true)

func _load_results() -> void:
	var loaded: Variant = _read_json(RESULTS_PATH)
	if loaded is Dictionary and int(loaded.get("schema_version", -1)) == SCHEMA_VERSION:
		results = loaded

func _read_json(path: String) -> Variant:
	var absolute := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path) and FileAccess.file_exists(absolute + ".bak"):
		DirAccess.rename_absolute(absolute + ".bak", absolute)
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed != null else {}

func _save_json_atomic(path: String, data: Dictionary) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var temporary := absolute + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if not file:
		return false
	file.store_string(JSON.stringify(data, "  "))
	file.close()
	var backup := absolute + ".bak"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	if FileAccess.file_exists(absolute) and DirAccess.rename_absolute(absolute, backup) != OK:
		DirAccess.remove_absolute(temporary)
		return false
	if DirAccess.rename_absolute(temporary, absolute) != OK:
		if FileAccess.file_exists(backup):
			DirAccess.rename_absolute(backup, absolute)
		return false
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	return true

func _safe_name(value: String) -> String:
	var safe := value.strip_edges().to_lower().replace(" ", "-")
	for character in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		safe = safe.replace(character, "-")
	return safe.left(64)

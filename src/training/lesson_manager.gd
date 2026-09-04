class_name LessonManager
extends Node

signal lesson_started(definition: Dictionary)
signal objective_changed(text: String)
signal lesson_finished(result: Dictionary)

const LESSONS := [
	{"id": "takeoff_land", "name": "Takeoff & Landing", "description": "Rise above 1 m, hold briefly, then land gently.", "gold": 25.0, "silver": 40.0, "bronze": 60.0},
	{"id": "hover", "name": "Stable Hover", "description": "Hold inside the target volume for 8 seconds.", "gold": 16.0, "silver": 25.0, "bronze": 40.0},
	{"id": "yaw", "name": "Yaw Orientation", "description": "Complete a full yaw rotation while holding altitude.", "gold": 18.0, "silver": 28.0, "bronze": 45.0},
	{"id": "slalom", "name": "Slalom", "description": "Fly through all five checkpoints in order.", "gold": 24.0, "silver": 38.0, "bronze": 58.0},
	{"id": "goal", "name": "Goal Ring", "description": "Approach cleanly and pass through the red goal.", "gold": 12.0, "silver": 22.0, "bronze": 35.0},
	{"id": "turtle", "name": "Turtle Recovery", "description": "Recover from an inverted start without resetting.", "gold": 10.0, "silver": 18.0, "bronze": 30.0},
]

var active: Dictionary = {}
var elapsed := 0.0
var collisions := 0
var resets := 0
var disarms := 0
var phase := 0
var hold_time := 0.0
var yaw_accumulated := 0.0
var previous_yaw := 0.0
var checkpoint_index := 0
var running := false
var session_paused := false
var drone: DroneBall

func bind_drone(value: DroneBall) -> void:
	drone = value
	drone.collision_happened.connect(func(_speed: float): if running: collisions += 1)
	drone.reset_performed.connect(func(): if running: resets += 1)
	drone.armed_changed.connect(_on_drone_armed_changed)

func start_lesson(lesson_id: String) -> void:
	active = {}
	for lesson in LESSONS:
		if lesson.id == lesson_id:
			active = lesson
			break
	if active.is_empty() or not drone:
		return
	elapsed = 0.0
	collisions = 0
	resets = 0
	disarms = 0
	phase = 0
	hold_time = 0.0
	yaw_accumulated = 0.0
	previous_yaw = drone.rotation.y
	checkpoint_index = 0
	running = true
	session_paused = lesson_id != "turtle"
	if lesson_id == "turtle":
		drone.rotation_degrees.z = 180.0
	objective_changed.emit(_objective())
	lesson_started.emit(active)

func stop_lesson() -> void:
	running = false
	session_paused = false
	active = {}
	objective_changed.emit("Free flight")

func _physics_process(delta: float) -> void:
	if not running or not drone or session_paused:
		return
	elapsed += delta
	match String(active.id):
		"takeoff_land": _update_takeoff(delta)
		"hover": _update_hover(delta)
		"yaw": _update_yaw()
		"slalom": _update_slalom()
		"goal": _update_goal()
		"turtle": _update_turtle()
	if elapsed > 120.0:
		_finish(false)

func _update_takeoff(delta: float) -> void:
	if phase == 0 and drone.position.y > 1.0:
		phase = 1
		hold_time = 0.0
		objective_changed.emit(_objective())
	elif phase == 1:
		if drone.position.y > 0.85:
			hold_time += delta
		if hold_time >= 2.0:
			phase = 2
			objective_changed.emit(_objective())
	elif phase == 2 and drone.position.y < 0.17 and drone.linear_velocity.length() < 0.45:
		_finish(true)

func _update_hover(delta: float) -> void:
	var target := Vector3(0.0, 1.5, 0.0)
	if drone.position.distance_to(target) < 0.35:
		hold_time += delta
	else:
		hold_time = maxf(0.0, hold_time - delta * 0.5)
	objective_changed.emit("Hold target: %.1f / 8.0 s" % hold_time)
	if hold_time >= 8.0:
		_finish(true)

func _update_yaw() -> void:
	if absf(drone.position.y - 1.3) > 0.55:
		return
	var yaw := drone.rotation.y
	yaw_accumulated += absf(wrapf(yaw - previous_yaw, -PI, PI))
	previous_yaw = yaw
	objective_changed.emit("Yaw rotation: %d%%" % mini(100, int(rad_to_deg(yaw_accumulated) / 3.6)))
	if yaw_accumulated >= TAU:
		_finish(true)

func _update_slalom() -> void:
	var checkpoints := [Vector3(-1.7, 0.8, -0.65), Vector3(-0.8, 1.4, 0.65), Vector3(0.0, 1.0, -0.65), Vector3(0.8, 1.6, 0.65), Vector3(1.65, 1.1, 0.0)]
	if drone.position.distance_to(checkpoints[checkpoint_index]) < 0.36:
		checkpoint_index += 1
		if checkpoint_index >= checkpoints.size():
			_finish(true)
		else:
			objective_changed.emit(_objective())

func _update_goal() -> void:
	if drone.position.x > 2.18 and absf(drone.position.y - 1.55) < 0.18 and absf(drone.position.z) < 0.18:
		_finish(true)

func _update_turtle() -> void:
	if drone.transform.basis.y.dot(Vector3.UP) > 0.86 and elapsed > 0.8:
		_finish(true)

func _objective() -> String:
	if active.is_empty():
		return "Free flight"
	match String(active.id):
		"takeoff_land": return ["Climb above 1 metre", "Hold altitude for 2 seconds", "Land gently"][phase]
		"hover": return "Reach the centre hover target"
		"yaw": return "Hold altitude and complete a full yaw rotation"
		"slalom": return "Checkpoint %d of 5" % (checkpoint_index + 1)
		"goal": return "Pass completely through the red goal"
		"turtle": return "Use TURTLE to recover upright"
	return String(active.description)

func _finish(completed: bool) -> void:
	if not running:
		return
	running = false
	var penalty := collisions * 120 + resets * 300 + disarms * 80
	var points := maxi(0, 10000 - int(elapsed * 100.0) - penalty) if completed else 0
	var medal := "Unranked"
	if completed:
		var adjusted_time := elapsed + collisions * 1.2 + resets * 3.0 + disarms * 0.8
		if adjusted_time <= float(active.gold): medal = "Gold"
		elif adjusted_time <= float(active.silver): medal = "Silver"
		elif adjusted_time <= float(active.bronze): medal = "Bronze"
	var result := {"lesson_id": active.id, "lesson_name": active.name, "completed": completed, "elapsed_s": snappedf(elapsed, 0.01), "collisions": collisions, "resets": resets, "disarms": disarms, "points": points, "medal": medal, "recorded_unix": int(Time.get_unix_time_from_system())}
	var is_best := ProfileStore.record_lesson_result(String(active.id), result) if completed else false
	result["personal_best"] = is_best
	lesson_finished.emit(result)

func pause_for_failsafe() -> void:
	if running:
		session_paused = true
		objective_changed.emit("Controller lost — reconnect and arm to resume")

func _on_drone_armed_changed(is_armed: bool) -> void:
	if not running:
		return
	if not is_armed:
		disarms += 1
		if String(active.get("id", "")) != "turtle":
			session_paused = true
	elif String(active.get("id", "")) != "turtle":
		session_paused = false
		objective_changed.emit(_objective())

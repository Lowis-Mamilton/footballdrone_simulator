class_name PIDAxis
extends RefCounted

var kp: float
var ki: float
var kd: float
var integral_limit: float
var output_limit: float
var integral := 0.0
var previous_measurement := 0.0
var initialized := false

func _init(p: float, i: float, d: float, i_limit: float = 0.35, out_limit: float = 0.5) -> void:
	kp = p
	ki = i
	kd = d
	integral_limit = i_limit
	output_limit = out_limit

func reset(measurement: float = 0.0) -> void:
	integral = 0.0
	previous_measurement = measurement
	initialized = false

func step(setpoint: float, measurement: float, dt: float) -> float:
	if dt <= 0.0:
		return 0.0
	var error := setpoint - measurement
	integral = clampf(integral + error * ki * dt, -integral_limit, integral_limit)
	var derivative := 0.0
	if initialized:
		derivative = -(measurement - previous_measurement) / dt
	initialized = true
	previous_measurement = measurement
	return clampf(kp * error + integral + kd * derivative, -output_limit, output_limit)


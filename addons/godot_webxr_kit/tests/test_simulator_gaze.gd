extends SceneTree

## Headless test for the desktop simulator's gaze mode: it publishes the tracker
## an adapter reads, from the camera, and takes it away again so rays resume.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_webxr_kit/tests/test_simulator_gaze.gd

const Simulator := preload("res://addons/godot_webxr_kit/runtime/xr_simulator.gd")
const ControllerHandAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")

var _failures: Array[String] = []


func _process(_delta: float) -> bool:
	_test_gaze_mode_publishes_and_withdraws()
	if _failures.is_empty():
		print("XR simulator gaze: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR simulator gaze: FAIL (%d)" % _failures.size())
	quit(1)
	return true


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _test_gaze_mode_publishes_and_withdraws() -> void:
	var origin := XROrigin3D.new()
	origin.position = Vector3(3, 0, 0)
	var camera := XRCamera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	origin.add_child(camera)
	var simulator := Simulator.new()
	get_root().add_child(origin)
	get_root().add_child(simulator)
	simulator.set("_origin", origin)
	simulator.set("_camera", camera)
	var adapter := ControllerHandAdapter.new()
	adapter.set("_origin", origin)

	simulator._update_gaze()
	_check(not adapter.get_gaze_state()["connected"], "gaze mode must be off until asked for")

	simulator._set_gaze(true)
	simulator._update_gaze()
	var state: Dictionary = adapter.get_gaze_state()
	_check(state["tracked"], "gaze mode must publish a tracked pose")
	_check((state["origin"] as Vector3).is_equal_approx(camera.global_position), "gaze must start at the camera")

	simulator._set_gaze(false)
	_check(not adapter.get_gaze_state()["connected"], "leaving gaze mode must disconnect the source")

	adapter.free()
	simulator.free()
	origin.free()

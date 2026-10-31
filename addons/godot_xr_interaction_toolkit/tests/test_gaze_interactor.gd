extends SceneTree

## Headless tests for the gaze pointer's own rules: dwell consensus, far-target
## ownership across loss and disconnect, the no-fallback rule, and the seams a
## ray yields through. The interaction chain itself runs in validate_interactions.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_gaze_interactor.gd

const Gaze := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_gaze_interactor.gd")
const Ray := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd")
const ControllerHandAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")
const InputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")
const Poke := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd")

const TRACKED := {"connected": true, "tracked": true, "origin": Vector3(0, 1.6, 0), "direction": Vector3.FORWARD, "basis": Basis.IDENTITY}
const LOST := {"connected": true, "tracked": false}
const GONE := {"connected": false, "tracked": false}
const GRACE := 5.0
const STEP := 0.1


## Stands in for a platform adapter: whatever state the test sets.
class ScriptedAdapter extends "res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd":
	var state := {"connected": false, "tracked": false}

	func get_gaze_state() -> Dictionary:
		return state


class PressTarget extends Node:
	var pressed := false

	func is_poke_pressed(_hand: int) -> bool:
		return pressed


var _failures: Array[String] = []


func _init() -> void:
	_test_dwell_takes_the_plurality()
	_test_dwell_ties_keep_the_current_target()
	_test_dwell_single_sample_is_that_sample()
	_test_adapter_default_is_no_gaze()
	_test_features_are_optional_and_both_spellings()


func _process(_delta: float) -> bool:
	_test_tracked_gaze_owns_far_targeting()
	_test_disconnect_releases_at_once()
	_test_loss_holds_ownership_for_the_grace_period()
	_test_loss_recovery_restarts_the_clock()
	_test_a_source_that_never_tracked_owns_nothing()
	_test_disabled_gaze_owns_nothing()
	_test_missing_gaze_is_never_head_pose()
	_test_head_preview_is_explicit_and_a_real_source_wins()
	_test_ray_yields_only_to_owning_gaze()
	_test_adapter_reads_the_tracker_into_world_space()
	_test_pressing_is_not_merely_in_reach()
	if _failures.is_empty():
		print("XR gaze interactor: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR gaze interactor: FAIL (%d)" % _failures.size())
	quit(1)
	return true


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _samples(entries: Array) -> Array:
	var out: Array = []
	for entry in entries:
		out.append({"t": entry[0], "key": entry[1]})
	return out


func _test_dwell_takes_the_plurality() -> void:
	var samples := _samples([[0.0, 1], [0.05, 1], [0.10, 2], [0.11, 2], [0.15, 1]])
	_check(Gaze.dwell_winner(samples, 2) == 1, "the key holding the most time must win")
	# A single stray frame cannot take it from a held target.
	samples = _samples([[0.0, 1], [0.05, 1], [0.10, 1], [0.11, 2]])
	_check(Gaze.dwell_winner(samples, 1) == 1, "a glance must not change the target")


func _test_dwell_ties_keep_the_current_target() -> void:
	var samples := _samples([[0.0, 0], [0.05, 1], [0.10, 2]])
	_check(Gaze.dwell_winner(samples, 2) == 2, "a tie must stay with the current target")
	_check(Gaze.dwell_winner(samples, 1) == 1, "a tie must stay with the current target")


func _test_dwell_single_sample_is_that_sample() -> void:
	# A frame longer than the window leaves one sample and no consensus to reach.
	_check(Gaze.dwell_winner(_samples([[0.0, 7]]), 3) == 7, "one sample must win outright")


func _test_adapter_default_is_no_gaze() -> void:
	var adapter := InputAdapter.new()
	var state: Dictionary = adapter.get_gaze_state()
	_check(not state["connected"] and not state["tracked"], "a plain adapter reports no gaze source")
	adapter.free()


func _test_features_are_optional_and_both_spellings() -> void:
	var gaze := Gaze.new()
	var optional: PackedStringArray = gaze.get_webxr_optional_features("immersive-vr")
	_check(optional.has("gaze-tracking") and optional.has("eye-tracking"), "both spellings must be requested")
	_check(not gaze.has_method("get_webxr_required_features"), "gaze must never be a required feature")
	gaze.free()


func _rig() -> Array:
	var adapter := ScriptedAdapter.new()
	var gaze := Gaze.new()
	get_root().add_child(adapter)
	gaze.set("_adapter", adapter)
	return [gaze, adapter]


func _drop(rig: Array) -> void:
	for node in rig:
		(node as Node).free()


func _test_tracked_gaze_owns_far_targeting() -> void:
	var rig := _rig()
	_check(not rig[0].owns_far_targeting(), "no gaze yet must own nothing")
	rig[1].state = TRACKED
	rig[0]._update_gaze(STEP)
	_check(rig[0].owns_far_targeting(), "tracked gaze must own far targeting")
	_drop(rig)


func _test_disconnect_releases_at_once() -> void:
	var rig := _rig()
	rig[1].state = TRACKED
	rig[0]._update_gaze(STEP)
	rig[1].state = GONE
	rig[0]._update_gaze(STEP)
	_check(not rig[0].owns_far_targeting(), "a disconnect must hand far targeting back immediately")
	_drop(rig)


func _test_loss_holds_ownership_for_the_grace_period() -> void:
	var rig := _rig()
	rig[0].tracking_loss_grace_seconds = GRACE
	rig[1].state = TRACKED
	rig[0]._update_gaze(STEP)
	rig[1].state = LOST
	rig[0]._update_gaze(STEP)
	_check(rig[0].owns_far_targeting(), "a lost pose must keep ownership")
	_check(rig[0]._aim_pose().is_empty(), "a lost pose must clear the target straight away")
	var elapsed := STEP
	while elapsed < GRACE - STEP:
		rig[0]._update_gaze(STEP)
		elapsed += STEP
	_check(rig[0].owns_far_targeting(), "ownership must last the whole grace period")
	rig[0]._update_gaze(STEP)
	rig[0]._update_gaze(STEP)
	rig[0]._update_gaze(STEP)
	_check(not rig[0].owns_far_targeting(), "ownership must end after the grace period")
	_drop(rig)


func _test_loss_recovery_restarts_the_clock() -> void:
	var rig := _rig()
	rig[0].tracking_loss_grace_seconds = GRACE
	rig[1].state = TRACKED
	rig[0]._update_gaze(STEP)
	rig[1].state = LOST
	rig[0]._update_gaze(GRACE - STEP)
	rig[1].state = TRACKED
	rig[0]._update_gaze(STEP)
	rig[1].state = LOST
	rig[0]._update_gaze(GRACE - STEP)
	_check(rig[0].owns_far_targeting(), "a recovered pose must restart the grace period")
	_drop(rig)


func _test_a_source_that_never_tracked_owns_nothing() -> void:
	var rig := _rig()
	rig[1].state = LOST
	rig[0]._update_gaze(STEP)
	_check(not rig[0].owns_far_targeting(), "only a tracked source may take far targeting")
	_drop(rig)


func _test_disabled_gaze_owns_nothing() -> void:
	var rig := _rig()
	rig[1].state = TRACKED
	rig[0]._update_gaze(STEP)
	rig[0].enabled = false
	_check(not rig[0].owns_far_targeting(), "a disabled block must leave far targeting to the rays")
	_drop(rig)


func _camera_rig() -> Array:
	var origin := XROrigin3D.new()
	var camera := XRCamera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	origin.add_child(camera)
	var adapter := ScriptedAdapter.new()
	var gaze := Gaze.new()
	origin.add_child(gaze)
	get_root().add_child(origin)
	get_root().add_child(adapter)
	gaze.set("_adapter", adapter)
	return [origin, adapter]


func _test_missing_gaze_is_never_head_pose() -> void:
	var rig := _camera_rig()
	var gaze: Node = rig[0].get_child(1)
	gaze._update_gaze(STEP)
	_check(not gaze.owns_far_targeting(), "missing gaze must not silently become head pose")
	_check(gaze._aim_pose().is_empty(), "missing gaze must not aim")
	_drop(rig)


func _test_head_preview_is_explicit_and_a_real_source_wins() -> void:
	var rig := _camera_rig()
	var gaze: Node = rig[0].get_child(1)
	gaze.head_directed_preview = true
	gaze._update_gaze(STEP)
	_check(gaze.owns_far_targeting(), "the preview must drive gaze when asked for")
	var head_origin: Vector3 = gaze._aim_pose()["origin"]
	_check(head_origin.is_equal_approx(Vector3(0, 1.6, 0)), "the preview must aim from the head")
	var source: Dictionary = TRACKED.duplicate()
	source["origin"] = Vector3(0, 9, 0)
	rig[1].state = source
	gaze._update_gaze(STEP)
	_check(gaze._aim_pose()["origin"].is_equal_approx(Vector3(0, 9, 0)), "a real source must beat the preview")
	_drop(rig)


func _test_ray_yields_only_to_owning_gaze() -> void:
	var ray := Ray.new()
	var rig := _rig()
	get_root().add_child(rig[0])
	get_root().add_child(ray)
	_check(not ray._is_suppressed_by_linked_interactor(), "a ray with no tracked gaze must stay live")
	rig[1].state = TRACKED
	rig[0]._update_gaze(STEP)
	_check(ray._is_suppressed_by_linked_interactor(), "a ray must stand down while gaze owns far targeting")
	_check(not rig[0]._is_suppressed_by_linked_interactor(), "gaze must not yield to itself")
	ray.suppress_on_gaze = false
	_check(not ray._is_suppressed_by_linked_interactor(), "suppress_on_gaze off must keep the ray live")
	ray.free()
	_drop(rig)


func _test_adapter_reads_the_tracker_into_world_space() -> void:
	var origin := XROrigin3D.new()
	origin.position = Vector3(2, 0, 0)
	get_root().add_child(origin)
	var adapter := ControllerHandAdapter.new()
	adapter.set("_origin", origin)
	_check(not adapter.get_gaze_state()["connected"], "no tracker must read as no source")
	var tracker := XRControllerTracker.new()
	tracker.name = ControllerHandAdapter.GAZE_TRACKER
	XRServer.add_tracker(tracker)
	var state: Dictionary = adapter.get_gaze_state()
	_check(state["connected"] and not state["tracked"], "a tracker with no pose must read as connected, untracked")
	tracker.set_pose(&"default", Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	state = adapter.get_gaze_state()
	_check(state["tracked"], "a posed tracker must read as tracked")
	_check((state["origin"] as Vector3).is_equal_approx(Vector3(2, 1.6, 0)), "the pose must land in world space")
	_check((state["direction"] as Vector3).is_equal_approx(Vector3.FORWARD), "the ray must run along -Z")
	tracker.invalidate_pose(&"default")
	_check(not adapter.get_gaze_state()["tracked"], "an invalidated pose must read as untracked")
	XRServer.remove_tracker(tracker)
	adapter.free()
	origin.free()


func _test_pressing_is_not_merely_in_reach() -> void:
	var poke := Poke.new()
	var target := PressTarget.new()
	get_root().add_child(target)
	poke._active[1][target] = true
	_check(poke.is_poking(1), "a target in reach reads as poking")
	_check(not poke.is_pressing(1), "reach alone must not read as pressing")
	target.pressed = true
	_check(poke.is_pressing(1), "a pressed target must read as pressing")
	_check(not poke.is_pressing(0), "the other hand must not read as pressing")
	poke.free()
	target.free()

extends SceneTree

## Headless tests for poke fidelity (docs/poke-fidelity-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd

const XRPokeEvaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")

var _failures: Array[String] = []


func _init() -> void:
	_test_normal_approach_presses_once(_failures)
	_test_lateral_sweep_never_presses(_failures)
	_test_slow_creep_abstains_and_presses(_failures)
	_test_slide_off_cancels_not_releases(_failures)
	_test_jitter_does_not_chatter(_failures)
	_test_fast_pass_through_presses_once(_failures)
	_test_pinned_point_clamps_to_surface(_failures)
	_test_drag_on_suppresses_release(_failures)
	_test_drag_off_still_releases(_failures)
	_test_steep_poke_rescued_by_entry(_failures)
	_test_fast_diagonal_rescued_by_angle(_failures)
	if _failures.is_empty():
		print("XR poke fidelity: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("FAIL: %s" % failure)
	printerr("XR poke fidelity: %d FAILURE(S)" % _failures.size())
	quit(1)


## A default evaluator: XRPokeable's shipped thresholds.
func _make() -> RefCounted:
	var evaluator = XRPokeEvaluator.new()
	evaluator.press_depth = 0.012
	evaluator.release_depth = 0.04
	evaluator.half_size = Vector2(0.05, 0.05)
	return evaluator


## Feed a point sequence, collect the event per sample.
func _run(evaluator, points: Array) -> Array:
	var events := []
	for point in points:
		events.append(evaluator.evaluate(0, point)["event"])
	return events


func _count(events: Array, event: int) -> int:
	var total := 0
	for candidate in events:
		if candidate == event:
			total += 1
	return total


func _check(failures: Array[String], condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_normal_approach_presses_once(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.100),
		Vector3(0.0, 0.0, 0.060),
		Vector3(0.0, 0.0, 0.030),
		Vector3(0.0, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"normal approach: expected exactly 1 PRESSED, got %s" % [events])


func _test_lateral_sweep_never_presses(failures: Array[String]) -> void:
	# Enters from OUTSIDE the face rectangle, already at press depth, and
	# sweeps across. This is the failure the gate exists to prevent.
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.200, 0.0, 0.008),
		Vector3(0.030, 0.0, 0.008),
		Vector3(0.000, 0.0, 0.008),
		Vector3(-0.030, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 0,
			"lateral sweep: expected no PRESSED, got %s" % [events])


## Isolates the ABSTAIN rule. Two constraints make this test actually test it:
## the entry test must stay REQUIRED (so it cannot supply the pass), and the
## motion must carry a LATERAL component. A purely axial creep satisfies the
## angle test at any magnitude, so an axial fixture would pass with the
## abstain deleted - which is exactly the mutation this must catch.
func _test_slow_creep_abstains_and_presses(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.require_entry_through_face = true
	evaluator.min_approach_travel = 0.003
	# Both samples are already at press depth, so in_front is never set and
	# only the angle test can arm. Window travel is 1.5 mm, mostly sideways.
	var events := _run(evaluator, [
		Vector3(0.0000, 0.0, 0.0110),
		Vector3(0.0015, 0.0, 0.0108),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"slow creep: expected 1 PRESSED via abstain, got %s" % [events])


func _test_slide_off_cancels_not_releases(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.080, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.CANCELLED) == 1,
			"slide off: expected 1 CANCELLED, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"slide off: expected no RELEASED, got %s" % [events])


func _test_jitter_does_not_chatter(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.0, 0.0, 0.014),
		Vector3(0.0, 0.0, 0.010),
		Vector3(0.0, 0.0, 0.013),
		Vector3(0.0, 0.0, 0.009),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"jitter: expected 1 PRESSED, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"jitter: expected no RELEASED, got %s" % [events])


func _test_fast_pass_through_presses_once(failures: Array[String]) -> void:
	# One sample in front, the next already past the surface.
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.200),
		Vector3(0.0, 0.0, -0.020),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"fast pass-through: expected 1 PRESSED, got %s" % [events])


func _test_pinned_point_clamps_to_surface(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.evaluate(0, Vector3(0.0, 0.0, 0.050))
	var result: Dictionary = evaluator.evaluate(0, Vector3(0.010, 0.020, -0.030))
	var pinned: Vector3 = result["pinned_point"]
	_check(failures, is_equal_approx(pinned.z, 0.0),
			"pinned point: expected z clamped to 0, got %f" % pinned.z)
	_check(failures, is_equal_approx(pinned.x, 0.010) and is_equal_approx(pinned.y, 0.020),
			"pinned point: planar coordinates must pass through, got %s" % [pinned])


func _test_drag_on_suppresses_release(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.interpret_drag = true
	evaluator.drag_threshold = 0.010
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.050),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.DRAG) >= 1,
			"drag on: expected at least 1 DRAG, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"drag on: RELEASED must be suppressed, got %s" % [events])


func _test_drag_off_still_releases(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.interpret_drag = false
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.050),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.DRAG) == 0,
			"drag off: expected no DRAG, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 1,
			"drag off: expected 1 RELEASED, got %s" % [events])


## RESCUE CASE A. A deliberate poke ~50 deg off the normal, at a 45 deg limit.
## The angle test rejects it; the entry test must rescue it.
##
## TRAP: do NOT isolate by setting require_entry_through_face = false. That
## OPENS the gate unconditionally (_entry_passes returns true), so the press
## would still happen and the test would assert the opposite of what it looks
## like it asserts. Isolate instead by making the FIRST sample land outside
## the face, so in_front is never set and only the angle test remains.
func _test_steep_poke_rescued_by_entry(failures: Array[String]) -> void:
	var armed_evaluator = _make()
	armed_evaluator.half_size = Vector2(0.200, 0.200)
	armed_evaluator.max_approach_angle = 45.0
	var armed := _run(armed_evaluator, [
		Vector3(0.000, 0.0, 0.050),
		Vector3(0.060, 0.0, 0.000),
	])
	_check(failures, _count(armed, XRPokeEvaluator.Event.PRESSED) == 1,
			"steep poke: the entry test must rescue it, got %s" % [armed])

	var blocked_evaluator = _make()
	blocked_evaluator.half_size = Vector2(0.200, 0.200)
	blocked_evaluator.max_approach_angle = 45.0
	var blocked := _run(blocked_evaluator, [
		Vector3(0.300, 0.0, 0.050),
		Vector3(0.060, 0.0, 0.000),
	])
	_check(failures, _count(blocked, XRPokeEvaluator.Event.PRESSED) == 0,
			"steep poke: without entry through the face there must be no press, got %s" % [blocked])


## RESCUE CASE B. A fast diagonal whose PREVIOUS sample fell outside the face
## rectangle, so the entry test never armed. The angle test must rescue it.
func _test_fast_diagonal_rescued_by_angle(failures: Array[String]) -> void:
	var points := [
		Vector3(0.060, 0.0, 0.050),
		Vector3(0.000, 0.0, -0.001),
	]
	var with_angle = _make()
	var armed := _run(with_angle, points)
	_check(failures, _count(armed, XRPokeEvaluator.Event.PRESSED) == 1,
			"fast diagonal: angle test must rescue it, got %s" % [armed])

	var without_angle = _make()
	without_angle.max_approach_angle = 0.0
	var blocked := _run(without_angle, points)
	_check(failures, _count(blocked, XRPokeEvaluator.Event.PRESSED) == 0,
			"fast diagonal: with the angle test closed there must be no press, got %s" % [blocked])

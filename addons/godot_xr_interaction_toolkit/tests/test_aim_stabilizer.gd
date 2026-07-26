extends SceneTree

## Headless tests for XRAimStabilizer.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_aim_stabilizer.gd

const XRAimStabilizerScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_aim_stabilizer.gd")

const DT90 := 1.0 / 90.0


func _init() -> void:
	var failures: Array[String] = []
	_test_large_movement_passes_through_untouched(failures)
	_test_small_jitter_is_damped(failures)
	_test_alpha_is_frame_rate_independent(failures)
	_test_first_call_snaps(failures)
	_test_reset_snaps(failures)
	_test_channels_are_independent(failures)
	_test_longer_range_is_stabilized_harder(failures)
	_test_position_is_damped_independently_of_direction(failures)
	_test_degenerate_inputs_do_not_produce_nan(failures)

	if failures.is_empty():
		print("XR aim stabilizer: PASS")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("XR aim stabilizer: FAIL (%d)" % failures.size())
		quit(1)


func _new_stabilizer() -> RefCounted:
	var s = XRAimStabilizerScript.new(2)
	s.angle_threshold_deg = 20.0
	s.position_threshold_m = 0.25
	s.default_range_m = 3.0
	return s


## The whole point of a deadband over a low-pass filter: a deliberate movement
## must arrive with ZERO added latency. If this ever softens, aiming goes
## rigid -- the exact regression already rejected on device in this codebase.
func _test_large_movement_passes_through_untouched(failures: Array[String]) -> void:
	var s = _new_stabilizer()
	s.stabilize(0, Vector3.ZERO, Vector3.FORWARD, null, DT90)
	# 90 degrees off, far beyond the 20 degree threshold.
	var out = s.stabilize(0, Vector3.ZERO, Vector3.RIGHT, null, DT90)
	var err := rad_to_deg((out["direction"] as Vector3).angle_to(Vector3.RIGHT))
	if err > 0.001:
		failures.append("a movement past the angle threshold must pass through exactly, got %.4f deg of lag" % err)

	# Same for position.
	var far_origin := Vector3(0.0, 0.0, 5.0)
	var out2 = s.stabilize(0, far_origin, Vector3.RIGHT, null, DT90)
	if (out2["origin"] as Vector3).distance_to(far_origin) > 0.0001:
		failures.append("a translation past the position threshold must pass through exactly")


## And the converse: sub-threshold noise must actually be attenuated, or the
## component is doing nothing.
func _test_small_jitter_is_damped(failures: Array[String]) -> void:
	var s = _new_stabilizer()
	var base := Vector3.FORWARD
	s.stabilize(0, Vector3.ZERO, base, null, DT90)

	# 2 degrees of wobble -- a tenth of the threshold, so firmly in the damped band.
	var jittered := base.rotated(Vector3.UP, deg_to_rad(2.0)).normalized()
	var out = s.stabilize(0, Vector3.ZERO, jittered, null, DT90)
	var residual := rad_to_deg((out["direction"] as Vector3).angle_to(base))
	if residual >= 2.0:
		failures.append("sub-threshold jitter must be damped toward the held direction, residual was %.3f of 2.0 deg" % residual)
	if residual <= 0.0:
		failures.append("damping must not fully freeze a sub-threshold move (that would be a hard deadband, not a scaling one)")


## Behaviour must be identical at 72, 90, and 120Hz, not merely similar --
## this ships to standalone AND to browsers from one set of values.
func _test_alpha_is_frame_rate_independent(failures: Array[String]) -> void:
	# Two steps at 90Hz must land where one step of twice the dt lands.
	var ratio := 0.5
	var one_big: float = XRAimStabilizerScript._stabilized_alpha(ratio, DT90 * 2.0)
	var a: float = XRAimStabilizerScript._stabilized_alpha(ratio, DT90)
	# Remaining error after two sequential applications of alpha `a`.
	var two_small := 1.0 - (1.0 - a) * (1.0 - a)
	if absf(one_big - two_small) > 0.0001:
		failures.append("alpha must compose exactly across frame times: one step of 2dt gave %.6f, two of dt gave %.6f" % [one_big, two_small])

	# Guard the clamps too.
	if XRAimStabilizerScript._stabilized_alpha(1.5, DT90) != 1.0:
		failures.append("ratio at or above 1 must pass through untouched")
	if XRAimStabilizerScript._stabilized_alpha(-0.5, DT90) != 0.0:
		failures.append("ratio at or below 0 must hold")


## No history means nothing to blend from; the first pose must be exact or the
## ray visibly flies in from wherever the struct was zero-initialized.
func _test_first_call_snaps(failures: Array[String]) -> void:
	var s = _new_stabilizer()
	var out = s.stabilize(0, Vector3(1.0, 2.0, 3.0), Vector3.RIGHT, null, DT90)
	if (out["origin"] as Vector3).distance_to(Vector3(1.0, 2.0, 3.0)) > 0.0001:
		failures.append("first call must snap the origin exactly")
	if rad_to_deg((out["direction"] as Vector3).angle_to(Vector3.RIGHT)) > 0.001:
		failures.append("first call must snap the direction exactly")


## Reacquisition after a dropout must snap, not slew across the gap.
func _test_reset_snaps(failures: Array[String]) -> void:
	var s = _new_stabilizer()
	s.stabilize(0, Vector3.ZERO, Vector3.FORWARD, null, DT90)
	s.reset(0)
	var out = s.stabilize(0, Vector3.ZERO, Vector3.RIGHT, null, DT90)
	if rad_to_deg((out["direction"] as Vector3).angle_to(Vector3.RIGHT)) > 0.001:
		failures.append("after reset the next pose must snap exactly, not blend from stale history")


## One instance serves both hands; neither may see the other's history.
func _test_channels_are_independent(failures: Array[String]) -> void:
	var s = _new_stabilizer()
	s.stabilize(0, Vector3.ZERO, Vector3.FORWARD, null, DT90)
	# Channel 1 has no history, so it must snap even though channel 0 does.
	var out = s.stabilize(1, Vector3.ZERO, Vector3.RIGHT, null, DT90)
	if rad_to_deg((out["direction"] as Vector3).angle_to(Vector3.RIGHT)) > 0.001:
		failures.append("channel 1 must not inherit channel 0's history")


## The range scaling is the reason this beats a plain direction filter: the
## same angular wobble costs more the further the ray reaches, so a long ray
## must end up steadier than a short one for identical input.
func _test_longer_range_is_stabilized_harder(failures: Array[String]) -> void:
	var base := Vector3.FORWARD
	var jittered := base.rotated(Vector3.UP, deg_to_rad(5.0)).normalized()

	var near = _new_stabilizer()
	near.stabilize(0, Vector3.ZERO, base, Vector3.FORWARD * 0.5, DT90)
	var near_out = near.stabilize(0, Vector3.ZERO, jittered, Vector3.FORWARD * 0.5, DT90)

	var far = _new_stabilizer()
	far.stabilize(0, Vector3.ZERO, base, Vector3.FORWARD * 20.0, DT90)
	var far_out = far.stabilize(0, Vector3.ZERO, jittered, Vector3.FORWARD * 20.0, DT90)

	var near_residual := rad_to_deg((near_out["direction"] as Vector3).angle_to(base))
	var far_residual := rad_to_deg((far_out["direction"] as Vector3).angle_to(base))
	# Smaller residual = moved further toward the noisy target = less stabilized.
	if far_residual >= near_residual:
		failures.append("a longer ray must be stabilized harder: far residual %.3f should exceed near residual %.3f" % [far_residual, near_residual])


## Position and direction carry separate thresholds in different units, so one
## must never be silently driven by the other -- a hand that slides without
## turning must not have its aim deflected, and a hand that turns in place must
## not have its origin dragged.
func _test_position_is_damped_independently_of_direction(failures: Array[String]) -> void:
	# Translation only: the direction is untouched.
	var s = _new_stabilizer()
	var dir := Vector3.FORWARD
	s.stabilize(0, Vector3.ZERO, dir, Vector3(0.0, 0.0, -4.0), DT90)
	var out = s.stabilize(0, Vector3(0.05, 0.0, 0.0), dir, Vector3(0.0, 0.0, -4.0), DT90)
	if rad_to_deg((out["direction"] as Vector3).angle_to(dir)) > 0.001:
		failures.append("translating the origin must not deflect the direction")
	var settled_x := (out["origin"] as Vector3).x
	if settled_x <= 0.0 or settled_x >= 0.05:
		failures.append("a sub-threshold translation must be damped, not held or passed through: x moved to %.4f of 0.05" % settled_x)

	# Rotation only: the origin is untouched.
	var s2 = _new_stabilizer()
	s2.stabilize(0, Vector3.ZERO, dir, null, DT90)
	var turned := dir.rotated(Vector3.UP, deg_to_rad(3.0)).normalized()
	var out2 = s2.stabilize(0, Vector3.ZERO, turned, null, DT90)
	if (out2["origin"] as Vector3).length() > 0.0001:
		failures.append("turning in place must not move the origin")


## Parallel and antiparallel directions both reach Vector3.slerp, where it is
## undefined; a still hand and a reacquisition flip make both reachable in
## normal use, and a NaN here would propagate into every ray consumer.
func _test_degenerate_inputs_do_not_produce_nan(failures: Array[String]) -> void:
	var s = _new_stabilizer()
	s.stabilize(0, Vector3.ZERO, Vector3.FORWARD, null, DT90)

	for label_and_dir in [["identical", Vector3.FORWARD], ["antiparallel", -Vector3.FORWARD]]:
		var out = s.stabilize(0, Vector3.ZERO, label_and_dir[1], null, DT90)
		var d: Vector3 = out["direction"]
		if is_nan(d.x) or is_nan(d.y) or is_nan(d.z):
			failures.append("%s direction produced NaN" % label_and_dir[0])
		s.reset(0)
		s.stabilize(0, Vector3.ZERO, Vector3.FORWARD, null, DT90)

	# Zero direction and non-positive dt must both be inert, not divide by zero.
	var zero_out = s.stabilize(0, Vector3.ONE, Vector3.ZERO, null, DT90)
	if (zero_out["direction"] as Vector3) != Vector3.ZERO:
		failures.append("a zero direction must pass through untouched rather than being normalized")
	var dt_out = s.stabilize(0, Vector3.ONE, Vector3.RIGHT, null, 0.0)
	if is_nan((dt_out["direction"] as Vector3).x):
		failures.append("dt of zero produced NaN")

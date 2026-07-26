extends SceneTree

## Headless tests for far-grab mode dispatch (docs/far-grab-modes-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_far_grab_modes.gd
##
## The ray interactor's distance state is what this task changes, so these
## tests drive it directly (_notify_select_granted, _apply_motion_distance_manipulation,
## get_grab_distance, adjust_grab_distance) rather than standing up an XR
## session -- no adapter, no manager, no scene tree required.

## HIT_DISTANCE is deliberately far from BOTH min_grab_distance (0.25) and the
## ATTRACT floor (which, for any hit beyond min_grab_distance, IS
## min_grab_distance) -- otherwise ATTRACT and FIXED would land on the same
## number and both pass against either implementation.
const HIT_DISTANCE := 3.0

## Minimal stand-in for an XRGrabInteractable: only carries far_grab_mode, so
## the ray's defensive "far_grab_mode" in interactable check has a concrete
## property to find.
class ModeStub:
	extends Node
	var far_grab_mode: int

## A third-party interactable with NO far_grab_mode property at all -- the
## case the brief requires the ray to survive by falling back to ATTRACT.
class NoModeStub:
	extends Node

## A grip source for _resolve_grab_pose's reel-to-grip blend/latch -- planted
## far from every ray_attach pose these tests build, so "did it move toward
## the grip" is unambiguous from the origin alone.
class GripStub:
	extends Node
	var pose := Transform3D(Basis.IDENTITY, Vector3(9, 9, 9))
	func get_attach_pose() -> Transform3D:
		return pose

## A hit distance strictly between min_grab_distance (0.25) and the ray's
## default reel_to_grip_distance (0.45) -- the only range where the
## reel-to-grip blend/latch can fire at all. Outside that range the case
## cannot arise, and a gate test would pass vacuously whether or not the gate
## exists (same trap as HIT_DISTANCE above, applied to this mechanism).
const CLOSE_HIT_DISTANCE := 0.35

## Below min_grab_distance (0.25): a FIXED grab here is the fixture that
## makes the LATCH half of the gate load-bearing. floor_distance =
## minf(min_grab_distance, _grab_distance) collapses to _grab_distance itself
## once _grab_distance < min_grab_distance, which forces
## t = inverse_lerp(reel_to_grip_distance, floor_distance, floor_distance) to
## exactly 1.0 -- the full LATCH branch, not the t=0.5 partial blend
## CLOSE_HIT_DISTANCE produces. At CLOSE_HIT_DISTANCE the latch assertion
## never fires either way (confirmed by the Fix pass 1 mutation run); this
## fixture is what makes it fire.
const VERY_CLOSE_HIT_DISTANCE := 0.20

var _failures: Array[String] = []

func _init() -> void:
	_test_attract_captures_the_floor(_failures)
	_test_fixed_captures_the_hit_distance(_failures)
	_test_fixed_ignores_hand_motion(_failures)
	_test_fixed_still_clamped_by_min_grab_distance(_failures)
	_test_reel_responds_to_hand_motion(_failures)
	_test_interactable_without_a_mode_is_left_alone(_failures)
	_test_fixed_does_not_blend_or_latch_within_reel_to_grip_distance(_failures)
	_test_attract_still_latches_within_reel_to_grip_distance(_failures)
	_test_fixed_does_not_latch_when_grabbed_below_min_grab_distance(_failures)
	_test_reel_axis_frozen_survives_aim_rotation(_failures)
	if _failures.is_empty():
		print("XR far grab modes: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	print("XR far grab modes: FAIL (%d)" % _failures.size())
	quit(1)

func _make_ray() -> XRRayInteractor:
	var ray := XRRayInteractor.new()
	ray._hover_distance = HIT_DISTANCE
	return ray

func _test_attract_captures_the_floor(failures: Array[String]) -> void:
	var ray := _make_ray()
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	ray._notify_select_granted(stub)
	var expected_floor := minf(ray.min_grab_distance, HIT_DISTANCE)
	if not is_equal_approx(ray.get_grab_distance(), expected_floor):
		failures.append("ATTRACT on select must capture the grip floor (%f), got %f" % [expected_floor, ray.get_grab_distance()])
	if is_equal_approx(ray.get_grab_distance(), HIT_DISTANCE):
		failures.append("ATTRACT on select must NOT capture the raw hit distance (%f)" % HIT_DISTANCE)
	ray.free()
	stub.free()

func _test_fixed_captures_the_hit_distance(failures: Array[String]) -> void:
	var ray := _make_ray()
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.FIXED
	ray._notify_select_granted(stub)
	if not is_equal_approx(ray.get_grab_distance(), HIT_DISTANCE):
		failures.append("FIXED on select must capture the raw hit distance (%f), got %f" % [HIT_DISTANCE, ray.get_grab_distance()])
	ray.free()
	stub.free()

func _test_fixed_ignores_hand_motion(failures: Array[String]) -> void:
	var ray := _make_ray()
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.FIXED
	ray._notify_select_granted(stub)
	var before := ray.get_grab_distance()
	# An established ray pose, then a 1 m hand pull along it -- the exact
	# input that reels a REEL-mode object in _test_reel_responds_to_hand_motion.
	ray._last_ray_origin = Vector3.ZERO
	ray._last_ray_direction = Vector3.FORWARD
	ray._has_last_ray_pose = true
	ray._apply_motion_distance_manipulation(Vector3(0, 0, -1), Vector3.FORWARD, 1.0 / 60.0)
	if not is_equal_approx(ray.get_grab_distance(), before):
		failures.append("FIXED must not change distance on hand motion: was %f, now %f" % [before, ray.get_grab_distance()])
	ray.free()
	stub.free()

func _test_fixed_still_clamped_by_min_grab_distance(failures: Array[String]) -> void:
	var ray := _make_ray()
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.FIXED
	ray._notify_select_granted(stub)  # distance = HIT_DISTANCE (3.0)
	# adjust_grab_distance is phase 2's entry point (pinch/twist) and must
	# obey the same clamp the internal reel path does, regardless of mode.
	ray.adjust_grab_distance(-10.0)
	if not is_equal_approx(ray.get_grab_distance(), ray.min_grab_distance):
		failures.append("adjust_grab_distance must floor at min_grab_distance (%f), got %f" % [ray.min_grab_distance, ray.get_grab_distance()])
	ray.free()
	stub.free()

func _test_reel_responds_to_hand_motion(failures: Array[String]) -> void:
	var ray := _make_ray()
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.REEL
	ray._notify_select_granted(stub)
	var before := ray.get_grab_distance()
	ray._last_ray_origin = Vector3.ZERO
	ray._last_ray_direction = Vector3.FORWARD
	ray._has_last_ray_pose = true
	ray._apply_motion_distance_manipulation(Vector3(0, 0, -1), Vector3.FORWARD, 1.0 / 60.0)
	if is_equal_approx(ray.get_grab_distance(), before):
		failures.append("REEL must still change distance on hand motion, stuck at %f" % before)
	ray.free()
	stub.free()

## REGRESSION, found in-headset: an interactable with no far_grab_mode is NOT a
## far-grabbable - it is a UI panel, a socket, or anything else this ray can
## select. Defaulting the absent case to ATTRACT collapsed the ray's attach
## distance to min_grab_distance the moment a UI button was pressed, dragging
## the cursor to the hand and making every menu unreachable. David, on device:
## "when i try to click a ui button the curser gets closer and i cant select
## any ui button to get to a scene".
##
## The ATTRACT default belongs on XRGrabInteractable's own export, which is how
## it reaches real grabbables. The fallback here only has to be INERT: keep the
## hit distance, exactly as the ray did before far_grab_mode existed.
func _test_interactable_without_a_mode_is_left_alone(failures: Array[String]) -> void:
	var ray := _make_ray()
	var stub := NoModeStub.new()
	ray._notify_select_granted(stub)
	if not is_equal_approx(ray.get_grab_distance(), HIT_DISTANCE):
		failures.append("an interactable with no far_grab_mode must keep the hit distance (%f), got %f - a UI panel must not be attracted" % [HIT_DISTANCE, ray.get_grab_distance()])
	var floor_distance := minf(ray.min_grab_distance, HIT_DISTANCE)
	if is_equal_approx(ray.get_grab_distance(), floor_distance):
		failures.append("an interactable with no far_grab_mode was ATTRACTed to the grip floor (%f) - this is the bug that made menus unusable" % floor_distance)
	ray.free()
	stub.free()

## Fix pass 1: FIXED must never blend or latch into the linked grip pose --
## "never reels, never attracts" was true of distance but not of pose. A hit
## distance inside reel_to_grip_distance (0.45) is exactly the case that used
## to silently turn FIXED into ATTRACT: without the gate, _resolve_grab_pose
## computes t = inverse_lerp(0.45, 0.25, 0.35) = 0.5 and blends the returned
## pose toward the grip regardless of mode.
func _test_fixed_does_not_blend_or_latch_within_reel_to_grip_distance(failures: Array[String]) -> void:
	var ray := _make_ray()
	ray._hover_distance = CLOSE_HIT_DISTANCE
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.FIXED
	ray._notify_select_granted(stub)  # distance = CLOSE_HIT_DISTANCE (0.35), inside reel_to_grip_distance
	var grip := GripStub.new()
	ray._suppress_interactor = grip
	var ray_attach := Transform3D(Basis.IDENTITY, Vector3(0, 1, -0.35))
	var result := ray._resolve_grab_pose(ray_attach)
	if not result.origin.is_equal_approx(ray_attach.origin):
		failures.append("FIXED within reel_to_grip_distance must return the ray pose unchanged, not blend toward the grip: got %s, expected %s" % [result.origin, ray_attach.origin])
	if ray._grip_latched:
		failures.append("FIXED within reel_to_grip_distance must never latch")
	ray.free()
	stub.free()
	grip.free()

## Companion to the test above: the gate must narrow FIXED only. ATTRACT's
## captured distance is always the floor (min_grab_distance), which for any
## reel_to_grip_distance > min_grab_distance forces
## t = inverse_lerp(reel_to_grip_distance, floor, floor) == 1.0 -- ATTRACT
## latches immediately by construction, which is the composition Task 1
## relies on ("the object tweens in and latches as a real hold").
func _test_attract_still_latches_within_reel_to_grip_distance(failures: Array[String]) -> void:
	var ray := _make_ray()
	ray._hover_distance = CLOSE_HIT_DISTANCE
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	ray._notify_select_granted(stub)
	var grip := GripStub.new()
	ray._suppress_interactor = grip
	var ray_attach := Transform3D(Basis.IDENTITY, Vector3(0, 1, -0.35))
	var result := ray._resolve_grab_pose(ray_attach)
	if not result.origin.is_equal_approx(grip.pose.origin):
		failures.append("ATTRACT within reel_to_grip_distance must still blend/latch toward the grip: got %s, expected %s" % [result.origin, grip.pose.origin])
	if not ray._grip_latched:
		failures.append("ATTRACT within reel_to_grip_distance must still latch -- the gate must only narrow FIXED")
	ray.free()
	stub.free()
	grip.free()

## Closes the gap the Fix pass 1 mutation run exposed: at CLOSE_HIT_DISTANCE
## the un-gated blend only reaches t=0.5, so a mutation that removes the
## mode gate is caught by the pose assertion but NOT by _grip_latched -- that
## assertion never fires either way at that distance. VERY_CLOSE_HIT_DISTANCE
## (below min_grab_distance) forces the full t=1.0 LATCH branch instead, so
## this is the fixture where the latch check is actually load-bearing.
func _test_fixed_does_not_latch_when_grabbed_below_min_grab_distance(failures: Array[String]) -> void:
	var ray := _make_ray()
	ray._hover_distance = VERY_CLOSE_HIT_DISTANCE
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.FIXED
	ray._notify_select_granted(stub)  # distance = VERY_CLOSE_HIT_DISTANCE (0.20), below min_grab_distance
	var grip := GripStub.new()
	ray._suppress_interactor = grip
	var ray_attach := Transform3D(Basis.IDENTITY, Vector3(0, 1, -0.20))
	var result := ray._resolve_grab_pose(ray_attach)
	if not result.origin.is_equal_approx(ray_attach.origin):
		failures.append("FIXED grabbed below min_grab_distance must return the ray pose unchanged, got %s, expected %s" % [result.origin, ray_attach.origin])
	if ray._grip_latched:
		failures.append("FIXED grabbed below min_grab_distance must never latch (t would be exactly 1.0 unguarded)")
	ray.free()
	stub.free()
	grip.free()

## Task 2: the coupling bug. _apply_motion_distance_manipulation used to
## project hand motion onto _last_ray_direction, which _update_ray refreshes
## every frame -- so a pure re-aim between samples changed what "pull" meant
## even though the hand never moved. Selects in REEL mode, applies a known
## 5 cm pull, then ROTATES the reported ray direction 25 degrees WITHOUT
## moving the hand, then applies the identical 5 cm pull again. A test that
## only checks "some delta occurred" passes against the bug -- the rotation
## between samples, and comparing the two deltas, is the whole point.
func _test_reel_axis_frozen_survives_aim_rotation(failures: Array[String]) -> void:
	var ray := _make_ray()
	var stub := ModeStub.new()
	stub.far_grab_mode = XRGrabInteractable.FarGrabMode.REEL
	ray._notify_select_granted(stub)
	ray._last_ray_origin = Vector3.ZERO
	ray._last_ray_direction = Vector3.FORWARD
	ray._has_last_ray_pose = true

	var before1 := ray.get_grab_distance()
	var origin1 := Vector3(0, 0, -0.05)  # a 5 cm pull along the select-time aim
	ray._apply_motion_distance_manipulation(origin1, ray._last_ray_direction, 1.0 / 60.0)
	var delta1 := ray.get_grab_distance() - before1

	# Advance frame-tracking state the way _update_ray would at frame end,
	# but ROTATE the reported aim direction 25 degrees in between -- without
	# moving the hand. This is the coupling bug's exact shape: re-aiming,
	# with no hand motion, must not change the next sample's result.
	ray._last_ray_origin = origin1
	ray._last_ray_direction = Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(25.0))
	ray._pending_distance_delta = 0.0  # isolate sample 2 from sample 1's leftover carry

	var before2 := ray.get_grab_distance()
	var origin2 := origin1 + Vector3(0, 0, -0.05)  # the SAME 5 cm pull, same world axis
	ray._apply_motion_distance_manipulation(origin2, ray._last_ray_direction, 1.0 / 60.0)
	var delta2 := ray.get_grab_distance() - before2

	if not is_equal_approx(delta1, delta2):
		failures.append("REEL distance delta must be unchanged by a pure re-aim between samples: first %f, second %f (reel axis must freeze at select, not re-read the live ray direction)" % [delta1, delta2])
	ray.free()
	stub.free()

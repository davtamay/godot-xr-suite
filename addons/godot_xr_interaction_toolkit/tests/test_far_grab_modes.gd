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

## Minimal stand-in for the input adapter get_hand_grip_pose/_update_ray read
## (is_select_down, get_aim_pose, get_grip_pose). grip_valid/grip_origin
## control what get_grip_pose reports, so the same stub can prove
## get_hand_grip_pose's adapter-empty and adapter-present cases both.
class RayAdapterStub:
	extends Node
	var pos := Vector3(0, 1, 0)
	var grip_valid := false
	var grip_origin := Vector3.ZERO
	var grip_basis := Basis.IDENTITY
	func is_select_down(_hand: int) -> bool:
		return true
	func get_aim_pose(_hand: int) -> Dictionary:
		return {"origin": pos, "direction": Vector3.FORWARD, "basis": Basis.IDENTITY}
	func get_grip_pose(_hand: int) -> Dictionary:
		if not grip_valid:
			return {}
		return {"origin": grip_origin, "basis": grip_basis}

## Real XRRayInteractor subclass with get_hand_grip_pose() overridden directly
## -- for the ATTRACT delivery-target tests below, which are about
## xr_grab_interactable.gd's CONSUMPTION of the grip-pose contract, not about
## xr_ray_interactor.gd's own adapter plumbing (that plumbing has its own
## test, _test_ray_get_hand_grip_pose_proxies_the_adapter, driven through
## RayAdapterStub instead). `is XRRayInteractor` still holds for a subclass,
## which is what _movement_target_pose_for/_compute_grab_offset gate on.
class AttractRayStub:
	extends XRRayInteractor
	var grip_origin := Vector3(0, 1, 0)
	var grip_basis := Basis.IDENTITY
	func get_hand_grip_pose() -> Dictionary:
		return {"valid": true, "origin": grip_origin, "basis": grip_basis}

## Minimal stand-in for an authored XRGrabPoint: only carries
## mirror_to_other_hand (set false, keeping the point-grab test's algebra
## unmirrored/simple), matching the real export XRGrabPoint always has. A
## bare Node3D was fine for test_grab_feel.gd's "gated" fixture because that
## point never matched (never added to the tree, so _best_grab_point's search
## never reached it, let alone _mirror_offset). This one is MEANT to match
## and reach _mirror_offset, which unconditionally reads
## point.get("mirror_to_other_hand") -- a bare Node3D lacking that property
## crashes there ("Nonexistent 'bool' constructor", confirmed empirically).
class GrabPointStub:
	extends Node3D
	var mirror_to_other_hand := false

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

## Minimal XRBaseInteractable stand-in for the phase-2 TWIST driver's tests:
## only needs far_grab_mode (duck-typed by the driver's `"far_grab_mode" in
## _interactable` check) plus the base class's own
## get_selecting_interactors()/_notify_select_entered. Never added to the
## tree (same reasoning as ModeStub etc. above -- these tests drive the
## driver's private methods directly), so none of XRBaseInteractable's
## manager-registration notifications ever fire.
class TwistInteractableStub:
	extends XRBaseInteractable
	var far_grab_mode: int = XRGrabInteractable.FarGrabMode.TWIST

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
	_test_ray_get_hand_grip_pose_proxies_the_adapter(_failures)
	_test_far_grab_attract_standoff_is_comfortably_inside_hide_ray_when_held_within(_failures)
	# TWIST (phase 2, docs/far-grab-modes-design.md "Phase 2: TWIST"): none of
	# these touch a Node3D.global_transform, so -- like the tests above --
	# they run tree-independent from _init(). Conditioning off for the
	# duration: XRConditionedHandPublisher's shadow is memoized per RENDERED
	# frame (Engine.get_process_frames()), which never advances across this
	# whole _init() call -- so the very first resolve of a hand would publish
	# a shadow ONCE and freeze it there, and every later mutation to the raw
	# tracker these tests make (rolling the wrist frame to frame) would be
	# invisible to the driver. set_conditioned(false) is the resolver's own
	# documented test knob for exactly this (test_hand_conditioning.gd uses
	# it the same way) -- it makes get_tracker fall through to resolve_raw,
	# which re-scans XRServer's live trackers on every call.
	var _twist_was_conditioned := XRHandTrackerResolver.is_conditioned()
	XRHandTrackerResolver.set_conditioned(false)
	_test_twist_offset_engages_scales_and_clamps(_failures)
	_test_twist_angle_extracts_roll_independent_of_swing(_failures)
	_test_twist_full_deflection_settles_at_span_and_clamps_beyond(_failures)
	_test_twist_pull_reaches_hand_default_reaches_min_grab_distance_from_multiple_engagement_distances(_failures)
	_test_twist_pull_reaches_hand_false_uses_span_instead(_failures)
	_test_twist_pull_reaches_hand_flag_does_not_affect_outward(_failures)
	_test_twist_pull_reaches_hand_rolling_back_still_retraces(_failures)
	_test_twist_rolling_back_to_neutral_returns_to_engagement_distance(_failures)
	_test_twist_opposite_rolls_move_opposite_ways_from_engagement(_failures)
	_test_twist_inside_deadband_nothing_moves(_failures)
	_test_twist_below_start_threshold_mapping_not_engaged(_failures)
	_test_twist_engagement_distance_captured_per_grab(_failures)
	_test_twist_second_grab_does_not_inherit_previous_neutral_rotation(_failures)
	_test_twist_fixed_and_reel_unaffected_by_twist(_failures)
	_test_twist_controller_with_no_wrist_joint_is_inert(_failures)
	XRHandTrackerResolver.set_conditioned(_twist_was_conditioned)
	# The remaining tests need a node genuinely inside the tree
	# (XRGrabInteractable._arm_transit calls get_target(), which asserts
	# "!is_inside_tree()") -- a node added to get_root() during _init() is not
	# yet inside the tree (tree membership only propagates by the first
	# _process, confirmed empirically -- the same hazard test_grab_feel.gd
	# documents and defers for identical reasons). Deferred to _process().

func _process(_delta: float) -> bool:
	_test_attract_offset_collapses_and_targets_the_grip(_failures)
	_test_attract_standoff_offsets_along_grip_forward(_failures)
	_test_attract_standoff_rides_grip_rotation(_failures)
	_test_fixed_and_reel_do_not_arm_transit_for_a_plain_grabbable(_failures)
	_test_attract_respects_an_authored_grab_point(_failures)
	_test_far_grab_attract_speed_drives_duration(_failures)
	_test_attract_transit_eases_out(_failures)
	if _failures.is_empty():
		print("XR far grab modes: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR far grab modes: FAIL (%d)" % _failures.size())
	quit(1)
	return true

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

## SUPERSEDES the original Fix-1 guard-only test (see far-grab-guards-report.md
## "Round 2" for the full writeup). f9a2230's guard turned out necessary but
## not sufficient: a plain grab's free-grab offset formula
## (interactor.get_attach_pose()^-1 * target.global_transform) makes
## _arm_transit's `desired` and `_transit_from` identical BY CONSTRUCTION
## (A * (A^-1 * X) == X for any A, X), so the guard could arm and still
## measure a zero-distance, zero-duration transit -- confirmed empirically in
## Round 1. The actual fix lives in _compute_grab_offset and
## _movement_target_pose_for: ATTRACT collapses the offset to IDENTITY (the
## same way snap_to_attach does with no attach_node) and targets the
## adapter's own grip pose as the destination, so `desired` is genuinely
## different from the object's current transform and the transit has real
## distance to cover. This is the test the original brief asked for, and the
## guard-only fix could not honestly pass it.
##
## Drives a real XRRayInteractor SUBCLASS (AttractRayStub) with
## get_hand_grip_pose() overridden directly, rather than a full adapter
## simulation -- this test is about xr_grab_interactable.gd's CONSUMPTION of
## the grip-pose contract; the contract's own adapter plumbing has its own
## test, _test_ray_get_hand_grip_pose_proxies_the_adapter, up in _init().
func _test_attract_offset_collapses_and_targets_the_grip(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = false
	grab.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	# Standoff is a SEPARATE concern (round 3) with its own dedicated tests
	# below (_test_attract_standoff_offsets_along_grip_forward and
	# _test_attract_standoff_rides_grip_rotation) -- zeroed here so this
	# test's "lands exactly on the grip pose" assertion stays about the
	# offset-collapse mechanism alone, not entangled with standoff math.
	grab.far_grab_attract_standoff = 0.0
	var far_position := Vector3(0, 1, -3.0)
	body.global_position = far_position

	var ray := AttractRayStub.new()
	ray.grip_origin = Vector3(0, 1, 0)  # 3 m from the object -- real distance to close
	get_root().add_child(ray)

	grab._notify_select_entered(ray)

	if grab._transit_duration <= 0.0:
		failures.append("ATTRACT plain grab must arm a transit with REAL (non-zero) duration once the offset is collapsed, got %f" % grab._transit_duration)
	if not grab.in_transit():
		failures.append("ATTRACT plain grab must be in_transit() immediately after being armed")
	if grab._transit_from.origin.is_equal_approx(ray.grip_origin):
		failures.append("_transit_from must be the object's ORIGINAL position, not already the grip -- got %s" % grab._transit_from.origin)

	# Run the transit to completion and confirm it lands EXACTLY on the grip
	# pose -- the assertion Mutation 1 (revert the offset collapse) breaks.
	# Reverting still arms a duration that LOOKS non-zero (the un-collapsed
	# offset composes with the grip pose into a wrong-but-plausible transform,
	# not an identity), so duration/in_transit() alone would not catch it --
	# the landing position is what does.
	var frames := 0
	while grab.in_transit() and frames < 600:
		grab._physics_process(1.0 / 60.0)
		frames += 1
	if grab.in_transit():
		failures.append("ATTRACT transit did not finish within the 600-frame test budget -- something is stuck")
	if not body.global_position.is_equal_approx(ray.grip_origin):
		failures.append("ATTRACT (standoff zeroed) must deliver the object exactly onto the adapter's grip pose, got %s expected %s" % [body.global_position, ray.grip_origin])

	grab.queue_free()
	ray.queue_free()

## Round 3 (on-device: "with attach i guess we can leave an offset, i see how
## overlaping hand completely can be a problem"): landing exactly ON the grip
## (the test above, with standoff zeroed) overcorrected -- object and hand
## occupy the same space. ATTRACT now lands far_grab_attract_standoff forward
## of the grip pose instead. Uses the DEFAULT far_grab_attract_standoff (not
## overridden), so Mutation "set the standoff to zero" (reverting to the
## overcorrection this round exists to fix) is caught by the shipped default,
## not a test-authored value.
func _test_attract_standoff_offsets_along_grip_forward(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = false
	grab.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	body.global_position = Vector3(0, 1, -3.0)

	var ray := AttractRayStub.new()
	ray.grip_origin = Vector3(0, 1, 0)
	ray.grip_basis = Basis.IDENTITY  # forward (-Z) is world -Z here
	get_root().add_child(ray)

	grab._notify_select_entered(ray)
	var frames := 0
	while grab.in_transit() and frames < 600:
		grab._physics_process(1.0 / 60.0)
		frames += 1
	if grab.in_transit():
		failures.append("standoff test: transit did not finish within the 600-frame budget")

	var expected := ray.grip_origin + (ray.grip_basis * Vector3.FORWARD) * grab.far_grab_attract_standoff
	if body.global_position.is_equal_approx(ray.grip_origin):
		failures.append("ATTRACT must NOT land exactly coincident with the grip pose -- got %s, same as the grip origin %s (this is the overcorrection round 3 exists to fix)" % [body.global_position, ray.grip_origin])
	if not body.global_position.is_equal_approx(expected):
		failures.append("ATTRACT must land far_grab_attract_standoff (%f m) forward of the grip pose along the grip's OWN axis, got %s expected %s" % [grab.far_grab_attract_standoff, body.global_position, expected])

	grab.queue_free()
	ray.queue_free()

## The standoff must ride the GRIP's rotation, not hang in a fixed world
## direction -- a rotated grip pose (wrist turned after the grab) must move
## the destination with it. Catches Mutation "apply the standoff along a
## fixed world axis instead of the grip's forward": a world-axis mutant would
## still pass _test_attract_standoff_offsets_along_grip_forward above (that
## fixture's grip_basis is IDENTITY, where "the grip's forward" and "a fixed
## world axis" are the SAME direction and cannot be told apart) -- this is
## the fixture where they diverge.
func _test_attract_standoff_rides_grip_rotation(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = false
	grab.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	body.global_position = Vector3(0, 1, -3.0)

	var ray := AttractRayStub.new()
	ray.grip_origin = Vector3(0, 1, 0)
	ray.grip_basis = Basis(Vector3.UP, deg_to_rad(90.0))  # wrist turned 90 degrees
	get_root().add_child(ray)

	grab._notify_select_entered(ray)
	var frames := 0
	while grab.in_transit() and frames < 600:
		grab._physics_process(1.0 / 60.0)
		frames += 1
	if grab.in_transit():
		failures.append("rotated-grip standoff test: transit did not finish within the 600-frame budget")

	var rotated_expected := ray.grip_origin + (ray.grip_basis * Vector3.FORWARD) * grab.far_grab_attract_standoff
	var world_axis_expected := ray.grip_origin + Vector3.FORWARD * grab.far_grab_attract_standoff
	if not body.global_position.is_equal_approx(rotated_expected):
		failures.append("standoff must follow the ROTATED grip's own forward axis, got %s expected %s" % [body.global_position, rotated_expected])
	if body.global_position.is_equal_approx(world_axis_expected):
		failures.append("standoff landed along a FIXED WORLD axis (%s) instead of the rotated grip's own forward -- it will hang in place as the wrist turns" % world_axis_expected)

	grab.queue_free()
	ray.queue_free()

## The constraint the coordinator asked to encode, not just respect once: the
## shipped default far_grab_attract_standoff must sit comfortably inside the
## shipped default hide_ray_when_held_within (XRRayInteractor) -- that
## threshold is what hides the far ray by comparing the held object's
## position against the SAME adapter grip origin ATTRACT now delivers onto.
## A standoff at or past it means a held object still draws a ray at you,
## which is the exact symptom that started this whole thread. Reads both
## defaults from FRESH instances (never overridden by a test) so a future
## tuning pass on either number is what this test is actually watching.
func _test_far_grab_attract_standoff_is_comfortably_inside_hide_ray_when_held_within(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var ray := XRRayInteractor.new()
	if not (grab.far_grab_attract_standoff < ray.hide_ray_when_held_within):
		failures.append("far_grab_attract_standoff (%f) must be strictly LESS than XRRayInteractor.hide_ray_when_held_within (%f) -- otherwise a held ATTRACT object still draws a ray" % [grab.far_grab_attract_standoff, ray.hide_ray_when_held_within])
	# "Comfortably", not by a hair: at least a 0.05 m margin, so rounding or a
	# small independent tweak to either number cannot brush the two together.
	var margin := ray.hide_ray_when_held_within - grab.far_grab_attract_standoff
	if margin < 0.05:
		failures.append("far_grab_attract_standoff (%f) is too close to hide_ray_when_held_within (%f) -- margin %f m, want >= 0.05 m of headroom" % [grab.far_grab_attract_standoff, ray.hide_ray_when_held_within, margin])
	grab.free()
	ray.free()

## Companion to the test above: the same plain grabbable in FIXED, REEL, or
## TWIST mode must NOT arm a transit -- the guard's "attracting" clause
## requires far_grab_mode == ATTRACT, so _arm_transit must still return early
## for these modes, leaving _transit_from untouched at the class default.
## Catches Mutation "drop the mode gate entirely" (not one of Round 2's three,
## but still guarded by this fixture from Round 1). TWIST added alongside the
## phase-2 driver: it is a distance-rate mode like REEL, not a delivery mode
## like ATTRACT, so it must not arm a transit either.
func _test_fixed_and_reel_do_not_arm_transit_for_a_plain_grabbable(failures: Array[String]) -> void:
	for mode in [XRGrabInteractable.FarGrabMode.FIXED, XRGrabInteractable.FarGrabMode.REEL, XRGrabInteractable.FarGrabMode.TWIST]:
		var grab := XRGrabInteractable.new()
		var body := Node3D.new()
		grab.add_child(body)
		get_root().add_child(grab)
		grab.target_path = grab.get_path_to(body)
		grab.snap_to_attach = false
		grab.far_grab_mode = mode
		body.global_position = Vector3(0, 1, -3.0)

		var ray := XRRayInteractor.new()
		get_root().add_child(ray)
		ray._attach_pose = Transform3D(Basis.IDENTITY, body.global_position)

		grab._notify_select_entered(ray)

		if not grab._transit_from.is_equal_approx(Transform3D.IDENTITY):
			failures.append("mode %d: a plain grab must NOT arm a transit outside ATTRACT -- _transit_from was touched: %s" % [mode, grab._transit_from.origin])
		if grab.in_transit():
			failures.append("mode %d: a plain grab must NOT be in_transit() outside ATTRACT" % mode)

		grab.queue_free()
		ray.queue_free()

## "Respect authored grab points if the object has them -- an object with a
## grip should still arrive held correctly" (coordinator brief). The point is
## a CHILD of the target, offset from its origin, so this can tell "the POINT
## landed on the grip" apart from "the object's ORIGIN happened to land near
## it" -- point.position != body.position is the whole reason this fixture
## exists, and the algebra (offset = point_local^-1, constant, independent of
## world position) is what makes the point land exactly on the grip pose
## regardless of where the object started.
func _test_attract_respects_an_authored_grab_point(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	body.global_position = Vector3(0, 1, -3.0)

	var point := GrabPointStub.new()
	point.position = Vector3(0.1, 0.0, 0.0)  # an authored grip 10 cm off the object's origin
	body.add_child(point)
	grab.register_grab_point(point)

	var ray := AttractRayStub.new()
	ray.grip_origin = Vector3(0, 1, 0)
	get_root().add_child(ray)

	grab._notify_select_entered(ray)
	if not grab._point_grab:
		failures.append("registering a grab point must make this a point grab -- fixture broken, not the behaviour under test")

	var frames := 0
	while grab.in_transit() and frames < 600:
		grab._physics_process(1.0 / 60.0)
		frames += 1
	if grab.in_transit():
		failures.append("ATTRACT point-grab transit did not finish within the 600-frame test budget")
	if not point.global_position.is_equal_approx(ray.grip_origin):
		failures.append("an authored grab point under ATTRACT must land exactly on the grip pose, got %s expected %s" % [point.global_position, ray.grip_origin])

	grab.queue_free()
	ray.queue_free()

## far_grab_attract_speed, not the shared transit_speed, drives an ATTRACT
## transit's duration. Two otherwise-identical grabs, same 3 m displacement,
## different far_grab_attract_speed -- catches Mutation "use transit_speed
## instead of far_grab_attract_speed", which would make both durations equal
## (and wrong: transit_speed defaults to 1.5, giving 2.0 s, not the 1.0 s / 0.5 s
## this test expects) regardless of the very different speed values passed in.
func _test_far_grab_attract_speed_drives_duration(failures: Array[String]) -> void:
	var speeds: Array[float] = [3.0, 6.0]
	var durations: Array[float] = []
	for speed in speeds:
		var grab := XRGrabInteractable.new()
		var body := Node3D.new()
		grab.add_child(body)
		get_root().add_child(grab)
		grab.target_path = grab.get_path_to(body)
		grab.snap_to_attach = false
		grab.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
		grab.far_grab_attract_speed = speed
		grab.far_grab_attract_standoff = 0.0  # keep the 3 m distance exact; standoff has its own tests
		body.global_position = Vector3(0, 1, -3.0)

		var ray := AttractRayStub.new()
		ray.grip_origin = Vector3(0, 1, 0)
		get_root().add_child(ray)

		grab._notify_select_entered(ray)
		durations.append(grab._transit_duration)

		var expected := 3.0 / speed
		if not is_equal_approx(grab._transit_duration, expected):
			failures.append("far_grab_attract_speed=%f over 3 m must give duration %f, got %f" % [speed, expected, grab._transit_duration])

		grab.queue_free()
		ray.queue_free()

	if is_equal_approx(durations[0], durations[1]):
		failures.append("two different far_grab_attract_speed values over the same distance produced the SAME duration (%f) -- speed is not driving duration" % durations[0])

## "Too snappy" is the easing, not only the speed (coordinator brief):
## transit_blend is linear, so the object would move at constant velocity and
## stop dead. The ATTRACT transit eases OUT (fast start, soft settle), so at
## the HALFWAY POINT IN TIME the object must be much further than halfway
## along -- ease_out_cubic(0.5) = 0.875, vs the 0.5 a linear pace would give.
## Halting _physics_process at exactly half the transit's total duration and
## checking the object landed near the 0.875 mark (and NOT near the 0.5 mark)
## is what makes this mutation-discriminating -- a "did it eventually arrive"
## check cannot see easing at all, only timing.
func _test_attract_transit_eases_out(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = false
	grab.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	grab.far_grab_attract_speed = 3.0
	grab.far_grab_attract_standoff = 0.0  # keep the target exactly at grip_origin; standoff has its own tests
	var start := Vector3(0, 1, -3.0)
	var target_pos := Vector3(0, 1, 0)
	body.global_position = start

	var ray := AttractRayStub.new()
	ray.grip_origin = target_pos
	get_root().add_child(ray)

	grab._notify_select_entered(ray)
	if grab._transit_duration <= 0.0:
		failures.append("ease-out fixture: transit duration must be positive -- fixture broken, not the behaviour under test")
		grab.queue_free()
		ray.queue_free()
		return

	grab._physics_process(grab._transit_duration * 0.5)

	var eased_expected := start.lerp(target_pos, XRGrabInteractable.ease_out_cubic(0.5))
	var linear_expected := start.lerp(target_pos, 0.5)
	if not body.global_position.is_equal_approx(eased_expected):
		failures.append("ATTRACT transit at 50%% elapsed TIME must sit at the ease-out fraction (%s), got %s" % [eased_expected, body.global_position])
	if body.global_position.is_equal_approx(linear_expected):
		failures.append("ATTRACT transit at 50%% elapsed TIME landed at the LINEAR midpoint (%s) -- ease-out is not being applied" % linear_expected)

	grab.queue_free()
	ray.queue_free()

## get_hand_grip_pose()'s own adapter plumbing on XRRayInteractor -- separate
## from the consumption tests above (AttractRayStub overrides
## get_hand_grip_pose() directly, so those never exercise this method's real
## body). No tree needed: this only touches _adapter/hand, never get_target()
## or global_transform, so it runs from _init() alongside the mode-dispatch
## tests rather than _process().
func _test_ray_get_hand_grip_pose_proxies_the_adapter(failures: Array[String]) -> void:
	var ray := XRRayInteractor.new()
	var no_adapter := ray.get_hand_grip_pose()
	if no_adapter.get("valid", true):
		failures.append("get_hand_grip_pose with no adapter assigned must report valid=false, got %s" % no_adapter)

	var adapter := RayAdapterStub.new()
	adapter.grip_valid = false
	ray._adapter = adapter
	var invalid := ray.get_hand_grip_pose()
	if invalid.get("valid", true):
		failures.append("get_hand_grip_pose must report valid=false when the adapter's own grip pose is empty, got %s" % invalid)

	adapter.grip_valid = true
	adapter.grip_origin = Vector3(1, 2, 3)
	adapter.grip_basis = Basis(Vector3.UP, deg_to_rad(30.0))
	var valid := ray.get_hand_grip_pose()
	if not valid.get("valid", false):
		failures.append("get_hand_grip_pose must report valid=true once the adapter has a grip pose, got %s" % valid)
	if not (valid.get("origin") as Vector3).is_equal_approx(adapter.grip_origin):
		failures.append("get_hand_grip_pose must pass through the adapter's grip origin, got %s expected %s" % [valid.get("origin"), adapter.grip_origin])
	if not (valid.get("basis") as Basis).is_equal_approx(adapter.grip_basis):
		failures.append("get_hand_grip_pose must pass through the adapter's grip basis, got %s expected %s" % [valid.get("basis"), adapter.grip_basis])

	ray.free()
	adapter.free()

## ---------------------------------------------------------------------------
## TWIST (phase 2): wrist-roll RATE control, driven by
## xr_pinch_twist_distance_driver.gd. docs/far-grab-modes-design.md,
## "Phase 2: TWIST" -- rate control (not absolute mapping), neutral captured
## at select (not absolute), roll measured around the ray/forward axis frozen
## at select, and inert (not broken) with no wrist joint (the controller
## case). Every fixture below drives the driver's private methods/static math
## directly, per the docs' own testing section for this feature -- no XR
## session, no rig, no adapter.

## A ray with no adapter/manager behind it -- just the two fields the driver
## reads (hand, and whatever get_attach_pose()/adjust_grab_distance() need).
## _attach_pose and _grab_distance are set directly, matching how the mode-
## dispatch tests above seed a ray's state without going through _update_ray.
func _make_twist_ray(hand: int, forward: Vector3, distance: float) -> XRRayInteractor:
	var ray := XRRayInteractor.new()
	ray.hand = hand
	# XRHandGestureProvider.basis_from_forward(direction) is built on
	# Basis.looking_at(direction, ...), whose local -Z axis points along
	# `direction` -- i.e. -basis.z == direction, matching how
	# xr_controller_hand_adapter.gd constructs both the "direction" field AND
	# the "basis" field from the SAME direction (see _roll_axis's doc comment
	# in the driver). Pass `forward` through UNCHANGED, not negated, or the
	# resulting attach pose's -Z ends up pointing the opposite way from what
	# the caller asked for.
	ray._attach_pose = Transform3D(XRHandGestureProvider.basis_from_forward(forward), Vector3(0, 1, -distance))
	ray._grab_distance = distance
	return ray

## Registers a real, resolvable XRHandTracker under the canonical path
## XRHandTrackerResolver scores first (XRHandTrackerResolver.TRACKER_PATHS),
## with only the WRIST joint populated -- the driver never reads any other
## joint. Tests must pair this with _unregister_wrist_tracker so a tracker
## from one test can never leak into the next (XRHandTrackerResolver caches
## its resolution per Engine.get_process_frames(), which does not advance
## between two calls in the same _init(), so a stale cache entry would
## otherwise silently outlive the test that built it).
func _register_wrist_tracker(hand: int, wrist_basis: Basis) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.name = XRHandTrackerResolver.TRACKER_PATHS[hand]
	tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == XRInputAdapter.Hand.LEFT else XRPositionalTracker.TRACKER_HAND_RIGHT
	tracker.has_tracking_data = true
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(wrist_basis, Vector3(0, 1, -0.3)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, valid)
	XRServer.add_tracker(tracker)
	return tracker

func _unregister_wrist_tracker(tracker: XRHandTracker) -> void:
	XRServer.remove_tracker(tracker)
	XRHandTrackerResolver._cache_frame = -1  # force a fresh scan for the next test

## Rolls the wrist tracker built by _register_wrist_tracker to a new absolute
## basis in place (the resolver caches the TRACKER OBJECT, not a value, so
## mutating it here is visible on the driver's very next read).
func _set_wrist_roll(tracker: XRHandTracker, wrist_basis: Basis) -> void:
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(wrist_basis, Vector3(0, 1, -0.3)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, valid)

## Drives one hand's frames until its held distance stops changing (bounded,
## so a broken fixture fails loudly instead of hanging). The absolute mapping
## APPROACHES its target through the ray's max_distance_change_per_second
## rather than snapping to it in one frame (see the driver's own comment on
## why), so any test that cares about the SETTLED distance must let it
## converge rather than reading a single frame.
func _drive_twist_until_settled(driver: XRPinchTwistDistanceDriver, ray: XRRayInteractor, hand: int, max_frames := 200) -> void:
	var previous := ray.get_grab_distance()
	for _frame in range(max_frames):
		driver._drive_hand(hand, 1.0 / 60.0)
		var now := ray.get_grab_distance()
		if is_equal_approx(now, previous):
			return
		previous = now

## Pure math, no tracker/interactor at all: twist_offset (the absolute
## roll-to-distance-offset mapping that replaced the rate/throttle) is exactly
## zero below the start threshold -- the mapping has not ENGAGED at all -- and
## exactly +/- twist_span_metres at +/- the full angle, clamped beyond it.
## Also checks a MID-span value against the closed-form expected result
## (deadband subtracted before scaling), which is what makes Mutation "remove
## the deadband" fail here specifically rather than only being caught
## incidentally by the start-threshold gate.
func _test_twist_offset_engages_scales_and_clamps(failures: Array[String]) -> void:
	var start := deg_to_rad(5.0)
	var deadband := deg_to_rad(1.0)
	var full := deg_to_rad(90.0)
	var span := 2.0

	# Below the start threshold: the mapping has not engaged, regardless of
	# being above or below the (smaller) deadband.
	if not is_equal_approx(XRPinchTwistDistanceDriver.twist_offset(deg_to_rad(2.0), start, deadband, full, span), 0.0):
		failures.append("twist_offset must be zero below the start threshold (2 deg < 5 deg start)")
	if not is_equal_approx(XRPinchTwistDistanceDriver.twist_offset(deg_to_rad(0.5), start, deadband, full, span), 0.0):
		failures.append("twist_offset must be zero inside the deadband (0.5 deg), which is also below the start threshold")

	# At full deflection: exactly +/- span, both directions.
	var positive_full := XRPinchTwistDistanceDriver.twist_offset(full, start, deadband, full, span)
	if not is_equal_approx(positive_full, span):
		failures.append("twist_offset at +full_angle must be +twist_span_metres (%f), got %f" % [span, positive_full])
	var negative_full := XRPinchTwistDistanceDriver.twist_offset(-full, start, deadband, full, span)
	if not is_equal_approx(negative_full, -span):
		failures.append("twist_offset at -full_angle must be -twist_span_metres (%f), got %f" % [-span, negative_full])

	# Twisting further than full_angle must CLAMP, not keep growing -- the
	# assertion Mutation "drop the span clamp" breaks.
	var beyond_full := XRPinchTwistDistanceDriver.twist_offset(full * 1.5, start, deadband, full, span)
	if not is_equal_approx(beyond_full, span):
		failures.append("twist_offset beyond full_angle must clamp at twist_span_metres (%f), got %f" % [span, beyond_full])

	# A mid-span value must match the closed form EXACTLY, including the
	# deadband subtraction -- the assertion Mutation "remove the deadband"
	# breaks (it would compute a larger fraction than expected here).
	var mid := deg_to_rad(45.0)
	var expected_mid := ((mid - deadband) / (full - deadband)) * span
	var actual_mid := XRPinchTwistDistanceDriver.twist_offset(mid, start, deadband, full, span)
	if not is_equal_approx(actual_mid, expected_mid):
		failures.append("twist_offset(45 deg) must equal the deadband-subtracted closed form (%f), got %f" % [expected_mid, actual_mid])

	# Opposite roll must give the exact negation -- the assertion Mutation
	# "make the mapping unsigned" breaks.
	var negative_mid := XRPinchTwistDistanceDriver.twist_offset(-mid, start, deadband, full, span)
	if not is_equal_approx(negative_mid, -expected_mid):
		failures.append("twist_offset(-45 deg) must be the negation of twist_offset(45 deg): expected %f, got %f" % [-expected_mid, negative_mid])

## The swing-twist extraction (XRPinchTwistDistanceDriver.twist_angle) must
## recover the TWIST angle around `axis` regardless of whatever SWING
## (rotation around a perpendicular axis -- what aiming looks like from the
## wrist's own orientation) rides along with it. Composes a known 0.4 rad
## twist around axis with a known 0.3 rad swing around a perpendicular axis
## (order matters: swing * twist, twist applied first -- see the driver's own
## doc comment on twist_angle for the algebra) and asserts the extracted
## angle is the twist ALONE. A mutation that measured roll from the wrist's
## RAW rotation angle (ignoring axis entirely, e.g. current_rotation.get_angle())
## would instead see the compound ~0.5 rad rotation and fail this.
func _test_twist_angle_extracts_roll_independent_of_swing(failures: Array[String]) -> void:
	var axis := Vector3(0, 0, 1)
	var swing_axis := Vector3(1, 0, 0)  # perpendicular to axis, by construction
	var twist_only := Quaternion(axis, 0.4)
	var swing_only := Quaternion(swing_axis, 0.3)
	var composed := swing_only * twist_only  # twist applied first, then swing
	var extracted := XRPinchTwistDistanceDriver.twist_angle(Quaternion.IDENTITY, composed, axis)
	if not is_equal_approx(extracted, 0.4):
		failures.append("twist_angle must extract the 0.4 rad TWIST alone from a twist+swing compound, got %f" % extracted)

	# The reverse twist, same swing, must give the reverse angle -- confirms
	# sign survives the swing contamination too, not just magnitude.
	var reverse_composed := swing_only * Quaternion(axis, -0.4)
	var reverse_extracted := XRPinchTwistDistanceDriver.twist_angle(Quaternion.IDENTITY, reverse_composed, axis)
	if not is_equal_approx(reverse_extracted, -0.4):
		failures.append("twist_angle must extract -0.4 rad for the reversed twist (same swing), got %f" % reverse_extracted)

## Twisting to full deflection settles at engagement_distance +/- twist_span_metres,
## and twisting FURTHER than the full angle clamps rather than continuing --
## the integration-level companion to the pure-math span-clamp assertions
## above, and the one that exercises the real per-frame settle path (rate-
## limited by max_distance_change_per_second) rather than the closed form
## directly. Mutation "drop the span clamp" fails the second half.
func _test_twist_full_deflection_settles_at_span_and_clamps_beyond(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub

	var axis := Vector3(0, 0, -1)  # matches _make_twist_ray's forward above
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)

	# Frame 1: neutral + engagement-distance capture only -- nothing should
	# move yet.
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)
	var engagement_distance := ray.get_grab_distance()
	if not is_equal_approx(engagement_distance, 3.0):
		failures.append("the engagement frame must not itself change distance, got %f" % engagement_distance)

	# Roll to exactly the default full angle (90 deg) and let it settle.
	_set_wrist_roll(tracker, Basis(axis, deg_to_rad(driver.twist_full_angle_degrees)))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	var expected_full := engagement_distance + driver.twist_span_metres
	if not is_equal_approx(ray.get_grab_distance(), expected_full):
		failures.append("full deflection must settle at engagement_distance + twist_span_metres (%f), got %f" % [expected_full, ray.get_grab_distance()])

	# Roll well PAST the full angle -- the offset must clamp at the span, not
	# keep growing.
	_set_wrist_roll(tracker, Basis(axis, deg_to_rad(driver.twist_full_angle_degrees) * 1.6))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray.get_grab_distance(), expected_full):
		failures.append("twisting past the full angle must clamp at engagement_distance + twist_span_metres (%f), got %f -- it must not keep growing" % [expected_full, ray.get_grab_distance()])

	_unregister_wrist_tracker(tracker)
	ray.free()
	stub.free()
	driver.free()

## ---------------------------------------------------------------------------
## twist_pull_reaches_hand (David, in-headset: "when i twist is gets close to
## the hand like 3/4 of the way, provide a way to adjust that for authoring, if
## meta goes all the way to the hand with this adjust it"). twist_span_metres
## is a FIXED offset, so full inward twist landing distance depends on how far
## away the object was when TWIST engaged -- engage at 3 m and it lands at 1 m
## (3/4 of the way in, the exact symptom reported); engage at 10 m and the same
## fixed span barely moves it. The flag defaults true: full inward deflection
## must reach min_grab_distance from ANY engagement distance -- proven here
## from two clearly different ones, 2 m and 6 m, so a mutation that leaves the
## inward span fixed can pass at most one of them.
func _test_twist_pull_reaches_hand_default_reaches_min_grab_distance_from_multiple_engagement_distances(failures: Array[String]) -> void:
	for engagement_distance in [2.0, 6.0]:
		var stub := TwistInteractableStub.new()
		var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), engagement_distance)
		stub._notify_select_entered(ray)

		var driver := XRPinchTwistDistanceDriver.new()
		driver._interactable = stub
		if not driver.twist_pull_reaches_hand:
			failures.append("twist_pull_reaches_hand must default to true")

		var axis := Vector3(0, 0, -1)
		var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
		driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # capture neutral + engagement distance

		# Negative roll is INWARD (confirmed by _test_twist_opposite_rolls_move_opposite_ways_from_engagement:
		# a negative roll settles BELOW the engagement distance).
		_set_wrist_roll(tracker, Basis(axis, -deg_to_rad(driver.twist_full_angle_degrees)))
		_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
		if not is_equal_approx(ray.get_grab_distance(), ray.min_grab_distance):
			failures.append("full inward twist engaged at %f m must reach min_grab_distance (%f) when twist_pull_reaches_hand is true, got %f" % [engagement_distance, ray.min_grab_distance, ray.get_grab_distance()])

		_unregister_wrist_tracker(tracker)
		ray.free()
		stub.free()
		driver.free()

## Companion: with the flag OFF, inward reverts to the pre-authoring-fix
## behaviour -- twist_span_metres, exactly like outward. Engagement distance
## (3 m) is picked so engagement - twist_span_metres (1 m) and min_grab_distance
## (0.25 m) are clearly different numbers, so this cannot pass by coincidence
## against Mutation "make the pull span fixed regardless of the flag".
func _test_twist_pull_reaches_hand_false_uses_span_instead(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub
	driver.twist_pull_reaches_hand = false

	var axis := Vector3(0, 0, -1)
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)
	var engagement_distance := ray.get_grab_distance()

	_set_wrist_roll(tracker, Basis(axis, -deg_to_rad(driver.twist_full_angle_degrees)))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	var expected := engagement_distance - driver.twist_span_metres
	if not is_equal_approx(ray.get_grab_distance(), expected):
		failures.append("with twist_pull_reaches_hand false, full inward twist must settle at engagement_distance - twist_span_metres (%f), got %f" % [expected, ray.get_grab_distance()])
	if is_equal_approx(ray.get_grab_distance(), ray.min_grab_distance):
		failures.append("with twist_pull_reaches_hand false, full inward twist must NOT reach min_grab_distance (%f) -- that is the true-flag behaviour" % ray.min_grab_distance)

	_unregister_wrist_tracker(tracker)
	ray.free()
	stub.free()
	driver.free()

## The flag is documented to change ONLY inward behaviour -- outward must
## settle at the identical engagement_distance + twist_span_metres whether the
## flag is true or false. Mutation "make the flag also change outward
## behaviour" fails this directly.
func _test_twist_pull_reaches_hand_flag_does_not_affect_outward(failures: Array[String]) -> void:
	var outward_distances: Array[float] = []
	for flag_value in [true, false]:
		var stub := TwistInteractableStub.new()
		var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
		stub._notify_select_entered(ray)

		var driver := XRPinchTwistDistanceDriver.new()
		driver._interactable = stub
		driver.twist_pull_reaches_hand = flag_value

		var axis := Vector3(0, 0, -1)
		var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
		driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)
		var engagement_distance := ray.get_grab_distance()

		_set_wrist_roll(tracker, Basis(axis, deg_to_rad(driver.twist_full_angle_degrees)))
		_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
		var expected := engagement_distance + driver.twist_span_metres
		if not is_equal_approx(ray.get_grab_distance(), expected):
			failures.append("outward with twist_pull_reaches_hand=%s must settle at engagement_distance + twist_span_metres (%f), got %f" % [flag_value, expected, ray.get_grab_distance()])
		outward_distances.append(ray.get_grab_distance())

		_unregister_wrist_tracker(tracker)
		ray.free()
		stub.free()
		driver.free()

	if not is_equal_approx(outward_distances[0], outward_distances[1]):
		failures.append("outward deflection must land at the SAME distance regardless of twist_pull_reaches_hand: true=%f, false=%f" % [outward_distances[0], outward_distances[1]])

## Rolling all the way back to neutral after a full INWARD (hand-reaching)
## twist must still retrace to exactly the engagement distance -- the
## headline absolute-mapping guarantee (see
## _test_twist_rolling_back_to_neutral_returns_to_engagement_distance above)
## must keep holding once inward uses a different, engagement-distance-
## dependent span. Mutation "make the pull span fixed regardless of the flag"
## would still likely retrace correctly (it is symmetric in that failure mode),
## so this test's real job is confirming the fix does not BREAK retracing --
## paired with the two tests above, which confirm the fix's actual effect.
func _test_twist_pull_reaches_hand_rolling_back_still_retraces(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 5.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub

	var axis := Vector3(0, 0, -1)
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)
	var engagement_distance := ray.get_grab_distance()

	_set_wrist_roll(tracker, Basis(axis, -deg_to_rad(driver.twist_full_angle_degrees)))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray.get_grab_distance(), ray.min_grab_distance):
		failures.append("fixture broken: full inward twist at 5 m engagement must reach min_grab_distance, got %f" % ray.get_grab_distance())

	_set_wrist_roll(tracker, Basis.IDENTITY)
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray.get_grab_distance(), engagement_distance):
		failures.append("rolling back to neutral after a hand-reaching inward twist must retrace to the engagement distance (%f), got %f" % [engagement_distance, ray.get_grab_distance()])

	_unregister_wrist_tracker(tracker)
	ray.free()
	stub.free()
	driver.free()

## THE headline test for the absolute-mapping correction: after twisting out
## to full deflection, rolling back to EXACTLY the captured neutral must
## settle back at EXACTLY the engagement distance -- retracing, not requiring
## further travel the wrist does not have. This is the assertion the original
## rate/throttle design could not honestly pass (device report: "seems like
## it only goes further") and the one a regression to that mechanic would
## fail immediately.
func _test_twist_rolling_back_to_neutral_returns_to_engagement_distance(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub

	var axis := Vector3(0, 0, -1)
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # capture neutral + engagement distance
	var engagement_distance := ray.get_grab_distance()

	_set_wrist_roll(tracker, Basis(axis, deg_to_rad(driver.twist_full_angle_degrees)))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	if is_equal_approx(ray.get_grab_distance(), engagement_distance):
		failures.append("fixture broken: full deflection must actually move the distance away from engagement -- got %f" % ray.get_grab_distance())

	# Roll all the way back to the captured neutral (Basis.IDENTITY) -- no
	# further travel than what was already used to get out here.
	_set_wrist_roll(tracker, Basis.IDENTITY)
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray.get_grab_distance(), engagement_distance):
		failures.append("rolling back to the captured neutral must retrace to the engagement distance (%f), got %f" % [engagement_distance, ray.get_grab_distance()])

	_unregister_wrist_tracker(tracker)
	ray.free()
	stub.free()
	driver.free()

## Opposite roll directions move to opposite sides of the engagement distance
## -- roll one way pulls in, the other pushes out. Mutation "make the mapping
## unsigned" fails this directly: an unsigned mapping would move BOTH rolls
## the same way.
func _test_twist_opposite_rolls_move_opposite_ways_from_engagement(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub

	var axis := Vector3(0, 0, -1)
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # capture neutral + engagement distance
	var engagement_distance := ray.get_grab_distance()

	var half_angle := deg_to_rad(driver.twist_full_angle_degrees) * 0.5
	_set_wrist_roll(tracker, Basis(axis, half_angle))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	var positive_distance := ray.get_grab_distance()
	if not (positive_distance > engagement_distance):
		failures.append("a positive roll must settle ABOVE the engagement distance (%f), got %f" % [engagement_distance, positive_distance])

	_set_wrist_roll(tracker, Basis(axis, -half_angle))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	var negative_distance := ray.get_grab_distance()
	if not (negative_distance < engagement_distance):
		failures.append("a negative roll must settle BELOW the engagement distance (%f), got %f" % [engagement_distance, negative_distance])

	_unregister_wrist_tracker(tracker)
	ray.free()
	stub.free()
	driver.free()

## Inside the deadband (well under the default 1 degree), nothing moves --
## the guard that lets a comfortable, not-perfectly-still wrist hold a
## position without drifting the distance.
func _test_twist_inside_deadband_nothing_moves(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub

	var axis := Vector3(0, 0, -1)
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # capture neutral + engagement distance
	var engagement_distance := ray.get_grab_distance()

	_set_wrist_roll(tracker, Basis(axis, deg_to_rad(0.3)))  # well inside the 1 deg default deadband
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray.get_grab_distance(), engagement_distance):
		failures.append("a 0.3 deg roll (inside the 1 deg default deadband) must not change distance: engagement %f, now %f" % [engagement_distance, ray.get_grab_distance()])

	_unregister_wrist_tracker(tracker)
	ray.free()
	stub.free()
	driver.free()

## Below the start threshold (but ABOVE the deadband, so this is genuinely
## testing the start-threshold gate and not just a tinier deadband case),
## the mapping has not engaged at all: distance holds exactly at the
## engagement distance. 3 deg sits between the 1 deg default deadband and the
## 5 deg default start threshold.
func _test_twist_below_start_threshold_mapping_not_engaged(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub

	var axis := Vector3(0, 0, -1)
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # capture neutral + engagement distance
	var engagement_distance := ray.get_grab_distance()

	if not (deg_to_rad(3.0) > deg_to_rad(driver.twist_deadband_degrees) and deg_to_rad(3.0) < deg_to_rad(driver.twist_start_threshold_degrees)):
		failures.append("fixture assumption broken: 3 deg must sit strictly between the deadband and the start threshold for this test to mean anything")

	_set_wrist_roll(tracker, Basis(axis, deg_to_rad(3.0)))
	_drive_twist_until_settled(driver, ray, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray.get_grab_distance(), engagement_distance):
		failures.append("a 3 deg roll (above the deadband but below the 5 deg start threshold) must not engage the mapping: engagement %f, now %f" % [engagement_distance, ray.get_grab_distance()])

	_unregister_wrist_tracker(tracker)
	ray.free()
	stub.free()
	driver.free()

## The engagement distance is captured PER GRAB, not once: grab at 2 m, twist,
## release, grab (a different object) at 4 m -- the new zero is 4 m, not 2 m.
## Mutation "use a fixed zero instead of the captured engagement distance"
## fails this directly (a fixed zero could match at most one of the two
## grabs' expectations, never both). Also exercises the release-time forget
## (_forget_neutral_on_release): without it, a release immediately followed
## by a new grab -- no intervening _drive_hand poll -- would silently reuse
## the FIRST grab's neutral/engagement against the second.
func _test_twist_engagement_distance_captured_per_grab(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub
	stub.select_exited.connect(driver._forget_neutral_on_release)

	var axis := Vector3(0, 0, -1)
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)

	# Grab 1: engage at 2 m, twist out, then release -- WITHOUT an
	# intervening _drive_hand call, so the only thing that can forget grab
	# 1's state before grab 2 begins is the release signal itself.
	var ray_one := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 2.0)
	stub._notify_select_entered(ray_one)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # capture neutral + 2 m engagement
	_set_wrist_roll(tracker, Basis(axis, deg_to_rad(driver.twist_full_angle_degrees)))
	_drive_twist_until_settled(driver, ray_one, XRInputAdapter.Hand.LEFT)
	if is_equal_approx(ray_one.get_grab_distance(), 2.0):
		failures.append("fixture broken: grab 1 must actually move away from its 2 m engagement distance")
	stub._notify_select_exited(ray_one)

	# Grab 2: a DIFFERENT ray/object, engaged at 4 m. The wrist is left at
	# grab 1's fully-twisted absolute orientation -- if grab 2 inherited grab
	# 1's neutral, this would already read as a large roll on the very first
	# frame instead of the neutral rotation for grab 2.
	var ray_two := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 4.0)
	stub._notify_select_entered(ray_two)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # must capture a FRESH neutral + 4 m engagement
	if not is_equal_approx(ray_two.get_grab_distance(), 4.0):
		failures.append("grab 2's engagement-capture frame must not itself move the distance away from its own 4 m engagement, got %f" % ray_two.get_grab_distance())

	# Roll back to grab 2's own neutral (the SAME absolute orientation grab 1
	# ended at) and settle -- must land on grab 2's 4 m engagement, not grab
	# 1's 2 m.
	_drive_twist_until_settled(driver, ray_two, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray_two.get_grab_distance(), 4.0):
		failures.append("grab 2's engagement distance must be its OWN 4 m, not grab 1's 2 m: got %f" % ray_two.get_grab_distance())

	_unregister_wrist_tracker(tracker)
	ray_one.free()
	ray_two.free()
	stub.free()
	driver.free()

## Companion to the test above, isolating the ROTATION half specifically: a
## second grab must not inherit the first grab's captured neutral ROLL either
## (not only its engagement distance). Grab 1 ends with the wrist twisted to
## full deflection; grab 2 begins with the wrist AT THAT SAME absolute
## orientation, which must read as grab 2's own zero, not as an
## already-twisted roll carried over from grab 1.
func _test_twist_second_grab_does_not_inherit_previous_neutral_rotation(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub
	stub.select_exited.connect(driver._forget_neutral_on_release)

	var axis := Vector3(0, 0, -1)
	var twisted_basis := Basis(axis, deg_to_rad(60.0))
	var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)

	var ray_one := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray_one)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # grab 1 neutral = Basis.IDENTITY
	_set_wrist_roll(tracker, twisted_basis)
	_drive_twist_until_settled(driver, ray_one, XRInputAdapter.Hand.LEFT)
	stub._notify_select_exited(ray_one)

	# Grab 2 begins with the wrist ALREADY at twisted_basis -- if that reads
	# as anything other than grab 2's own zero, this settles away from 3 m.
	var ray_two := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray_two)
	driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)  # must capture twisted_basis as grab 2's OWN neutral
	_drive_twist_until_settled(driver, ray_two, XRInputAdapter.Hand.LEFT)
	if not is_equal_approx(ray_two.get_grab_distance(), 3.0):
		failures.append("grab 2's neutral rotation must be captured fresh (the wrist's CURRENT orientation), not inherited from grab 1: expected 3.0, got %f" % ray_two.get_grab_distance())

	_unregister_wrist_tracker(tracker)
	ray_one.free()
	ray_two.free()
	stub.free()
	driver.free()

## FIXED and REEL objects are untouched by twist -- that decision is not
## being re-opened (coordinator brief). Same large roll that drives a TWIST
## object in the test above; asserts it does nothing for either mode.
## Mutation "let the driver act regardless of mode" fails this directly.
func _test_twist_fixed_and_reel_unaffected_by_twist(failures: Array[String]) -> void:
	for mode in [XRGrabInteractable.FarGrabMode.FIXED, XRGrabInteractable.FarGrabMode.REEL]:
		var stub := TwistInteractableStub.new()
		stub.far_grab_mode = mode
		var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
		stub._notify_select_entered(ray)

		var driver := XRPinchTwistDistanceDriver.new()
		driver._interactable = stub

		var axis := Vector3(0, 0, -1)
		var tracker := _register_wrist_tracker(XRInputAdapter.Hand.LEFT, Basis.IDENTITY)
		driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)
		var before := ray.get_grab_distance()

		_set_wrist_roll(tracker, Basis(axis, 0.4))
		for _frame in range(3):
			driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)
		var after := ray.get_grab_distance()
		if not is_equal_approx(after, before):
			failures.append("mode %d: a large sustained roll must not change distance outside TWIST, was %f, now %f" % [mode, before, after])

		_unregister_wrist_tracker(tracker)
		ray.free()
		stub.free()
		driver.free()

## Controllers (and a hand that has dropped out of tracking) have no
## resolvable wrist joint. No tracker is registered for this hand at all --
## XRHandTrackerResolver.get_tracker must return null, and the driver must
## hold distance (like FIXED) rather than error. The suite's own PASS/FAIL
## gate is part of what this proves: a crash here would abort the script
## before printing PASS at all (see tools/run_tests.ps1's scripterrors check).
func _test_twist_controller_with_no_wrist_joint_is_inert(failures: Array[String]) -> void:
	var stub := TwistInteractableStub.new()
	var ray := _make_twist_ray(XRInputAdapter.Hand.LEFT, Vector3(0, 0, -1), 3.0)
	stub._notify_select_entered(ray)

	var driver := XRPinchTwistDistanceDriver.new()
	driver._interactable = stub

	# Defensive: make sure nothing left a tracker registered for this hand
	# from an earlier test (each tracker-registering test above unregisters
	# its own, but this guards the fixture rather than trusting ordering).
	var leaked := XRHandTrackerResolver.get_tracker(XRInputAdapter.Hand.LEFT)
	if leaked != null:
		failures.append("fixture broken: a wrist tracker is already resolvable for LEFT before this test registered one")

	var before := ray.get_grab_distance()
	for _frame in range(3):
		driver._drive_hand(XRInputAdapter.Hand.LEFT, 1.0 / 60.0)
	var after := ray.get_grab_distance()
	if not is_equal_approx(after, before):
		failures.append("with no resolvable wrist joint, distance must hold (FIXED-like), was %f, now %f" % [before, after])

	ray.free()
	stub.free()
	driver.free()

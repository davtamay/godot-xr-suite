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

## Companion to the test above: the same plain grabbable in FIXED or REEL mode
## must NOT arm a transit -- the guard's "attracting" clause requires
## far_grab_mode == ATTRACT, so _arm_transit must still return early for these
## two modes, leaving _transit_from untouched at the class default. Catches
## Mutation "drop the mode gate entirely" (not one of Round 2's three, but
## still guarded by this fixture from Round 1).
func _test_fixed_and_reel_do_not_arm_transit_for_a_plain_grabbable(failures: Array[String]) -> void:
	for mode in [XRGrabInteractable.FarGrabMode.FIXED, XRGrabInteractable.FarGrabMode.REEL]:
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

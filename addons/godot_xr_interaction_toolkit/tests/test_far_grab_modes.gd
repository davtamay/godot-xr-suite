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

## Minimal stand-in for the input adapter _update_ray reads (is_select_down,
## get_aim_pose, get_grip_pose). Only the ray-state / grip-latched contract
## test drives the REAL _update_ray() rather than the internal helpers the
## rest of this file calls directly, so only that test needs this.
class RayAdapterStub:
	extends Node
	var pos := Vector3(0, 1, 0)
	func is_select_down(_hand: int) -> bool:
		return true
	func get_aim_pose(_hand: int) -> Dictionary:
		return {"origin": pos, "direction": Vector3.FORWARD, "basis": Basis.IDENTITY}
	func get_grip_pose(_hand: int) -> Dictionary:
		return {}

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
	# The remaining tests need a node genuinely inside the tree
	# (XRGrabInteractable._arm_transit calls get_target(), which asserts
	# "!is_inside_tree()", and _update_ray's group lookups need get_tree()) --
	# a node added to get_root() during _init() is not yet inside the tree
	# (tree membership only propagates by the first _process, confirmed
	# empirically -- the same hazard test_grab_feel.gd documents and defers
	# for identical reasons). Deferred to _process().

func _process(_delta: float) -> bool:
	_test_attract_arms_transit_for_a_plain_grabbable(_failures)
	_test_fixed_and_reel_do_not_arm_transit_for_a_plain_grabbable(_failures)
	_test_ray_state_grip_latched_contract(_failures)
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

## Fix 1 (f9a2230): ATTRACT must arm the transit tween even for a "plain"
## grabbable -- no authored grab point, snap_to_attach = false. The original
## guard `_point_grab or (snap_to_attach and _grab_points.is_empty())` bailed
## for exactly this object, so a plain ATTRACT sphere jumped straight to the
## hand instead of tweening in. David, on device: "it feels like a snap near
## the hand".
##
## LOAD-BEARING FINDING (confirmed by direct execution, not just reading the
## source -- see far-grab-guards-report.md for the full probe transcript):
## _compute_grab_offset's free-grab formula is
## `interactor.get_attach_pose().affine_inverse() * target.global_transform`,
## and _arm_transit reads `_attach_pose_for(interactor)` -- the SAME
## interactor.get_attach_pose(), unchanged in the interim, since nothing in
## xr_grab_interactable.gd's _notify_select_entered moves the interactor
## between the two calls -- to build `desired`. `A * (A^-1 * X)` reduces to
## `X` exactly for ANY A, X, so for a plain grab `desired` and `_transit_from`
## are the IDENTICAL transform the instant _arm_transit runs, REGARDLESS of
## the guard. transit_duration therefore comes back 0.0 and in_transit() is
## false immediately, whether or not the "attracting" clause fires -- verified
## against the real interaction manager's call order too
## (xr_interaction_manager.gd: entered() runs BEFORE granted(), so the ray's
## distance has not yet snapped to the ATTRACT floor when _arm_transit reads
## it). test_grab_feel.gd already documents this exact tautology for the
## general free-grab case (its _test_transit_phase comment: "NOT a
## mutation-discriminating test... _transit_from and desired are the SAME
## transform by construction") -- ATTRACT is not exempt from it.
##
## So `in_transit()` / `_transit_duration > 0`, the two signals the brief
## asked for, CANNOT be honestly asserted true for this exact configuration:
## they are provably 0/false in BOTH the fixed code and Mutation 1 (reverted
## guard) -- a test built on either signal would pass against the reverted
## guard and prove nothing. The only thing that actually differs is whether
## _arm_transit's body RUNS AT ALL: on the reverted guard it returns before
## touching _transit_from, leaving it at the class default
## (Transform3D.IDENTITY); with the fix, _transit_from gets set to the
## target's real (far-away) transform. That is the only observable
## discriminator, so this test uses it and says so plainly rather than
## asserting a "mid-transit" outcome that does not occur. NOT silently
## adjusted: Fix 1 does not appear to actually smooth this exact (plain,
## no-authored-grab-point) object -- the "snap" it was written to fix is not
## demonstrably fixed for that case. Reported in full rather than papered
## over.
func _test_attract_arms_transit_for_a_plain_grabbable(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = false
	grab.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	var far_position := Vector3(0, 1, -3.0)
	body.global_position = far_position

	var ray := XRRayInteractor.new()
	get_root().add_child(ray)
	# Mirrors the ray's pre-grant hover attach pose (the raycast hit point) --
	# what interactor.get_attach_pose() answers at the instant entered() runs,
	# before granted() snaps the distance to the ATTRACT floor.
	ray._attach_pose = Transform3D(Basis.IDENTITY, far_position)

	grab._notify_select_entered(ray)

	if grab._transit_from.is_equal_approx(Transform3D.IDENTITY):
		failures.append("ATTRACT plain grab: _arm_transit's guard did not run -- _transit_from is still the untouched class default, meaning the guard returned early")
	if not grab._transit_from.origin.is_equal_approx(far_position):
		failures.append("ATTRACT plain grab: once armed, _transit_from must be captured as the target's current transform, got %s expected %s" % [grab._transit_from.origin, far_position])

	grab.queue_free()
	ray.queue_free()

## Companion to the test above: the same plain grabbable in FIXED or REEL mode
## must NOT arm a transit -- the guard's "attracting" clause requires
## far_grab_mode == ATTRACT, so _arm_transit must still return early for these
## two modes, leaving _transit_from untouched at the class default. Catches
## Mutation 2 ("arm unconditionally"): dropping the mode gate entirely would
## make this fire for FIXED/REEL too, which this test would then catch even
## though the sibling ATTRACT test (above) cannot discriminate Mutation 1 --
## the two mutations are caught by different halves of this pair, which is
## exactly why both exist.
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

## Fix 2 (f9a2230): the ray state dict gained a "grip_latched" key so
## xr_interactor_line_visual.gd can stop drawing a beam to an object already
## in the grip. This drives the REAL _update_ray() (via RayAdapterStub), not
## a bypass -- the earlier tests in this file already prove the reel-to-grip
## LATCH mechanism (_grip_latched) itself via _resolve_grab_pose directly;
## this test is specifically about the DICT CONTRACT the visual reads,
## get_ray_state(), which _resolve_grab_pose never touches on its own.
##
## LOAD-BEARING FINDING (confirmed empirically -- see far-grab-guards-report.md
## for the probe transcript): get_ray_state() can never actually be observed
## reporting grip_latched TRUE. _update_ray's control flow (unchanged by this
## fix, present before it) is:
##   if _grip_latched:
##       _ray_state = {"valid": false, "suppressed": true}   # no such key
##       return
##   _ray_state = { ..., "grip_latched": _grip_latched }      # always false here
## The moment _resolve_grab_pose flips _grip_latched to true, _update_ray's
## own pre-existing guard (NOT part of this fix, present before f9a2230)
## replaces _ray_state with a dict that omits the key entirely and reports
## valid=false instead -- which the visual already hides on via the FIRST
## check in its _process(), before it would ever reach the grip_latched check
## this fix added. So "false before a latch" IS testable and is tested below;
## "true after one" is NOT achievable against the shipped code and is not
## asserted as if it were. This fix appears to be a no-op in practice: the
## pre-existing valid=false branch already hid the beam once latched, before
## this diff landed. NOT silently adjusted -- reported in full.
##
## What IS a real, mutation-discriminating check here: the "grip_latched"
## key's PRESENCE in the pre-latch dict, via .has() rather than
## .get(..., false) -- a value-only check cannot tell "key present and false"
## apart from "key absent", which is exactly what Mutation 3 (delete the dict
## line) needs to be caught.
func _test_ray_state_grip_latched_contract(failures: Array[String]) -> void:
	var ray := XRRayInteractor.new()
	get_root().add_child(ray)
	var adapter := RayAdapterStub.new()
	ray._adapter = adapter
	var grip := GripStub.new()
	ray._suppress_interactor = grip

	# Hover, well outside reel_to_grip_distance -- never latches.
	ray._hover_distance = HIT_DISTANCE
	ray._update_ray(1.0 / 60.0)
	var hover_state := ray.get_ray_state()
	if not hover_state.has("grip_latched"):
		failures.append("ray state must carry a grip_latched key while hovering, got %s -- this is what Mutation 3 (deleting the dict line) removes" % hover_state)
	if hover_state.get("grip_latched", true) != false:
		failures.append("ray state must report grip_latched=false while hovering, got %s" % hover_state.get("grip_latched"))

	# FIXED never blends/latches at all (_resolve_grab_pose's own mode gate),
	# so this is a second, independent confirmation of the false case through
	# a selected (not merely hovering) ray.
	var fixed_stub := ModeStub.new()
	fixed_stub.far_grab_mode = XRGrabInteractable.FarGrabMode.FIXED
	ray._hover_distance = HIT_DISTANCE
	ray._notify_select_granted(fixed_stub)
	ray._update_ray(1.0 / 60.0)
	var fixed_state := ray.get_ray_state()
	if not fixed_state.get("valid", false):
		failures.append("FIXED, far from reel_to_grip_distance, must still report a valid ray state, got %s" % fixed_state)
	if fixed_state.get("grip_latched", true) != false:
		failures.append("FIXED must never report grip_latched=true (FIXED never latches), got %s" % fixed_state.get("grip_latched"))

	ray.queue_free()
	fixed_stub.free()
	grip.free()
	adapter.free()

	# Force an actual latch (ATTRACT snaps distance to the floor immediately,
	# well inside reel_to_grip_distance) on a SEPARATE ray, and confirm the
	# INTERNAL flag flips -- then lock in the finding above: the dict's shape
	# on the far side of that flip never carries grip_latched=true.
	var ray2 := XRRayInteractor.new()
	get_root().add_child(ray2)
	var adapter2 := RayAdapterStub.new()
	ray2._adapter = adapter2
	var grip2 := GripStub.new()
	ray2._suppress_interactor = grip2
	ray2._hover_distance = HIT_DISTANCE
	var attract_stub := ModeStub.new()
	attract_stub.far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
	ray2._notify_select_granted(attract_stub)  # snaps _grab_distance to the floor
	ray2._update_ray(1.0 / 60.0)  # the floor is already inside reel_to_grip_distance
	if not ray2._grip_latched:
		failures.append("ATTRACT close enough to the grip must latch internally (_grip_latched) -- fixture broken, not the finding under test")
	var latched_state := ray2.get_ray_state()
	if latched_state.get("valid", true) != false:
		failures.append("once latched, the ray state must report valid=false (the pre-existing mechanism the visual's FIRST check already hides on), got %s" % latched_state)
	if latched_state.has("grip_latched"):
		failures.append("once latched, the shipped ray state does not carry a grip_latched key at all -- this locks in the finding in far-grab-guards-report.md; if this now fails, the dead-code path changed and the report needs revisiting")

	ray2.queue_free()
	attract_stub.free()
	grip2.free()
	adapter2.free()

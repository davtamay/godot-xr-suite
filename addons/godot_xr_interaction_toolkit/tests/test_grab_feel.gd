extends SceneTree

## Headless tests for grab feel (docs/grab-feel-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd

const XRControllerHandAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")
const XRSimulator := preload("res://addons/godot_webxr_kit/runtime/xr_simulator.gd")

## Minimal interactor stub for transit-phase tests: only needs to answer
## get_attach_pose() with a pose the test can move frame-to-frame, so the
## transit target is LIVE rather than a static fixture (Task-9 lesson).
class StubInteractor:
	extends Node
	var pose := Transform3D.IDENTITY
	func get_attach_pose() -> Transform3D:
		return pose

var _failures: Array[String] = []

func _init() -> void:
	_test_grip_anchor_prefers_palm(_failures)
	_test_grip_anchor_identity_when_nothing_valid(_failures)
	_test_grab_point_bind_palm_uses_metacarpal_center(_failures)
	_test_simulator_palm_uses_metacarpal_center(_failures)
	_test_throw_consensus(_failures)
	_test_throw_consensus_small_buffer_not_starved(_failures)
	_test_angular_deadzone_not_starved(_failures)
	_test_consensus_tolerance_scales_by_median(_failures)
	_test_consensus_tie_prefers_recent(_failures)
	_test_peak_bias_recovers_deadzone_loss(_failures)
	_test_transit_timing(_failures)
	_test_transit_blend(_failures)
	# _test_grip_pose_stays_on_palm_with_full_hand, _test_transit_phase, and
	# _test_transit_survives_handoff all need a live Node3D.global_transform,
	# which asserts "!is_inside_tree()" if read this early: a node added to
	# get_root() during _init() is not yet inside the tree (confirmed empirically -
	# tree membership only propagates by the first _process). Deferred there.

func _process(_delta: float) -> bool:
	_test_grip_pose_stays_on_palm_with_full_hand(_failures)
	_test_transit_phase(_failures)
	_test_grab_swaps_between_hands(_failures)
	_test_stabilization_is_bounded(_failures)
	_test_ray_recovers_from_wedged_selection(_failures)
	_test_use_axis(_failures)
	_test_activator_publishes_use_value(_failures)
	_test_transit_survives_handoff(_failures)
	_test_transit_respects_track_rotation(_failures)
	_test_angular_release_uses_the_guard(_failures)
	if _failures.is_empty():
		print("XR grab feel: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR grab feel: FAIL (%d)" % _failures.size())
	quit(1)
	return true

func _make_tracker(palm_valid: bool) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.has_tracking_data = true
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, Vector3(0, 1, -0.07)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, valid if palm_valid else 0)
	return tracker

func _test_grip_anchor_prefers_palm(failures: Array[String]) -> void:
	var palm_anchor := XRControllerHandAdapter.resolve_grip_anchor(_make_tracker(true))
	if not palm_anchor.origin.is_equal_approx(Vector3(0, 1, -0.07)):
		failures.append("grip anchor must sit on the PALM when the palm is valid, got %s" % palm_anchor.origin)
	var wrist_anchor := XRControllerHandAdapter.resolve_grip_anchor(_make_tracker(false))
	if not wrist_anchor.origin.is_equal_approx(Vector3(0, 1, 0)):
		failures.append("grip anchor must fall back to the WRIST when the palm is invalid, got %s" % wrist_anchor.origin)

## Fix-round regression (reviewer-found cross-file divergence): XRGrabPoint's
## Preview Hand pose math builds its own wrist-relative "bind" per joint, and
## bind[PALM] used the same retired wrist<->metacarpal midpoint. Aligned it to
## OpenXR's real XR_HAND_JOINT_PALM_EXT convention: the midpoint between the
## middle metacarpal joint and the middle finger's PROXIMAL PHALANX joint (the
## center of the metacarpal bone), not the wrist. A synthetic 3-bone skeleton
## keeps this independent of the shipped hand model asset.
func _test_grab_point_bind_palm_uses_metacarpal_center(failures: Array[String]) -> void:
	var skeleton := Skeleton3D.new()
	var wrist_bone := skeleton.add_bone("wrist")
	var metacarpal_bone := skeleton.add_bone("middle_mc")
	var proximal_bone := skeleton.add_bone("middle_prox")
	skeleton.set_bone_rest(wrist_bone, Transform3D(Basis.IDENTITY, Vector3.ZERO))
	skeleton.set_bone_rest(metacarpal_bone, Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.04)))
	skeleton.set_bone_rest(proximal_bone, Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.08)))

	var joint_bone := {
		XRHandTracker.HAND_JOINT_WRIST: wrist_bone,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL: metacarpal_bone,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL: proximal_bone,
	}

	var grab_point := XRGrabPoint.new()
	var bind: Array = grab_point._build_bind(skeleton, joint_bone, Transform3D.IDENTITY)
	var palm_origin: Vector3 = (bind[XRHandTracker.HAND_JOINT_PALM] as Transform3D).origin
	var expected := Vector3(0, 0, 0.06)  # (0.04 + 0.08) / 2
	if not palm_origin.is_equal_approx(expected):
		failures.append("bind[PALM] must sit at the metacarpal<->proximal-phalanx midpoint, got %s, expected %s" % [palm_origin, expected])
	var wrist_metacarpal_midpoint := Vector3(0, 0, 0.02)  # the retired (wrist + metacarpal) / 2
	if palm_origin.is_equal_approx(wrist_metacarpal_midpoint):
		failures.append("bind[PALM] regressed to the retired wrist<->metacarpal midpoint: %s" % palm_origin)

	grab_point.free()
	skeleton.free()

## Fix-round regression: xr_simulator.gd's fake tracker synthesized its PALM
## joint with the same retired wrist<->metacarpal midpoint. Drives the REAL
## asset-loading path (_load_bind_skeletons reads the shipped generic_hand
## glbs' Skin bind poses) rather than a synthetic double, since it turns out
## to be genuinely headless-testable: no editor and no scene-tree dependency
## (confirmed - it only touches ResourceLoader/PackedScene/Skin/Skeleton3D
## bind data, never Node3D.global_transform).
func _test_simulator_palm_uses_metacarpal_center(failures: Array[String]) -> void:
	var sim := XRSimulator.new()
	if not sim._load_bind_skeletons():
		failures.append("XRSimulator failed to load its bind skeletons - cannot check its PALM synthesis")
		sim.free()
		return
	for hand in 2:
		var rel: Array = sim._bind[hand]["rel"]
		var palm: Vector3 = (rel[XRHandTracker.HAND_JOINT_PALM] as Transform3D).origin
		var metacarpal: Vector3 = (rel[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL] as Transform3D).origin
		var proximal: Vector3 = (rel[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL] as Transform3D).origin
		var expected := (metacarpal + proximal) * 0.5
		if not palm.is_equal_approx(expected):
			failures.append("hand %d: simulator PALM must be the metacarpal<->proximal-phalanx midpoint, got %s, expected %s" % [hand, palm, expected])
		var retired_midpoint := metacarpal * 0.5  # (wrist + metacarpal) / 2, wrist = origin in this wrist-relative frame
		if palm.is_equal_approx(retired_midpoint):
			failures.append("hand %d: simulator PALM regressed to the retired wrist<->metacarpal midpoint: %s" % [hand, palm])
	sim.free()

## Regression for the 2026-07-19 (15d3783) wrist<->middle-metacarpal midpoint
## that silently overrode resolve_grip_anchor()'s PALM-first choice whenever
## the metacarpals were also tracked - the normal case on real hardware, so
## the override fired on effectively every real grab. Drives the actual call
## site (get_grip_pose, via a real registered XRHandTracker), not just the
## extracted selector, since the midpoint bug lived downstream of it.
func _test_grip_pose_stays_on_palm_with_full_hand(failures: Array[String]) -> void:
	var hand_id := XRControllerHandAdapter.Hand.RIGHT
	var palm_position := Vector3(0, 1, -0.05)
	var wrist_position := Vector3(0, 1, 0)
	var midpoint := (wrist_position + Vector3(0, 1.015, -0.035)) * 0.5

	var was_conditioned := XRHandTrackerResolver.is_conditioned()
	XRHandTrackerResolver._conditioned = false
	XRHandTrackerResolver._cache_frame = -1

	var tracker := XRHandTracker.new()
	tracker.name = "/user/hand_tracker/right"
	tracker.hand = XRPositionalTracker.TRACKER_HAND_RIGHT
	tracker.has_tracking_data = true
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(Basis.IDENTITY, wrist_position))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, palm_position))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, Transform3D(Basis.IDENTITY, Vector3(0.02, 1.02, -0.03)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, Transform3D(Basis.IDENTITY, Vector3(-0.02, 1.01, -0.03)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, Transform3D(Basis.IDENTITY, Vector3(0, 1.015, -0.035)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, valid)
	XRServer.add_tracker(tracker)

	var adapter := XRControllerHandAdapter.new()
	var origin_node := Node3D.new()
	get_root().add_child(origin_node)  # global_transform asserts on an out-of-tree node
	adapter._origin = origin_node
	var pose := adapter.get_grip_pose(hand_id)

	if pose.is_empty():
		failures.append("get_grip_pose returned nothing with a fully-tracked hand")
	else:
		var origin: Vector3 = pose["origin"]
		if not origin.is_equal_approx(palm_position):
			failures.append("grip pose origin must stay on the PALM joint with a full hand tracked, got %s (palm %s, midpoint %s)" % [origin, palm_position, midpoint])
		if origin.is_equal_approx(midpoint):
			failures.append("grip pose origin regressed to the retired wrist<->metacarpal midpoint: %s" % origin)
		if origin.is_equal_approx(wrist_position):
			failures.append("grip pose origin regressed to the raw WRIST joint: %s" % origin)

	adapter.free()
	get_root().remove_child(origin_node)
	origin_node.free()
	XRServer.remove_tracker(tracker)
	XRHandTrackerResolver._conditioned = was_conditioned
	XRHandTrackerResolver._cache_frame = -1

func _test_throw_consensus(failures: Array[String]) -> void:
	# A clean constant-velocity throw: consensus == the velocity.
	var clean: Array[Vector3] = []
	for i in range(10):
		clean.append(Vector3(2, 1, 0))
	var v := XRGrabInteractable.throw_consensus(clean, 2, 0.35)
	if not v.is_equal_approx(Vector3(2, 1, 0)):
		failures.append("clean throw: expected (2,1,0), got %s" % v)

	# Release corruption: last 2 samples wildly wrong (fingers peeling off).
	# The old mean is dragged sideways; consensus must not be.
	var corrupted: Array[Vector3] = []
	for i in range(8):
		corrupted.append(Vector3(2, 1, 0) + Vector3(randf(), randf(), randf()) * 0.0)  # deterministic: exact
	corrupted.append(Vector3(-6, 0, 4))
	corrupted.append(Vector3(0, -9, 2))
	var cv := XRGrabInteractable.throw_consensus(corrupted, 2, 0.35)
	if cv.distance_to(Vector3(2, 1, 0)) > 0.05:
		failures.append("corrupted tail leaked into the estimate: %s" % cv)

	# Mid-buffer outlier (tracking glitch): consensus rejects it, mean cannot.
	var glitched: Array[Vector3] = []
	for i in range(9):
		glitched.append(Vector3(0, 0, -3))
	glitched.insert(4, Vector3(8, 8, 8))
	# dead-zone removes the newest 2 REAL samples; glitch is mid-buffer and must
	# be rejected by consensus, not the dead-zone.
	var gv := XRGrabInteractable.throw_consensus(glitched, 2, 0.35)
	if gv.distance_to(Vector3(0, 0, -3)) > 0.05:
		failures.append("mid-buffer glitch leaked into the estimate: %s" % gv)

	# Degenerate: fewer than 4 usable -> plain mean fallback (documented).
	var short: Array[Vector3] = [Vector3.ONE, Vector3.ONE, Vector3.ONE]
	var sv := XRGrabInteractable.throw_consensus(short, 2, 0.35)
	if not sv.is_equal_approx(Vector3.ONE):
		failures.append("short-buffer fallback broke: %s" % sv)
	if XRGrabInteractable.throw_consensus([], 2, 0.35) != Vector3.ZERO:
		failures.append("empty input must return ZERO")

	# Dead-zone-decisive: a slowdown tail (fingers decelerating through
	# release) forms the LARGER cluster, so consensus alone would pick it.
	# Only the dead-zone dropping the 2 newest keeps the true velocity ahead:
	# without it, tail cluster = 5 beats clean = 4; with it, 3 vs 4.
	var decisive: Array[Vector3] = []
	for i in range(4):
		decisive.append(Vector3(2, 1, 0))
	for i in range(5):
		decisive.append(Vector3(0.1, 0.05, 0))
	var dv := XRGrabInteractable.throw_consensus(decisive, 2, 0.35)
	if dv.distance_to(Vector3(2, 1, 0)) > 0.05:
		failures.append("dead-zone must keep the slowdown tail from winning consensus: %s" % dv)

## Coordinator-flagged regression: throw_sample_frames=3 (throwable.tscn,
## throw_station.tscn's Block1-4) with the default throw_deadzone_frames=2
## leaves only 1 usable sample after an UNGUARDED dead-zone slice, so
## _mean_of([oldest]) = the single oldest, stale sample -- strictly worse
## than the pre-branch behaviour, which averaged all 3. Two clean (oldest)
## samples plus one deliberately different (newest) sample makes the 1-sample
## and 3-sample answers differ by a measurable, exact amount: an unguarded
## slice returns the clean value alone; a guarded slice (dead-zone shrunk to
## keep >=3 usable) returns the mean of all three, pulled toward the newest.
func _test_throw_consensus_small_buffer_not_starved(failures: Array[String]) -> void:
	var clean := Vector3(2, 1, 0)
	var different := Vector3(5, 1, 0)
	var small: Array[Vector3] = [clean, clean, different]
	var expected_mean := (clean + clean + different) / 3.0  # (3, 1, 0)
	var starved := clean  # what an unguarded slice(0, 1) would return
	var result := XRGrabInteractable.throw_consensus(small, 2, 0.35)
	if not result.is_equal_approx(expected_mean):
		failures.append("3-sample buffer with deadzone_frames=2 must shrink the dead-zone and use all 3 samples: expected %s, got %s" % [expected_mean, result])
	if result.is_equal_approx(starved):
		failures.append("3-sample buffer was starved down to the single oldest sample (%s) -- dead-zone guard did not engage" % starved)

func _test_transit_timing(failures: Array[String]) -> void:
	var origin := Transform3D.IDENTITY
	# 0.3 m translation, no rotation, speed 1.5 -> 0.2 s.
	var moved := Transform3D(Basis.IDENTITY, Vector3(0.3, 0, 0))
	if not is_equal_approx(XRGrabInteractable.transit_duration(origin, moved, 1.5), 0.2):
		failures.append("translation-dominant duration wrong")
	# 180 deg rotation, no translation: perceived 180*0.5/360 = 0.25 m -> 1/6 s.
	var flipped := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	if not is_equal_approx(XRGrabInteractable.transit_duration(origin, flipped, 1.5), 0.25 / 1.5):
		failures.append("rotation-dominant duration wrong")
	# Rotation must be able to DOMINATE a small translation (the ISDK point).
	var both := Transform3D(Basis(Vector3.UP, PI), Vector3(0.05, 0, 0))
	if not is_equal_approx(XRGrabInteractable.transit_duration(origin, both, 1.5), 0.25 / 1.5):
		failures.append("rotation must dominate when perceived-larger")
	if XRGrabInteractable.transit_duration(origin, moved, 0.0) != 0.0:
		failures.append("zero speed must yield zero duration (transit skipped)")

func _test_transit_blend(failures: Array[String]) -> void:
	var from := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var to := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(1, 0, 0))
	var mid := XRGrabInteractable.transit_blend(from, to, 0.5)
	if not mid.origin.is_equal_approx(Vector3(0.5, 0, 0)):
		failures.append("blend origin at 0.5 wrong: %s" % mid.origin)
	var mid_angle := mid.basis.get_rotation_quaternion().angle_to(from.basis.get_rotation_quaternion())
	if absf(mid_angle - PI * 0.25) > 0.01:
		failures.append("blend rotation at 0.5 wrong: %f rad" % mid_angle)
	if not XRGrabInteractable.transit_blend(from, to, 1.5).origin.is_equal_approx(to.origin):
		failures.append("alpha must clamp at 1")
	# Scale rides through transit untouched, for NON-UNIFORM scale on a rotated
	# basis -- the case where get_scale()/scaled() round-tripping permutes axes.
	var object_scale := Basis(Vector3.UP, PI * 0.25).scaled(Vector3(2, 0.5, 3))
	var scaled_from := Transform3D(object_scale, Vector3.ZERO)
	var scaled_to := Transform3D(Basis(Vector3.UP, PI * 0.75) * (Basis(Vector3.UP, PI * 0.25).inverse() * object_scale), Vector3(1, 0, 0))
	if not XRGrabInteractable.transit_blend(scaled_from, scaled_to, 0.0).basis.is_equal_approx(scaled_from.basis):
		failures.append("alpha 0 must reproduce the source basis exactly")
	var landed := XRGrabInteractable.transit_blend(scaled_from, scaled_to, 1.0).basis
	if not landed.is_equal_approx(scaled_to.basis):
		failures.append("alpha 1 must reproduce the target basis exactly for non-uniform scale, got %s vs %s" % [landed, scaled_to.basis])
	var midway := XRGrabInteractable.transit_blend(scaled_from, scaled_to, 0.5).basis
	if absf(midway.determinant() - object_scale.determinant()) > 0.001:
		failures.append("transit must not change object volume mid-tween: %f vs %f" % [midway.determinant(), object_scale.determinant()])

## Encodes the Task-9 lesson (static fixtures cannot expose feed-forward /
## handoff bugs): drives _physics_process directly with a stub interactor
## whose pose MOVES every frame, so transit must converge onto a LIVE target,
## not a snapshot taken at grab time. Also proves free grabs (no grab point,
## no snap_to_attach) never transit -- hold-where-grabbed, offset exact.
func _test_transit_phase(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = true      # authored-grip style: transit arms
	grab.track_rotation = true
	grab.transit_speed = 1.5
	var interactor := StubInteractor.new()
	get_root().add_child(interactor)
	interactor.pose = Transform3D(Basis.IDENTITY, Vector3(0.3, 1.0, 0.0))
	body.global_position = Vector3.ZERO  # 0.3+ m from grip -> real transit

	grab._notify_select_entered(interactor)
	if not grab.in_transit():
		failures.append("snap grab 0.3 m away must enter transit")
	# Simulate 60 physics frames while the HAND MOVES; transit target is live.
	# Fast enough (1.2 m/s) that a "captured at grab time" target would land
	# ~0.24 m away from the live one by the time the ~0.2 s transit ends --
	# large enough that a mutant blending toward a frozen target instead of
	# the live one produces either a wrong landing spot or a visible pop when
	# the post-transit INSTANT catch-up re-syncs to the live pose (a 60-frame
	# "did it eventually arrive" check alone cannot see that pop: the coast
	# phase papers over it, confirmed empirically -- see mutation (a) log).
	var previous_position := body.global_position
	var max_frame_jump := 0.0
	for frame in range(60):
		interactor.pose.origin += Vector3(0.0, 0.0, -0.02)
		grab._physics_process(1.0 / 60.0)
		var jump := body.global_position.distance_to(previous_position)
		max_frame_jump = maxf(max_frame_jump, jump)
		previous_position = body.global_position
	if grab.in_transit():
		failures.append("transit must have ended (duration ~0.2 s < 1 s simulated)")
	if not body.global_position.is_equal_approx(interactor.pose.origin):
		failures.append("after transit the object must sit exactly on the LIVE attach pose, got %s vs %s" % [body.global_position, interactor.pose.origin])
	if max_frame_jump > 0.15:
		failures.append("transit must track the LIVE attach pose smoothly, no frame may pop >0.15 m; worst single-frame jump was %.3f m" % max_frame_jump)

	# Free grab (no snap, no grab point): NEVER transits, offset exact.
	var free := XRGrabInteractable.new()
	var free_body := Node3D.new()
	free.add_child(free_body)
	get_root().add_child(free)
	free.target_path = free.get_path_to(free_body)
	free_body.global_position = Vector3(0.05, 0.9, -0.1)
	var free_interactor := StubInteractor.new()
	get_root().add_child(free_interactor)
	free_interactor.pose = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var relative := free_body.global_position - free_interactor.pose.origin
	free._notify_select_entered(free_interactor)
	if free.in_transit():
		failures.append("free grab must not transit")
	free_interactor.pose.origin += Vector3(0.2, 0.1, 0.0)
	free._physics_process(1.0 / 60.0)
	var new_relative := free_body.global_position - free_interactor.pose.origin
	if not new_relative.is_equal_approx(relative):
		failures.append("hold-where-grabbed offset drifted: %s -> %s" % [relative, new_relative])

	# The "free grab must not transit" check above is NOT, by itself, a
	# mutation-discriminating test: a true free grab's offset is computed as
	# `interactor.get_attach_pose().affine_inverse() * target.global_transform`,
	# so `desired == _attach_pose_for(interactor) * _grab_offset` reduces
	# algebraically to `target.global_transform` exactly -- `_transit_from`
	# and `desired` are the SAME transform by construction, so
	# transit_duration is ~0 REGARDLESS of whether the arming guard runs
	# (confirmed empirically: forcing the guard open on the free-grab object
	# above still left in_transit() false and the offset check passing).
	# This snap_to_attach case is NOT tautological -- its offset comes from
	# an attach node / IDENTITY fallback, independent of the interactor's
	# live pose -- so it is where a dropped guard is actually observable.
	# It also exercises a real edge in the brief's stated arming condition:
	# `_grab_points.is_empty()` means "the object has NO grab points
	# registered anywhere", not "no point matched THIS interactor". An
	# object with an authored point for the OTHER hand only denies transit
	# to a snap_to_attach grab on THIS hand even though this grab is not
	# using the free/hold-where-grabbed offset formula. Implemented exactly
	# per the brief's given condition (an interface contract, not something
	# to silently rewrite); flagged here and in the report rather than
	# changed unilaterally.
	var gated := XRGrabInteractable.new()
	var gated_body := Node3D.new()
	gated.add_child(gated_body)
	get_root().add_child(gated)
	gated.target_path = gated.get_path_to(gated_body)
	gated.snap_to_attach = true
	gated_body.global_position = Vector3(2.0, 2.0, 2.0)  # far from the interactor: nonzero offset IF armed
	var phantom_point := Node3D.new()  # registered, never added to the tree -> never matches any hand, but keeps _grab_points non-empty
	gated.register_grab_point(phantom_point)
	var gated_interactor := StubInteractor.new()
	get_root().add_child(gated_interactor)
	gated_interactor.pose = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	gated._notify_select_entered(gated_interactor)
	if gated.in_transit():
		failures.append("snap_to_attach grab must not transit while an unrelated grab point keeps _grab_points non-empty (arming guard bypassed)")

	grab.queue_free(); interactor.queue_free(); free.queue_free(); free_interactor.queue_free()
	gated.queue_free(); gated_interactor.queue_free(); phantom_point.queue_free()

## LOAD-BEARING regression: transit_blend's exactness at alpha=1 depends on
## `from` and `to` carrying the SAME object scale/pose lineage. That breaks
## whenever `_grab_offset` is recomputed with a different grab point/attach
## pose mid-transit -- which a two-hand -> one-hand handoff does in
## _notify_select_exited. Drives that exact sequence: single-hand snap grab
## arms a transit, a second hand joins (must clear the leftover transit --
## two-hand tracking doesn't touch _grab_offset at all), the two-hand session
## moves the object well away from where the stale single-hand _transit_from
## was captured, then the second hand releases (handoff recomputes
## _grab_offset). If the handoff doesn't re-arm/clear, the next frame blends
## from that STALE pre-two-hand transform toward the new live target and pops
## the object backward -- a wrong-but-plausible position with no engine error.
func _test_transit_survives_handoff(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = true
	grab.two_hand_grab_enabled = true
	grab.track_rotation = true
	grab.transit_speed = 1.5
	body.global_position = Vector3.ZERO

	var hand_a := StubInteractor.new()
	get_root().add_child(hand_a)
	hand_a.pose = Transform3D(Basis.IDENTITY, Vector3(0.3, 1.0, 0.0))  # 0.3 m -> ~0.2 s transit @ speed 1.5

	grab._notify_select_entered(hand_a)
	if not grab.in_transit():
		failures.append("handoff setup: single-hand snap grab 0.3 m away must arm transit")

	# One frame in: the transit has barely progressed (1/60 s of a ~0.2 s transit).
	grab._physics_process(1.0 / 60.0)
	if not grab.in_transit():
		failures.append("handoff setup: transit must still be in flight after 1 frame")

	# Second hand joins well away from the first -> two-hand grab begins.
	# Two-hand tracking never reads _grab_offset/_transit_*, so a leftover
	# single-hand transit would otherwise sit frozen (armed but un-decremented)
	# through the whole two-hand session.
	var hand_b := StubInteractor.new()
	get_root().add_child(hand_b)
	hand_b.pose = Transform3D(Basis.IDENTITY, Vector3(0.9, 1.0, 0.0))
	grab._notify_select_entered(hand_b)
	if grab.in_transit():
		failures.append("two-hand begin must clear any leftover single-hand transit")

	# Two-hand session: separate the hands (distance 0.6 -> 1.8 m, i.e. 3.0x)
	# WHILE ALSO shifting the midpoint by the same total translation as
	# before (per-frame average of the two hand deltas is unchanged), so the
	# stale-target assertions below still hold. two_hand_scale (default true,
	# set explicitly for clarity) means this genuinely scales the object --
	# the case that motivates the whole re-arm decision. A fixture that moves
	# both hands by the same vector (as an earlier version of this test did)
	# never changes hand DISTANCE, so two_hand_scale never actually fires and
	# the scale-staleness case goes completely unexercised.
	grab.two_hand_scale = true
	for frame in range(10):
		hand_a.pose.origin += Vector3(-0.01, 0.0, 0.02)
		hand_b.pose.origin += Vector3(0.11, 0.0, 0.02)
		grab._physics_process(1.0 / 60.0)
	var pos_before_handoff := body.global_position
	var det_before_handoff := body.global_transform.basis.determinant()
	if pos_before_handoff.distance_to(Vector3.ZERO) < 0.2:
		failures.append("handoff setup: two-hand session must move the object well away from the stale pre-grab pose, got %s" % pos_before_handoff)
	if absf(det_before_handoff - 27.0) > 0.5:
		failures.append("handoff setup: two-hand session must scale the object to 3.0x (determinant 27), got determinant %.3f" % det_before_handoff)

	# Hand B releases: two-hand -> one-hand handoff recomputes _grab_offset
	# against hand A's CURRENT pose and the object's CURRENT (moved, SCALED)
	# transform.
	grab._notify_select_exited(hand_b)

	# The very next frame is where a leftover/stale transit would pop the
	# object backward toward the ORIGINAL pre-grab pose (near Vector3.ZERO)
	# instead of continuing smoothly from where the two-hand grab left it.
	hand_a.pose.origin += Vector3(0.01, 0.0, 0.0)
	grab._physics_process(1.0 / 60.0)
	var jump := body.global_position.distance_to(pos_before_handoff)
	if jump > 0.05:
		failures.append("handoff must not pop the object toward a stale pre-grab transit target: jumped %.3f m (pos %s, was %s)" % [jump, body.global_position, pos_before_handoff])
	if body.global_position.distance_to(Vector3.ZERO) < pos_before_handoff.distance_to(Vector3.ZERO) * 0.5:
		failures.append("handoff object landed suspiciously close to the STALE pre-grab origin: %s" % body.global_position)

	# Run the SAME handoff-re-armed transit to completion, tracking scale
	# drift every frame. transit_blend (Task 3) carries `from`'s scale
	# through UNTOUCHED for the entire blend, by construction -- if
	# _arm_transit recaptured a STALE _transit_from (e.g. the pre-two-hand,
	# unscaled 1.0x object pose) instead of the object's CURRENT (3.0x)
	# transform at the moment of handoff, the whole blend would carry the
	# WRONG constant scale from start to finish and land on a
	# wrong-but-plausible basis with no engine error -- exactly the
	# load-bearing concern this test exists to catch. Compares determinant
	# (not Basis.get_scale(), per the Task 3 lesson: get_scale() silently
	# permutes axes once a basis is rotated with non-uniform scale -- moot
	# here since scale is uniform, but determinant is the sound choice on
	# principle) against every frame while still in transit, and against the
	# final value once the transit ends.
	var max_scale_drift := 0.0
	var transit_frames := 0
	while grab.in_transit() and transit_frames < 400:
		hand_a.pose.origin += Vector3(0.0, 0.0, -0.001)
		grab._physics_process(1.0 / 60.0)
		var det_now := body.global_transform.basis.determinant()
		max_scale_drift = maxf(max_scale_drift, absf(det_now - det_before_handoff))
		transit_frames += 1
	if grab.in_transit():
		failures.append("handoff-re-armed transit did not finish within the 400-frame test budget -- something is stuck")
	if max_scale_drift > 0.01:
		failures.append("object scale must not drift across the re-armed handoff transit: max |determinant delta| = %.4f (scale at handoff had determinant %.4f)" % [max_scale_drift, det_before_handoff])
	var det_at_settle := body.global_transform.basis.determinant()
	if absf(det_at_settle - det_before_handoff) > 0.01:
		failures.append("object scale once the re-armed transit ends must match the scale it had at handoff: settle determinant %.4f, handoff determinant %.4f" % [det_at_settle, det_before_handoff])
	if not body.global_position.is_equal_approx(hand_a.pose.origin):
		failures.append("handoff-re-armed transit must land exactly on hand A's live pose at alpha=1, got %s vs %s" % [body.global_position, hand_a.pose.origin])

	# Separately: releasing to zero grabbers must clear a transit that is
	# genuinely still in flight (not one that already finished on its own,
	# like the one just driven to completion above). _physics_process
	# returns early with no grabbers, so a leftover _transit_time_left would
	# never get the chance to decrement afterward.
	grab._notify_select_exited(hand_a)
	hand_a.pose = Transform3D(Basis.IDENTITY, hand_a.pose.origin + Vector3(1.0, 0.0, 0.0))  # far enough for a real transit
	grab._notify_select_entered(hand_a)
	if not grab.in_transit():
		failures.append("handoff test teardown: re-grab 1 m away must arm a fresh transit")
	grab._physics_process(1.0 / 60.0)
	if not grab.in_transit():
		failures.append("handoff test teardown: transit must still be in flight after 1 frame")
	grab._notify_select_exited(hand_a)
	if grab.in_transit():
		failures.append("releasing to zero grabbers must clear a still-armed transit, not leave in_transit() stuck true")

	grab.queue_free(); hand_a.queue_free(); hand_b.queue_free()

func _test_angular_deadzone_not_starved(failures: Array[String]) -> void:
	# The angular estimate used to slice the dead-zone off raw, unguarded: on the
	# shipped throw prefabs (throw_sample_frames = 3) that left ONE sample, and at
	# 2 it left NONE -- zero angular velocity. Both paths now share _deadzone_slice.
	var three: Array[Vector3] = [Vector3(0, 4, 0), Vector3(0, 8, 0), Vector3(0, 16, 0)]
	var guarded := XRGrabInteractable._deadzone_slice(three, 2)
	if guarded.size() != 3:
		failures.append("a 3-sample angular buffer must keep all 3 rather than starve to 1, got %d" % guarded.size())
	var two: Array[Vector3] = [Vector3(0, 4, 0), Vector3(0, 9, 0)]
	var tiny := XRGrabInteractable._deadzone_slice(two, 2)
	if tiny.is_empty():
		failures.append("a 2-sample buffer must never slice to empty -- angular velocity would be exactly zero")
	# A buffer large enough to afford the dead-zone still pays it in full.
	var plenty: Array[Vector3] = []
	for i in range(10):
		plenty.append(Vector3(0, float(i), 0))
	if XRGrabInteractable._deadzone_slice(plenty, 2).size() != 8:
		failures.append("a 10-sample buffer must still drop the newest 2")

func _test_consensus_tolerance_scales_by_median(failures: Array[String]) -> void:
	# The cluster radius is tolerance * MEDIAN magnitude. Using the minimum
	# instead silently shrinks the radius to near-nothing on any throw containing
	# one slow sample -- the tolerance stops meaning anything physical.
	# Here: median magnitude 5.0 -> limit 1.75; min magnitude 0.02 -> limit 0.007,
	# which isolates every sample and returns a single-sample estimate.
	# The slow sample is NEWEST deliberately: under the min-magnitude mutant every
	# sample isolates into its own singleton cluster and the tie-to-recent rule
	# then returns this one. With the slow sample oldest, the tie handed back a
	# fast singleton and the mutation sailed through.
	var samples: Array[Vector3] = [
		Vector3(5.0, 0, 0),
		Vector3(5.4, 0, 0),
		Vector3(5.8, 0, 0),
		Vector3(6.2, 0, 0),
		Vector3(0.02, 0, 0),
	]
	var estimate := XRGrabInteractable.throw_consensus(samples, 0, 0.35)
	if estimate.x < 5.0:
		failures.append("consensus must cluster the fast samples via the MEDIAN magnitude, got %s" % estimate)

func _test_consensus_tie_prefers_recent(failures: Array[String]) -> void:
	# Two clusters of equal size: the design says ties go to the MORE RECENT set,
	# because the later samples are closer to the actual release.
	var samples: Array[Vector3] = [
		Vector3(1.0, 0, 0),
		Vector3(1.0, 0, 0),
		Vector3(4.0, 0, 0),
		Vector3(4.0, 0, 0),
	]
	var estimate := XRGrabInteractable.throw_consensus(samples, 0, 0.20)
	if not is_equal_approx(estimate.x, 4.0):
		failures.append("a tie must resolve to the more recent cluster (4.0), got %s" % estimate)

func _test_transit_respects_track_rotation(failures: Array[String]) -> void:
	# Transit used to assign target.global_transform directly, bypassing the
	# track_rotation / track_position / movement_type gate that governs every
	# other frame of a grab. A snap grab with track_rotation = false then twisted
	# into the grip during transit and FROZE there, because the post-transit
	# _apply_movement preserves whatever basis transit left behind. Every other
	# transit fixture sets track_rotation = true, which is why nothing caught it.
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = true
	grab.track_rotation = false
	grab.transit_speed = 1.5
	var interactor := StubInteractor.new()
	get_root().add_child(interactor)
	# A grip rotated well away from the object's resting basis: if transit ignored
	# the gate, the object would visibly yaw into it.
	interactor.pose = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0.3, 1.0, 0.0))
	body.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var resting_basis := body.global_transform.basis

	grab._notify_select_entered(interactor)
	var worst_drift := 0.0
	for frame in range(60):
		grab._physics_process(1.0 / 60.0)
		var drift := rad_to_deg(body.global_transform.basis.get_rotation_quaternion().angle_to(resting_basis.get_rotation_quaternion()))
		worst_drift = maxf(worst_drift, drift)
	if worst_drift > 0.5:
		failures.append("track_rotation = false must hold the basis through transit too, drifted %.1f deg" % worst_drift)
	if grab.in_transit():
		failures.append("transit should have completed within 60 frames")

	grab.queue_free()
	interactor.queue_free()

func _test_angular_release_uses_the_guard(failures: Array[String]) -> void:
	# Exercises the RELEASE PATH, not just _deadzone_slice: an earlier revision
	# guarded only the linear estimate, so the angular one still sliced raw and
	# starved to a single stale sample on the shipped throw prefabs
	# (throw_sample_frames = 3). Asserting the helper alone cannot see that --
	# the defect lives in the call site.
	var grab := XRGrabInteractable.new()
	var body := RigidBody3D.new()
	body.freeze = true
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.throw_on_release = true
	grab.throw_sample_frames = 3
	grab.throw_deadzone_frames = 2
	grab.throw_angular_velocity_scale = 1.0
	grab.max_throw_angular_speed = 100.0
	grab._has_throw_sample = true
	# An accelerating spin: the 3-sample mean is 10.0, the single-oldest-sample
	# answer a starved slice would give is 4.0.
	grab._throw_angular_samples.assign([Vector3(0, 4, 0), Vector3(0, 10, 0), Vector3(0, 16, 0)])
	grab._throw_linear_samples.assign([Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 0)])

	body.freeze = false
	grab._apply_throw_on_release()
	var spin := body.angular_velocity.y
	if absf(spin - 10.0) > 0.01:
		failures.append("release must average all 3 angular samples (10.0), got %.3f -- a starved slice yields 4.0" % spin)

	grab.queue_free()

func _test_grip_anchor_identity_when_nothing_valid(failures: Array[String]) -> void:
	# Public static: with neither palm nor wrist valid it must hand back identity
	# rather than whatever stale transform the tracker still carries.
	var tracker := XRHandTracker.new()
	tracker.has_tracking_data = true
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(Basis.IDENTITY, Vector3(9, 9, 9)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, 0)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, Vector3(9, 9, 9)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, 0)
	var anchor := XRControllerHandAdapter.resolve_grip_anchor(tracker)
	if not anchor.is_equal_approx(Transform3D.IDENTITY):
		failures.append("no valid joint must yield identity, got %s" % anchor.origin)

func _test_peak_bias_recovers_deadzone_loss(failures: Array[String]) -> void:
	# The dead-zone drops the newest frames, which on an accelerating throw are
	# the FASTEST -- so a pure mean systematically under-throws. Leaning toward
	# the peak of the CLEAN samples recovers speed without readmitting the
	# corrupted release frames.
	var ramp: Array[Vector3] = []
	for i in range(10):
		ramp.append(Vector3(0.4 + 0.4 * float(i), 0, 0))
	var mean_only := XRGrabInteractable.throw_consensus(ramp, 2, 0.35, 0.0)
	var leaned := XRGrabInteractable.throw_consensus(ramp, 2, 0.35, 0.6)
	if leaned.x <= mean_only.x:
		failures.append("peak bias must speed up an accelerating throw: %.3f vs %.3f" % [leaned.x, mean_only.x])
	var full := XRGrabInteractable.throw_consensus(ramp, 2, 0.35, 1.0)
	if full.x <= leaned.x:
		failures.append("bias 1.0 must reach further than 0.6")

	# It must never exceed the fastest CLEAN sample -- the corrupted newest
	# frames stay excluded no matter how hard the bias is turned up.
	var clean_peak := ramp[ramp.size() - 3].x
	if full.x > clean_peak + 0.001:
		failures.append("peak bias must not reach past the dead-zone into the release frames: %.3f > %.3f" % [full.x, clean_peak])

	# It must not RESURRECT a sample consensus already rejected. A mid-buffer
	# tracking glitch survives the dead-zone (it is not among the newest
	# frames) but loses consensus -- if the peak search ran over the whole
	# post-dead-zone buffer instead of the winning cluster, that glitch would
	# come back as the "peak" and fling the object.
	var glitched: Array[Vector3] = []
	for i in range(6):
		glitched.append(Vector3(2.0, 0, 0))
	glitched.insert(2, Vector3(40.0, 0, 0))
	glitched.append(Vector3(2.0, 0, 0))
	glitched.append(Vector3(2.0, 0, 0))
	var guarded := XRGrabInteractable.throw_consensus(glitched, 2, 0.35, 1.0)
	if guarded.x > 2.5:
		failures.append("peak bias must search only the winning cluster, not resurrect a rejected glitch: %.3f" % guarded.x)

	# It must not redirect a throw: the peak belongs to the same cluster, so
	# direction is preserved.
	var angled: Array[Vector3] = []
	for i in range(8):
		angled.append(Vector3(1.0 + 0.2 * float(i), 1.0 + 0.2 * float(i), 0))
	var biased := XRGrabInteractable.throw_consensus(angled, 2, 0.35, 1.0)
	if absf(biased.normalized().angle_to(Vector3(1, 1, 0).normalized())) > 0.01:
		failures.append("peak bias must not change throw DIRECTION, got %s" % biased)

	# Zero bias is exactly the previous behaviour.
	if not XRGrabInteractable.throw_consensus(ramp, 2, 0.35, 0.0).is_equal_approx(XRGrabInteractable.throw_consensus(ramp, 2, 0.35)):
		failures.append("default peak_bias must be 0 so existing callers are unchanged")

class UseStub:
	extends Node
	var hand := 0
	func get_attach_pose() -> Transform3D:
		return Transform3D.IDENTITY

## The analog USE axis: additive to grabbing and to the binary activate pair.
func _test_use_axis(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var seen: Array[float] = []
	grab.use_changed.connect(func(v: float) -> void: seen.append(v))
	var left := UseStub.new()
	left.hand = 0
	var right := UseStub.new()
	right.hand = 1
	grab._grabbers = [left, right]

	# Clamping.
	grab.set_use_value(2.5, 0)
	if not is_equal_approx(grab.use_value, 1.0):
		failures.append("use_value must clamp above 1, got %f" % grab.use_value)
	grab.set_use_value(-3.0, 0)
	if not is_equal_approx(grab.use_value, 0.0):
		failures.append("use_value must clamp below 0, got %f" % grab.use_value)

	# use_changed fires on a real change and NOT on a repeat. A prop driving a
	# per-frame signal would rebuild its effect every frame at a steady pull --
	# and a steady-value fixture could never see that, so drive both.
	seen.clear()
	grab.set_use_value(0.5, 0)
	grab.set_use_value(0.5, 0)
	grab.set_use_value(0.5, 0)
	if seen.size() != 1:
		failures.append("use_changed must fire once for a change held steady, fired %d times" % seen.size())
	grab.set_use_value(0.75, 0)
	if seen.size() != 2:
		failures.append("use_changed must fire again when the value actually moves")

	# Two-hand rule: the FIRST grabber owns the axis; the second cannot fight it.
	grab.set_use_value(0.2, 1)
	if not is_equal_approx(grab.use_value, 0.75):
		failures.append("a non-primary hand must not drive the axis, value moved to %f" % grab.use_value)

	# Handoff: the primary leaves, the remaining hand takes over.
	grab._grabbers = [right]
	grab.set_use_value(0.3, 1)
	if not is_equal_approx(grab.use_value, 0.3):
		failures.append("after a handoff the remaining hand must drive the axis, got %f" % grab.use_value)

	left.free()
	right.free()
	grab.free()

	# The RELEASE path itself must zero the axis -- asserting a manual
	# set_use_value(0.0) proves nothing about what happens when the object is
	# actually let go, which is when a prop would latch a stale pull.
	var released_grab := XRGrabInteractable.new()
	get_root().add_child(released_grab)
	var holder := UseStub.new()
	holder.hand = 0
	get_root().add_child(holder)
	released_grab._notify_select_entered(holder)
	released_grab.set_use_value(0.9, 0)
	if not is_equal_approx(released_grab.use_value, 0.9):
		failures.append("the primary grabber must be able to drive the axis while held")
	released_grab._notify_select_exited(holder)
	if not is_equal_approx(released_grab.use_value, 0.0):
		failures.append("releasing must zero the use axis, left at %f -- a prop would latch a stale pull" % released_grab.use_value)
	released_grab.free()
	holder.free()

const HandActivator := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_hand_activator.gd")

## The activator is what actually drives the axis on device, so this drives its
## REAL code path -- _poll_finger, its own curl, its own baseline -- rather
## than calling set_use_value on its behalf. Simulating the publish inside the
## test left the publish call free to be deleted with the suite still green,
## which is the same mistake the arbiter's first flicker test made.
func _test_activator_publishes_use_value(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	get_root().add_child(grab)
	var activator := HandActivator.new()
	activator.require_held = false  # no live interactor in a headless run
	grab.add_child(activator)
	var holder := UseStub.new()
	holder.hand = 0
	get_root().add_child(holder)
	grab._grabbers = [holder]

	if activator._find_interactable() != grab:
		failures.append("the activator must resolve the interactable it is parented to")
	# _ready() normally assigns this; it has not run for a node added mid-test.
	activator._interactable = grab

	# Read RAW: the activator normally reads the conditioned shadow, which the
	# publisher refreshes at most once per PROCESS frame -- so in a headless
	# loop it would never see the bend this test applies between polls. What is
	# under test is the activator's publish, not the conditioning chain.
	var was_conditioned := XRHandTrackerResolver.is_conditioned()
	XRHandTrackerResolver.set_conditioned(false)

	var tracker := _index_finger_tracker(0.0)
	# Frame 1: a straight finger establishes the relaxed baseline.
	XRHandTrackerResolver._cache_frame = -1
	activator._poll_finger(0)
	# Frames 2+: the same finger, now curled -- pull is measured against that
	# rest, and the activator smooths toward the new curl rather than jumping,
	# so a single frame would under-read it.
	_bend_index(tracker, 0.6)
	for frame in range(4):
		XRHandTrackerResolver._cache_frame = -1
		activator._poll_finger(0)

	if grab.use_value <= 0.0:
		failures.append("a real curl through _poll_finger must publish a non-zero use axis, got %f" % grab.use_value)

	XRHandTrackerResolver.set_conditioned(was_conditioned)
	XRServer.remove_tracker(tracker)
	grab.free()
	holder.free()

## A hand whose INDEX finger joints form a real chain, so _finger_curl's
## bone-angle sum is meaningful rather than degenerate.
func _index_finger_tracker(bend: float) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.name = "/user/hand_tracker/left"
	tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT
	tracker.has_tracking_data = true
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		tracker.set_hand_joint_transform(joint, Transform3D(Basis.IDENTITY, Vector3(0.05, 1.0, -0.2)))
		tracker.set_hand_joint_flags(joint, valid)
	XRServer.add_tracker(tracker)
	_bend_index(tracker, bend)
	return tracker

## Lays the index chain out with a controllable bend: 0 is straight, higher
## values fold each successive bone further, which is what a pull looks like.
func _bend_index(tracker: XRHandTracker, bend: float) -> void:
	var chain := [
		XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
	]
	# Away from the world origin: joint_position_valid treats a joint sitting on
	# the origin as STALE and rejects it, which made the whole curl read -1.
	var position := Vector3(0.05, 1.0, -0.2)
	var direction := Vector3(0.0, 0.0, -1.0)
	for i in range(chain.size()):
		tracker.set_hand_joint_transform(chain[i], Transform3D(Basis.IDENTITY, position))
		position += direction * 0.03
		direction = direction.rotated(Vector3.RIGHT, bend).normalized()

## A stub that models a REAL interactor closely enough to prove the swap
## releases it properly: it tracks its own _selected, the way the base
## interactor does, so a swap that only tells the interactable would leave this
## stub wedged -- which is what wedges a real ray.
class SwapStub:
	extends Node
	var hand := 0
	# can_hover masks the interactable's layers against the interactor's, so a
	# stub without this is refused before the swap logic is ever reached.
	var interaction_layers := 1
	var _selected: Node = null
	func get_attach_pose() -> Transform3D:
		return Transform3D.IDENTITY
	func _release_select() -> void:
		var released = _selected
		_selected = null
		if released != null and is_instance_valid(released):
			released._notify_select_exited(self)

func _test_grab_swaps_between_hands(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	get_root().add_child(grab)
	grab.allow_grab_swap = true
	grab.two_hand_grab_enabled = false

	var left := SwapStub.new()
	left.hand = 0
	get_root().add_child(left)
	var right := SwapStub.new()
	right.hand = 1
	get_root().add_child(right)

	left._selected = grab
	grab._notify_select_entered(left)
	if grab._grabbers.size() != 1 or grab._grabbers[0] != left:
		failures.append("the first hand must hold the object")

	# The other hand takes it: exactly one holder, and it is the new one.
	right._selected = grab
	if not grab.can_select(right):
		failures.append("a held object must accept the other hand when swapping is allowed")
	grab._notify_select_entered(right)
	if grab._grabbers.size() != 1:
		failures.append("after a swap exactly one hand may hold it, got %d" % grab._grabbers.size())
	elif grab._grabbers[0] != right:
		failures.append("after a swap the NEW hand must hold it")

	# ...and the old hand must not still believe it holds the object, or it
	# stays wedged and can never hover or select anything again.
	if left._selected != null:
		failures.append("the previous holder must be released through its own interactor, not just dropped from the list")

	# With swapping off, the second hand is refused and the first keeps it.
	var kept := XRGrabInteractable.new()
	get_root().add_child(kept)
	kept.allow_grab_swap = false
	kept.two_hand_grab_enabled = false
	var holder := SwapStub.new()
	get_root().add_child(holder)
	holder._selected = kept
	kept._notify_select_entered(holder)
	var thief := SwapStub.new()
	thief.hand = 1
	get_root().add_child(thief)
	if kept.can_select(thief):
		failures.append("with swapping off a held object must refuse the other hand")
	# ...and the swap must not happen even if the entry point is reached anyway:
	# asserting only can_select leaves the second guard free to be deleted.
	kept._notify_select_entered(thief)
	if holder._selected == null:
		failures.append("with swapping off the original holder must not be released")

	grab.free(); left.free(); right.free()
	kept.free(); holder.free(); thief.free()

const HandAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")
const RayInteractor := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd")

## The stabilization anchor must cover the PINCH TRANSIENT and then let go.
## Holding it for the whole grab freezes the aim direction, so a far-held object
## cannot be steered -- David on device: "their movement is more rigid, i cant
## manuever things like i was doing before".
func _test_stabilization_is_bounded(failures: Array[String]) -> void:
	var adapter := HandAdapter.new()
	get_root().add_child(adapter)
	adapter.stabilize_hand_select = true
	adapter.stabilize_hand_select_sec = 0.18

	var anchored := {"origin": Vector3(0, 1.4, 0), "direction": Vector3(0, 0, -1), "basis": Basis.IDENTITY}
	var live := {"origin": Vector3(0, 1.4, 0), "direction": Vector3(0.5, -0.4, -1).normalized(), "basis": Basis.IDENTITY}
	adapter._select_down[0] = true
	adapter._select_anchor_pose[0] = anchored.duplicate()
	adapter._select_anchor_hand_anchor[0] = null

	# Inside the window: the anchored aim is what the ray gets.
	adapter._select_held_time[0] = 0.05
	var during: Dictionary = adapter._stabilized_hand_pose(0, live)
	if not (during.get("direction", Vector3.ZERO) as Vector3).is_equal_approx(anchored["direction"]):
		failures.append("inside the window the anchored aim must be used, got %s" % during.get("direction"))

	# Past it: live again, so the object can be steered.
	adapter._select_held_time[0] = 0.40
	var after: Dictionary = adapter._stabilized_hand_pose(0, live)
	if not (after.get("direction", Vector3.ZERO) as Vector3).is_equal_approx(live["direction"]):
		failures.append("past the window the ray must track live so a held object can be manoeuvred, got %s" % after.get("direction"))

	# 0 keeps the old unbounded behaviour for anyone who wants it.
	adapter.stabilize_hand_select_sec = 0.0
	adapter._select_held_time[0] = 10.0
	var unbounded: Dictionary = adapter._stabilized_hand_pose(0, live)
	if not (unbounded.get("direction", Vector3.ZERO) as Vector3).is_equal_approx(anchored["direction"]):
		failures.append("0 must mean no bound, keeping the anchor for the whole hold")

	adapter.free()

## An adapter whose select state we control, to model the input having let go
## while the interactor still believes it holds something.
class WedgeAdapter:
	extends Node
	signal select_started(hand: int)
	signal select_ended(hand: int)
	var down := false
	func is_select_down(_hand: int) -> bool:
		return down
	func get_aim_pose(_hand: int) -> Dictionary:
		return {"origin": Vector3(0, 1.4, 0), "direction": Vector3(0, 0, -1), "basis": Basis.IDENTITY}
	func get_grip_pose(_hand: int) -> Dictionary:
		return {}
	func get_source_kind(_hand: int) -> int:
		return 0

## The ray must not stay wedged holding something the input already released.
## While _selected is set the ray skips hovering entirely, so a stale selection
## makes it go completely deaf -- no hover, no select -- until some unrelated
## release clears it. Reported on device as the right ray needing "random
## pinching gestures" before it would work again.
func _test_ray_recovers_from_wedged_selection(failures: Array[String]) -> void:
	var host := Node3D.new()
	get_root().add_child(host)
	var ray := RayInteractor.new()
	host.add_child(ray)
	var adapter := WedgeAdapter.new()
	host.add_child(adapter)
	ray._adapter = adapter

	# A selection the input still backs must be left alone.
	var held := XRGrabInteractable.new()
	host.add_child(held)
	ray._selected = held
	adapter.down = true
	ray._update_ray(1.0 / 72.0)
	if ray._selected == null:
		failures.append("a selection the input still backs must NOT be torn down")

	# The input lets go: the stale selection must be reconciled away.
	adapter.down = false
	ray._update_ray(1.0 / 72.0)
	if ray._selected != null:
		failures.append("a selection the input no longer backs must be released, or the ray goes deaf")

	host.free()

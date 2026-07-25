extends SceneTree

## Headless tests for grab feel (docs/grab-feel-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd

const XRControllerHandAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")
const XRSimulator := preload("res://addons/godot_webxr_kit/runtime/xr_simulator.gd")

var _failures: Array[String] = []

func _init() -> void:
	_test_grip_anchor_prefers_palm(_failures)
	_test_grab_point_bind_palm_uses_metacarpal_center(_failures)
	_test_simulator_palm_uses_metacarpal_center(_failures)
	_test_throw_consensus(_failures)
	# _test_grip_pose_stays_on_palm_with_full_hand needs a live Node3D.global_transform,
	# which asserts "!is_inside_tree()" if read this early: a node added to
	# get_root() during _init() is not yet inside the tree (confirmed empirically -
	# tree membership only propagates by the first _process). Deferred there.

func _process(_delta: float) -> bool:
	_test_grip_pose_stays_on_palm_with_full_hand(_failures)
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

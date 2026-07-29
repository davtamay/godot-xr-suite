class_name XRConditionedHandPublisher
extends RefCounted

## Publishes conditioned hand data as a shadow XRHandTracker per hand.
##
## Consumers that speak XRHandTracker keep their exact type and API and simply
## receive better data. The pattern is already proven in this codebase by
## xr_simulator.gd, which constructs and populates XRHandTracker instances.
##
## The chain runs lazily on first access per rendered frame. That is correct
## rather than merely convenient: XRServer updates trackers pre-render, so hand
## data genuinely does not change between physics ticks inside one render
## frame. It also means staleness is structurally impossible -- access is what
## triggers the run -- and it needs no autoload, node, or scene setup.

const TRACKER_NAMES := [
	&"/user/hand_tracker/left_conditioned",
	&"/user/hand_tracker/right_conditioned",
]
const _RAW_NAMES := [
	&"/user/hand_tracker/left",
	&"/user/hand_tracker/right",
]
const _HANDS := 2

static var _enabled := true
static var _trackers := [null, null]
static var _frames := [null, null]
static var _gate: XRHandConfidenceGate = null
static var _filter: XRHandFilter = null
static var _published_frame := [-1, -1]
static var _last_tracked := [false, false]

static func set_enabled(value: bool) -> void:
	_enabled = value

static func is_enabled() -> bool:
	return _enabled

static func filter() -> XRHandFilter:
	_ensure_chain()
	return _filter

## Drops the per-frame memo and the filter's history so the next access re-runs
## the chain and SEEDS rather than blending. The A/B toggle needs this: while
## conditioning is off nothing drives the filter, so _last_timestamp and the
## dedup wrist age by the whole length of the off-leg. Without the reset the
## first frame back computes dt against that stale stamp, and the dedup
## shortcut can replay a seconds-old output frame.
static func reset_chain() -> void:
	_ensure_chain()
	for hand in range(_HANDS):
		_published_frame[hand] = -1
		_last_tracked[hand] = false
		_filter.reset(hand)
		# Invalidate any registered shadow as well: it holds the last published
		# joints, and a stale shadow that still claims tracking data would leak
		# conditioned output into the raw A/B leg for anything reading it.
		if _trackers[hand] != null:
			_scrub_tracker(_trackers[hand])

## Runs the chain like get_conditioned, but returns the shadow even when the
## hand is untracked -- it then carries has_tracking_data = false and no valid
## joint flags, so consumers observe a clean dropout instead of whatever the
## raw tracker holds. Null only when disabled or the hand id is invalid.
## David's decision, 2026-07-24 (Task 9 review, Important #2): on gate
## rejection consumers see the untracked shadow, keeping the tracking-loss
## policy in the gate instead of leaking raw garbage through the resolver's
## fallback.
static func get_shadow(hand: int) -> XRHandTracker:
	if not _enabled or hand < 0 or hand >= _HANDS:
		return null
	if _should_republish(hand, Engine.get_process_frames()):
		publish(hand)
	return _trackers[hand]

## Runs the chain at most once per rendered frame per hand and returns the
## shadow tracker, or null when nothing is being tracked.
static func get_conditioned(hand: int) -> XRHandTracker:
	if not _enabled or hand < 0 or hand >= _HANDS:
		return null
	var frame_number := Engine.get_process_frames()
	if not _should_republish(hand, frame_number):
		return _trackers[hand] if _last_tracked[hand] else null
	return publish(hand)

## Frame-keyed memoization decision, pulled out of get_conditioned so it can
## be unit-tested without XRServer. True (and records `frame_number` as seen)
## the first time this frame number is asked about for `hand`; false on every
## later call with the same frame number. This is the guarantee that makes
## staleness structurally impossible -- access is what triggers a run -- and
## that stops a second consumer in the same render frame from re-driving the
## One Euro filter and corrupting its derivative estimate.
static func _should_republish(hand: int, frame_number: int) -> bool:
	if _published_frame[hand] == frame_number:
		return false
	_published_frame[hand] = frame_number
	return true

static func publish(hand: int) -> XRHandTracker:
	_ensure_chain()
	if _frames[hand] == null:
		_frames[hand] = XRHandFrame.new()
	var frame: XRHandFrame = _frames[hand]

	# Feeds the gate's FOV liveness test. Resolved every publish (not cached)
	# for the same reason nothing else here is cached: the rig can appear,
	# disappear, or move between frames, and the gate must never keep judging
	# against a stale head pose. Hand-independent, so this re-resolves for the
	# second hand's publish call in the same frame too -- redundant, not wrong,
	# and cheap next to a scene tree find_children scan happening at most twice
	# a frame.
	_update_head_pose()

	# The modality manager is the authority on controller-driven hands;
	# tracker.hand_tracking_source is not reliable across runtimes. Resolve it
	# softly by group so the toolkit gains no dependency on godot_webxr_kit.
	_filter.set_controller_source(hand, _is_controller_modality(hand))

	# One call drives the whole chain: the filter pulls from the gate, which
	# pulls from the raw tracker source. The filter consumes the gate's
	# discontinuity internally, so the reset lands before the frame is
	# conditioned rather than after.
	var tracked := _filter.capture(hand, Time.get_ticks_usec(), frame)
	if not tracked:
		# A failed capture returns without writing the frame, and the frame is
		# reused across publishes -- so it still holds the last tracked pose,
		# tracking_valid and all. Mark it invalid or write_frame_to_tracker
		# republishes the stale pose as live. Latent since Task 8: the shadow
		# claimed tracking data throughout every dropout, unobservable only
		# because nothing consumed the shadow on the untracked path until now.
		frame.tracking_valid = false

	var tracker := _ensure_tracker(hand)
	write_frame_to_tracker(frame, tracker, _raw_source(hand))
	_probe(hand, tracked)
	_last_tracked[hand] = tracked
	return tracker if tracked else null


## DIAGNOSTIC, temporary. Logs what the runtime ACTUALLY reports as a hand
## leaves view, from inside the chain every consumer already goes through --
## so it runs in every scene with no node or setup, unlike a probe placed in
## one sample scene, which is how the first attempt at this measured nothing.
##
## ANSWERED, which is why this now ships OFF. The question was whether the
## runtime CLEARS HAND_JOINT_FLAG_POSITION_TRACKED when a hand leaves view, or
## keeps reporting tracked-and-valid while extrapolating. Measured on Quest over
## Link: it does the latter. POSITION_VALID reads 26 permanently and carries no
## information at all; only POSITION_TRACKED varies, swinging 26 <-> 2, while
## the wrist travelled 34cm/24cm across six frames with every flag healthy.
## Those numbers are what the FOV cone and min_tracked_joints were built from.
##
## Kept rather than deleted because the same measurement is still owed on
## Android XR / Galaxy XR, where the skeleton and the flag behaviour may differ
## again. Switch it on for that pass and read the per-hand lines.
##
## Change-gated: an unconditional per-frame print produced 91,530 lines in one
## Link session on this project.
static var debug_tracking := false
static var _probe_last := [{}, {}]

static func _probe(hand: int, gate_says_tracked: bool) -> void:
	if not debug_tracking:
		return
	var raw: XRHandTracker = XRHandTrackerResolver.resolve_raw(hand)
	var valid := 0
	var tracked_joints := 0
	var has_data := false
	if raw != null:
		has_data = raw.has_tracking_data
		for joint in XRHandTracker.HAND_JOINT_MAX:
			var flags := raw.get_hand_joint_flags(joint)
			if (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0:
				valid += 1
			if (flags & XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED) != 0:
				tracked_joints += 1

	var state := {
		"present": raw != null, "data": has_data,
		"valid": valid, "tracked": tracked_joints, "gate": gate_says_tracked,
	}
	# Also report when the WRIST MOVES far while the flags say nothing changed:
	# that is the signature of a hand being extrapolated, and it is invisible to
	# a flags-only change gate.
	var wrist_now := Vector3.ZERO
	if raw != null:
		wrist_now = raw.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
	state["wrist"] = wrist_now
	# The head-to-wrist angle the FOV gate itself measures against, read
	# through the SAME method the gate's own liveness decision uses
	# (head_to_wrist_angle_deg) -- not a separate re-derivation of the
	# geometry -- so this probe can never disagree with what actually gated
	# the hand. INF when the gate has no head pose (no rig resolved).
	var angle_deg := _gate.head_to_wrist_angle_deg(wrist_now) if _gate != null else INF
	state["angle_deg"] = angle_deg
	var previous: Dictionary = _probe_last[hand]
	if not previous.is_empty() \
			and previous["present"] == state["present"] \
			and previous["data"] == state["data"] \
			and previous["gate"] == state["gate"] \
			and absi(int(previous["valid"]) - valid) < 3 \
			and absi(int(previous["tracked"]) - tracked_joints) < 3 \
			and (previous.get("wrist", Vector3.ZERO) as Vector3).distance_to(wrist_now) < 0.05:
		return
	_probe_last[hand] = state
	# The wrist POSITION matters as much as the flags now. If a hand the user
	# cannot see still reports tracked=26 while its wrist wanders, then
	# POSITION_TRACKED is not an "observed" signal on this runtime at all and
	# no threshold on it can work -- the gate would need a motion-plausibility
	# test instead. Printing the position is what tells those two apart. The
	# angle is what tells the next device session whether the FOV cone is
	# actually firing when the wrist wanders like this: it should cross
	# fov_half_angle_deg right around when the drift starts.
	var wrist := Vector3.INF
	if raw != null:
		wrist = raw.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
	print("[hand-probe] hand=%d has_data=%s valid=%d tracked=%d gate=%s wrist=(%.3f, %.3f, %.3f) angle_deg=%.1f" % [
		hand, has_data, valid, tracked_joints, gate_says_tracked, wrist.x, wrist.y, wrist.z, angle_deg])

## Copies a conditioned frame into a tracker. Static and dependency-free so it
## can be unit-tested without touching XRServer.
static func write_frame_to_tracker(frame: XRHandFrame, tracker: XRHandTracker, source: int) -> void:
	tracker.hand_tracking_source = source
	if not frame.tracking_valid:
		_scrub_tracker(tracker)
		return
	for joint in range(XRHandFrame.JOINT_COUNT):
		tracker.set_hand_joint_transform(joint, frame.joint_transforms[joint])
		tracker.set_hand_joint_radius(joint, frame.joint_radii[joint])
		tracker.set_hand_joint_flags(joint, frame.joint_flags[joint])
	tracker.has_tracking_data = true

## An untracked shadow must carry NO usable data: has_tracking_data false AND
## every joint flag cleared. Several consumers (grip curl, pinch, hand rays)
## gate on joint_position_valid rather than has_tracking_data, and the joints
## left behind by the last tracked publish would still read as valid.
static func _scrub_tracker(tracker: XRHandTracker) -> void:
	for joint in range(XRHandFrame.JOINT_COUNT):
		tracker.set_hand_joint_flags(joint, 0)
	tracker.has_tracking_data = false

static func _ensure_chain() -> void:
	if _gate != null:
		return
	# raw tracker source -> confidence gate -> filter. Gate first: filtering a
	# dropout would interpolate smoothly into the garbage pose and back out.
	_gate = XRHandConfidenceGate.new(XRTrackerHandPoseSource.new())
	_filter = XRHandFilter.new(_gate)

static func _ensure_tracker(hand: int) -> XRHandTracker:
	if _trackers[hand] != null:
		return _trackers[hand]
	var tracker := XRHandTracker.new()
	tracker.name = TRACKER_NAMES[hand]
	tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == 0 else XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(tracker)
	_trackers[hand] = tracker
	return tracker

static func _raw_source(hand: int) -> int:
	var raw := XRServer.get_tracker(_RAW_NAMES[hand]) as XRHandTracker
	return raw.hand_tracking_source if raw else XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN

## Resolves the head pose in XROrigin3D space and hands it to the gate, or
## tells the gate no head pose is available. Never suppresses on its own --
## every early return below calls set_head_pose(false, ...), which is exactly
## what makes the FOV gate inert when no rig can be found (a missing rig must
## not blind every hand). XRRigResolver.find_origin/find_camera both expect a
## Node already in the tree to search from; a static publisher has none of its
## own, so the running SceneTree's current_scene stands in for it, matching
## how find_origin itself resolves a scoped search root (_own_scene_root) when
## given a node that owns no XROrigin3D ancestor.
static func _update_head_pose() -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.current_scene == null:
		_gate.set_head_pose(false, Transform3D.IDENTITY)
		return
	var scene := loop.current_scene
	var origin := XRRigResolver.find_origin(scene)
	var camera := XRRigResolver.find_camera(scene)
	if origin == null or camera == null:
		_gate.set_head_pose(false, Transform3D.IDENTITY)
		return
	_gate.set_head_pose(true, head_transform_in_origin_space(origin.global_transform, camera.global_transform))

## Pure conversion (plain Transform3D in, plain Transform3D out -- no node
## dependency) so it can be unit-tested with literal values instead of a live
## XR session or a constructed scene tree. Godot's Node3D.global_transform
## requires the node to be is_inside_tree(); a headless SceneTree test
## script's own `root` never reports true for that in this harness (confirmed
## empirically -- ERROR: Condition "!is_inside_tree()" is true even from
## inside SceneTree._initialize()), so testing this conversion through real
## XROrigin3D/XRCamera3D nodes is not possible here. Splitting the tree lookup
## (_update_head_pose, only exercised for real by the boot check) from this
## pure math is what makes the math itself provable at all.
##
## XRHandTracker.get_hand_joint_transform() (and therefore every XRHandFrame
## joint transform the gate compares against) is local to the XROrigin3D;
## XRCamera3D.global_transform is world. Comparing world against origin-local
## would make the FOV gate fire at whatever angle the origin itself happens to
## be rotated to in the world, not the angle between the camera and the hand
## -- this inverse is what cancels that out.
static func head_transform_in_origin_space(origin_world: Transform3D, camera_world: Transform3D) -> Transform3D:
	return origin_world.affine_inverse() * camera_world

static func _is_controller_modality(hand: int) -> bool:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return false
	var manager := loop.get_first_node_in_group("xr_input_modality_manager")
	if manager and manager.has_method("get_modality"):
		return int(manager.get_modality(hand)) == 1  # Modality.CONTROLLER
	return _raw_source(hand) == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER

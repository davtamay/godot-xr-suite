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

static func set_enabled(value: bool) -> void:
	_enabled = value

static func is_enabled() -> bool:
	return _enabled

static func filter() -> XRHandFilter:
	_ensure_chain()
	return _filter

## Runs the chain at most once per rendered frame per hand and returns the
## shadow tracker, or null when nothing is being tracked.
static func get_conditioned(hand: int) -> XRHandTracker:
	if not _enabled or hand < 0 or hand >= _HANDS:
		return null
	var frame_number := Engine.get_process_frames()
	if not _should_republish(hand, frame_number):
		return _trackers[hand]
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

	# The modality manager is the authority on controller-driven hands;
	# tracker.hand_tracking_source is not reliable across runtimes. Resolve it
	# softly by group so the toolkit gains no dependency on godot_webxr_kit.
	_filter.set_controller_source(hand, _is_controller_modality(hand))

	# One call drives the whole chain: the filter pulls from the gate, which
	# pulls from the raw tracker source. The filter consumes the gate's
	# discontinuity internally, so the reset lands before the frame is
	# conditioned rather than after.
	var tracked := _filter.capture(hand, Time.get_ticks_usec(), frame)

	var tracker := _ensure_tracker(hand)
	write_frame_to_tracker(frame, tracker, _raw_source(hand))
	return tracker if tracked else null

## Copies a conditioned frame into a tracker. Static and dependency-free so it
## can be unit-tested without touching XRServer.
static func write_frame_to_tracker(frame: XRHandFrame, tracker: XRHandTracker, source: int) -> void:
	tracker.hand_tracking_source = source
	if not frame.tracking_valid:
		tracker.has_tracking_data = false
		return
	for joint in range(XRHandFrame.JOINT_COUNT):
		tracker.set_hand_joint_transform(joint, frame.joint_transforms[joint])
		tracker.set_hand_joint_radius(joint, frame.joint_radii[joint])
		tracker.set_hand_joint_flags(joint, frame.joint_flags[joint])
	tracker.has_tracking_data = true

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
	tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == 0 else XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(tracker)
	_trackers[hand] = tracker
	return tracker

static func _raw_source(hand: int) -> int:
	var raw := XRServer.get_tracker(_RAW_NAMES[hand]) as XRHandTracker
	return raw.hand_tracking_source if raw else XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN

static func _is_controller_modality(hand: int) -> bool:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return false
	var manager := loop.get_first_node_in_group("xr_input_modality_manager")
	if manager and manager.has_method("get_modality"):
		return int(manager.get_modality(hand)) == 1  # Modality.CONTROLLER
	return _raw_source(hand) == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER

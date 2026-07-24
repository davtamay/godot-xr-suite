class_name XRHandTrackerResolver
extends RefCounted

## Resolves left/right XRHandTracker instances robustly across runtimes.
## Some WebXR/OpenXR runtimes expose the canonical hand tracker path before it
## has useful joints while another same-hand tracker entry is already updating.

const XRInputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")

const TRACKER_PATHS := {
    XRInputAdapter.Hand.LEFT: &"/user/hand_tracker/left",
    XRInputAdapter.Hand.RIGHT: &"/user/hand_tracker/right",
}

const POSITION_VALID_FLAG := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
const STALE_JOINT_EPSILON_SQUARED := 0.000001
const JOINTS_TO_SCORE := [
    XRHandTracker.HAND_JOINT_PALM,
    XRHandTracker.HAND_JOINT_WRIST,
    XRHandTracker.HAND_JOINT_THUMB_TIP,
    XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
    XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
    XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
]

# Frame-stamped cache: every consumer (adapter aim/grip/pinch, visualizers,
# gestures) resolves the same two trackers - without this the full
# get_trackers scan + string scoring ran 8-12x per frame. Within one frame
# the XR tracker set is constant (XRServer updates pre-render), so caching
# per frame is behavior-identical; a mid-frame hot-plug is picked up next
# frame by the same scoring.
static var _cache := {}
static var _cache_frame := -1

## Conditioning is on by default. Flip at runtime for A/B comparison.
static var _conditioned := true


static func set_conditioned(value: bool) -> void:
    if _conditioned == value:
        return
    _conditioned = value
    _cache_frame = -1  # drop the frame cache so the switch takes effect now
    # The chain only runs while conditioning is on, so across an A/B leg the
    # filter's timestamp and wrist history age by the length of that leg.
    # Seed fresh on the way back in rather than blending against them.
    XRConditionedHandPublisher.reset_chain()


static func is_conditioned() -> bool:
    return _conditioned


static func get_tracker(hand_id: int) -> XRHandTracker:
    if not _valid_hand(hand_id):
        return null

    var frame := Engine.get_process_frames()
    if _cache_frame != frame:
        _cache_frame = frame
        _cache.clear()
    if _cache.has(hand_id):
        return _cache[hand_id]

    var tracker: XRHandTracker = null
    if _conditioned:
        tracker = XRConditionedHandPublisher.get_conditioned(hand_id)
    if tracker == null:
        tracker = resolve_raw(hand_id)
    _cache[hand_id] = tracker
    return tracker


## The unconditioned tracker, scored and resolved. Used by the conditioning
## chain itself; everything else should call get_tracker.
static func resolve_raw(hand_id: int) -> XRHandTracker:
    # get_tracker used to gate this; now that callers reach it directly, the
    # guard has to live here or TRACKER_PATHS[hand_id] faults on a bad hand.
    if not _valid_hand(hand_id):
        return null

    var expected_hand := _expected_tracker_hand(hand_id)
    var side_text := _side_text(hand_id)
    var best_tracker := XRServer.get_tracker(TRACKER_PATHS[hand_id]) as XRHandTracker
    var best_score := _score_tracker(best_tracker, expected_hand, side_text, str(TRACKER_PATHS[hand_id]))

    var trackers := XRServer.get_trackers(XRServer.TRACKER_HAND)
    for tracker_name in trackers.keys():
        # Never score the conditioning layer's own shadow trackers. Their name
        # and hand match like any real tracker, and after a raw dropout they
        # still hold last frame's fully-valid joints -- so they would outrank
        # the degraded raw tracker, feed the filter its own previous output,
        # and hold the "valid" hand frozen past the gate's dropout window.
        if tracker_name in XRConditionedHandPublisher.TRACKER_NAMES:
            continue
        var tracker := trackers[tracker_name] as XRHandTracker
        var score := _score_tracker(tracker, expected_hand, side_text, str(tracker_name))
        if score > best_score:
            best_tracker = tracker
            best_score = score

    return best_tracker if best_score > 0 else null

static func valid_joint_count(tracker: XRHandTracker) -> int:
    if tracker == null:
        return 0

    var count := 0
    for joint in JOINTS_TO_SCORE:
        if joint_position_valid(tracker, joint):
            count += 1
    return count

static func joint_position_valid(tracker: XRHandTracker, joint: int) -> bool:
    if tracker == null:
        return false
    if (tracker.get_hand_joint_flags(joint) & POSITION_VALID_FLAG) == 0:
        return false

    var origin := tracker.get_hand_joint_transform(joint).origin
    return origin.is_finite() and origin.length_squared() > STALE_JOINT_EPSILON_SQUARED

static func tracker_debug_name(hand_id: int, tracker: XRHandTracker) -> String:
    if tracker == null:
        return "none"

    var canonical := str(TRACKER_PATHS[hand_id]) if _valid_hand(hand_id) else ""
    var trackers := XRServer.get_trackers(XRServer.TRACKER_HAND)
    for tracker_name in trackers.keys():
        if trackers[tracker_name] == tracker:
            return str(tracker_name)
    return canonical

static func _score_tracker(tracker: XRHandTracker, expected_hand: int, side_text: String, tracker_name: String) -> int:
    if tracker == null:
        return 0

    var hand_matches := tracker.hand == expected_hand
    var name_matches := tracker_name.to_lower().find(side_text) >= 0
    if not hand_matches and not name_matches:
        return 0

    var score := valid_joint_count(tracker) * 1000
    if tracker.has_tracking_data:
        score += 100
    if hand_matches:
        score += 20
    if name_matches:
        score += 10
    return score

static func _expected_tracker_hand(hand_id: int) -> int:
    return XRPositionalTracker.TRACKER_HAND_LEFT if hand_id == XRInputAdapter.Hand.LEFT else XRPositionalTracker.TRACKER_HAND_RIGHT

static func _side_text(hand_id: int) -> String:
    return "left" if hand_id == XRInputAdapter.Hand.LEFT else "right"

static func _valid_hand(hand_id: int) -> bool:
    return hand_id == XRInputAdapter.Hand.LEFT or hand_id == XRInputAdapter.Hand.RIGHT

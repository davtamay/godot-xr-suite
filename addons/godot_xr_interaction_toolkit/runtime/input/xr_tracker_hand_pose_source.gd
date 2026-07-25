class_name XRTrackerHandPoseSource
extends XRHandPoseSource

## Default engine-level acquisition. Godot's XRHandTracker is populated by
## both WebXR and OpenXR, keeping this source platform-neutral.
##
## Reads the RAW tracker by default, because the conditioning chain itself
## feeds from this source and would otherwise consume its own output. Consumers
## OUTSIDE that chain -- gesture recognition, for one -- want the conditioned
## hand instead, and set `conditioned = true` rather than there being a second
## near-identical class differing by a single line.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## false (default): the RAW tracker, for the conditioning chain that feeds
## from here. true: the conditioned result, for consumers outside the chain.
var conditioned := false

var _sequence := 0

func _init(use_conditioned := false) -> void:
    conditioned = use_conditioned

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
    _sequence += 1
    target.begin_capture(hand, timestamp_usec, _sequence)

    # resolve_raw when feeding the chain (get_tracker would make the filter
    # consume its own output); get_tracker when this is an ordinary consumer.
    var tracker: XRHandTracker = null
    if conditioned:
        tracker = XRHandTrackerResolver.get_tracker(hand)
    else:
        tracker = XRHandTrackerResolver.resolve_raw(hand)
    if tracker == null or not tracker.has_tracking_data:
        return false

    for joint in range(XRHandFrame.JOINT_COUNT):
        var flags := int(tracker.get_hand_joint_flags(joint))
        target.set_joint(
            joint,
            tracker.get_hand_joint_transform(joint),
            tracker.get_hand_joint_radius(joint),
            flags)

    target.tracking_valid = target.valid_joint_count > 0
    return target.tracking_valid

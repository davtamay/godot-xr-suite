class_name XRTrackerHandPoseSource
extends XRHandPoseSource

## Default engine-level acquisition. Godot's XRHandTracker is populated by
## both WebXR and OpenXR, keeping this source platform-neutral.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

var _sequence := 0

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
    _sequence += 1
    target.begin_capture(hand, timestamp_usec, _sequence)

    var tracker := XRHandTrackerResolver.get_tracker(hand)
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

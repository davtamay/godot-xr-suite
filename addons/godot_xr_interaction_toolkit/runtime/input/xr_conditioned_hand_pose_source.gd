class_name XRConditionedHandPoseSource
extends XRHandPoseSource

## Acquisition source that reads the CONDITIONED hand, for consumers that want
## filtered joints through the pose-source seam rather than through
## XRHandTracker directly -- the gesture runtime being the reason this exists.
##
## Deliberately the mirror image of XRTrackerHandPoseSource. That one calls
## resolve_raw because it FEEDS the conditioning chain and would otherwise
## consume its own output. This one is a CONSUMER, sits outside the chain, and
## so calls get_tracker like every other consumer -- no loop is possible.
##
## Falls back to whatever get_tracker returns when conditioning is off or the
## publisher is disabled, which is the raw tracker: this source degrades to
## XRTrackerHandPoseSource's behaviour rather than to nothing.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

var _sequence := 0

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
	_sequence += 1
	target.begin_capture(hand, timestamp_usec, _sequence)

	var tracker := XRHandTrackerResolver.get_tracker(hand)
	if tracker == null or not tracker.has_tracking_data:
		return false

	for joint in range(XRHandFrame.JOINT_COUNT):
		target.set_joint(
			joint,
			tracker.get_hand_joint_transform(joint),
			tracker.get_hand_joint_radius(joint),
			int(tracker.get_hand_joint_flags(joint)))

	target.tracking_valid = target.valid_joint_count > 0
	return target.tracking_valid

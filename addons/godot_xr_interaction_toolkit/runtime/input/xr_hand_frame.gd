class_name XRHandFrame
extends RefCounted

## One runtime-independent snapshot of a hand. Joint transforms are local to
## the XROrigin3D, matching XRHandTracker. Acquisition writes this object once;
## feature extractors and recognizers only read it.

const JOINT_COUNT := XRHandTracker.HAND_JOINT_MAX

var hand: int = -1
var timestamp_usec: int = 0
var sequence: int = 0
var tracking_valid := false
var valid_joint_count := 0
## Joints flagged POSITION_TRACKED (genuinely OBSERVED), a strict subset of
## valid_joint_count -- OpenXR also sets POSITION_VALID on a joint it is only
## PREDICTING, which valid_joint_count cannot tell apart from one actually
## seen. Mirrors XRHandTrackerResolver.joint_position_tracked, the per-joint
## primitive for the same distinction on a live XRHandTracker; this is the
## frame-shaped counterpart XRHandConfidenceGate reads its liveness decision
## from, since the gate only ever sees a captured XRHandFrame, not a tracker.
var tracked_joint_count := 0
var joint_transforms: Array[Transform3D] = []
var joint_radii := PackedFloat32Array()
var joint_flags := PackedInt32Array()

func _init() -> void:
    joint_transforms.resize(JOINT_COUNT)
    joint_radii.resize(JOINT_COUNT)
    joint_flags.resize(JOINT_COUNT)
    clear()

func clear() -> void:
    tracking_valid = false
    valid_joint_count = 0
    tracked_joint_count = 0
    for joint in range(JOINT_COUNT):
        joint_transforms[joint] = Transform3D.IDENTITY
        joint_radii[joint] = 0.0
        joint_flags[joint] = 0

func begin_capture(p_hand: int, p_timestamp_usec: int, p_sequence: int) -> void:
    clear()
    hand = p_hand
    timestamp_usec = p_timestamp_usec
    sequence = p_sequence

func set_joint(joint: int, transform: Transform3D, radius: float, flags: int) -> void:
    if joint < 0 or joint >= JOINT_COUNT:
        return
    joint_transforms[joint] = transform
    joint_radii[joint] = radius
    joint_flags[joint] = flags
    if has_joint(joint):
        valid_joint_count += 1
    if has_tracked_joint(joint):
        tracked_joint_count += 1

func has_joint(joint: int) -> bool:
    if joint < 0 or joint >= JOINT_COUNT:
        return false
    return (joint_flags[joint] & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) != 0

## True only when the runtime is genuinely OBSERVING this joint (POSITION_VALID
## AND POSITION_TRACKED), as against has_joint()'s POSITION_VALID alone, which
## OpenXR also sets on a joint it is merely PREDICTING.
func has_tracked_joint(joint: int) -> bool:
    if joint < 0 or joint >= JOINT_COUNT:
        return false
    if (joint_flags[joint] & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) == 0:
        return false
    return (joint_flags[joint] & XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED) != 0

func joint_position(joint: int) -> Vector3:
    return joint_transforms[joint].origin if has_joint(joint) else Vector3.ZERO

## Copies this frame's full contents into another frame.
func copy_into(target: XRHandFrame) -> void:
    target.begin_capture(hand, timestamp_usec, sequence)
    for joint in range(JOINT_COUNT):
        target.set_joint(joint, joint_transforms[joint], joint_radii[joint], joint_flags[joint])
    target.tracking_valid = tracking_valid

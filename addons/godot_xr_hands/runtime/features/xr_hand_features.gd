class_name XRHandFeatures
extends RefCounted

## Compact normalized measurements shared by every gesture recognizer.

enum Finger { THUMB, INDEX, MIDDLE, RING, PINKY }
enum Feature {
    TRACKING_QUALITY,
    PINCH_DISTANCE,
    THUMB_CURL,
    INDEX_CURL,
    MIDDLE_CURL,
    RING_CURL,
    PINKY_CURL,
    PALM_SPEED,
}

var hand: int = -1
var timestamp_usec: int = 0
var valid := false
var tracking_quality := 0.0
## True on exactly the frame the pose source reports a tracking discontinuity
## (first acquisition, or recovery from a dropout / FOV freeze). The pose on
## such a frame is real but NOT continuous with the previous frame's, so any
## recognizer accumulating motion across frames must treat it as a restart,
## never as movement -- a reacquisition jump read as motion is a phantom
## gesture. Stamped by XRGestureRuntime from the pose source's one-shot;
## sources with no notion of continuity leave it false forever.
var discontinuity := false
var palm_transform := Transform3D.IDENTITY
var palm_width := 0.0
var pinch_distance := 1.0
var thumb_index_side_distance := 1.0
var thumb_index_contact_position := 0.5
var palm_linear_velocity := Vector3.ZERO
var thumb_tip_local := Vector3.ZERO
var index_tip_local := Vector3.ZERO
var thumb_direction_local := Vector3.ZERO
var thumb_direction_origin := Vector3.ZERO
var finger_curls := PackedFloat32Array()

func _init() -> void:
    finger_curls.resize(Finger.size())
    reset()

func reset() -> void:
    valid = false
    tracking_quality = 0.0
    discontinuity = false
    palm_transform = Transform3D.IDENTITY
    palm_width = 0.0
    pinch_distance = 1.0
    thumb_index_side_distance = 1.0
    thumb_index_contact_position = 0.5
    palm_linear_velocity = Vector3.ZERO
    thumb_tip_local = Vector3.ZERO
    index_tip_local = Vector3.ZERO
    thumb_direction_local = Vector3.ZERO
    thumb_direction_origin = Vector3.ZERO
    finger_curls.fill(0.0)

func get_feature(feature: int) -> float:
    match feature:
        Feature.TRACKING_QUALITY:
            return tracking_quality
        Feature.PINCH_DISTANCE:
            return pinch_distance
        Feature.THUMB_CURL:
            return finger_curls[Finger.THUMB]
        Feature.INDEX_CURL:
            return finger_curls[Finger.INDEX]
        Feature.MIDDLE_CURL:
            return finger_curls[Finger.MIDDLE]
        Feature.RING_CURL:
            return finger_curls[Finger.RING]
        Feature.PINKY_CURL:
            return finger_curls[Finger.PINKY]
        Feature.PALM_SPEED:
            return palm_linear_velocity.length()
    return 0.0

func to_palm_local(position: Vector3) -> Vector3:
    return palm_transform.affine_inverse() * position

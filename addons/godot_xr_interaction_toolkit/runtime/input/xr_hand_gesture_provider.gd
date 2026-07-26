class_name XRHandGestureProvider
extends RefCounted

## XRHandTracker geometry helpers. Returned transforms are XROrigin3D-local,
## matching XRHandTracker joint data; callers convert to global space.
## Hand ray, Meta/Unity-style: the ORIGIN sits at the pinch point (between the
## index + thumb tips) so the ray emerges from your fingers, but the DIRECTION is
## STABLE (index knuckle -> wrist), so pinching does not swing the aim. Only the
## origin tracks the fingers; for a far target the direction dominates, so it holds.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

const RAY_ORIGIN_FORWARD_OFFSET := 0.025
## Downward pitch applied to the stable aim so the ray points where you point,
## not up at the knuckles (Meta/Unity apply a similar tilt). Tune to taste.
const HAND_RAY_PITCH_DOWN_DEGREES := 35.0

static func joint_position_valid(tracker: XRHandTracker, joint: int) -> bool:
    return XRHandTrackerResolver.joint_position_valid(tracker, joint)

static func get_hand_ray_pose(tracker: XRHandTracker) -> Dictionary:
    if tracker == null:
        return {}

    # STABLE aim: the index knuckle (proximal) and wrist hold still when you pinch,
    # so the ray does not swing. But knuckles sit ABOVE the wrist, so wrist->knuckle
    # aims high - pitch it DOWN so it points where you point (Meta/Unity do the same).
    var wrist := XRHandTracker.HAND_JOINT_WRIST
    var palm := XRHandTracker.HAND_JOINT_PALM
    var knuckle := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL
    if not joint_position_valid(tracker, knuckle):
        knuckle = XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL
    if not joint_position_valid(tracker, knuckle):
        return {}
    var back := wrist
    if not joint_position_valid(tracker, back):
        back = palm
    if not joint_position_valid(tracker, back):
        return {}

    var knuckle_pos := tracker.get_hand_joint_transform(knuckle).origin
    var fwd := knuckle_pos - tracker.get_hand_joint_transform(back).origin
    if fwd.length_squared() < 0.000001:
        return {}
    fwd = fwd.normalized()

    # Pitch axis = across the knuckles (index -> pinky); it mirrors between hands,
    # so flip the tilt sign by the tracker's handedness.
    # ANATOMICAL first, and through several joints, because the fallback below
    # is not equivalent. The pinky is the least reliably tracked knuckle on the
    # hand, so keying only on it dropped to the world-derived axis often --
    # exactly when the hand is edge-on or leaving view. Any of these knuckles
    # gives a correctly-mirroring axis; the ring and middle ones survive
    # partial tracking that loses the pinky.
    var across := Vector3.ZERO
    for candidate in [
            XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
            XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
            XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
            XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
    ]:
        if joint_position_valid(tracker, candidate):
            var axis := tracker.get_hand_joint_transform(candidate).origin - knuckle_pos
            if axis.length_squared() >= 0.000001:
                across = axis
                break

    if across.length_squared() < 0.000001:
        # LAST RESORT, and it must be mirrored by hand. fwd.cross(UP) has fixed
        # chirality, so it does NOT flip between hands the way the anatomical
        # axis above does -- but the pitch sign below flips regardless. Left
        # and right therefore tilted in OPPOSITE directions whenever this
        # branch was taken, which is precisely when a hand is leaving camera
        # view and its outer knuckles stop being reported. Negating here
        # restores the mirroring the pitch flip is written to expect, so both
        # hands behave identically in the fallback as they do in the normal
        # path. Reported on device as one hand feeling less stable than the
        # other while out of view.
        across = fwd.cross(Vector3.UP)
        if tracker.hand == XRPositionalTracker.TRACKER_HAND_RIGHT:
            across = -across
    across = across.normalized()
    var pitch := deg_to_rad(HAND_RAY_PITCH_DOWN_DEGREES)
    if tracker.hand == XRPositionalTracker.TRACKER_HAND_RIGHT:
        pitch = -pitch
    var direction := fwd.rotated(across, pitch).normalized()

    # ORIGIN at a STABLE anchor (the index knuckle, else palm) - NOT the
    # fingertips. The old fingertip/pinch-midpoint origin swung the whole ray
    # as fingers curled or pinched (David saw the line offset per pose); Meta/
    # Unity anchor the pointer near the knuckle so posing does not move it. A
    # small forward offset lifts it clear of the hand.
    var origin_point := knuckle_pos
    if joint_position_valid(tracker, palm):
        origin_point = (knuckle_pos + tracker.get_hand_joint_transform(palm).origin) * 0.5

    return {
        "origin": origin_point + direction * RAY_ORIGIN_FORWARD_OFFSET,
        "direction": direction,
    }

static func basis_from_forward(direction: Vector3) -> Basis:
    var forward := direction.normalized()
    if forward.length_squared() < 0.000001:
        return Basis.IDENTITY

    var up := Vector3.UP
    if absf(forward.dot(up)) > 0.95:
        up = Vector3.FORWARD

    return Basis.looking_at(forward, up)

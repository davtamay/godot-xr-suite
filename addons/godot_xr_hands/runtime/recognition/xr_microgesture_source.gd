class_name XRMicrogestureSource
extends Node

## Canonical, runtime-independent microgesture event contract.
##
## Providers may classify gestures from normalized joints, native runtime
## events, recordings, simulation, or another input backend. Consumers see
## the same wearer-relative vocabulary and never depend on that provider.

enum Gesture { LEFT, RIGHT, FORWARD, BACKWARD, TAP }

## Why a gesture attempt produced nothing. Meta's interaction model (technique
## from the ISDK sweep, no code): invalid commits get EXPLICIT rejection
## feedback, never silence -- a fumbled gesture the system saw but discarded
## must tell the user so, or reliability problems read as mystery.
## SWIPE_TOO_SHORT is the dead band: travel past the tap ceiling but short of
## the swipe floor. TAP_TOO_QUICK: contact released before a tap's minimum
## duration. TOO_SLOW: contact outlived maximum_duration. POSTURE_LOST: the
## hand left gesture posture mid-track. LOW_QUALITY: tracking stayed below the
## quality floor past the grace window. DISCONTINUITY: a tracking
## reacquisition landed mid-gesture, so the accumulated motion is
## unattributable.
## OUT_OF_START_ZONE closes tier 2's own blind spot, found on device: a
## contact with good posture whose START position sits outside the arming
## zone never arms, and produced NO event at all -- the user's "swiping left
## is not very reliable" while the counters showed 19 LEFT successes and 2
## rejections was exactly this, invisible. Emitted once per contact episode,
## not per frame.
## CONTACT_TOO_LIGHT and POSTURE_NOT_READY close the last silent arming
## gates, found the same way OUT_OF_START_ZONE was: on-device feel
## contradicting clean counters. Measured: the right thumb's near-contact
## side distance had median 0.46 against a 0.40 contact gate -- a leftward
## swipe (thumb extending, pressure lightening) rode the surface above the
## gate and died in silence, while rightward (pressing inward) dipped under
## it. CONTACT_TOO_LIGHT = a sweep's worth of lateral travel while hovering
## just above the contact gate, never pressing in. POSTURE_NOT_READY =
## contact made but the posture score below arming. Both once per episode.
enum RejectReason { SWIPE_TOO_SHORT, TAP_TOO_QUICK, TOO_SLOW, POSTURE_LOST, LOW_QUALITY, DISCONTINUITY, OUT_OF_START_ZONE, CONTACT_TOO_LIGHT, POSTURE_NOT_READY }

signal gesture_candidate(gesture: Gesture, hand: int, progress: float)
signal gesture_performed(gesture: Gesture, hand: int, confidence: float)
## One emission per gesture attempt that was seen and discarded, with the most
## specific reason. `attempted` is the Gesture the motion was heading toward
## when it died (-1 when unattributable, e.g. a quality dropout before any
## meaningful travel) -- ON-DEVICE COUNTS SHOWED WHY THIS EXISTS: "swiping
## right seems more reliable than swiping left" is unanswerable from reasons
## alone; per-direction rejection counts answer it in one session. Sources
## that cannot observe their own rejections (the native runtime detector
## publishes only successes) simply never emit it.
signal gesture_rejected(hand: int, reason: RejectReason, attempted: int)

func gesture_name(gesture: int) -> String:
    if gesture < 0 or gesture >= Gesture.size():
        return "unknown"
    return Gesture.keys()[gesture].to_lower()

func reject_reason_name(reason: int) -> String:
    if reason < 0 or reason >= RejectReason.size():
        return "unknown"
    return RejectReason.keys()[reason].to_lower()

## Which Gesture values this provider can EVER emit. Consumers use this to
## adapt instead of discovering a missing gesture by dead air -- e.g. the
## portable joint recognizer has no FORWARD/BACKWARD, so a consumer mapping
## those can fall back or say so. Defaults to the full vocabulary because
## that is the claim every source implicitly made before this method existed;
## sources with a narrower set override honestly.
func get_supported_gestures() -> Array:
    return [Gesture.LEFT, Gesture.RIGHT, Gesture.FORWARD, Gesture.BACKWARD, Gesture.TAP]

func reset() -> void:
    pass

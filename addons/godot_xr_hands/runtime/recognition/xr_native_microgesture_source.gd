@icon("res://addons/godot_xr_hands/icons/xr_gesture_recognizer.svg")
extends "res://addons/godot_xr_hands/runtime/recognition/xr_microgesture_source.gd"

## Runtime-detected microgestures, surfaced through the same provider
## contract as the joint-based recognizer.
##
## On OpenXR runtimes advertising XR_META_hand_tracking_microgestures (all
## verified: standalone Quest 3, Horizon OS v205 -- Found AND Enabled in the
## boot log), the RUNTIME's own detector -- the one Meta's first-party apps
## use -- publishes swipe left/right/forward/backward and thumb tap as plain
## bool inputs on the ext hand-interaction profile. The action map binds
## them to the mg_* actions this node listens for on the left_hand and
## right_hand trackers.
##
## The extension is part of the open OpenXR registry: consuming it carries
## none of the ISDK's license restrictions. Per the suite's standing rule it
## is ADDITIVE only -- the joint-based recognizer remains the portable
## default (WebXR, Link, any runtime without the extension), and consumers
## decide per hand which source to trust (see
## XRMicrogestureLocomotionDriver.prefer_platform_microgestures).
##
## Directions arrive wearer-relative from the runtime for both hands -- no
## handedness mirroring here. (Meta's own bindings map swipe-left to
## snap-turn-left identically on both hands.)

const _ACTION_TO_GESTURE := {
    "mg_swipe_left": Gesture.LEFT,
    "mg_swipe_right": Gesture.RIGHT,
    "mg_swipe_forward": Gesture.FORWARD,
    "mg_swipe_backward": Gesture.BACKWARD,
    "mg_tap": Gesture.TAP,
}

const _TRACKER_TO_HAND := {
    &"left_hand": 0,
    &"right_hand": 1,
}

var _connected := {}


func _ready() -> void:
    XRServer.tracker_added.connect(_on_tracker_added)
    for tracker_name in _TRACKER_TO_HAND:
        _try_connect(tracker_name)


func _on_tracker_added(tracker_name: StringName, _type: int) -> void:
    if _TRACKER_TO_HAND.has(tracker_name):
        _try_connect(tracker_name)


func _try_connect(tracker_name: StringName) -> void:
    if _connected.get(tracker_name, false):
        return
    var tracker := XRServer.get_tracker(tracker_name)
    if tracker == null:
        return
    var hand: int = _TRACKER_TO_HAND[tracker_name]
    tracker.button_pressed.connect(_on_button_pressed.bind(hand))
    _connected[tracker_name] = true


func _on_button_pressed(action_name: String, hand: int) -> void:
    if not _ACTION_TO_GESTURE.has(action_name):
        return
    # The runtime has already done its own gating and debounce; each press
    # is one recognized gesture. Confidence is 1.0 by definition -- the
    # runtime does not publish gestures it doubts.
    gesture_performed.emit(_ACTION_TO_GESTURE[action_name], hand, 1.0)


## The full vocabulary -- the runtime detector emits all five, including the
## FORWARD/BACKWARD the joint recognizer cannot derive. Explicit rather than
## inherited so a test pins it. Note gesture_rejected NEVER fires here: the
## extension publishes only successes, so this source cannot observe its own
## rejections -- rejection feedback is a portable-recognizer feature.
func get_supported_gestures() -> Array:
    return [Gesture.LEFT, Gesture.RIGHT, Gesture.FORWARD, Gesture.BACKWARD, Gesture.TAP]

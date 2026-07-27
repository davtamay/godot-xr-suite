extends SceneTree

## Headless tests for the native (runtime-detected) microgesture source: the
## mg_* OpenXR bool actions arriving on the hand trackers must come out as
## the canonical XRMicrogestureSource vocabulary with the right hand ids,
## and unknown inputs must be ignored.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_hands/tests/test_native_microgesture_source.gd

const NativeSourceScript := preload("res://addons/godot_xr_hands/runtime/recognition/xr_native_microgesture_source.gd")
const SourceContract := preload("res://addons/godot_xr_hands/runtime/recognition/xr_microgesture_source.gd")

var _ran := false


func _process(_delta: float) -> bool:
    if _ran:
        return false
    _ran = true
    _run_all()
    return false


func _run_all() -> void:
    var failures: Array[String] = []
    _test_actions_map_to_vocabulary(failures)

    if failures.is_empty():
        print("XR native microgesture source: PASS")
        quit(0)
    else:
        for f in failures:
            push_error(f)
        print("XR native microgesture source: FAIL (%d)" % failures.size())
        quit(1)


func _test_actions_map_to_vocabulary(failures: Array[String]) -> void:
    var source = NativeSourceScript.new()
    root.add_child(source)

    var left := XRControllerTracker.new()
    left.name = "left_hand"
    XRServer.add_tracker(left)
    var right := XRControllerTracker.new()
    right.name = "right_hand"
    XRServer.add_tracker(right)

    var events: Array = []
    source.gesture_performed.connect(
        func(gesture: int, hand: int, confidence: float) -> void:
            events.append([gesture, hand, confidence]))

    left.set_input("mg_tap", true)
    left.set_input("mg_tap", false)  # release must NOT emit a second gesture
    left.set_input("mg_swipe_left", true)
    right.set_input("mg_swipe_forward", true)
    right.set_input("mg_swipe_backward", true)
    right.set_input("mg_swipe_right", true)
    left.set_input("unrelated_action", true)  # ignored

    var expected := [
        [SourceContract.Gesture.TAP, 0, 1.0],
        [SourceContract.Gesture.LEFT, 0, 1.0],
        [SourceContract.Gesture.FORWARD, 1, 1.0],
        [SourceContract.Gesture.BACKWARD, 1, 1.0],
        [SourceContract.Gesture.RIGHT, 1, 1.0],
    ]
    if events != expected:
        failures.append("native actions must map 1:1 onto the source vocabulary, got %s expected %s" % [events, expected])

    XRServer.remove_tracker(left)
    XRServer.remove_tracker(right)
    root.remove_child(source)
    source.free()

class_name XRGestureRuntime
extends Node

## Orchestrates the frame pipeline: acquire each hand once, extract shared
## features once, then evaluate all definitions and their temporal state.

signal gesture_started(gesture_id: StringName, hand: int, score: float)
signal gesture_performed(gesture_id: StringName, hand: int, score: float)
signal gesture_ended(gesture_id: StringName, hand: int, score: float)
signal hand_features_updated(hand: int, features: XRHandFeatures)

const XRInputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")

@export var enabled := true
@export var process_without_xr := false
## Feed recognition the CONDITIONED hand instead of raw joints. The
## recognizers' thresholds were tuned against raw data, so this is an
## on-device question, not a settled one -- flip it live from the feel-check
## scene and compare. set_pose_source() overrides this entirely.
@export var use_conditioned_hands := true
@export var definitions: Array[XRGestureDefinition] = []

var _pose_source: XRHandPoseSource
var _extractor := XRHandFeatureExtractor.new()
var _frames := {}
var _frame_indices := {}
var _features := {}
var _states := {}

func _ready() -> void:
    if _pose_source == null:
        _pose_source = default_pose_source(use_conditioned_hands)
    for hand in [XRInputAdapter.Hand.LEFT, XRInputAdapter.Hand.RIGHT]:
        _frames[hand] = [XRHandFrame.new(), XRHandFrame.new()]
        _frame_indices[hand] = 0
        _features[hand] = XRHandFeatures.new()

func set_pose_source(source: XRHandPoseSource) -> void:
    _pose_source = source

## The source a runtime uses when nothing was injected. Static and free of node
## state so the raw-vs-conditioned choice is testable headless.
static func default_pose_source(conditioned: bool) -> XRHandPoseSource:
    return XRTrackerHandPoseSource.new(conditioned)

## Swaps the acquisition source at runtime for A/B comparison, preserving
## nothing: recognizers keep their own state, and the next frame simply
## arrives from the other source. Rebuilds even when the flag is unchanged is
## avoided so a caller driving this every frame cannot thrash the source.
func set_use_conditioned_hands(value: bool) -> void:
    if use_conditioned_hands == value:
        return
    use_conditioned_hands = value
    _pose_source = default_pose_source(value)

func get_features(hand: int) -> XRHandFeatures:
    return _features.get(hand) as XRHandFeatures

func get_gesture_state(gesture_id: StringName, hand: int) -> XRGestureStateMachine:
    return _states.get(_state_key(gesture_id, hand)) as XRGestureStateMachine

func _process(delta: float) -> void:
    if not enabled:
        return
    if not process_without_xr and not get_viewport().use_xr:
        _reset_states()
        return
    if _pose_source == null:
        return

    var timestamp_usec := Time.get_ticks_usec()
    for hand in [XRInputAdapter.Hand.LEFT, XRInputAdapter.Hand.RIGHT]:
        _update_hand(hand, timestamp_usec, delta)

func _update_hand(hand: int, timestamp_usec: int, delta: float) -> void:
    var buffers: Array = _frames[hand]
    var previous_index: int = _frame_indices[hand]
    var current_index := 1 - previous_index
    var previous := buffers[previous_index] as XRHandFrame
    var current := buffers[current_index] as XRHandFrame
    _pose_source.capture(hand, timestamp_usec, current)
    _frame_indices[hand] = current_index

    var features := _extractor.extract(current, previous, _features[hand])
    # Stamped AFTER extract (which resets the features object) and every frame
    # unconditionally, so a stale true can never survive into the next frame.
    # The one-shot is consumed here, once, on behalf of every recognizer this
    # runtime feeds -- recognizers read the stamp, they do not race for the
    # source's flag.
    features.discontinuity = _pose_source.consume_discontinuity(hand)
    hand_features_updated.emit(hand, features)
    for definition in definitions:
        if definition == null or (definition.hand >= 0 and definition.hand != hand):
            continue
        _evaluate(definition, hand, features, delta)

func _evaluate(definition: XRGestureDefinition, hand: int, features: XRHandFeatures, delta: float) -> void:
    var key := _state_key(definition.gesture_id, hand)
    var machine := _states.get(key) as XRGestureStateMachine
    if machine == null:
        machine = XRGestureStateMachine.new()
        _states[key] = machine
    var transition := machine.update(definition.evaluate(features), delta, definition)
    match transition:
        XRGestureStateMachine.Transition.STARTED:
            gesture_started.emit(definition.gesture_id, hand, machine.score)
        XRGestureStateMachine.Transition.PERFORMED:
            gesture_performed.emit(definition.gesture_id, hand, machine.score)
        XRGestureStateMachine.Transition.ENDED:
            gesture_ended.emit(definition.gesture_id, hand, machine.score)

func _reset_states() -> void:
    for machine in _states.values():
        (machine as XRGestureStateMachine).reset()

func _state_key(gesture_id: StringName, hand: int) -> String:
    return "%s:%d" % [gesture_id, hand]

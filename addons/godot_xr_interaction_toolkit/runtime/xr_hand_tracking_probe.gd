@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_direct_interactor.svg")
class_name XRHandTrackingProbe
extends Node

## DIAGNOSTIC. Logs what a hand tracker ACTUALLY reports as a hand leaves and
## re-enters view, so tracking-loss policy is written from measurements instead
## of from assumptions about the runtime.
##
## This exists because three successive fixes for a drifting out-of-view ray
## were reasoned from source and all three were wrong on device. The open
## question it answers: does this runtime CLEAR
## HAND_JOINT_FLAG_POSITION_TRACKED when a hand leaves view, or does it keep
## reporting tracked-and-valid while merely extrapolating? Every gate in the
## suite depends on that answer and none of it has been measured.
##
## Change-gated, and deliberately so: an unconditional per-frame print produced
## 91,530 lines in one Link session on this project. Only transitions log.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

const _VALID := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
const _TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
const _HANDS := 2

@export var enabled := true
## Joint counts move by one or two on noise; only report a real change.
@export_range(1, 26, 1) var report_delta := 3

var _last := [{}, {}]


func _physics_process(_delta: float) -> void:
	if not enabled:
		return
	for hand in _HANDS:
		_sample(hand, XRHandTrackerResolver.resolve_raw(hand), "raw")
		_sample(hand, XRHandTrackerResolver.get_tracker(hand), "conditioned")


func _sample(hand: int, tracker: XRHandTracker, label: String) -> void:
	var state := {"present": tracker != null, "data": false, "valid": 0, "tracked": 0}
	if tracker != null:
		state["data"] = tracker.has_tracking_data
		for joint in XRHandTracker.HAND_JOINT_MAX:
			var flags := tracker.get_hand_joint_flags(joint)
			if (flags & _VALID) != 0:
				state["valid"] = int(state["valid"]) + 1
			if (flags & _TRACKED) != 0:
				state["tracked"] = int(state["tracked"]) + 1

	var key := "%s_%s" % [hand, label]
	var previous: Dictionary = _last[hand].get(key, {})
	if not _changed(previous, state):
		return
	_last[hand][key] = state
	print("[hand-probe] hand=%d %-11s present=%s has_data=%s valid=%d tracked=%d" % [
		hand, label, state["present"], state["data"], state["valid"], state["tracked"]])


## A transition worth printing: presence or has_tracking_data flipped, or a
## joint count moved by more than noise.
func _changed(previous: Dictionary, state: Dictionary) -> bool:
	if previous.is_empty():
		return true
	if previous["present"] != state["present"] or previous["data"] != state["data"]:
		return true
	if absi(int(previous["valid"]) - int(state["valid"])) >= report_delta:
		return true
	return absi(int(previous["tracked"]) - int(state["tracked"])) >= report_delta

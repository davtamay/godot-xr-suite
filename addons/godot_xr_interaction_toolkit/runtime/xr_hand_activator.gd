@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRHandActivator
extends Node
## Fires a held object's ACTIVATE with a bare-hand gesture, so hands do what a
## controller trigger does. Drop it inside a grab interactable: while the object
## is held bare-handed, curling the chosen TRIGGER FINGER (index by default)
## fires the object's activate - a blaster shoots, a spray can sprays. The effect
## stays separate (XRBlaster and friends listen for `activated`), so this one
## bridge powers any activatable hand tool.
##
## Authorable two ways: the simple default measures a single finger's curl (set
## `trigger_finger` + the thresholds - a gun uses the index, a spray can the
## thumb); or point `activate_gesture` at any XRHandGesture (a Gesture Studio
## recording or a preset) to fire on a whole authored pose instead.
##
## Publishes the pull as the held object's USE axis (XRGrabInteractable
## .use_value). Also still emits the deprecated `trigger_progress` so the
## tool can respond live (a trigger that visibly depresses as your finger curls),
## which is how the gesture teaches itself to the user.
##
## Controllers already fire activate from their trigger button, so this stays
## quiet unless a HAND is the one holding the object.

enum Finger { THUMB, INDEX, MIDDLE, RING, PINKY }
## MOMENTARY: one activate per pull (a gun shot). CONTINUOUS: the object stays
## activated the whole time the finger is held past the threshold and
## deactivates on release (a spray can, a drill) - drives activate_entered /
## activate_exited on the interactable.
enum ActivateMode { MOMENTARY, CONTINUOUS }

## Which finger pulls the trigger. Ignored when activate_gesture is set.
@export var trigger_finger: Finger = Finger.INDEX
## One shot per pull, or held-active while pulled. See ActivateMode.
@export var activate_mode: ActivateMode = ActivateMode.MOMENTARY
## How much MORE the finger must curl, past its resting position, to fire (0..1).
## Measured relative to how you're holding the tool, so it adapts to any grip and
## hand - a deliberate trigger pull, not an absolute pose. Lower = hair trigger.
@export_range(0.03, 0.6, 0.01) var fire_pull := 0.14
## How far the pull must relax back before it can fire again (hysteresis, so one
## pull = one shot). Keep below fire_pull.
@export_range(0.01, 0.5, 0.01) var release_pull := 0.06
## Optional: fire on a whole authored pose (a Gesture Studio recording or preset)
## instead of a single finger curl. When set, the finger settings are ignored.
@export var activate_gesture: XRHandGesture:
	set(value):
		activate_gesture = value
		_rebuild_recognizer()
## Only fire while the object is actually held by a hand (the normal case).
@export var require_held := true

## Emitted the frame the gesture fires. hand is XRPositionalTracker.TRACKER_HAND_*.
signal activated_by_gesture(hand: int)
## Emitted every frame a hand holds the object: amount is the trigger finger's
## curl 0..1 (or 1.0 when an authored gesture is matched). Drive live feedback.
## DEPRECATED, kept as a thin forward of the held object's USE axis so any
## external project still connected to it keeps working. Prefer
## XRGrabInteractable.use_changed / use_value: that is the single source, and
## it reaches controller-held props too if a controller analog source lands.
signal trigger_progress(hand: int, amount: float)

const _RECOGNIZER_PATH := "res://addons/godot_xr_hands/runtime/gesture_studio/xr_gesture_recognizer.gd"

# Full joint chain per finger (base -> tip). Curl = the SUM of the bend angles at
# each knuckle, so a trigger pull (which bends the mid/tip joints while the big
# knuckle barely moves) reads strongly - a single-joint measure misses it.
const _FINGER_JOINTS := {
	Finger.THUMB: [
		XRHandTracker.HAND_JOINT_THUMB_METACARPAL,
		XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_THUMB_TIP,
	],
	Finger.INDEX: [
		XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	],
	Finger.MIDDLE: [
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
	],
	Finger.RING: [
		XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
		XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
	],
	Finger.PINKY: [
		XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
	],
}

var _interactable: XRBaseInteractable
var _recognizer: Node
# Per-hand armed state so one pull fires once (mirrors the pinch re-arm).
var _armed := {}
# Per-hand resting curl (how the finger sits while holding) - the pull baseline.
var _rest := {}
# Per-hand smoothed curl, to shave tracking jitter on a held pull.
var _smooth := {}
# Per-hand count of consecutive frames with no valid curl (tracking gap).
var _invalid := {}
# Per-hand active interactor while CONTINUOUS spray/drill is on (null = off).
var _active := {}


func _ready() -> void:
	_interactable = _find_interactable()
	if Engine.is_editor_hint():
		return
	_rebuild_recognizer()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# The recognizer path drives itself off its own signals; the finger path
	# polls the holding hand here. Use the interactor/tracker-resolver Hand enum
	# (LEFT = 0, RIGHT = 1) - NOT XRPositionalTracker.TRACKER_HAND_* (1, 2), which
	# would skip the left hand and mis-match the holding interactor.
	if activate_gesture != null:
		return
	_poll_finger(XRInputAdapter.Hand.LEFT)
	_poll_finger(XRInputAdapter.Hand.RIGHT)


func _find_interactable() -> XRBaseInteractable:
	var node := get_parent()
	while node != null:
		if node is XRBaseInteractable:
			return node
		node = node.get_parent()
	return null


func _poll_finger(hand: int) -> void:
	var interactor := _held_by(hand)
	if require_held and interactor == null:
		_end_continuous(hand)  # dropping the tool always stops a held activate
		_rest.erase(hand)
		_smooth.erase(hand)
		_invalid.erase(hand)
		_armed[hand] = true
		return
	var raw := _finger_curl(hand)
	if raw < 0.0:
		# Brief tracking gap - hold the last curl a few frames so a pull isn't
		# silently dropped mid-motion; give up if the hand is truly gone.
		var last: float = _smooth.get(hand, -1.0)
		if last < 0.0:
			return
		_invalid[hand] = _invalid.get(hand, 0) + 1
		if _invalid[hand] > 8:
			return
		raw = last
	else:
		_invalid[hand] = 0
	# Smooth the curl so hand-tracking jitter (worst while moving the tool around)
	# can't flicker the state on a held pull.
	var curl: float = lerpf(_smooth.get(hand, raw), raw, 0.5)
	_smooth[hand] = curl
	# Baseline = the RELAXED finger in this grip. Follow DOWN instantly (a more
	# relaxed finger is the new rest), but drift UP only while the finger is NEAR
	# rest - never during a deliberate hold, or the baseline would creep up toward
	# a sustained curl and drop the pull (the spray cutting out mid-hold).
	var rest: float = _rest.get(hand, curl)
	rest = minf(rest, curl)
	if curl - rest < release_pull:
		rest = lerpf(rest, curl, 0.05)
	_rest[hand] = rest
	var pull := curl - rest
	# Trigger bottoms out exactly at the fire point, so the visual = the shot.
	var progress := clampf(pull / fire_pull, 0.0, 1.0)
	trigger_progress.emit(hand, progress)
	# Publish the same normalized pull as the held object's USE axis, so any prop
	# can read "how hard is this being used" without knowing about this node or
	# about hands at all. Deliberately reuses the value already computed above --
	# the curl math and its thresholds are on-device tuned and untouched here.
	if _interactable != null and _interactable.has_method("set_use_value"):
		_interactable.set_use_value(progress, hand)
	if activate_mode == ActivateMode.CONTINUOUS:
		if _active.get(hand) == null and pull >= fire_pull:
			_active[hand] = interactor
			activated_by_gesture.emit(hand)
			if _interactable != null:
				_interactable._notify_activate_entered(interactor)
		elif _active.get(hand) != null and pull <= release_pull:
			_end_continuous(hand)
		return
	# MOMENTARY: one shot per pull.
	if not _armed.get(hand, true):
		if pull <= release_pull:
			_armed[hand] = true
		return
	if pull >= fire_pull:
		_armed[hand] = false
		_fire(hand, interactor)


## End a CONTINUOUS activate using the interactor that started it, so releasing
## or dropping the tool always deactivates cleanly (spray never sticks on).
func _end_continuous(hand: int) -> void:
	var interactor = _active.get(hand)
	if interactor == null:
		return
	_active.erase(hand)
	if _interactable != null:
		_interactable._notify_activate_exited(interactor)


## Curl of the trigger finger, 0 (straight) .. 1 (fully curled), or -1 if the
## hand isn't tracked this frame. Sum of the bend angles at every knuckle, so a
## trigger pull (bending the mid/tip joints) reads even when the big knuckle
## stays put; pose-stable and independent of the hand's world orientation.
func _finger_curl(hand: int) -> float:
	var tracker := XRHandTrackerResolver.get_tracker(hand)
	if tracker == null:
		return -1.0
	# Use the base -> distal joints, NOT the fingertip: curling to fire folds the
	# tip toward the palm where the cameras lose it, so requiring the tip made a
	# real pull read as "no data" and drop the shot. These four track reliably
	# through the whole curl, and their two knuckle bends still capture the pull.
	var joints: Array = _FINGER_JOINTS[trigger_finger]
	var pts: Array[Vector3] = []
	for i in mini(4, joints.size()):
		if not XRHandGestureProvider.joint_position_valid(tracker, joints[i]):
			return -1.0
		pts.append(tracker.get_hand_joint_transform(joints[i]).origin)
	var bones: Array[Vector3] = []
	for i in range(pts.size() - 1):
		var b := pts[i + 1] - pts[i]
		if b.length_squared() < 0.000001:
			return -1.0
		bones.append(b.normalized())
	var total := 0.0
	for i in range(bones.size() - 1):
		total += bones[i].angle_to(bones[i + 1])
	# ~3 rad of bend across these knuckles is a full curl.
	return clampf(total / 3.0, 0.0, 1.0)


func _held_by(hand: int) -> Node:
	if _interactable == null:
		return null
	for interactor in _interactable.get_selecting_interactors():
		if interactor != null and interactor.get("hand") == hand:
			return interactor
	return null


func _fire(hand: int, interactor) -> void:
	activated_by_gesture.emit(hand)
	if _interactable != null:
		# Momentary fire - emit the activate signal the tool listens for without
		# leaving the interactable latched in an activated state.
		_interactable.activated.emit(interactor)


func _rebuild_recognizer() -> void:
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	if _recognizer != null and is_instance_valid(_recognizer):
		_recognizer.queue_free()
		_recognizer = null
	if activate_gesture == null:
		return
	var script := load(_RECOGNIZER_PATH)
	if script == null:
		push_warning("XRHandActivator: gesture recognizer script not found; falling back to finger curl.")
		return
	_recognizer = script.new()
	_recognizer.name = "ActivatorRecognizer"
	_recognizer.gestures = [activate_gesture]
	_recognizer.focus_gesture_name = activate_gesture.gesture_name
	add_child(_recognizer)
	_recognizer.gesture_started.connect(_on_gesture_started)


func _on_gesture_started(gesture_name: String, hand: int) -> void:
	if activate_gesture == null or gesture_name != activate_gesture.gesture_name:
		return
	var interactor := _held_by(hand)
	if require_held and interactor == null:
		return
	trigger_progress.emit(hand, 1.0)
	_fire(hand, interactor)


func _get_configuration_warnings() -> PackedStringArray:
	if _find_interactable() == null:
		return PackedStringArray([
			"Place XRHandActivator inside a grab interactable (XRGrabInteractable) - "
			+ "it fires that object's activate from a bare-hand gesture."])
	return PackedStringArray()

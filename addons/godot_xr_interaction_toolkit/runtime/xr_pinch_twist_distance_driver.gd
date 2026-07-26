@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRPinchTwistDistanceDriver
extends Node

## Wrist-roll RATE control for XRGrabInteractable.FarGrabMode.TWIST far-grabs
## (docs/far-grab-modes-design.md, "Phase 2: TWIST").
##
## Pinch IS grab for a bare hand, so thumb-and-index are occupied the instant
## a far-grab starts. The wrist stays free, gives ~180 degrees of comfortable
## travel, and rolling around the direction you are already pointing is
## decoupled from aiming -- aiming swings the ray ACROSS its own axis; roll
## turns AROUND it.
##
## Parent this INSIDE a grab interactable, the same placement XRHandActivator
## uses: it finds the interactable by walking up its ancestors and, every
## physics frame, checks whichever interactor currently holds it per hand.
## Soft dependency on godot_xr_hands, following xr_microgesture_locomotion_driver.gd
## exactly -- inert (no wrist tracker ever resolves) when that addon, or hand
## tracking, is absent; xr.interaction keeps requires=[] in xr_package.cfg.
##
## RATE control, not absolute mapping -- the design doc records why absolute
## mapping was rejected (it runs out of travel against a 0.25-6 m range and
## amplifies jitter at the gain that would require). Roll away from a NEUTRAL
## captured the moment this hand's grab starts drives the RATE distance
## changes, not the distance itself: twist and hold and the object keeps
## travelling; return to neutral and it stops.
##
## Only acts on a held object whose far_grab_mode is TWIST, and only while a
## ray interactor (a far grab) holds it -- a near/direct hold is untouched.
## Only acts once a wrist joint resolves for the holding hand, which is never
## true for a controller (no pinch, no wrist joint): an object authored TWIST
## but held by a controller simply holds its distance, exactly like FIXED,
## rather than breaking.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")
const XRInputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")

## Radians of roll away from the captured neutral before it starts driving
## distance at all. Guards ordinary aiming -- which does not hold the wrist
## still -- from drifting the distance while you are only re-aiming.
@export_range(0.0, 1.0, 0.001) var deadzone_radians := 0.12

## Metres/second of distance RATE per radian of roll BEYOND the deadzone.
## Example: gain 1.5 with a 0.5 rad twist (0.38 rad past the default 0.12 rad
## deadzone) drives ~0.57 m/s -- about a metre per two seconds of a
## comfortable twist. adjust_grab_distance() still applies the ray's own
## clamps (min_grab_distance, max_distance, max_distance_change_per_second),
## which are not reimplemented here.
@export_range(0.0, 10.0, 0.01, "or_greater") var rate_gain := 1.5

var _interactable: Node
## Per-hand captured neutral, keyed by XRInputAdapter.Hand: {axis, rotation}.
## axis is the ray/forward direction frozen the first physics frame this
## driver observes that hand TWIST-holding via a ray (the same "capture once,
## never re-read while held" decision the reel axis makes, for the same
## reason -- aiming after the grab must not change what "roll" means).
## rotation is the wrist's own orientation at that same moment. Erased the
## moment the hand stops TWIST-holding via a ray, so the next grab captures a
## fresh neutral rather than reusing a stale one.
var _neutral: Dictionary = {}


func _ready() -> void:
	_interactable = _find_interactable()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _interactable == null:
		return
	_drive_hand(XRInputAdapter.Hand.LEFT, delta)
	_drive_hand(XRInputAdapter.Hand.RIGHT, delta)


func _drive_hand(hand: int, delta: float) -> void:
	var interactor := _held_by(hand)
	if interactor == null or not (interactor is XRRayInteractor) or not _is_twist_target():
		_neutral.erase(hand)
		return

	var tracker := XRHandTrackerResolver.get_tracker(hand)
	if tracker == null or not tracker.has_tracking_data \
			or not XRHandTrackerResolver.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_WRIST):
		# No wrist joint resolves for this hand -- a controller (no pinch, no
		# wrist joint at all) or a hand that dropped out of tracking. Hold
		# distance, exactly like FIXED, rather than break. Neutral is left
		# captured (not erased) so a brief tracking dropout mid-twist resumes
		# from the same baseline instead of silently re-zeroing.
		return

	var current_rotation := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).basis.get_rotation_quaternion()
	if not _neutral.has(hand):
		# First frame this hand is seen TWIST-holding: capture neutral, drive
		# nothing yet. Freezing here (not at the interactable's `grabbed`
		# signal, which fires BEFORE the ray records its own post-grab attach
		# pose -- see xr_interaction_manager.request_select's call order) means
		# the frozen axis reads the ray's already-settled aim, at the cost of
		# at most one physics frame of skew versus the exact select instant --
		# bounded, and it does not accumulate.
		_neutral[hand] = {"axis": _roll_axis(interactor), "rotation": current_rotation}
		return

	var neutral: Dictionary = _neutral[hand]
	var roll := twist_angle(neutral["rotation"], current_rotation, neutral["axis"])
	var rate := distance_rate(roll, deadzone_radians, rate_gain)
	if rate == 0.0:
		return
	interactor.adjust_grab_distance(rate * delta)


## Signed angle (radians) the wrist has rotated AROUND `axis` between
## `neutral_rotation` and `current_rotation`, independent of whatever the
## wrist also did around any axis perpendicular to it (aiming) -- the
## standard swing-twist decomposition. For delta = current * neutral^-1,
## expressed as a quaternion (x, y, z, w), the twist embedded in delta around
## a unit axis A is 2 * atan2(dot((x,y,z), A), w): the swing component's
## contribution to dot((x,y,z), A) is exactly zero because swing's own
## rotation axis is by construction perpendicular to A, so this is exact
## whenever the swing angle is under +/-180 degrees -- always true for a
## wrist twisting while pinched, never a case this technique needs to defend
## against separately. `axis` must already be a unit vector.
static func twist_angle(neutral_rotation: Quaternion, current_rotation: Quaternion, axis: Vector3) -> float:
	var delta := (current_rotation * neutral_rotation.inverse()).normalized()
	var vector_part := Vector3(delta.x, delta.y, delta.z)
	return 2.0 * atan2(vector_part.dot(axis), delta.w)


## Signed distance RATE (m/s) for a measured roll against the authored
## deadzone/gain. Zero inside the deadzone -- this is what keeps ordinary
## aiming, which does not hold the wrist still, from drifting the distance.
## Linear beyond it: rate_gain is m/s PER RADIAN of roll past the deadzone,
## so holding a constant roll keeps producing the same rate every frame (a
## throttle), never an absolute position (a dial).
static func distance_rate(roll_radians: float, deadzone_radians: float, rate_gain: float) -> float:
	var excess := 0.0
	if roll_radians > deadzone_radians:
		excess = roll_radians - deadzone_radians
	elif roll_radians < -deadzone_radians:
		excess = roll_radians + deadzone_radians
	return excess * rate_gain


## The frozen roll axis for a fresh neutral capture: the ray's current aim
## direction. -basis.z, not +basis.z -- confirmed from
## xr_controller_hand_adapter.gd's own pose construction
## ("direction": (-xf.basis.z).normalized(), and the hand-aim branch builds
## its basis FROM that same direction), so this matches the ray's actual
## forward convention rather than assuming it.
func _roll_axis(interactor) -> Vector3:
	var axis: Vector3 = -interactor.get_attach_pose().basis.z
	if axis.length_squared() < 0.000001:
		return Vector3.FORWARD
	return axis.normalized()


func _is_twist_target() -> bool:
	return _interactable != null and "far_grab_mode" in _interactable \
			and int(_interactable.far_grab_mode) == XRGrabInteractable.FarGrabMode.TWIST


## Same pattern as XRHandActivator._held_by: the interactor (if any) of this
## hand among the interactable's current selecting interactors.
func _held_by(hand: int) -> Node:
	if _interactable == null or not _interactable.has_method("get_selecting_interactors"):
		return null
	for interactor in _interactable.get_selecting_interactors():
		if interactor != null and interactor.get("hand") == hand:
			return interactor
	return null


## Same pattern as XRHandActivator._find_interactable: walk up the ancestors
## for the interactable this driver was parented inside.
func _find_interactable() -> Node:
	var node := get_parent()
	while node != null:
		if node is XRBaseInteractable:
			return node
		node = node.get_parent()
	return null


func _get_configuration_warnings() -> PackedStringArray:
	if _find_interactable() == null:
		return PackedStringArray([
			"Place XRPinchTwistDistanceDriver inside a grab interactable "
			+ "(XRGrabInteractable) with far_grab_mode set to TWIST -- it "
			+ "drives that object's far-grab distance from wrist roll."])
	return PackedStringArray()

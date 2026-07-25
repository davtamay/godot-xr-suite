class_name XRHandFilter
extends XRHandPoseSource

## Adaptive conditioning decorator over any XRHandPoseSource.
##
## Decomposes each frame into a wrist world pose plus per-joint PARENT-LOCAL
## transforms, filters those, and recomposes. Because rotations are filtered in
## parent-local space, no filter strength can change a bone length -- distortion
## is structurally impossible rather than merely unlikely.
##
## Bone OFFSETS are filtered very hard: a given user's skeleton is essentially
## constant, and the runtime reports it with measurement noise on top, so heavy
## filtering converges to a stable per-user skeleton. That stops the mesh hand
## breathing, which is a separate artifact from joint jitter.

const _HANDS := 2

@export var enabled := true

## Optically-tracked parameters. Tuned 2026-07-24 against recorded Quest Link
## traces (docs/hand-conditioning-results.md): beta 0.7 -> 2.0 cut motion lag
## from 53-56 ms to 18-28 ms at a 0.2% jitter cost; the sweep plateaus above
## beta 1.5, so higher values buy nothing.
@export var position_min_cutoff := 1.0
@export var position_beta := 2.0
@export var rotation_min_cutoff := 1.5
@export var rotation_beta := 0.5
## Bone offsets converge to a stable skeleton; deliberately far lower.
@export var bone_min_cutoff := 0.05

## Controller-emulated hands have different noise characteristics.
@export var controller_position_min_cutoff := 2.0
@export var controller_position_beta := 0.4
@export var controller_rotation_min_cutoff := 3.0
@export var controller_rotation_beta := 0.3

var _inner: XRHandPoseSource
var _raw := XRHandFrame.new()

# Per hand.
var _wrist_position: Array[XROneEuroFilter] = []
var _wrist_rotation: Array[XROneEuroRotationFilter] = []
var _local_rotation: Array[XROneEuroRotationFilter] = []
var _local_offset: Array[XROneEuroFilter] = []
var _is_controller := [false, false]
var _last_timestamp := [-1, -1]
# Duplicate-sample suppression (see capture).
var _output: Array[XRHandFrame] = []
var _last_raw_wrist: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _has_output := [false, false]

func _init(inner: XRHandPoseSource = null) -> void:
	_inner = inner
	for hand in range(_HANDS):
		_output.append(XRHandFrame.new())
		var wrist_position := XROneEuroFilter.new()
		wrist_position.resize(1)
		_wrist_position.append(wrist_position)

		var wrist_rotation := XROneEuroRotationFilter.new()
		wrist_rotation.resize(1)
		_wrist_rotation.append(wrist_rotation)

		var rotations := XROneEuroRotationFilter.new()
		rotations.resize(XRHandFrame.JOINT_COUNT)
		_local_rotation.append(rotations)

		var offsets := XROneEuroFilter.new()
		offsets.resize(XRHandFrame.JOINT_COUNT)
		_local_offset.append(offsets)
	_apply_parameters()

## Called on tracking reacquisition so the filter snaps to the recovered pose
## instead of slewing from a stale one over its whole time constant.
func reset(hand: int) -> void:
	if hand < 0 or hand >= _HANDS:
		return
	_wrist_position[hand].reset_all()
	_wrist_rotation[hand].reset_all()
	_local_rotation[hand].reset_all()
	_local_offset[hand].reset_all()
	_last_timestamp[hand] = -1
	_has_output[hand] = false

## The input modality manager is the authority on whether a hand is
## controller-driven -- tracker.hand_tracking_source is NOT reliable across
## runtimes. Callers resolve the manager by group and push the answer here.
func set_controller_source(hand: int, is_controller: bool) -> void:
	if hand < 0 or hand >= _HANDS or _is_controller[hand] == is_controller:
		return
	_is_controller[hand] = is_controller
	_apply_parameters()
	reset(hand)

func _apply_parameters() -> void:
	for hand in range(_HANDS):
		var controller: bool = _is_controller[hand]
		var pos_cutoff := controller_position_min_cutoff if controller else position_min_cutoff
		var pos_beta := controller_position_beta if controller else position_beta
		var rot_cutoff := controller_rotation_min_cutoff if controller else rotation_min_cutoff
		var rot_beta := controller_rotation_beta if controller else rotation_beta

		_wrist_position[hand].min_cutoff = pos_cutoff
		_wrist_position[hand].beta = pos_beta
		_wrist_rotation[hand].min_cutoff = rot_cutoff
		_wrist_rotation[hand].beta = rot_beta
		_local_rotation[hand].min_cutoff = rot_cutoff
		_local_rotation[hand].beta = rot_beta
		_local_offset[hand].min_cutoff = bone_min_cutoff
		_local_offset[hand].beta = 0.0

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
	if _inner == null:
		return false
	if not _inner.capture(hand, timestamp_usec, _raw):
		return false

	# Reset before conditioning this frame, never after: on reacquisition the
	# filter must snap to the recovered pose, not slew from the held stale one.
	if _inner.consume_discontinuity(hand):
		reset(hand)

	if not enabled or hand < 0 or hand >= _HANDS:
		_raw.copy_into(target)
		return _raw.tracking_valid

	# The render rate often exceeds the hand-tracking rate. If the runtime has
	# not moved the hand, re-running the chain would advance filter state on a
	# duplicate sample -- which biases the derivative estimate toward zero and
	# makes the filter over-smooth. Replay the previous output instead.
	var wrist_raw := _raw.joint_transforms[XRHandTracker.HAND_JOINT_WRIST]
	if _has_output[hand] and wrist_raw.is_equal_approx(_last_raw_wrist[hand]):
		_output[hand].copy_into(target)
		return _output[hand].tracking_valid
	_last_raw_wrist[hand] = wrist_raw

	var previous: int = _last_timestamp[hand]
	var dt := 1.0 / 72.0
	if previous >= 0 and _raw.timestamp_usec > previous:
		dt = float(_raw.timestamp_usec - previous) / 1_000_000.0
	_last_timestamp[hand] = _raw.timestamp_usec

	_raw.copy_into(target)

	var wrist_id := XRHandTracker.HAND_JOINT_WRIST
	var wrist := _raw.joint_transforms[wrist_id]
	var filtered_origin := _wrist_position[hand].filter(0, wrist.origin, dt)
	var filtered_basis := Basis(_wrist_rotation[hand].filter(0, wrist.basis.get_rotation_quaternion(), dt))
	var world: Array[Transform3D] = []
	world.resize(XRHandFrame.JOINT_COUNT)
	world[wrist_id] = Transform3D(filtered_basis, filtered_origin)
	target.joint_transforms[wrist_id] = world[wrist_id]

	var parents := XRHandJointHierarchy.PARENT
	for joint in XRHandJointHierarchy.ORDER:
		if joint == wrist_id:
			continue
		var parent_joint: int = parents[joint]
		if not _raw.has_joint(joint) or not _raw.has_joint(parent_joint):
			world[joint] = _raw.joint_transforms[joint]
			target.joint_transforms[joint] = world[joint]
			continue

		# Parent-local decomposition. Filtering here cannot change a bone
		# length, because length lives in the offset, not the rotation.
		var local := _raw.joint_transforms[parent_joint].affine_inverse() * _raw.joint_transforms[joint]
		var offset := _local_offset[hand].filter(joint, local.origin, dt)
		var rotation := local.basis.get_rotation_quaternion()
		if XRHandJointHierarchy.IS_TIP[joint] == 0:
			# Tips have no children and their rotation is unused by poke and
			# pinch, so filtering it would be pure cost.
			rotation = _local_rotation[hand].filter(joint, rotation, dt)

		world[joint] = world[parent_joint] * Transform3D(Basis(rotation), offset)
		target.joint_transforms[joint] = world[joint]

	target.copy_into(_output[hand])
	_has_output[hand] = true
	return target.tracking_valid

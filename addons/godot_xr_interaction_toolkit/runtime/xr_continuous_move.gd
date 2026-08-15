@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg")
class_name XRContinuousMove
extends Node

## Smooth stick-walk locomotion - Unity XRI's Continuous Move + Continuous Turn
## as one drop-in block. Push a thumbstick to glide across the floor (relative
## to where you're LOOKING); optionally use the other stick to turn smoothly.
##
## Opt-in (NOT rig-default): smooth motion causes discomfort for some players,
## so teleport stays the default and you ADD this when you want free movement.
## It coexists with teleport: the locomotion system automatically stops
## teleporting on the hand this block drives, so a common setup is left stick =
## walk here, right stick = teleport + snap turn on XRLocomotion.
##
## Self-wiring: drop it anywhere in a scene with an XR rig.

enum TurnMode { NONE, CONTINUOUS }

## Group locomotion checks to know which hand(s) this block owns.
const GROUP := "xr_continuous_move"

@export var enabled := true

@export_group("Move")
## Which thumbstick drives walking. (This used to be a private duplicate of
## XRInputAdapter.Hand that stayed in sync only by ordinal coincidence; the
## ordinals are identical, so saved scenes keep their value.)
@export var move_hand := XRInputAdapter.Hand.LEFT
@export_range(0.5, 6.0, 0.1) var move_speed := 2.0
## Also move up/down with the play-space? Off = stay on your current height
## (recommended; gravity/steps are a future block).
@export var allow_vertical := false
@export_range(0.0, 0.9, 0.01) var deadzone := 0.15

@export_group("Turn")
## CONTINUOUS = the other stick turns you smoothly. NONE = leave turning to
## XRLocomotion's snap turn on that hand.
@export var turn_mode := TurnMode.NONE
@export_range(30.0, 180.0, 5.0) var continuous_turn_speed := 90.0

@export_group("Rig")
@export var xr_origin_path: NodePath
@export var camera_path: NodePath
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath

var _origin: Node3D
var _camera: Node3D
var _controllers: Array[XRController3D] = [null, null]


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		add_to_group(GROUP)


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	_origin = get_node_or_null(xr_origin_path) as Node3D
	if _origin == null:
		_origin = XRRigResolver.find_origin(self)
	_camera = get_node_or_null(camera_path) as Node3D
	if _camera == null:
		_camera = XRRigResolver.find_camera(self)
	_controllers[0] = get_node_or_null(left_controller_path) as XRController3D
	_controllers[1] = get_node_or_null(right_controller_path) as XRController3D
	for hand in 2:
		if _controllers[hand] == null:
			_controllers[hand] = XRRigResolver.find_controller(self, hand)


## Hands this block owns so XRLocomotion skips teleport/snap on them.
func get_claimed_hands() -> Array:
	if not enabled:
		return []
	var hands := [int(move_hand)]
	var turn_hand := _turn_hand()
	if turn_mode != TurnMode.NONE and turn_hand != int(move_hand):
		hands.append(turn_hand)
	return hands


func _turn_hand() -> int:
	return XRHandIdentity.other(int(move_hand))


func _physics_process(delta: float) -> void:
	if not enabled or _origin == null or _camera == null:
		return

	var mover := _controllers[int(move_hand)]
	if mover and mover.get_is_active():
		var stick := mover.get_vector2(&"thumbstick")
		if stick.length() > deadzone:
			var basis := _camera.global_transform.basis
			var forward := -basis.z
			var right := basis.x
			if not allow_vertical:
				forward.y = 0.0
				right.y = 0.0
			forward = forward.normalized()
			right = right.normalized()
			_origin.global_position += (right * stick.x + forward * stick.y) * move_speed * delta

	if turn_mode == TurnMode.CONTINUOUS:
		var turner := _controllers[_turn_hand()]
		if turner and turner.get_is_active():
			var tstick := turner.get_vector2(&"thumbstick")
			if absf(tstick.x) > deadzone:
				_yaw_around_camera(deg_to_rad(-tstick.x * continuous_turn_speed * delta))


func _yaw_around_camera(radians: float) -> void:
	var pivot := _camera.global_position
	var rotation_basis := Basis(Vector3.UP, radians)
	var xf := _origin.global_transform
	xf.origin = pivot + rotation_basis * (xf.origin - pivot)
	xf.basis = rotation_basis * xf.basis
	_origin.global_transform = xf

@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg")
class_name XRClimbProvider
extends Node

## Climbing locomotion - Unity XRI's Climb Provider as a drop-in block. When a
## hand grabs an XRClimbInteractable (a handhold, rung, ledge), moving that hand
## moves YOU the opposite way: pull a handhold down and you rise. Hand-over-hand
## works - grab a higher hold with the other hand and it takes over seamlessly.
##
## The handhold stays put; the RIG moves. Because it just translates the origin,
## the tunnelling vignette (which watches camera motion) fades in while you
## climb for free. Self-wiring: drop one near a rig; XRClimbInteractables find
## it by group.

## Handholds find the provider by this group.
const GROUP := "xr_climb_provider"

## Emitted when climbing starts (first hand grabs) and fully ends (last hand
## releases) - handy for the debug panel / comfort effects.
signal climb_started()
signal climb_ended()

@export var enabled := true
## 1.0 = your body moves exactly opposite your hand (natural). >1 exaggerates.
@export_range(0.5, 3.0, 0.1) var move_scale := 1.0
@export var xr_origin_path: NodePath

var _origin: Node3D
var _climbers: Array = []       # interactors currently gripping a handhold
var _active: Node               # the one driving movement (last grabbed)
var _last_local := Vector3.ZERO
# Selection fires on an input event, which can be out of step with the physics
# frame that reads the hand pose. Take the baseline on the first physics frame
# instead, so the baseline and every later reading share one source - no jump.
var _rebase_pending := false


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


## Called by a handhold when an interactor grabs it.
func begin_climb(interactor: Node) -> void:
	if not enabled or interactor == null or _origin == null:
		return
	var was_idle := _climbers.is_empty()
	if not _climbers.has(interactor):
		_climbers.append(interactor)
	_active = interactor
	_rebase_pending = true  # baseline taken on the next physics frame
	if was_idle:
		climb_started.emit()


## Called by a handhold when an interactor releases it.
func end_climb(interactor: Node) -> void:
	_climbers.erase(interactor)
	if interactor == _active:
		_active = _climbers.back() if not _climbers.is_empty() else null
		if _active:
			_rebase_pending = true  # re-base on next frame: no jump on hand-over
	if _climbers.is_empty():
		_active = null
		climb_ended.emit()


func is_climbing() -> bool:
	return _active != null


func _physics_process(_delta: float) -> void:
	if not enabled or _active == null or _origin == null:
		return
	if not is_instance_valid(_active):
		end_climb(_active)
		return
	# Take (or re-take) the baseline this frame after a grab / hand-over, so the
	# first delta is exactly zero - no visible jump.
	if _rebase_pending:
		_last_local = _hand_local(_active)
		_rebase_pending = false
		return
	# The hand's PLAY-SPACE position is invariant when the origin moves, so the
	# frame-to-frame change is purely the physical hand motion. Move the origin
	# the opposite way to keep the grabbed hold fixed under the hand.
	var hand_local := _hand_local(_active)
	var delta := (hand_local - _last_local) * move_scale
	_origin.global_position -= _origin.global_transform.basis * delta
	_last_local = hand_local


func _hand_local(interactor: Node) -> Vector3:
	return _origin.to_local(_hand_world(interactor))


## Track the physical HAND, not the attach point. A far ray's attach point is
## reeled in/out by distance manipulation as you pull, which would read as the
## hold moving closer and bounce the rig; the ray/grip ORIGIN is the hand and
## moves only when you physically move it.
func _hand_world(interactor: Node) -> Vector3:
	return XRBaseInteractor.hand_origin_of(interactor)

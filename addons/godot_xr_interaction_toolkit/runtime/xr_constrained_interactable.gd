@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRConstrainedInteractable
extends "res://addons/godot_xr_interaction_toolkit/runtime/xr_base_interactable.gd"

## Base for grab-driven MECHANISMS - a drawer, lever, dial - where grabbing
## doesn't move the object freely but along ONE degree of freedom, producing a
## normalised 0..1 value you wire to anything (Unity XRI's Dial/Lever/Drawer).
##
## Put it on a node with a collider (the moving part). Grab it (near or far),
## and the subclass projects your HAND motion onto its constraint. Like the
## climb block, it tracks the hand ORIGIN, not the reeled far-ray attach point,
## so pulling to operate a mechanism never bounces.
##
## Subclasses (XRDrawer / XRLever / XRDial) implement the constraint; this base
## handles grab tracking, the value + value_changed signal, and hand tracking.

## Fires whenever the mechanism moves (normalised 0..1).
signal value_changed(value: float)

@export_group("Mechanism")
## Node to move. Empty = this node (the one with the collider).
@export var target_path: NodePath
## Starting position of the mechanism, 0..1.
@export_range(0.0, 1.0, 0.01) var default_value := 0.0

var value := 0.0
var _grabber: Node
var _rest_transform := Transform3D.IDENTITY


func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	var moved := target()
	if moved:
		_rest_transform = moved.transform
	value = default_value
	select_entered.connect(_on_select)
	select_exited.connect(_on_deselect)
	_capture_rest()
	_apply_value()


func target() -> Node3D:
	if target_path.is_empty():
		return self
	return get_node_or_null(target_path) as Node3D


## Set the mechanism 0..1 programmatically (clamped), moving it and signalling.
## A mechanism needs a MOTION, not just a grip: a drive has to know where to
## carry the hand once it has hold. `to` is a world point that works the
## mechanism through a useful part of its range - subclasses know their own
## axis and say so.
func drive_hint() -> Dictionary:
	var hint := super()
	hint["kind"] = "constrained"
	hint["gesture"] = "grab"
	hint["to"] = drive_travel()
	return hint


## Default: no motion. A mechanism that does not override this is grabbed and
## held still, which is honest rather than a guess about its axis.
func drive_travel() -> Vector3:
	return drive_point()


## The mechanism's own axis in world space.
func drive_axis_world(local_axis: Vector3) -> Vector3:
	var moved := target()
	if moved == null:
		return Vector3.UP
	return (moved.global_transform.basis * local_axis).normalized()


func set_value(new_value: float) -> void:
	var clamped := clampf(new_value, 0.0, 1.0)
	if is_equal_approx(clamped, value):
		return
	value = clamped
	_apply_value()
	value_changed.emit(value)


func _on_select(interactor) -> void:
	_grabber = interactor
	_on_grab()


func _on_deselect(interactor) -> void:
	if interactor == _grabber:
		_grabber = null


func _physics_process(_delta: float) -> void:
	if _grabber == null:
		return
	if not is_instance_valid(_grabber):
		_grabber = null
		return
	_on_update(_hand_world())


## Track the physical HAND (ray/grip origin), not the reeled attach point.
func _hand_world() -> Vector3:
	return XRBaseInteractor.hand_origin_of(_grabber)


## Signed angle (radians) from `from_vec` to `to_vec` measured around `axis`.
func _signed_angle_around(from_vec: Vector3, to_vec: Vector3, axis: Vector3) -> float:
	var n := axis.normalized()
	var f := from_vec - n * from_vec.dot(n)
	var t := to_vec - n * to_vec.dot(n)
	if f.length_squared() < 1e-8 or t.length_squared() < 1e-8:
		return 0.0
	f = f.normalized()
	t = t.normalized()
	return atan2(n.dot(f.cross(t)), clampf(f.dot(t), -1.0, 1.0))


# --- subclass hooks -----------------------------------------------------------
## Record the constraint's rest reference (called once at _ready).
func _capture_rest() -> void:
	pass

## Grab started: capture the hand's reference against the current value.
func _on_grab() -> void:
	pass

## Per frame while held: project the hand onto the constraint and set_value().
func _on_update(_hand: Vector3) -> void:
	pass

## Move the target to reflect `value`.
func _apply_value() -> void:
	pass

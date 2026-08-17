class_name XRBaseInteractable
extends Node3D
## Base interactable: registers its colliders with the XRInteractionManager
## and tracks hover/select/activate state. Emits signals only; visual
## affordances are the consuming scene's responsibility.

const XRInteractionLayerMask := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_interaction_layers.gd")
const XRInteractionManager := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_interaction_manager.gd")

enum ActivationMode {
	DISABLED,
	SELECTED,
	HOVERED,
	HOVERED_OR_SELECTED,
}

signal hover_entered(interactor)
signal hover_exited(interactor)
signal select_entered(interactor)
signal select_exited(interactor)
signal activate_entered(interactor)
signal activate_exited(interactor)
signal activated(interactor)
signal deactivated(interactor)

@export_flags("Layer 1", "Layer 2", "Layer 3", "Layer 4", "Layer 5", "Layer 6", "Layer 7", "Layer 8") var interaction_layers := 1
@export var activation_mode := ActivationMode.SELECTED
## Colliders to register. Empty = auto-collect all CollisionObject3D descendants.
@export var collider_paths: Array[NodePath] = []

var _hovering_interactors: Array[Node] = []
var _selecting_interactor: Node
var _selecting_interactors: Array[Node] = []
var _activating_interactors: Array[Node] = []
var _registered_manager: Node

func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED:
		_register_with_manager()
	elif what == NOTIFICATION_UNPARENTED:
		_unregister_from_manager()
	elif what == NOTIFICATION_CHILD_ORDER_CHANGED and is_inside_tree():
		_register_with_manager(true)

func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return  # @tool subclasses (keyboard preview) must not register in-editor.
	_register_with_manager()

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_register_with_manager(true)

func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	_unregister_from_manager()

func _unregister_from_manager() -> void:
	if _registered_manager and is_instance_valid(_registered_manager):
		_registered_manager.unregister_interactable(self)
	_registered_manager = null

func _register_with_manager(force_refresh := false) -> void:
	var manager = XRInteractionManager.find(self)
	if manager == null:
		push_warning("%s: no XRInteractionManager in the scene tree." % name)
		return
	if manager == _registered_manager:
		# Same manager: a refresh only re-syncs colliders. It must NOT go
		# through unregister_interactable, which tears down active
		# selections (adding a child in a select_entered handler would
		# otherwise cancel the grab it is reacting to).
		if force_refresh:
			manager.refresh_interactable_colliders(self)
		return
	if _registered_manager and is_instance_valid(_registered_manager):
		_registered_manager.unregister_interactable(self)
	_registered_manager = manager
	_registered_manager.register_interactable(self)

func get_colliders() -> Array[CollisionObject3D]:
	var colliders: Array[CollisionObject3D] = []
	if collider_paths.is_empty():
		_collect_colliders(self, colliders)
	else:
		for path in collider_paths:
			var collider := get_node_or_null(path) as CollisionObject3D
			if collider:
				colliders.append(collider)
	return colliders

## How something driving this scene should take hold of it: WHERE to put the
## hand, and WHAT gesture this object expects. Authored drives had to carry both
## as hand-measured constants, and both were routinely wrong in ways nothing
## reported - a hand aimed at a node origin can sit 50 mm inside the object it
## meant to press, and an open hand reaches a grip-style tool forever without
## being offered it. Neither is knowable from outside, so the object says it.
##
## Subclasses override to describe their own affordance. The default is the
## honest one for a plain interactable: the middle of its collider, taken with
## an ordinary grab.
func drive_hint() -> Dictionary:
	return {
		"kind": "grab",
		"gesture": "grab",
		"point": drive_point(),
	}


## The point a hand should occupy to interact. Collider centre rather than node
## origin, because the two differ on almost everything with a body.
func drive_point() -> Vector3:
	var colliders := get_colliders()
	if colliders.is_empty():
		return global_position
	var total := Vector3.ZERO
	for collider in colliders:
		total += (collider as Node3D).global_position
	return total / float(colliders.size())


func is_hovered() -> bool:
	return not _hovering_interactors.is_empty()

func is_selected() -> bool:
	return not _selecting_interactors.is_empty()

func get_selecting_interactor() -> Node:
	return _selecting_interactor

func get_selecting_interactors() -> Array[Node]:
	return _selecting_interactors.duplicate()

func is_activated() -> bool:
	return not _activating_interactors.is_empty()

func get_activating_interactors() -> Array[Node]:
	return _activating_interactors.duplicate()

func can_hover(interactor) -> bool:
	return interactor != null and XRInteractionLayerMask.overlaps(interaction_layers, interactor.interaction_layers)

func can_select(interactor) -> bool:
	return _selecting_interactors.is_empty() and can_hover(interactor)

func can_activate(interactor) -> bool:
	if _activating_interactors.has(interactor) or not can_hover(interactor):
		return false

	match activation_mode:
		ActivationMode.DISABLED:
			return false
		ActivationMode.SELECTED:
			return _selecting_interactors.has(interactor)
		ActivationMode.HOVERED:
			return _hovering_interactors.has(interactor)
		ActivationMode.HOVERED_OR_SELECTED:
			return _hovering_interactors.has(interactor) or _selecting_interactors.has(interactor)
	return false

func _notify_hover_entered(interactor) -> void:
	if _hovering_interactors.has(interactor):
		return
	_hovering_interactors.append(interactor)
	hover_entered.emit(interactor)

func _notify_hover_exited(interactor) -> void:
	if not _hovering_interactors.has(interactor):
		return
	_hovering_interactors.erase(interactor)
	hover_exited.emit(interactor)

func _notify_select_entered(interactor) -> void:
	if _selecting_interactors.has(interactor):
		return
	_selecting_interactors.append(interactor)
	if _selecting_interactor == null:
		_selecting_interactor = interactor
	select_entered.emit(interactor)

func _notify_select_exited(interactor) -> void:
	if not _selecting_interactors.has(interactor):
		return
	_selecting_interactors.erase(interactor)
	if _selecting_interactor == interactor:
		_selecting_interactor = _selecting_interactors[0] if not _selecting_interactors.is_empty() else null
	select_exited.emit(interactor)

func _notify_activate_entered(interactor) -> void:
	if _activating_interactors.has(interactor):
		return
	_activating_interactors.append(interactor)
	activate_entered.emit(interactor)
	activated.emit(interactor)

func _notify_activate_exited(interactor) -> void:
	if not _activating_interactors.has(interactor):
		return
	_activating_interactors.erase(interactor)
	activate_exited.emit(interactor)
	deactivated.emit(interactor)

func _collect_colliders(node: Node, out: Array[CollisionObject3D]) -> void:
	if node is CollisionObject3D:
		out.append(node)
	for child in node.get_children():
		_collect_colliders(child, out)

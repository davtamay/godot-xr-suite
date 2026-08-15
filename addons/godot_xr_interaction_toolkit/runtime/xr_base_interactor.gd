class_name XRBaseInteractor
extends Node3D
## Base interactor: wires an XRInputAdapter's select events to manager-arbitrated
## selection and owns hover-transition bookkeeping. Subclasses compute what is
## hovered and call _set_hovered().

const XRInputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")
const XRInteractionManager := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_interaction_manager.gd")


## Where the hand driving an interactor is, in world space.
##
## Mechanisms (climb, dial, lever, drawer) follow the HAND, not the point the
## ray happens to hit: reeling a far-grabbed object would otherwise move the
## thing you are using while you use it. The ray's own origin is that hand,
## which is why it is preferred over the attach pose.
##
## Static and interactor-typed so an interactable can ask about whichever
## interactor grabbed it without knowing its concrete class.
static func hand_origin_of(interactor: Node) -> Vector3:
    if interactor == null:
        return Vector3.ZERO
    if interactor.has_method(&"get_ray_state"):
        var ray: Dictionary = interactor.get_ray_state()
        if ray.get("valid", false) and ray.has("origin"):
            return ray["origin"]
    if interactor.has_method(&"get_direct_state"):
        var direct: Dictionary = interactor.get_direct_state()
        if direct.get("valid", false) and direct.has("origin"):
            return direct["origin"]
    if interactor.has_method(&"get_attach_pose"):
        return (interactor.get_attach_pose() as Transform3D).origin
    if interactor is Node3D:
        return (interactor as Node3D).global_position
    return Vector3.ZERO

signal hover_entered(interactable)
signal hover_exited(interactable)
signal select_entered(interactable)
signal select_exited(interactable)
signal activate_entered(interactable)
signal activate_exited(interactable)

@export_group("Input")
@export var input_adapter_path: NodePath
@export var hand: XRInputAdapter.Hand = XRInputAdapter.Hand.LEFT

@export_group("Interaction")
@export_flags("Layer 1", "Layer 2", "Layer 3", "Layer 4", "Layer 5", "Layer 6", "Layer 7", "Layer 8") var interaction_layers := 1

var _manager: Node
var _adapter: Node
var _hovered: Node
var _selected: Node
var _activated: Node

func _notification(what: int) -> void:
    if what == NOTIFICATION_PARENTED:
        _resolve_manager()

func _enter_tree() -> void:
    if Engine.is_editor_hint():
        return  # @tool subclasses (socket preview) must not resolve in-editor.
    _resolve_manager()

func _resolve_manager() -> void:
    if Engine.is_editor_hint():
        return
    _manager = XRInteractionManager.find(self)
    if _manager == null:
        push_warning("%s: no XRInteractionManager in the scene tree." % name)

func _is_manager_valid() -> bool:
    return _manager != null and is_instance_valid(_manager)

func _ready() -> void:
    var adapter := get_node_or_null(input_adapter_path)
    if adapter:
        set_input_adapter(adapter)

func _exit_tree() -> void:
    _release_activate()
    _release_select()
    _set_hovered(null)

func set_input_adapter(adapter: Node) -> void:
    if _adapter:
        if _adapter.select_started.is_connected(_on_adapter_select_started):
            _adapter.select_started.disconnect(_on_adapter_select_started)
        if _adapter.select_ended.is_connected(_on_adapter_select_ended):
            _adapter.select_ended.disconnect(_on_adapter_select_ended)
        if _adapter.activate_started.is_connected(_on_adapter_activate_started):
            _adapter.activate_started.disconnect(_on_adapter_activate_started)
        if _adapter.activate_ended.is_connected(_on_adapter_activate_ended):
            _adapter.activate_ended.disconnect(_on_adapter_activate_ended)

    _adapter = adapter
    if _adapter:
        if not _adapter.select_started.is_connected(_on_adapter_select_started):
            _adapter.select_started.connect(_on_adapter_select_started)
        if not _adapter.select_ended.is_connected(_on_adapter_select_ended):
            _adapter.select_ended.connect(_on_adapter_select_ended)
        if not _adapter.activate_started.is_connected(_on_adapter_activate_started):
            _adapter.activate_started.connect(_on_adapter_activate_started)
        if not _adapter.activate_ended.is_connected(_on_adapter_activate_ended):
            _adapter.activate_ended.connect(_on_adapter_activate_ended)

func get_hovered() -> Node:
    return _hovered

func get_selected() -> Node:
    return _selected

func get_activated() -> Node:
    return _activated

## Global-space pose grabbed objects follow. Base: this node's transform.
func get_attach_pose() -> Transform3D:
    return global_transform

func _on_adapter_select_started(event_hand: int) -> void:
    if event_hand != hand:
        return
    _try_select()

func _on_adapter_select_ended(event_hand: int) -> void:
    if event_hand != hand:
        return
    _release_select()

func _on_adapter_activate_started(event_hand: int) -> void:
    if event_hand != hand:
        return
    _try_activate()

func _on_adapter_activate_ended(event_hand: int) -> void:
    if event_hand != hand:
        return
    _release_activate()

func _try_select() -> void:
    if not _is_manager_valid():
        _resolve_manager()
    if _selected or _hovered == null or not _is_manager_valid():
        return
    _manager.request_select(self, _hovered)

func _release_select() -> void:
    if _selected == null:
        return
    if not _is_manager_valid():
        _resolve_manager()
    if _is_manager_valid() and _manager.request_deselect(self):
        return
    # The manager is gone or was rebuilt and never knew this selection: clean
    # up locally so the interactor cannot stay wedged in a selected state.
    var released = _selected
    _selected = null
    if released and is_instance_valid(released):
        released._notify_select_exited(self)
        select_exited.emit(released)

func _try_activate() -> void:
    if not _is_manager_valid():
        _resolve_manager()
    if _activated != null or not _is_manager_valid():
        return

    var target = _selected if _selected != null else _hovered
    if target == null:
        return
    _manager.request_activate(self, target)

func _release_activate() -> void:
    if _activated == null:
        return
    if not _is_manager_valid():
        _resolve_manager()
    if _is_manager_valid() and _manager.request_deactivate(self):
        return
    var released = _activated
    _activated = null
    if released and is_instance_valid(released):
        released._notify_activate_exited(self)
        activate_exited.emit(released)

func _set_hovered(interactable) -> void:
    if interactable == _hovered:
        return
    if _hovered and is_instance_valid(_hovered):
        _hovered._notify_hover_exited(self)
        hover_exited.emit(_hovered)
    _hovered = interactable
    if _hovered:
        _hovered._notify_hover_entered(self)
        hover_entered.emit(_hovered)

func _notify_select_granted(interactable) -> void:
    _selected = interactable
    select_entered.emit(interactable)

func _notify_select_released(interactable) -> void:
    _selected = null
    select_exited.emit(interactable)

func _notify_activate_granted(interactable) -> void:
    _activated = interactable
    activate_entered.emit(interactable)

func _notify_activate_released(interactable) -> void:
    _activated = null
    activate_exited.emit(interactable)

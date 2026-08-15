@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_direct_interactor.svg")
class_name XRDirectInteractor
extends "res://addons/godot_xr_interaction_toolkit/runtime/xr_base_interactor.gd"

## Near-field hand interactor. Uses an overlap sphere at the adapter's grip pose
## to hover/select nearby interactables. This is the Direct Interactor half of
## Unity XRI's near/far setup; XRRayInteractor remains the far interactor.

## Group the arbiter finds these by. A LIVE lookup, not a cached list: this
## node is a rig child, and a rig is rebuilt on every scene change.
const GROUP := "xr_direct_interactor"

@export_group("Direct Hover")
@export_range(0.01, 2.0, 0.01, "or_greater") var hover_radius := 0.16
@export_range(1, 128, 1, "or_greater") var max_results := 16
@export_flags_3d_physics var collision_mask := 1
@export var collide_with_areas := true

@export_group("Grip Grab")
## For objects set to GRIP hand-grab (XRGrabInteractable.hand_grab_style): the
## middle/ring/pinky curl (0..1) at which a bare hand grabs them, leaving the
## index free for a trigger. Controllers ignore this and use the grip button.
@export_range(0.05, 1.0, 0.01) var grip_close := 0.5
## Curl the lower fingers must open back below to release a grip-grabbed object.
@export_range(0.0, 1.0, 0.01) var grip_open := 0.28

# base / knuckle / tip joints per grip finger - curl is the bend between bones.
const _GRIP_FINGERS := [
    [XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
        XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
        XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
    [XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
        XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
        XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
    [XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
        XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
        XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP],
]

var _shape := SphereShape3D.new()
var _direct_state := {"valid": false}
var _attach_pose := Transform3D.IDENTITY
var _grip_armed := true

func _enter_tree() -> void:
    add_to_group(GROUP)

func _physics_process(_delta: float) -> void:
    _update_direct()
    _update_grip_grab()

func get_direct_state() -> Dictionary:
    return _direct_state

func get_attach_pose() -> Transform3D:
    return _attach_pose

func _update_direct() -> void:
    var pose := _get_grip_pose()
    if pose.is_empty():
        _direct_state = {"valid": false}
        if _selected == null:
            _set_hovered(null)
        return

    var origin: Vector3 = pose["origin"]
    var basis: Basis = pose.get("basis", Basis.IDENTITY)
    _attach_pose = Transform3D(basis, origin)

    # While holding a selection the overlap query's result was discarded
    # (hover only updates when unselected) - skip it; the held object IS the
    # hovered one. Mirrors the guard the socket interactor already has.
    var hovered = _selected if _selected != null else _closest_interactable(origin)
    if _selected == null:
        _set_hovered(hovered)

    _direct_state = {
        "valid": true,
        "origin": origin,
        "hovered": hovered,
        "radius": hover_radius,
    }

func _get_grip_pose() -> Dictionary:
    if _adapter == null:
        return {}
    if _adapter.has_method("get_grip_pose"):
        return _adapter.get_grip_pose(hand)
    if _adapter.has_method("get_aim_pose"):
        return _adapter.get_aim_pose(hand)
    return {}

# --- Grip grab (bare hands only) --------------------------------------------
# A GRIP-style object (XRGrabInteractable.hand_grab_style == GRIP) is grabbed by
# curling middle/ring/pinky instead of pinching, so the index stays free to pull
# a trigger. Controllers keep grabbing it with the grip button (see the adapter
# select overrides below).

## True when this hand should use the grip-curl gesture for the given target:
## the target opts into grip-grab AND this hand is a real bare hand (not a
## controller). No modality manager -> assume bare hand (the grip-grab case).
func _grip_grab_active_for(target) -> bool:
    if target == null or not target.has_method("uses_grip_grab") or not target.uses_grip_grab():
        return false
    if XRModalityQuery.is_resolved(self, hand):
        return not XRModalityQuery.is_controller(self, hand)
    return true

func _update_grip_grab() -> void:
    var target = _selected if _selected != null else _hovered
    if not _grip_grab_active_for(target):
        return
    var curl := _grip_curl()
    if curl < 0.0:
        return  # no bare-hand tracking this frame
    if _selected != null:
        if curl <= grip_open:
            _release_select()
        return
    # Not holding: fire once per grip, re-armed after the hand opens.
    if not _grip_armed:
        if curl <= grip_open:
            _grip_armed = true
        return
    if curl >= grip_close:
        _grip_armed = false
        _try_select()

## Average curl (0 straight .. 1 fully curled) of middle/ring/pinky on this hand,
## or -1 if the hand isn't bare-tracked this frame.
func _grip_curl() -> float:
    var tracker := XRHandTrackerResolver.get_tracker(hand)
    if tracker == null:
        return -1.0
    var total := 0.0
    var count := 0
    for joints in _GRIP_FINGERS:
        var ok := true
        for j in joints:
            if not XRHandGestureProvider.joint_position_valid(tracker, j):
                ok = false
                break
        if not ok:
            continue
        var base_p: Vector3 = tracker.get_hand_joint_transform(joints[0]).origin
        var knuckle_p: Vector3 = tracker.get_hand_joint_transform(joints[1]).origin
        var tip_p: Vector3 = tracker.get_hand_joint_transform(joints[2]).origin
        var bone := knuckle_p - base_p
        var finger := tip_p - knuckle_p
        if bone.length_squared() < 0.000001 or finger.length_squared() < 0.000001:
            continue
        total += clampf((bone.normalized().angle_to(finger.normalized()) - 0.2) / 2.0, 0.0, 1.0)
        count += 1
    if count == 0:
        return -1.0
    return total / float(count)

# Pinch must NOT drive grip-objects on bare hands (they grab by the grip gesture
# above). Controllers are unaffected: _grip_grab_active_for -> false for them, so
# the grip button's select/release still works normally.
func _on_adapter_select_started(event_hand: int) -> void:
    if event_hand == hand and _grip_grab_active_for(_hovered):
        return
    super._on_adapter_select_started(event_hand)

func _on_adapter_select_ended(event_hand: int) -> void:
    if event_hand == hand and _grip_grab_active_for(_selected):
        return
    super._on_adapter_select_ended(event_hand)

func _closest_interactable(origin: Vector3):
    if _manager == null:
        _resolve_manager()
    if _manager == null:
        return null

    _shape.radius = hover_radius
    var query := PhysicsShapeQueryParameters3D.new()
    query.shape = _shape
    query.transform = Transform3D(Basis.IDENTITY, origin)
    query.collision_mask = collision_mask
    query.collide_with_areas = collide_with_areas
    query.collide_with_bodies = true

    var hits := get_world_3d().direct_space_state.intersect_shape(query, max_results)
    var best = null
    var best_distance := INF
    for hit in hits:
        var collider = hit.get("collider")
        var interactable = _manager.get_interactable_for_collider(collider)
        if interactable == null or not interactable.can_hover(self):
            continue

        var distance := origin.distance_squared_to((collider as Node3D).global_position)
        if distance < best_distance:
            best_distance = distance
            best = interactable
    return best

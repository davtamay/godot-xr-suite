@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_ray_interactor.svg")
class_name XRRayInteractor
extends "res://addons/godot_xr_interaction_toolkit/runtime/xr_base_interactor.gd"

## Raycasting interactor: hovers the nearest interactable along the adapter's
## aim ray and, while selecting, exposes an attach pose at the captured grab
## distance so XRGrabInteractable can follow the ray.

@export_group("Raycast")
@export_range(0.1, 100.0, 0.1, "or_greater") var max_distance := 6.0
@export_flags_3d_physics var collision_mask := 1
@export var collide_with_areas := true
@export_range(0.0, 20.0, 0.01, "or_greater") var min_grab_distance := 0.25

@export_group("Distance Manipulation")
## While far-grabbing, hand motion along the ray changes the held distance.
## Pulling the hand back along the ray brings the object closer; pushing forward
## moves it away. This approximates XR Interaction Toolkit-style attach
## distance manipulation for hand rays.
@export var enable_motion_distance_manipulation := true
## How much held-object distance changes per metre of hand motion along the ray.
## >1 reels the object in faster than the hand moves, so a short arm pull-back can
## bring a far object to your face — the default is tuned to feel responsive.
@export_range(0.0, 8.0, 0.01, "or_greater") var distance_motion_scale := 3.0
@export_range(0.0, 0.2, 0.001, "or_greater") var distance_motion_deadzone := 0.006
@export var allow_push_distance_manipulation := true
@export_range(0.0, 40.0, 0.1, "or_greater") var max_distance_change_per_second := 12.0
## As you pull a far-grabbed object to within this distance, its pose blends
## from the ray aim into your hand's natural GRIP pose - so it settles into a
## real hold (and grab-point objects orient correctly) instead of staying
## aimed along the ray. Needs a linked near/direct interactor as the grip
## source (suppress_interactor_path). 0 = off (keeps the ray orientation).
@export_range(0.0, 2.0, 0.01) var reel_to_grip_distance := 0.45

@export_group("Suppression")
## Optional linked near/direct interactor. When it is active, this far ray is
## suppressed so one hand does not show or select with near and far at once.
@export var suppress_interactor_path: NodePath
@export var suppress_on_linked_hover := true
@export var suppress_on_linked_select := true
## Also hide the ray while THIS hand's fingertip is within poke reach of a
## panel or pokeable (Meta/Unity near-far switch: no far ray up close).
@export var suppress_on_poke := true
## Hide the ray while THIS hand is aiming a teleport - teleport and the far
## selection ray are mutually exclusive (no two lines from one hand at once).
@export var suppress_on_teleport := true
## During near interaction the ray is HIDDEN (0, default) - clean, no line
## while you poke. Set > 0 to instead SHRINK the ray to a stub of that length
## at the hand (Unity Near-Far look) rather than hiding it fully.
@export var near_stub_length := 0.0
## Unity/Meta hand-ray rule: a BARE HAND only shows the ray when it's tracked and
## in an aim posture (palm facing away from your head). Turn your palm toward your
## face, drop your hand, or lose tracking and the ray hides. Controllers always
## show the ray. OFF by default (always-on ray) - the palm-normal sign wants an
## on-device check before it's trusted as the default; opt in per rig to try it.
@export var hand_ray_requires_aim_pose := false
## How far the palm must turn toward your face before the ray hides (dot of the
## palm normal with the direction to your head). Higher = harder to hide.
@export_range(0.0, 1.0, 0.05) var aim_pose_palm_threshold := 0.35
var _ray_state := {"valid": false}
var _poke_interactor: Node
var _locomotion: Node
var _grab_distance := 0.0
var _grip_latched := false
var _hover_distance := 0.0
var _pending_distance_delta := 0.0
var _attach_pose := Transform3D.IDENTITY
var _suppress_interactor: Node
var _arbiter: XRInteractionArbiter
var _last_ray_origin := Vector3.ZERO
var _last_ray_direction := Vector3.FORWARD
var _has_last_ray_pose := false

func _ready() -> void:
    super()
    _resolve_suppression_interactor()

func _physics_process(delta: float) -> void:
    _update_ray(delta)

## {valid: bool} when inactive, else {valid: true, origin, direction, end,
## hit, hovered}. All vectors are in global space.
func get_ray_state() -> Dictionary:
    return _ray_state

func get_attach_pose() -> Transform3D:
    return _attach_pose

## Unity/Meta hand-ray gate: hide a BARE hand's ray unless it's tracked and the
## palm faces away from the head (an aiming posture). Controllers never gate.
func _suppressed_by_hand_pose() -> bool:
    # Only ever gate a REAL bare hand: a controller, an undetected modality, or a
    # missing manager all keep the ray on (never let this hide a controller ray).
    var manager := get_tree().get_first_node_in_group("xr_input_modality_manager")
    if manager == null or not manager.has_method("get_modality") \
            or int(manager.get_modality(hand)) != 2:  # 2 == HAND
        return false
    if _adapter == null or not _adapter.has_method("get_grip_pose"):
        return false
    var grip: Dictionary = _adapter.get_grip_pose(hand)
    if grip.is_empty():
        return true  # hand not tracked / not in view -> no ray
    var cam := get_viewport().get_camera_3d()
    if cam == null:
        return false
    var palm_pos: Vector3 = grip["origin"]
    # Grip +Y is out of the back of the fist, so the palm faces -Y.
    var palm_facing := -(grip["basis"] as Basis).y
    var to_head := (cam.global_position - palm_pos)
    if to_head.length_squared() < 0.0001:
        return false
    # Palm turned toward your face (menu posture) -> not aiming -> hide the ray.
    return palm_facing.dot(to_head.normalized()) > aim_pose_palm_threshold

func _update_ray(delta := 0.0) -> void:
    var pose: Dictionary = _adapter.get_aim_pose(hand) if _adapter else {}

    if _selected == null and (_is_suppressed_by_linked_interactor() \
            or (hand_ray_requires_aim_pose and _suppressed_by_hand_pose())):
        # Near-far switch (Unity): don't leave a long ray pointing off-angle
        # during near interaction - SHRINK the line to a short stub at the
        # hand (near_stub_length; 0 = hide fully). No far cursor, no select.
        _set_hovered(null)
        _has_last_ray_pose = false
        if pose.is_empty() or near_stub_length <= 0.0:
            _ray_state = {"valid": false, "suppressed": true}
        else:
            var stub_origin: Vector3 = pose["origin"]
            var stub_dir: Vector3 = (pose["direction"] as Vector3).normalized()
            _ray_state = {
                "valid": true, "suppressed": true, "hit": false, "hovered": null,
                "origin": stub_origin, "direction": stub_dir,
                "end": stub_origin + stub_dir * near_stub_length, "grab_distance": 0.0,
            }
        return

    if pose.is_empty():
        _ray_state = {"valid": false}
        if _selected == null:
            _set_hovered(null)
            _has_last_ray_pose = false
        return

    var origin: Vector3 = pose["origin"]
    var direction: Vector3 = (pose["direction"] as Vector3).normalized()
    var pose_basis: Basis = pose.get("basis", Basis.IDENTITY)
    # While far-grabbing, the selected branch below overrides every raycast
    # output (end/hit/hovered) and _hover_distance is only read at select
    # START - the query result is provably discarded, so skip it.
    var hit := {} if _selected != null else _intersect(origin, direction)
    var hit_anything := not hit.is_empty()
    var end := origin + direction * max_distance
    if hit_anything:
        end = hit["position"]

    var hovered = null
    if hit_anything and _manager:
        var interactable = _manager.get_interactable_for_collider(hit["collider"])
        if interactable and interactable.can_hover(self):
            hovered = interactable

    _hover_distance = origin.distance_to(end)
    if _selected == null:
        _set_hovered(hovered)
        _attach_pose = Transform3D(pose_basis, end)
    else:
        if not _grip_latched:
            _apply_motion_distance_manipulation(origin, direction, delta)
        _attach_pose = _resolve_grab_pose(Transform3D(pose_basis, origin + direction * _grab_distance))
        end = _attach_pose.origin
        hit_anything = true
        hovered = _selected
        if _grip_latched:
            # Reeled into the hand: it's a near hold now, so hide the far line
            # and cursor entirely (still selected - the object follows the grip).
            _ray_state = {"valid": false, "suppressed": true}
            _last_ray_origin = origin
            _last_ray_direction = direction
            _has_last_ray_pose = true
            return

    _ray_state = {
        "valid": true,
        "origin": origin,
        "direction": direction,
        "end": end,
        "hit": hit_anything,
        "hovered": hovered,
        "grab_distance": _grab_distance,
    }
    _last_ray_origin = origin
    _last_ray_direction = direction
    _has_last_ray_pose = true

func _intersect(origin: Vector3, direction: Vector3) -> Dictionary:
    var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_distance)
    query.collision_mask = collision_mask
    query.collide_with_areas = collide_with_areas
    query.collide_with_bodies = true
    return get_world_3d().direct_space_state.intersect_ray(query)

func _notify_select_granted(interactable) -> void:
    # Grabbing closer than min_grab_distance keeps the true distance so the
    # object does not pop forward; min_grab_distance only floors pull-ins.
    _grab_distance = minf(_hover_distance, max_distance)
    _pending_distance_delta = 0.0
    _grip_latched = false
    _seed_last_ray_pose_from_state()
    super(interactable)

func _notify_select_released(interactable) -> void:
    super(interactable)
    _pending_distance_delta = 0.0
    _grip_latched = false
    _seed_last_ray_pose_from_state()

func _apply_motion_distance_manipulation(origin: Vector3, _direction: Vector3, delta: float) -> void:
    if not enable_motion_distance_manipulation or not _has_last_ray_pose:
        return

    # The deadzone gates ACCUMULATED motion, not per-frame deltas: slow hand
    # movement adds up instead of being discarded, and the threshold is not
    # frame-rate dependent.
    var movement := origin - _last_ray_origin
    _pending_distance_delta += movement.dot(_last_ray_direction.normalized()) * distance_motion_scale
    if _pending_distance_delta > 0.0 and not allow_push_distance_manipulation:
        _pending_distance_delta = 0.0
        return
    if absf(_pending_distance_delta) < distance_motion_deadzone:
        return

    var step := _pending_distance_delta
    if delta > 0.0 and max_distance_change_per_second > 0.0:
        var max_step := max_distance_change_per_second * delta
        step = clampf(step, -max_step, max_step)

    var floor_distance := minf(min_grab_distance, _grab_distance)
    var previous := _grab_distance
    _grab_distance = clampf(_grab_distance + step, floor_distance, max_distance)
    _pending_distance_delta -= _grab_distance - previous
    if is_equal_approx(_grab_distance, floor_distance) or is_equal_approx(_grab_distance, max_distance):
        _pending_distance_delta = 0.0

## Reel-to-hand with LATCH: the closer a far-grabbed object is pulled, the more
## its pose blends into the linked interactor's grip pose; once it fully arrives
## it LATCHES into the hand (a real hold) and no longer reels back out along the
## ray - you have to let go to release it. Returns the ray pose unchanged when
## disabled or there is no grip source.
func _resolve_grab_pose(ray_attach: Transform3D) -> Transform3D:
    var grip := _grip_pose()
    if reel_to_grip_distance <= 0.0 or not grip.get("valid", false):
        return ray_attach
    if _grip_latched:
        return grip["pose"]
    var floor_distance := minf(min_grab_distance, _grab_distance)
    if reel_to_grip_distance <= floor_distance:
        return ray_attach
    var t := clampf(inverse_lerp(reel_to_grip_distance, floor_distance, _grab_distance), 0.0, 1.0)
    if t >= 0.999:
        _grip_latched = true
        return grip["pose"]
    if t <= 0.0:
        return ray_attach
    return ray_attach.interpolate_with(grip["pose"], t)


## The linked near/direct interactor's grip pose, our blend/latch target.
func _grip_pose() -> Dictionary:
    if _suppress_interactor == null or not is_instance_valid(_suppress_interactor):
        _resolve_suppression_interactor()
    if _suppress_interactor == null or not _suppress_interactor.has_method("get_attach_pose"):
        return {"valid": false}
    return {"valid": true, "pose": _suppress_interactor.get_attach_pose()}


func _seed_last_ray_pose_from_state() -> void:
    if not _ray_state.get("valid", false):
        _has_last_ray_pose = false
        return
    _last_ray_origin = _ray_state["origin"]
    _last_ray_direction = (_ray_state["direction"] as Vector3).normalized()
    _has_last_ray_pose = true

## Cached because it is consulted every physics frame; re-resolved if the node
## goes away, so a scene that adds or removes the arbiter at runtime still
## behaves correctly rather than holding a freed reference.
func _resolve_arbiter() -> XRInteractionArbiter:
    if _arbiter != null and is_instance_valid(_arbiter):
        return _arbiter
    _arbiter = XRInteractionArbiter.find_in_tree(self)
    return _arbiter

func _resolve_suppression_interactor() -> void:
    _suppress_interactor = null
    if suppress_interactor_path.is_empty():
        return
    _suppress_interactor = get_node_or_null(suppress_interactor_path)

func _is_suppressed_by_linked_interactor() -> bool:
    # The arbiter owns this decision: one rule in one place. The shipped rig
    # carries one, which is why the suppress_on_* exports below are no longer
    # wired there. They remain for scenes that build their own rig without an
    # arbiter -- NOT as a parallel system, but as the answer for a rig that has
    # not adopted one.
    var arbiter := _resolve_arbiter()
    if arbiter != null:
        return not arbiter.is_mode_active(hand, XRInteractionArbiter.Mode.FAR)

    # Near a pokeable/panel: hide the far ray (near-far switch). Independent of
    # the linked-direct path, so it works even without a direct interactor.
    if suppress_on_poke and _is_poking():
        return true

    # Aiming a teleport: teleport arc and far ray are mutually exclusive.
    if suppress_on_teleport and _is_teleporting():
        return true

    if suppress_interactor_path.is_empty():
        return false
    if _suppress_interactor == null or not is_instance_valid(_suppress_interactor):
        _resolve_suppression_interactor()
    if _suppress_interactor == null:
        return false

    if suppress_on_linked_select and _suppress_interactor.has_method("get_selected") and _suppress_interactor.get_selected() != null:
        return true
    if suppress_on_linked_hover and _suppress_interactor.has_method("get_hovered") and _suppress_interactor.get_hovered() != null:
        return true
    return false

func _is_poking() -> bool:
    if _poke_interactor == null or not is_instance_valid(_poke_interactor):
        _poke_interactor = get_tree().get_first_node_in_group("xr_poke_interactor")
    return _poke_interactor != null and _poke_interactor.has_method("is_poking") \
        and _poke_interactor.is_poking(hand)

func _is_teleporting() -> bool:
    if _locomotion == null or not is_instance_valid(_locomotion):
        _locomotion = get_tree().get_first_node_in_group("xr_locomotion")
    return _locomotion != null and _locomotion.has_method("is_aiming") \
        and _locomotion.is_aiming(hand)

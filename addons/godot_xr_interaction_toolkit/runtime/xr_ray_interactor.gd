@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_ray_interactor.svg")
class_name XRRayInteractor
extends "res://addons/godot_xr_interaction_toolkit/runtime/xr_base_interactor.gd"

## Raycasting interactor: hovers the nearest interactable along the adapter's
## aim ray and, while selecting, exposes an attach pose at the captured grab
## distance so XRGrabInteractable can follow the ray.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

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
## A held object this close to the hand is NEAR interaction, so the ray and its
## cursor stand down even though this ray is what is holding it -- reeling
## something into your hand should not leave a ray drawn through it. The grab
## itself is untouched; only the visual and the hover/cursor stop. 0 disables.
##
## CONSTRAINT, ENCODED: XRGrabInteractable.far_grab_attract_standoff (default
## 0.12 m) must stay strictly LESS than this (default 0.25 m) -- ATTRACT
## delivers a free-grabbed object to a point this many metres forward of the
## SAME adapter grip origin this threshold measures against, so raising this
## value, or far_grab_attract_standoff, without checking the other can put a
## held object back outside the hide radius and leave a ray drawn at it.
## test_far_grab_modes.gd asserts the relationship between the two shipped
## defaults directly.
@export_range(0.0, 1.0, 0.01) var hide_ray_when_held_within := 0.25
## Unity/Meta hand-ray rule: a BARE HAND only shows the ray when it's tracked and
## in an aim posture (palm facing away from your head). Turn your palm toward your
## face, drop your hand, or lose tracking and the ray hides. Controllers always
## show the ray. OFF by default (always-on ray) - the palm-normal sign wants an
## on-device check before it's trusted as the default; opt in per rig to try it.
@export var hand_ray_requires_aim_pose := false
## How far the palm must turn toward your face before the ray hides (dot of the
## palm normal with the direction to your head). Higher = harder to hide.
@export_range(0.0, 1.0, 0.05) var aim_pose_palm_threshold := 0.35
## OpenXR sets HAND_JOINT_FLAG_POSITION_VALID on a joint it is PREDICTING, and
## HAND_JOINT_FLAG_POSITION_TRACKED only on one it is actually OBSERVING - a
## hand out of view keeps publishing valid-looking extrapolated poses, which is
## why an untracked hand's ray "goes all over the place" instead of going away.
## When true, this ray hides itself once its aim joint (wrist, falling back to
## palm - the same anchor xr_hand_gesture_provider.gd's get_hand_ray_pose calls
## `back`) has been VALID-but-not-TRACKED for longer than
## untracked_hand_hold_sec. Reads XRHandTrackerResolver directly (the same way
## xr_pinch_twist_distance_driver.gd already does) rather than going through
## the modality manager, so it is inert - never true - for a controller (no
## hand tracker ever resolves for that hand) and needs no dependency this ray
## does not already have.
@export var suppress_when_aim_joint_untracked := true
## How long the aim joint must stay VALID-but-not-TRACKED before the ray
## suppresses. Absorbs a single dropped tracking frame (a real hand blinking
## out for one sample) without strobing the ray; a hand genuinely out of view
## stays untracked well past this. Order-of-magnitude - a fraction of a
## second - not device-tuned, the same idea xr_hand_confidence_gate.gd's
## hold_duration_sec encodes for the pose pipeline (not a dependency on that
## gate itself).
@export_range(0.0, 1.0, 0.01) var untracked_hand_hold_sec := 0.12
var _ray_state := {"valid": false}
## Live-diagnosis aid: prints when THIS ray starts or stops being suppressed,
## with the reason. Change-gated. Paired with XRInteractionArbiter.debug_log.
@export var debug_log := false
var _debug_last_suppressed := -1
var _debug_pose_was_empty := false
var _poke_interactor: Node
var _locomotion: Node
var _grab_distance := 0.0
var _far_grab_mode := XRGrabInteractable.FarGrabMode.ATTRACT
var _grip_latched := false
var _hover_distance := 0.0
var _pending_distance_delta := 0.0
var _attach_pose := Transform3D.IDENTITY
var _suppress_interactor: Node
var _arbiter: XRInteractionArbiter
var _last_ray_origin := Vector3.ZERO
var _last_ray_direction := Vector3.FORWARD
var _has_last_ray_pose := false
## The reel projection axis, captured once at select and never updated again
## while held - unlike _last_ray_direction, which _update_ray refreshes every
## frame. Aiming and reeling are decoupled by using this instead of the live
## direction: hand motion is measured against where the ray pointed AT SELECT,
## not wherever it happens to be pointing this frame.
var _reel_axis := Vector3.FORWARD
## Accumulated seconds the aim joint has been observed VALID-but-not-TRACKED,
## reset to 0 the instant it is either TRACKED or not a resolvable hand at
## all. See _aim_joint_untracked_past_hold.
var _aim_untracked_elapsed := 0.0

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

## The adapter's own grip pose for this ray's hand -- the physical
## hand/controller transform, independent of anything about the ray itself
## (raycast distance, hover state, selection, _grab_distance). This is what
## XRGrabInteractable's ATTRACT far-grab path delivers the object onto: it
## needs no scene wiring, unlike _resolve_grab_pose's reel-to-grip blend
## (suppress_interactor_path), which is set in no scene in this repository
## and so never actually fires (see docs/far-grab-modes-design.md's
## amendment). {"valid": false} when there is no adapter, or the adapter has
## no grip pose to report (hand/controller not tracked).
func get_hand_grip_pose() -> Dictionary:
    if _adapter == null or not _adapter.has_method("get_grip_pose"):
        return {"valid": false}
    var grip: Dictionary = _adapter.get_grip_pose(hand)
    if grip.is_empty():
        return {"valid": false}
    return {"valid": true, "origin": grip["origin"], "basis": grip.get("basis", Basis.IDENTITY)}

## The current held distance along the ray. Public so a mode-aware
## interactable (or a phase-2 distance driver) can read the ray's own state
## rather than each keeping a shadow copy.
func get_grab_distance() -> float:
    return _grab_distance

## Public mutator for the ray's distance state, clamped the same way the
## internal reel path clamps it. This is phase 2's entry point (a pinch/twist
## driver adjusting distance while FIXED or REEL is held) - it exists now so
## there is exactly one place that owns the clamp arithmetic.
func adjust_grab_distance(delta: float) -> void:
    _grab_distance = _clamp_grab_distance(_grab_distance + delta)

## Grabbing closer than min_grab_distance keeps the true distance so the
## object does not pop forward; min_grab_distance only floors pull-ins. Shared
## by the reel path and the public adjust_grab_distance() mutator so there is
## exactly one place computing this clamp.
func _clamp_grab_distance(value: float) -> float:
    var floor_distance := minf(min_grab_distance, _grab_distance)
    return clampf(value, floor_distance, max_distance)

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

## True once this hand's aim joint has been reporting POSITION_VALID without
## POSITION_TRACKED for longer than untracked_hand_hold_sec -- the OpenXR
## "predicting, not observing" signal a hand out of view keeps sending
## forever, which is what made an unseen hand's ray flail with the
## extrapolation instead of disappearing. Reads XRHandTrackerResolver
## directly, exactly the way xr_pinch_twist_distance_driver.gd already reads
## the wrist for TWIST, so it is inert (never true) for a controller: no hand
## tracker ever resolves for that hand, has_tracking_data is false, or the
## joint itself never reports POSITION_VALID at all in the first place.
func _aim_joint_untracked_past_hold(delta: float) -> bool:
    var tracker := XRHandTrackerResolver.get_tracker(hand)
    if tracker == null or not tracker.has_tracking_data:
        _aim_untracked_elapsed = 0.0
        return false
    var joint := XRHandTracker.HAND_JOINT_WRIST
    if not XRHandTrackerResolver.joint_position_valid(tracker, joint):
        joint = XRHandTracker.HAND_JOINT_PALM
    if XRHandTrackerResolver.joint_position_tracked(tracker, joint):
        _aim_untracked_elapsed = 0.0
        return false
    _aim_untracked_elapsed += maxf(delta, 0.0)
    return _aim_untracked_elapsed >= untracked_hand_hold_sec

func _update_ray(delta := 0.0) -> void:
    # A selection the input no longer backs is STALE, and it is silently
    # crippling: with _selected set, the ray skips hovering entirely and runs
    # its held-object branch, so it stops responding to anything until some
    # later release happens to clear it. Reconcile against the input instead of
    # waiting for that -- David, on device: the right ray would not hover or
    # select "until i do random pinching gestures and out of nowhere it starts
    # working", which is that stray release arriving.
    if _selected != null and _adapter != null and not _adapter.is_select_down(hand):
        _release_select()

    var pose: Dictionary = _adapter.get_aim_pose(hand) if _adapter else {}

    var linked_suppressed := _is_suppressed_by_linked_interactor()
    var held_near := _held_object_is_in_hand()
    var pose_suppressed: bool = hand_ray_requires_aim_pose and _suppressed_by_hand_pose()
    # Independent of hold state (unlike the clause below): a hand that is not
    # genuinely tracked should not keep steering an active far-grab any more
    # than it should keep hovering, so this is OR'd in unconditionally rather
    # than gated by `_selected == null or held_near`.
    var aim_untracked: bool = suppress_when_aim_joint_untracked and _aim_joint_untracked_past_hold(delta)
    var suppressed: bool = aim_untracked \
            or ((_selected == null or held_near) \
                    and (linked_suppressed or held_near or pose_suppressed))
    if debug_log and int(suppressed) != _debug_last_suppressed:
        _debug_last_suppressed = int(suppressed)
        var dbg := _resolve_arbiter()
        print("[ray] hand=%d suppressed=%s | linked=%s held_near=%s pose_gate=%s aim_untracked=%s selected=%s pose_empty=%s | arbiter=%s" % [
            hand, suppressed, linked_suppressed, held_near, pose_suppressed, aim_untracked,
            _selected != null, pose.is_empty(),
            "none" if dbg == null else dbg._mode_name(dbg.mode_for(hand))])
    if debug_log and pose.is_empty() != _debug_pose_was_empty:
        _debug_pose_was_empty = pose.is_empty()
        print("[ray] hand=%d aim_pose_empty=%s (empty means no ray and no hover at all)" % [hand, pose.is_empty()])
    if suppressed:
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
        # grip_latched used to be reported here for the line visual to hide
        # on. Removed: it could never be observed true (the moment
        # _grip_latched flips, the early-return above already replaces
        # _ray_state with {"valid": false, ...} before this dict is ever
        # built - confirmed empirically, see far-grab-guards-report.md) and
        # it duplicated hide_ray_when_held_within (_held_object_is_in_hand,
        # commit 2944a22, predating this branch), which hides the ray by
        # comparing the held object's actual position against the adapter's
        # real grip origin - a signal that works whether or not the
        # reel-to-grip latch ever fires at all.
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
    var hit_distance := minf(_hover_distance, max_distance)
    # An interactable with no far_grab_mode is NOT a far-grabbable - it is a UI
    # panel, a socket, or anything else this ray can select - and it must be
    # left alone. Defaulting the absent case to ATTRACT collapsed the ray's
    # attach distance to min_grab_distance the moment a UI button was pressed,
    # dragging the cursor to the hand and making every menu unusable. The
    # ATTRACT default lives on XRGrabInteractable's own export, which is where
    # it reaches real grabbables; the fallback here only has to be inert.
    _far_grab_mode = interactable.far_grab_mode if interactable != null and "far_grab_mode" in interactable else XRGrabInteractable.FarGrabMode.FIXED
    if _far_grab_mode == XRGrabInteractable.FarGrabMode.ATTRACT:
        # ATTRACT sets the held distance to the same floor the reel-to-grip
        # path already uses, so the existing transit tween carries the object
        # in and the existing grip latch holds it - no new motion path.
        _grab_distance = minf(min_grab_distance, hit_distance)
    else:
        _grab_distance = hit_distance
    _pending_distance_delta = 0.0
    _grip_latched = false
    _seed_last_ray_pose_from_state()
    # Freeze the reel axis at the moment of select, from whatever ray
    # direction was last observed - aiming after this point must not change
    # what "pull" means.
    _reel_axis = _last_ray_direction
    super(interactable)

func _notify_select_released(interactable) -> void:
    super(interactable)
    _pending_distance_delta = 0.0
    _grip_latched = false
    _far_grab_mode = XRGrabInteractable.FarGrabMode.ATTRACT
    _reel_axis = Vector3.FORWARD
    _seed_last_ray_pose_from_state()

func _apply_motion_distance_manipulation(origin: Vector3, _direction: Vector3, delta: float) -> void:
    # Reeling is a REEL-only behaviour now; ATTRACT and FIXED never wind
    # distance in or out from hand motion.
    if _far_grab_mode != XRGrabInteractable.FarGrabMode.REEL:
        return
    if not enable_motion_distance_manipulation or not _has_last_ray_pose:
        return

    # The deadzone gates ACCUMULATED motion, not per-frame deltas: slow hand
    # movement adds up instead of being discarded, and the threshold is not
    # frame-rate dependent.
    var movement := origin - _last_ray_origin
    # Projected onto the axis frozen at select (_reel_axis), NOT the live
    # _last_ray_direction: re-aiming mid-pull must not change what "pull"
    # means. _last_ray_origin is still what pairs with `movement` here.
    _pending_distance_delta += movement.dot(_reel_axis) * distance_motion_scale
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
    _grab_distance = _clamp_grab_distance(_grab_distance + step)
    _pending_distance_delta -= _grab_distance - previous
    if is_equal_approx(_grab_distance, floor_distance) or is_equal_approx(_grab_distance, max_distance):
        _pending_distance_delta = 0.0

## Reel-to-hand with LATCH: the closer a far-grabbed object is pulled, the more
## its pose blends into the linked interactor's grip pose; once it fully arrives
## it LATCHES into the hand (a real hold) and no longer reels back out along the
## ray - you have to let go to release it. Returns the ray pose unchanged when
## disabled or there is no grip source.
##
## FIXED is gated out entirely: "never reels, never attracts" means the ray
## pose is the whole story, so a FIXED object grabbed within
## reel_to_grip_distance must not blend or latch into the grip either -
## otherwise anything grabbed close would silently behave like ATTRACT. Reads
## the mode cached at select (_far_grab_mode) rather than the interactable
## itself, since this runs every frame.
func _resolve_grab_pose(ray_attach: Transform3D) -> Transform3D:
    if _far_grab_mode == XRGrabInteractable.FarGrabMode.FIXED:
        return ray_attach
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

## True when this ray is holding something that has ended up within arm's reach
## -- a far grab reeled in, or an object handed over. At that point it is near
## interaction by any sensible reading, so the ray should not still be drawn
## through the thing in your hand.
func _held_object_is_in_hand() -> bool:
    if _selected == null or hide_ray_when_held_within <= 0.0 or _adapter == null:
        return false
    var target: Node3D = null
    if _selected.has_method("get_target"):
        target = _selected.get_target() as Node3D
    else:
        target = _selected as Node3D
    if target == null:
        return false
    var grip: Dictionary = _adapter.get_grip_pose(hand)
    if grip.is_empty():
        return false
    return (grip["origin"] as Vector3).distance_to(target.global_position) <= hide_ray_when_held_within


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

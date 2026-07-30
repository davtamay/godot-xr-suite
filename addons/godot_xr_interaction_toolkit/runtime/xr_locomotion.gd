@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg")
class_name XRLocomotion
extends Node

## Drop-in teleport + snap-turn locomotion (Unity XRI's locomotion system as
## one block). Push a thumbstick FORWARD to aim a teleport arc - release to
## teleport where the marker lands (upward-facing physics surfaces only).
## Flick a thumbstick LEFT/RIGHT to snap-turn.
##
## Works with controllers on both WebXR and OpenXR (the kit's action map binds
## "thumbstick"; the browser maps it natively). Bare-hand teleport gestures are
## a future upgrade - hands keep pinch/grab interaction unaffected.
##
## Built into WebXRRig, so every rig/prefab scene can teleport BY DEFAULT -
## scenes without physics floors simply never produce a valid arc target.

## Fired after a successful teleport (positions are global).
signal teleported(from: Vector3, to: Vector3)
## Aiming lifecycle (both the thumbstick and the intent-API paths):
## teleport_cancelled = the aim ended WITHOUT a teleport (teleported covers
## the success case).
signal teleport_aim_started(hand: int)
signal teleport_cancelled(hand: int)
## Fired after a snap turn (positive = counter-clockwise).
signal snap_turned(degrees: float)

const _LINE_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_line_material.tres")
const _RETICLE_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_reticle_material.tres")
const XRHandGestureProvider := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_gesture_provider.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## Group external drivers use to find the locomotion system.
const GROUP := "xr_locomotion"

const _ARC_STEP_SECONDS := 0.05
const _ARC_MAX_STEPS := 40

## Master switch: off = no teleport, no snap turn, visuals hidden.
@export var enabled := true

@export_group("Rig")
## All optional: empty paths self-resolve (drop the node anywhere in a scene
## with an XR rig and it wires itself).
@export var xr_origin_path: NodePath
@export var camera_path: NodePath
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath

@export_group("Teleport")
@export var teleport_enabled := true
## Only teleport to XRTeleportAnchor pads - free ground is not a valid target.
## Use it for guided, station-to-station layouts (a workshop, a gallery).
@export var anchors_only := false
## Initial arc speed; higher = flatter, longer reach (~6 m/s reaches ~4 m).
@export_range(2.0, 15.0, 0.5) var arc_velocity := 7.0
## Surfaces steeper than this (1 = flat floor) are not teleport targets.
@export_range(0.0, 1.0, 0.05) var min_ground_normal_y := 0.7
@export_flags_3d_physics var collision_mask := 1

@export_group("Snap Turn")
@export var snap_turn_enabled := true
@export_range(15.0, 90.0, 15.0) var snap_turn_degrees := 45.0

@export_group("Directional Teleport")
## Unity-style: while aiming, the THUMBSTICK direction sets which way you'll
## FACE when you land (a facing arrow shows on the reticle). The controller
## still aims WHERE you land; the stick only chooses the facing. Turns snap
## turn OFF (the stick now means "facing"). An anchor with force_facing still
## wins. Off = classic forward-to-aim + left/right snap turn.
@export var directional_teleport := false

@export_group("Appearance")
## Teleport marker colour on valid ground / invalid target.
@export var valid_color := Color(0.25, 1.0, 0.5, 0.9)
@export var invalid_color := Color(1.0, 0.35, 0.3, 0.7)
## Teleport target ring inner/outer radius (metres).
@export var marker_inner_radius := 0.16
@export var marker_outer_radius := 0.22

@export_group("Feel")
## Thumbstick push to START aiming a teleport / snap turn, and to RELEASE it
## (hysteresis so it does not chatter at the edge).
@export_range(0.1, 1.0, 0.05) var stick_engage := 0.65
@export_range(0.05, 1.0, 0.05) var stick_release := 0.3

var _origin: Node3D
var _camera: Node3D
var _controllers: Array[XRController3D] = [null, null]
var _teleport_hand := -1
var _intent_aim := false
var _intent_time := 0.0
var _target_valid := false
var _last_aim_hand := -1
var _committed_teleport := false
var _target_point := Vector3.ZERO
var _target_anchor: XRTeleportAnchor = null
var _highlighted_anchor: XRTeleportAnchor = null
var _target_facing := Vector3.ZERO
var _has_target_facing := false
var _reticle_arrow: Node3D
var _snap_armed := [true, true]
var _arc_visual: MeshInstance3D
var _arc_mesh := ImmediateMesh.new()
var _target_visual: MeshInstance3D

## External aim that never commits auto-cancels after this long.
const _INTENT_TIMEOUT := 3.0


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
	_build_visuals()


func _get_configuration_warnings() -> PackedStringArray:
	return PackedStringArray()  # Paths self-resolve; nothing to warn about.


func _physics_process(delta: float) -> void:
	if not enabled or _origin == null or _camera == null:
		if _intent_aim:
			# Disabled mid-aim: end the aim rather than suspend it, or the
			# arc pops back on re-enable pointing at a stale target.
			cancel_teleport()
		_hide_visuals()
		return
	# Externally driven aim (microgestures, custom gestures, UI): the SAME
	# arc + marker, aimed by the hand ray when no controller is in that hand.
	if _intent_aim and _teleport_hand >= 0:
		_intent_time += delta
		if _intent_time > _INTENT_TIMEOUT:
			cancel_teleport()
		else:
			_project_intent_arc(_teleport_hand)
	for hand in 2:
		var controller := _controllers[hand]
		if controller == null or not controller.get_is_active():
			if _teleport_hand == hand and not _intent_aim:
				_cancel_teleport()
			continue
		# A continuous-move block can own a hand's stick (smooth walk/turn);
		# don't also teleport/snap-turn on it.
		if _hand_claimed_by_continuous_move(hand):
			continue
		var stick := controller.get_vector2(&"thumbstick")
		if not _intent_aim:
			_update_teleport(hand, controller, stick)
		_update_snap_turn(hand, stick)
	# Observability latch: both the stick and intent paths set/clear
	# _teleport_hand, so aim start/cancel signals come from watching the
	# transition - no flow changes. teleported (in _teleport_to) marks the
	# commit case so a successful teleport doesn't also read as cancelled.
	if _teleport_hand != _last_aim_hand:
		if _teleport_hand >= 0:
			teleport_aim_started.emit(_teleport_hand)
		elif not _committed_teleport:
			teleport_cancelled.emit(_last_aim_hand)
		_last_aim_hand = _teleport_hand
	_committed_teleport = false


## ---- intent API (external drivers: microgestures, gestures, UI) --------------

## Start aiming the teleport arc for a hand (0/1). Aims from the controller
## when one is held, else from the HAND RAY - same visuals as the thumbstick.
func begin_teleport_aim(hand: int) -> void:
	if not teleport_enabled or hand < 0 or hand > 1:
		return
	if _intent_aim and _teleport_hand >= 0 and _teleport_hand != hand:
		# Hand handoff: close the first hand's aim OBSERVABLY and kill its
		# target. Silently reassigning left the old arc's consumers (ray
		# suppression, UI) latched forever, and a commit racing the handoff
		# could land on the FIRST hand's target.
		teleport_cancelled.emit(_teleport_hand)
		_target_valid = false
		_target_anchor = null
	_teleport_hand = hand
	_intent_aim = true
	_intent_time = 0.0


## Keep-alive for an externally driven aim. The intent timeout exists to
## bound an ABANDONED aim, but it cannot tell abandonment from patience: a
## user holding the aiming posture for longer than the window lost the arc
## mid-aim ("we maintain the gesture and we just lose the teleportation
## arc", on device 2026-07-30). A driver that can POSITIVELY see the aiming
## posture still held calls this each frame; the timeout then only reaps
## aims whose posture has been gone or unknowable for the full window.
## Deliberately requires the hand to match: a keep-alive must not extend an
## aim that was handed off to the other hand in the meantime.
func refresh_teleport_aim(hand: int) -> void:
	if _intent_aim and _teleport_hand == hand:
		_intent_time = 0.0


## Teleport to the current marker if valid (ends the aim either way).
func commit_teleport(hand: int = -1) -> void:
	if not _intent_aim or (hand >= 0 and hand != _teleport_hand):
		return
	var commit := _target_valid
	var target := _target_point
	var anchor := _target_anchor
	_intent_aim = false
	_cancel_teleport()
	if commit:
		_teleport_to(target, anchor)


func cancel_teleport(hand: int = -1) -> void:
	if hand >= 0 and hand != _teleport_hand:
		return
	_intent_aim = false
	_cancel_teleport()


func is_aiming(hand: int = -1) -> bool:
	if _teleport_hand < 0:
		return false
	return hand < 0 or hand == _teleport_hand


## Snap turn; direction > 0 turns left (counter-clockwise).
func do_snap_turn(direction: float) -> void:
	if not snap_turn_enabled:
		return
	if _intent_aim:
		# A turn is a statement the user is not mid-teleport. The hands-addon
		# locomotion binding already cancels here; without the same rule this
		# path rotated the rig under a live arc and left it drawn.
		cancel_teleport()
	_apply_snap_turn(snap_turn_degrees * signf(direction))


## ---- teleport ---------------------------------------------------------------

func _update_teleport(hand: int, controller: XRController3D, stick: Vector2) -> void:
	if not teleport_enabled:
		return
	# Directional mode engages/holds on stick MAGNITUDE (the angle is free to
	# pick a facing); classic mode uses forward-push (left/right = snap turn).
	var can_engage := stick.length() > stick_engage if directional_teleport \
		else (stick.y > stick_engage and absf(stick.x) < stick_engage)
	if _teleport_hand == -1 and can_engage:
		_teleport_hand = hand
	if _teleport_hand != hand:
		return

	var holding := stick.length() > stick_release if directional_teleport else stick.y > stick_release
	if holding:
		_project_arc(controller)
		if directional_teleport:
			_compute_directional_facing(stick)
		return

	# Stick released: commit if the marker was on valid ground (or an anchor).
	var commit := _target_valid
	var target := _target_point
	var anchor := _target_anchor
	var facing := _target_facing if _has_target_facing else Vector3.ZERO
	_cancel_teleport()
	if commit:
		_teleport_to(target, anchor, facing)


func _teleport_to(target: Vector3, anchor: XRTeleportAnchor = null, facing: Vector3 = Vector3.ZERO) -> void:
	var from := _camera.global_position
	# Move the origin so the CAMERA lands on the target horizontally and the
	# play space floor lands at the target height - the user's offset inside
	# the play space is preserved.
	var camera_floor := Vector3(_camera.global_position.x, _origin.global_position.y, _camera.global_position.z)
	_origin.global_position += target - camera_floor
	# Anchors can force a facing: yaw the rig (around the now-moved camera) so
	# the user looks along the anchor's forward.
	# Facing precedence: a force_facing anchor is the author's intent and wins;
	# otherwise directional teleport's stick-chosen facing (if any) applies.
	if anchor and is_instance_valid(anchor) and anchor.wants_facing():
		_face_direction(anchor.facing_forward())
	elif facing.length_squared() > 0.0001:
		_face_direction(facing)
	_committed_teleport = true
	teleported.emit(from, _camera.global_position)


func _project_arc(controller: XRController3D) -> void:
	var start := controller.global_transform.origin
	var direction := -controller.global_transform.basis.z
	_project_arc_from(start, direction)


## Aim from the hand ray (bare hand) or the controller, whichever is live.
func _project_intent_arc(hand: int) -> void:
	var controller := _controllers[hand]
	if controller and controller.get_is_active() and controller.get_has_tracking_data():
		_project_arc(controller)
		return
	var tracker := XRHandTrackerResolver.get_tracker(hand)
	var local_ray := XRHandGestureProvider.get_hand_ray_pose(tracker)
	if local_ray.is_empty():
		# No pose to aim with: the target dies WITH the visuals. Hiding the
		# arc while keeping _target_valid let a commit arriving in this
		# window teleport to wherever the arc last pointed -- on device,
		# "teleport comes out of nowhere".
		_target_valid = false
		_target_anchor = null
		_hide_visuals()
		return
	var origin_xf := _origin.global_transform
	var start: Vector3 = origin_xf * (local_ray["origin"] as Vector3)
	var direction := (origin_xf.basis * (local_ray["direction"] as Vector3)).normalized()
	_project_arc_from(start, direction)


func _project_arc_from(start: Vector3, direction: Vector3) -> void:
	var space := _origin.get_world_3d().direct_space_state
	var point := start
	var velocity := direction * arc_velocity
	var points := PackedVector3Array([point])
	_target_valid = false
	_target_anchor = null

	for step in _ARC_MAX_STEPS:
		var next := point + velocity * _ARC_STEP_SECONDS
		velocity += Vector3(0.0, -9.8, 0.0) * _ARC_STEP_SECONDS
		var query := PhysicsRayQueryParameters3D.create(point, next, collision_mask)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			points.append(hit["position"])
			var anchor := _anchor_from_hit(hit)
			if anchor:
				# Discrete destination: snap to the anchor's exact point,
				# always valid regardless of the surface normal.
				_target_anchor = anchor
				_target_point = anchor.snap_position()
				_target_valid = true
			else:
				# Free ground: valid only if flat enough - and only at all when
				# not restricted to anchor pads.
				_target_valid = not anchors_only and (hit["normal"] as Vector3).y >= min_ground_normal_y
				_target_point = hit["position"]
			break
		points.append(next)
		point = next

	_draw_arc(points)


## True if a continuous-move block drives this hand's stick (walk/turn), so
## teleport + snap turn should stay off it.
func _hand_claimed_by_continuous_move(hand: int) -> bool:
	for mover in get_tree().get_nodes_in_group("xr_continuous_move"):
		if mover.has_method("get_claimed_hands") and hand in mover.get_claimed_hands():
			return true
	return false


## Return the XRTeleportAnchor owning a ray hit's collider, or null.
func _anchor_from_hit(hit: Dictionary) -> XRTeleportAnchor:
	var collider = hit.get("collider")
	if collider and collider.has_meta("xr_teleport_anchor"):
		var anchor = collider.get_meta("xr_teleport_anchor")
		if anchor is XRTeleportAnchor and is_instance_valid(anchor) and anchor.enabled:
			return anchor
	return null


func _cancel_teleport() -> void:
	_teleport_hand = -1
	_intent_aim = false
	_target_valid = false
	_target_anchor = null
	_target_facing = Vector3.ZERO
	_has_target_facing = false
	_hide_visuals()


## Facing (world direction) chosen by the thumbstick angle while aiming: push
## forward = keep current facing, rotate the stick = turn the landing facing.
func _compute_directional_facing(stick: Vector2) -> void:
	var cam_forward := -_camera.global_transform.basis.z
	cam_forward.y = 0.0
	if cam_forward.length_squared() < 0.0001:
		return
	var angle := atan2(stick.x, stick.y)
	_target_facing = (Basis(Vector3.UP, -angle) * cam_forward.normalized()).normalized()
	_has_target_facing = true


## ---- snap turn --------------------------------------------------------------

func _update_snap_turn(hand: int, stick: Vector2) -> void:
	# Directional teleport consumes the stick angle for facing - no snap turn.
	if not snap_turn_enabled or directional_teleport:
		return
	if absf(stick.x) < stick_release:
		_snap_armed[hand] = true
		return
	# A hand mid-teleport-aim keeps its stick for the arc.
	if _teleport_hand == hand or not _snap_armed[hand] or absf(stick.x) < stick_engage:
		return
	_snap_armed[hand] = false
	_apply_snap_turn(-snap_turn_degrees * signf(stick.x))


func _apply_snap_turn(degrees: float) -> void:
	_yaw_origin_around_camera(deg_to_rad(degrees))
	snap_turned.emit(degrees)


## Rotate the origin around the CAMERA so the user pivots in place.
func _yaw_origin_around_camera(radians: float) -> void:
	var pivot := _camera.global_position
	var rotation_basis := Basis(Vector3.UP, radians)
	var xf := _origin.global_transform
	xf.origin = pivot + rotation_basis * (xf.origin - pivot)
	xf.basis = rotation_basis * xf.basis
	_origin.global_transform = xf


## Yaw the rig so the camera's horizontal forward aligns with `forward`.
func _face_direction(forward: Vector3) -> void:
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	var cam_forward := -_camera.global_transform.basis.z
	cam_forward.y = 0.0
	if cam_forward.length_squared() < 0.0001:
		return
	_yaw_origin_around_camera(cam_forward.normalized().signed_angle_to(forward.normalized(), Vector3.UP))


## ---- visuals ----------------------------------------------------------------

func _build_visuals() -> void:
	# top_level children drawn in GLOBAL coordinates (arc points are global).
	_arc_visual = MeshInstance3D.new()
	_arc_visual.name = "TeleportArc"
	_arc_visual.top_level = true
	_arc_visual.mesh = _arc_mesh
	_arc_visual.material_override = _LINE_MATERIAL.duplicate()
	_arc_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arc_visual)

	_target_visual = MeshInstance3D.new()
	_target_visual.name = "TeleportTarget"
	_target_visual.top_level = true
	var disc := TorusMesh.new()
	disc.inner_radius = marker_inner_radius
	disc.outer_radius = marker_outer_radius
	disc.rings = 24
	disc.ring_segments = 8
	_target_visual.mesh = disc
	_target_visual.material_override = _RETICLE_MATERIAL.duplicate()
	_target_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_target_visual)

	# Directional-teleport facing arrow: a flat wedge pointing the way you'll
	# face on landing. Container yaws (looking_at); the mesh lies flat pointing
	# the container's -Z.
	_reticle_arrow = Node3D.new()
	_reticle_arrow.name = "TeleportFacingArrow"
	_reticle_arrow.top_level = true
	var head := PrismMesh.new()
	head.size = Vector3(0.16, 0.012, 0.22)
	var head_instance := MeshInstance3D.new()
	head_instance.mesh = head
	head_instance.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	head_instance.position = Vector3(0.0, 0.0, -marker_outer_radius - 0.12)
	head_instance.material_override = _RETICLE_MATERIAL.duplicate()
	(head_instance.material_override as StandardMaterial3D).albedo_color = valid_color
	head_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_reticle_arrow.add_child(head_instance)
	add_child(_reticle_arrow)
	_hide_visuals()


func _draw_arc(points: PackedVector3Array) -> void:
	var color := valid_color if _target_valid else invalid_color
	(_arc_visual.material_override as StandardMaterial3D).albedo_color = color
	_arc_mesh.clear_surfaces()
	if points.size() >= 2:
		_arc_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for p in points:
			_arc_mesh.surface_add_vertex(p)
		_arc_mesh.surface_end()
	_arc_visual.visible = true
	# The anchor draws its own ring; the free-teleport reticle is only for
	# free-surface landings, so hide it when an anchor is the target.
	_target_visual.visible = _target_valid and _target_anchor == null
	if _target_visual.visible:
		(_target_visual.material_override as StandardMaterial3D).albedo_color = color
		_target_visual.global_position = _target_point + Vector3(0.0, 0.01, 0.0)
	# Directional facing arrow: only on a free-surface landing (an anchor draws
	# its own arrow) when the stick has chosen a facing.
	var show_facing := _target_valid and _target_anchor == null and _has_target_facing
	_reticle_arrow.visible = show_facing
	if show_facing:
		_reticle_arrow.global_transform = Transform3D(
			Basis.looking_at(_target_facing, Vector3.UP),
			_target_point + Vector3(0.0, 0.02, 0.0))
	_set_anchor_highlight(_target_anchor)


func _hide_visuals() -> void:
	if _arc_visual:
		_arc_visual.visible = false
	if _target_visual:
		_target_visual.visible = false
	if _reticle_arrow:
		_reticle_arrow.visible = false
	_set_anchor_highlight(null)


func _set_anchor_highlight(anchor: XRTeleportAnchor) -> void:
	if anchor == _highlighted_anchor:
		return
	if _highlighted_anchor and is_instance_valid(_highlighted_anchor):
		_highlighted_anchor.set_highlighted(false)
	_highlighted_anchor = anchor
	if anchor and is_instance_valid(anchor):
		anchor.set_highlighted(true)

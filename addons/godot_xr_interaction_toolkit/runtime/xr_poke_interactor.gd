@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg")
class_name XRPokeInteractor
extends Node

## Fingertip poke input as one block: tracks each hand's INDEX TIP (falling
## back to the controller tip while a hand drives a controller) and feeds it
## to everything pokeable - UI panels (press buttons and DRAG SLIDERS by
## touch) and XRPokeButton 3D push-buttons. Optional fingertip markers show
## exactly where the poke point is.
##
## Built into WebXRRig, so every rig/prefab scene is pokeable by default.

const _RETICLE_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_reticle_material.tres")
const XRHandGestureProvider := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_gesture_provider.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## Group other blocks use to find poke sources.
const GROUP := "xr_poke_interactor"
## How far in front of the controller's aim origin the poke tip sits.
const _CONTROLLER_TIP_FORWARD := 0.02

@export var enabled := true

@export_group("Detection")
## Physics layers poke targets live on (panels + XRPokeable bodies). The
## interactor sphere-queries this each frame so only targets NEAR a finger are
## processed - Unity-style broad-phase scaling instead of scanning every panel.
@export_flags_3d_physics var poke_collision_mask := 1
## Near-interaction radius (metres): the fingertip's zone for finding poke
## targets AND for hiding the far ray (is_poking). Unity's near region is
## deliberately larger than the press depth, so the ray bows out as you
## APPROACH, not only at contact - important on angled approaches. Actual
## press still fires at each target's own press depth, so a wide zone here
## does not cause early presses.
@export var poke_reach := 0.12

@export_group("Rig")
## All optional: empty paths self-resolve (drop the node anywhere - under the
## rig, under a hands mount, or at the scene root - and it finds the rig).
@export var xr_origin_path: NodePath
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath

## Small dot on each active poke point - the aiming affordance.
@export var show_markers := true
## Fingertip dot radius (metres) and colour.
@export var marker_radius := 0.005
@export var marker_color := Color(0.5, 0.9, 1.0, 0.85)

var _origin: Node3D
var _controllers: Array = [null, null]
var _points := [Vector3.INF, Vector3.INF]
var _arbiter: XRInteractionArbiter
var _markers: Array = [null, null]
var _finger_shape := SphereShape3D.new()
# Per hand: the poke targets touched last frame, so we can send poke_end/release
# to ones the finger has left.
var _active := [{}, {}]


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(GROUP)
	_origin = get_node_or_null(xr_origin_path) as Node3D
	if _origin == null:
		_origin = XRRigResolver.find_origin(self)
	_controllers[0] = get_node_or_null(left_controller_path) as XRController3D
	_controllers[1] = get_node_or_null(right_controller_path) as XRController3D
	for hand in 2:
		if _controllers[hand] == null:
			_controllers[hand] = XRRigResolver.find_controller(self, hand)


## World-space poke point for a hand; Vector3.INF when none is tracked.
func get_poke_point(hand: int) -> Vector3:
	return _points[hand] if hand >= 0 and hand < 2 else Vector3.INF


## True while this hand's fingertip is within reach of a poke target - the far
## ray suppresses on this so near and far interaction never show at once.
func is_poking(hand: int) -> bool:
	return hand >= 0 and hand < 2 and not _active[hand].is_empty()


## True only while this hand is aiming a teleport. Poke is gated on TELEPORT
## exclusivity and NOT on NEAR, because NEAR is derived from the GRAB
## interactor's hover -- and poke targets are not grab interactables.
## XRPokeButton carries no collider at all, so a hand reaching for one resolves
## to FAR; gating poke on NEAR made every poke button in the suite unpressable
## whenever an arbiter existed, including the arbiter's own off switch. Poke's
## own poke_reach broad-phase already is its near-field test, and teleport
## exclusivity is all the design ever required of it.
func _suppressed_by_arbiter(hand: int) -> bool:
	if _arbiter == null or not is_instance_valid(_arbiter):
		_arbiter = XRInteractionArbiter.find_in_tree(self)
	if _arbiter == null:
		return false
	return _arbiter.mode_for(hand) == XRInteractionArbiter.Mode.TELEPORT and _arbiter.enabled

func _physics_process(_delta: float) -> void:
	if not enabled:
		_points = [Vector3.INF, Vector3.INF]
		for hand in 2:
			_release_all(hand)
		_update_markers()
		return
	for hand in 2:
		if _suppressed_by_arbiter(hand):
			_points[hand] = Vector3.INF
			_release_all(hand)
			continue
		_points[hand] = _resolve_point(hand)
	# Dispatch first so _active is current: the marker only appears when the
	# finger is actually near a pokeable, not floating on the fingertip.
	_dispatch()
	_update_markers()


func _resolve_point(hand: int) -> Vector3:
	var controller := _controllers[hand] as XRController3D
	var controller_live: bool = controller and controller.get_is_active() and controller.get_has_tracking_data()
	# CONTROLLER modality: use the controller tip - a stable point rigidly on the
	# control - NOT the controller-emulated hand joints (which jitter, so the dot
	# bounced). The modality manager is the authority on who's driving.
	if _is_controller_modality(hand) and controller_live:
		return controller.global_transform * Vector3(0.0, 0.0, -_CONTROLLER_TIP_FORWARD)
	# Bare-hand tracking: the index fingertip.
	var tracker := XRHandTrackerResolver.get_tracker(hand)
	if tracker and tracker.has_tracking_data and _origin:
		var tip := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
		if XRHandGestureProvider.joint_position_valid(tracker, tip):
			return _origin.global_transform * tracker.get_hand_joint_transform(tip).origin
	# Fallback to the controller tip if one is present.
	if controller_live:
		return controller.global_transform * Vector3(0.0, 0.0, -_CONTROLLER_TIP_FORWARD)
	return Vector3.INF


## Is this hand driving a controller? The modality manager decides (it counts
## controller-emulated hands as CONTROLLER); without it, fall back to the
## tracker source.
func _is_controller_modality(hand: int) -> bool:
	var manager := get_tree().get_first_node_in_group("xr_input_modality_manager")
	if manager and manager.has_method("get_modality"):
		return int(manager.get_modality(hand)) == 1  # Modality.CONTROLLER
	var tracker := XRHandTrackerResolver.get_tracker(hand)
	return tracker != null and tracker.has_tracking_data \
			and tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER


## Physics broad-phase dispatch: for each fingertip, sphere-query the poke
## layer and feed poke_update to only the targets it actually touches. Targets
## the finger has left get poke_end. Panels + XRPokeable share the same
## poke_update/poke_end contract, so both are handled uniformly.
func _dispatch() -> void:
	var world: World3D = _origin.get_world_3d() if _origin else null
	if world == null:
		return
	_finger_shape.radius = poke_reach
	for hand in 2:
		if _points[hand] == Vector3.INF:
			_release_all(hand)
			continue
		var touched := {}
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = _finger_shape
		params.transform = Transform3D(Basis.IDENTITY, _points[hand])
		params.collision_mask = poke_collision_mask
		params.collide_with_areas = true
		params.collide_with_bodies = true
		for hit in world.direct_space_state.intersect_shape(params, 16):
			var target := _poke_target(hit.get("collider"))
			if target != null and target.has_method("poke_update"):
				touched[target] = true
				target.poke_update(hand, _points[hand])
		# Anything active last frame but not touched now: leave it.
		for prev in _active[hand]:
			if not touched.has(prev) and is_instance_valid(prev):
				prev.poke_end(hand)
		_active[hand] = touched


## A hit collider -> its poke target (an XRPokeable via body meta, or a UI
## canvas panel, which is the collider's own interactable ancestor).
func _poke_target(collider) -> Node:
	if collider == null:
		return null
	if collider.has_meta("xr_pokeable"):
		return collider.get_meta("xr_pokeable")
	if collider.has_meta("xr_poke_canvas"):
		return collider.get_meta("xr_poke_canvas")
	return null


func _release_all(hand: int) -> void:
	for target in _active[hand]:
		if is_instance_valid(target):
			target.poke_end(hand)
	_active[hand] = {}


func _update_markers() -> void:
	for hand in 2:
		# Show the aiming dot only when the finger is within reach of a pokeable
		# target (Unity/Meta-style: it appears on approach). Otherwise it would
		# float on the fingertip and jump around as the fingers curl to pinch.
		var has_point: bool = _points[hand] != Vector3.INF and not _active[hand].is_empty()
		if not show_markers or not has_point:
			if _markers[hand]:
				(_markers[hand] as Node3D).visible = false
			continue
		if _markers[hand] == null:
			var marker := MeshInstance3D.new()
			marker.top_level = true
			var dot := SphereMesh.new()
			dot.radius = marker_radius
			dot.height = marker_radius * 2.0
			marker.mesh = dot
			var material := _RETICLE_MATERIAL.duplicate() as StandardMaterial3D
			material.albedo_color = marker_color
			marker.material_override = material
			marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(marker)
			_markers[hand] = marker
		(_markers[hand] as Node3D).visible = true
		(_markers[hand] as Node3D).global_position = _points[hand]

@icon("res://addons/godot_webxr_kit/icons/xr_hands_mount.svg")
class_name XRHandsMount
extends Node3D

## Drop-in procedural tracked hands with the AR-passthrough rule built in.
##
## Parent this node under an XROrigin3D and it soft-loads godot_xr_hands' hand
## visualizer (skipped cleanly when that addon isn't installed) and hides the
## virtual hand meshes during AR passthrough - in AR you see your REAL hands
## (virtual ones would draw on top of them); in VR the virtual hands return.
## Hand INPUT (pinch, rays, grab) is unaffected either way.
##
## This is THE one place that rule lives: WebXRPrefab uses it, and any
## rig-based scene adds one of these instead of hand-wiring the visualizer.

const HAND_VISUALIZER := "res://addons/godot_xr_hands/runtime/hand_visualizer.gd"
const HAND_MESH_VISUALIZER := "res://addons/godot_xr_hands/runtime/xr_hand_mesh_visualizer.gd"

enum HandStyle { PROCEDURAL, REALISTIC }
## When to draw the virtual hand meshes. ALWAYS also shows them in AR
## passthrough (virtual objects occlude passthrough hands, so hiding them
## leaves you handless mid-interaction); VR_ONLY hides them in AR so you see
## your REAL hands (pick this when the scene ships hand/depth occlusion);
## NEVER draws no hand mesh at all (input still works). Hand INPUT - pinch,
## rays, grab - is unaffected by all three.
enum ShowHands { NEVER, VR_ONLY, ALWAYS }

@export_group("Hands")
## Draw virtual hands never / only in VR / always (incl. AR passthrough).
@export var show_hands := ShowHands.ALWAYS

## Virtual hand look. PROCEDURAL = capsule joints/bones (the "debug" look);
## REALISTIC = the bundled WebXR Input Profiles rigged hand mesh (MIT) skinned
## live to the tracked joints. Realistic falls back to procedural if the mesh
## visualizer is unavailable.
@export var hand_style := HandStyle.REALISTIC

## Custom hand meshes for REALISTIC style: drop in your own rigged glb whose
## bones use the standard WebXR joint names. Empty = the bundled generic hand.
@export var left_hand_model: PackedScene
@export var right_hand_model: PackedScene

@export_group("Advanced")
## Forwarded to the visualizer; false = XRHandTracker joints on every platform.
@export var prefer_browser_hand_bridge := false

## The group WebXRBootstrap hides during AR passthrough.
@export var ar_hide_group := WebXRBootstrap.GROUP_AR_PASSTHROUGH_HIDDEN

## Hide a hand's virtual mesh while THAT hand is driving a controller (the
## Unity-XRI visual swap: you see the controller model instead of the hand).
## With multimodal runtimes (simultaneous hands + controllers) hand joints keep
## tracking over a held controller, so without this the virtual hand draws
## wrapped around the controller model. Off = Meta-Home-style hands-over-
## controller presentation. Needs an XRInputModalityManager in the scene.
@export var hide_hand_while_using_controller := true

var _hands: Node3D


func _ready() -> void:
	if show_hands == ShowHands.NEVER:
		return  # no hand mesh at all; input paths are unaffected.
	var script_path := HAND_VISUALIZER
	if hand_style == HandStyle.REALISTIC and ResourceLoader.exists(HAND_MESH_VISUALIZER):
		script_path = HAND_MESH_VISUALIZER
	if not ResourceLoader.exists(script_path):
		return  # godot_xr_hands not installed; nothing to mount.
	_hands = load(script_path).new()
	if "prefer_browser_hand_bridge" in _hands:
		_hands.prefer_browser_hand_bridge = prefer_browser_hand_bridge
	if "left_model" in _hands:
		_hands.left_model = left_hand_model
		_hands.right_model = right_hand_model
	# The visualizer manages its own visibility (tracking watchdog), so the AR
	# hide targets THIS mount - the two never fight.
	add_child(_hands)
	if show_hands == ShowHands.VR_ONLY:
		add_to_group(ar_hide_group)
	if hide_hand_while_using_controller:
		_connect_modality.call_deferred()


func _connect_modality() -> void:
	var manager := get_tree().get_first_node_in_group(XRInputModalityManager.GROUP)
	if manager == null or not manager.has_signal("modality_changed"):
		return  # No modality manager in the scene - hands stay always-on.
	manager.modality_changed.connect(_on_modality_changed)
	for hand in 2:
		_on_modality_changed(hand, manager.get_modality(hand))


func _on_modality_changed(hand: int, modality: int) -> void:
	if _hands == null:
		return
	var side := "Right" if hand == 1 else "Left"
	var hand_root := _hands.get_node_or_null("%sHandTracking" % side)
	if hand_root == null:
		return
	# Hide via render layers, not `visible` - the visualizer's own tracking
	# watchdog drives `visible` and would fight (and win) every frame.
	var shown := modality != XRInputModalityManager.Modality.CONTROLLER
	for mesh in hand_root.find_children("*", "VisualInstance3D", true, false):
		mesh.layers = 1 if shown else 0

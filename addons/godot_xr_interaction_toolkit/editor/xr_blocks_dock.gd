@tool
extends VBoxContainer

## The "XR Suite" dock has two deliberately separate authoring jobs:
## export-preset/addon validation at the top, and scene blocks below.
## "Block" means only a node or scene authors can add to the edited scene.

## kind "scene" = instantiate a .tscn; "node" = create the script's node type
## with the script attached. Paths are existence-checked at refresh.
const CATEGORIES := [
	{"name": "Start Here", "blocks": [
		{"name": "XR Prefab", "desc": "Everything XR in one drop. Web creates browser Enter VR/AR UI; native OpenXR starts directly.", "kind": "scene", "path": "res://addons/godot_webxr_kit/xr_prefab.tscn", "icon": "res://addons/godot_webxr_kit/icons/webxr_bootstrap.svg"},
		{"name": "XR Rig", "desc": "The runtime-neutral rig alone (origin, camera, controllers, interactors) - for custom-HUD scenes.", "kind": "scene", "path": "res://addons/godot_webxr_kit/rig/webxr_rig.tscn", "icon": "res://addons/godot_webxr_kit/icons/openxr_input_adapter.svg"},
		{"name": "WebXR Session UI", "desc": "Browser-only Enter VR/AR buttons + capabilities/status HUD; WebXRBootstrap adopts it automatically.", "kind": "scene", "path": "res://addons/godot_webxr_kit/xr_session_ui.tscn", "icon": "res://addons/godot_webxr_kit/icons/xr_session_ui.svg"},
		{"name": "WebXR Bootstrap", "desc": "Browser session lifecycle (VR/AR entry, passthrough, feature requests).", "kind": "node", "base": "Node3D", "path": "res://addons/godot_webxr_kit/runtime/webxr_bootstrap.gd", "icon": "res://addons/godot_webxr_kit/icons/webxr_bootstrap.svg"},
		{"name": "OpenXR Bootstrap", "desc": "Play straight to a headset from the editor (Quest Link / SteamVR). Inert on web.", "kind": "node", "base": "Node", "path": "res://addons/godot_webxr_kit/runtime/openxr_bootstrap.gd", "icon": "res://addons/godot_webxr_kit/icons/openxr_bootstrap.svg"},
		{"name": "XR Simulator (desktop)", "desc": "Test flat, no headset: fakes controllers AND hands (X switches; RMB pinches through the real select path). On-screen hotkey help (H). Auto-inert in a real XR session - safe to leave in.", "kind": "node", "base": "Node", "path": "res://addons/godot_webxr_kit/runtime/xr_simulator.gd", "icon": "res://addons/godot_webxr_kit/icons/openxr_input_adapter.svg"},
		{"name": "Interaction Feedback", "desc": "Scene-wide feel: EVERY interactable gets hover glow + click sound + controller haptics automatically, styled by one swappable XRFeedbackTheme. Per-object override = give that object its own Highlight Affordance. Rig-default.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_interaction_feedback.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_highlight_affordance.svg"},
		{"name": "Debug Panel (XR)", "desc": "The panel that stays visible INSIDE a session: FPS, session state, per-hand modality, and a live event log auto-wired to the suite's signals (grabs, teleports, sockets, gestures).", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_debug_panel.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_ui_canvas_interactable.svg"},
	]},
	{"name": "Hands & Input", "blocks": [
		{"name": "Hands Mount", "desc": "Procedural tracked hands; virtual meshes hide in AR so you see your real hands. Parent under XROrigin3D.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_webxr_kit/runtime/xr_hands_mount.gd", "icon": "res://addons/godot_webxr_kit/icons/xr_hands_mount.svg"},
		{"name": "Realistic Hands", "desc": "Rigged hand meshes (WebXR Input Profiles, MIT) skinned live to the tracked joints. Or set hand_style=REALISTIC on a Hands Mount.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_hands/runtime/xr_hand_mesh_visualizer.gd", "icon": "res://addons/godot_xr_hands/icons/xr_hand_mesh_visualizer.svg"},
		{"name": "Input Modality", "desc": "Per-hand controller/hands switching + profile-matched models. Drop anywhere - finds the rig itself. Rig-default.", "kind": "node", "base": "Node", "path": "res://addons/godot_webxr_kit/runtime/xr_input_modality_manager.gd", "icon": "res://addons/godot_webxr_kit/icons/xr_input_modality_manager.svg"},
		{"name": "Gesture Recognizer", "desc": "Hand gestures as data (.tres) - presets included, tune live with show_debug. Per-hand start/end signals.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_hands/runtime/gesture_studio/xr_gesture_recognizer.gd", "icon": "res://addons/godot_xr_hands/icons/xr_gesture_recognizer.svg"},
		{"name": "Gesture Recorder", "desc": "Hold a pose, get a gesture (.tres, tolerances from your own jitter). Browser saves = that browser only; record via Link/native for real files.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_hands/runtime/gesture_studio/xr_gesture_recorder.gd", "icon": "res://addons/godot_xr_hands/icons/xr_gesture_recognizer.svg"},
	]},
	{"name": "Locomotion", "blocks": [
		{"name": "Locomotion", "desc": "Teleport arc + snap turn (thumbsticks). Drop anywhere - finds the rig itself. Rig-default.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_locomotion.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
		{"name": "Microgesture Locomotion", "desc": "Thumb swipes drive the SAME teleport arc + snap turn (needs godot_xr_hands; inert without). Rig-default.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_microgesture_locomotion_driver.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
		{"name": "Teleport Anchor", "desc": "A FIXED teleport destination: aim the arc at it to SNAP to this exact spot, optionally turned to FACE its forward. Drop anywhere, rotate to aim; self-wires to the rig's locomotion. Seats, viewpoints, doorways.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_teleport_anchor.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
		{"name": "Continuous Move", "desc": "Smooth stick-walk (+ optional continuous turn). Opt-in alternative/complement to teleport - it auto-claims its stick so teleport stays on the other hand. Self-wires to the rig.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_continuous_move.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
		{"name": "Tunneling Vignette", "desc": "Comfort: darkens the view edges WHILE you move to cut motion sickness. Watches camera motion, so it works with any locomotion; ignores teleport jumps. Drop near a rig.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_tunneling_vignette.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
		{"name": "Climb Provider", "desc": "Climbing locomotion: grab an XRClimbInteractable and moving your hand moves the RIG the opposite way (pull down = rise), hand over hand. Drop one near the rig; handholds find it.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_climb_provider.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
		{"name": "Climb Interactable", "desc": "A handhold you climb by. Put it on a node with a collider (rung/rock/ledge); grabbing it drives the Climb Provider. Needs a Climb Provider in the scene.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_climb_interactable.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
		{"name": "Floor (teleportable)", "desc": "Ground in one drop: visible floor + teleport collision; the visual hides in AR passthrough (your real floor takes over).", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/xr_floor.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg"},
	]},
	{"name": "Grab & Sockets", "blocks": [
		{"name": "Grabbable", "desc": "Ready grabbable object: swap the mesh, collision auto-fits, highlight included. far_grab_mode decides what a RAY grab does: ATTRACT (default) brings it to your hand and keeps it, FIXED holds the distance you grabbed it at and follows your aim, REEL lets hand motion along the ray wind it in and out, TWIST hands the distance to wrist roll (see Pinch-Twist Distance Driver, below - needs godot_xr_hands). Tune the arrival with far_grab_attract_speed (how fast it flies in) and far_grab_attract_standoff (how far off your palm it settles - keep it under the ray's hide_ray_when_held_within or a held object still draws a ray). Near grab is unaffected.", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/grabbable.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Throwable", "desc": "A physics block you can grab and THROW: a RigidBody3D frozen while held (gravity won't fight the grab) and thrown on release, so it flies, falls, and bounces with real gravity. Swap the mesh; near or far grab.", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/throwable.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Pinch-Twist Distance Driver", "desc": "Drives a TWIST far-grab from wrist roll (needs godot_xr_hands - bare hands only). Roll away from the roll you grabbed with drives the RATE distance changes, not the distance itself: twist and hold to keep travelling, return to neutral to stop - so pinch stays occupied grabbing while the wrist, still free, places the object. Drop inside a Grabbable set to far_grab_mode = TWIST. Held by a controller (no wrist joint) it just holds its distance, like FIXED.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_pinch_twist_distance_driver.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Blaster", "desc": "Grab it, then fire: controllers pull the trigger, BARE HANDS grip it with the lower fingers (index free) and curl the index to fire (the trigger visibly depresses so the gesture teaches itself). The grab-it-then-use-it pattern (guns, spray cans, drills). Drop XRBlaster inside any grabbable + point a Muzzle node.", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/blaster.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Hand Activator", "desc": "Fires a held object's ACTIVATE from a BARE-HAND gesture, so hands do what a controller trigger does. Drop inside a grabbable: curl the chosen trigger finger (index for a gun, thumb for a spray can), or point it at any Gesture Studio pose. Emits trigger_progress for live feedback. Reusable across every powered hand tool.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_hand_activator.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Spray Can", "desc": "The CONTINUOUS twin of the blaster: hold the trigger and it sprays. Grip-grab + XRHandActivator (set to CONTINUOUS) + an XRSprayer that raycasts from the nozzle and paints any Drawing Surface it hits. Proof the parts compose - a whole different tool from the same blocks.", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/spray_can.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Grab Point", "desc": "Authored grip: parent INSIDE a grabbable where the hand should hold it - grabbing snaps the object into the palm (pos+rot). Enable 'Preview Hand' to see a reference hand grip the object as you place it (WYSIWYG, no guessing). Per-hand filter, multiple points OK.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_grab_point.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Pen", "desc": "A grabbable pen whose grab point is pitched into a natural WRITING pose; its tip draws on any Drawing Surface it touches. Shows off custom grab points + drawing.", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/pen.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Drawing Surface", "desc": "A notepad you draw on: give it a PlaneMesh and any Pen tip (group xr_pen_tip) paints ink where it touches. Runtime texture on a pre-baked material, so it works on WebGPU too. clear() wipes it.", "kind": "node", "base": "MeshInstance3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_drawing_surface.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_ui_canvas.svg"},
		{"name": "Highlight Affordance", "desc": "Hover/grab/use tinting for any interactable. Parent it INSIDE the object - it wires itself.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_highlight_affordance.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_highlight_affordance.svg"},
		{"name": "Socket Affordance", "desc": "Ready/hover/occupied tinting for a socket pad. Parent inside the socket.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_socket_affordance.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_socket_affordance.svg"},
		{"name": "Socket Interactor", "desc": "Snap-zone that grabs and holds interactables placed into it.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_socket_interactor.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_socket_interactor.svg"},
	]},
	{"name": "Mechanisms", "blocks": [
		{"name": "Dial", "desc": "Rotary knob: grab and turn to sweep a 0-1 value (optional detents). Put it on a node with a collider; wire value_changed to brightness, volume, anything.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_dial.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Lever", "desc": "Hinged handle: grab and swing between a min/max angle, outputting 0-1. Great for switches and throttles.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_lever.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Drawer", "desc": "Linear slider/drawer: grab and pull along one axis between closed (0) and open (1). Tracks the hand, so far-ray pulls don't bounce.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_drawer.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
		{"name": "Surface Draggable", "desc": "Position constraint: grab a piece and slide it along ONLY the local axes you allow - a magnet on a board (allow two, freeze the up axis), a bead on a wire (allow one). Parent-local, so it works on a tilted board; optional per-axis bounds.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_surface_draggable.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg"},
	]},
	{"name": "Touch & UI", "blocks": [
		{"name": "Poke Interactor", "desc": "Fingertip touch: press panels, drag sliders, push 3D buttons. Drop anywhere - finds the rig itself. Rig-default.", "kind": "node", "base": "Node", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg"},
		{"name": "Poke Button (3D)", "desc": "Physical push-button: the cap depresses under your fingertip and fires with hysteresis.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_button.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg"},
		{"name": "Pokeable", "desc": "Make ANY body pokeable (Unity XRPokeFilter-style): parent INSIDE a collider object, pick the face + press depth, get pressed/released/CANCELLED signals. Arming is gated on approach, so a hand sweeping sideways across a row of buttons presses none of them. Set interpret_drag for a handle that reports drags and does not fire on let-go.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_pokeable.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg"},
		{"name": "UI Panel (3D)", "desc": "In-world interactive UI panel; build your Control tree under Viewport/Root.", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/xr_ui_panel.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_ui_canvas_interactable.svg"},
		{"name": "Keyboard (XR)", "desc": "In-world keyboard: open(initial, prompt) -> text_submitted/cancelled. Letters, digits, space, underscore.", "kind": "scene", "path": "res://addons/godot_xr_interaction_toolkit/xr_keyboard.tscn", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_ui_canvas_interactable.svg"},
	]},
	{"name": "Perception (AR)", "blocks": [
		{"name": "Occlusion / Depth", "desc": "Runtime-neutral real-world occlusion (hard/soft) + depth debug. Uses the best installed WebXR or OpenXR provider.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_scene_understanding/shared/environment_depth_manager.gd", "icon": "res://addons/godot_xr_scene_understanding/icons/environment_depth_manager.svg"},
		{"name": "Scene Mesh", "desc": "Runtime-neutral room geometry: visualize, occlude, labels, collision. Uses the best installed WebXR or OpenXR provider.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_xr_scene_understanding/shared/scene_mesh_manager.gd", "icon": "res://addons/godot_xr_scene_understanding/icons/scene_mesh_manager.svg"},
		{"name": "Light Estimation", "desc": "Objects lit by (and reflecting) the real room. Android XR / ARCore.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_webxr_scene_understanding/runtime/light_estimation_manager.gd", "icon": "res://addons/godot_webxr_scene_understanding/icons/light_estimation_manager.svg"},
		{"name": "Hit Test + Anchors", "desc": "Surface reticle + pinch-to-place spatial anchors with your scene instanced at them.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_webxr_scene_understanding/runtime/hit_test_anchor_manager.gd", "icon": "res://addons/godot_webxr_scene_understanding/icons/hit_test_anchor_manager.svg"},
	]},
	{"name": "WebGPU Export", "blocks": [
		{"name": "Bake Anchor", "desc": "Declare runtime-built materials so their shaders bake for WebGPU exports.", "kind": "node", "base": "Node3D", "path": "res://addons/godot_webgpu/bake_anchor.gd", "icon": "res://addons/godot_webgpu/icons/bake_anchor.svg"},
		{"name": "XR Font Bake Anchor", "desc": "Makes 3D text available to ahead-of-time shader baking across exports.", "kind": "node", "base": "Label3D", "path": "res://addons/godot_xr_interaction_toolkit/runtime/xr_font_bake_anchor.gd", "icon": "res://addons/godot_xr_interaction_toolkit/icons/xr_font_bake_anchor.svg"},
	]},
]

const _Setup := preload("res://addons/godot_xr_interaction_toolkit/editor/xr_project_setup.gd")
const _DoctorScript := preload("res://addons/godot_xr_interaction_toolkit/editor/xr_scene_doctor.gd")
const _ProjectDoctorScript := preload("res://addons/godot_xr_interaction_toolkit/editor/xr_project_doctor.gd")

var _list: ItemList
var _desc: Label
var _add_button: Button
var _visible_blocks := []  # parallel to list rows; null = category header row
var _doctor: AcceptDialog
var _project_doctor: AcceptDialog
var _new_scene_dialog: EditorFileDialog
var _search: LineEdit



func _ready() -> void:
	name = "XR Suite"
	_build_package_setup()

	if ResourceLoader.exists(_Setup.KIT_PREFAB):
		var new_scene_button := Button.new()
		new_scene_button.text = "New XR Scene"
		new_scene_button.tooltip_text = "Creates a ready XR playground."
		new_scene_button.pressed.connect(_on_new_scene)
		add_child(new_scene_button)

	var scene_title := Label.new()
	scene_title.text = "SCENE BLOCKS"
	scene_title.tooltip_text = "Reusable nodes and scenes you can add to the open scene."
	scene_title.add_theme_color_override("font_color", Color(0.62, 0.78, 1.0))
	add_child(scene_title)

	var scene_hint := Label.new()
	scene_hint.text = "Double-click a block to add it to the scene."
	scene_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scene_hint.add_theme_font_size_override("font_size", 12)
	add_child(scene_hint)
	_search = LineEdit.new()
	_search.placeholder_text = "Search blocks..."
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_text): refresh())
	add_child(_search)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_selected)
	_list.item_activated.connect(func(_i): _add_selected())
	add_child(_list)
	_desc = Label.new()
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.custom_minimum_size = Vector2(0, 56)
	add_child(_desc)
	_add_button = Button.new()
	_add_button.text = "Add to Scene"
	_add_button.pressed.connect(_add_selected)
	add_child(_add_button)
	refresh()


func _build_package_setup() -> void:
	var title := Label.new()
	title.text = "XR SUITE VALIDATOR"
	title.tooltip_text = "Project-wide export and scene validation."
	title.add_theme_color_override("font_color", Color(0.62, 0.78, 1.0))
	add_child(title)

	var hint := Label.new()
	hint.text = (
		"Export presets are the source of truth. Project Validator rechecks "
		+ "presets, addons, configuration, and package footprint."
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	add_child(hint)

	var project_doctor_button := Button.new()
	project_doctor_button.text = "Project Validator"
	project_doctor_button.tooltip_text = (
		"Freshly validates export presets, required addons, XR settings, "
		+ "and automatic export package cleanup; offers preset-scoped repair "
		+ "only for missing project configuration."
	)
	project_doctor_button.pressed.connect(_on_open_project_doctor)
	project_doctor_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var scene_doctor_button := Button.new()
	scene_doctor_button.text = "Scene Validator"
	scene_doctor_button.tooltip_text = (
		"Checks the open scene for XR rig, lighting, collision, and "
		+ "interaction problems."
	)
	scene_doctor_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scene_doctor_button.pressed.connect(_on_open_doctor)

	var doctor_actions := HBoxContainer.new()
	doctor_actions.add_child(project_doctor_button)
	doctor_actions.add_child(scene_doctor_button)
	add_child(doctor_actions)

	var separator := HSeparator.new()
	add_child(separator)


func _on_new_scene() -> void:
	if _new_scene_dialog == null:
		_new_scene_dialog = EditorFileDialog.new()
		_new_scene_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_new_scene_dialog.add_filter("*.tscn", "Godot Scene")
		_new_scene_dialog.current_file = "xr_playground.tscn"
		_new_scene_dialog.file_selected.connect(_on_new_scene_path)
		add_child(_new_scene_dialog)
	_new_scene_dialog.popup_centered_ratio(0.5)


func _on_new_scene_path(path: String) -> void:
	var error := _Setup.save_starter_scene(path)
	if not error.is_empty():
		_desc.text = error
		return
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	_desc.text = "XR playground created - teleport, grab, hands all live. Press Play to a headset or export for the browser."


func _on_open_doctor() -> void:
	if _doctor == null:
		_doctor = _DoctorScript.new()
		add_child(_doctor)
	_doctor.popup_centered()


func _on_open_project_doctor() -> void:
	if _project_doctor == null:
		_project_doctor = _ProjectDoctorScript.new()
		add_child(_project_doctor)
	_project_doctor.call(
		"open_for_export_preset",
		_current_export_preset_name()
	)


func _current_export_preset_name() -> String:
	var pending: Array[Node] = [EditorInterface.get_base_control()]
	while not pending.is_empty():
		var node := pending.pop_back()
		if node.has_method("get_current_preset"):
			# Calling get_current_preset() before Godot's Export dialog has
			# populated its ItemList emits an engine error. Check selection
			# state first; the fallback below matches Godot's default.
			var has_selection := false
			for candidate in node.find_children("*", "ItemList", true, false):
				var item_list := candidate as ItemList
				if item_list != null and not item_list.get_selected_items().is_empty():
					has_selection = true
					break
			if has_selection:
				var preset: Variant = node.call("get_current_preset")
				if (
					preset is Object
					and (preset as Object).has_method("get_preset_name")
				):
					return str((preset as Object).call("get_preset_name"))
		for child in node.get_children():
			if child is Node:
				pending.append(child)
	return _Setup.get_default_export_preset_name()


func refresh() -> void:
	_list.clear()
	_visible_blocks.clear()
	var query := _search.text.strip_edges().to_lower() if _search else ""
	for category in CATEGORIES:
		var installed := []
		for block in category["blocks"]:
			if not ResourceLoader.exists(block["path"]):
				continue
			if not query.is_empty() \
					and not str(block["name"]).to_lower().contains(query) \
					and not str(block["desc"]).to_lower().contains(query):
				continue
			installed.append(block)
		if installed.is_empty():
			continue  # whole addon not installed - drop the header too
		var header := _list.add_item(str(category["name"]).to_upper())
		_list.set_item_selectable(header, false)
		_list.set_item_disabled(header, true)
		_list.set_item_custom_fg_color(header, Color(0.62, 0.68, 0.78))
		_visible_blocks.append(null)
		for block in installed:
			var icon: Texture2D = load(block["icon"]) if ResourceLoader.exists(block["icon"]) else null
			_list.add_item("  " + block["name"], icon)
			_visible_blocks.append(block)


func _on_selected(index: int) -> void:
	if _visible_blocks[index] == null:
		return
	_desc.text = _visible_blocks[index]["desc"]


func _add_selected() -> void:
	var selected := _list.get_selected_items()
	if selected.is_empty() or _visible_blocks[selected[0]] == null:
		return
	var block: Dictionary = _visible_blocks[selected[0]]
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_desc.text = "Open a scene first."
		return
	# Add under the current selection when there is one, else the scene root.
	var parent: Node = root
	var editor_selection := EditorInterface.get_selection().get_selected_nodes()
	if not editor_selection.is_empty():
		parent = editor_selection[0]

	var node: Node
	if block["kind"] == "scene":
		node = (load(block["path"]) as PackedScene).instantiate()
	else:
		node = ClassDB.instantiate(block["base"])
		node.set_script(load(block["path"]))
		node.name = block["name"].replace(" ", "").replace("/", "").replace("+", "").replace("(", "").replace(")", "")

	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Add XR Block: %s" % block["name"])
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(parent, "remove_child", node)
	undo.commit_action()
	_desc.text = "%s added under %s." % [block["name"], parent.name]

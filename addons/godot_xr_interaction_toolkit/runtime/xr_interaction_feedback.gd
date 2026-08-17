@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_highlight_affordance.svg")
class_name XRInteractionFeedback
extends Node

## Scene-wide interaction feedback - visuals, audio, and haptics for EVERY
## interactable, with zero per-object setup. Unity deprecated its affordance
## system and announced a unified feedback system "in a future version"; this
## is that system, today, and scene-default instead of per-object:
##
## - VISUAL: each interactable automatically gets a highlight (the proven
##   XRHighlightAffordance, deployed at runtime) tinted from the theme.
## - AUDIO: hover tick + select click played AT the object (positional).
## - HAPTICS: pulse on the interacting hand's controller (our signals carry
##   the interactor, so the correct hand buzzes). Bare hands no-op silently.
##
## Authorship: styling lives in ONE XRFeedbackTheme resource - swap it to
## restyle the whole scene. Per-object control: give an object its OWN
## affordance child (Highlight Affordance block) and the system skips it -
## default everywhere, override anywhere. Rig-default: ships in WebXRRig.

const _HIGHLIGHT_SCRIPT := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_highlight_affordance.gd")
const _DEFAULT_THEME := preload("res://addons/godot_xr_interaction_toolkit/runtime/feedback/default_feedback_theme.tres")

@export var enabled := true
## Styling for all three channels; swap to restyle the scene.
@export var theme: XRFeedbackTheme
## Skip objects that carry their own affordance child (their author already
## chose a look). Off = system feedback stacks on top anyway.
@export var respect_object_affordances := true

var _wired := {}       # interactable -> true (avoid double-wiring)
var _audio := {}       # interactable -> AudioStreamPlayer3D
var _grip_hint: Label3D = null   # one shared hint, repositioned per hover
var _grip_hint_target: Node = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if theme == null:
		theme = _DEFAULT_THEME
	_wire_manager.call_deferred()


func _wire_manager() -> void:
	var manager := get_tree().get_first_node_in_group(XRInteractionManager.GROUP_NAME)
	if manager == null:
		push_warning("XRInteractionFeedback: no XRInteractionManager in the scene.")
		return
	manager.interactable_registered.connect(_on_interactable_registered)
	for interactable in manager.get_interactables():
		_on_interactable_registered(interactable)


func _on_interactable_registered(interactable) -> void:
	if not enabled or interactable == null or _wired.has(interactable):
		return
	# A UI canvas panel forwards hover/click to the 2D buttons on its surface -
	# those highlight themselves. Glowing the whole panel (and ticking on hover)
	# is wrong, so skip the auto-feedback for it entirely.
	if _is_ui_canvas(interactable):
		return
	if respect_object_affordances and _has_own_affordance(interactable):
		return
	_wired[interactable] = true

	if theme.visual_enabled:
		var highlight: Node = _HIGHLIGHT_SCRIPT.new()
		highlight.name = "AutoFeedbackHighlight"
		highlight.hover_color = theme.hover_color
		highlight.select_color = theme.select_color
		highlight.activate_color = theme.activate_color
		highlight.emission_energy = theme.emission_energy
		interactable.add_child(highlight)

	if theme.audio_enabled or theme.haptics_enabled:
		interactable.hover_entered.connect(_on_hover.bind(interactable))
		interactable.select_entered.connect(_on_select.bind(interactable))

	# Not folded into the block above: the hint needs hover even when audio
	# and haptics are both off, and it needs the EXIT edge besides.
	if theme.grip_hint_enabled and _wants_grip_hint(interactable):
		interactable.hover_entered.connect(_on_grip_hover.bind(interactable))
		interactable.hover_exited.connect(_on_grip_unhover.bind(interactable))
		interactable.select_entered.connect(_on_grip_unhover.bind(interactable))


## A UI canvas panel (XRUICanvasInteractable, incl. subclasses) whose surface has
## its own interactive controls - no whole-object highlight.
func _is_ui_canvas(interactable: Node) -> bool:
	var script: Script = interactable.get_script()
	while script:
		if script.get_global_name() == &"XRUICanvasInteractable":
			return true
		script = script.get_base_script()
	return false


func _has_own_affordance(interactable: Node) -> bool:
	for child in interactable.get_children():
		var script: Script = child.get_script()
		while script:
			if script.get_global_name() == &"XRHighlightAffordance":
				return true
			script = script.get_base_script()
	return false


## Duck-typed so this block keeps zero hard dependency on the grab script:
## anything exposing hand_grab_style == GRIP (1) wants the hint.
func _wants_grip_hint(interactable: Node) -> bool:
	var style: Variant = interactable.get("hand_grab_style")
	return style != null and int(style) == 1


func _on_grip_hover(_interactor, interactable) -> void:
	if _grip_hint == null or not is_instance_valid(_grip_hint):
		# A runtime Label3D renders on WebGPU because the demo scenes carry
		# the label bake anchor (the flag-twin pattern); no material work
		# needed here. no_depth_test + priority so a held tool or the object
		# itself cannot swallow the hint - the scene-labels lesson.
		_grip_hint = Label3D.new()
		_grip_hint.name = "GripHint"
		_grip_hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_grip_hint.no_depth_test = true
		_grip_hint.render_priority = 10
		_grip_hint.pixel_size = 0.0009
		_grip_hint.font_size = 40
		_grip_hint.outline_size = 8
		add_child(_grip_hint)
	_grip_hint.text = theme.grip_hint_text
	_grip_hint.global_position = (interactable as Node3D).global_position + Vector3(0.0, 0.14, 0.0)
	_grip_hint.visible = true
	_grip_hint_target = interactable


func _on_grip_unhover(_interactor, interactable) -> void:
	# Only the CURRENT target may clear the hint: with two hands, the first
	# hand's exit must not erase the hint the second hand is looking at.
	if interactable == _grip_hint_target and _grip_hint and is_instance_valid(_grip_hint):
		_grip_hint.visible = false
		_grip_hint_target = null


func _on_hover(interactor, interactable) -> void:
	if theme.audio_enabled and theme.hover_sound:
		_play(interactable, theme.hover_sound)
	if theme.haptics_enabled:
		_pulse(interactor, theme.hover_amplitude, theme.hover_duration)


func _on_select(interactor, interactable) -> void:
	if theme.audio_enabled and theme.select_sound:
		_play(interactable, theme.select_sound)
	if theme.haptics_enabled:
		_pulse(interactor, theme.select_amplitude, theme.select_duration)


func _play(interactable: Node, stream: AudioStream) -> void:
	var player: AudioStreamPlayer3D = _audio.get(interactable)
	if player == null or not is_instance_valid(player):
		player = AudioStreamPlayer3D.new()
		player.volume_db = theme.volume_db
		player.max_distance = 12.0
		interactable.add_child(player)
		_audio[interactable] = player
	player.stream = stream
	player.play()


## Buzz the controller of the hand that caused the event. Interactors carry a
## hand id; the rig resolver finds that hand's controller. Bare hands (no
## controller live) no-op silently.
func _pulse(interactor, amplitude: float, duration: float) -> void:
	if interactor == null or not ("hand" in interactor):
		return
	var controller := XRRigResolver.find_controller(self, int(interactor.hand))
	if controller and controller.get_is_active():
		controller.trigger_haptic_pulse("haptic", 0.0, amplitude, duration, 0.0)

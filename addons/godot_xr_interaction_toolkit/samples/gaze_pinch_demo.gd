extends Node3D

## Gaze and pinch: look at something, pinch with either hand. Nothing here knows
## about gaze except this status line. The cube, the sphere and the panel are the
## same blocks a hand ray uses, and GazeInteractor was dropped in unwired.
##
## On a headset without eye tracking, open with ?headgaze=1 to try the flow with
## your head standing in for your eyes.

@onready var _gaze: Node = $GazeInteractor
@onready var _status: Label3D = $StatusLabel

var _presses := 0
var _press_label: Label
var _last_source := ""


func _ready() -> void:
	if ResourceLoader.exists("res://scripts/back_to_menu_button.gd"):
		add_child((load("res://scripts/back_to_menu_button.gd") as GDScript).new())
	if OS.has_feature("web") and str(JavaScriptBridge.eval("window.location.search", true)).contains("headgaze=1"):
		_gaze.head_directed_preview = true
	_gaze.hover_entered.connect(func(target: Node) -> void: _report("hover", target))
	_gaze.select_entered.connect(func(target: Node) -> void: _report("select", target))
	_gaze.select_exited.connect(func(target: Node) -> void: _report("release", target))
	_build_panel()


func _process(_delta: float) -> void:
	var state: Dictionary = _gaze.get_gaze_status()
	var source := "no gaze source - hand rays stay in charge"
	if state["owns_far_targeting"]:
		source = "gaze tracked" if state["tracked"] else "gaze lost - holding on"
	if source != _last_source:
		_last_source = source
		print("GAZEDEMO source %s" % source)
	var hovered: Node = _gaze.get_hovered()
	var held: Node = _gaze.get_selected()
	var target := "-" if hovered == null else String(hovered.name)
	if held != null:
		target = "%s (held)" % held.name
	_status.text = "%s\nlooking at: %s" % [source, target]


## One line per step, so a browser harness can read the result off the console.
func _report(what: String, target: Node) -> void:
	print("GAZEDEMO %s %s hand=%d" % [what, target.name, _gaze.hand])


func _build_panel() -> void:
	var root: Control = $Panel/Viewport/Root
	var button := Button.new()
	button.name = "GazeButton"
	button.text = "LOOK HERE, THEN PINCH"
	button.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.offset_left = 40
	button.offset_top = 40
	button.offset_right = -40
	button.offset_bottom = -140
	button.add_theme_font_size_override("font_size", 44)
	button.pressed.connect(_on_button_pressed)
	root.add_child(button)
	_press_label = Label.new()
	_press_label.text = "presses: 0"
	_press_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_press_label.offset_top = -120
	_press_label.offset_bottom = -30
	_press_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_press_label.add_theme_font_size_override("font_size", 40)
	root.add_child(_press_label)


func _on_button_pressed() -> void:
	_presses += 1
	_press_label.text = "presses: %d" % _presses
	print("GAZEDEMO pressed GazeButton count=%d" % _presses)

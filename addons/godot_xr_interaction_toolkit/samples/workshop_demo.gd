extends Node3D

## Workshop: five grab stations in a row - Throw, Draw, Shoot, Spray, Grab Lab -
## each an INSTANCED prefab from samples/stations/ (edit a station once and it
## updates here and in its own test scene). Every station owns its wiring
## (respawns, reset buttons, the layer filter), so this root only adds the
## back-to-menu button and locks teleport to the station pads.


## Three spheres, one per far_grab_mode, floated about 3 m out so a RAY grab is
## the only way to reach them. Side by side because the modes are only
## meaningful in comparison - the question is never "is ATTRACT good", it is
## "which of these should this object do".
const _FAR_GRAB_BENCH := Vector3(-1.2, 2.0, 2.5)
const _FAR_GRAB_SPACING := 0.8
const _GRABBABLE := "res://addons/godot_xr_interaction_toolkit/grabbable.tscn"


func _ready() -> void:
	if ResourceLoader.exists("res://scripts/back_to_menu_button.gd"):
		add_child((load("res://scripts/back_to_menu_button.gd") as GDScript).new())

	_build_far_grab_bench()

	# DIAGNOSTIC, temporary: measures what the runtime actually reports as a
	# hand leaves view. Three fixes for the drifting out-of-view ray were
	# reasoned from source and all three were wrong on device, so the next one
	# gets written from numbers.
	if ResourceLoader.exists("res://addons/godot_xr_interaction_toolkit/runtime/xr_hand_tracking_probe.gd"):
		var probe := Node.new()
		probe.name = "HandTrackingProbe"
		probe.set_script(load("res://addons/godot_xr_interaction_toolkit/runtime/xr_hand_tracking_probe.gd"))
		add_child(probe)

	# Guided navigation: teleport can ONLY land on the station pads.
	for loco in get_tree().get_nodes_in_group("xr_locomotion"):
		if "anchors_only" in loco:
			loco.anchors_only = true


## The driver resolves its target by walking UP for an XRBaseInteractable, the
## same shape as XRHandActivator - so it must live INSIDE the grabbable it
## drives, not beside it in the scene. Parented to the demo root it found no
## interactable, `_interactable` stayed null, and `_physics_process` returned on
## its first line: present in the tree and completely inert. Reported on device
## as "cant notice it moving towards hand when i twist my pinch".
func _attach_twist_driver(ball: Node) -> void:
	const DRIVER := "res://addons/godot_xr_interaction_toolkit/runtime/xr_pinch_twist_distance_driver.gd"
	if not ResourceLoader.exists(DRIVER):
		return
	var script := load(DRIVER) as GDScript
	if script == null:
		return
	var driver := Node.new()
	driver.name = "PinchTwistDistance"
	driver.set_script(script)
	ball.add_child(driver)


## Built from the shipped grabbable block rather than hand-assembled: it already
## auto-fits its collision to whatever mesh is swapped in, so a sphere gets a
## correctly sized shape for free and there is no way to end up with a
## beautiful object the ray cannot actually hit.
func _build_far_grab_bench() -> void:
	if not ResourceLoader.exists(_GRABBABLE):
		return
	var scene := load(_GRABBABLE) as PackedScene
	if scene == null:
		return

	var modes := [
		{"mode": 0, "name": "ATTRACT", "color": Color(0.35, 0.85, 1.0),
			"caption": "ATTRACT (default)\ncomes to your hand and stays"},
		{"mode": 1, "name": "FIXED", "color": Color(0.9, 0.9, 0.95),
			"caption": "FIXED\nholds its distance, follows your aim"},
		{"mode": 2, "name": "REEL", "color": Color(1.0, 0.65, 0.25),
			"caption": "REEL\npull your hand to wind it in"},
		{"mode": 3, "name": "TWIST", "color": Color(0.75, 0.55, 1.0),
			"caption": "TWIST\nroll your wrist to throttle it in/out"},
	]


	var bench := Node3D.new()
	bench.name = "FarGrabBench"
	bench.position = _FAR_GRAB_BENCH
	add_child(bench)

	var span := float(modes.size() - 1) * _FAR_GRAB_SPACING
	for i in modes.size():
		var entry: Dictionary = modes[i]
		var ball := scene.instantiate()
		ball.name = "FarGrab%s" % entry["name"]
		ball.position = Vector3(i * _FAR_GRAB_SPACING - span * 0.5, 0.0, 0.0)
		if "far_grab_mode" in ball:
			ball.far_grab_mode = entry["mode"]

		var mesh_instance := ball.get_node_or_null("Mesh") as MeshInstance3D
		if mesh_instance:
			var sphere := SphereMesh.new()
			sphere.radius = 0.11
			sphere.height = 0.22
			mesh_instance.mesh = sphere
			var material := StandardMaterial3D.new()
			material.albedo_color = entry["color"]
			material.metallic = 0.15
			material.roughness = 0.45
			mesh_instance.set_surface_override_material(0, material)

		bench.add_child(ball)
		if entry["mode"] == 3:
			_attach_twist_driver(ball)

		var label := Label3D.new()
		label.text = entry["caption"]
		label.position = ball.position + Vector3(0.0, 0.26, 0.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = 0.0016
		label.font_size = 26
		label.outline_size = 8
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bench.add_child(label)

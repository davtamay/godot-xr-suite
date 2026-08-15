extends Node3D
class_name XRSyntheticRoom

## Synthetic scene-understanding data for desktop and editor runs: generates
## a plausible scanned room (jittered surface chunks + semantic planes) and
## feeds it through the REAL mesh bridge's ingestion path, so managers,
## labels, the occlusion punch, collision, and signals all behave exactly as
## they do on a headset - without one. Pairs with the XR simulator the way
## synthetic environments pair with browser emulators.
##
## Inert on web exports by default (real platform data wins there); flip
## enable_on_web to debug the same pipeline in a flat browser tab.

@export var room_size := Vector3(4.0, 2.6, 3.5)
@export var include_furniture := true
## Vertex jitter (m) so surfaces read as scanned reconstruction, not CSG.
@export var scan_jitter := 0.008
## Chunks stream in over this window like a live scan; 0 = all at once.
@export var reveal_duration := 1.2
@export var visualize := true
@export var labels := true
@export var collision := true
@export var enable_on_web := false

const _BRIDGE_SCRIPT := "res://addons/godot_webxr_scene_understanding/runtime/webxr_mesh_bridge.gd"

var _bridge: Node = null
# Queued [id, verts, indices, xform, label] entries, streamed by _process.
var _pending: Array = []
var _reveal_accum := 0.0
var _reveal_interval := 0.0
var _next_id := 1


func _ready() -> void:
	set_process(false)
	if OS.has_feature("web") and not enable_on_web:
		return
	add_to_group("xr_synthetic_room")
	# Bridges and managers build themselves in their own _ready; attach
	# after the tree settles so an existing bridge is found, not raced.
	_setup.call_deferred()


func _setup() -> void:
	_bridge = get_tree().get_first_node_in_group("webxr_mesh_bridge")
	if _bridge == null:
		# On native the bridge never joins its group (its _ready is
		# web-gated); adopt an inert instance if the scene carries one.
		_bridge = _find_by_method(get_tree().root, "synthetic_store_chunk")
	if _bridge == null:
		_bridge = (load(_BRIDGE_SCRIPT) as GDScript).new()
		_bridge.name = "SyntheticMeshBridge"
		add_child(_bridge)
	_bridge.auto_visualize = visualize
	_bridge.show_labels = labels
	_bridge.generate_collision = collision
	_bridge.enable_synthetic()
	_build_room()
	if reveal_duration <= 0.0:
		while not _pending.is_empty():
			_feed_next()
	else:
		_reveal_interval = reveal_duration / maxf(1.0, float(_pending.size()))
		set_process(true)


func _find_by_method(p_node: Node, p_method: String) -> Node:
	if p_node != self and p_node.has_method(p_method):
		return p_node
	for child in p_node.get_children():
		var hit := _find_by_method(child, p_method)
		if hit != null:
			return hit
	return null


func _process(delta: float) -> void:
	_reveal_accum += delta
	while not _pending.is_empty() and _reveal_accum >= _reveal_interval:
		_reveal_accum -= _reveal_interval
		_feed_next()
	if _pending.is_empty():
		set_process(false)


func _feed_next() -> void:
	var entry: Array = _pending.pop_front()
	_bridge.synthetic_store_chunk(entry[0], entry[1], entry[2], entry[3], entry[4])


func _build_room() -> void:
	var w := room_size.x
	var h := room_size.y
	var d := room_size.z
	var rng := RandomNumberGenerator.new()
	# Deterministic: a debug session reproduces the same "scan" every run.
	rng.seed = 0xB00C
	_queue_grid(Vector3(0, 0, 0), Vector3(w * 0.5, 0, 0), Vector3(0, 0, d * 0.5), "floor", rng)
	_queue_grid(Vector3(0, h, 0), Vector3(w * 0.5, 0, 0), Vector3(0, 0, d * 0.5), "ceiling", rng)
	_queue_grid(Vector3(0, h * 0.5, -d * 0.5), Vector3(w * 0.5, 0, 0), Vector3(0, h * 0.5, 0), "wall", rng)
	_queue_grid(Vector3(0, h * 0.5, d * 0.5), Vector3(w * 0.5, 0, 0), Vector3(0, h * 0.5, 0), "wall", rng)
	_queue_grid(Vector3(-w * 0.5, h * 0.5, 0), Vector3(0, 0, d * 0.5), Vector3(0, h * 0.5, 0), "wall", rng)
	_queue_grid(Vector3(w * 0.5, h * 0.5, 0), Vector3(0, 0, d * 0.5), Vector3(0, h * 0.5, 0), "wall", rng)
	if include_furniture:
		_queue_box(Vector3(-w * 0.22, 0.37, -d * 0.18), Vector3(0.55, 0.37, 0.33), "table", rng)
		_queue_box(Vector3(w * 0.28, 0.30, d * 0.22), Vector3(0.85, 0.30, 0.40), "couch", rng)
	# Semantic planes at surface centers: the label pass merges these with
	# chunk labels, mirroring how Quest (planes) and Android XR (mesh
	# labels) serve semantics through different modules.
	_bridge.synthetic_store_plane(1, Vector3(0, 0, 0), "floor")
	_bridge.synthetic_store_plane(2, Vector3(0, h, 0), "ceiling")
	_bridge.synthetic_store_plane(3, Vector3(0, h * 0.5, -d * 0.5), "wall")
	_bridge.synthetic_store_plane(4, Vector3(0, h * 0.5, d * 0.5), "wall")
	_bridge.synthetic_store_plane(5, Vector3(-w * 0.5, h * 0.5, 0), "wall")
	_bridge.synthetic_store_plane(6, Vector3(w * 0.5, h * 0.5, 0), "wall")


## A subdivided quad spanning +-p_u and +-p_v around p_center, jittered so
## it reads as reconstruction. Geometry is chunk-local on a translation-only
## pose, matching how devices serve chunks.
func _queue_grid(p_center: Vector3, p_u: Vector3, p_v: Vector3, p_label: String, p_rng: RandomNumberGenerator, p_subdiv := 6) -> void:
	var verts := PackedVector3Array()
	var normal := p_u.cross(p_v)
	if normal.length_squared() > 0.0:
		normal = normal.normalized()
	for row in p_subdiv + 1:
		for col in p_subdiv + 1:
			var su := (float(col) / p_subdiv) * 2.0 - 1.0
			var sv := (float(row) / p_subdiv) * 2.0 - 1.0
			var jitter := normal * p_rng.randf_range(-scan_jitter, scan_jitter)
			verts.push_back(p_u * su + p_v * sv + jitter)
	var indices := PackedInt32Array()
	var stride := p_subdiv + 1
	for row in p_subdiv:
		for col in p_subdiv:
			var a := row * stride + col
			indices.append_array(PackedInt32Array([a, a + 1, a + stride, a + 1, a + stride + 1, a + stride]))
	_pending.push_back([_next_id, verts, indices, Transform3D(Basis(), p_center), p_label])
	_next_id += 1


func _queue_box(p_center: Vector3, p_half: Vector3, p_label: String, p_rng: RandomNumberGenerator) -> void:
	var verts := PackedVector3Array()
	for corner in 8:
		var sign := Vector3(
			-1.0 if (corner & 1) == 0 else 1.0,
			-1.0 if (corner & 2) == 0 else 1.0,
			-1.0 if (corner & 4) == 0 else 1.0)
		var jitter := Vector3(
			p_rng.randf_range(-scan_jitter, scan_jitter),
			p_rng.randf_range(-scan_jitter, scan_jitter),
			p_rng.randf_range(-scan_jitter, scan_jitter))
		verts.push_back(sign * p_half + jitter)
	var indices := PackedInt32Array([
		0, 1, 3, 0, 3, 2, # -y? faces cover the box; the scan material is cull-disabled.
		4, 6, 7, 4, 7, 5,
		0, 2, 6, 0, 6, 4,
		1, 5, 7, 1, 7, 3,
		0, 4, 5, 0, 5, 1,
		2, 3, 7, 2, 7, 6,
	])
	_pending.push_back([_next_id, verts, indices, Transform3D(Basis(), p_center), p_label])
	_next_id += 1


## Drops and re-feeds the room (e.g. after changing exports at runtime).
func rebuild() -> void:
	if _bridge == null:
		return
	_bridge.synthetic_clear()
	_pending.clear()
	_next_id = 1
	_build_room()
	while not _pending.is_empty():
		_feed_next()

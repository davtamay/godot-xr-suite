extends RefCounted
## Consumes the engine-owned, view-normalized WebXR depth contract.
## Sampling stays on the GPU; only scan/hard-mesh consumers request readback.
var texture: Texture2DArrayRD
var info: Dictionary = {}
var active := false
var pending := false
var _epoch := 0


func clear() -> void:
	_epoch += 1
	active = false
	pending = false
	info = {}
	if texture:
		texture.texture_rd_rid = RID()
	texture = null


func update(system_info: Dictionary) -> bool:
	var depth: Dictionary = system_info.get("webxr_depth", {})
	var rid: RID = system_info.get("webxr_depth_texture_array_rd", RID())
	if depth.get("status", "") != "ok" or not rid.is_valid() or int(depth.get("valid_mask", 0)) == 0:
		clear()
		return false
	if texture == null:
		texture = Texture2DArrayRD.new()
	if texture.texture_rd_rid != rid:
		_epoch += 1 # Ignore callbacks from a resized/replaced session texture.
		pending = false
		texture.texture_rd_rid = rid
	info = depth.duplicate(true)
	active = true
	return true


func request_mesh(system_info: Dictionary, space_to_local: Transform3D, world_scale: float, callback: Callable) -> void:
	if pending or not active:
		return
	var rid: RID = system_info.get("webxr_depth_readback_array_rd", RID())
	if not rid.is_valid():
		return
	var views: Array = info.get("views", [])
	var layer := -1
	for i in range(views.size()):
		if views[i].get("valid", false):
			layer = i
			break
	if layer < 0:
		return
	pending = true
	var captured := info.duplicate(true)
	RenderingServer.call_on_render_thread(_request_on_render_thread.bind(rid, layer, captured, space_to_local, world_scale, _epoch, callback))


func _request_on_render_thread(rid: RID, layer: int, captured: Dictionary, space_to_local: Transform3D, world_scale: float, epoch: int, callback: Callable) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not rd.texture_is_valid(rid):
		_received.call_deferred(PackedByteArray(), layer, captured, space_to_local, world_scale, epoch, callback)
		return
	var error := rd.texture_get_data_async(rid, layer, _readback_received.bind(layer, captured, space_to_local, world_scale, epoch, callback))
	if error != OK:
		_received.call_deferred(PackedByteArray(), layer, captured, space_to_local, world_scale, epoch, callback)


func _readback_received(data: PackedByteArray, layer: int, captured: Dictionary, space_to_local: Transform3D, world_scale: float, epoch: int, callback: Callable) -> void:
	_received.call_deferred(data, layer, captured, space_to_local, world_scale, epoch, callback)


func _received(data: PackedByteArray, layer: int, captured: Dictionary, space_to_local: Transform3D, world_scale: float, epoch: int, callback: Callable) -> void:
	if epoch != _epoch:
		return # Session ended, provider changed or data disappeared while pending.
	pending = false
	var grid := build_grid(data, captured, layer, space_to_local, world_scale)
	if not grid.is_empty() and callback.is_valid():
		callback.call(grid)


static func view_transform(view: Dictionary) -> Transform3D:
	var m: Array = view.get("transform", [])
	if m.size() != 16:
		return Transform3D.IDENTITY
	return Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])), Vector3(m[12], m[13], m[14]))


static func build_grid(data: PackedByteArray, captured: Dictionary, layer: int, space_to_local: Transform3D = Transform3D.IDENTITY, world_scale: float = 1.0) -> Dictionary:
	var width := int(captured.get("width", 0))
	var height := int(captured.get("height", 0))
	var views: Array = captured.get("views", [])
	if width <= 0 or height <= 0 or data.size() != width * height * 4 or layer < 0 or layer >= views.size():
		return {}
	var view: Dictionary = views[layer]
	var projection: Array = view.get("projection", [])
	if not view.get("valid", false) or projection.size() != 16 or is_zero_approx(projection[0]) or is_zero_approx(projection[5]):
		return {}
	var transform := view_transform(view)
	var values := data.to_float32_array()
	var gw := mini(width, 64)
	var gh := mini(height, 48)
	var points: Array = []
	var valid: Array = []
	for y in range(gh):
		for x in range(gw):
			var sx := mini(width - 1, int((x + 0.5) * width / gw))
			var sy := mini(height - 1, int((y + 0.5) * height / gh))
			var meters := float(values[sy * width + sx])
			var good := is_finite(meters) and meters > 0.0
			var u := (sx + 0.5) / width
			var v := (sy + 0.5) / height
			var point := Vector3.ZERO
			if good:
				point = transform * Vector3(meters * (2.0 * u - 1.0 + projection[8]) / projection[0], meters * (1.0 - 2.0 * v + projection[9]) / projection[5], -meters)
				point = space_to_local * (point * world_scale)
			points.append_array([point.x, point.y, point.z])
			valid.append(good)
	var eye := space_to_local * (transform.origin * world_scale)
	return {"seq": captured.get("sequence", 0), "gw": gw, "gh": gh, "pts": points, "val": valid, "eye": [eye.x, eye.y, eye.z]}

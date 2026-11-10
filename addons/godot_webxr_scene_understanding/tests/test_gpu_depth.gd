extends SceneTree
const GPU_DEPTH = preload("res://addons/godot_webxr_scene_understanding/runtime/webxr_gpu_depth.gd")

func _initialize() -> void:
	var identity := [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
	var transform: Array = identity.duplicate()
	transform[12] = 1
	var frame := {"width": 2, "height": 2, "sequence": 9, "views": [{"valid": true, "projection": identity, "transform": transform}]}
	var bytes := PackedFloat32Array([1,2,3,0]).to_byte_array()
	var grid := GPU_DEPTH.build_grid(bytes, frame, 0, Transform3D(Basis.IDENTITY, Vector3(10,0,0)), 2.0)
	assert(grid.gw == 2 and grid.gh == 2 and grid.seq == 9)
	assert(grid.pts.slice(0,3) == [11.0,1.0,-2.0])
	assert(grid.pts.slice(6,9) == [9.0,-3.0,-6.0])
	assert(grid.eye == [12.0,0.0,0.0])
	assert(grid.val == [true,true,true,false])
	assert(GPU_DEPTH.build_grid(PackedByteArray(),frame,0).is_empty())
	assert(GPU_DEPTH.build_grid(bytes,frame,1).is_empty())
	frame.views[0].valid = false
	assert(GPU_DEPTH.build_grid(bytes,frame,0).is_empty())
	frame.views[0].valid = true
	grid = GPU_DEPTH.build_grid(PackedFloat32Array([NAN,INF,-1,1]).to_byte_array(),frame,0)
	assert(grid.val == [false,false,false,true])
	var consumer = GPU_DEPTH.new()
	consumer.pending = true
	consumer.clear()
	consumer.pending = true
	consumer._received(bytes,0,frame,Transform3D.IDENTITY,1.0,0,Callable())
	assert(consumer.pending) # An obsolete completion cannot clear a new request.
	consumer.pending = false
	assert(not consumer.update({"webxr_depth": {"status": "no_depth_data"}}))
	print("PASS: GPU depth unprojection, validity, world scale and cancellation")
	quit(0)

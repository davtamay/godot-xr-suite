extends SceneTree

## Replays a trace raw and conditioned, and prints the three acceptance numbers.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tools/trace/measure_traces.gd -- <trace.res>

const _WRIST := XRHandTracker.HAND_JOINT_WRIST
const _TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: ... -- <res://path/to/trace.res>")
		quit(1)
		return

	var trace := XRHandTrace.load_trace(args[0])
	if trace == null:
		push_error("could not load %s" % args[0])
		quit(1)
		return

	var raw_wrist := _replay(trace, false, _WRIST)
	var conditioned_wrist := _replay(trace, true, _WRIST)
	var raw_tip := _replay(trace, false, _TIP)
	var conditioned_tip := _replay(trace, true, _TIP)

	var dt := _mean_dt(trace)
	print("frames                : %d" % trace.size())
	print("mean dt               : %.4f s (%.1f Hz)" % [dt, 1.0 / maxf(dt, 0.0001)])
	print("wrist jitter raw      : %.6f m" % XRHandTraceMetrics.rest_jitter(raw_wrist))
	print("wrist jitter cond     : %.6f m" % XRHandTraceMetrics.rest_jitter(conditioned_wrist))
	print("tip   jitter raw      : %.6f m" % XRHandTraceMetrics.rest_jitter(raw_tip))
	print("tip   jitter cond     : %.6f m" % XRHandTraceMetrics.rest_jitter(conditioned_tip))
	print("wrist lag             : %.4f s" % XRHandTraceMetrics.motion_lag_seconds(raw_wrist, conditioned_wrist, dt, 12))
	print("tip   lag             : %.4f s" % XRHandTraceMetrics.motion_lag_seconds(raw_tip, conditioned_tip, dt, 12))
	print("tip bone dev raw      : %.6f m" % XRHandTraceMetrics.bone_length_deviation(trace.frames, _TIP))
	print("tip bone dev cond     : %.6f m" % XRHandTraceMetrics.bone_length_deviation(_conditioned_frames(trace), _TIP))
	quit(0)

func _replay(trace: XRHandTrace, conditioned: bool, joint: int) -> PackedVector3Array:
	var player := XRHandTracePlayer.new(trace)
	var source: XRHandPoseSource = XRHandFilter.new(player) if conditioned else player
	var frame := XRHandFrame.new()
	var samples := PackedVector3Array()
	for step in range(trace.size()):
		if source.capture(1, 0, frame):
			samples.append(frame.joint_transforms[joint].origin)
	return samples

func _conditioned_frames(trace: XRHandTrace) -> Array:
	var filter := XRHandFilter.new(XRHandTracePlayer.new(trace))
	var frame := XRHandFrame.new()
	var out: Array = []
	for step in range(trace.size()):
		if not filter.capture(1, 0, frame):
			continue
		var transforms: Array[Transform3D] = []
		transforms.resize(XRHandFrame.JOINT_COUNT)
		for j in range(XRHandFrame.JOINT_COUNT):
			transforms[j] = frame.joint_transforms[j]
		out.append({"transforms": transforms, "flags": frame.joint_flags.duplicate()})
	return out

func _mean_dt(trace: XRHandTrace) -> float:
	if trace.size() < 2:
		return 1.0 / 72.0
	var first := int(trace.frames[0]["timestamp_usec"])
	var last := int(trace.frames[trace.size() - 1]["timestamp_usec"])
	return float(last - first) / 1_000_000.0 / float(trace.size() - 1)

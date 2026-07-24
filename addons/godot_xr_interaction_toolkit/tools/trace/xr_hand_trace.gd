class_name XRHandTrace
extends Resource

## A recorded stream of raw hand frames, so conditioning can be measured and
## tuned offline against real tracking data instead of guesses.

@export var frames: Array = []

func append_frame(frame: XRHandFrame) -> void:
	var transforms: Array[Transform3D] = []
	transforms.resize(XRHandFrame.JOINT_COUNT)
	for joint in range(XRHandFrame.JOINT_COUNT):
		transforms[joint] = frame.joint_transforms[joint]
	frames.append({
		"timestamp_usec": frame.timestamp_usec,
		"hand": frame.hand,
		"transforms": transforms,
		"radii": frame.joint_radii.duplicate(),
		"flags": frame.joint_flags.duplicate(),
		"tracking_valid": frame.tracking_valid,
	})

func size() -> int:
	return frames.size()

func save(path: String) -> Error:
	return ResourceSaver.save(self, path)

static func load_trace(path: String) -> XRHandTrace:
	if not ResourceLoader.exists(path):
		return null
	# No type hint: ResourceLoader's type_hint matches ClassDB/recognized-extension
	# types, not GDScript "class_name" globals -- passing "XRHandTrace" here makes
	# the loader report the file as not found even though it exists and loads fine
	# untyped. The cast below still gives static callers a typed result.
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as XRHandTrace

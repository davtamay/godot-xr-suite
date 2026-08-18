@tool
class_name XRGripImport
extends RefCounted

## Turn hand landmarks from ANY source into a grip this suite can hold with.
##
## The suite's recorded grips are joint POSITIONS - XRHandGesture.joint_snapshot,
## retargeted onto whatever hand is playing them. That happens to be the output
## format of nearly every way there is to obtain a hand pose:
##
##   - a reference PHOTO of someone holding the object, through MediaPipe Hands
##     (21 landmarks, and the reason this module exists: you can photograph a
##     real grip instead of miming one)
##   - a captured grasp DATASET (ContactPose, GRAB) - real humans holding real
##     objects, with meshes and contact maps
##   - a learned SYNTHESISER (GrabNet, DexGraspNet and successors), which emit
##     joint positions for an arbitrary mesh
##   - the suite's own recording station, which already writes this format
##
## So none of those needs a pipeline built for it. They need converting to one
## array, which is what this does. An imported grip is indistinguishable from a
## recorded one downstream - same resource, same lookup, same playback.
##
## WHAT AN IMPORT CANNOT GIVE YOU, stated plainly: a single photo carries no
## reliable absolute depth, so a MediaPipe grip arrives structurally right -
## splay, thumb opposition, per-joint variation, the things an analytic fit
## cannot invent - and dimensionally approximate. Snapping it onto the object's
## collider afterwards is what makes it exact; the grab point's fitter already
## does that arithmetic.

## MediaPipe Hands landmark order, which is the de-facto interchange layout.
## 0 wrist, then four per finger from base to tip.
const MEDIAPIPE_WRIST := 0
const MEDIAPIPE_CHAINS := {
	"thumb": [1, 2, 3, 4],
	"index": [5, 6, 7, 8],
	"middle": [9, 10, 11, 12],
	"ring": [13, 14, 15, 16],
	"pinky": [17, 18, 19, 20],
}

## Where each finger's metacarpal sits between wrist and knuckle. MediaPipe has
## no metacarpal landmark for the four fingers - it starts at the knuckle - so
## the joint the suite expects is interpolated. Not a fudge: the metacarpals
## are inside the palm and barely move relative to it, which is exactly why
## every grip convention in this suite reads direction from them.
const _METACARPAL_ALONG := 0.45


## Convert MediaPipe's 21 landmarks into the suite's 26-joint snapshot.
## `landmarks` is an Array of Vector3 (or of 3-element Arrays) in MediaPipe
## world-landmark order; any consistent units work, since playback retargets
## onto the playing hand's own bone lengths.
static func snapshot_from_mediapipe(landmarks: Array) -> PackedVector3Array:
	var points := _as_vectors(landmarks)
	if points.size() < 21:
		return PackedVector3Array()

	var out := PackedVector3Array()
	out.resize(XRHandTracker.HAND_JOINT_MAX)
	var wrist: Vector3 = points[MEDIAPIPE_WRIST]
	out[XRHandTracker.HAND_JOINT_WRIST] = wrist

	# The thumb maps one-to-one: MediaPipe's CMC/MCP/IP/TIP are the suite's
	# metacarpal/proximal/distal/tip.
	var thumb: Array = MEDIAPIPE_CHAINS["thumb"]
	out[XRHandTracker.HAND_JOINT_THUMB_METACARPAL] = points[thumb[0]]
	out[XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL] = points[thumb[1]]
	out[XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL] = points[thumb[2]]
	out[XRHandTracker.HAND_JOINT_THUMB_TIP] = points[thumb[3]]

	# The four fingers each gain an interpolated metacarpal, then map
	# knuckle -> proximal, PIP -> intermediate, DIP -> distal, tip -> tip.
	var finger_joints := {
		"index": [
			XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
			XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
			XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
			XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
			XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
		],
		"middle": [
			XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
			XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
			XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
			XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
			XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
		],
		"ring": [
			XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
			XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
			XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
			XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
			XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
		],
		"pinky": [
			XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
			XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
			XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
			XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
			XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
		],
	}
	for finger in finger_joints:
		var source: Array = MEDIAPIPE_CHAINS[finger]
		var target: Array = finger_joints[finger]
		var knuckle: Vector3 = points[source[0]]
		out[target[0]] = wrist.lerp(knuckle, _METACARPAL_ALONG)
		for i in 4:
			out[target[i + 1]] = points[source[i]]

	# The palm joint the suite's grip anchor reads: the centre of the middle
	# metacarpal BONE, the same construction the bind and the simulator use, so
	# an imported grip anchors exactly where a recorded one does.
	out[XRHandTracker.HAND_JOINT_PALM] = (
			out[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL]
			+ out[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL]) * 0.5
	return out


## Build a grip resource from a snapshot. Named so a grab point finds it: the
## suite looks up "grip_<object scene name>", which is the same name the
## recording station saves under - import and record are interchangeable.
static func gesture_from_snapshot(snapshot: PackedVector3Array, grip_name: String, hand := 1) -> XRHandGesture:
	if snapshot.size() < XRHandTracker.HAND_JOINT_MAX:
		return null
	var gesture := XRHandGesture.new()
	gesture.gesture_name = grip_name
	gesture.joint_snapshot = snapshot
	gesture.recorded_hand = hand
	return gesture


## One call from a MediaPipe result to a saved grip.
static func import_mediapipe(landmarks: Array, grip_name: String, save_dir := "user://gestures", hand := 1) -> String:
	var snapshot := snapshot_from_mediapipe(landmarks)
	if snapshot.is_empty():
		return ""
	var gesture := gesture_from_snapshot(snapshot, grip_name, hand)
	if gesture == null:
		return ""
	DirAccess.make_dir_recursive_absolute(save_dir)
	var path := save_dir.path_join("%s.tres" % grip_name)
	return path if ResourceSaver.save(gesture, path) == OK else ""


## Read a landmark file and import it. Accepts either a bare array of points or
## MediaPipe's own shape ({"landmarks": [{"x":..,"y":..,"z":..}, ...]}), so a
## file straight out of a MediaPipe script needs no reshaping first.
static func import_json(json_path: String, grip_name: String, save_dir := "user://gestures", hand := 1) -> String:
	if not FileAccess.file_exists(json_path):
		return ""
	var text := FileAccess.get_file_as_string(json_path)
	var parsed: Variant = JSON.parse_string(text)
	var raw: Variant = parsed
	if parsed is Dictionary:
		for key in ["landmarks", "world_landmarks", "points"]:
			if (parsed as Dictionary).has(key):
				raw = (parsed as Dictionary)[key]
				break
	return import_mediapipe(raw as Array, grip_name, save_dir, hand) if raw is Array else ""


## Landmarks arrive as Vector3, as [x, y, z], or as {"x":..}, depending on which
## tool produced them. Normalise once here rather than at every call site.
static func _as_vectors(landmarks: Array) -> Array:
	var out := []
	for entry in landmarks:
		if entry is Vector3:
			out.append(entry)
		elif entry is Array and (entry as Array).size() >= 3:
			out.append(Vector3(float(entry[0]), float(entry[1]), float(entry[2])))
		elif entry is Dictionary and (entry as Dictionary).has("x"):
			var d: Dictionary = entry
			out.append(Vector3(float(d["x"]), float(d["y"]), float(d.get("z", 0.0))))
	return out

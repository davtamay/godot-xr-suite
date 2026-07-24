class_name XRHandTraceMetrics
extends RefCounted

## The three quantities that decide whether a conditioning parameter set is
## better or merely different. Jitter and lag are in direct tension -- that
## tension is what an adaptive filter exists to manage -- so both are always
## reported together. Bone-length deviation checks the rigidity guarantee.

## RMS deviation from the mean over a segment where the hand was held still.
## Metres. Lower is steadier.
static func rest_jitter(samples: PackedVector3Array) -> float:
	if samples.size() < 2:
		return 0.0
	var mean := Vector3.ZERO
	for sample in samples:
		mean += sample
	mean /= float(samples.size())
	var total := 0.0
	for sample in samples:
		total += (sample - mean).length_squared()
	return sqrt(total / float(samples.size()))

## Delay between raw and conditioned, found by the frame shift that best aligns
## them. Seconds. Higher is laggier.
static func motion_lag_seconds(raw: PackedVector3Array, conditioned: PackedVector3Array, dt: float, max_shift: int) -> float:
	var count := mini(raw.size(), conditioned.size())
	if count < 2 or max_shift < 1:
		return 0.0
	var best_shift := 0
	var best_error := INF
	for shift in range(0, max_shift + 1):
		var error := 0.0
		var compared := 0
		for index in range(shift, count):
			error += (conditioned[index] - raw[index - shift]).length_squared()
			compared += 1
		if compared == 0:
			continue
		error /= float(compared)
		if error < best_error:
			best_error = error
			best_shift = shift
	return float(best_shift) * dt

## Standard deviation of one bone's length across a trace. Metres.
## The formal check on the parent-local design: filtering must not change it.
static func bone_length_deviation(frames: Array, joint: int) -> float:
	var parent_joint: int = XRHandJointHierarchy.PARENT[joint]
	if parent_joint < 0:
		return 0.0

	var lengths := PackedFloat32Array()
	for entry in frames:
		var transforms: Array = entry["transforms"]
		var flags: PackedInt32Array = entry["flags"]
		var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
		if (flags[joint] & valid) == 0 or (flags[parent_joint] & valid) == 0:
			continue
		var child: Transform3D = transforms[joint]
		var parent: Transform3D = transforms[parent_joint]
		lengths.append((child.origin - parent.origin).length())

	if lengths.size() < 2:
		return 0.0
	var mean := 0.0
	for length in lengths:
		mean += length
	mean /= float(lengths.size())
	var total := 0.0
	for length in lengths:
		total += pow(length - mean, 2.0)
	return sqrt(total / float(lengths.size()))

class_name XRHandJointHierarchy
extends RefCounted

## Skeleton topology for Godot's 26 XRHandTracker joints.
##
## XRHandTracker reports every joint in one common space, not hierarchically.
## Conditioning needs parent-local rotations (so filtering can never change a
## bone length), which requires knowing who parents whom.

const _WRIST := XRHandTracker.HAND_JOINT_WRIST

## Finger chains, root-first. Matches the chains declared in xr_simulator.gd.
const CHAINS := [
	[XRHandTracker.HAND_JOINT_THUMB_METACARPAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_THUMB_TIP],
	[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP],
]

## PARENT[joint] = parent joint id, or -1 for the wrist (the root).
static var PARENT: PackedInt32Array = _build_parents()
## IS_TIP[joint] = 1 for the five fingertips (leaf joints), else 0.
static var IS_TIP: PackedByteArray = _build_tips()
## Traversal order guaranteeing every parent precedes its children.
static var ORDER: PackedInt32Array = _build_order()

static func _build_parents() -> PackedInt32Array:
	var parents := PackedInt32Array()
	parents.resize(XRHandTracker.HAND_JOINT_MAX)
	parents.fill(_WRIST)
	parents[_WRIST] = -1
	parents[XRHandTracker.HAND_JOINT_PALM] = _WRIST
	for chain in CHAINS:
		# chain[0] is a metacarpal and keeps the default wrist parent.
		for index in range(1, chain.size()):
			parents[chain[index]] = chain[index - 1]
	return parents

static func _build_tips() -> PackedByteArray:
	var tips := PackedByteArray()
	tips.resize(XRHandTracker.HAND_JOINT_MAX)
	tips.fill(0)
	for chain in CHAINS:
		tips[chain[chain.size() - 1]] = 1
	return tips

static func _build_order() -> PackedInt32Array:
	var order := PackedInt32Array()
	order.append(_WRIST)
	order.append(XRHandTracker.HAND_JOINT_PALM)
	for chain in CHAINS:
		for joint in chain:
			order.append(joint)
	return order

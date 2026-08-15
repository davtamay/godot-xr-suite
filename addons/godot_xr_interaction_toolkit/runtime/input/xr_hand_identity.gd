class_name XRHandIdentity
extends RefCounted

## Converts between the hand encodings this suite and the engine use.
##
## The two integer spaces OVERLAP: XRInputAdapter.Hand is LEFT=0/RIGHT=1 while
## XRPositionalTracker.TrackerHand is UNKNOWN=0/LEFT=1/RIGHT=2 - so Hand.RIGHT
## equals TRACKER_HAND_LEFT. Since nearly every signature types hands as bare
## int, an inline conversion written in the wrong space typechecks and silently
## means the opposite hand. Convert through these helpers, never inline.
##
## Two sentinels legitimately travel through hand-typed ints in this suite:
## -1 = "any hand" (locomotion, gesture recognizers) and 2 = "both hands"
## (gesture ghost/recorder). is_valid() is the guard; every converter answers
## sentinels with its own "unknown" value instead of silently picking a side.

const ANY := -1
const BOTH := 2


## True only for a concrete LEFT or RIGHT.
static func is_valid(hand: int) -> bool:
	return hand == XRInputAdapter.Hand.LEFT or hand == XRInputAdapter.Hand.RIGHT


## LEFT <-> RIGHT. Sentinels come back unchanged - there is no "other" of ANY.
static func other(hand: int) -> int:
	if not is_valid(hand):
		return hand
	return XRInputAdapter.Hand.RIGHT if hand == XRInputAdapter.Hand.LEFT else XRInputAdapter.Hand.LEFT


## Hand -> XRPositionalTracker.TrackerHand. Sentinels map to UNKNOWN, never
## to a side.
static func to_tracker_hand(hand: int) -> int:
	if hand == XRInputAdapter.Hand.LEFT:
		return XRPositionalTracker.TRACKER_HAND_LEFT
	if hand == XRInputAdapter.Hand.RIGHT:
		return XRPositionalTracker.TRACKER_HAND_RIGHT
	return XRPositionalTracker.TRACKER_HAND_UNKNOWN


## XRPositionalTracker.TrackerHand -> Hand. UNKNOWN maps to ANY.
static func from_tracker_hand(tracker_hand: int) -> int:
	if tracker_hand == XRPositionalTracker.TRACKER_HAND_LEFT:
		return XRInputAdapter.Hand.LEFT
	if tracker_hand == XRPositionalTracker.TRACKER_HAND_RIGHT:
		return XRInputAdapter.Hand.RIGHT
	return ANY


## "left"/"right"; "" for sentinels.
static func side_text(hand: int) -> String:
	if hand == XRInputAdapter.Hand.LEFT:
		return "left"
	if hand == XRInputAdapter.Hand.RIGHT:
		return "right"
	return ""


## "Left"/"Right"; "" for sentinels.
static func side_label(hand: int) -> String:
	if hand == XRInputAdapter.Hand.LEFT:
		return "Left"
	if hand == XRInputAdapter.Hand.RIGHT:
		return "Right"
	return ""


## Parses handedness out of any name-ish string: "left", "Left", "left_hand",
## "/user/hand_tracker/left", a WebXR handedness value. ANY when neither side
## word appears. ("left" never occurs inside "right" or vice versa, so the
## check order cannot misread a well-formed name.)
static func from_text(text: String) -> int:
	var lower := text.to_lower()
	if lower.find("left") >= 0:
		return XRInputAdapter.Hand.LEFT
	if lower.find("right") >= 0:
		return XRInputAdapter.Hand.RIGHT
	return ANY


## The controller tracker names the engine registers. Empty for sentinels.
static func controller_tracker_name(hand: int) -> StringName:
	if hand == XRInputAdapter.Hand.LEFT:
		return &"left_hand"
	if hand == XRInputAdapter.Hand.RIGHT:
		return &"right_hand"
	return &""


## The canonical XRHandTracker paths. Empty for sentinels.
static func hand_tracker_path(hand: int) -> StringName:
	if hand == XRInputAdapter.Hand.LEFT:
		return &"/user/hand_tracker/left"
	if hand == XRInputAdapter.Hand.RIGHT:
		return &"/user/hand_tracker/right"
	return &""


## The per-hand root node name both hand visualizers build and other addons
## look up ("LeftHandTracking"/"RightHandTracking"). One symbol so a rename
## cannot silently strand a consumer on get_node_or_null -> null. The one
## deliberately dependency-free copy of this contract lives in
## godot_xr_scene_understanding's environment_depth_provider.gd, which must
## parse without this addon installed - keep that file in mind when changing
## the shape here.
static func hand_tracking_root_name(hand: int) -> String:
	if not is_valid(hand):
		return ""
	return "%sHandTracking" % side_label(hand)

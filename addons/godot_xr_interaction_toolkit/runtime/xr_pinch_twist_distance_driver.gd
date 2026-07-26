@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRPinchTwistDistanceDriver
extends Node

## Wrist-roll ABSOLUTE distance control for XRGrabInteractable.FarGrabMode.TWIST
## far-grabs (docs/far-grab-modes-design.md, "Phase 2: TWIST" and its
## "TWIST correction: absolute, not a throttle" amendment).
##
## Pinch IS grab for a bare hand, so thumb-and-index are occupied the instant
## a far-grab starts. The wrist stays free, and rolling around the direction
## you are already pointing is decoupled from aiming -- aiming swings the ray
## ACROSS its own axis; roll turns AROUND it.
##
## Parent this INSIDE a grab interactable, the same placement XRHandActivator
## uses: it finds the interactable by walking up its ancestors and, every
## physics frame, checks whichever interactor currently holds it per hand.
## Soft dependency on godot_xr_hands, following xr_microgesture_locomotion_driver.gd
## exactly -- inert (no wrist tracker ever resolves) when that addon, or hand
## tracking, is absent; xr.interaction keeps requires=[] in xr_package.cfg.
##
## ABSOLUTE mapping, not a rate/throttle. A throttle (roll drives the RATE of
## change, hold to keep travelling) was the original design and was corrected
## on-device ("seems like it only goes further"): reversing a throttle means
## rolling PAST neutral the opposite way, and a pinch-grab wrist pose does not
## have that bidirectional travel -- supination one way is comfortable,
## pronation the other is limited, so there is real travel in one direction
## and almost none in the other. Absolute removes the constraint: the twist
## angle away from the roll captured when TWIST engaged maps to a distance
## OFFSET from the distance the object was held at when it engaged, so
## rolling back toward the start RETRACES the value instead of requiring
## further travel to undo. Only one direction of travel is ever needed.
##
## Technique read (not code) from Meta's Hand-Tracking-Template
## PinchAndTwistEventSource, which emits a normalized twist-angle value with a
## start threshold, a small deadband, and change-gated emission, leaving the
## mapping to the consumer -- permitted under CLAUDE.md as an
## order-of-magnitude sanity check on the shape of the technique. The
## constants below are ours, chosen and justified independently, not copied.
##
## Only acts on a held object whose far_grab_mode is TWIST, and only while a
## ray interactor (a far grab) holds it -- a near/direct hold is untouched.
## Only acts once a wrist joint resolves for the holding hand, which is never
## true for a controller (no pinch, no wrist joint): an object authored TWIST
## but held by a controller simply holds its distance, exactly like FIXED,
## rather than breaking.

const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")
const XRInputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")

## Metres the distance offset reaches at full deflection (+/- twist_full_angle_degrees)
## from the distance held when TWIST engaged -- a bounded SPAN around that
## distance, not the ray's whole min_grab_distance..max_distance range. This is
## what keeps the gain sane: the original rate design was rejected in part on
## range grounds (a wide output forces a gain that amplifies tracking jitter),
## and bounding the span rather than the whole range is what carries that
## reasoning into the absolute mapping. 2.0 m: enough to place something
## across a room-scale gap in one twist without needing to re-grab, small
## enough that the jitter a comfortable ~90 degree twist amplifies stays in
## the low centimetres. Order-of-magnitude, owed on-device tuning.
##
## Governs OUTWARD deflection unconditionally, and INWARD deflection only when
## twist_pull_reaches_hand is false -- see that export for why inward has its
## own, engagement-distance-dependent span by default.
@export_range(0.05, 10.0, 0.01, "or_greater") var twist_span_metres := 2.0

## Reported on device: full inward twist only closed about three quarters of
## the distance to the hand, because twist_span_metres is a FIXED offset --
## engage at 3 m and full inward twist lands at 1 m (3/4 of the way in); engage
## at 10 m and the same fixed span barely moves it proportionally. When true
## (default), full inward deflection instead maps to the ray's
## min_grab_distance -- all the way to the hand -- REGARDLESS of how far away
## the object was when TWIST engaged, so the gesture feels the same whether
## the grab happened at 1 m or 6 m. This is the closer analogue of Meta's own
## design: PinchAndTwistEventSource emits a NORMALIZED value and leaves the
## consumer to map it onto its own range (a slider maps to its authored
## min/max); ours maps the same normalized inward deflection onto min_grab_distance
## as its "min" (read for technique only, per CLAUDE.md -- no code copied).
##
## OUTWARD deflection always uses twist_span_metres, regardless of this flag:
## "bring it to me" has a natural endpoint (the hand) that "push it away" does
## not, so only the inward side gets the hand-reaching remap.
##
## When false, inward uses twist_span_metres exactly like outward, i.e. the
## pre-authoring-fix behaviour this export exists to make optional.
@export var twist_pull_reaches_hand := true

## Degrees of roll (away from the captured neutral) at which the offset
## reaches +/- twist_span_metres. Beyond it the offset clamps -- twisting
## further does not continue past the span. 90 degrees: a quarter turn of the
## forearm, comfortably inside supination's usable range from a pinch-grab
## wrist pose (unlike a half turn, which starts to fight the pinch itself).
## Order-of-magnitude reference: Meta's PinchAndTwistEventSource is described
## as "roughly a quarter turn" for full range (read for technique, not
## copied -- see the class doc comment).
@export_range(5.0, 180.0, 1.0) var twist_full_angle_degrees := 90.0

## Degrees of roll before the mapping ENGAGES at all -- below this, the offset
## is exactly zero regardless of deadband. This is what keeps a grab from
## immediately moving the object: right at select the wrist is rarely at
## PERFECT rest, and without a distinct, larger gate than the deadband below,
## that incidental roll would already read as a small intentional twist.
## Deliberately several times twist_deadband_degrees -- a small deliberate
## roll, not a jitter-sized one, is what should start the mapping.
@export_range(0.0, 30.0, 0.1) var twist_start_threshold_degrees := 5.0

## Degrees of roll, inside twist_full_angle_degrees, treated as the
## mapping's own zero for SCALING once engaged -- this is what makes rolling
## exactly back to the captured neutral retrace to exactly zero offset rather
## than leaving a residual few percent from tracking noise sitting right at
## neutral. Order-of-magnitude reference: Meta's own description quotes "a ~1
## degree deadband" (read for technique, not copied). Distinct from
## twist_start_threshold_degrees, which gates whether the mapping has engaged
## AT ALL -- this one only shapes the scale once it has.
@export_range(0.0, 10.0, 0.1) var twist_deadband_degrees := 1.0

var _interactable: Node
## Per-hand captured engagement state, keyed by XRInputAdapter.Hand:
## {axis, rotation, engagement_distance}. axis is the ray/forward direction
## frozen the first physics frame this driver observes that hand
## TWIST-holding via a ray (the same "capture once, never re-read while held"
## decision the reel axis makes, for the same reason -- aiming after the grab
## must not change what "roll" means). rotation is the wrist's own
## orientation at that same moment -- roll is measured relative to it, so a
## wrist that happens to be rolled at grab time reads as zero, not as
## already-twisted. engagement_distance is the ray's held distance at that
## same moment -- the zero point the absolute offset is measured from.
## Erased the moment the hand stops TWIST-holding via a ray, so the next grab
## captures a fresh neutral AND a fresh engagement distance rather than
## reusing either from a previous hold.
var _neutral: Dictionary = {}


func _ready() -> void:
	_interactable = _find_interactable()
	# _drive_hand's own erase-on-not-held branch is a per-frame POLL: it only
	# notices a release the next time this hand is asked about, which is fine
	# on its own but leaves a gap if the SAME hand releases and re-grabs again
	# (a new object, or the same one) before that next poll runs -- the stale
	# engagement_distance/neutral rotation from the FIRST grab would otherwise
	# leak into the second. Forgetting on the interactable's own select_exited
	# signal closes that gap at the source instead of relying on polling
	# timing to happen to catch it.
	if _interactable != null and _interactable.has_signal("select_exited"):
		_interactable.select_exited.connect(_forget_neutral_on_release)


func _forget_neutral_on_release(interactor) -> void:
	if interactor == null or not ("hand" in interactor):
		return
	_neutral.erase(int(interactor.hand))


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _interactable == null:
		return
	_drive_hand(XRInputAdapter.Hand.LEFT, delta)
	_drive_hand(XRInputAdapter.Hand.RIGHT, delta)


func _drive_hand(hand: int, delta: float) -> void:
	var interactor := _held_by(hand)
	if interactor == null or not (interactor is XRRayInteractor) or not _is_twist_target():
		_neutral.erase(hand)
		return

	var tracker := XRHandTrackerResolver.get_tracker(hand)
	if tracker == null or not tracker.has_tracking_data \
			or not XRHandTrackerResolver.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_WRIST):
		# No wrist joint resolves for this hand -- a controller (no pinch, no
		# wrist joint at all) or a hand that dropped out of tracking. Hold
		# distance, exactly like FIXED, rather than break. Neutral is left
		# captured (not erased) so a brief tracking dropout mid-twist resumes
		# from the same baseline instead of silently re-zeroing.
		return

	var current_rotation := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).basis.get_rotation_quaternion()
	if not _neutral.has(hand):
		# First frame this hand is seen TWIST-holding: capture neutral AND the
		# distance the object is held at right now -- that distance becomes the
		# zero point every later offset is measured from. Drive nothing yet.
		# Freezing here (not at the interactable's `grabbed` signal, which
		# fires BEFORE the ray records its own post-grab attach pose -- see
		# xr_interaction_manager.request_select's call order) means the frozen
		# axis/distance read the ray's already-settled state, at the cost of
		# at most one physics frame of skew versus the exact select instant --
		# bounded, and it does not accumulate.
		_neutral[hand] = {
			"axis": _roll_axis(interactor),
			"rotation": current_rotation,
			"engagement_distance": interactor.get_grab_distance(),
		}
		return

	var neutral: Dictionary = _neutral[hand]
	var roll := twist_angle(neutral["rotation"], current_rotation, neutral["axis"])
	# INWARD span only: when twist_pull_reaches_hand is on, full inward
	# deflection must land on min_grab_distance regardless of how far the
	# object was when TWIST engaged, so the span it scales against is
	# (engagement_distance - min_grab_distance) -- computed fresh here, not
	# cached in _neutral, so a runtime change to min_grab_distance takes effect
	# immediately. Outward is untouched: twist_offset only consults this value
	# for a NEGATIVE (inward) fraction. `interactor` is the generic Node
	# _held_by returns, so `.min_grab_distance` resolves dynamically the same
	# way `.max_distance_change_per_second` does below.
	var engagement_distance: float = neutral["engagement_distance"]
	var inward_span := twist_span_metres
	if twist_pull_reaches_hand:
		var min_grab_distance: float = interactor.min_grab_distance
		inward_span = maxf(engagement_distance - min_grab_distance, 0.0)
	var offset := twist_offset(roll, deg_to_rad(twist_start_threshold_degrees),
			deg_to_rad(twist_deadband_degrees), deg_to_rad(twist_full_angle_degrees),
			twist_span_metres, inward_span)
	var target: float = engagement_distance + offset
	# interactor is typed as the generic Node _held_by returns, so its method
	# calls resolve dynamically -- explicit `: float` (not `:=`) is required
	# here, or the compiler cannot infer a type from a Variant-returning call.
	var step: float = target - interactor.get_grab_distance()
	# Rate-limit the STEP the same way REEL's own hand-motion path limits
	# itself (_apply_motion_distance_manipulation), rather than relying on
	# adjust_grab_distance() to do it -- it only range-clamps
	# (min_grab_distance/max_distance), never rate-limits. Without this, a
	# target that jumps (crossing twist_start_threshold_degrees, or a noisy
	# tracking sample) would SNAP the held distance there in one frame instead
	# of approaching it, which is the "smooths the approach rather than
	# snapping" max_distance_change_per_second is meant to buy here too.
	if delta > 0.0 and interactor.max_distance_change_per_second > 0.0:
		var max_step: float = interactor.max_distance_change_per_second * delta
		step = clampf(step, -max_step, max_step)
	if is_equal_approx(step, 0.0):
		return
	interactor.adjust_grab_distance(step)


## Signed angle (radians) the wrist has rotated AROUND `axis` between
## `neutral_rotation` and `current_rotation`, independent of whatever the
## wrist also did around any axis perpendicular to it (aiming) -- the
## standard swing-twist decomposition. For delta = current * neutral^-1,
## expressed as a quaternion (x, y, z, w), the twist embedded in delta around
## a unit axis A is 2 * atan2(dot((x,y,z), A), w): the swing component's
## contribution to dot((x,y,z), A) is exactly zero because swing's own
## rotation axis is by construction perpendicular to A, so this is exact
## whenever the swing angle is under +/-180 degrees -- always true for a
## wrist twisting while pinched, never a case this technique needs to defend
## against separately. `axis` must already be a unit vector.
##
## The w>=0 canonicalization below is NOT optional: a quaternion and its
## negation represent the identical rotation (q === -q), but
## Basis.get_rotation_quaternion() does not guarantee which sign it returns
## -- confirmed empirically, a 144 degree roll came back with w<0 while a 90
## degree roll from the same construction came back with w>=0. atan2 is not
## invariant under negating both arguments (atan2(-y,-x) is atan2(y,x)
## rotated by 180 degrees, not the same value), so an uncanonicalized delta
## silently flips this formula's answer by up to 360 degrees for some rolls
## and not others. Same fix xr_grab_interactable.gd's own
## _angular_velocity_between already applies to its rotation delta, for the
## identical reason.
static func twist_angle(neutral_rotation: Quaternion, current_rotation: Quaternion, axis: Vector3) -> float:
	var delta := (current_rotation * neutral_rotation.inverse()).normalized()
	if delta.w < 0.0:
		delta = Quaternion(-delta.x, -delta.y, -delta.z, -delta.w)
	var vector_part := Vector3(delta.x, delta.y, delta.z)
	return 2.0 * atan2(vector_part.dot(axis), delta.w)


## Signed distance OFFSET (metres) from the engagement distance, for a
## measured roll against the authored start-threshold/deadband/full-angle/span.
## Two gates, kept distinct on purpose:
##  - below `start_threshold_radians`, the offset is exactly zero -- the
##    mapping has not ENGAGED at all, so a grab does not immediately move the
##    object from incidental at-rest wrist roll.
##  - once engaged, `deadband_radians` (smaller than the start threshold) is
##    subtracted from the roll before scaling, so rolling exactly back to the
##    captured neutral retraces to exactly zero offset rather than leaving a
##    residual sliver from tracking noise sitting right at neutral.
## Linear from there to +/- full_angle_radians, clamped beyond it -- twisting
## further than full_angle never overshoots.
##
## `span_metres` scales a POSITIVE (outward) fraction; `inward_span_metres`
## scales a NEGATIVE (inward) fraction instead, when given. Defaults to -1.0,
## a sentinel meaning "use span_metres for both directions" -- the original
## symmetric mapping, and what every caller that only cares about one span
## (this file's own pure-math test included) still gets by passing 5 args.
## twist_pull_reaches_hand is what gives callers a REASON to pass a different
## inward_span_metres: full inward deflection should reach min_grab_distance
## regardless of engagement distance, which is a span that depends on the
## engagement distance and so cannot be the fixed twist_span_metres constant.
static func twist_offset(roll_radians: float, start_threshold_radians: float,
		deadband_radians: float, full_angle_radians: float, span_metres: float,
		inward_span_metres := -1.0) -> float:
	if absf(roll_radians) < start_threshold_radians:
		return 0.0
	var excess := 0.0
	if roll_radians > deadband_radians:
		excess = roll_radians - deadband_radians
	elif roll_radians < -deadband_radians:
		excess = roll_radians + deadband_radians
	var usable_span := maxf(full_angle_radians - deadband_radians, 0.0001)
	var fraction := clampf(excess / usable_span, -1.0, 1.0)
	var span_for_fraction := span_metres
	if fraction < 0.0 and inward_span_metres >= 0.0:
		span_for_fraction = inward_span_metres
	return fraction * span_for_fraction


## The frozen roll axis for a fresh neutral capture: the ray's current aim
## direction. -basis.z, not +basis.z -- confirmed from
## xr_controller_hand_adapter.gd's own pose construction
## ("direction": (-xf.basis.z).normalized(), and the hand-aim branch builds
## its basis FROM that same direction), so this matches the ray's actual
## forward convention rather than assuming it.
func _roll_axis(interactor) -> Vector3:
	var axis: Vector3 = -interactor.get_attach_pose().basis.z
	if axis.length_squared() < 0.000001:
		return Vector3.FORWARD
	return axis.normalized()


func _is_twist_target() -> bool:
	return _interactable != null and "far_grab_mode" in _interactable \
			and int(_interactable.far_grab_mode) == XRGrabInteractable.FarGrabMode.TWIST


## Same pattern as XRHandActivator._held_by: the interactor (if any) of this
## hand among the interactable's current selecting interactors.
func _held_by(hand: int) -> Node:
	if _interactable == null or not _interactable.has_method("get_selecting_interactors"):
		return null
	for interactor in _interactable.get_selecting_interactors():
		if interactor != null and interactor.get("hand") == hand:
			return interactor
	return null


## Same pattern as XRHandActivator._find_interactable: walk up the ancestors
## for the interactable this driver was parented inside.
func _find_interactable() -> Node:
	var node := get_parent()
	while node != null:
		if node is XRBaseInteractable:
			return node
		node = node.get_parent()
	return null


func _get_configuration_warnings() -> PackedStringArray:
	if _find_interactable() == null:
		return PackedStringArray([
			"Place XRPinchTwistDistanceDriver inside a grab interactable "
			+ "(XRGrabInteractable) with far_grab_mode set to TWIST -- it "
			+ "drives that object's far-grab distance from wrist roll."])
	return PackedStringArray()

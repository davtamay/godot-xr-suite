class_name XRAimStabilizer
extends RefCounted

## Low-latency ray stabilization: a scaling deadband, not a low-pass filter.
##
## The problem this solves is geometric. A hand ray's direction is derived from
## an ~8cm wrist-to-knuckle baseline, so a few mm of joint noise becomes degrees
## of angular error, which is tens of centimetres of cursor swing at the far end
## of a multi-metre ray. Smoothing the DIRECTION treats every ray the same
## regardless of how far it reaches, which is why the One Euro pass this
## replaces was simultaneously too soft up close and too weak at range.
##
## Three ideas, in order of how much they matter:
##
## 1. DEADBAND THAT SCALES. Error is divided by a threshold and clamped. At or
##    above the threshold the raw pose passes through untouched -- full speed,
##    zero added latency, so deliberate aiming is never damped. Near zero the
##    previous pose is held, which is where jitter lives. In between it is
##    proportional. There is no velocity estimate and no cutoff to tune, which
##    is the practical advantage over One Euro: two thresholds in units a person
##    can reason about (degrees, metres) instead of three coupled rates.
##
## 2. BUDGET BY RANGE. The same angular error costs more the further you point,
##    so the angle threshold is scaled by 1 + log(range), clamped. Pointing
##    across the room is stabilized harder than pointing at your own hand,
##    automatically, with no second set of tunables. This is why callers should
##    feed set_aim_endpoint: without it every ray is treated as
##    default_range_m.
##
## DELIBERATELY NOT IMPLEMENTED: endpoint anchoring. XRTransformStabilizer also
## keeps a second candidate rotation -- one aimed from the stabilized origin at
## the point the raw ray designates -- and takes whichever needs less
## correction. It exists to stop POSITION smoothing from deflecting the aim,
## not to cancel jitter, and it cannot engage in the common case (when the
## direction is steady, simply holding it is already a zero-error candidate and
## always wins). It was implemented here, could not be given a test that
## asserted a guarantee it actually makes, and was removed rather than shipped
## half-understood. Revisit only with an on-device case that it demonstrably
## fixes.
##
## Frame-rate independence is exact here rather than approximated: applying a
## lerp of ratio r once per frame for n frames leaves (1-r)^n, so the
## equivalent single-step alpha for an arbitrary dt is 1 - (1-r)^(dt/ref_dt).
## That is a closed form, so 72Hz, 90Hz, and 120Hz produce the same feel
## instead of merely similar feel -- which matters because this codebase ships
## to standalone (72-120Hz) and to browsers (whatever the compositor gives us)
## from one set of values.
##
## Technique adapted from the published behaviour of Unity's XRTransformStabilizer
## (Unity Companion License -- incompatible, so this is an independent
## implementation from the described approach, not a translation; its
## frame-compensation is a three-term piecewise approximation, this is the
## exact closed form). See docs/XR_INPUT_PRACTICES.md.

## Reference frame time the thresholds are expressed against.
const REFERENCE_DT := 1.0 / 90.0
## Range below which no extra angular budget is granted.
const MIN_SCALED_RANGE := 1.0
## Ceiling on the range multiplier, so a very long ray cannot freeze the ray.
const MAX_RANGE_SCALE := 3.0

## Angular error, in degrees, at or above which the raw direction passes
## through untouched. Below it, correction is proportional.
var angle_threshold_deg := 20.0
## Positional error, in metres, at or above which the raw origin passes through
## untouched.
var position_threshold_m := 0.25
## Nominal ray range used when a caller gives no endpoint hint.
var default_range_m := 3.0

var _origin: Array[Vector3] = []
var _direction: Array[Vector3] = []
var _primed: Array[bool] = []


func _init(channels: int = 2) -> void:
	resize(channels)


## Channels are independent by construction: one stabilizer instance serves
## both hands without either seeing the other's history.
func resize(channels: int) -> void:
	_origin.resize(channels)
	_direction.resize(channels)
	_primed.resize(channels)
	for i in range(channels):
		_primed[i] = false


## Drops history so the next call snaps rather than slewing from a stale pose.
## Call on tracking reacquisition -- otherwise the ray visibly drags from where
## the hand used to be to where it now is.
func reset(channel: int) -> void:
	if channel >= 0 and channel < _primed.size():
		_primed[channel] = false


## `endpoint_hint` is where this ray currently terminates (a hit point, or the
## cursor). Pass null when unknown and `default_range_m` stands in. `dt` is a
## parameter rather than an internal clock read so this is testable headless
## with deterministic timing.
func stabilize(channel: int, target_origin: Vector3, target_direction: Vector3,
		endpoint_hint, dt: float) -> Dictionary:
	var direction := target_direction.normalized()
	if channel < 0 or channel >= _primed.size() or direction == Vector3.ZERO or dt <= 0.0:
		return {"origin": target_origin, "direction": target_direction}

	if not _primed[channel]:
		_origin[channel] = target_origin
		_direction[channel] = direction
		_primed[channel] = true
		return {"origin": target_origin, "direction": direction}

	var previous_origin: Vector3 = _origin[channel]
	var previous_direction: Vector3 = _direction[channel]

	var range_m := default_range_m
	if endpoint_hint is Vector3:
		range_m = maxf((endpoint_hint as Vector3 - previous_origin).length(), 0.0)

	# --- position: plain scaling deadband -------------------------------------
	var position_error := (target_origin - previous_origin).length()
	var settled_origin := target_origin
	if position_threshold_m > 0.0 and position_error > 0.0:
		var alpha := _stabilized_alpha(position_error / position_threshold_m, dt)
		settled_origin = previous_origin.lerp(target_origin, alpha)

	# --- direction: range-scaled deadband -------------------------------------
	var settled_direction := direction
	if angle_threshold_deg > 0.0:
		# Range scaling lives in the THRESHOLD, so a long ray tolerates less
		# angular movement before it starts damping -- which is the whole point:
		# a degree of wobble is a few millimetres at arm's length and a
		# quarter-metre across a room.
		var budget := angle_threshold_deg * clampf(
				1.0 + log(maxf(range_m, MIN_SCALED_RANGE)), 1.0, MAX_RANGE_SCALE)
		var error := rad_to_deg(previous_direction.angle_to(direction))
		var alpha := _stabilized_alpha(error / budget, dt)
		settled_direction = _slerp_direction(previous_direction, direction, alpha)

	_origin[channel] = settled_origin
	_direction[channel] = settled_direction
	return {"origin": settled_origin, "direction": settled_direction}


## Exact frame-rate compensation. `ratio` is error over threshold: >= 1 means
## the movement is large enough to pass through untouched, <= 0 means hold.
## Between those, the per-reference-frame lerp of `ratio` is composed over
## dt/REFERENCE_DT frames -- (1-r)^n remaining -- so behaviour is identical at
## any refresh rate rather than merely close.
static func _stabilized_alpha(ratio: float, dt: float) -> float:
	if ratio >= 1.0:
		return 1.0
	if ratio <= 0.0:
		return 0.0
	return 1.0 - pow(1.0 - ratio, dt / REFERENCE_DT)


## Vector3.slerp is undefined for parallel and antiparallel inputs; both are
## reachable here (a perfectly still hand, and a 180-degree flip on
## reacquisition), so neither may fall through to it.
static func _slerp_direction(from: Vector3, to: Vector3, weight: float) -> Vector3:
	var dot := clampf(from.dot(to), -1.0, 1.0)
	if dot > 0.9999:
		return to
	if dot < -0.9999:
		return to
	return from.slerp(to, weight).normalized()

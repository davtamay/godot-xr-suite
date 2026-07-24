class_name XROneEuroFilter
extends RefCounted

## Adaptive low-pass filter bank over Vector3 channels.
##
## Casiez, G., Roussel, N., & Vogel, D. (2012). "1 euro filter: a simple
## speed-based low-pass filter for noisy input in interactive systems." CHI '12.
##
## The cutoff frequency rises with the estimated speed of the signal: heavy
## smoothing while the hand is still, low lag while it moves.
##
## Vectors are filtered as WHOLE UNITS -- one speed estimate from the vector's
## magnitude, one alpha, one lerp. Filtering components independently gives each
## axis its own alpha, so on a diagonal motion the slower axis lags further and
## the trajectory BENDS. One alpha preserves direction exactly, and costs 1
## GDScript operation instead of 3.
##
## State lives in flat packed arrays indexed by channel rather than one object
## per filtered value, avoiding both the allocation and the property lookups.

## Cutoff in Hz at zero speed. Lower = steadier at rest, more lag.
var min_cutoff := 1.0
## Speed coefficient. Higher = less lag when moving, more jitter passed through.
var beta := 0.0
## Cutoff in Hz for smoothing the speed estimate itself.
var d_cutoff := 1.0

var _value: PackedVector3Array = PackedVector3Array()
var _derivative: PackedVector3Array = PackedVector3Array()
var _seeded: PackedByteArray = PackedByteArray()

## Smallest dt we will divide by. A backgrounded tab or a paused frame can
## report a huge or zero delta; clamping keeps one bad frame from spiking.
const MIN_DELTA := 0.0001
const MAX_DELTA := 0.5

static func alpha(cutoff: float, dt: float) -> float:
	var time_constant := 1.0 / (TAU * maxf(cutoff, 0.0001))
	return 1.0 / (1.0 + time_constant / dt)

func resize(channel_count: int) -> void:
	_value.resize(channel_count)
	_derivative.resize(channel_count)
	_seeded.resize(channel_count)
	reset_all()

func reset_all() -> void:
	_seeded.fill(0)

func reset_channel(channel: int) -> void:
	if channel >= 0 and channel < _seeded.size():
		_seeded[channel] = 0

func filter(channel: int, value: Vector3, dt: float) -> Vector3:
	if channel < 0 or channel >= _seeded.size():
		return value
	# Never let a bad sample enter the state. Pass it through so the caller sees
	# the runtime's own value rather than a silently invented one.
	if not value.is_finite():
		return value

	var step := clampf(dt, MIN_DELTA, MAX_DELTA)

	if _seeded[channel] == 0:
		_value[channel] = value
		_derivative[channel] = Vector3.ZERO
		_seeded[channel] = 1
		return value

	var previous := _value[channel]
	var raw_derivative := (value - previous) / step
	var smooth_derivative := _derivative[channel].lerp(raw_derivative, alpha(d_cutoff, step))
	var cutoff := min_cutoff + beta * smooth_derivative.length()
	var filtered := previous.lerp(value, alpha(cutoff, step))

	_value[channel] = filtered
	_derivative[channel] = smooth_derivative
	return filtered

class_name XROneEuroRotationFilter
extends RefCounted

## One Euro adaptive low-pass over Quaternion channels.
##
## Shares XROneEuroFilter's alpha computation. Speed is angular distance per
## second and the blend is a single slerp, so the whole rotation is filtered as
## one unit -- the rotational counterpart of filtering a Vector3 as one unit.
##
## State is Array[Quaternion], NOT a stride-4 PackedFloat32Array: in GDScript
## the cost that matters is the number of GDScript-level operations, and one
## typed-array read beats four float reads plus a constructor.

var min_cutoff := 1.0
var beta := 0.0
var d_cutoff := 1.0

var _value: Array[Quaternion] = []
var _speed: PackedFloat32Array = PackedFloat32Array()
var _seeded: PackedByteArray = PackedByteArray()

func resize(channel_count: int) -> void:
	_value.resize(channel_count)
	_speed.resize(channel_count)
	_seeded.resize(channel_count)
	reset_all()

func reset_all() -> void:
	_seeded.fill(0)

func reset_channel(channel: int) -> void:
	if channel >= 0 and channel < _seeded.size():
		_seeded[channel] = 0

func filter(channel: int, value: Quaternion, dt: float) -> Quaternion:
	if channel < 0 or channel >= _seeded.size():
		return value
	if not value.is_finite() or is_zero_approx(value.length_squared()):
		return value

	var normalized := value.normalized()
	var step := clampf(dt, XROneEuroFilter.MIN_DELTA, XROneEuroFilter.MAX_DELTA)

	if _seeded[channel] == 0:
		_value[channel] = normalized
		_speed[channel] = 0.0
		_seeded[channel] = 1
		return normalized

	var previous: Quaternion = _value[channel]
	# No manual hemisphere correction here: Godot's Quaternion.slerp and
	# angle_to are already double-cover invariant (slerp(a, b, t) ==
	# slerp(a, -b, t), angle_to(a, b) == angle_to(a, -b)), so negating toward
	# the same hemisphere as `previous` would be a no-op. slerpni exists as
	# the explicit opt-out if non-inverting behaviour is ever wanted.

	var raw_speed := previous.angle_to(normalized) / step
	var smooth_speed := lerpf(_speed[channel], raw_speed, XROneEuroFilter.alpha(d_cutoff, step))
	var cutoff := min_cutoff + beta * smooth_speed
	var filtered := previous.slerp(normalized, XROneEuroFilter.alpha(cutoff, step)).normalized()

	_value[channel] = filtered
	_speed[channel] = smooth_speed
	return filtered

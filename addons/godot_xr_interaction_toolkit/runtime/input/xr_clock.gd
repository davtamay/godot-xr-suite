class_name XRClock
extends RefCounted

## The time the input chain reasons in, in microseconds.
##
## Hand filters, gesture recognizers and dwell windows all measure how long
## something lasted. Normally that is wall time, which is what a headset runs
## on, and this returns it unchanged. An app on a fixed step is different:
## every frame advances the scene by exactly one step and nothing waits for the
## wall clock, so frames run back to back as fast as the machine allows. Wall
## time then says almost nothing passed between frames - measured as a hand
## filter that barely moved and a pinch that selected 20 frames late - while
## the scene moved a full step. On a fixed step this returns the scene's own
## time instead, so every reader sees the clock the motion runs on, and a drive
## gives the same result however fast the machine runs it.
##
## A fixed step is recognised from `--fixed-fps` among the user arguments
## (after `--`) or from a movie being written. Godot consumes its own
## `--fixed-fps` and does not show it to scripts, so whoever launches a fixed
## run passes it again after `--`; the operator's drives do.
##
## Read through here, never Time.get_ticks_usec(), anywhere a duration decides
## what an interaction does.

static var _fixed := -1
static var _step := 1.0 / 60.0


static func now_usec() -> int:
	if _fixed < 0:
		_fixed = 1 if fixed_step_requested() else 0
	if _fixed == 0:
		return Time.get_ticks_usec()
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		var step := tree.root.get_process_delta_time()
		if Engine.time_scale > 0.0:
			step /= Engine.time_scale
		if step > 0.0:
			_step = step
	return int(round(Engine.get_process_frames() * _step * 1_000_000.0))


static func now_msec() -> int:
	return now_usec() / 1000


static func now_seconds() -> float:
	return float(now_usec()) * 0.000001


## True when this run advances by a fixed step rather than by the wall clock.
static func is_fixed_step() -> bool:
	if _fixed < 0:
		_fixed = 1 if fixed_step_requested() else 0
	return _fixed == 1


static func fixed_step_requested() -> bool:
	if not Engine.get_write_movie_path().is_empty():
		return true
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		var text := str(arg)
		if text == "--fixed-fps" or text.begins_with("--fixed-fps="):
			return true
	return false

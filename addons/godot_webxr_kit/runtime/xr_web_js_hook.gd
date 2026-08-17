class_name XRWebJSHook
extends RefCounted

## One place that installs a per-frame WebXR hook, because five bridges had
## each written their own and every copy had to remember the same four
## non-obvious rules. Three of them were learned the hard way on device:
##
## 1. INSTALL ONCE. The hook lives on XRSession.prototype, which is global -
##    a second install would wrap the wrapper and run every bridge twice.
##
## 2. GUARD `typeof XRSession`. A browser without WebXR (Firefox on desktop,
##    at the time it was found) throws a ReferenceError on the bare name, and
##    an exception here kills the whole install - so the bridge reports
##    api-unavailable instead of dying.
##
## 3. NEVER UN-PATCH. There is no safe moment to restore the original: another
##    bridge may have wrapped ours in the meantime, and unwinding out of order
##    drops somebody's hook.
##
## 4. ALWAYS CALL THE CALLBACK. The wrapper must reach `callback(time, frame)`
##    on every path, including failure - that callback is the ENGINE's frame.
##    A bare `return` inside the wrapper skips it and the app freezes, which
##    is why the per-frame work is wrapped in try/catch and the catch falls
##    through rather than returning.
##
## The per-bridge parts stay per-bridge: its state object, its helper
## functions, and what it does each frame.

## Builds the installer source. Pure, so it can be diffed against what a
## bridge used to emit without running a browser - which is the only
## verification available off-device.
static func build(global_name: String, state_js: String, helpers_js: String,
		frame_js: String, unavailable_js := "", catch_js := "") -> String:
	var unavailable := unavailable_js if not unavailable_js.is_empty() \
			else "bridge.status = 'api-unavailable';"
	var catch_body := catch_js if not catch_js.is_empty() else \
			"bridge.error = error && (error.name || error.message) ? String(error.name || error.message) : 'unknown';\n\t\t\t\tbridge.status = 'frame-error';"
	return """
(function () {
	if (window.%s) { return; }
	const bridge = %s;
	window.%s = bridge;

	if (typeof XRSession === 'undefined') {
		%s
		return;
	}
%s
	const originalRequestAnimationFrame = XRSession.prototype.requestAnimationFrame;
	XRSession.prototype.requestAnimationFrame = function (callback) {
		return originalRequestAnimationFrame.call(this, function (time, frame) {
			try {
%s
			} catch (error) {
				%s
			}
			callback(time, frame);
		});
	};
}())
""" % [global_name, state_js, global_name, unavailable, helpers_js, frame_js, catch_body]


## Installs the hook, or does nothing off the web. Returns false when there is
## no browser to install into, so a caller can report that honestly rather
## than assuming its bridge is live.
static func install(global_name: String, state_js: String, helpers_js: String,
		frame_js: String, unavailable_js := "", catch_js := "") -> bool:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return false
	Engine.get_singleton("JavaScriptBridge").eval(
			build(global_name, state_js, helpers_js, frame_js, unavailable_js, catch_js), true)
	return true


## Pokes a field on an installed bridge, guarded so it is a no-op when the
## hook never installed. Every bridge hand-wrote this pattern too, and an
## unguarded poke on a browser without WebXR is a TypeError.
static func poke(global_name: String, assignments_js: String) -> void:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return
	Engine.get_singleton("JavaScriptBridge").eval(
			"window.%s && (%s);" % [global_name, assignments_js], true)

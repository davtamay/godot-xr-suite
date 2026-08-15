extends Node

## Acquires standardized WebXR Lighting Estimation data without making any
## rendering decisions. Consumers receive the primary light direction and
## intensity plus all nine RGB spherical-harmonic coefficients, then decide
## how those values map into their renderer or art direction.
##
## The bridge deliberately remains WebXR-specific. The demo translates its
## output into Godot DirectionalLight3D and shader parameters, while a future
## OpenXR provider can emit the same signal without sharing this acquisition
## code.

signal estimate_updated(
	direction_to_light: Vector3,
	primary_intensity: Vector3,
	spherical_harmonics: PackedVector3Array
)
signal estimate_lost

@export_range(0.03, 1.0, 0.01) var poll_interval := 0.1

var _webxr: XRInterface
var _installed := false
var _poll_accum := 0.0
var _last_seq := -1
var _has_live_estimate := false
var _primary_direction := Vector3.UP
var _primary_intensity := Vector3.ZERO
var _spherical_harmonics := PackedVector3Array()


func _ready() -> void:
	add_to_group("webxr_light_estimation_bridge")
	add_to_group("webxr_feature_provider")
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		set_process(false)
		return
	_webxr = XRServer.find_interface("WebXR")
	if _webxr:
		_webxr.session_started.connect(_on_session_started)
		_webxr.session_ended.connect(_on_session_ended)
	_install_js_hook()
	set_process(false)
	if _webxr and _webxr.is_initialized():
		_on_session_started()


func _install_js_hook() -> void:
	if _installed:
		return
	_installed = true
	var js := Engine.get_singleton("JavaScriptBridge")
	js.eval("""
(function () {
	if (window.GodotWebXRLightEstimationBridge) { return; }
	const bridge = {
		status: 'waiting-session', error: '', session: null, probe: null,
		probePending: false, probeFailed: false, seq: 0, reflectionSeq: 0,
		direction: [0, 1, 0], intensity: [0, 0, 0], sh: new Array(27).fill(0),
		preferredReflectionFormat: '', intervalMs: 80, lastSample: 0
	};
	window.GodotWebXRLightEstimationBridge = bridge;

	if (typeof XRSession === 'undefined') {
		bridge.status = 'api-unavailable';
		return;
	}

	function beginSession(session) {
		bridge.session = session;
		bridge.probe = null;
		bridge.probePending = false;
		bridge.probeFailed = false;
		bridge.error = '';
		bridge.status = 'requesting-probe';
		bridge.lastSample = 0;
		bridge.preferredReflectionFormat = session.preferredReflectionFormat || '';
	}

	function requestProbe(session) {
		if (bridge.probe || bridge.probePending || bridge.probeFailed) { return; }
		if (typeof session.requestLightProbe !== 'function') {
			bridge.probeFailed = true;
			bridge.status = 'api-unavailable';
			return;
		}
		bridge.probePending = true;
		bridge.status = 'requesting-probe';
		// No reflectionFormat is requested here. Direction/intensity/SH are
		// useful without a cubemap, and the default is the most portable path.
		session.requestLightProbe().then(function (probe) {
			if (bridge.session !== session) { return; }
			bridge.probePending = false;
			bridge.probe = probe;
			bridge.status = 'probe-ready';
			probe.addEventListener('reflectionchange', function () {
				bridge.reflectionSeq++;
			});
		}).catch(function (error) {
			if (bridge.session !== session) { return; }
			bridge.probePending = false;
			bridge.probeFailed = true;
			bridge.error = error && (error.name || error.message) ? String(error.name || error.message) : 'unknown';
			bridge.status = 'not-granted';
		});
	}

	const originalRequestAnimationFrame = XRSession.prototype.requestAnimationFrame;
	XRSession.prototype.requestAnimationFrame = function (callback) {
		return originalRequestAnimationFrame.call(this, function (time, frame) {
			try {
				if (bridge.session !== frame.session) { beginSession(frame.session); }
				requestProbe(frame.session);
				if (bridge.probe && typeof frame.getLightEstimate === 'function' &&
					(time - bridge.lastSample) >= bridge.intervalMs) {
					bridge.lastSample = time;
					const estimate = frame.getLightEstimate(bridge.probe);
					if (estimate) {
						const d = estimate.primaryLightDirection;
						const i = estimate.primaryLightIntensity;
						bridge.direction = [d.x, d.y, d.z];
						bridge.intensity = [i.x, i.y, i.z];
						bridge.sh = Array.from(estimate.sphericalHarmonicsCoefficients);
						bridge.status = 'live';
						bridge.seq++;
					} else {
						bridge.status = 'waiting-estimate';
					}
				}
			} catch (error) {
				bridge.error = error && (error.name || error.message) ? String(error.name || error.message) : 'unknown';
				bridge.status = 'frame-error';
			}
			callback(time, frame);
		});
	};
}())
""", true)


func _on_session_started() -> void:
	_last_seq = -1
	_poll_accum = 0.0
	set_process(true)


func _on_session_ended() -> void:
	set_process(false)
	_reset_estimate()
	Engine.get_singleton("JavaScriptBridge").eval("""
(function () {
	const bridge = window.GodotWebXRLightEstimationBridge;
	if (!bridge) { return; }
	bridge.status = 'session-ended';
	bridge.session = null;
	bridge.probe = null;
	bridge.probePending = false;
	bridge.probeFailed = false;
}())
""", true)


func _process(delta: float) -> void:
	_poll_accum += delta
	if _poll_accum < poll_interval:
		return
	_poll_accum = 0.0
	_poll_estimate()


func _poll_estimate() -> void:
	var payload := str(Engine.get_singleton("JavaScriptBridge").eval("""
(function () {
	const bridge = window.GodotWebXRLightEstimationBridge;
	if (!bridge) { return '{}'; }
	return JSON.stringify({
		seq: bridge.seq,
		direction: bridge.direction,
		intensity: bridge.intensity,
		sh: bridge.sh
	});
}())
""", true))
	var parsed = JSON.parse_string(payload)
	if not (parsed is Dictionary):
		return
	# seq starts at 0 in the JS hook and only increments when getLightEstimate
	# returns a REAL sample - so seq 0 is the hook's zero-initialized packet,
	# not data. Ingesting it marked the bridge "live" with all-zero values on
	# devices that never grant the feature (Quest showed a green "reading your
	# room's light" banner). A real sample always has seq >= 1.
	var seq := int(parsed.get("seq", -1))
	if seq <= 0 or seq == _last_seq:
		return
	var direction_value = parsed.get("direction", [])
	var intensity_value = parsed.get("intensity", [])
	var sh_value = parsed.get("sh", [])
	if not (direction_value is Array) or direction_value.size() < 3:
		return
	if not (intensity_value is Array) or intensity_value.size() < 3:
		return
	if not (sh_value is Array) or sh_value.size() < 27:
		return

	_last_seq = seq
	_primary_direction = Vector3(
		float(direction_value[0]), float(direction_value[1]), float(direction_value[2])
	).normalized()
	_primary_intensity = Vector3(
		float(intensity_value[0]), float(intensity_value[1]), float(intensity_value[2])
	)
	_spherical_harmonics = PackedVector3Array()
	for coefficient in range(9):
		var offset := coefficient * 3
		_spherical_harmonics.append(Vector3(
			float(sh_value[offset]),
			float(sh_value[offset + 1]),
			float(sh_value[offset + 2])
		))
	_has_live_estimate = true
	estimate_updated.emit(_primary_direction, _primary_intensity, _spherical_harmonics)


func _reset_estimate() -> void:
	var was_live := _has_live_estimate
	_has_live_estimate = false
	_last_seq = -1
	_primary_direction = Vector3.UP
	_primary_intensity = Vector3.ZERO
	_spherical_harmonics = PackedVector3Array()
	if was_live:
		estimate_lost.emit()


func has_live_estimate() -> bool:
	return _has_live_estimate


func get_primary_direction() -> Vector3:
	return _primary_direction


func get_primary_intensity() -> Vector3:
	return _primary_intensity


func get_spherical_harmonics() -> PackedVector3Array:
	return _spherical_harmonics


func get_status() -> String:
	if not OS.has_feature("web"):
		return "Light estimation: web export required."
	if not Engine.has_singleton("JavaScriptBridge"):
		return "Light estimation: JavaScript bridge unavailable."
	var js := Engine.get_singleton("JavaScriptBridge")
	var state := str(js.eval("window.GodotWebXRLightEstimationBridge ? window.GodotWebXRLightEstimationBridge.status : 'no-bridge'", true))
	var error := str(js.eval("window.GodotWebXRLightEstimationBridge ? window.GodotWebXRLightEstimationBridge.error : ''", true))
	match state:
		"live":
			return "Light estimation LIVE: primary direction, RGB intensity, and 9-band RGB SH are updating."
		"requesting-probe", "probe-ready", "waiting-estimate":
			return "Light estimation: granted; waiting for the first environmental estimate."
		"not-granted":
			return "Light estimation: browser/runtime did not grant the optional feature (%s)." % error
		"api-unavailable":
			return "Light estimation: this browser/runtime does not expose XRLightProbe."
		"frame-error":
			return "Light estimation: frame read failed (%s)." % error
		"session-ended":
			return "Light estimation: session ended."
		_:
			return "Light estimation: waiting for an immersive AR session."


func get_state() -> String:
	# Raw JS status token for a clean UI state machine: "live", "not-granted",
	# "api-unavailable", "requesting-probe"/"probe-ready"/"waiting-estimate",
	# "waiting-session"/"session-ended", "frame-error". Consumers map it to labels.
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return "unavailable"
	var js := Engine.get_singleton("JavaScriptBridge")
	return str(js.eval("window.GodotWebXRLightEstimationBridge ? window.GodotWebXRLightEstimationBridge.status : 'no-bridge'", true))


func get_reflection_status() -> String:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return "Reflection probe unavailable outside WebXR."
	var js := Engine.get_singleton("JavaScriptBridge")
	var format := str(js.eval("window.GodotWebXRLightEstimationBridge ? window.GodotWebXRLightEstimationBridge.preferredReflectionFormat : ''", true))
	var changes := int(js.eval("window.GodotWebXRLightEstimationBridge ? window.GodotWebXRLightEstimationBridge.reflectionSeq : 0", true))
	if format.is_empty():
		return "Reflection cubemap: not advertised."
	return "Reflection cubemap advertised (%s, %d change event(s)); Godot texture interop is the next bridge slice." % [format, changes]


func get_webxr_required_features(_session_mode: String) -> PackedStringArray:
	return PackedStringArray()


func get_webxr_optional_features(session_mode: String) -> PackedStringArray:
	if session_mode == WebXRFeatures.MODE_AR:
		return PackedStringArray([WebXRFeatures.LIGHT_ESTIMATION])
	return PackedStringArray()

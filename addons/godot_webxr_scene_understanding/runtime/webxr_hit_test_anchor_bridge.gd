extends Node

## Standard WebXR hit-test and anchor acquisition. This node owns browser
## objects and publishes renderer-neutral Godot transforms; placement visuals
## and gameplay remain consumers of the signals below.

signal hit_pose_updated(hit_transform: Transform3D)
signal hit_lost
signal anchor_added(anchor_id: int, anchor_transform: Transform3D)
signal anchor_updated(anchor_id: int, anchor_transform: Transform3D, tracked: bool)
signal anchor_removed(anchor_id: int)
signal anchor_failed(message: String)
## Emitted when the bridge auto-spawns a standard XRAnchor3D (only when
## anchor_node_root is set). Attach your visuals to anchor_node.
signal anchor_node_added(anchor_id: int, anchor_node: XRAnchor3D)

@export_range(0.016, 0.25, 0.001) var poll_interval := 0.033
@export_range(1, 64, 1) var maximum_anchors := 16
## Optional: an XROrigin3D (or a node under one). When set, the bridge spawns a
## standard XRAnchor3D per anchor beneath it, each following that anchor's
## XRServer tracker - drop the bridge in and get standard anchor nodes with zero
## wiring. Leave empty to drive your own XRAnchor3D via get_anchor_tracker_name().
@export var anchor_node_root: NodePath

var _webxr: XRInterface
var _installed := false
var _poll_accum := 0.0
var _last_seq := -1
var _has_hit := false
var _hit_transform := Transform3D.IDENTITY
var _hit_mode := "viewer"
var _hit_handedness := ""
var _anchors := {}
var _anchor_trackers := {}
var _anchor_nodes := {}
var _last_error := ""

const ANCHOR_TRACKER_PREFIX := "webxr_anchor_"


func _ready() -> void:
	add_to_group("webxr_hit_test_anchor_bridge")
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
	Engine.get_singleton("JavaScriptBridge").eval("""
(function () {
	if (window.GodotWebXRHitAnchorBridge) { return; }
	const bridge = {
		status: 'waiting-session', hitStatus: 'waiting-session', anchorStatus: 'waiting-session',
		error: '', session: null, refType: 'local-floor', refSpace: null,
		viewerSpace: null, hitSource: null, sourcePending: false,
		inputRecords: [], lastSelectedSource: null,
		selectedHit: null, selectedMatrix: null, selectedHitTime: 0,
		currentHit: null, hitMatrix: null, hitVisible: false,
		hitMode: 'viewer', hitHandedness: '',
		placeRequested: false, anchorPending: false, nextAnchorId: 1,
		anchors: {}, maxAnchors: 16, seq: 0
	};
	window.GodotWebXRHitAnchorBridge = bridge;

	if (typeof XRSession === 'undefined') {
		bridge.status = 'api-unavailable';
		bridge.hitStatus = 'api-unavailable';
		bridge.anchorStatus = 'api-unavailable';
		return;
	}

	function beginSession(session) {
		bridge.session = session;
		bridge.refSpace = null;
		bridge.viewerSpace = null;
		bridge.hitSource = null;
		bridge.sourcePending = false;
		bridge.currentHit = null;
		bridge.hitMatrix = null;
		bridge.hitVisible = false;
		bridge.inputRecords = [];
		bridge.lastSelectedSource = null;
		bridge.selectedHit = null;
		bridge.selectedMatrix = null;
		bridge.selectedHitTime = 0;
		bridge.hitMode = 'viewer';
		bridge.hitHandedness = '';
		bridge.placeRequested = false;
		bridge.anchorPending = false;
		bridge.anchors = {};
		bridge.error = '';
		bridge.status = 'requesting-spaces';
		bridge.hitStatus = 'requesting-source';
		bridge.anchorStatus = 'ready';
		bridge.seq++;

		session.addEventListener('select', function (event) {
			if (bridge.session !== session) { return; }
			bridge.lastSelectedSource = event.inputSource || null;
			const record = bridge.inputRecords.find(function (item) {
				return item.source === bridge.lastSelectedSource;
			});
			if (record && record.currentHit) {
				bridge.selectedHit = record.currentHit;
				bridge.selectedMatrix = record.matrix ? record.matrix.slice() : null;
				bridge.selectedHitTime = performance.now();
			}
		});

		session.requestReferenceSpace(bridge.refType).then(function (space) {
			if (bridge.session !== session) { return; }
			bridge.refSpace = space;
		}).catch(function (error) {
			if (bridge.session !== session) { return; }
			bridge.error = error && (error.name || error.message) ? String(error.name || error.message) : 'reference-space';
			bridge.status = 'reference-space-failed';
		});

		if (typeof session.requestHitTestSource !== 'function') {
			bridge.hitStatus = 'api-unavailable';
			bridge.status = 'hit-api-unavailable';
			return;
		}
		bridge.sourcePending = true;
		session.requestReferenceSpace('viewer').then(function (viewerSpace) {
			if (bridge.session !== session) { return null; }
			bridge.viewerSpace = viewerSpace;
			return session.requestHitTestSource({ space: viewerSpace });
		}).then(function (source) {
			if (!source || bridge.session !== session) { return; }
			bridge.sourcePending = false;
			bridge.hitSource = source;
			bridge.hitStatus = 'source-ready';
			bridge.status = 'ready';
		}).catch(function (error) {
			if (bridge.session !== session) { return; }
			bridge.sourcePending = false;
			bridge.error = error && (error.name || error.message) ? String(error.name || error.message) : 'hit-test';
			bridge.hitStatus = 'not-granted';
			bridge.status = 'hit-not-granted';
		});
	}

	function syncInputHitSources(session) {
		const sources = Array.from(session.inputSources || []).filter(function (source) {
			return source && source.targetRaySpace && source.targetRayMode === 'tracked-pointer';
		});
		for (let index = bridge.inputRecords.length - 1; index >= 0; index--) {
			const record = bridge.inputRecords[index];
			if (sources.indexOf(record.source) < 0) {
				if (record.hitSource) { try { record.hitSource.cancel(); } catch (_) {} }
				bridge.inputRecords.splice(index, 1);
			}
		}
		sources.forEach(function (source) {
			if (bridge.inputRecords.some(function (record) { return record.source === source; })) { return; }
			const record = { source: source, hitSource: null, pending: true, currentHit: null, matrix: null };
			bridge.inputRecords.push(record);
			session.requestHitTestSource({ space: source.targetRaySpace }).then(function (hitSource) {
				if (bridge.session !== session || bridge.inputRecords.indexOf(record) < 0) {
					try { hitSource.cancel(); } catch (_) {}
					return;
				}
				record.hitSource = hitSource;
				record.pending = false;
			}).catch(function () {
				record.pending = false;
			});
		});
	}

	function createAnchorFromCurrentHit() {
		bridge.placeRequested = false;
		let placementHit = bridge.currentHit;
		let placementMatrix = bridge.hitMatrix;
		if (bridge.selectedHit && performance.now() - bridge.selectedHitTime < 750) {
			placementHit = bridge.selectedHit;
			placementMatrix = bridge.selectedMatrix;
		}
		bridge.selectedHit = null;
		bridge.selectedMatrix = null;
		if (!placementHit) {
			bridge.anchorStatus = 'no-hit';
			bridge.error = 'No current surface hit';
			bridge.seq++;
			return;
		}
		if (typeof placementHit.createAnchor !== 'function') {
			bridge.anchorStatus = 'api-unavailable';
			bridge.error = 'XRHitTestResult.createAnchor unavailable';
			bridge.seq++;
			return;
		}
		if (bridge.anchorPending) { return; }
		bridge.anchorPending = true;
		bridge.anchorStatus = 'creating';
		const initialMatrix = placementMatrix ? placementMatrix.slice() : null;
		placementHit.createAnchor().then(function (anchor) {
			bridge.anchorPending = false;
			if (!bridge.session) {
				try { anchor.delete(); } catch (_) {}
				return;
			}
			const id = bridge.nextAnchorId++;
			bridge.anchors[id] = { anchor: anchor, matrix: initialMatrix, tracked: true };
			bridge.anchorStatus = 'created';
			const ids = Object.keys(bridge.anchors).map(Number).sort(function (a, b) { return a - b; });
			while (ids.length > bridge.maxAnchors) {
				const oldId = ids.shift();
				const oldRecord = bridge.anchors[oldId];
				try { oldRecord.anchor.delete(); } catch (_) {}
				delete bridge.anchors[oldId];
			}
			bridge.seq++;
		}).catch(function (error) {
			bridge.anchorPending = false;
			bridge.error = error && (error.name || error.message) ? String(error.name || error.message) : 'anchor';
			bridge.anchorStatus = 'create-failed';
			bridge.seq++;
		});
	}

	const originalRequestAnimationFrame = XRSession.prototype.requestAnimationFrame;
	XRSession.prototype.requestAnimationFrame = function (callback) {
		return originalRequestAnimationFrame.call(this, function (time, frame) {
			try {
				if (bridge.session !== frame.session) { beginSession(frame.session); }
				syncInputHitSources(frame.session);
				let nextHitVisible = false;
				let viewerHit = null;
				let viewerMatrix = null;
				if (bridge.refSpace && bridge.hitSource && typeof frame.getHitTestResults === 'function') {
					const results = frame.getHitTestResults(bridge.hitSource);
					if (results && results.length > 0) {
						const pose = results[0].getPose(bridge.refSpace);
						if (pose) {
							viewerHit = results[0];
							viewerMatrix = Array.from(pose.transform.matrix);
						}
					}
				}

				bridge.inputRecords.forEach(function (record) {
					record.currentHit = null;
					record.matrix = null;
					if (!bridge.refSpace || !record.hitSource || typeof frame.getHitTestResults !== 'function') { return; }
					const results = frame.getHitTestResults(record.hitSource);
					if (!results || results.length === 0) { return; }
					const pose = results[0].getPose(bridge.refSpace);
					if (!pose) { return; }
					record.currentHit = results[0];
					record.matrix = Array.from(pose.transform.matrix);
				});

				let activeRecord = bridge.inputRecords.find(function (record) {
					return record.source === bridge.lastSelectedSource && record.currentHit;
				});
				if (!activeRecord) {
					activeRecord = bridge.inputRecords.find(function (record) {
						return record.source.handedness === 'right' && record.currentHit;
					});
				}
				if (!activeRecord) {
					activeRecord = bridge.inputRecords.find(function (record) {
						return record.source.handedness === 'left' && record.currentHit;
					});
				}
				if (!activeRecord) {
					activeRecord = bridge.inputRecords.find(function (record) { return !!record.currentHit; });
				}
				if (activeRecord) {
					bridge.currentHit = activeRecord.currentHit;
					bridge.hitMatrix = activeRecord.matrix;
					bridge.hitMode = 'tracked-pointer';
					bridge.hitHandedness = activeRecord.source.handedness || '';
					nextHitVisible = true;
				} else if (viewerHit) {
					bridge.currentHit = viewerHit;
					bridge.hitMatrix = viewerMatrix;
					bridge.hitMode = 'viewer';
					bridge.hitHandedness = '';
					nextHitVisible = true;
				}
				if (nextHitVisible) {
					bridge.hitStatus = 'live';
					bridge.status = 'live';
				}
				if (!nextHitVisible) {
					bridge.currentHit = null;
					bridge.hitMatrix = null;
					bridge.hitMode = bridge.inputRecords.length > 0 ? 'tracked-pointer' : 'viewer';
					bridge.hitHandedness = '';
					if (bridge.hitSource) { bridge.hitStatus = 'no-hit'; }
				}
				bridge.hitVisible = nextHitVisible;

				if (bridge.placeRequested) { createAnchorFromCurrentHit(); }

				const trackedAnchors = frame.trackedAnchors;
				for (const id in bridge.anchors) {
					const record = bridge.anchors[id];
					const tracked = !!trackedAnchors && trackedAnchors.has(record.anchor);
					record.tracked = tracked;
					if (tracked && bridge.refSpace) {
						const pose = frame.getPose(record.anchor.anchorSpace, bridge.refSpace);
						if (pose) { record.matrix = Array.from(pose.transform.matrix); }
					}
				}
				bridge.seq++;
			} catch (error) {
				bridge.error = error && (error.name || error.message) ? String(error.name || error.message) : 'frame';
				bridge.status = 'frame-error';
				bridge.seq++;
			}
			callback(time, frame);
		});
	};
}())
""", true)


func _on_session_started() -> void:
	_reset_local_state()
	var reference_type: String = str(_webxr.reference_space_type) if _webxr else "local-floor"
	if reference_type.is_empty():
		reference_type = "local-floor"
	var js := Engine.get_singleton("JavaScriptBridge")
	js.eval("""
(function () {
	const bridge = window.GodotWebXRHitAnchorBridge;
	if (!bridge) { return; }
	bridge.refType = %s;
	bridge.maxAnchors = %d;
}())
""" % [JSON.stringify(reference_type), maximum_anchors], true)
	set_process(true)


func _on_session_ended() -> void:
	set_process(false)
	clear_anchors()
	_reset_local_state()
	Engine.get_singleton("JavaScriptBridge").eval("""
(function () {
	const bridge = window.GodotWebXRHitAnchorBridge;
	if (!bridge) { return; }
	if (bridge.hitSource) { try { bridge.hitSource.cancel(); } catch (_) {} }
	bridge.inputRecords.forEach(function (record) {
		if (record.hitSource) { try { record.hitSource.cancel(); } catch (_) {} }
	});
	bridge.session = null;
	bridge.refSpace = null;
	bridge.viewerSpace = null;
	bridge.hitSource = null;
	bridge.inputRecords = [];
	bridge.lastSelectedSource = null;
	bridge.selectedHit = null;
	bridge.currentHit = null;
	bridge.hitVisible = false;
	bridge.status = 'session-ended';
}())
""", true)


func _process(delta: float) -> void:
	_poll_accum += delta
	if _poll_accum < poll_interval:
		return
	_poll_accum = 0.0
	_poll_bridge()


func _poll_bridge() -> void:
	var payload := str(Engine.get_singleton("JavaScriptBridge").eval("""
(function () {
	const bridge = window.GodotWebXRHitAnchorBridge;
	if (!bridge) { return '{}'; }
	const anchors = {};
	for (const id in bridge.anchors) {
		const record = bridge.anchors[id];
		anchors[id] = { matrix: record.matrix, tracked: record.tracked };
	}
	return JSON.stringify({
		seq: bridge.seq,
		hitVisible: bridge.hitVisible,
		hitMatrix: bridge.hitMatrix,
		hitMode: bridge.hitMode,
		hitHandedness: bridge.hitHandedness,
		anchors: anchors,
		anchorStatus: bridge.anchorStatus,
		error: bridge.error
	});
}())
""", true))
	var parsed = JSON.parse_string(payload)
	if not (parsed is Dictionary):
		return
	var seq := int(parsed.get("seq", -1))
	if seq < 0 or seq == _last_seq:
		return
	_last_seq = seq
	_hit_mode = str(parsed.get("hitMode", "viewer"))
	_hit_handedness = str(parsed.get("hitHandedness", ""))

	var next_hit := bool(parsed.get("hitVisible", false))
	var hit_matrix = parsed.get("hitMatrix", [])
	if next_hit and hit_matrix is Array and hit_matrix.size() >= 16:
		_hit_transform = _matrix_to_transform(hit_matrix)
		_has_hit = true
		hit_pose_updated.emit(_hit_transform)
	elif _has_hit:
		_has_hit = false
		hit_lost.emit()

	var incoming = parsed.get("anchors", {})
	if incoming is Dictionary:
		var seen := {}
		for id_value in incoming.keys():
			var anchor_id := int(id_value)
			var record = incoming[id_value]
			if not (record is Dictionary):
				continue
			var matrix = record.get("matrix", [])
			if not (matrix is Array) or matrix.size() < 16:
				continue
			var anchor_transform := _matrix_to_transform(matrix)
			var tracked := bool(record.get("tracked", false))
			seen[anchor_id] = true
			if not _anchors.has(anchor_id):
				_anchors[anchor_id] = anchor_transform
				_register_anchor_tracker(anchor_id, anchor_transform)
				anchor_added.emit(anchor_id, anchor_transform)
			else:
				_anchors[anchor_id] = anchor_transform
			_update_anchor_tracker(anchor_id, anchor_transform, tracked)
			anchor_updated.emit(anchor_id, anchor_transform, tracked)
		for existing_id in _anchors.keys().duplicate():
			if not seen.has(existing_id):
				_anchors.erase(existing_id)
				_remove_anchor_tracker(existing_id)
				anchor_removed.emit(existing_id)

	var anchor_state := str(parsed.get("anchorStatus", ""))
	var error := str(parsed.get("error", ""))
	if anchor_state in ["create-failed", "api-unavailable"] and error != _last_error:
		_last_error = error
		anchor_failed.emit(error)


func request_anchor() -> bool:
	if not _has_hit or not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return false
	Engine.get_singleton("JavaScriptBridge").eval(
		"window.GodotWebXRHitAnchorBridge && (window.GodotWebXRHitAnchorBridge.placeRequested = true);",
		true
	)
	return true


func clear_anchors() -> void:
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		Engine.get_singleton("JavaScriptBridge").eval("""
(function () {
	const bridge = window.GodotWebXRHitAnchorBridge;
	if (!bridge) { return; }
	for (const id in bridge.anchors) {
		try { bridge.anchors[id].anchor.delete(); } catch (_) {}
	}
	bridge.anchors = {};
	bridge.anchorStatus = 'cleared';
	bridge.seq++;
}())
""", true)
	for anchor_id in _anchors.keys():
		_remove_anchor_tracker(anchor_id)
		anchor_removed.emit(anchor_id)
	_anchors.clear()


func _reset_local_state() -> void:
	if _has_hit:
		hit_lost.emit()
	for anchor_id in _anchors.keys():
		_remove_anchor_tracker(anchor_id)
		anchor_removed.emit(anchor_id)
	_has_hit = false
	_hit_transform = Transform3D.IDENTITY
	_hit_mode = "viewer"
	_hit_handedness = ""
	_anchors.clear()
	_last_seq = -1
	_last_error = ""
	_poll_accum = 0.0


func has_hit() -> bool:
	return _has_hit


func get_hit_transform() -> Transform3D:
	return _hit_transform


func get_hit_aim_label() -> String:
	if _hit_mode == "tracked-pointer":
		if not _hit_handedness.is_empty():
			return "%s-hand ray" % _hit_handedness
		return "tracked hand/controller ray"
	return "head-view fallback"


func get_anchor_count() -> int:
	return _anchors.size()


func get_status() -> String:
	if not OS.has_feature("web"):
		return "Hit Test + Anchors: web export required."
	if not Engine.has_singleton("JavaScriptBridge"):
		return "Hit Test + Anchors: JavaScript bridge unavailable."
	var js := Engine.get_singleton("JavaScriptBridge")
	var status := str(js.eval("window.GodotWebXRHitAnchorBridge ? window.GodotWebXRHitAnchorBridge.status : 'no-bridge'", true))
	var hit_status := str(js.eval("window.GodotWebXRHitAnchorBridge ? window.GodotWebXRHitAnchorBridge.hitStatus : ''", true))
	var anchor_status := str(js.eval("window.GodotWebXRHitAnchorBridge ? window.GodotWebXRHitAnchorBridge.anchorStatus : ''", true))
	var error := str(js.eval("window.GodotWebXRHitAnchorBridge ? window.GodotWebXRHitAnchorBridge.error : ''", true))
	if status == "frame-error" or status == "reference-space-failed":
		return "Hit Test + Anchors: %s (%s)." % [status, error]
	if hit_status == "not-granted":
		return "Hit testing was not granted by this browser/runtime (%s)." % error
	if hit_status == "api-unavailable":
		return "Hit testing is unavailable in this browser/runtime."
	if anchor_status == "api-unavailable":
		return "Hit testing LIVE; anchor creation is unavailable."
	if _has_hit:
		return "Surface hit LIVE via %s. Pinch or press select to place an anchor. Anchors: %d/%d." % [get_hit_aim_label(), _anchors.size(), maximum_anchors]
	if hit_status in ["source-ready", "no-hit"]:
		return "Hit test ready (%s); aim at a real floor, table, or wall. Anchors: %d/%d." % [get_hit_aim_label(), _anchors.size(), maximum_anchors]
	return "Hit Test + Anchors: waiting for an immersive AR session."


func get_webxr_required_features(_session_mode: String) -> PackedStringArray:
	return PackedStringArray()


func get_webxr_optional_features(session_mode: String) -> PackedStringArray:
	if session_mode == WebXRFeatures.MODE_AR:
		return PackedStringArray([WebXRFeatures.HIT_TEST, WebXRFeatures.ANCHORS])
	return PackedStringArray()


## Tracker name an XRAnchor3D should follow for a given anchor id, e.g. wire it
## from the anchor_added signal: node.tracker = bridge.get_anchor_tracker_name(id).
func get_anchor_tracker_name(anchor_id: int) -> StringName:
	return StringName(ANCHOR_TRACKER_PREFIX + str(anchor_id))

func _register_anchor_tracker(anchor_id: int, anchor_transform: Transform3D) -> void:
	var tracker := XRPositionalTracker.new()
	tracker.type = XRServer.TRACKER_ANCHOR
	tracker.name = get_anchor_tracker_name(anchor_id)
	XRServer.add_tracker(tracker)
	_anchor_trackers[anchor_id] = tracker
	_set_anchor_pose(tracker, anchor_transform, true)
	if not anchor_node_root.is_empty():
		var root := get_node_or_null(anchor_node_root)
		if root != null:
			var node := XRAnchor3D.new()
			node.tracker = get_anchor_tracker_name(anchor_id)
			node.pose = &"default"
			root.add_child(node)
			_anchor_nodes[anchor_id] = node
			anchor_node_added.emit(anchor_id, node)

func _update_anchor_tracker(anchor_id: int, anchor_transform: Transform3D, tracked: bool) -> void:
	var tracker = _anchor_trackers.get(anchor_id)
	if tracker != null:
		_set_anchor_pose(tracker, anchor_transform, tracked)

func _set_anchor_pose(tracker: XRPositionalTracker, anchor_transform: Transform3D, tracked: bool) -> void:
	var confidence := XRPose.XR_TRACKING_CONFIDENCE_HIGH if tracked else XRPose.XR_TRACKING_CONFIDENCE_LOW
	tracker.set_pose(&"default", anchor_transform, Vector3.ZERO, Vector3.ZERO, confidence)

func _remove_anchor_tracker(anchor_id: int) -> void:
	var tracker = _anchor_trackers.get(anchor_id)
	if tracker != null:
		XRServer.remove_tracker(tracker)
		_anchor_trackers.erase(anchor_id)
	var node = _anchor_nodes.get(anchor_id)
	if node != null:
		if is_instance_valid(node):
			node.queue_free()
		_anchor_nodes.erase(anchor_id)

static func _matrix_to_transform(matrix: Array) -> Transform3D:
	var basis := Basis(
		Vector3(float(matrix[0]), float(matrix[1]), float(matrix[2])),
		Vector3(float(matrix[4]), float(matrix[5]), float(matrix[6])),
		Vector3(float(matrix[8]), float(matrix[9]), float(matrix[10]))
	)
	var origin := Vector3(float(matrix[12]), float(matrix[13]), float(matrix[14]))
	return Transform3D(basis, origin)

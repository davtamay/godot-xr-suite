extends Node3D

## Procedural hand-tracking visualizer for WebXR/OpenXR.
## Attach under XROrigin3D so XRHandTracker joint transforms can be used directly.

## Preloaded so the shader baker can precompile it for web/WebGPU exports.
const JOINT_MATERIAL := preload("res://addons/godot_xr_hands/runtime/hand_joint_material.tres")

@export var status_label_path: NodePath
@export var joint_radius_min := 0.012
@export var joint_radius_max := 0.026
@export var bone_radius := 0.006
@export var pinch_threshold := 0.035
@export var show_tracking_diagnostics := true
@export var prefer_browser_hand_bridge := true
@export var render_fallback_hand_mesh := false
@export var render_fallback_for_unproven_joints := false
@export var stale_joint_pose_max_distance := 0.0
@export var startup_mesh_warmup_seconds := 1.5
@export var startup_live_anchor_delta := 0.015
@export var left_fallback_pose_path: NodePath
@export var right_fallback_pose_path: NodePath
@export var world_status_label_path: NodePath

const XRInputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

const BROWSER_HAND_JOINT_NAMES := {
    XRHandTracker.HAND_JOINT_WRIST: "wrist",
    XRHandTracker.HAND_JOINT_THUMB_METACARPAL: "thumb-metacarpal",
    XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL: "thumb-phalanx-proximal",
    XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL: "thumb-phalanx-distal",
    XRHandTracker.HAND_JOINT_THUMB_TIP: "thumb-tip",
    XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL: "index-finger-metacarpal",
    XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL: "index-finger-phalanx-proximal",
    XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE: "index-finger-phalanx-intermediate",
    XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL: "index-finger-phalanx-distal",
    XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP: "index-finger-tip",
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL: "middle-finger-metacarpal",
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL: "middle-finger-phalanx-proximal",
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE: "middle-finger-phalanx-intermediate",
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL: "middle-finger-phalanx-distal",
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP: "middle-finger-tip",
    XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL: "ring-finger-metacarpal",
    XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL: "ring-finger-phalanx-proximal",
    XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE: "ring-finger-phalanx-intermediate",
    XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL: "ring-finger-phalanx-distal",
    XRHandTracker.HAND_JOINT_RING_FINGER_TIP: "ring-finger-tip",
    XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL: "pinky-finger-metacarpal",
    XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL: "pinky-finger-phalanx-proximal",
    XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE: "pinky-finger-phalanx-intermediate",
    XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL: "pinky-finger-phalanx-distal",
    XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP: "pinky-finger-tip",
}

const HAND_JOINTS := [
    XRHandTracker.HAND_JOINT_PALM,
    XRHandTracker.HAND_JOINT_WRIST,
    XRHandTracker.HAND_JOINT_THUMB_METACARPAL,
    XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
    XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,
    XRHandTracker.HAND_JOINT_THUMB_TIP,
    XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
    XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
    XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
    XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
    XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
    XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
    XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
    XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
    XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
    XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
    XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
    XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
    XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
    XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
    XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
    XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
]

const BONE_PAIRS := [
    [XRHandTracker.HAND_JOINT_WRIST, XRHandTracker.HAND_JOINT_PALM],
    [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_THUMB_METACARPAL],
    [XRHandTracker.HAND_JOINT_THUMB_METACARPAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL],
    [XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL],
    [XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_THUMB_TIP],
    [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL],
    [XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL],
    [XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE],
    [XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL],
    [XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
    [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL],
    [XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL],
    [XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE],
    [XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL],
    [XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
    [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL],
    [XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL],
    [XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE],
    [XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL],
    [XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
    [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL],
    [XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL],
    [XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE],
    [XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL],
    [XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP],
]

var _status_label: Label
var _world_status_label: Label
var _joint_mesh: SphereMesh
var _bone_mesh: CylinderMesh
var _hands := {}
var _last_hand_debug := {}
var _last_tracking_summary := ""
var _status_elapsed := 0.0
var _xr_active := false
var _xr_elapsed := 0.0
var _js_bridge
var _browser_hand_snapshot := {}

func _ready() -> void:
    _status_label = get_node_or_null(status_label_path) as Label
    _world_status_label = get_node_or_null(world_status_label_path) as Label
    if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
        _js_bridge = Engine.get_singleton("JavaScriptBridge")
    _auto_resolve_controllers()
    _create_shared_meshes()
    _create_hand("Left", XRInputAdapter.Hand.LEFT, left_fallback_pose_path, Color(0.15, 0.72, 1.0, 1.0))
    _create_hand("Right", XRInputAdapter.Hand.RIGHT, right_fallback_pose_path, Color(1.0, 0.48, 0.18, 1.0))

## Resilience: if the fallback controller paths were not wired, find the sibling
## XRController3D nodes automatically. Lets the visualizer drop under any
## XROrigin3D and "just work" with no NodePath setup.
func _auto_resolve_controllers() -> void:
    var parent := get_parent()
    if parent == null:
        return
    for child in parent.get_children():
        if child is XRController3D:
            if left_fallback_pose_path.is_empty() and (child as XRController3D).tracker == &"left_hand":
                left_fallback_pose_path = child.get_path()
            elif right_fallback_pose_path.is_empty() and (child as XRController3D).tracker == &"right_hand":
                right_fallback_pose_path = child.get_path()

func _process(delta: float) -> void:
    _status_elapsed += delta

    if not get_viewport().use_xr:
        _xr_active = false
        _xr_elapsed = 0.0
        for hand_data in _hands.values():
            _reset_hand_startup_state(hand_data)
            hand_data["root"].visible = false
        return

    if not _xr_active:
        _xr_active = true
        _xr_elapsed = 0.0
        for hand_data in _hands.values():
            _reset_hand_startup_state(hand_data)
    else:
        _xr_elapsed += delta

    _refresh_browser_hand_snapshot()

    var active_hands: Array[String] = []
    for hand_name in _hands.keys():
        if _update_hand(_hands[hand_name], delta):
            active_hands.append(hand_name)

    if _status_elapsed >= 0.5:
        _status_elapsed = 0.0
        var summary := ", ".join(active_hands) if not active_hands.is_empty() else "none"
        if show_tracking_diagnostics:
            var details: Array[String] = []
            for hand_name in _hands.keys():
                details.append("%s %s" % [hand_name.substr(0, 1), _last_hand_debug.get(hand_name, "pending")])
            summary = "%s | %s" % [summary, " | ".join(details)]
        if summary != _last_tracking_summary:
            _last_tracking_summary = summary
            _set_status("Hand tracking: %s." % summary)

func _create_shared_meshes() -> void:
    _joint_mesh = SphereMesh.new()
    _joint_mesh.radius = 1.0
    _joint_mesh.height = 2.0
    _joint_mesh.radial_segments = 12
    _joint_mesh.rings = 6

    _bone_mesh = CylinderMesh.new()
    _bone_mesh.top_radius = 1.0
    _bone_mesh.bottom_radius = 1.0
    _bone_mesh.height = 1.0
    _bone_mesh.radial_segments = 8
    _bone_mesh.rings = 1

func _create_hand(hand_name: String, hand_id: int, fallback_pose_path: NodePath, color: Color) -> void:
    var root := Node3D.new()
    root.name = XRHandIdentity.hand_tracking_root_name(hand_id)
    root.visible = false
    add_child(root)

    var material := _create_material(color)
    var pinch_material := _create_material(Color(0.25, 1.0, 0.55, 1.0))

    var joint_nodes := {}
    for joint_id in HAND_JOINTS:
        var joint_node := MeshInstance3D.new()
        joint_node.name = "Joint_%02d" % joint_id
        joint_node.mesh = _joint_mesh
        joint_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        joint_node.set_surface_override_material(0, material)
        root.add_child(joint_node)
        joint_nodes[joint_id] = joint_node

    var bone_nodes: Array[MeshInstance3D] = []
    for bone_index in range(BONE_PAIRS.size()):
        var bone_node := MeshInstance3D.new()
        bone_node.name = "Bone_%02d" % bone_index
        bone_node.mesh = _bone_mesh
        bone_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        bone_node.set_surface_override_material(0, material)
        root.add_child(bone_node)
        bone_nodes.append(bone_node)

    _hands[hand_name] = {
        "label": hand_name,
        "root": root,
        "hand": hand_id,
        "fallback_pose_path": fallback_pose_path,
        "material": material,
        "pinch_material": pinch_material,
        "joints": joint_nodes,
        "bones": bone_nodes,
        "last_anchor": null,
        "live_anchor_delta": 0.0,
        "startup_ready": false,
        "prev_anchor": null,
        "static_time": 0.0,
    }
    _last_hand_debug[hand_name] = "pending"

func _create_material(color: Color) -> StandardMaterial3D:
    # Duplicate of a baked .tres so web/WebGPU exports have the shader
    # precompiled; colors/roughness are uniforms, so the hash is kept.
    var material := JOINT_MATERIAL.duplicate() as StandardMaterial3D
    material.albedo_color = color
    material.emission = color
    material.emission_energy_multiplier = 0.45
    material.roughness = 0.7
    return material

func _update_hand(hand_data: Dictionary, p_delta: float) -> bool:
    var hand_name: String = hand_data["label"]
    var hand_id: int = hand_data["hand"]
    var root := hand_data["root"] as Node3D

    if prefer_browser_hand_bridge and _update_hand_from_browser_bridge(hand_data):
        return true

    var tracker := XRHandTrackerResolver.get_tracker(hand_id)
    if tracker == null:
        if render_fallback_hand_mesh and _update_fallback_hand(hand_data, "no joints"):
            return true
        _last_hand_debug[hand_name] = "no tracker"
        root.visible = false
        return false

    if not tracker.has_tracking_data:
        # The engine invalidates the tracker when the browser drops the
        # hand's input source; its joints are stale until tracking resumes.
        _reset_hand_startup_state(hand_data)
        _last_hand_debug[hand_name] = "tracking lost - waiting for the platform to re-acquire"
        root.visible = false
        return false

    var joint_positions := {}
    var joint_valid := {}
    var joint_nodes := hand_data["joints"] as Dictionary
    var valid_joint_count := 0

    for joint_id in HAND_JOINTS:
        var valid := _is_joint_position_valid(tracker, joint_id)
        joint_valid[joint_id] = valid
        var joint_node := joint_nodes[joint_id] as MeshInstance3D
        joint_node.visible = valid
        if not valid:
            continue

        valid_joint_count += 1
        var joint_transform := tracker.get_hand_joint_transform(joint_id)
        var radius: float = clamp(tracker.get_hand_joint_radius(joint_id), joint_radius_min, joint_radius_max)
        joint_positions[joint_id] = joint_transform.origin
        joint_node.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * radius), joint_transform.origin)

    if valid_joint_count == 0:
        var empty_source := XRHandTrackerResolver.tracker_debug_name(hand_id, tracker)
        var reason := "0 joints tracking=%s src=%s" % [str(tracker.has_tracking_data), empty_source]
        if render_fallback_hand_mesh and _update_fallback_hand(hand_data, reason):
            return true
        _last_hand_debug[hand_name] = reason
        root.visible = false
        return false

    var source := XRHandTrackerResolver.tracker_debug_name(hand_id, tracker)
    var anchor = _joint_anchor_position(joint_positions, joint_valid)
    if anchor != null:
        # Continuous freeze watchdog: live tracking always jitters, so a
        # bit-identical anchor for this long means the platform froze the
        # pose mid-session (e.g. hands occluded). Hide and re-prove.
        if hand_data["prev_anchor"] != null and (anchor as Vector3) == (hand_data["prev_anchor"] as Vector3):
            hand_data["static_time"] = float(hand_data["static_time"]) + p_delta
        else:
            hand_data["static_time"] = 0.0
        hand_data["prev_anchor"] = anchor
        if bool(hand_data["startup_ready"]) and float(hand_data["static_time"]) > 0.75:
            _reset_hand_startup_state(hand_data)
            _last_hand_debug[hand_name] = "%d joints FROZEN mid-session - waiting for live tracking (src=%s)" % [valid_joint_count, source]
            root.visible = false
            return false
    _update_hand_startup_state(hand_data, anchor)
    if _hand_waiting_for_startup(hand_data):
        if _xr_elapsed >= startup_mesh_warmup_seconds and float(hand_data["live_anchor_delta"]) == 0.0:
            # Valid joints with EXACTLY zero cumulative motion past warm-up is
            # impossible for a live sensor: the browser is serving the previous
            # session'''s last-known pose as "valid" (seen on Quest Browser
            # after AR<->VR switches) and will not re-acquire on its own.
            _last_hand_debug[hand_name] = "%d joints FROZEN by the browser - hide your hands, then show them to the cameras (src=%s)" % [valid_joint_count, source]
            root.visible = false
            return false
        if _xr_elapsed >= startup_mesh_warmup_seconds and render_fallback_for_unproven_joints:
            if _update_fallback_hand(hand_data, "%d joints unproven src=%s" % [valid_joint_count, source]):
                return true
        _last_hand_debug[hand_name] = "%d joints warming %.2fs live=%.3f src=%s" % [
            valid_joint_count,
            maxf(startup_mesh_warmup_seconds - _xr_elapsed, 0.0),
            float(hand_data["live_anchor_delta"]),
            source,
        ]
        root.visible = false
        return false

    if _joint_pose_looks_stale(hand_data, joint_positions, joint_valid):
        _last_hand_debug[hand_name] = "%d joints stale src=%s" % [valid_joint_count, source]
        root.visible = false
        return false

    _last_hand_debug[hand_name] = "%d joints tracking=%s src=%s" % [valid_joint_count, str(tracker.has_tracking_data), source]
    root.visible = true
    _update_bones(hand_data["bones"], joint_positions, joint_valid)
    _update_pinch_materials(hand_data, joint_positions, joint_valid)
    return true

func _is_joint_position_valid(tracker: XRHandTracker, joint_id: int) -> bool:
    return XRHandTrackerResolver.joint_position_valid(tracker, joint_id)

func _refresh_browser_hand_snapshot() -> void:
    if _js_bridge == null:
        _browser_hand_snapshot = {}
        return

    var json_text = _js_bridge.eval("JSON.stringify(window.CompanyWebXRHandBridge && window.CompanyWebXRHandBridge.latest || null)", true)
    var parsed = JSON.parse_string(str(json_text))
    if typeof(parsed) == TYPE_DICTIONARY:
        _browser_hand_snapshot = parsed
    else:
        _browser_hand_snapshot = {}

func _update_hand_from_browser_bridge(hand_data: Dictionary) -> bool:
    if _browser_hand_snapshot.is_empty():
        return false

    var hands = _browser_hand_snapshot.get("hands", {})
    if typeof(hands) != TYPE_DICTIONARY:
        return false

    var hand_name: String = hand_data["label"]
    var hand_id: int = hand_data["hand"]
    var side := "right" if hand_id == XRInputAdapter.Hand.RIGHT else "left"
    var hand_snapshot = hands.get(side, {})
    if typeof(hand_snapshot) != TYPE_DICTIONARY:
        return false

    var joints = hand_snapshot.get("joints", {})
    if typeof(joints) != TYPE_DICTIONARY:
        return false

    var root := hand_data["root"] as Node3D
    var joint_nodes := hand_data["joints"] as Dictionary
    var joint_positions := {}
    var joint_valid := {}
    var valid_joint_count := 0

    for joint_id in HAND_JOINTS:
        var sample := _browser_bridge_joint_sample(joints, joint_id)
        var joint_node := joint_nodes[joint_id] as MeshInstance3D
        if sample.is_empty():
            joint_node.visible = false
            joint_valid[joint_id] = false
            continue

        var joint_position := _browser_bridge_sample_position(sample)
        var radius: float = clamp(float(sample.get("r", joint_radius_min)), joint_radius_min, joint_radius_max)
        joint_positions[joint_id] = joint_position
        joint_valid[joint_id] = true
        joint_node.visible = true
        joint_node.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * radius), joint_position)
        valid_joint_count += 1

    if valid_joint_count == 0:
        root.visible = false
        return false

    root.visible = true
    var frame_number := int(_browser_hand_snapshot.get("frame", 0))
    _last_hand_debug[hand_name] = "%d browser joints frame=%d" % [valid_joint_count, frame_number]
    _update_bones(hand_data["bones"], joint_positions, joint_valid)
    _update_pinch_materials(hand_data, joint_positions, joint_valid)
    return true

func _browser_bridge_joint_sample(joints: Dictionary, joint_id: int) -> Dictionary:
    if joint_id == XRHandTracker.HAND_JOINT_PALM:
        return _browser_bridge_palm_sample(joints)

    var joint_name: String = BROWSER_HAND_JOINT_NAMES.get(joint_id, "")
    if joint_name.is_empty():
        return {}

    var sample = joints.get(joint_name, {})
    return sample if typeof(sample) == TYPE_DICTIONARY else {}

func _browser_bridge_palm_sample(joints: Dictionary) -> Dictionary:
    var names := [
        "wrist",
        "index-finger-metacarpal",
        "middle-finger-metacarpal",
        "ring-finger-metacarpal",
        "pinky-finger-metacarpal",
    ]
    var position := Vector3.ZERO
    var radius := 0.0
    var count := 0
    for joint_name in names:
        var sample = joints.get(joint_name, {})
        if typeof(sample) != TYPE_DICTIONARY:
            continue
        position += _browser_bridge_sample_position(sample)
        radius += float(sample.get("r", joint_radius_min))
        count += 1

    if count == 0:
        return {}

    position /= float(count)
    radius /= float(count)
    return {
        "x": position.x,
        "y": position.y,
        "z": position.z,
        "r": radius,
    }

func _browser_bridge_sample_position(sample: Dictionary) -> Vector3:
    return Vector3(
        float(sample.get("x", 0.0)),
        float(sample.get("y", 0.0)),
        float(sample.get("z", 0.0))
    )

func _reset_hand_startup_state(hand_data: Dictionary) -> void:
    hand_data["last_anchor"] = null
    hand_data["live_anchor_delta"] = 0.0
    hand_data["startup_ready"] = false
    hand_data["prev_anchor"] = null
    hand_data["static_time"] = 0.0

func _update_hand_startup_state(hand_data: Dictionary, anchor) -> void:
    if bool(hand_data["startup_ready"]):
        return
    if anchor == null:
        return

    var anchor_position := anchor as Vector3
    var last_anchor = hand_data["last_anchor"]
    if last_anchor != null:
        # Accumulate ANY nonzero change: a frozen last-known pose repeats
        # bit-identical positions (delta exactly 0) while live tracking always
        # jitters, so no per-frame floor is needed. A floor here would be
        # frame-rate dependent (1mm @ 90fps demanded 9cm/s of sustained motion,
        # which made the mesh never start when hands were held still).
        var delta := anchor_position.distance_to(last_anchor as Vector3)
        hand_data["live_anchor_delta"] = float(hand_data["live_anchor_delta"]) + delta

    hand_data["last_anchor"] = anchor_position
    if float(hand_data["live_anchor_delta"]) >= startup_live_anchor_delta:
        hand_data["startup_ready"] = true

func _hand_waiting_for_startup(hand_data: Dictionary) -> bool:
    if startup_mesh_warmup_seconds > 0.0 and _xr_elapsed < startup_mesh_warmup_seconds:
        return true
    if startup_live_anchor_delta > 0.0 and not bool(hand_data["startup_ready"]):
        return true
    return false

func _joint_pose_looks_stale(hand_data: Dictionary, joint_positions: Dictionary, joint_valid: Dictionary) -> bool:
    if stale_joint_pose_max_distance <= 0.0:
        return false

    var fallback_path: NodePath = hand_data["fallback_pose_path"]
    if fallback_path.is_empty():
        return false

    var fallback_node := get_node_or_null(fallback_path) as Node3D
    if fallback_node == null:
        return false

    var controller := fallback_node as XRController3D
    if controller != null and (not controller.get_is_active() or not controller.get_has_tracking_data()):
        return false

    var anchor = _joint_anchor_position(joint_positions, joint_valid)
    if anchor == null:
        return false

    var fallback_pose := global_transform.affine_inverse() * fallback_node.global_transform
    return (anchor as Vector3).distance_to(fallback_pose.origin) > stale_joint_pose_max_distance

func _joint_anchor_position(joint_positions: Dictionary, joint_valid: Dictionary):
    var palm := XRHandTracker.HAND_JOINT_PALM
    if bool(joint_valid.get(palm, false)):
        return joint_positions[palm]

    var wrist := XRHandTracker.HAND_JOINT_WRIST
    if bool(joint_valid.get(wrist, false)):
        return joint_positions[wrist]

    var index_tip := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
    if bool(joint_valid.get(index_tip, false)):
        return joint_positions[index_tip]

    return null

func _update_fallback_hand(hand_data: Dictionary, reason: String) -> bool:
    var hand_name: String = hand_data["label"]
    var root := hand_data["root"] as Node3D
    var fallback_path: NodePath = hand_data["fallback_pose_path"]
    if fallback_path.is_empty():
        return false

    var fallback_node := get_node_or_null(fallback_path) as Node3D
    if fallback_node == null:
        _last_hand_debug[hand_name] = "%s fallback=missing" % reason
        return false

    var controller := fallback_node as XRController3D
    if controller != null and (not controller.get_is_active() or not controller.get_has_tracking_data()):
        _last_hand_debug[hand_name] = "%s fallback_wait active=%s tracking=%s" % [
            reason,
            str(controller.get_is_active()),
            str(controller.get_has_tracking_data()),
        ]
        return false

    var hand_id: int = hand_data["hand"]
    var fallback_pose := global_transform.affine_inverse() * fallback_node.global_transform
    var joint_positions := {}
    var joint_valid := {}
    var joint_nodes := hand_data["joints"] as Dictionary

    for joint_id in HAND_JOINTS:
        var offset := _fallback_joint_offset(hand_id, joint_id)
        var joint_position := fallback_pose * offset
        var radius := joint_radius_min
        joint_positions[joint_id] = joint_position
        joint_valid[joint_id] = true

        var joint_node := joint_nodes[joint_id] as MeshInstance3D
        joint_node.visible = true
        joint_node.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * radius), joint_position)

    _last_hand_debug[hand_name] = "%s fallback=%s" % [reason, fallback_node.name]
    root.visible = true
    _update_bones(hand_data["bones"], joint_positions, joint_valid)
    _update_pinch_materials(hand_data, joint_positions, joint_valid)
    return true

func _fallback_joint_offset(hand_id: int, joint_id: int) -> Vector3:
    var side := 1.0 if hand_id == XRInputAdapter.Hand.RIGHT else -1.0
    match joint_id:
        XRHandTracker.HAND_JOINT_WRIST:
            return Vector3(0.0, -0.035, 0.025)
        XRHandTracker.HAND_JOINT_PALM:
            return Vector3(0.0, -0.01, -0.035)
        XRHandTracker.HAND_JOINT_THUMB_METACARPAL:
            return Vector3(side * 0.025, -0.01, -0.045)
        XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL:
            return Vector3(side * 0.052, -0.006, -0.06)
        XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL:
            return Vector3(side * 0.073, -0.002, -0.078)
        XRHandTracker.HAND_JOINT_THUMB_TIP:
            return Vector3(side * 0.09, 0.002, -0.095)
        XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL:
            return Vector3(side * 0.027, 0.0, -0.055)
        XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL:
            return Vector3(side * 0.032, 0.004, -0.09)
        XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE:
            return Vector3(side * 0.034, 0.006, -0.12)
        XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL:
            return Vector3(side * 0.035, 0.007, -0.145)
        XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP:
            return Vector3(side * 0.036, 0.008, -0.165)
        XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL:
            return Vector3(side * 0.006, 0.003, -0.058)
        XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL:
            return Vector3(side * 0.006, 0.007, -0.096)
        XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE:
            return Vector3(side * 0.006, 0.009, -0.13)
        XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL:
            return Vector3(side * 0.006, 0.01, -0.158)
        XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP:
            return Vector3(side * 0.006, 0.011, -0.18)
        XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL:
            return Vector3(side * -0.016, 0.0, -0.056)
        XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL:
            return Vector3(side * -0.018, 0.003, -0.09)
        XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE:
            return Vector3(side * -0.02, 0.004, -0.12)
        XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL:
            return Vector3(side * -0.021, 0.005, -0.145)
        XRHandTracker.HAND_JOINT_RING_FINGER_TIP:
            return Vector3(side * -0.022, 0.006, -0.164)
        XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL:
            return Vector3(side * -0.038, -0.005, -0.05)
        XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL:
            return Vector3(side * -0.045, -0.003, -0.08)
        XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE:
            return Vector3(side * -0.049, -0.002, -0.105)
        XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL:
            return Vector3(side * -0.052, -0.001, -0.126)
        XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP:
            return Vector3(side * -0.054, 0.0, -0.142)
    return Vector3.ZERO

func _update_bones(bone_nodes: Array[MeshInstance3D], joint_positions: Dictionary, joint_valid: Dictionary) -> void:
    for bone_index in range(BONE_PAIRS.size()):
        var bone_node := bone_nodes[bone_index]
        var pair: Array = BONE_PAIRS[bone_index]
        var from_joint: int = pair[0]
        var to_joint: int = pair[1]
        var visible := bool(joint_valid.get(from_joint, false)) and bool(joint_valid.get(to_joint, false))
        bone_node.visible = visible
        if not visible:
            continue

        var from_position: Vector3 = joint_positions[from_joint]
        var to_position: Vector3 = joint_positions[to_joint]
        var delta := to_position - from_position
        var length := delta.length()
        if length < 0.001:
            bone_node.visible = false
            continue

        var basis := bone_basis(from_position, to_position, bone_radius)
        bone_node.transform = Transform3D(basis, from_position + delta * 0.5)

func _update_pinch_materials(hand_data: Dictionary, joint_positions: Dictionary, joint_valid: Dictionary) -> void:
    var thumb_tip := XRHandTracker.HAND_JOINT_THUMB_TIP
    var index_tip := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
    var is_pinching := bool(joint_valid.get(thumb_tip, false)) and bool(joint_valid.get(index_tip, false))

    if is_pinching:
        var thumb_position: Vector3 = joint_positions[thumb_tip]
        var index_position: Vector3 = joint_positions[index_tip]
        var distance := thumb_position.distance_to(index_position)
        is_pinching = distance <= pinch_threshold

    var joint_nodes := hand_data["joints"] as Dictionary
    var material: Material = hand_data["pinch_material"] if is_pinching else hand_data["material"]
    (joint_nodes[thumb_tip] as MeshInstance3D).set_surface_override_material(0, material)
    (joint_nodes[index_tip] as MeshInstance3D).set_surface_override_material(0, material)

## Orthonormal basis whose local +Y points along `direction`. Roll about Y is
## arbitrary (chosen from a stable helper axis); irrelevant for a radially
## symmetric bone cylinder.
static func _basis_from_y_axis(direction: Vector3) -> Basis:
    var y_axis := direction.normalized()
    var helper := Vector3.UP
    if absf(y_axis.dot(helper)) > 0.95:
        helper = Vector3.FORWARD

    var x_axis := helper.cross(y_axis).normalized()
    var z_axis := x_axis.cross(y_axis).normalized()
    return Basis(x_axis, y_axis, z_axis)

## Bone transform basis: local +Y spans from->to at full bone length, X/Z carry
## the radius. Scaling is baked into the columns (B * S = LOCAL-frame scale), so
## the cylinder stays rigid. Using Basis.scaled() here would scale in the PARENT
## frame (S * B) and shear the bone whenever it is not axis-aligned.
static func bone_basis(from_position: Vector3, to_position: Vector3, radius: float) -> Basis:
    var delta := to_position - from_position
    var length := delta.length()
    if length < 0.00001:
        return Basis(Vector3(radius, 0, 0), Vector3.ZERO, Vector3(0, 0, radius))
    var axes := _basis_from_y_axis(delta)
    return Basis(axes.x * radius, axes.y * length, axes.z * radius)

func _set_status(message: String) -> void:
    if _status_label:
        _status_label.text = message
    if _world_status_label:
        _world_status_label.text = _format_world_status(message)
    print(message)

func _format_world_status(message: String) -> String:
    var prefix := "Hand tracking: "
    if not message.begins_with(prefix):
        return message

    var body := message.trim_suffix(".").substr(prefix.length())
    var parts := body.split(" | ", false)
    if parts.size() <= 1:
        return message

    var lines: Array[String] = ["Hand tracking: %s" % parts[0]]
    for index in range(1, parts.size()):
        lines.append(parts[index])
    return "\n".join(lines)

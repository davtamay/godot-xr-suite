class_name XRMicrogestureLocomotion
extends Node3D

## Provider-agnostic locomotion consumer. Any source that emits
## gesture_performed(type, hand, confidence) using XRMicrogestureSource can
## drive it, including joint, native-runtime, replay, and simulated sources.

signal locomotion_action(action: StringName, confidence: float)
signal teleport_targeting_changed(active: bool, target: Vector3)

@export var gesture_source_path: NodePath
@export var thumb_pose_source_path: NodePath
@export var gesture_runtime_path: NodePath
@export var xr_origin_path: NodePath
@export var camera_path: NodePath
@export_range(15.0, 90.0, 1.0) var snap_turn_degrees := 45.0
@export_range(1.0, 12.0, 0.5) var targeting_timeout := 8.0
## How long the aim survives after thumb-UP ends, waiting for the DOWN
## commit. The worst-case commit chain is the recognizer's post-UP cooldown
## (0.20) + the smoothed transit through the +-direction dead band (~0.1) +
## activation_time (0.06) ~= 0.36 s; the old 0.20 lost that race routinely,
## measured on device as "thumb down doesn't work 100%". Cost of the larger
## value: an aborted aim lingers ~a quarter second longer before clearing.
@export_range(0.0, 1.0, 0.01) var pose_release_grace := 0.45
@export var use_hand_aim := true
@export_range(0.01, 1.0, 0.01) var hand_aim_smoothing := 0.22
@export_range(1.0, 20.0, 0.25) var projectile_speed := 10.5
@export_range(1.0, 20.0, 0.25) var projectile_gravity := 9.8
@export_range(0.25, 4.0, 0.05) var projectile_maximum_time := 2.5
@export_range(8, 96, 1) var projectile_samples := 40
@export_flags_3d_physics var teleport_collision_mask := 1
@export_range(0.0, 1.0, 0.05) var minimum_surface_up := 0.55
@export var floor_height := 0.0
@export var teleport_enabled := true
@export var snap_turn_enabled := true
@export_enum("Any:-1", "Left:0", "Right:1") var hand_filter := -1

var _origin: XROrigin3D
var _camera: XRCamera3D
var _runtime: XRGestureRuntime
var _targeting := false
var _targeting_left := 0.0
var _target_position := Vector3.ZERO
var _target_valid := false
var _indicator: MeshInstance3D
var _arc_points: Array[MeshInstance3D] = []
var _active_hand := 1
var _pose_owned_targeting := false
var _pose_release_left := -1.0
var _smoothed_aim_direction := Vector3.ZERO

func _ready() -> void:
    _origin = get_node_or_null(xr_origin_path) as XROrigin3D
    _camera = get_node_or_null(camera_path) as XRCamera3D
    _runtime = get_node_or_null(gesture_runtime_path) as XRGestureRuntime
    var gesture_source := get_node_or_null(gesture_source_path)
    if gesture_source != null and gesture_source.has_signal("gesture_performed"):
        gesture_source.connect("gesture_performed", _on_gesture_performed)
    elif gesture_source != null and gesture_source.has_signal("microgesture_performed"):
        # Compatibility with sources predating XRMicrogestureSource.
        gesture_source.connect("microgesture_performed", _on_gesture_performed)
    var pose_source := get_node_or_null(thumb_pose_source_path)
    if pose_source != null and pose_source.has_signal("pose_performed"):
        pose_source.connect("pose_performed", _on_thumb_pose_performed)
    if pose_source != null and pose_source.has_signal("pose_candidate"):
        pose_source.connect("pose_candidate", _on_thumb_pose_candidate)
    if pose_source != null and pose_source.has_signal("pose_ended"):
        pose_source.connect("pose_ended", _on_thumb_pose_ended)
    _build_teleport_visuals()

func _process(delta: float) -> void:
    if not _targeting:
        return
    if _pose_owned_targeting and _pose_release_left >= 0.0:
        _pose_release_left -= delta
        if _pose_release_left <= 0.0:
            cancel_teleport()
            return
    _targeting_left -= delta
    if _targeting_left <= 0.0:
        cancel_teleport()
        return
    _update_target()

func begin_teleport(confidence := 1.0, require_pose_hold := false) -> void:
    if not teleport_enabled or _origin == null or _camera == null:
        return
    _targeting = true
    _pose_owned_targeting = require_pose_hold
    _pose_release_left = -1.0
    _smoothed_aim_direction = Vector3.ZERO
    _targeting_left = targeting_timeout
    _set_target_visuals(true)
    _update_target()
    teleport_targeting_changed.emit(true, _target_position)
    locomotion_action.emit(&"teleport_aim", confidence)

func commit_teleport(confidence := 1.0) -> void:
    if not _targeting or not _target_valid or _origin == null or _camera == null:
        return
    var head_floor := Vector3(_camera.global_position.x, floor_height, _camera.global_position.z)
    var offset := _target_position - head_floor
    offset.y = 0.0
    _origin.global_position += offset
    _targeting = false
    _pose_owned_targeting = false
    _pose_release_left = -1.0
    _set_target_visuals(false)
    teleport_targeting_changed.emit(false, _target_position)
    locomotion_action.emit(&"teleport_commit", confidence)

func cancel_teleport() -> void:
    if not _targeting:
        return
    _targeting = false
    _pose_owned_targeting = false
    _pose_release_left = -1.0
    _set_target_visuals(false)
    teleport_targeting_changed.emit(false, _target_position)
    locomotion_action.emit(&"teleport_cancel", 1.0)

func snap_turn(left: bool, confidence := 1.0) -> void:
    if not snap_turn_enabled or _origin == null or _camera == null:
        return
    if _targeting:
        cancel_teleport()
    var pivot_before := _camera.global_position
    var angle := deg_to_rad(snap_turn_degrees) * (1.0 if left else -1.0)
    _origin.rotate_y(angle)
    _origin.global_position += pivot_before - _camera.global_position
    locomotion_action.emit(&"snap_left" if left else &"snap_right", confidence)

func _on_gesture_performed(gesture: int, hand: int, confidence: float) -> void:
    if hand_filter >= 0 and hand != hand_filter:
        return
    if _active_hand != hand:
        _smoothed_aim_direction = Vector3.ZERO
    _active_hand = hand
    match gesture:
        XRMicrogestureSource.Gesture.LEFT:
            snap_turn(true, confidence)
        XRMicrogestureSource.Gesture.RIGHT:
            snap_turn(false, confidence)
        XRMicrogestureSource.Gesture.FORWARD:
            begin_teleport(confidence)
        XRMicrogestureSource.Gesture.BACKWARD:
            commit_teleport(confidence)
        XRMicrogestureSource.Gesture.TAP:
            if _targeting:
                commit_teleport(confidence)
            else:
                begin_teleport(confidence)

func _on_thumb_pose_performed(pose: int, hand: int, confidence: float) -> void:
    if hand_filter >= 0 and hand != hand_filter:
        return
    if _active_hand != hand:
        _smoothed_aim_direction = Vector3.ZERO
    _active_hand = hand
    if pose == 0:
        begin_teleport(confidence, true)
    else:
        commit_teleport(confidence)

func _on_thumb_pose_candidate(_pose: int, hand: int, _progress: float) -> void:
    if hand_filter >= 0 and hand != hand_filter:
        return
    if _targeting and _pose_owned_targeting and hand == _active_hand:
        _pose_release_left = -1.0

func _on_thumb_pose_ended(_pose: int, hand: int) -> void:
    if _targeting and _pose_owned_targeting and hand == _active_hand:
        _pose_release_left = pose_release_grace

func _update_target() -> void:
    var ray_origin := _active_hand_start() if use_hand_aim else _camera.global_position
    var forward := _active_hand_direction() if use_hand_aim else -_camera.global_basis.z.normalized()
    var trajectory := XRHandTeleportTrajectory.solve(
        ray_origin,
        forward,
        get_world_3d().direct_space_state,
        floor_height,
        projectile_speed,
        projectile_gravity,
        projectile_maximum_time,
        projectile_samples,
        teleport_collision_mask,
        minimum_surface_up
    )
    _target_valid = bool(trajectory["valid"])
    _target_position = Vector3(trajectory["target"])
    _indicator.global_position = _target_position
    _indicator.global_basis = Basis(Quaternion(Vector3.UP, Vector3(trajectory["normal"])))
    _indicator.visible = _targeting and _target_valid
    _show_trajectory(trajectory["points"])

func _show_trajectory(points: PackedVector3Array) -> void:
    if points.size() < 2:
        for point in _arc_points:
            point.visible = false
        return
    for index in range(_arc_points.size()):
        var fraction := float(index + 1) / float(_arc_points.size())
        var sample := mini(int(round(fraction * float(points.size() - 1))), points.size() - 1)
        _arc_points[index].global_position = points[sample]
        _arc_points[index].visible = _targeting

func _active_hand_start() -> Vector3:
    if _runtime != null:
        var features := _runtime.get_features(_active_hand)
        if features != null and features.valid:
            return _origin.global_transform * features.palm_transform.origin
    var side := -1.0 if _active_hand == 0 else 1.0
    return _camera.global_position + _camera.global_basis.x * (0.22 * side) - _camera.global_basis.y * 0.18

func _active_hand_direction() -> Vector3:
    var raw_direction := -_camera.global_basis.z.normalized()
    if _runtime != null:
        var features := _runtime.get_features(_active_hand)
        if features != null and features.valid:
            # Palm basis Z is wrist-to-middle-knuckle: the forward axis of a
            # thumbs-up fist and independent of runtime/vendor aim poses.
            raw_direction = (_origin.global_basis * features.palm_transform.basis.z).normalized()
    if _smoothed_aim_direction.is_zero_approx():
        _smoothed_aim_direction = raw_direction
    else:
        _smoothed_aim_direction = _smoothed_aim_direction.slerp(raw_direction, hand_aim_smoothing).normalized()
    return _smoothed_aim_direction

func _build_teleport_visuals() -> void:
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = Color(0.25, 1.0, 0.62, 1.0)
    material.emission_enabled = true
    material.emission = material.albedo_color
    material.emission_energy_multiplier = 2.0

    var ring_mesh := TorusMesh.new()
    ring_mesh.inner_radius = 0.22
    ring_mesh.outer_radius = 0.29
    ring_mesh.rings = 28
    ring_mesh.ring_segments = 12
    _indicator = MeshInstance3D.new()
    _indicator.name = "TeleportIndicator"
    _indicator.mesh = ring_mesh
    _indicator.set_surface_override_material(0, material)
    _indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _indicator.visible = false
    add_child(_indicator)

    var dot_mesh := SphereMesh.new()
    dot_mesh.radius = 0.018
    dot_mesh.height = 0.036
    dot_mesh.radial_segments = 10
    dot_mesh.rings = 5
    for index in range(18):
        var point := MeshInstance3D.new()
        point.name = "TeleportArc%02d" % index
        point.mesh = dot_mesh
        point.set_surface_override_material(0, material)
        point.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        point.visible = false
        add_child(point)
        _arc_points.append(point)

func _set_target_visuals(visible: bool) -> void:
    if _indicator != null:
        _indicator.visible = visible
    for point in _arc_points:
        point.visible = visible

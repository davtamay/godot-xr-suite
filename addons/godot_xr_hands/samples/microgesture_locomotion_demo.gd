extends Node3D

## Demonstrates action binding, not recognition policy: the reusable thumb
## recognizer emits directions and this scene chooses locomotion responses.

const WEBXR_BOOTSTRAP := "res://addons/godot_webxr_kit/runtime/webxr_bootstrap.gd"
const SHOWCASE_MATERIAL := preload("res://addons/godot_xr_hands/runtime/showcase_material.tres")
const TELEPORT_COLOR := Color(0.25, 1.0, 0.62, 1.0)
const TURN_COLOR := Color(1.0, 0.72, 0.15, 1.0)

@export_range(15.0, 90.0, 1.0) var snap_turn_degrees := 45.0
@export_range(1.0, 12.0, 0.5) var targeting_timeout := 8.0
## See XRMicrogestureLocomotion.pose_release_grace: must outlast the
## recognizer's post-UP cooldown + dead-band transit + activation (~0.36 s
## worst case) or the DOWN commit races a cancelled aim.
@export_range(0.0, 1.0, 0.01) var pose_release_grace := 0.45
@export var use_hand_aim := true
@export_range(0.01, 1.0, 0.01) var hand_aim_smoothing := 0.22
@export_range(1.0, 20.0, 0.25) var projectile_speed := 10.5
@export_range(1.0, 20.0, 0.25) var projectile_gravity := 9.8
@export_range(0.25, 4.0, 0.05) var projectile_maximum_time := 2.5
@export_range(8, 96, 1) var projectile_samples := 40
@export_flags_3d_physics var teleport_collision_mask := 1
@export_range(0.0, 1.0, 0.05) var minimum_surface_up := 0.55

@onready var _origin: XROrigin3D = $XROrigin3D
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var _runtime: XRGestureRuntime = $GestureRuntime
@onready var _microgestures: XRThumbMicrogestureRecognizer = $ThumbMicrogestures
@onready var _thumb_poses: XRThumbPoseRecognizer = $ThumbPoses
@onready var _status: Label = %StatusLabel
@onready var _world_status: Label3D = $WorldStatus

var _targeting := false
var _target_position := Vector3.ZERO
var _target_valid := false
var _targeting_left := 0.0
var _indicator: MeshInstance3D
var _arc_points: Array[MeshInstance3D] = []
var _last_action := "Thumb TAP to aim teleport, then TAP again to commit"
var _active_hand := 1
var _pose_owned_targeting := false
var _pose_release_left := -1.0
var _smoothed_aim_direction := Vector3.ZERO

func _ready() -> void:
    _build_locomotion_visuals()
    _build_landmarks()
    _microgestures.gesture_candidate.connect(_on_microgesture_candidate)
    _microgestures.gesture_performed.connect(_on_microgesture_performed)
    _thumb_poses.pose_candidate.connect(_on_thumb_pose_candidate)
    _thumb_poses.pose_performed.connect(_on_thumb_pose_performed)
    _thumb_poses.pose_ended.connect(_on_thumb_pose_ended)
    _install_optional_webxr_bootstrap()
    _update_status()
    const MENU_BUTTON := "res://scripts/back_to_menu_button.gd"
    if ResourceLoader.exists(MENU_BUTTON):
        var menu_button = load(MENU_BUTTON)
        if menu_button:
            add_child(menu_button.new())

func _process(delta: float) -> void:
    if _targeting:
        if _pose_owned_targeting and _pose_release_left >= 0.0:
            _pose_release_left -= delta
            if _pose_release_left <= 0.0:
                _cancel_targeting("Teleport aim cancelled: thumb pose released")
                _update_status()
                return
        _targeting_left -= delta
        if _targeting_left <= 0.0:
            _cancel_targeting("Teleport aim timed out")
        else:
            _update_target()
    _update_status()

func _unhandled_key_input(event: InputEvent) -> void:
    var key_event := event as InputEventKey
    if key_event == null or get_viewport().use_xr or not key_event.pressed or key_event.echo:
        return
    match key_event.keycode:
        KEY_SPACE:
            _invoke_direction(XRMicrogestureSource.Gesture.TAP, 1.0)
        KEY_UP:
            _invoke_direction(XRMicrogestureSource.Gesture.FORWARD, 1.0)
        KEY_DOWN:
            _invoke_direction(XRMicrogestureSource.Gesture.BACKWARD, 1.0)
        KEY_LEFT:
            _invoke_direction(XRMicrogestureSource.Gesture.LEFT, 1.0)
        KEY_RIGHT:
            _invoke_direction(XRMicrogestureSource.Gesture.RIGHT, 1.0)

func _on_microgesture_candidate(direction: int, hand: int, progress: float) -> void:
    if not _targeting:
        _active_hand = hand
    _last_action = "Thumb swipe %s  %.0f%%" % [_microgestures.direction_name(direction), progress * 100.0]

func _on_microgesture_performed(direction: int, hand: int, confidence: float) -> void:
    if _active_hand != hand:
        _smoothed_aim_direction = Vector3.ZERO
    _active_hand = hand
    _invoke_direction(direction, confidence)

func _on_thumb_pose_candidate(pose: int, hand: int, progress: float) -> void:
    if not _targeting:
        _active_hand = hand
    if _targeting and _pose_owned_targeting and hand == _active_hand:
        _pose_release_left = -1.0
    _last_action = "Fist + thumb %s  %.0f%%" % [_thumb_poses.pose_name(pose), progress * 100.0]

func _on_thumb_pose_performed(pose: int, hand: int, confidence: float) -> void:
    if _active_hand != hand:
        _smoothed_aim_direction = Vector3.ZERO
    _active_hand = hand
    if pose == XRThumbPoseRecognizer.Pose.UP:
        _begin_targeting(confidence, true)
    else:
        _commit_teleport(confidence)

func _on_thumb_pose_ended(_pose: int, hand: int) -> void:
    if _targeting and _pose_owned_targeting and hand == _active_hand:
        _pose_release_left = pose_release_grace

func _invoke_direction(direction: int, confidence: float) -> void:
    match direction:
        XRMicrogestureSource.Gesture.TAP:
            if _targeting:
                _commit_teleport(confidence)
            else:
                _begin_targeting(confidence)
        XRMicrogestureSource.Gesture.FORWARD:
            _begin_targeting(confidence)
        XRMicrogestureSource.Gesture.BACKWARD:
            _commit_teleport(confidence)
        XRMicrogestureSource.Gesture.LEFT:
            _snap_turn(true, confidence)
        XRMicrogestureSource.Gesture.RIGHT:
            _snap_turn(false, confidence)

func _begin_targeting(confidence: float, require_pose_hold := false) -> void:
    _targeting = true
    _pose_owned_targeting = require_pose_hold
    _pose_release_left = -1.0
    _smoothed_aim_direction = Vector3.ZERO
    _targeting_left = targeting_timeout
    _indicator.visible = true
    for point in _arc_points:
        point.visible = true
    _update_target()
    _last_action = "TELEPORT AIM active  •  keep pose or turn thumb DOWN to commit  •  %.0f%%" % (confidence * 100.0)

func _commit_teleport(confidence: float) -> void:
    if not _targeting:
        _last_action = "Thumb UP first to choose a teleport destination"
        return
    if not _target_valid:
        _last_action = "No valid teleport surface under the hand arc"
        return
    var head_floor := Vector3(_camera.global_position.x, 0.0, _camera.global_position.z)
    var delta := _target_position - head_floor
    delta.y = 0.0
    _origin.global_position += delta
    _targeting = false
    _pose_owned_targeting = false
    _pose_release_left = -1.0
    _set_target_visuals(false)
    _last_action = "TELEPORTED  •  %.1f m  •  %.0f%%" % [delta.length(), confidence * 100.0]

func _cancel_targeting(message: String) -> void:
    _targeting = false
    _pose_owned_targeting = false
    _pose_release_left = -1.0
    _set_target_visuals(false)
    _last_action = message

func _snap_turn(left: bool, confidence: float) -> void:
    if _targeting:
        _cancel_targeting("Teleport cancelled by snap turn")
    var pivot_before := _camera.global_position
    var angle := deg_to_rad(snap_turn_degrees) * (1.0 if left else -1.0)
    _origin.rotate_y(angle)
    _origin.global_position += pivot_before - _camera.global_position
    _last_action = "SNAP %s  •  %.0f°  •  %.0f%%" % ["LEFT" if left else "RIGHT", snap_turn_degrees, confidence * 100.0]
    _pulse_turn(left)

func _update_target() -> void:
    var ray_origin := _active_hand_start() if use_hand_aim else _camera.global_position
    var forward := _active_hand_direction() if use_hand_aim else -_camera.global_basis.z.normalized()
    var trajectory := XRHandTeleportTrajectory.solve(
        ray_origin,
        forward,
        get_world_3d().direct_space_state,
        0.0,
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
    var features := _runtime.get_features(_active_hand)
    if features != null and features.valid:
        return _origin.global_transform * features.palm_transform.origin
    var side := -1.0 if _active_hand == 0 else 1.0
    return _camera.global_position + _camera.global_basis.x * (0.22 * side) - _camera.global_basis.y * 0.18

func _active_hand_direction() -> Vector3:
    var raw_direction := -_camera.global_basis.z.normalized()
    var features := _runtime.get_features(_active_hand)
    if features != null and features.valid:
        raw_direction = (_origin.global_basis * features.palm_transform.basis.z).normalized()
    if _smoothed_aim_direction.is_zero_approx():
        _smoothed_aim_direction = raw_direction
    else:
        _smoothed_aim_direction = _smoothed_aim_direction.slerp(raw_direction, hand_aim_smoothing).normalized()
    return _smoothed_aim_direction

func _build_locomotion_visuals() -> void:
    var ring_mesh := TorusMesh.new()
    ring_mesh.inner_radius = 0.22
    ring_mesh.outer_radius = 0.29
    ring_mesh.rings = 28
    ring_mesh.ring_segments = 12
    _indicator = MeshInstance3D.new()
    _indicator.name = "TeleportIndicator"
    _indicator.mesh = ring_mesh
    # TorusMesh is generated in the XZ plane, so its default orientation lies
    # flat on a horizontal teleport surface.
    _indicator.rotation_degrees = Vector3.ZERO
    _indicator.set_surface_override_material(0, _material(TELEPORT_COLOR))
    _indicator.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _indicator.visible = false
    add_child(_indicator)

    var dot_mesh := SphereMesh.new()
    dot_mesh.radius = 0.018
    dot_mesh.height = 0.036
    dot_mesh.radial_segments = 10
    dot_mesh.rings = 5
    var shared_material := _material(TELEPORT_COLOR)
    for index in range(18):
        var point := MeshInstance3D.new()
        point.name = "Arc%02d" % index
        point.mesh = dot_mesh
        point.set_surface_override_material(0, shared_material)
        point.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        point.visible = false
        add_child(point)
        _arc_points.append(point)

func _build_landmarks() -> void:
    var colors := [Color(0.18, 0.72, 1.0), Color(1.0, 0.35, 0.2), Color(0.5, 1.0, 0.35)]
    for z in range(3):
        for x in range(-2, 3):
            var mesh := BoxMesh.new()
            mesh.size = Vector3(0.18, 0.5 + float((x + z + 6) % 3) * 0.22, 0.18)
            var landmark := MeshInstance3D.new()
            landmark.mesh = mesh
            landmark.position = Vector3(float(x) * 1.35, mesh.size.y * 0.5, -2.5 - float(z) * 2.0)
            landmark.set_surface_override_material(0, _material(colors[(x + z + 6) % colors.size()]))
            add_child(landmark)

func _pulse_turn(left: bool) -> void:
    var flash := Label3D.new()
    flash.text = "↶" if left else "↷"
    flash.font_size = 128
    flash.pixel_size = 0.003
    flash.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    flash.modulate = TURN_COLOR
    flash.global_position = _camera.global_position + (-_camera.global_basis.z * 1.4)
    add_child(flash)
    var tween := create_tween()
    tween.tween_property(flash, "scale", Vector3.ONE * 1.8, 0.28).set_trans(Tween.TRANS_BACK)
    tween.tween_callback(flash.queue_free)

func _material(color: Color) -> StandardMaterial3D:
    var material := SHOWCASE_MATERIAL.duplicate() as StandardMaterial3D
    material.albedo_color = color
    material.emission = color
    material.emission_energy_multiplier = 2.2
    return material

func _set_target_visuals(visible: bool) -> void:
    _indicator.visible = visible
    for point in _arc_points:
        point.visible = visible

func _update_status() -> void:
    var mode := "READY"
    if _targeting:
        var planar_target := Vector2(_target_position.x - _camera.global_position.x, _target_position.z - _camera.global_position.z).length()
        mode = "AIMING %.1fs  •  %.1fm" % [_targeting_left, planar_target] if _target_valid else "AIMING  •  NO VALID SURFACE"
    var diagnostics := "Waiting for hand tracking (head-aim fallback)"
    var features := _runtime.get_features(_active_hand)
    if features != null and features.valid:
        var fist_curl := 0.0
        for finger in range(XRHandFeatures.Finger.INDEX, XRHandFeatures.Finger.PINKY + 1):
            fist_curl += features.finger_curls[finger]
        fist_curl /= 4.0
        diagnostics = "%s HAND AIM  fist %.2f  thumb-up %+.2f  side %.2f  index %.2f  pinch %.2f" % [
            "L" if _active_hand == 0 else "R",
            fist_curl,
            features.thumb_direction_origin.y,
            features.thumb_index_side_distance,
            features.thumb_index_contact_position,
            features.pinch_distance,
        ]
    var text := "MICROGESTURE LOCOMOTION  •  %s\n%s\nFIST+THUMB UP aim  •  THUMB DOWN teleport  •  FIST+SWIPE LEFT/RIGHT snap %.0f°\n%s\nDesktop preview: Space + arrow keys" % [mode, _last_action, snap_turn_degrees, diagnostics]
    _status.text = text
    _world_status.text = text

func _install_optional_webxr_bootstrap() -> void:
    if not ResourceLoader.exists(WEBXR_BOOTSTRAP):
        %EnterVRButton.disabled = true
        %EnterARButton.disabled = true
        return
    var script = load(WEBXR_BOOTSTRAP)
    if script == null:
        return
    var bootstrap = script.new()
    bootstrap.name = "WebXRBootstrap"
    bootstrap.enter_vr_button_path = NodePath("../CanvasLayer/Panel/Margin/VBox/Buttons/EnterVRButton")
    bootstrap.enter_ar_button_path = NodePath("../CanvasLayer/Panel/Margin/VBox/Buttons/EnterARButton")
    bootstrap.status_label_path = NodePath("../CanvasLayer/Panel/Margin/VBox/StatusLabel")
    bootstrap.world_environment_path = NodePath("../WorldEnvironment")
    add_child(bootstrap)

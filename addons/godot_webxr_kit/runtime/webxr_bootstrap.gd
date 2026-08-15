@icon("res://addons/godot_webxr_kit/icons/webxr_bootstrap.svg")
class_name WebXRBootstrap
extends Node3D

## Minimal WebXR startup flow.
## Attach to a Node3D in the demo scene and wire VR/AR Buttons plus optional status Label.
## This intentionally uses Godot's WebXRInterface, not custom WebGPU rendering.

## Session lifecycle for game logic - connect instead of polling use_xr.
## mode is "immersive-vr" or "immersive-ar".
signal session_started(mode: String)
signal session_ended
signal session_failed(message: String)

## Runtime-configurable master switch. This node is always inert in native
## builds, even when enabled, so it is safe to ship beside OpenXRBootstrap.
@export var enabled := true

## The groups this bootstrap acts on, as constants so consumers never typo the
## magic strings (a misspelled group fails SILENTLY - e.g. a HUD outside
## GROUP_SESSION_HIDDEN renders into both eyes).
const GROUP_SESSION_HIDDEN := "xr_session_hidden"
const GROUP_AR_PASSTHROUGH_HIDDEN := "ar_passthrough_hidden"
## The inverse: nodes shown ONLY during AR passthrough (hidden everywhere
## else) - e.g. a translucent grid marking teleportable ground where the
## solid floor hides so the real floor shows through.
const GROUP_AR_PASSTHROUGH_ONLY := "ar_passthrough_only"
const GROUP_FEATURE_PROVIDER := "webxr_feature_provider"
const GROUP_SESSION_UI := "xr_session_ui"

## Legacy single-button path. If enter_vr_button_path is empty, this is used as the VR button.
@export var enter_xr_button_path: NodePath
@export var enter_vr_button_path: NodePath
@export var enter_ar_button_path: NodePath
@export var status_label_path: NodePath
@export var inspect_object_path: NodePath
@export var world_environment_path: NodePath
@export var enable_legacy_select_visuals := false
## When true, "hand-tracking" is a REQUIRED session feature and browsers or
## devices without it refuse the whole session (controller-only headsets,
## hands disabled in system settings). Off by default: hand tracking is then
## requested as an optional feature and still granted where available.
@export var require_hand_tracking := false
@export var ar_hide_group := GROUP_AR_PASSTHROUGH_HIDDEN
## Nodes in this group are hidden during ANY immersive session (VR or AR)
## and restored on exit. Put screen-space UI (CanvasLayer HUDs) here:
## Godot composites the 2D canvas into each eye's view otherwise.
@export var session_hide_group := GROUP_SESSION_HIDDEN
## Fixed foveation level requested from the browser compositor for the
## projection layer: 0.0 = off (full resolution everywhere), 1.0 = maximum
## (lowest resolution at the periphery, best performance). Rendering the
## periphery at reduced resolution is the single most effective perf lever on
## standalone headsets and costs the engine nothing - the compositor does it.
## Needs an engine build exposing WebXRInterface.set_fixed_foveation (the
## WebGPU fork does); silently skipped on stock Godot templates and on
## browsers without WebXR Layers fixed foveation.
@export_range(0.0, 1.0, 0.01) var fixed_foveation := 1.0
## Snap the camera back to the design forward when a session ends. XR leaves
## the camera at your last head orientation, which on the flat page can face
## you away from the scene and its UI. Turn off for apps that deliberately
## want to keep the last look direction.
@export var reset_view_on_exit := true
## Ask the browser to surface its own native "enter XR" prompt for this mode
## at page load ("" = off). Needs an engine whose WebXRInterface has
## offer_session() (the fork); silently skipped elsewhere, and the page
## buttons keep working everywhere as the fallback.
@export var offer_session_mode := ""

## Preloaded so the shader baker can precompile it for web/WebGPU exports.
const HIGHLIGHT_MATERIAL := preload("res://addons/godot_webxr_kit/runtime/highlight_material.tres")

var _webxr: XRInterface
var _vr_supported := false
var _ar_supported := false
var _vr_support_checked := false
var _ar_support_checked := false
var _vr_button: Button
var _ar_button: Button
var _status_label: Label
var _inspect_object: MeshInstance3D
var _world_environment: WorldEnvironment
var _select_count := 0
var _base_scale := Vector3.ONE
var _base_material: Material
var _highlight_material: StandardMaterial3D
var _last_session_failed := false
var _requested_session_mode := ""
var _active_session_mode := ""
var _base_transparent_bg := false
var _base_clear_color := Color.BLACK
var _base_environment_background_mode := -1
var _base_environment_background_color := Color.BLACK
var _ar_hidden_node_visibility := {}
var _session_hidden_node_visibility := {}

func _ready() -> void:
    # Check the platform before building browser entry UI or touching the
    # WebXR interface. Native exports carry this node but pay no runtime/UI
    # cost; OpenXRBootstrap exclusively owns their session.
    if not enabled or not OS.has_feature("web"):
        set_process(false)
        return

    _vr_button = get_node_or_null(enter_vr_button_path) as Button
    if _vr_button == null:
        _vr_button = get_node_or_null(enter_xr_button_path) as Button
    _ar_button = get_node_or_null(enter_ar_button_path) as Button
    _status_label = get_node_or_null(status_label_path) as Label
    _inspect_object = get_node_or_null(inspect_object_path) as MeshInstance3D
    _base_transparent_bg = get_viewport().transparent_bg
    _base_clear_color = RenderingServer.get_default_clear_color()
    # Deliberately NOT resolved here -- see _resolve_world_environment.
    _resolve_world_environment()

    # Zero-wiring paths, in order: adopt an XRSessionUI block if the scene has
    # one (the polished HUD, found by group - it joins in _enter_tree so it is
    # visible here regardless of ready order); else build the minimal default
    # UI so this bootstrap drops into any scene with no setup at all.
    if _vr_button == null and _ar_button == null:
        _adopt_session_ui()
    if _vr_button == null and _ar_button == null:
        _build_default_ui()

    if _vr_button:
        _vr_button.pressed.connect(_on_enter_vr_pressed)
        _vr_button.disabled = true
    else:
        _set_status("Enter VR button path is not assigned or does not point to a Button.")

    if _ar_button:
        _ar_button.pressed.connect(_on_enter_ar_pressed)
        _ar_button.disabled = true
    else:
        _set_status("Enter AR button path is not assigned or does not point to a Button.")

    if _inspect_object:
        _base_scale = _inspect_object.scale
        _base_material = _inspect_object.get_active_material(0)
        # Duplicate of a baked .tres; colors/energy are uniforms, so the
        # baked shader hash is kept.
        _highlight_material = HIGHLIGHT_MATERIAL.duplicate() as StandardMaterial3D
        _highlight_material.albedo_color = Color(0.25, 0.95, 0.68, 1.0)
        _highlight_material.emission = Color(0.25, 0.95, 0.68, 1.0)
        _highlight_material.emission_energy_multiplier = 1.2
    # No inspect object is fine - it is an optional legacy demo feature.

    _webxr = XRServer.find_interface("WebXR")
    if not _webxr:
        _set_status("WebXR interface not found.")
        return

    _webxr.session_supported.connect(_on_session_supported)
    _webxr.session_started.connect(_on_session_started)
    _webxr.session_ended.connect(_on_session_ended)
    _webxr.session_failed.connect(_on_session_failed)
    _connect_webxr_input_signal("select", _on_webxr_select)
    _connect_webxr_input_signal("selectstart", _on_webxr_select_start)
    _connect_webxr_input_signal("selectend", _on_webxr_select_end)

    # Scene routers can replace one XR scene with another without ending the
    # browser session. A bootstrap joining that hand-off has already missed
    # session_started, so adopt the active interface immediately and apply the
    # same viewport/UI state idempotently.
    if _webxr.is_initialized():
        _requested_session_mode = str(_webxr.session_mode)
        _on_session_started()
        return

    _set_status("Checking WebXR VR/AR support...")
    _webxr.is_session_supported("immersive-vr")
    _webxr.is_session_supported("immersive-ar")
    _maybe_offer_session()

func _on_session_supported(session_mode: String, supported: bool) -> void:
    match session_mode:
        "immersive-vr":
            _vr_supported = supported
            _vr_support_checked = true
            if _vr_button:
                _vr_button.disabled = not supported
        "immersive-ar":
            _ar_supported = supported
            _ar_support_checked = true
            if _ar_button:
                _ar_button.disabled = not supported
        _:
            return

    _set_status("WebXR support: VR %s, AR %s." % [_support_text(_vr_support_checked, _vr_supported), _support_text(_ar_support_checked, _ar_supported)])

func _on_enter_vr_pressed() -> void:
    _start_xr_session("immersive-vr")

func _on_enter_ar_pressed() -> void:
    _start_xr_session("immersive-ar")

func _start_xr_session(session_mode: String) -> void:
    if not _webxr:
        _set_status("WebXR interface missing.")
        return

    if session_mode == "immersive-vr" and not _vr_supported:
        _set_status("immersive-vr not supported.")
        return
    if session_mode == "immersive-ar" and not _ar_supported:
        _set_status("immersive-ar not supported.")
        return

    _requested_session_mode = session_mode
    _webxr.session_mode = session_mode
    _webxr.requested_reference_space_types = _reference_space_types_for(session_mode)
    _webxr.required_features = _required_features_for(session_mode)
    _webxr.optional_features = _optional_features_for(session_mode)

    _set_status("Requesting %s session..." % _session_label(session_mode))
    if not _webxr.initialize():
        _requested_session_mode = ""
        _set_status("WebXR initialize() returned false. Session was not requested.")

func _maybe_offer_session() -> void:
    if offer_session_mode.is_empty() or _webxr == null:
        return
    if not _webxr.has_method("offer_session") or not _webxr.has_signal("session_offer_accepted"):
        return
    _webxr.connect("session_offer_accepted", _on_session_offer_accepted)
    _webxr.session_mode = offer_session_mode
    _webxr.requested_reference_space_types = _reference_space_types_for(offer_session_mode)
    _webxr.required_features = _required_features_for(offer_session_mode)
    _webxr.optional_features = _optional_features_for(offer_session_mode)
    _webxr.offer_session()


func _on_session_offer_accepted() -> void:
    # The browser already granted the session with the user's consent;
    # initialize() consumes it, so the normal start path just works.
    _start_xr_session(offer_session_mode)


func _on_session_started() -> void:
    _last_session_failed = false
    _active_session_mode = _requested_session_mode
    if _active_session_mode.is_empty():
        _active_session_mode = _webxr.session_mode
    _apply_ar_scene_mode(_active_session_mode == "immersive-ar")
    _apply_session_hidden(true)
    if fixed_foveation > 0.0 and _webxr.has_method("set_fixed_foveation"):
        _webxr.set_fixed_foveation(fixed_foveation)
    get_viewport().use_xr = true
    _set_status("%s session started. Reference space: %s. Enabled features: %s." % [_session_label(_active_session_mode), _webxr.reference_space_type, _webxr.enabled_features])
    session_started.emit(_active_session_mode)

func _on_session_ended() -> void:
    get_viewport().use_xr = false
    # The root viewport only re-derives its size from the window inside
    # Window's private update, which runs on resize notifications - and on
    # web the window doesn't resize after session exit, so the viewport
    # stays stuck at the XR per-eye size (2D draws shrunken while input
    # maps to the real layout). Nudging the content scale factor forces
    # that update to run against the (correct) window size. Godot builds that
    # re-derive the size on Window::set_use_xr teardown make this redundant,
    # but it keeps the addon working on stock engines that lack that fix.
    var win := get_window()
    var scale_factor := win.content_scale_factor
    win.content_scale_factor = scale_factor * 1.000001 + 0.000001
    win.content_scale_factor = scale_factor
    if reset_view_on_exit:
        # XR leaves the camera at the last head orientation; on the flat
        # page that can face you away from the scene and its UI. Snap the
        # camera back to face the design forward (its parent/origin -Z).
        var cam := get_viewport().get_camera_3d()
        if cam:
            cam.rotation = Vector3.ZERO
    _apply_ar_scene_mode(false)
    _apply_session_hidden(false)
    _requested_session_mode = ""
    _active_session_mode = ""
    session_ended.emit()
    if _last_session_failed:
        return
    _set_status("WebXR session ended.")


func _on_session_failed(message: String) -> void:
    _last_session_failed = true
    get_viewport().use_xr = false
    _apply_ar_scene_mode(false)
    _apply_session_hidden(false)
    _requested_session_mode = ""
    _active_session_mode = ""
    _set_status("WEBXR FAILED: " + message)
    _show_browser_failure("WEBXR FAILED: " + message)
    session_failed.emit(message)

func _connect_webxr_input_signal(signal_name: StringName, callback: Callable) -> void:
    if not _webxr.has_signal(signal_name):
        _set_status("WebXR signal unavailable in this Godot build: " + str(signal_name))
        return

    if not _webxr.is_connected(signal_name, callback):
        _webxr.connect(signal_name, callback)

func _on_webxr_select(input_source_id: int) -> void:
    _select_count += 1
    if enable_legacy_select_visuals:
        _apply_select_visual_state()
        _set_status("XR select received: %d (input source %d)" % [_select_count, input_source_id])
    else:
        print_verbose("XR select received: %d (input source %d)" % [_select_count, input_source_id])

func _on_webxr_select_start(input_source_id: int) -> void:
    print_verbose("XR select started (input source %d)" % input_source_id)

func _on_webxr_select_end(input_source_id: int) -> void:
    print_verbose("XR select ended (input source %d)" % input_source_id)

func _apply_select_visual_state() -> void:
    if not _inspect_object:
        _set_status("XR select received but inspect object is unavailable.")
        return

    var highlighted := _select_count % 2 == 1
    _inspect_object.scale = _base_scale * (1.25 if highlighted else 1.0)
    _inspect_object.set_surface_override_material(0, _highlight_material if highlighted else _base_material)

func _set_status(message: String) -> void:
    if _status_label:
        _status_label.text = message
    print_verbose(message)

func _support_text(checked: bool, supported: bool) -> String:
    if not checked:
        return "checking"
    return "yes" if supported else "no"

func _session_label(session_mode: String) -> String:
    return "AR" if session_mode == "immersive-ar" else "VR"

func _reference_space_types_for(session_mode: String) -> String:
    if session_mode == "immersive-ar":
        return "local-floor, local"
    # local-floor first: its forward is where the user faces at session
    # start, so the scene spawns in front of them. bounded-floor anchors to
    # the room's calibrated (arbitrary) forward instead.
    return "local-floor, bounded-floor, local"

func _required_features_for(session_mode: String) -> String:
    # Deliberately NOT declaring the 'layers' feature: Godot only ever uses
    # a single projection layer, which Chromium serves without the
    # declaration - while DECLARING it makes Android XR spin up its full
    # multi-layer compositor at session start (a 2-3s head-locked system
    # transition; found by feature-set bisection on a Galaxy XR). Verified
    # working without it on Quest 3 (WebGL+WebGPU paths) and Galaxy XR.
    # Re-add (conditionally) only if quad/cylinder layers are ever used.
    var features: Array[String] = []
    if require_hand_tracking:
        features.append(WebXRFeatures.HAND_TRACKING)
    _merge_provider_features(features, &"get_webxr_required_features", session_mode)
    return ", ".join(features)

func _optional_features_for(session_mode: String) -> String:
    var features: Array[String] = [WebXRFeatures.LOCAL_FLOOR]
    if session_mode == WebXRFeatures.MODE_VR:
        features.append(WebXRFeatures.BOUNDED_FLOOR)
    if not require_hand_tracking:
        features.append(WebXRFeatures.HAND_TRACKING)
    # Feature-provider contract: nodes in the 'webxr_feature_provider' group
    # declare the session features they need (mesh bridge -> mesh-detection,
    # depth bridge/occluder -> depth-sensing), so a scene only requests what
    # it actually contains. Leaner requests enter immersive mode faster
    # (Android XR charges startup ceremony per feature family).
    _merge_provider_features(features, &"get_webxr_optional_features", session_mode)
    return ", ".join(features)

func _merge_provider_features(features: Array[String], method: StringName, session_mode: String) -> void:
    for node in get_tree().get_nodes_in_group(GROUP_FEATURE_PROVIDER):
        if not node.has_method(method):
            continue
        for f in node.call(method, session_mode):
            var feature := str(f)
            if not feature.is_empty() and not features.has(feature):
                features.append(feature)

## Resolved lazily and re-tried, never cached once at _ready. _ready runs during
## add_child, which is BEFORE the tree publishes current_scene -- and
## _find_world_environment searched exactly that. So the lookup returned null on
## every scene the router streams in, _apply_ar_scene_mode had nothing to clear,
## and the scene's opaque background painted straight over passthrough. On
## device (Quest 3, WebXR immersive-ar): AR mode entered, but no room, no floor.
func _resolve_world_environment() -> WorldEnvironment:
    if _world_environment != null and is_instance_valid(_world_environment):
        return _world_environment
    var found := get_node_or_null(world_environment_path) as WorldEnvironment
    if found == null:
        found = _find_world_environment()
    if found == null:
        return null
    _world_environment = found
    # Capture the restore values the first time we actually have them, not at
    # _ready -- restoring from a base that was never read would clear the
    # scene's real background when AR mode is left.
    if found.environment and _base_environment_background_mode < 0:
        _base_environment_background_mode = found.environment.background_mode
        _base_environment_background_color = found.environment.background_color
    return _world_environment

func _apply_ar_scene_mode(enabled: bool) -> void:
    get_viewport().transparent_bg = enabled if enabled else _base_transparent_bg
    RenderingServer.set_default_clear_color(Color(0, 0, 0, 0) if enabled else _base_clear_color)

    if _resolve_world_environment() and _world_environment.environment:
        if enabled:
            _world_environment.environment.background_mode = Environment.BG_CLEAR_COLOR
            _world_environment.environment.background_color = Color(0, 0, 0, 0)
        elif _base_environment_background_mode >= 0:
            _world_environment.environment.background_mode = _base_environment_background_mode
            _world_environment.environment.background_color = _base_environment_background_color

    for node in get_tree().get_nodes_in_group(ar_hide_group):
        if not (node is Node3D):
            continue

        var node_3d := node as Node3D
        if enabled:
            if not _ar_hidden_node_visibility.has(node_3d):
                _ar_hidden_node_visibility[node_3d] = node_3d.visible
            node_3d.visible = false
        elif _ar_hidden_node_visibility.has(node_3d):
            node_3d.visible = bool(_ar_hidden_node_visibility[node_3d])

    # The inverse group: visible ONLY while AR passthrough is active.
    for node in get_tree().get_nodes_in_group(GROUP_AR_PASSTHROUGH_ONLY):
        if node is Node3D:
            (node as Node3D).visible = enabled

    if not enabled:
        _ar_hidden_node_visibility.clear()

func _apply_session_hidden(enabled: bool) -> void:
    for node in get_tree().get_nodes_in_group(session_hide_group):
        if not (node is CanvasItem or node is Node3D or node is CanvasLayer):
            continue
        if enabled:
            if not _session_hidden_node_visibility.has(node):
                _session_hidden_node_visibility[node] = node.visible
            node.visible = false
        elif _session_hidden_node_visibility.has(node):
            node.visible = bool(_session_hidden_node_visibility[node])

    if not enabled:
        _session_hidden_node_visibility.clear()

func _show_browser_failure(message: String) -> void:
    if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
        return

    var js_bridge = Engine.get_singleton("JavaScriptBridge")
    var encoded_message := JSON.stringify(message)
    js_bridge.eval("window.CompanyWebXRFailure = %s; console.error(%s);" % [encoded_message, encoded_message], true)


func _adopt_session_ui() -> void:
    for ui in get_tree().get_nodes_in_group(GROUP_SESSION_UI):
        if ui.has_method("get_vr_button"):
            _vr_button = ui.get_vr_button()
            _ar_button = ui.get_ar_button()
            _status_label = ui.get_status_label()
            return


func _build_default_ui() -> void:
    # Self-contained VR/AR entry panel + status. Added to session_hide_group so
    # it auto-hides during any immersive session. Wire your own buttons/label via
    # the export paths to override this.
    var canvas := CanvasLayer.new()
    canvas.name = "WebXRSessionUI"
    add_child(canvas)
    canvas.add_to_group(session_hide_group)

    var panel := PanelContainer.new()
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 24.0
    panel.offset_top = 24.0
    canvas.add_child(panel)

    var margin := MarginContainer.new()
    for side in ["left", "top", "right", "bottom"]:
        margin.add_theme_constant_override("margin_" + side, 16)
    panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 8)
    margin.add_child(vbox)

    var title := Label.new()
    title.text = "WebXR"
    title.add_theme_font_size_override("font_size", 22)
    vbox.add_child(title)

    _status_label = Label.new()
    _status_label.text = "Checking WebXR support..."
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _status_label.custom_minimum_size = Vector2(300, 0)
    vbox.add_child(_status_label)

    var buttons := HBoxContainer.new()
    buttons.add_theme_constant_override("separation", 8)
    vbox.add_child(buttons)

    _vr_button = Button.new()
    _vr_button.text = "Enter VR"
    _vr_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    buttons.add_child(_vr_button)

    _ar_button = Button.new()
    _ar_button.text = "Enter AR"
    _ar_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    buttons.add_child(_ar_button)


func _find_world_environment() -> WorldEnvironment:
    # Auto-find the scene's WorldEnvironment when not wired, so AR passthrough can
    # clear its background (sky/color) with no manual setup.
    # Walks up to our own top-level ancestor rather than asking the tree for
    # current_scene: current_scene is not published until AFTER add_child
    # returns, so anything resolving during _ready (or during the router's
    # add-then-publish order) reads null or the OUTGOING scene. Our own ancestry
    # is correct the moment we are in the tree.
    var scene: Node = self
    while scene.get_parent() != null and scene.get_parent() != get_tree().root:
        scene = scene.get_parent()
    if scene == null:
        return null
    var found := scene.find_children("*", "WorldEnvironment", true, false)
    if found.is_empty():
        # Last resort for a rig parented outside the scene it serves.
        var current := get_tree().current_scene
        if current == null or current == scene:
            return null
        found = current.find_children("*", "WorldEnvironment", true, false)
        if found.is_empty():
            return null
    return found[0] as WorldEnvironment

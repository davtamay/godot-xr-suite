class_name WebXRRenderer
extends RefCounted

## Renderer selection for WebXR web apps (WebGL vs WebGPU).
##
## The graphics backend is chosen ONCE, at page load, before the first canvas
## context exists: an HTML canvas is permanently locked to its first
## getContext type, so WebGL2 and WebGPU can never share a canvas and the
## renderer cannot be switched live. This helper lets a menu present the choice
## EXPLICITLY - read which backend booted, ask what each backend can do on THIS
## browser, and save a preference + reload to switch to the other.
##
## The preference is a localStorage key the export's HTML shell reads before
## engine start-up and turns into GODOT_CONFIG.experimentalWebGPU. With no
## preference, the shell selects WebGPU for flat desktop and WebGL when an
## immersive WebXR runtime is available. Pure GDScript + JavaScriptBridge; every
## call is safe off-web (returns sensible defaults so a menu still builds in the
## editor).
##
## GPU depth availability is negotiated per session. Feature detection describes
## the browser API; the runtime depth status also reports CPU fallback, missing
## data, paused sensing and engine import failures. API presence alone is not
## proof that a headset delivered valid depth.

const PREF_KEY := "godot_renderer"

## "webgpu" when the RenderingDevice (WebGPU) backend booted, else "webgl".
static func active() -> String:
    return "webgpu" if is_webgpu() else "webgl"

## True when the app is running on the WebGPU (RenderingDevice) backend. On the
## web the only RD driver is WebGPU, so RD-present == WebGPU; gated to web so a
## desktop editor (Vulkan/D3D12 RD) does not read as "webgpu".
static func is_webgpu() -> bool:
    return OS.has_feature("web") and RenderingServer.get_rendering_device() != null

## True when this BUILD can actually run WebGPU at all: exported with the WebGPU
## driver (a custom engine that has the infrastructure) AND the browser supports
## WebGPU. On stock Godot (no WebGPU driver) or a gl_compatibility export this is
## false - so a menu offers the WebGPU choice ONLY where it exists and stays
## WebGL-only everywhere else. This is what makes the addon portable: drop it in
## any Godot project and it degrades gracefully.
static func webgpu_supported() -> bool:
    if is_webgpu():
        return true
    var js = _js()
    if js == null:
        return false
    # __godotWebGPUCapable is stamped by a WebGPU-aware HTML shell as
    # (this export baked the WebGPU driver) AND (the browser exposes WebGPU).
    # The separate __godotWebXRWebGPUCapable flag reports XRGPUBinding support;
    # flat desktop WebGPU remains useful even when immersive XR cannot use it.
    # Absent on stock Godot and gl_compatibility exports, so those builds stay
    # WebGL-only instead of showing a dead WebGPU button.
    return bool(js.eval("(!!window.__godotWebGPUCapable)", true))

## Does the WebGPU XR path expose real-world depth on THIS browser? Feature-
## detects getDepthInformation on XRGPUBinding, so this flips to true on its own
## the day a browser ships it (Quest's XRGPUBinding lacks it today).
static func webgpu_depth_available() -> bool:
    var js = _js()
    if js == null:
        return false
    var probe := "(function(){try{return !!(window.XRGPUBinding && XRGPUBinding.prototype && typeof XRGPUBinding.prototype.getDepthInformation === 'function');}catch(e){return false;}})()"
    return bool(js.eval(probe, true))

## True when the app is on WebGPU AND this browser can't serve depth there, i.e.
## depth scan / occlusion are unavailable until the user switches to WebGL.
static func depth_blocked_here() -> bool:
    if not is_webgpu():
        return false
    var xr := XRServer.find_interface("WebXR")
    if xr and xr.is_initialized():
        var status := str(xr.get_system_info().get("webxr_depth_status", ""))
        if status in ["ok", "cpu_depth"]:
            return false
    return not webgpu_depth_available()

## The saved renderer preference: "webgl", "webgpu", or "" (none set yet).
static func preference() -> String:
    var js = _js()
    if js == null:
        return ""
    var v = js.eval("(function(){try{return localStorage.getItem('%s')||'';}catch(e){return '';}})()" % PREF_KEY, true)
    return str(v) if v != null else ""

## Compact browser/runtime status for an in-app diagnostics label. This makes
## insecure LAN URLs obvious on the headset instead of leaving a disabled
## "Enter VR" button unexplained.
static func runtime_summary() -> String:
    if not OS.has_feature("web"):
        return "Desktop preview | WebXR requires a web export"
    var js = _js()
    if js == null:
        return "Browser status unavailable"
    var probe := """(function () {
        try {
            return JSON.stringify({
                protocol: location.protocol,
                host: location.host,
                secure: window.isSecureContext === true,
                webxr: !!navigator.xr,
                width: window.innerWidth || 0,
                height: window.innerHeight || 0,
                dpr: window.devicePixelRatio || 1
            });
        } catch (e) {
            return "{}";
        }
    })()"""
    var raw = js.eval(probe, true)
    var info = JSON.parse_string(str(raw))
    if typeof(info) != TYPE_DICTIONARY:
        return "Browser status unavailable"

    var protocol := str(info.get("protocol", "")).trim_suffix(":").to_upper()
    var host := str(info.get("host", "unknown host"))
    var secure := bool(info.get("secure", false))
    var webxr := bool(info.get("webxr", false))
    var security_note := "secure context" if secure else "INSECURE: immersive WebXR blocked"
    var xr_note := "WebXR API ready" if webxr else "WebXR API unavailable"
    return "%s %s | %s | %s\nViewport %dx%d @ %.2fx" % [
        protocol,
        host,
        security_note,
        xr_note,
        int(info.get("width", 0)),
        int(info.get("height", 0)),
        float(info.get("dpr", 1.0)),
    ]

## Save a renderer preference ("webgl" or "webgpu") and reload the page so the
## shell boots the chosen backend. No-op off-web or for an unknown mode.
static func switch_to(mode: String) -> void:
    if mode != "webgl" and mode != "webgpu":
        return
    var js = _js()
    if js == null:
        return
    # The shell's explicit test URL takes precedence over the saved preference.
    # Update both so in-app switches and WebGL retry buttons still work.
    var script := """
        try { localStorage.setItem('%s', '%s'); } catch (e) {}
        const rendererURL = new URL(location.href);
        rendererURL.searchParams.set('renderer', '%s');
        location.replace(rendererURL.href);
    """ % [PREF_KEY, mode, mode]
    js.eval(script, true)

## True when a failed WebGPU session has somewhere to go: this page runs on
## WebGPU, and the shell that honors the preference loaded it. That shell is the
## only thing that defines __godotWebGPUCapable. Without it a reload just boots
## WebGPU again, so a retry button would lead back to the same failure.
static func can_retry_on_webgl() -> bool:
    if not is_webgpu():
        return false
    var js = _js()
    if js == null:
        return false
    return bool(js.eval("('__godotWebGPUCapable' in window)", true))

## A short human-readable coverage note for a menu label. `renderer` is
## "webgl" or "webgpu"; the WebGPU note reflects THIS browser's depth support.
static func coverage_note(renderer: String) -> String:
    if renderer == "webgl":
        return "Recommended. Full features (depth scan, occlusion, room mesh, hands), smooth XR."
    var note := "EXPERIMENTAL - Godot's modern Mobile renderer (PBR, compute, MSAA) running on WebGPU in XR, likely a web first. Held back by today's browsers, not the engine: the WebXR-WebGPU bridge copies every frame to the compositor (WebGL hands frames over directly), so XR framerate is lower, and re-entering a session may need a page reload."
    if not webgpu_depth_available():
        note += " GPU depth API unavailable; CPU depth may still be granted by the session."
    return note + " It all lights up as browsers optimize - until then, WebGL is the smooth choice."

static func _js():
    if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
        return Engine.get_singleton("JavaScriptBridge")
    return null

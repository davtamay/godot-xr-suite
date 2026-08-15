extends Node3D
## Harvests WebXR depth-sensing data (CPU path) into a live depth mesh.
##
## Depth sensing is the LIVE sensor view: per-frame range data covering
## whatever the headset currently looks at, including moving objects. It
## complements mesh detection (webxr_mesh_bridge.gd), which serves the
## platform's persistent reconstructed room geometry. Out of the box today
## Quest ships mesh detection while Android XR ships depth sensing, so a
## demo needs both, separately toggleable.
##
## Mechanism: a JS hook wraps the session's requestAnimationFrame. On a
## throttled tick it reads the primary view's XRCPUDepthInformation, samples
## it on a fixed grid via getDepthInMeters() (which applies the buffer
## transform and rawValueToMeters for us), unprojects each sample to the
## session reference space, and publishes the point grid. This node polls
## the grid and triangulates it into an ArrayMesh, culling triangles across
## depth discontinuities and coloring vertices by distance.
##
## Two layers render: the LIVE SWEEP (the current sensor view, refreshed
## ~4 Hz, distance-colored - the "scanner beam") and, with `accumulate` on,
## the persistent SCAN - triangulated surface patches accumulate wherever
## the sweep touches unscanned space (tracked in a world-anchored 5 cm
## voxel store), rendered in the same blue as the room-mesh visualization.
## Looking around progressively reconstructs the room from raw depth. This
## is the room-scan experience on devices that ship depth sensing but lock
## mesh detection behind browser flags (Android XR out of the box).
##
## The unprojection is exact for WebXR's (possibly asymmetric) perspective
## projections without a matrix inverse: with column-major projection P and
## eye depth d (meters), ndc.x = (P[0]*x + P[8]*z)/-z with z = -d, so
## x = d*(ndc.x + P[8])/P[0] and y = d*(ndc.y + P[9])/P[5].
##
## Requires the session to be granted "depth-sensing". cpu-optimized grants
## (Android XR) read XRCPUDepthInformation directly; gpu-optimized grants on
## WebGL sessions (Quest) decode the XRWebGLBinding depth texture with a
## grid-sized shader pass and read it back. get_status() reports honestly
## which precondition is missing.
##
## OCCLUSION PATHS (both fed by THIS bridge's CPU depth harvest - the depth
## sensor's own texture is not directly bindable in the browser yet):
##   HARD (set_occlude): the live per-frame depth grid is triangulated into a
##     mesh drawn with a subtract-blend punch (_punch_instance). Crisp, cheap,
##     reliable - the default.
##   SOFT (set_ext_harvest): the depth grid is uploaded as a per-eye texture
##     array and PUSHED onto occludable objects' neutral occlusion shader
##     (group 'xr_occludable'), which fades each object to passthrough where
##     the real world is in front, with a feathered edge (the Meta/Unity
##     per-object technique). No fullscreen quad, no scene DEPTH_TEXTURE.
## The old FULLSCREEN sensor occluder (webxr_occluder + webxr_occlusion*.gdshader)
## was REMOVED: a fullscreen quad can't read scene depth in the XR render path,
## so it never worked. A future GPU-direct depth path (the engine's dormant
## wip/gl-depth-texture branch) would remove the CPU roundtrip; until then this
## bridge is the single source of depth for both occlusion modes.

const MESH_MATERIAL := preload("res://addons/godot_webxr_scene_understanding/runtime/depth_mesh_material.tres")
## Scan accumulation draws depth-test-free at a high queue priority so the
## occlusion punch (which depth-writes real surfaces to hide virtual content
## behind them) can never erase the scan itself - the scan IS the real
## surface's visualization. no_depth_test is shader codegen, so it must live
## in a baked .tres, never be flipped at runtime (web exports would miss the
## shader variant).
const SCAN_MATERIAL := preload("res://addons/godot_webxr_scene_understanding/runtime/depth_scan_overlay_material.tres")
## The same subtract-blend punch the room-mesh occluder uses. Rendered on the
## LIVE per-frame depth mesh it gives DYNAMIC occlusion - virtual content is
## hidden behind moving real things (a hand) the static room mesh can't see.
const PUNCH_MATERIAL := preload("res://addons/godot_webxr_scene_understanding/runtime/mesh_punch_material.tres")

## Longest triangle edge kept, in meters; longer edges span depth
## discontinuities (object silhouettes) and would web the scene together.
@export var max_edge_length := 0.35
## Distance (from the headset at harvest time) mapped to the far color.
@export var far_distance := 6.0
## Accumulate every harvest into a persistent triangulated scan. OFF by
## default: depth sensing is a LIVE, per-frame measurement, so persisting it
## across frames contradicts what it is and quickly overwhelms the view with
## stale geometry. Persistent room reconstruction is mesh detection's job
## (the Room Mesh / Live Reconstruction toggles), not depth's.
@export var accumulate := false
## Draw the raw per-harvest sweep - the CURRENT sensor view, replaced (not
## accumulated) each ~4 Hz harvest. This is the honest depth-sensing view:
## only the live measurement, nothing persisted.
@export var show_live_sweep := true
## The accumulated scan's tint - matches the room-mesh blue.
@export var scan_color := Color(0.08, 0.72, 1.0, 0.5)

## The scan is stored as half-meter world chunks, each holding the newest
## connected triangulated geometry that covered it - chunks REPLACE rather
## than accumulate, which is what keeps the mesh a single coherent layer
## (no stacking) with grid connectivity (no gaps), matching the platform
## reconstructions' behavior.
const SCAN_CHUNK_SIZE := 0.5
const SCAN_CHUNK_CAP := 4000

var auto_visualize := false
## Occlusion mode: harvest depth and punch the live mesh (dynamic occlusion),
## independent of the scan visualization.
var occlude_enabled := false

var _webxr: XRInterface
var _installed := false
var _poll_accum := 0.0
## Poll cadence: faster while soft-occluding (less head-motion lag), slower for
## the passive scan/mesh view.
var _poll_interval := 0.25
var _last_seq := 0
## Triangles in the most recent live harvest (for an honest status count now
## that accumulation is off - the old cell count would always read 0).
var _live_tris := 0
var _material: StandardMaterial3D
var _mesh_instance: MeshInstance3D
## Second instance sharing the live mesh geometry but drawing the occlusion
## punch, so Show (visible sweep) and Occlude (invisible punch) are independent.
var _punch_instance: MeshInstance3D
var _scan_instance: MeshInstance3D
## Screen-space depth texture (metres, FORMAT_RF) uploaded from the harvest for
## the per-pixel occlusion shader, plus an external-harvest request from the
## occluder (harvest + upload the texture without rendering the bridge's mesh).
## Two-layer env-depth (layer 0 = left eye, 1 = right eye) so the per-object
## occlusion shader can sample the correct eye via ViewIndex (stereo-correct).
var _env_img0: Image
var _env_img1: Image  # last VALID right-eye grid (kept when a harvest lacks met1)
var _env_depth_tex: Texture2DArray
var _ext_harvest := false
## Per-object occlusion edge softness (0 = crisp, 1 = very soft).
var _occ_softness := 0.0
# Vector3i chunk key -> { verts: Array[Vector3], indices: Array[int] }
# (plain Arrays: reference semantics during building; packed at rebuild).
var _scan_chunks := {}
var _scan_dirty := false
var _scan_rebuild_cooldown := 0.0
# The mesh bridge this toggle is currently driving (Android XR routing).

func _ready() -> void:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		set_process(false)
		return
	_webxr = XRServer.find_interface("WebXR")
	if _webxr:
		_webxr.session_started.connect(_on_session_started)
		_webxr.session_ended.connect(_on_session_ended)
	add_to_group("webxr_depth_bridge")
	add_to_group("webxr_feature_provider")
	_material = MESH_MATERIAL.duplicate() as StandardMaterial3D
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "DepthMesh"
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.visible = false
	add_child(_mesh_instance)
	_punch_instance = MeshInstance3D.new()
	_punch_instance.name = "DepthMeshPunch"
	_punch_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_punch_instance.material_override = PUNCH_MATERIAL
	_punch_instance.visible = false
	add_child(_punch_instance)
	_scan_instance = MeshInstance3D.new()
	_scan_instance.name = "DepthScan"
	_scan_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_scan_instance.visible = false
	_scan_instance.material_override = SCAN_MATERIAL.duplicate()
	add_child(_scan_instance)
	_install_js_hook()
	if _webxr and _webxr.is_initialized():
		_on_session_started()

## Push a shader parameter onto every occludable object's material. The neutral
## group is canonical; the old WebXR group remains a compatibility input.
func _push_occlusion(param: StringName, value: Variant) -> void:
	for node in _occludable_nodes():
		if node is MeshInstance3D:
			var mat: Material = node.get_surface_override_material(0)
			if mat == null:
				mat = node.material_override
			if mat is ShaderMaterial:
				mat.set_shader_parameter(param, value)

func _install_js_hook() -> void:
	if _installed:
		return
	_installed = true
	var js := Engine.get_singleton("JavaScriptBridge")
	js.eval("""
(function () {
	if (window.GodotWebXRDepthBridge) { return; }
	const bridge = {
		harvest: false, refType: 'local-floor', _ref: null, _refPending: false,
		seq: 0, frame: null, intervalMs: 250, _last: 0,
		gridW: 128, gridH: 96, status: 'idle', usage: '', format: '', size: '', path: '',
		// Accumulated scan: world-anchored voxel occupancy. Grid points whose
		// cell is NEW this harvest get flagged fresh, so the consumer can
		// accumulate triangulated patches of only-new surface - looking
		// around builds a persistent room scan out of live depth.
		cellSize: 0.05, maxCells: 100000, cells: null, cellCount: 0,
	};
	window.GodotWebXRDepthBridge = bridge;

	if (typeof XRSession === 'undefined') {
		bridge.status = 'api-unavailable';
		return;
	}

	// CPU path (Android XR): sample XRCPUDepthInformation on the grid.
	function cpuHarvestMeters(frame, view) {
		if (typeof frame.getDepthInformation !== 'function') {
			bridge.status = 'no-cpu-api';
			return null;
		}
		let d = null;
		try { d = frame.getDepthInformation(view); } catch (e) {
			bridge.status = 'error:' + e.name;
			return null;
		}
		if (!d) { bridge.status = 'no-data'; return null; }
		if (typeof d.getDepthInMeters !== 'function') { bridge.status = 'no-meters-api'; return null; }
		const gw = bridge.gridW, gh = bridge.gridH;
		const meters = new Float32Array(gw * gh);
		for (let gy = 0; gy < gh; gy++) {
			const v = gy / (gh - 1);
			for (let gx = 0; gx < gw; gx++) {
				let dm = 0;
				try { dm = d.getDepthInMeters(gx / (gw - 1), v); } catch (e) { dm = 0; }
				meters[gy * gw + gx] = dm;
			}
		}
		bridge.path = 'cpu';
		bridge.status = 'ok';
		bridge.size = d.width + 'x' + d.height;
		return meters;
	}

	// GPU path (Quest: gpu-optimized-only grants on WebGL sessions): decode
	// the XRWebGLBinding depth texture into a grid-sized RGBA8 target with a
	// tiny shader pass and read it back. Runs on the engine's own WebGL2
	// context inside the rAF (XR textures are frame-scoped), with full GL
	// state save/restore around the pass.
	function gpuHarvestMeters(frame, view, layerIdx) {
		const g = bridge._gpu || (bridge._gpu = {});
		if (g.fail) { bridge.status = g.failWhy; return null; }
		const gw = bridge.gridW, gh = bridge.gridH;
		if (!g.gl) {
			const c = (typeof GodotConfig !== 'undefined' && GodotConfig.canvas) ? GodotConfig.canvas : document.querySelector('canvas');
			g.gl = c ? c.getContext('webgl2') : null;
			if (!g.gl) {
				g.fail = true; g.failWhy = 'gpu-no-webgl-context';
				bridge.status = g.failWhy;
				return null;
			}
		}
		const gl = g.gl;
		if (g.session !== frame.session) {
			try {
				g.binding = new XRWebGLBinding(frame.session, gl);
				g.session = frame.session;
			} catch (e) { bridge.status = 'gpu-binding-fail:' + e.name; return null; }
		}
		if (typeof g.binding.getDepthInformation !== 'function') {
			g.fail = true; g.failWhy = 'gpu-api-missing';
			bridge.status = g.failWhy;
			return null;
		}
		let d = null;
		try { d = g.binding.getDepthInformation(view); } catch (e) {
			bridge.status = 'gpu-error:' + e.name;
			return null;
		}
		if (!d || !d.texture) { bridge.status = 'no-data'; return null; }
		// The delivered texture's exact shape varies per browser (2D vs
		// array, 8-bit pair vs 16-bit normalized vs float). Self-calibrate:
		// cycle decode/sampler combos until a readback yields valid depths,
		// then lock. bridge.dbg carries the evidence either way.
		if (g.attempt === undefined) { g.attempt = 0; }
		const typeKnown = typeof d.textureType === 'string' && d.textureType.length > 0;
		let isArray, mode;
		// If the browser exposes the depth camera's own projection matrix,
		// the exact conversion derives from it: raw = -P10 + P14/m, so
		// m = P14/(raw + P10) - no guessed planes (mode 5, sign-agnostic).
		const pm = (d.projectionMatrix && d.projectionMatrix.length >= 16) ? d.projectionMatrix : null;
		if (g.locked) {
			isArray = g.locked.arr; mode = g.locked.mode;
		} else if (bridge.format === 'luminance-alpha' && g.attempt < 4) {
			// THE DOCUMENTED PATH: luminance-alpha packs a 16-bit value
			// across the L+A channels storing millimeters; raw = L + A*256,
			// meters = raw * rawValueToMeters (= mode 0). This is what every
			// reference engine uses - no linearization guessing.
			mode = 0;
			isArray = typeKnown ? (d.textureType === 'texture-array') : (g.attempt % 2 === 1);
		} else if (bridge.format === 'float32' && g.attempt < 4) {
			// float32 stores metric depth directly in .r * rawValueToMeters.
			mode = 1;
			isArray = typeKnown ? (d.textureType === 'texture-array') : (g.attempt % 2 === 1);
		} else if (pm && g.attempt < 8) {
			// Fallback for unsigned-short (undocumented GPU encoding): the
			// depth camera's projection matrix gives ndc = -P10 + P14/m.
			mode = 5;
			isArray = typeKnown ? (d.textureType === 'texture-array') : (g.attempt % 2 === 1);
		} else {
			mode = g.attempt % 6;
			isArray = typeKnown ? (d.textureType === 'texture-array') : (Math.floor(g.attempt / 6) % 2 === 1);
			if (mode === 5 && !pm) {
				g.attempt++;
				bridge.status = 'calibrating';
				return null;
			}
		}
		// The depth map may carry its own projection range - but only trust
		// it when it is actually usable (Quest exposes the fields holding
		// zero, which turns the linearization into NaN); otherwise the
		// session's planes.
		const rs = frame.session.renderState;
		let depthNear = (rs && isFinite(rs.depthNear) && rs.depthNear > 0.0001) ? rs.depthNear : 0.1;
		let depthFar = (rs && isFinite(rs.depthFar) && rs.depthFar > depthNear) ? rs.depthFar : 1000.0;
		if (isFinite(d.depthNear) && d.depthNear > 0.0001 && isFinite(d.depthFar) && d.depthFar > d.depthNear) {
			depthNear = d.depthNear;
			depthFar = d.depthFar;
		}
		try {
			if (!g.fbo || g.gw !== gw || g.gh !== gh) {
				// Rebuild the readback target when the resolution changes at
				// runtime (the resolution stepper), freeing the old one first.
				if (g.fbo) { gl.deleteFramebuffer(g.fbo); gl.deleteTexture(g.tex); }
				g.gw = gw; g.gh = gh;
				g.tex = gl.createTexture();
				gl.activeTexture(gl.TEXTURE0);
				const prevTex = gl.getParameter(gl.TEXTURE_BINDING_2D);
				gl.bindTexture(gl.TEXTURE_2D, g.tex);
				gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gw, gh, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
				gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
				gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
				gl.bindTexture(gl.TEXTURE_2D, prevTex);
				g.fbo = gl.createFramebuffer();
				const prevFbo = gl.getParameter(gl.DRAW_FRAMEBUFFER_BINDING);
				gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, g.fbo);
				gl.framebufferTexture2D(gl.DRAW_FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, g.tex, 0);
				gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, prevFbo);
				if (!g.vao) { g.vao = gl.createVertexArray(); }
				g.buf = new Uint8Array(gw * gh * 4);
			}
			const progKey = isArray ? 'progArr' : 'prog2d';
			if (!g[progKey]) {
				const vs = '#version 300 es\\nvoid main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));gl_Position=vec4(p*2.0-1.0,0.0,1.0);}';
				const samp = isArray ? 'uniform highp sampler2DArray depthTex;' : 'uniform highp sampler2D depthTex;';
				// uLayer picks the eye's array layer (0 = left, 1 = right) so the
				// right eye reads its OWN depth, not the left's.
				const fetch = isArray ? 'texture(depthTex, vec3(uv, uLayer))' : 'texture(depthTex, uv)';
				const fs = '#version 300 es\\nprecision highp float;\\n' + samp +
					'\\nuniform mat4 uvTransform;\\nuniform vec2 gridSize;\\nuniform int fmt;\\nuniform float rawToMeters;\\nuniform vec2 nearFar;\\nuniform vec2 pmv;\\nuniform float uLayer;\\nout vec4 outColor;\\n' +
					'void main(){\\n' +
					// gl_FragCoord.y is bottom-up, but the depth transform (and
					// the CPU getDepthInMeters path) use a top-down normalized
					// view; without this flip the whole reconstruction - and
					// the occlusion punch built from it - is mirrored top-to-
					// bottom (a hand reads upside down).
					'  vec2 nv = vec2(floor(gl_FragCoord.x) / (gridSize.x - 1.0), 1.0 - floor(gl_FragCoord.y) / (gridSize.y - 1.0));\\n' +
					'  vec2 uv = (uvTransform * vec4(nv, 0.0, 1.0)).xy;\\n' +
					'  vec4 t = ' + fetch + ';\\n' +
					// fmt 0: two 8-bit channels (luminance-alpha style);
					// fmt 1: float meters in r; fmt 2: 16-bit normalized in r;
					// fmt 3: forward nonlinear depth-buffer value in r;
					// fmt 4: reversed-z nonlinear depth-buffer value in r
					// (both linearized with the depth map's near/far planes).
					'  float m;\\n' +
					'  if (fmt == 3) {\\n' +
					'    m = nearFar.x * nearFar.y / max(nearFar.y - t.r * (nearFar.y - nearFar.x), 0.0001);\\n' +
					'  } else if (fmt == 4) {\\n' +
					'    m = nearFar.x * nearFar.y / max(nearFar.x + t.r * (nearFar.y - nearFar.x), 0.0001);\\n' +
					// GL depth buffers store window-space [0,1] mapped from
					// [-1,1] NDC; undo that remap before applying the
					// projection relation ndc = -P10 + P14/m.
					'  } else if (fmt == 5) {\\n' +
					'    m = abs(pmv.y / (2.0 * t.r - 1.0 + pmv.x));\\n' +
					'  } else {\\n' +
					'    float raw = (fmt == 0) ? dot(t.ra, vec2(255.0, 255.0 * 256.0)) : ((fmt == 1) ? t.r : t.r * 65535.0);\\n' +
					// luminance-alpha's unpacked value is MILLIMETERS (the
					// reference decode divides by 8000mm). meters =
					// raw * rawValueToMeters, but Quest reports that as 1.0
					// (passthrough), so fall back to a mm->m scale for fmt 0
					// when rawToMeters is not a plausible sub-metre factor.
					'    float scale = (fmt == 0 && !(rawToMeters > 0.00001 && rawToMeters < 0.5)) ? 0.001 : rawToMeters;\\n' +
					'    m = raw * scale;\\n' +
					'  }\\n' +
					'  float nvd = clamp(m / 8.0, 0.0, 1.0);\\n' +
					'  float hi = floor(nvd * 255.0) / 255.0;\\n' +
					'  float lo = fract(nvd * 255.0);\\n' +
					'  outColor = vec4(hi, lo, 0.0, 1.0);\\n' +
					'}';
				const mk = function (type, src) {
					const sh = gl.createShader(type);
					gl.shaderSource(sh, src);
					gl.compileShader(sh);
					if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) { throw new Error(gl.getShaderInfoLog(sh)); }
					return sh;
				};
				const prog = gl.createProgram();
				gl.attachShader(prog, mk(gl.VERTEX_SHADER, vs));
				gl.attachShader(prog, mk(gl.FRAGMENT_SHADER, fs));
				gl.linkProgram(prog);
				if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { throw new Error(gl.getProgramInfoLog(prog)); }
				g[progKey] = prog;
				g[progKey + '_u'] = {
					tex: gl.getUniformLocation(prog, 'depthTex'),
					xf: gl.getUniformLocation(prog, 'uvTransform'),
					grid: gl.getUniformLocation(prog, 'gridSize'),
					fmt: gl.getUniformLocation(prog, 'fmt'),
					r2m: gl.getUniformLocation(prog, 'rawToMeters'),
					nf: gl.getUniformLocation(prog, 'nearFar'),
					pmv: gl.getUniformLocation(prog, 'pmv'),
					layer: gl.getUniformLocation(prog, 'uLayer'),
				};
			}
			// Save every piece of GL state the pass touches; the engine
			// assumes its cached state survives between its own frames.
			const s = {
				drawFbo: gl.getParameter(gl.DRAW_FRAMEBUFFER_BINDING),
				readFbo: gl.getParameter(gl.READ_FRAMEBUFFER_BINDING),
				prog: gl.getParameter(gl.CURRENT_PROGRAM),
				vao: gl.getParameter(gl.VERTEX_ARRAY_BINDING),
				activeTex: gl.getParameter(gl.ACTIVE_TEXTURE),
				viewport: gl.getParameter(gl.VIEWPORT),
				scissor: gl.isEnabled(gl.SCISSOR_TEST),
				blend: gl.isEnabled(gl.BLEND),
				depth: gl.isEnabled(gl.DEPTH_TEST),
				cull: gl.isEnabled(gl.CULL_FACE),
				stencil: gl.isEnabled(gl.STENCIL_TEST),
				rasterDiscard: gl.isEnabled(gl.RASTERIZER_DISCARD),
				colorMask: gl.getParameter(gl.COLOR_WRITEMASK),
				packBuf: gl.getParameter(gl.PIXEL_PACK_BUFFER_BINDING),
				packAlign: gl.getParameter(gl.PACK_ALIGNMENT),
			};
			gl.activeTexture(gl.TEXTURE0);
			s.tex2d = gl.getParameter(gl.TEXTURE_BINDING_2D);
			s.tex2da = gl.getParameter(gl.TEXTURE_BINDING_2D_ARRAY);
			try {
				gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, g.fbo);
				gl.viewport(0, 0, gw, gh);
				gl.disable(gl.SCISSOR_TEST);
				gl.disable(gl.BLEND);
				gl.disable(gl.DEPTH_TEST);
				gl.disable(gl.CULL_FACE);
				gl.disable(gl.STENCIL_TEST);
				gl.disable(gl.RASTERIZER_DISCARD);
				gl.colorMask(true, true, true, true);
				const prog = g[progKey];
				const u = g[progKey + '_u'];
				gl.useProgram(prog);
				gl.bindVertexArray(g.vao);
				if (isArray) { gl.bindTexture(gl.TEXTURE_2D_ARRAY, d.texture); } else { gl.bindTexture(gl.TEXTURE_2D, d.texture); }
				gl.uniform1i(u.tex, 0);
				gl.uniformMatrix4fv(u.xf, false, d.normDepthBufferFromNormView.matrix);
				gl.uniform2f(u.grid, gw, gh);
				gl.uniform1i(u.fmt, mode);
				gl.uniform1f(u.r2m, d.rawValueToMeters);
				gl.uniform2f(u.nf, depthNear, depthFar);
				gl.uniform2f(u.pmv, pm ? pm[10] : 0.0, pm ? pm[14] : 0.0);
				if (u.layer) { gl.uniform1f(u.layer, layerIdx || 0.0); }
				gl.drawArrays(gl.TRIANGLES, 0, 3);
				gl.bindFramebuffer(gl.READ_FRAMEBUFFER, g.fbo);
				gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
				gl.pixelStorei(gl.PACK_ALIGNMENT, 4);
				gl.readPixels(0, 0, gw, gh, gl.RGBA, gl.UNSIGNED_BYTE, g.buf);
			} finally {
				gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, s.drawFbo);
				gl.bindFramebuffer(gl.READ_FRAMEBUFFER, s.readFbo);
				gl.useProgram(s.prog);
				gl.bindVertexArray(s.vao);
				gl.activeTexture(gl.TEXTURE0);
				gl.bindTexture(gl.TEXTURE_2D, s.tex2d);
				gl.bindTexture(gl.TEXTURE_2D_ARRAY, s.tex2da);
				gl.activeTexture(s.activeTex);
				gl.viewport(s.viewport[0], s.viewport[1], s.viewport[2], s.viewport[3]);
				if (s.scissor) { gl.enable(gl.SCISSOR_TEST); }
				if (s.blend) { gl.enable(gl.BLEND); }
				if (s.depth) { gl.enable(gl.DEPTH_TEST); }
				if (s.cull) { gl.enable(gl.CULL_FACE); }
				if (s.stencil) { gl.enable(gl.STENCIL_TEST); }
				if (s.rasterDiscard) { gl.enable(gl.RASTERIZER_DISCARD); }
				gl.colorMask(s.colorMask[0], s.colorMask[1], s.colorMask[2], s.colorMask[3]);
				gl.bindBuffer(gl.PIXEL_PACK_BUFFER, s.packBuf);
				gl.pixelStorei(gl.PACK_ALIGNMENT, s.packAlign);
			}
			const meters = new Float32Array(gw * gh);
			const buf = g.buf;
			// Shader row r encodes view-coord v = r/(gh-1); readPixels also
			// returns row 0 first, so indices line up with the grid loop.
			let valid = 0;
			let vmn = 1e9, vmx = -1e9;
			for (let i = 0; i < gw * gh; i++) {
				const nvd = buf[i * 4] / 255.0 + buf[i * 4 + 1] / 65025.0;
				const m = nvd * 8.0;
				meters[i] = m;
				if (m > 0.1 && m < 8.0) {
					valid++;
					if (m < vmn) { vmn = m; }
					if (m > vmx) { vmx = m; }
				}
			}
			const spread = (valid > 0) ? (vmx - vmn) : 0;
			bridge.dbg = 'type=' + (d.textureType || '?') + ' fmt=' + (bridge.format || '?') + ' mode=' + mode + (isArray ? 'A' : '2') + ' r2m=' + Number(d.rawValueToMeters).toPrecision(3) + ' nf=' + depthNear.toFixed(2) + '/' + depthFar.toFixed(0) + ' rawNF=' + String(d.depthNear) + '/' + String(d.depthFar) + ' pm=' + (pm ? pm[10].toPrecision(3) + ',' + pm[14].toPrecision(3) : 'n') + ' range=' + (valid ? vmn.toFixed(2) + '..' + vmx.toFixed(2) : 'none') + ' valid=' + valid + ' spread=' + spread.toFixed(2) + ' try=' + g.attempt;
			if (!g.locked) {
				// Room-plausibility gates: coverage, variation, reach (a
				// normalized decode varies but never exceeds ~1m = a wall in
				// the user's face), AND temporal consistency - a wrong
				// linearization amplifies sensor noise into meters of jitter,
				// so its stats jump wildly between readings; demand two
				// agreeing readings of the same combo before trusting it.
				if (valid > (gw * gh) * 0.25 && spread > 0.25 && vmx > 1.5) {
					const skey = mode + (isArray ? 'A' : '2');
					if (!g.pendingStats) { g.pendingStats = {}; }
					const prev = g.pendingStats[skey];
					if (prev && Math.abs(prev.vmx - vmx) < 1.0 && Math.abs(prev.spread - spread) < 0.8) {
						g.locked = { arr: isArray, mode: mode };
					} else {
						g.pendingStats[skey] = { vmx: vmx, spread: spread };
						g.attempt++;
						bridge.path = 'gpu';
						bridge.status = 'calibrating';
						return null;
					}
				} else if (g.attempt >= 24) {
					g.fail = true;
					g.failWhy = 'gpu-calibration-failed [' + bridge.dbg + ']';
					bridge.status = g.failWhy;
					return null;
				} else {
					g.attempt++;
					bridge.path = 'gpu';
					bridge.status = 'calibrating';
					return null;
				}
			}
			bridge.path = 'gpu';
			bridge.status = 'ok';
			bridge.size = d.width + 'x' + d.height;
			return meters;
		} catch (e) {
			g.fail = true; g.failWhy = 'gpu-pass-fail:' + (e && e.message ? String(e.message).slice(0, 80) : 'unknown');
			bridge.status = g.failWhy;
			return null;
		}
	}

	const orig = XRSession.prototype.requestAnimationFrame;
	XRSession.prototype.requestAnimationFrame = function (cb) {
		return orig.call(this, function (t, frame) {
			try {
				// Cheap property reads - keep the availability display honest
				// even before the first toggle turns harvesting on.
				bridge.usage = frame.session.depthUsage || '';
				bridge.format = frame.session.depthDataFormat || '';
				// 'raw' keeps moving objects (a hand); 'smooth' fuses them
				// away. Surfaced so the status can explain a missing hand.
				bridge.depthType = frame.session.depthType || '';
				// Newer UAs let pages pause the depth pipeline entirely -
				// reconcile it with the toggle so 'off' is free device-side.
				// depthActive is nullable; only act on a real boolean, and
				// only where the methods exist.
				if (bridge.harvest && frame.session.depthActive === false && typeof frame.session.resumeDepthSensing === 'function') {
					frame.session.resumeDepthSensing();
				} else if (!bridge.harvest && frame.session.depthActive === true && typeof frame.session.pauseDepthSensing === 'function') {
					frame.session.pauseDepthSensing();
				}
				if (bridge.harvest) {
					if (!bridge._ref && !bridge._refPending) {
						bridge._refPending = true;
						frame.session.requestReferenceSpace(bridge.refType)
							.then((r) => { bridge._ref = r; })
							.catch(() => { bridge._refPending = false; });
					}
					if (bridge._ref && (t - bridge._last) >= bridge.intervalMs) {
						// Throttle attempts too, not just successes; a
						// failing path must not retry at headset frame rate.
						bridge._last = t;
						const vp = frame.getViewerPose(bridge._ref);
						if (vp && vp.views.length) {
							const view = vp.views[0];
							// The depth image lags the pose by a few dozen ms;
							// harvesting during fast head motion smears samples
							// into wrong world positions. Skip only whip-pans
							// (roughly >60 deg/s or >0.5 m/s) - slow sweeps
							// paint normally.
							const trm = view.transform.matrix;
							const lastp = bridge._panPose;
							bridge._panPose = [trm[8], trm[9], trm[10], trm[12], trm[13], trm[14]];
							// A bare return here would skip the engine's own
							// frame callback below - gate by nulling the harvest.
							let pan = false;
							if (lastp) {
								const dr = Math.hypot(trm[8] - lastp[0], trm[9] - lastp[1], trm[10] - lastp[2]);
								const dp = Math.hypot(trm[12] - lastp[3], trm[13] - lastp[4], trm[14] - lastp[5]);
								pan = dr > 0.26 || dp > 0.12;
							}
							// gpu-optimized grants refuse the CPU API by
							// spec; go straight to the readback path there.
							const meters = pan ? null : (bridge.usage === 'gpu-optimized')
								? gpuHarvestMeters(frame, view, 0)
								: cpuHarvestMeters(frame, view);
							// Right eye, for stereo per-object occlusion. Layer 1 of the depth
							// array. GPU path: its own readback, once the decode LOCK holds
							// (else two readbacks per frame fight over calibration). CPU path:
							// NO second getDepthInMeters sweep - Galaxy's view-1 CPU depth
							// carries sustained reprojection junk during head motion (right-
							// eye-only round occlusion blobs, A/B-proven); the right grid is
							// instead REPROJECTED from the reliable left grid below - junk-free
							// by construction, parallax-correct, disocclusion holes stay empty
							// (= no occlusion), and a full sensor sweep cheaper per harvest.
							const view1 = (vp.views.length > 1) ? vp.views[1] : null;
							const meters1 = (bridge.wantMet && meters && view1 && bridge.usage === 'gpu-optimized' && bridge._gpu && bridge._gpu.locked)
								? gpuHarvestMeters(frame, view1, 1)
								: null;
							if (meters) {
								bridge._last = t;
								const p = view.projectionMatrix;
								const tr = view.transform.matrix;
								const gw = bridge.gridW, gh = bridge.gridH;
								const pts = new Array(gw * gh * 3);
								const val = new Array(gw * gh);
								const fresh = new Array(gw * gh);
								// Screen-space depth grid in millimetres for the
								// per-pixel occlusion texture (0 = no data). Only
								// built when the soft occluder asks (wantMet).
								const met = bridge.wantMet ? new Array(gw * gh) : null;
								// gpu path (Quest): met1 from its own readback ONLY - on a
								// readback gap met1 stays null and GDScript holds the last valid
								// right grid (the Quest-verified behavior; splatting into gaps
								// made the right eye ping-pong between differing grids = flaky).
								// cpu path (Galaxy): met1 ALWAYS by reprojecting the left grid
								// (met1Splat) - its own view-1 depth serves junk (blob fix).
								const gpuPath = (bridge.usage === 'gpu-optimized');
								const met1 = (bridge.wantMet && view1 && (meters1 || !gpuPath)) ? new Array(gw * gh).fill(0) : null;
								const met1Splat = !!(met1 && !meters1 && !gpuPath);
								const inv1 = met1Splat ? view1.transform.inverse.matrix : null;
								const p1 = met1Splat ? view1.projectionMatrix : null;
								const metFlip = (bridge.path === 'cpu');
								// The CPU getDepthInMeters grid stores row 0 at view-top; the GPU-readback grid (which the soft occluder shader is tuned for) stores row 0 at view-bottom. Flip the occlusion grid on the CPU path so Soft occludes the same place on both platforms.
								for (let gy = 0; gy < gh; gy++) {
									// Normalized view coords have a top-left
									// origin (y down); NDC y points up.
									const v = gy / (gh - 1);
									const ny = 1 - 2 * v;
									const mrow = metFlip ? (gh - 1 - gy) : gy;
									for (let gx = 0; gx < gw; gx++) {
										const u = gx / (gw - 1);
										const i = gy * gw + gx;
										const mi = mrow * gw + gx;
										// GPU-path right-eye grid: raw fill, exactly the behavior
										// verified on Quest. (A near-jump debounce was tried here and
										// REGRESSED Quest - it delays every moving occluder's leading
										// edge per-cell, which reads as flicker. Don't re-add.)
										if (met1 && meters1) {
											const d1 = meters1[i];
											met1[mi] = (d1 > 0.1 && d1 < 8.0) ? Math.round(d1 * 1000) : 0;
										}
										const dm = meters[i];
										if (!(dm > 0.1 && dm < 8.0)) {
											val[i] = 0;
											fresh[i] = 0;
											if (met) { met[mi] = 0; }
											pts[i * 3] = 0; pts[i * 3 + 1] = 0; pts[i * 3 + 2] = 0;
											continue;
										}
										if (met) { met[mi] = Math.round(dm * 1000); }
										const nx = 2 * u - 1;
										const ex = dm * (nx + p[8]) / p[0];
										const ey = dm * (ny + p[9]) / p[5];
										const ez = -dm;
										// View pose -> reference space (column-major).
										const wx = tr[0] * ex + tr[4] * ey + tr[8] * ez + tr[12];
										const wy = tr[1] * ex + tr[5] * ey + tr[9] * ez + tr[13];
										const wz = tr[2] * ex + tr[6] * ey + tr[10] * ez + tr[14];
										val[i] = 1;
										// mm precision keeps the poll payload small.
										pts[i * 3] = Math.round(wx * 1000) / 1000;
										pts[i * 3 + 1] = Math.round(wy * 1000) / 1000;
										pts[i * 3 + 2] = Math.round(wz * 1000) / 1000;
										if (met1Splat) {
											// Reproject this left-grid point into the RIGHT eye's grid.
											const ex1 = inv1[0] * wx + inv1[4] * wy + inv1[8] * wz + inv1[12];
											const ey1 = inv1[1] * wx + inv1[5] * wy + inv1[9] * wz + inv1[13];
											const ez1 = inv1[2] * wx + inv1[6] * wy + inv1[10] * wz + inv1[14];
											if (ez1 < -0.1) {
												const cw1 = p1[3] * ex1 + p1[7] * ey1 + p1[11] * ez1 + p1[15];
												const ndx = (p1[0] * ex1 + p1[4] * ey1 + p1[8] * ez1 + p1[12]) / cw1;
												const ndy = (p1[1] * ex1 + p1[5] * ey1 + p1[9] * ez1 + p1[13]) / cw1;
												if (ndx > -1 && ndx < 1 && ndy > -1 && ndy < 1) {
													const fx = (ndx + 1) * 0.5 * (gw - 1);
													const fy = (1 - ndy) * 0.5 * (gh - 1);
													const dmm = Math.round(-ez1 * 1000);
													// 2x2 min-splat: single-cell splats leave pinholes on
													// slanted surfaces, and a zero-hole bilinear-mixed with
													// a valid depth reads as a phantom NEAR value.
													// Met grids are BOTTOM-origin on BOTH paths (the cpu
													// path flips its top-origin source rows; the gpu
													// readback is natively bottom-origin). fy is a
													// TOP-origin row, so ALWAYS flip - the old metFlip-
													// conditional fed Quest an UPSIDE-DOWN right grid
													// whenever the splat covered a readback gap (flaky
													// occlusion that cut out and came back).
													for (let sy = 0; sy < 2; sy++) {
														const gy1 = Math.min(gh - 1, Math.floor(fy) + sy);
														const my1 = gh - 1 - gy1;
														for (let sx = 0; sx < 2; sx++) {
															const gx1 = Math.min(gw - 1, Math.floor(fx) + sx);
															const mi1 = my1 * gw + gx1;
															if (!met1[mi1] || dmm < met1[mi1]) { met1[mi1] = dmm; }
														}
													}
												}
											}
										}
										fresh[i] = 0;
										if (!bridge.cells) { bridge.cells = new Set(); }
										if (bridge.cellCount < bridge.maxCells) {
											const cs = bridge.cellSize;
											const bx = Math.round(wx / cs);
											const by = Math.round(wy / cs);
											const bz = Math.round(wz / cs);
											const key = bx + ',' + by + ',' + bz;
											if (!bridge.cells.has(key)) {
												bridge.cellCount++;
												fresh[i] = 1;
												// Claim a one-cell shell too: sensor noise
												// re-lands repeat views of the same surface
												// in neighboring voxels, which would tile
												// the same wall on top of itself forever.
												for (let ox = -1; ox <= 1; ox++) {
													for (let oy = -1; oy <= 1; oy++) {
														for (let oz = -1; oz <= 1; oz++) {
															bridge.cells.add((bx + ox) + ',' + (by + oy) + ',' + (bz + oz));
														}
													}
												}
											}
										}
									}
								}
								bridge.frame = {
									seq: ++bridge.seq, gw: gw, gh: gh, pts: pts, val: val,
									met: met, met1: met1,
									eye: [tr[12], tr[13], tr[14]],
									eye1: view1 ? [view1.transform.matrix[12], view1.transform.matrix[13], view1.transform.matrix[14]] : null,
								};
							}
						}
					}
				}
			} catch (e) { /* never break the app's frame loop */ }
			cb(t, frame);
		});
	};
}())
""", true)

func set_visualize(p_on: bool) -> void:
	auto_visualize = p_on
	_sync_harvest()
	_sync_render()
	if not p_on:
		# Live sensor data goes stale instantly; free it rather than freeze it.
		_last_seq = 0
		_clear_scan()

## Sampling resolution levels (fidelity stepper). Wider = sharper occlusion
## and scan, up to the sensor's own resolution; cost is the per-harvest
## JS->GDScript transport and, on the CPU path, one getDepthInMeters per cell.
const RES_LEVELS := [
	{ "name": "Low", "w": 96, "h": 72 },
	{ "name": "Med", "w": 128, "h": 96 },
	{ "name": "High", "w": 160, "h": 120 },
	{ "name": "Ultra", "w": 224, "h": 168 },
	{ "name": "Max", "w": 320, "h": 240 },
]
var res_level := 1

## Set the harvest grid to a level index; the GPU readback rebuilds its target
## on the next frame and the CPU path adapts automatically.
func set_resolution_level(p_level: int) -> void:
	res_level = clampi(p_level, 0, RES_LEVELS.size() - 1)
	var lvl: Dictionary = RES_LEVELS[res_level]
	Engine.get_singleton("JavaScriptBridge").eval("window.GodotWebXRDepthBridge && (window.GodotWebXRDepthBridge.gridW = %d, window.GodotWebXRDepthBridge.gridH = %d);" % [lvl["w"], lvl["h"]], true)
	_last_seq = 0

## The label for the current level, e.g. "Med 128x96".
func resolution_label() -> String:
	var lvl: Dictionary = RES_LEVELS[res_level]
	return "%s %dx%d" % [lvl["name"], lvl["w"], lvl["h"]]

## Occlusion mode: punch the live per-frame depth mesh so virtual content is
## hidden behind real surfaces, INCLUDING moving things (a hand) - the room
## mesh is static and cannot. Additive with the room-mesh occluder, not a
## replacement, so that working path is never disturbed.
func set_occlude(p_on: bool) -> void:
	occlude_enabled = p_on
	_sync_harvest()
	_sync_render()
	if not p_on:
		_last_seq = 0

## Depth harvesting (and the poll loop) run while EITHER the scan view or
## occlusion needs the data.
func _sync_harvest() -> void:
	var active := auto_visualize or occlude_enabled or _ext_harvest
	Engine.get_singleton("JavaScriptBridge").eval("window.GodotWebXRDepthBridge && (window.GodotWebXRDepthBridge.harvest = %s);" % ("true" if active else "false"), true)
	set_process(active)
	if not active:
		_mesh_instance.mesh = null
		_punch_instance.mesh = null

## Show and Occlude are independent: the visible sweep and the invisible punch
## are two instances sharing the live per-frame geometry.
func _sync_render() -> void:
	_mesh_instance.material_override = _material
	_mesh_instance.visible = auto_visualize and show_live_sweep
	_punch_instance.visible = occlude_enabled
	_scan_instance.visible = auto_visualize and accumulate

func _clear_scan() -> void:
	_scan_chunks.clear()
	_scan_dirty = false
	_scan_instance.mesh = null
	Engine.get_singleton("JavaScriptBridge").eval("window.GodotWebXRDepthBridge && (window.GodotWebXRDepthBridge.frame = null, window.GodotWebXRDepthBridge.cells = new Set(), window.GodotWebXRDepthBridge.cellCount = 0);", true)

## The granted depth usage ('cpu-optimized' / 'gpu-optimized' / '') for
## availability displays.
func get_usage() -> String:
	if not _installed:
		return ""
	return str(Engine.get_singleton("JavaScriptBridge").eval("window.GodotWebXRDepthBridge ? String(window.GodotWebXRDepthBridge.usage || '') : '';", true))

func get_status() -> String:
	if not _installed:
		return "Depth sensing: web only."
	if _webxr == null or not _webxr.is_initialized():
		return "Depth sensing: waiting for an immersive session."
	var features := str(_webxr.get("enabled_features"))
	if not features.contains("depth-sensing"):
		return "Depth sensing: not granted by the browser (on some devices it hides behind chrome://flags WebXR Incubations)."
	var js := Engine.get_singleton("JavaScriptBridge")
	var usage := str(js.eval("window.GodotWebXRDepthBridge ? window.GodotWebXRDepthBridge.usage : '';", true))
	var status := str(js.eval("window.GodotWebXRDepthBridge ? window.GodotWebXRDepthBridge.status : '';", true))
	var size := str(js.eval("window.GodotWebXRDepthBridge ? window.GodotWebXRDepthBridge.size : '';", true))
	if not (auto_visualize or occlude_enabled or _ext_harvest):
		return "Depth sensing: granted (usage: %s). Toggle on to harvest." % (usage if not usage.is_empty() else "pending")
	var path := str(js.eval("window.GodotWebXRDepthBridge ? String(window.GodotWebXRDepthBridge.path || '') : '';", true))
	match status:
		"ok":
			var path_desc := "CPU depth" if path == "cpu" else "GPU depth readback"
			var dtype := str(js.eval("window.GodotWebXRDepthBridge ? String(window.GodotWebXRDepthBridge.depthType || '') : '';", true))
			var dtype_note := ""
			if dtype == "smooth":
				dtype_note = ", SMOOTHED (moving objects like a hand may fade - raw is preferred)"
			elif dtype == "raw":
				dtype_note = ", raw"
			return "Depth LIVE via WebXR depth-sensing (%s%s): %s sensor, %d live triangles. A live per-frame view for occlusion, never a saved map." % [path_desc, dtype_note, size, _live_tris]
		"calibrating":
			var cal_dbg := str(js.eval("window.GodotWebXRDepthBridge ? String(window.GodotWebXRDepthBridge.dbg || '') : '';", true))
			return "Depth sensing (GPU readback) calibrating... [%s]" % cal_dbg
		"no-data":
			return "Depth sensing: granted (usage: %s) but no depth data served yet." % usage
		"no-cpu-api", "no-meters-api":
			return "Depth sensing: granted, but this browser lacks the CPU depth API (%s)." % status
		"gpu-no-webgl-context":
			return "Depth sensing: granted GPU-only, and this WebGPU session's browser has not shipped XRGPUBinding depth - upcoming browser feature."
		"gpu-api-missing":
			return "Depth sensing: granted GPU-only, but this browser lacks XRWebGLBinding.getDepthInformation."
		"idle":
			return "Depth sensing: harvest starting..."
		_:
			return "Depth sensing: granted but unreadable (%s, usage: %s)." % [status, usage]

func _on_session_started() -> void:
	# Match the hook's reference space to the one Godot's session got, so
	# harvested points land in tracked-node space.
	var js := Engine.get_singleton("JavaScriptBridge")
	var ref_type := str(_webxr.get("reference_space_type"))
	if not ref_type.is_empty():
		js.eval("window.GodotWebXRDepthBridge && (window.GodotWebXRDepthBridge.refType = '%s', window.GodotWebXRDepthBridge._ref = null, window.GodotWebXRDepthBridge._refPending = false);" % ref_type, true)
	# Fresh material per session: some browsers lose bindings to pre-session
	# GPU resources (same lesson as the mesh bridge). All shader-codegen
	# flags (vertex color, transparency, cull) live in the baked .tres.
	_material = MESH_MATERIAL.duplicate() as StandardMaterial3D
	_scan_instance.material_override = SCAN_MATERIAL.duplicate()
	# Re-apply the correct live-mesh material for the active mode (punch when
	# occluding, visualization otherwise).
	_sync_render()

func _on_session_ended() -> void:
	_mesh_instance.mesh = null
	_punch_instance.mesh = null
	_last_seq = 0
	_clear_scan()

func _process(delta: float) -> void:
	if not (auto_visualize or occlude_enabled or _ext_harvest):
		return
	if _scan_rebuild_cooldown > 0.0:
		_scan_rebuild_cooldown -= delta
	elif _scan_dirty:
		_rebuild_scan_mesh()
	_poll_accum += delta
	if _poll_accum < _poll_interval:
		return
	_poll_accum = 0.0
	var js := Engine.get_singleton("JavaScriptBridge")
	var payload := str(js.eval("(window.GodotWebXRDepthBridge && window.GodotWebXRDepthBridge.frame && window.GodotWebXRDepthBridge.frame.seq > %d) ? JSON.stringify(window.GodotWebXRDepthBridge.frame) : '';" % _last_seq, true))
	if payload.is_empty():
		return
	var data: Variant = JSON.parse_string(payload)
	if data == null:
		return
	_last_seq = int(data["seq"])
	# The per-pixel env-depth texture is only built when a consumer (the soft
	# occluder) asks for it - keeps the transport lean for Show/Hard-occlude.
	if _ext_harvest:
		_update_env_depth(data)
	if auto_visualize or occlude_enabled:
		_rebuild_mesh(data)

## Upload the harvested metres grid as a FORMAT_RF texture for the per-pixel
## (Meta-style) occlusion shader. Reuses the Image/ImageTexture across frames.
func _update_env_depth(data: Dictionary) -> void:
	var met_v: Variant = data.get("met", null)
	if met_v == null:
		return
	var met: Array = met_v
	var gw := int(data["gw"])
	var gh := int(data["gh"])
	if met.size() != gw * gh:
		return
	var met1_v: Variant = data.get("met1", null)
	var img0 := _grid_to_image(met, gw, gh)
	# Right eye: NEVER silently substitute the left grid when this harvest lacks
	# met1 (platforms skip second-view depth on some frames, especially during
	# head motion) - the left eye's grid is parallax-offset for the right eye and
	# painted RANDOM occlusion spots in that eye only. A stale right-eye grid is
	# strictly better than the other eye's fresh one.
	if met1_v != null and (met1_v as Array).size() == gw * gh:
		_env_img1 = _grid_to_image(met1_v, gw, gh)
	elif _env_img1 == null or _env_img1.get_width() != gw or _env_img1.get_height() != gh:
		_env_img1 = img0  # no right-eye grid served yet (first frames / res change)
	var img1: Image = _env_img1
	if _env_depth_tex == null or _env_img0 == null or _env_img0.get_width() != gw or _env_img0.get_height() != gh:
		_env_img0 = img0
		_env_depth_tex = Texture2DArray.new()
		_env_depth_tex.create_from_images([img0, img1])
		_push_occlusion(&"env_size", Vector2(gw, gh))
		_push_occlusion(&"env_depth", _env_depth_tex)
	else:
		_env_depth_tex.update_layer(img0, 0)
		_env_depth_tex.update_layer(img1, 1)
	# Eye-layer selector: each platform runs the selector VERIFIED on it.
	# Quest (gpu-optimized) = projection-sign (the nearest-eye test flickered
	# there); Galaxy (cpu) = nearest actual eye position (the sign heuristic
	# misfired on its projections and painted right-eye-only blobs).
	_push_occlusion(&"eye_select", 0.0 if get_usage() == "gpu-optimized" else 1.0)
	# Actual eye positions for the nearest-eye selector.
	var eye_v: Variant = data.get("eye", null)
	if eye_v is Array and (eye_v as Array).size() == 3:
		_push_occlusion(&"eye0_pos", Vector3(float(eye_v[0]), float(eye_v[1]), float(eye_v[2])))
	var eye1_v: Variant = data.get("eye1", null)
	if eye1_v is Array and (eye1_v as Array).size() == 3:
		_push_occlusion(&"eye1_pos", Vector3(float(eye1_v[0]), float(eye1_v[1]), float(eye1_v[2])))

func _grid_to_image(grid: Array, gw: int, gh: int) -> Image:
	var floats := PackedFloat32Array()
	floats.resize(gw * gh)
	for i in range(gw * gh):
		floats[i] = float(grid[i]) / 1000.0
	return Image.create_from_data(gw, gh, false, Image.FORMAT_RF, floats.to_byte_array())

## The per-pixel occlusion env-depth texture array (null until the first harvest).
func get_env_depth_texture() -> Texture:
	return _env_depth_tex

func get_env_size() -> Vector2:
	return Vector2(_env_img0.get_width(), _env_img0.get_height()) if _env_img0 else Vector2(128, 96)

## True while the per-object soft occlusion is feeding the env-depth globals.
func is_soft_occluding() -> bool:
	return _ext_harvest

## Soft occlusion feeds the env-depth globals from the harvest without the
## bridge rendering its own mesh (the objects' materials fade themselves).
func set_ext_harvest(on: bool) -> void:
	_ext_harvest = on
	# Gate the metres grid in the JS payload; also harvest FASTER while occluding
	# so the depth tracks head motion (stale depth = the occlusion "drags").
	Engine.get_singleton("JavaScriptBridge").eval("window.GodotWebXRDepthBridge && (window.GodotWebXRDepthBridge.wantMet = %s, window.GodotWebXRDepthBridge.intervalMs = %d);" % [("true" if on else "false"), (100 if on else 250)], true)
	_poll_interval = 0.1 if on else 0.25
	# Swap to the transparent occlusion material for Soft, opaque otherwise, THEN
	# push the enable flag (onto the now-active occlusion material).
	_swap_occlusion_materials(on)
	_push_occlusion(&"occ_enabled", 1.0 if on else 0.0)
	if on:
		_push_occlusion(&"softness", _occ_softness)
	_sync_harvest()

## Edge softness for the per-object occlusion (0 = crisp .. 1 = very soft).
func set_occ_softness(v: float) -> void:
	_occ_softness = clampf(v, 0.0, 1.0)
	_push_occlusion(&"softness", _occ_softness)

## Swap occludable objects to their transparent occlusion material for Soft mode,
## back to opaque otherwise. An OPAQUE object writes depth so the Hard mesh punch
## respects it; the transparent occlusion shader would let the punch through.
func _swap_occlusion_materials(on: bool) -> void:
	for node in _occludable_nodes():
		if not (node is MeshInstance3D):
			continue
		if on:
			if node.has_meta("occ_material") and not (node.get_surface_override_material(0) is ShaderMaterial):
				node.set_meta("opaque_material", node.get_surface_override_material(0))
				node.set_surface_override_material(0, node.get_meta("occ_material"))
		elif node.has_meta("opaque_material"):
			node.set_surface_override_material(0, node.get_meta("opaque_material"))


func _occludable_nodes() -> Array[Node]:
	var nodes: Array[Node] = []
	for group: StringName in [&"xr_occludable", &"webxr_occludable"]:
		for node: Node in get_tree().get_nodes_in_group(group):
			if not nodes.has(node):
				nodes.append(node)
	return nodes


## Bucket this harvest's connected triangles into world chunks by centroid
## and REPLACE each covered chunk's geometry with the newest version.
func _update_scan_chunks(verts: PackedVector3Array, tris: PackedInt32Array) -> void:
	var touched := {}
	for t in range(0, tris.size(), 3):
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		var centroid: Vector3 = (verts[a] + verts[b] + verts[c]) / 3.0
		var ck := Vector3i(floori(centroid.x / SCAN_CHUNK_SIZE), floori(centroid.y / SCAN_CHUNK_SIZE), floori(centroid.z / SCAN_CHUNK_SIZE))
		if not touched.has(ck):
			touched[ck] = { "verts": [], "indices": [], "remap": {} }
		var chunk: Dictionary = touched[ck]
		var remap: Dictionary = chunk["remap"]
		var cverts: Array = chunk["verts"]
		var cidx: Array = chunk["indices"]
		for idx in [a, b, c]:
			if not remap.has(idx):
				remap[idx] = cverts.size()
				cverts.append(verts[idx])
			cidx.append(remap[idx])
	for ck in touched:
		var newc: Dictionary = touched[ck]
		newc.erase("remap")
		if _scan_chunks.has(ck):
			# A harvest grazing a chunk's edge must not wipe a well-covered
			# chunk with a sliver; keep the old geometry until a comparable
			# view replaces it.
			var old_n: int = (_scan_chunks[ck]["indices"] as Array).size()
			if (newc["indices"] as Array).size() * 2 < old_n:
				continue
		elif _scan_chunks.size() >= SCAN_CHUNK_CAP:
			continue
		_scan_chunks[ck] = newc
	if not touched.is_empty():
		_scan_dirty = true

## Rebuild the persistent scan mesh from the chunk store. Throttled: chunk
## replacement is cheap per harvest, the merged rebuild is the heavy step.
func _rebuild_scan_mesh() -> void:
	_scan_dirty = false
	_scan_rebuild_cooldown = 1.0
	var all_verts := PackedVector3Array()
	var all_colors := PackedColorArray()
	var all_indices := PackedInt32Array()
	for ck in _scan_chunks:
		var chunk: Dictionary = _scan_chunks[ck]
		var base := all_verts.size()
		var cverts: Array = chunk["verts"]
		var cidx: Array = chunk["indices"]
		for v in cverts:
			all_verts.append(v)
			all_colors.append(scan_color)
		for i in cidx:
			all_indices.append(base + int(i))
	if all_indices.is_empty():
		_scan_instance.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = all_verts
	arrays[Mesh.ARRAY_COLOR] = all_colors
	arrays[Mesh.ARRAY_INDEX] = all_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	_scan_instance.mesh = mesh

func _rebuild_mesh(data: Dictionary) -> void:
	var gw := int(data["gw"])
	var gh := int(data["gh"])
	var pts: Array = data["pts"]
	var val: Array = data["val"]
	var tris := PackedInt32Array()
	var eye_arr: Array = data["eye"]
	var eye := Vector3(eye_arr[0], eye_arr[1], eye_arr[2])

	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(gw * gh)
	colors.resize(gw * gh)
	for i in gw * gh:
		var p := Vector3(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2])
		verts[i] = p
		var dist := clampf(eye.distance_to(p) / far_distance, 0.0, 1.0)
		# Near cyan -> far deep blue, dimming with distance (the punch material
		# ignores vertex color; the scan visualization uses it as its tint).
		colors[i] = Color.from_hsv(0.5 + 0.16 * dist, 0.85, 1.0 - 0.5 * dist, 0.85)

	var max_edge_sq := max_edge_length * max_edge_length
	var indices := PackedInt32Array()
	for gy in gh - 1:
		for gx in gw - 1:
			var i00 := gy * gw + gx
			var i10 := i00 + 1
			var i01 := i00 + gw
			var i11 := i01 + 1
			if not (val[i00] and val[i10] and val[i01] and val[i11]):
				continue
			# The diagonal is shared; checking it once covers both triangles.
			if verts[i00].distance_squared_to(verts[i11]) > max_edge_sq:
				continue
			# Godot front faces wind clockwise; these are clockwise as seen
			# from the harvesting eye, which depth surfaces always face.
			if verts[i00].distance_squared_to(verts[i10]) <= max_edge_sq \
					and verts[i10].distance_squared_to(verts[i11]) <= max_edge_sq:
				indices.append_array(PackedInt32Array([i00, i10, i11]))
				tris.append_array(PackedInt32Array([i00, i10, i11]))
			if verts[i00].distance_squared_to(verts[i01]) <= max_edge_sq \
					and verts[i01].distance_squared_to(verts[i11]) <= max_edge_sq:
				indices.append_array(PackedInt32Array([i00, i11, i01]))
				tris.append_array(PackedInt32Array([i00, i11, i01]))

	_live_tris = indices.size() / 3
	# Accumulation is a visualization concern; occlusion wants the LIVE frame
	# only (a moving hand must not smear into a persistent scan).
	if accumulate and auto_visualize and not tris.is_empty():
		_update_scan_chunks(verts, tris)
	# Build the live mesh when the visible sweep OR the occlusion punch needs it.
	if not ((auto_visualize and show_live_sweep) or occlude_enabled) or indices.is_empty():
		_mesh_instance.mesh = null
		_punch_instance.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	# Only the visible instance carries geometry (Show/Occlude are exclusive).
	if occlude_enabled:
		_mesh_instance.mesh = null
		_punch_instance.mesh = mesh
	else:
		_mesh_instance.mesh = mesh
		_punch_instance.mesh = null


## webxr_feature_provider contract, collected by webxr_bootstrap.gd before
## the session request. Depth sensing is an AR capability on today's
## browsers; requesting it in VR buys nothing.
func get_webxr_required_features(_session_mode: String) -> PackedStringArray:
	return PackedStringArray()

func get_webxr_optional_features(session_mode: String) -> PackedStringArray:
	if session_mode == WebXRFeatures.MODE_AR:
		return PackedStringArray([WebXRFeatures.DEPTH_SENSING])
	return PackedStringArray()

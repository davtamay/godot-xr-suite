shader_type spatial;
// Runtime-neutral per-object soft occlusion material.
//
// A selected depth provider pushes a two-eye environment-depth texture and
// camera positions into this material. The shader does not depend on WebXR or
// OpenXR APIs, so it belongs to the shared scene-understanding contract.
render_mode cull_back, depth_draw_opaque;

uniform sampler2DArray env_depth : filter_linear, hint_default_black;
uniform vec2 env_size = vec2(128.0, 96.0);
uniform float occ_enabled = 0.0;
// CPU/WebGL grids use the historical flip; normalized WebGPU grids are top-left.
uniform float depth_uv_flip_y = 1.0;
uniform float depth_world_scale = 1.0;
uniform vec3 eye0_pos = vec3(0.0);
uniform vec3 eye1_pos = vec3(0.0);
// 0 = projection off-centre sign; 1 = nearest actual eye position.
uniform float eye_select = 0.0;

uniform vec4 albedo : source_color = vec4(1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.45;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float softness : hint_range(0.0, 1.0) = 0.0;

varying float v_depth;

void vertex() {
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	ALBEDO = albedo.rgb;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	if (occ_enabled > 0.5) {
		vec2 uv = vec2(SCREEN_UV.x, mix(SCREEN_UV.y, 1.0 - SCREEN_UV.y, depth_uv_flip_y));
		float layer;
		if (eye_select > 0.5) {
			vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;
			layer = (distance(cam_pos, eye0_pos) <= distance(cam_pos, eye1_pos)) ? 0.0 : 1.0;
		} else {
			layer = (PROJECTION_MATRIX[2].x < 0.0) ? 0.0 : 1.0;
		}
		vec2 texel = mix(0.15, 3.0, softness) / env_size;
		float margin = mix(0.006, 0.1, softness);
		float occ = 0.0;
		float total = 0.0;
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				float rm = texture(
					env_depth,
					vec3(uv + vec2(float(dx), float(dy)) * texel, layer)
				).r * depth_world_scale;
				if (rm > 0.05) {
					total += 1.0;
					occ += 1.0 - smoothstep(-margin, margin, rm - v_depth);
				}
			}
		}
		if (total > 0.0) {
			ALPHA = clamp(1.0 - occ / total, 0.0, 1.0);
		}
	}
}

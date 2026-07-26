@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_interactor_line_visual.svg")
class_name XRInteractorLineVisual
extends MeshInstance3D

## Straight-line beam for an XRRayInteractor parent. Draws in world space
## (top_level), so the interactor's transform never bends the visual.

## Preloaded so the shader baker can precompile it for web/WebGPU exports
## (runtime-constructed materials cannot be baked). Tinting a duplicate only
## changes uniforms, so the baked shader still matches.
const LINE_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_line_material.tres")

@export var color := Color(0.7, 0.88, 1.0, 0.85)

var _ray: Node
var _line_mesh := ImmediateMesh.new()

func _ready() -> void:
    _ray = get_parent()
    if _ray == null or not _ray.has_method("get_ray_state"):
        _ray = null
        push_warning("%s: parent does not provide get_ray_state()." % name)
    mesh = _line_mesh
    top_level = true
    cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

    var material := LINE_MATERIAL.duplicate() as StandardMaterial3D
    material.albedo_color = color
    material_override = material

func _process(_delta: float) -> void:
    _line_mesh.clear_surfaces()
    var state: Dictionary = _ray.get_ray_state() if _ray else {}
    if not state.get("valid", false):
        visible = false
        return

    # The old grip_latched hide is gone: it could never be observed true (the
    # ray state's own valid=false branch already fires first once latched)
    # and it duplicated xr_ray_interactor.gd's hide_ray_when_held_within,
    # which hides this beam by comparing the held object's actual position
    # against the adapter's real grip origin - the "valid" check above
    # already covers both.
    var from_point: Vector3 = state["origin"]
    var to_point: Vector3 = state["end"]
    if from_point.distance_squared_to(to_point) < 0.000001:
        visible = false
        return

    visible = true
    global_transform = Transform3D.IDENTITY
    _line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
    _line_mesh.surface_add_vertex(from_point)
    _line_mesh.surface_add_vertex(to_point)
    _line_mesh.surface_end()

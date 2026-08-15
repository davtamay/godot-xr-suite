class_name WebXRFeatures
extends RefCounted

## The WebXR feature descriptor strings this suite requests, in one place.
##
## Feature names are part of the WebXR specification and are spelled into
## requestSession(); a typo or a rename is not an error, it is a feature the
## browser silently does not grant. Every provider and every consumer names
## them from here so a spec rename is one edit, and so the capability
## manifest cannot drift from the providers it advertises.
##
## See https://immersive-web.github.io/webxr/#feature-descriptor

## Reference spaces, requested as features as well as space types.
const LOCAL := "local"
const LOCAL_FLOOR := "local-floor"
const BOUNDED_FLOOR := "bounded-floor"
const UNBOUNDED := "unbounded"

## Input.
const HAND_TRACKING := "hand-tracking"

## Real-world understanding.
const DEPTH_SENSING := "depth-sensing"
const MESH_DETECTION := "mesh-detection"
const PLANE_DETECTION := "plane-detection"
const HIT_TEST := "hit-test"
const ANCHORS := "anchors"
const LIGHT_ESTIMATION := "light-estimation"

## Compositor.
const LAYERS := "layers"
const SECONDARY_VIEWS := "secondary-views"

## Renderer binding (fork-only: the WebGPU binding needs the session to be
## created against a WebGPU-capable adapter).
const WEBGPU := "webgpu"

## Session modes, which are not features but are spelled just as often.
const MODE_VR := "immersive-vr"
const MODE_AR := "immersive-ar"
const MODE_INLINE := "inline"

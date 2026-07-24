class_name XRHandPoseSource
extends RefCounted

## Acquisition seam for WebXR, OpenXR, replay files, simulated hands, or a
## future native provider. Recognition code never references a runtime API.

func capture(_hand: int, _timestamp_usec: int, _target: XRHandFrame) -> bool:
    return false

## True exactly once after a tracking discontinuity (first acquisition, or
## recovery from a dropout). Decorators above reset their state on it rather
## than slewing from a stale pose. Sources with no notion of continuity return
## false forever, which is the correct default.
func consume_discontinuity(_hand: int) -> bool:
    return false

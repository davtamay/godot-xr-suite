@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg")
class_name XRPokeProfile
extends Resource

## One resource carrying the whole POKE FEEL of a project: how deep a press
## is, how far it re-arms, and how strictly arming is gated on approach.
## Assign it to any poke target (XRPokeable, XRUICanvasInteractable,
## XRPokeButton) and every one of them moves together - the same pattern
## XRFeedbackTheme uses for scene-wide interaction feedback.
##
## PRECEDENCE: an assigned profile WINS. The node's own exports are the
## fallback, used only while poke_profile is null. Godot cannot distinguish an
## export left at its default from one deliberately set to that value, so
## per-property override would silently ignore the profile whenever the two
## happened to match.

@export_group("Depth")
## How close (metres) the poke point must come to the surface to press, and
## how far it must retract to re-arm. The gap between them is the hysteresis
## that stops flicker at the boundary.
@export_range(0.001, 0.1, 0.001) var press_depth := 0.012
@export_range(0.005, 0.2, 0.001) var release_depth := 0.04

@export_group("Approach Gate")
## Require the point to have been seen in front of the face before it can
## press. Stops a hand sweeping sideways across a row of buttons from pressing
## each one it crosses. Turn OFF (with max_approach_angle at 90) to restore
## pre-gate behaviour exactly.
@export var require_entry_through_face := true
## Travel over the sample window must point inward within this angle. 90
## accepts any inward motion; 0 accepts only a perfectly axial approach.
@export_range(0.0, 90.0, 1.0) var max_approach_angle := 60.0
## Below this window displacement (metres) the direction is noise and the
## angle test abstains. Do not set to 0: a slow, deliberate creep-in would
## then be rejected on jitter alone.
@export_range(0.0, 0.02, 0.0005) var min_approach_travel := 0.003

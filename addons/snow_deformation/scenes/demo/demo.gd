# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
extends Node3D
## Demo for the snow_deformation addon: walk to leave footprints, shove the balls to plough troughs.
##
## Everything structural is wired in demo.tscn. This script only does the things a node cannot:
## the debug keys, the snowfall refill and the readout.

## Refill rates F3 turns on, at full precipitation: geometry in metres per second, mask in units per
## second. Scaled by how hard it is actually snowing, so a blizzard fills tracks in and a clear sky
## leaves them alone.
const REFILL_GEO: float = 0.02
const REFILL_MASK: float = 0.06
## F4's waist-deep snow, the depth of Red Dead Redemption 2's opening: up to the mannequin's hips, so the legs
## plough a trench rather than leave prints.
const DEEP_SNOW: float = 0.95

@export var snow: SnowDeformation
@export var readout: Label
## Optional. When present, F3's refill is driven by how hard it is snowing. The addon knows nothing
## about Weather FX; tying the two together is this demo's job, so either can be used without the other.
@export var weather: Node

var _refilling: bool = false
## The scene's own depth, which F4 goes back to.
var _normal_depth: float = -1.0


func _process(_delta: float) -> void:
	_apply_refill()
	_update_readout()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_F1:
				snow.debug_overlay = not snow.debug_overlay
			KEY_F2:
				snow.clear()
			KEY_F3:
				_refilling = not _refilling
				_apply_refill()
			KEY_F4:
				if _normal_depth < 0.0:
					_normal_depth = snow.snow_depth
				snow.snow_depth = _normal_depth if is_equal_approx(snow.snow_depth, DEEP_SNOW) else DEEP_SNOW


## How hard it is snowing, 0 to 1. Everything works without Weather FX in the scene; then it is simply
## always snowing as hard as it can, which is what a refill with nothing to scale it should mean.
func _precipitation() -> float:
	if weather == null or not is_instance_valid(weather):
		return 1.0
	return clampf(weather.get(&"active_precipitation_strength") as float, 0.0, 1.0)


## Snowfall filling the tracks back in. Re-read every frame, because the storm rises and falls.
func _apply_refill() -> void:
	if snow == null:
		return
	var fall: float = _precipitation() if _refilling else 0.0
	snow.refill_rate_geo = REFILL_GEO * fall
	snow.refill_rate_mask = REFILL_MASK * fall


func _update_readout() -> void:
	if readout == null or snow == null:
		return
	var status: String = "compute passes running" if snow.enabled else "DISABLED: no RenderingDevice, snow is flat"
	readout.text = "\n".join([
		"Snow deformation: %s" % status,
		"%d x %d texels over %.0f m  (%.1f cm per texel)" % [snow.resolution, snow.resolution, snow.world_size, snow.world_size / float(snow.resolution) * 100.0],
		"stamps this frame: %d    dropped: %d" % [snow.stamps_last_frame, snow.dropped_stamps],
		"refill from snowfall: %s" % ("%.0f%%" % (_precipitation() * 100.0) if _refilling else "off"),
		"snow depth: %.0f cm" % (snow.snow_depth * 100.0),
		"",
		"F1 overlay    F2 clear    F3 refill    F4 waist-deep snow",
	])

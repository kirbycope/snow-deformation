# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
extends Node3D
## Demo for the snow_deformation addon: walk to leave footprints, swing to gouge a trench.
##
## Everything structural is wired in demo.tscn. This script only does the things a node cannot:
## the scripted sword arc, the debug keys, and the readout.

## How long one swing takes. Short on purpose: a fast blade is what proves the sweep is substepped
## rather than stamped once per frame.
const SWING_SECONDS: float = 0.3
## The arc, in degrees about the sword pivot's X axis. Starts raised, finishes just past straight down,
## which carries the tip well below the snow's surface.
const SWING_FROM: float = 80.0
const SWING_TO: float = -95.0
## Where the sword rests between swings.
const SWORD_IDLE_ANGLE: float = 35.0
## Refill rates F3 turns on, at full precipitation: geometry in metres per second, mask in units per
## second. Scaled by how hard it is actually snowing, so a blizzard fills tracks in and a clear sky
## leaves them alone.
const REFILL_GEO: float = 0.02
const REFILL_MASK: float = 0.06

@export var snow: SnowDeformation
@export var player: CharacterBody3D
@export var sword: Node3D
@export var readout: Label
## Optional. When present, F3's refill is driven by how hard it is snowing. The addon knows nothing
## about Weather FX; tying the two together is this demo's job, so either can be used without the other.
@export var weather: Node

## Seconds into the current swing, or -1 when the sword is at rest.
var _swing_time: float = -1.0
var _skeleton: Skeleton3D = null
var _hand_bone: int = -1
var _refilling: bool = false


func _ready() -> void:
	if player != null:
		_skeleton = player.get_node_or_null("PlayerModel/Armature/GeneralSkeleton") as Skeleton3D
		if _skeleton != null:
			_hand_bone = _skeleton.find_bone(&"RightHand")
	_rest_sword()


func _process(delta: float) -> void:
	_carry_sword()
	_apply_refill()
	if _swing_time >= 0.0:
		_swing_time += delta
		var t: float = _swing_time / SWING_SECONDS
		if t >= 1.0:
			_swing_time = -1.0
			_rest_sword()
		else:
			# Eased so the blade is at its fastest through the bottom of the arc, which is where it is
			# in the snow and where a naive once-per-frame stamp would leave gaps.
			var eased: float = ease(t, 2.2)
			sword.rotation.x = deg_to_rad(lerpf(SWING_FROM, SWING_TO, eased))
	_update_readout()


## _input rather than _unhandled_input: the player's HUD puts a crosshair Control over the screen, and
## it consumes the mouse button before anything unhandled is reached.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var click: InputEventMouseButton = event as InputEventMouseButton
		if click.pressed and click.button_index == MOUSE_BUTTON_LEFT and _swing_time < 0.0:
			_swing_time = 0.0
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_F1:
				snow.debug_overlay = not snow.debug_overlay
			KEY_F2:
				snow.clear()
			KEY_F3:
				_refilling = not _refilling
				_apply_refill()


## Keeps the sword in the player's right hand without inheriting the hand bone's own basis, so the arc
## below stays in the player's frame and is the same every swing whatever the animation is doing.
func _carry_sword() -> void:
	if sword == null or _skeleton == null or _hand_bone < 0:
		return
	var hand: Vector3 = (_skeleton.global_transform * _skeleton.get_bone_global_pose(_hand_bone)).origin
	sword.global_position = hand


func _rest_sword() -> void:
	if sword != null:
		sword.rotation.x = deg_to_rad(SWORD_IDLE_ANGLE)


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
		"",
		"WASD walk    Left click swing    F1 overlay    F2 clear    F3 refill",
	])

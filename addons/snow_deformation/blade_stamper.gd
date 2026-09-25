# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
@icon("res://addons/snow_deformation/assets/icons/blade_stamper_icon.svg")
class_name BladeStamper
extends Node
## Cuts a continuous gouge in the snow along whatever a blade swept through since the last frame.
##
## Add it to a weapon and mark the blade with two nodes, one at the base and one at the tip. A sword
## swing covers metres in a couple of frames, so stamping the blade where it happens to be each frame
## would leave a dotted line. This walks the sweep in substeps fine enough that the capsules overlap.
##
## Only the part of the blade below the snow's top surface is stamped, so a blade held overhead or
## swung through the air leaves nothing.

@export_group("Blade")
## A node at the hilt end of the cutting edge. Left empty, the parent is used.
@export var base_marker: NodePath = NodePath()
## A node at the point. Left empty, nothing is stamped and the node warns.
@export var tip_marker: NodePath = NodePath()
## Half the thickness of the gouge the blade cuts, in metres.
@export_range(0.005, 0.2, 0.005) var blade_radius: float = 0.03

@export_group("Sweep")
## Ceiling on capsules emitted for one frame's sweep. The manager has its own per-frame cap as well.
@export_range(1, 64, 1) var max_substeps: int = 16
## How far apart substeps may be, as a fraction of [member blade_radius]. Smaller overlaps more.
@export_range(0.1, 2.0, 0.05) var substep_fraction: float = 0.5
## How high the berm along a gouge stands, as a fraction of its depth.
@export_range(0.0, 1.0, 0.01) var rim_factor: float = 0.3
## Gouges shallower than this are not worth a stamp.
@export_range(0.0, 0.1, 0.001) var min_depth: float = 0.005

## Turn stamping off without removing the node. Re-enabling it skips one frame, so a weapon that was
## sheathed somewhere else does not carve a line across the level on its way back.
@export var active: bool = true:
	set(value):
		active = value
		_has_previous = false

var _snow: SnowDeformation = null
var _base: Node3D = null
var _tip: Node3D = null
var _previous_base: Vector3 = Vector3.ZERO
var _previous_tip: Vector3 = Vector3.ZERO
## False for the first frame after enabling, so there is no sweep from the origin.
var _has_previous: bool = false


func _ready() -> void:
	_snow = SnowDeformation.find(self)
	_base = get_node_or_null(base_marker) as Node3D
	if _base == null:
		_base = get_parent() as Node3D
	_tip = get_node_or_null(tip_marker) as Node3D
	if _tip == null:
		push_warning("BladeStamper on %s has no tip_marker, so it will cut nothing." % name)
	if _snow == null:
		push_warning("BladeStamper on %s found no SnowDeformation in the level." % name)


func _physics_process(_delta: float) -> void:
	if not active or _snow == null or not is_instance_valid(_snow):
		return
	if _base == null or _tip == null or not is_instance_valid(_base) or not is_instance_valid(_tip):
		return
	var base: Vector3 = _base.global_position
	var tip: Vector3 = _tip.global_position
	if not _has_previous:
		_previous_base = base
		_previous_tip = tip
		_has_previous = true
		return

	# Enough substeps that consecutive capsules overlap, judged by whichever end moved further.
	var travel: float = maxf(base.distance_to(_previous_base), tip.distance_to(_previous_tip))
	var step: float = maxf(blade_radius * substep_fraction, 1e-4)
	var count: int = clampi(ceili(travel / step), 1, max_substeps)
	for i: int in range(1, count + 1):
		var t: float = float(i) / float(count)
		_stamp_blade(_previous_base.lerp(base, t), _previous_tip.lerp(tip, t))

	_previous_base = base
	_previous_tip = tip


## Stamps the part of the blade between [param base] and [param tip] that is under the snow's surface.
func _stamp_blade(base: Vector3, tip: Vector3) -> void:
	var depth_base: float = _snow.get_undeformed_surface_height(Vector2(base.x, base.z)) - base.y
	var depth_tip: float = _snow.get_undeformed_surface_height(Vector2(tip.x, tip.z)) - tip.y
	if depth_base <= 0.0 and depth_tip <= 0.0:
		return # The whole blade is in the air.

	var a: Vector3 = base
	var b: Vector3 = tip
	var depth_a: float = depth_base
	var depth_b: float = depth_tip
	if depth_base <= 0.0 or depth_tip <= 0.0:
		# One end is above the snow: move it to where the blade crosses the surface, so the gouge stops
		# at the snow line instead of being stretched up out of it.
		var crossing: float = depth_base / (depth_base - depth_tip)
		crossing = clampf(crossing, 0.0, 1.0)
		var at: Vector3 = base.lerp(tip, crossing)
		if depth_base > 0.0:
			b = at
			depth_b = 0.0
		else:
			a = at
			depth_a = 0.0

	if maxf(depth_a, depth_b) < min_depth:
		return
	_snow.add_capsule(
		a, b, blade_radius,
		clampf(depth_a, 0.0, _snow.snow_depth),
		clampf(depth_b, 0.0, _snow.snow_depth),
		rim_factor
	)

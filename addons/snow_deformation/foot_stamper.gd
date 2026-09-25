# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
@icon("res://addons/snow_deformation/assets/icons/foot_stamper_icon.svg")
class_name FootStamper
extends Node
## Presses footprints into the snow wherever a character's feet are below the snow's top surface.
##
## Add it under a character. It finds the [SnowDeformation] in the level by itself. Point it at a
## [Skeleton3D] and name the foot bones, or give it [Marker3D] feet instead for a rig-less character.
##
## It emits every physics frame a foot is in contact, on purpose. The manager combines stamps with
## max(), so a planted foot re-stamping the same hole changes nothing, while a sliding one lays down a
## drag mark for free.
##
## For feet to sink at all, the character's own collision has to rest on the ground *underneath* the
## snow rather than on top of it. The snow surface mesh carries no collider, so this is the default.

@export_group("Feet")
## The skeleton the foot bones belong to. Left empty, the first [Skeleton3D] under the parent is used.
@export var skeleton_path: NodePath = NodePath()
## Bones to stamp with. The Godot humanoid profile names them LeftFoot and RightFoot.
@export var foot_bones: Array[StringName] = [&"LeftFoot", &"RightFoot"]
## Feet as plain nodes instead, for a character with no skeleton. Used when [member foot_bones] finds
## nothing.
@export var foot_markers: Array[NodePath] = []
## Which way the toes point in a foot bone's own space. Bones run along their length, and the foot's
## child is the toes, so +Y is right for a Godot-retargeted humanoid.
@export var bone_forward: Vector3 = Vector3.UP

@export_group("Print")
## Half the width of a print, in metres. 6 cm is a boot.
@export_range(0.01, 0.5, 0.005) var half_width: float = 0.06
## Half the length of a print, in metres.
@export_range(0.01, 0.8, 0.005) var half_length: float = 0.14
## How far the sole sits below the bone's origin, which for a foot bone is the ankle.
@export_range(0.0, 0.3, 0.005) var sole_offset: float = 0.08
## How far the middle of the print sits ahead of the ankle.
@export_range(-0.2, 0.3, 0.005) var forward_offset: float = 0.03
## A foot this far above the snow still counts as touching it, which keeps prints continuous through
## the frame a foot lands on.
@export_range(0.0, 0.2, 0.005) var contact_margin: float = 0.02
## Prints shallower than this are not worth a stamp.
@export_range(0.0, 0.1, 0.001) var min_depth: float = 0.005
## How high the berm around a print stands, as a fraction of its depth.
@export_range(0.0, 1.0, 0.01) var rim_factor: float = 0.35

@export_group("Sound")
## Played when a foot comes down into the snow. An [AudioStreamRandomizer] holding several crunches is
## what stops it repeating. Left empty the stamper is silent, so the addon ships no audio of its own.
@export var footstep_sound: AudioStream = null
@export_range(-40.0, 12.0, 0.5, "suffix:dB") var footstep_volume_db: float = -4.0
@export_range(1.0, 60.0, 1.0, "suffix:m") var footstep_max_distance: float = 22.0
## A foot has to sink at least this deep to be heard, so brushing the surface is silent.
@export_range(0.0, 0.5, 0.01, "suffix:m") var footstep_min_depth: float = 0.05

## Stamping can be turned off without removing the node, for a character that has just been teleported.
@export var active: bool = true

var _snow: SnowDeformation = null
var _skeleton: Skeleton3D = null
## Resolved bone indices, parallel to the names that resolved. Empty means the markers are in use.
var _bone_indices: PackedInt32Array = PackedInt32Array()
var _markers: Array[Node3D] = []
## One player per foot, so two feet landing together are heard as two steps rather than one cut short.
var _voices: Array[AudioStreamPlayer3D] = []
## Whether each foot was in the snow last frame. A step is heard on the way in, not every frame it
## stays there, which is the difference between walking and a held note.
var _was_down: Array[bool] = []


func _ready() -> void:
	_snow = SnowDeformation.find(self)
	_resolve_feet()
	if _snow == null:
		push_warning("FootStamper on %s found no SnowDeformation in the level, so it will leave no prints." % get_parent().name)


func _physics_process(_delta: float) -> void:
	if not active or _snow == null or not is_instance_valid(_snow):
		return
	if not _bone_indices.is_empty():
		_stamp_bones()
	else:
		_stamp_markers()


## Footprints from skeleton bones. Yaw comes from the bone's own basis, so a turning foot turns its print.
func _stamp_bones() -> void:
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	for foot: int in _bone_indices.size():
		var pose: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(_bone_indices[foot])
		var forward: Vector3 = (pose.basis * bone_forward)
		forward.y = 0.0
		if forward.length_squared() < 1e-8:
			forward = Vector3(0.0, 0.0, 1.0)
		forward = forward.normalized()
		_stamp(pose.origin, forward.normalized(), foot)


## Footprints from plain marker nodes, for a character animated without a skeleton.
func _stamp_markers() -> void:
	for foot: int in _markers.size():
		var marker: Node3D = _markers[foot]
		if not is_instance_valid(marker):
			continue
		var forward: Vector3 = -marker.global_basis.z
		forward.y = 0.0
		if forward.length_squared() < 1e-8:
			forward = Vector3(0.0, 0.0, 1.0)
		_stamp(marker.global_position, forward.normalized(), foot)


## One print, if this foot is actually in the snow. [param forward] points at the toes and is flat, and
## [param foot] is which foot it is, so each keeps its own contact state and its own voice.
func _stamp(ankle: Vector3, forward: Vector3, foot: int) -> void:
	var centre: Vector3 = ankle + forward * forward_offset
	centre.y = ankle.y - sole_offset
	var xz: Vector2 = Vector2(centre.x, centre.z)
	var top: float = _snow.get_undeformed_surface_height(xz)
	if centre.y >= top + contact_margin:
		_set_down(foot, false)
		return
	var depth: float = clampf(top - centre.y, 0.0, _snow.snow_depth)
	if depth < min_depth:
		_set_down(foot, false)
		return
	if depth >= footstep_min_depth:
		# Only on the way in. A planted foot re-stamps its own hole every frame, and a crunch every
		# frame it stood there would be a drone rather than a footstep.
		if _set_down(foot, true):
			_play_step(foot, centre)
	else:
		_set_down(foot, false)
	# The manager's yaw convention: forward is (-sin yaw, cos yaw) in world XZ.
	var yaw: float = atan2(-forward.x, forward.z)
	_snow.add_footprint(centre, yaw, half_width, half_length, depth, rim_factor)


## Records whether a foot is in the snow and returns true only on the frame it arrives.
func _set_down(foot: int, down: bool) -> bool:
	while _was_down.size() <= foot:
		_was_down.append(false)
	var landed: bool = down and not _was_down[foot]
	_was_down[foot] = down
	return landed


## The crunch, at the foot rather than at the character, so a step is heard where it was taken.
func _play_step(foot: int, at: Vector3) -> void:
	if footstep_sound == null:
		return
	while _voices.size() <= foot:
		var voice: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		voice.name = "StepVoice%d" % _voices.size()
		voice.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") >= 0 else &"Master"
		add_child(voice)
		_voices.append(voice)
	var player: AudioStreamPlayer3D = _voices[foot]
	player.stream = footstep_sound
	player.volume_db = footstep_volume_db
	player.max_distance = footstep_max_distance
	player.global_position = at
	player.play()


func _resolve_feet() -> void:
	_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if _skeleton == null:
		_skeleton = _first_skeleton(get_parent())
	if _skeleton != null:
		for name: StringName in foot_bones:
			var index: int = _skeleton.find_bone(name)
			if index >= 0:
				_bone_indices.append(index)
			else:
				push_warning("FootStamper: %s has no bone named %s." % [_skeleton.name, name])
	if not _bone_indices.is_empty():
		return
	for path: NodePath in foot_markers:
		var marker: Node3D = get_node_or_null(path) as Node3D
		if marker != null:
			_markers.append(marker)
	if _markers.is_empty():
		push_warning("FootStamper on %s resolved no feet: give it foot bones on a Skeleton3D, or foot_markers." % get_parent().name)


## Depth-first search for a skeleton, so the node works wherever under the character it is placed.
func _first_skeleton(from: Node) -> Skeleton3D:
	if from == null:
		return null
	if from is Skeleton3D:
		return from as Skeleton3D
	for child: Node in from.get_children():
		var found: Skeleton3D = _first_skeleton(child)
		if found != null:
			return found
	return null

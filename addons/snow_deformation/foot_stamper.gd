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
## In deep snow the legs plough as well: [member leg_bones] names bone pairs pressed as capsules
## wherever they are under the surface, so a character wading through snow up to the thigh cuts a trench
## rather than a line of post holes. A foot moving through the snow throws clumps of it forward
## ([method SnowDeformation.kick]).
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

@export_group("Legs")
## Pairs of bones, each pair one segment of a leg, pressed into the snow as a capsule wherever it is below the
## surface. The humanoid default is thigh and shin on both sides. A pair naming a bone the skeleton lacks is
## skipped, so a horse or a rig with other names simply leaves prints.
@export var leg_bones: Array[StringName] = [
	&"LeftUpperLeg", &"LeftLowerLeg", &"LeftLowerLeg", &"LeftFoot",
	&"RightUpperLeg", &"RightLowerLeg", &"RightLowerLeg", &"RightFoot",
]
## Half the thickness of a leg, and of the trench it cuts.
@export_range(0.02, 0.3, 0.005, "suffix:m") var leg_radius: float = 0.12
## How far in from its edge a leg's cut reaches full depth, as a fraction of its radius: 0 is a sheer wall, 1 a V.
## Deep snow slumps back into the hole behind a leg, so its walls slope.
@export_range(0.0, 1.0, 0.01) var leg_wall_softness: float = 0.65
## The two bones either side of the pelvis. A wide capsule between them pushes the top of the snow aside once it
## is up to the hips, which is what makes a wading trench as wide as the body rather than the legs.
@export var hip_bones: Array[StringName] = [&"LeftUpperLeg", &"RightUpperLeg"]
## Half the width of that push, beyond the hip joints.
@export_range(0.05, 0.6, 0.01, "suffix:m") var hip_radius: float = 0.24

@export_group("Wading")
## Fraction of normal speed left when the snow is up to the hips; set on the character's
## [code]terrain_speed_scale[/code] when it has one (the player controller's Player does).
@export_range(0.05, 1.0, 0.01) var wading_speed: float = 0.4
## Snow this deep, as a fraction of hip height, starts to slow the character: about the knee.
@export_range(0.0, 1.0, 0.01) var wading_starts: float = 0.5

@export_group("Kicked snow")
## Clumps a foot throws per metre it moves through the snow.
@export_range(0.0, 100.0, 1.0) var kick_per_metre: float = 14.0
## A foot slower than this throws nothing: standing still, or shuffling.
@export_range(0.0, 5.0, 0.05, "suffix:m/s") var kick_min_speed: float = 0.8
## How much of the foot's own speed the clumps leave with.
@export_range(0.0, 2.0, 0.05) var kick_speed_factor: float = 0.8

@export_group("Sound")
## Played when a foot comes down into the snow. An [AudioStreamRandomizer] holding several crunches is
## what stops it repeating. Left empty the stamper is silent, so the addon ships no audio of its own. A character with
## a [code]footstep_override[/code] property (the player controller's Player) plays it instead, from its own steps,
## while it stands in snow, so its own footsteps and this crunch never sound together; the stamper then plays none.
@export var footstep_sound: AudioStream = null
@export_range(-40.0, 12.0, 0.5, "suffix:dB") var footstep_volume_db: float = -4.0
@export_range(1.0, 60.0, 1.0, "suffix:m") var footstep_max_distance: float = 22.0
## A foot has to sink at least this deep to be heard, so brushing the surface is silent.
@export_range(0.0, 0.5, 0.01, "suffix:m") var footstep_min_depth: float = 0.05

@export_group("Surfing")
## The character's property that is true while it surfs down the snow on a shield or a board. It is read by name, so
## the character needs nothing from this addon; the player controller's Player calls it is_shield_surfing. While it
## is true the feet leave no prints and the board cuts a groove instead.
@export var surfing_property: StringName = &"is_shield_surfing"
## Width and length of what is surfed on, in metres. A shield is about half a metre across.
@export var board_size: Vector2 = Vector2(0.5, 0.75)
## How much deeper than the board's underside its groove is pressed, so a board skimming the top still marks it.
@export_range(0.0, 0.2, 0.005, "suffix:m") var board_groove: float = 0.02
## While surfing, the character rides the packed-snow floor ([member SnowDeformation.floor_layer]) instead of the
## ground under the snow, so it skims the top of the snow as a snowball rolls on it, and is lifted onto it as it
## starts. Off, it ploughs through on the ground, and its groove is as deep as the snow.
@export var ride_snow_while_surfing: bool = true
## Clumps the board throws up behind it per metre it surfs.
@export_range(0.0, 100.0, 1.0) var spray_per_metre: float = 20.0

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
## Resolved leg segments, two bone indices each.
var _leg_indices: PackedInt32Array = PackedInt32Array()
var _hip_indices: PackedInt32Array = PackedInt32Array()
## Where each foot was last frame, for its speed, and the clumps it owes, carried between frames.
var _last_ankle: Array[Vector3] = []
var _kick_owed: Array[float] = []
var _dt: float = 1.0 / 60.0
## Whether the character was surfing last frame, whether this node gave it the floor layer to ride, where the board
## was last frame (INF when it was not on the snow) and the spray it owes.
var _surfing: bool = false
var _gave_floor: bool = false
var _last_board: Vector3 = Vector3.INF
var _spray_owed: float = 0.0


func _ready() -> void:
	_snow = SnowDeformation.find(self)
	_resolve_feet()
	if _snow == null:
		push_warning("FootStamper on %s found no SnowDeformation in the level, so it will leave no prints." % get_parent().name)


func _exit_tree() -> void:
	var character: Node = get_parent()
	if character != null and "terrain_speed_scale" in character:
		character.set(&"terrain_speed_scale", 1.0) # Out of the snow's hands, back to normal going.
	if _gave_floor and character is CollisionObject3D and _snow != null and is_instance_valid(_snow):
		(character as CollisionObject3D).collision_mask &= ~_snow.floor_layer # nor still riding the snow it gave
		_gave_floor = false


func _physics_process(delta: float) -> void:
	if not active or _snow == null or not is_instance_valid(_snow):
		return
	_dt = maxf(delta, 1e-4)
	_lend_steps()
	var surfing: bool = is_surfing()
	if surfing != _surfing:
		_set_surfing(surfing)
	if surfing:
		_press_board()
		return
	if not _bone_indices.is_empty():
		_stamp_bones()
		_stamp_legs()
	else:
		_stamp_markers()


## Hands the crunch to a character that plays its own steps ([code]footstep_override[/code]) while it stands in snow
## deep enough to be heard, and takes it back once it is out, on a board, or the snow is too thin.
func _lend_steps() -> void:
	var character: Node3D = get_parent() as Node3D
	if character == null or not "footstep_override" in character:
		return
	var at: Vector3 = character.global_position
	var top: float = _snow.get_undeformed_surface_height(Vector2(at.x, at.z))
	var in_snow: bool = footstep_sound != null and _snow.snow_depth >= footstep_min_depth and at.y <= top + contact_margin 			and not is_surfing()
	var stream: AudioStream = footstep_sound if in_snow else null
	if character.get("footstep_override") != stream:
		character.set("footstep_override", stream)


## True while the character is surfing: its [member surfing_property] is true.
func is_surfing() -> bool:
	var character: Node = get_parent()
	return character != null and surfing_property != &"" and character.get(surfing_property) == true


## Starts or stops surfing. Starting, the character is given the snow's floor layer to ride and lifted onto it if the
## ground under the snow has it below the floor (by its own peer only; the others take its position as it is sent),
## and walks at full speed; stopping takes the floor layer away again, only if this node gave it, so the character
## sinks back to the ground under the snow.
func _set_surfing(on: bool) -> void:
	_surfing = on
	_last_board = Vector3.INF
	var character: Node = get_parent()
	if on and character != null and "terrain_speed_scale" in character:
		character.set(&"terrain_speed_scale", 1.0)
	var body: CollisionObject3D = character as CollisionObject3D
	if body == null or not ride_snow_while_surfing or _snow.floor_layer == 0:
		return
	if on and (body.collision_mask & _snow.floor_layer) == 0:
		body.collision_mask |= _snow.floor_layer
		_gave_floor = true
		var at: Vector3 = body.global_position
		var floor_top: float = _snow.get_floor_height(Vector2(at.x, at.z))
		if body.is_multiplayer_authority() and _snow.floor_covers(Vector2(at.x, at.z)) and at.y < floor_top:
			body.global_position = Vector3(at.x, floor_top, at.z)
	elif not on and _gave_floor:
		body.collision_mask &= ~_snow.floor_layer
		_gave_floor = false


## The board's groove: swept from where the board was last frame to where it is, [member board_size] wide and as deep
## as the board sits in the snow plus [member board_groove], without digging the floor it rides. It throws snow up
## behind it as it goes. Nothing while the character is in the air above the snow.
func _press_board() -> void:
	var body: Node3D = get_parent() as Node3D
	if body == null:
		return
	var at: Vector3 = body.global_position
	var xz: Vector2 = Vector2(at.x, at.z)
	var top: float = _snow.get_undeformed_surface_height(xz)
	# On a slope a character's rounded underside rests uphill of its origin, which floats centimetres above the snow,
	# so a character on the floor is on the snow whatever its origin's height says.
	var character: CharacterBody3D = body as CharacterBody3D
	if at.y > top + contact_margin and not (character != null and character.is_on_floor()):
		_last_board = Vector3.INF
		return
	# The board's underside is on what it rides: the packed floor, or the ground under the snow.
	var rides_floor: bool = character != null and (character.collision_mask & _snow.floor_layer) != 0
	at.y = minf(at.y, _snow.get_floor_height(xz) if rides_floor else _snow.get_terrain_height(xz))
	var from: Vector3 = _last_board if _last_board.is_finite() and _last_board.distance_to(at) < 2.0 else at
	_last_board = at
	var depth: float = clampf(top - at.y + board_groove, 0.0, _snow.snow_depth)
	_snow.add_capsule(from, at, board_size.x * 0.5, depth, depth, rim_factor, 0.3, 0.4, false)
	var moved: Vector3 = Vector3(at.x - from.x, 0.0, at.z - from.z)
	if moved.is_zero_approx():
		return
	var along: Vector3 = moved.normalized()
	# The board's own length, ahead of and behind where the character stands on it.
	var yaw: float = atan2(-along.x, along.z)
	_snow.add_footprint(at, yaw, board_size.x * 0.5, board_size.y * 0.5, depth, rim_factor, 0.3, 0.4, false)
	_spray_owed += moved.length() * spray_per_metre
	var burst: int = maxi(_snow.kick_burst, 1)
	if _spray_owed >= float(burst):
		_spray_owed -= float(burst)
		var tail: Vector3 = at - along * board_size.y * 0.5
		_snow.kick(Vector3(tail.x, top, tail.z), -moved / _dt * kick_speed_factor * 0.5, burst)


## The legs, as capsules clipped to the snow's surface: nothing above it, all of what is under it.
func _stamp_legs() -> void:
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	for i: int in range(0, _leg_indices.size() - 1, 2):
		var a: Vector3 = _bone_position(_leg_indices[i])
		var b: Vector3 = _bone_position(_leg_indices[i + 1])
		_snow.press_segment(a, b, leg_radius, 0.3, leg_wall_softness)
	if _hip_indices.size() == 2:
		var left: Vector3 = _bone_position(_hip_indices[0])
		var right: Vector3 = _bone_position(_hip_indices[1])
		_snow.press_segment(left, right, hip_radius, 0.25, 0.85)
		_wade((left + right) * 0.5)


func _bone_position(index: int) -> Vector3:
	return (_skeleton.global_transform * _skeleton.get_bone_global_pose(index)).origin


## Slows the character in snow above the knee, down to [member wading_speed] at the hips, through the
## character's own [code]terrain_speed_scale[/code] when it has one. Returns the scale it asked for.
func _wade(hips: Vector3) -> float:
	var xz: Vector2 = Vector2(hips.x, hips.z)
	var ground: float = _snow.get_terrain_height(xz)
	var hip_height: float = maxf(hips.y - ground, 0.1)
	var submerged: float = clampf(_snow.snow_depth / hip_height, 0.0, 1.0)
	var scale: float = lerpf(1.0, wading_speed, smoothstep(wading_starts, 1.0, submerged))
	var character: Node = get_parent()
	if character != null and "terrain_speed_scale" in character:
		character.set(&"terrain_speed_scale", scale)
	return scale


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
	_kick(foot, ankle, top)
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


## A foot moving through the snow throws some of it forward, from the surface above it, in proportion to how far
## it went: a stride kicks a spray, a planted foot nothing. Returns how many clumps it threw.
func _kick(foot: int, ankle: Vector3, top: float) -> int:
	while _last_ankle.size() <= foot:
		_last_ankle.append(ankle)
		_kick_owed.append(0.0)
	var moved: Vector3 = ankle - _last_ankle[foot]
	_last_ankle[foot] = ankle
	moved.y = 0.0
	var speed: float = moved.length() / _dt
	if speed < kick_min_speed or speed > 20.0: # Faster than any stride is a teleport.
		return 0
	_kick_owed[foot] += moved.length() * kick_per_metre
	# Thrown a kick at a time, not a clump a frame: a stride throws a spray.
	var burst: int = maxi(_snow.kick_burst, 1)
	if _kick_owed[foot] < float(burst):
		return 0
	_kick_owed[foot] -= float(burst)
	_snow.kick(Vector3(ankle.x, top, ankle.z), moved / _dt * kick_speed_factor, burst)
	return burst


## Records whether a foot is in the snow and returns true only on the frame it arrives.
func _set_down(foot: int, down: bool) -> bool:
	while _was_down.size() <= foot:
		_was_down.append(false)
	var landed: bool = down and not _was_down[foot]
	_was_down[foot] = down
	return landed


## The crunch, at the foot rather than at the character, so a step is heard where it was taken.
func _play_step(foot: int, at: Vector3) -> void:
	if footstep_sound == null or "footstep_override" in get_parent():
		return # a character that plays its own steps has the crunch already
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
	if _skeleton != null:
		for i: int in range(0, leg_bones.size() - 1, 2):
			var upper: int = _skeleton.find_bone(leg_bones[i])
			var lower: int = _skeleton.find_bone(leg_bones[i + 1])
			if upper >= 0 and lower >= 0:
				_leg_indices.append(upper)
				_leg_indices.append(lower)
		if hip_bones.size() == 2:
			var left: int = _skeleton.find_bone(hip_bones[0])
			var right: int = _skeleton.find_bone(hip_bones[1])
			if left >= 0 and right >= 0:
				_hip_indices.append(left)
				_hip_indices.append(right)
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

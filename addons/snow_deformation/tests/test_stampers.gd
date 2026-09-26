extends GutTest
## What the FootStamper decides to cut, and how deep.
##
## The manager below is a recording subclass rather than the real thing, because the real one drops
## every stamp headless (there is no RenderingDevice) and these tests are about the numbers handed to
## it, not about what the GPU then does with them.

const MANAGER: GDScript = preload("res://addons/snow_deformation/snow_deformation.gd")
const FOOT_STAMPER: GDScript = preload("res://addons/snow_deformation/foot_stamper.gd")


## Writes down what it was asked to stamp instead of packing it for a GPU.
class RecordingSnow:
	extends SnowDeformation
	var footprints: Array[Dictionary] = []
	var capsules: Array[Dictionary] = []
	var kicks: Array[Dictionary] = []

	func kick(at: Vector3, velocity: Vector3, clumps: int) -> void:
		kicks.append({"at": at, "velocity": velocity, "clumps": clumps})

	func add_footprint(pos: Vector3, yaw: float, half_width: float, half_length: float, depth: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4, digs_floor: bool = true) -> void:
		footprints.append({"pos": pos, "yaw": yaw, "half_width": half_width, "half_length": half_length, "depth": depth})

	func add_capsule(a: Vector3, b: Vector3, radius: float, depth_a: float, depth_b: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4, digs_floor: bool = true) -> void:
		capsules.append({"a": a, "b": b, "radius": radius, "depth_a": depth_a, "depth_b": depth_b, "wall_softness": wall_softness})


var _snow: RecordingSnow = null


func before_each() -> void:
	_snow = RecordingSnow.new()
	_snow.snow_depth = 0.4
	_snow.create_surface = false
	add_child_autofree(_snow)


#region Feet

func test_a_foot_above_the_snow_leaves_nothing() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	add_child_autofree(stamper)
	stamper.call("_stamp", Vector3(0.0, 2.0, 0.0), Vector3(0.0, 0.0, 1.0), 0)
	assert_eq(_snow.footprints.size(), 0, "A foot two metres up is not touching the snow")


func test_a_foot_in_the_snow_leaves_a_print_as_deep_as_it_has_sunk() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	stamper.sole_offset = 0.0
	stamper.forward_offset = 0.0
	add_child_autofree(stamper)
	# Snow top is 0.4; an ankle at 0.1 has sunk 0.3.
	stamper.call("_stamp", Vector3(0.0, 0.1, 0.0), Vector3(0.0, 0.0, 1.0), 0)
	assert_eq(_snow.footprints.size(), 1, "It leaves one print")
	assert_almost_eq(_snow.footprints[0]["depth"] as float, 0.3, 0.0001, "as deep as the sole is below the undisturbed surface")


func test_a_print_can_never_be_deeper_than_the_snow() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	stamper.sole_offset = 0.0
	stamper.forward_offset = 0.0
	add_child_autofree(stamper)
	stamper.call("_stamp", Vector3(0.0, -5.0, 0.0), Vector3(0.0, 0.0, 1.0), 0)
	assert_almost_eq(_snow.footprints[0]["depth"] as float, _snow.snow_depth, 0.0001, "A foot below the ground still only displaces the snow that is there")


func test_the_sole_offset_is_what_decides_contact_not_the_ankle() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	stamper.sole_offset = 0.08
	stamper.forward_offset = 0.0
	add_child_autofree(stamper)
	stamper.call("_stamp", Vector3(0.0, 0.2, 0.0), Vector3(0.0, 0.0, 1.0), 0)
	assert_almost_eq(_snow.footprints[0]["depth"] as float, 0.28, 0.0001, "The bone is the ankle, so the print is taken 8 cm lower, at the sole")


func test_the_yaw_written_into_a_print_matches_the_shader_convention() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	stamper.sole_offset = 0.0
	stamper.forward_offset = 0.0
	add_child_autofree(stamper)
	# snow_update.glsl rotates a texel by -yaw and treats local +Y as forward, which makes the
	# forward direction (-sin yaw, cos yaw). Round-tripping it has to give the vector back.
	for forward: Vector3 in [Vector3(0.0, 0.0, 1.0), Vector3(1.0, 0.0, 0.0), Vector3(-0.6, 0.0, 0.8).normalized()]:
		_snow.footprints.clear()
		stamper.call("_stamp", Vector3(0.0, 0.1, 0.0), forward, 0)
		var yaw: float = _snow.footprints[0]["yaw"]
		var rebuilt: Vector3 = Vector3(-sin(yaw), 0.0, cos(yaw))
		assert_almost_eq(rebuilt.x, forward.x, 0.0001, "yaw round-trips to the same forward X for %s" % forward)
		assert_almost_eq(rebuilt.z, forward.z, 0.0001, "and the same forward Z for %s" % forward)

#endregion


#region Footstep sound

func test_a_planted_foot_is_heard_once_not_every_frame() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	stamper.sole_offset = 0.0
	stamper.forward_offset = 0.0
	stamper.footstep_sound = AudioStreamRandomizer.new()
	add_child_autofree(stamper)
	# Down into the snow and held there, as a foot is for most of a stance.
	var down: Vector3 = Vector3(0.0, 0.1, 0.0)
	assert_true(stamper.call("_set_down", 0, true), "The frame it arrives is a footfall")
	for i in 30:
		assert_false(stamper.call("_set_down", 0, true), "but standing there is not another one")


func test_lifting_a_foot_arms_the_next_step() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	add_child_autofree(stamper)
	assert_true(stamper.call("_set_down", 0, true), "Down")
	assert_false(stamper.call("_set_down", 0, false), "up is not a step")
	assert_true(stamper.call("_set_down", 0, true), "and down again is the next one")


func test_each_foot_keeps_its_own_step() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	add_child_autofree(stamper)
	assert_true(stamper.call("_set_down", 0, true), "The left foot lands")
	assert_true(stamper.call("_set_down", 1, true), "and the right is its own step, not swallowed by the left")


func test_a_foot_barely_touching_the_surface_is_silent() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	stamper.sole_offset = 0.0
	stamper.forward_offset = 0.0
	stamper.footstep_min_depth = 0.05
	stamper.footstep_sound = AudioStreamRandomizer.new()
	add_child_autofree(stamper)
	# Snow top is 0.4, so a sole at 0.38 has sunk 2 cm: a print, but not a crunch.
	stamper.call("_stamp", Vector3(0.0, 0.38, 0.0), Vector3(0.0, 0.0, 1.0), 0)
	assert_eq(_snow.footprints.size(), 1, "It still leaves a shallow print")
	assert_false((stamper.get("_was_down") as Array)[0], "but it does not count as a footfall, so nothing is heard")


func test_a_stamper_with_no_sound_assigned_stays_silent_and_does_not_break() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	stamper.sole_offset = 0.0
	stamper.forward_offset = 0.0
	add_child_autofree(stamper)
	assert_null(stamper.footstep_sound, "The addon ships no audio of its own")
	stamper.call("_stamp", Vector3(0.0, 0.1, 0.0), Vector3(0.0, 0.0, 1.0), 0)
	assert_eq(_snow.footprints.size(), 1, "and it still cuts prints with nothing to play")
	assert_eq((stamper.get("_voices") as Array).size(), 0, "without building a voice it will never use")

#endregion


#region Kicked snow

func test_a_stride_through_the_snow_kicks_it_forward() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	add_child_autofree(stamper)
	stamper.set("_dt", 1.0 / 60.0)
	var ankle: Vector3 = Vector3(0.0, 0.1, 0.0)
	var thrown: int = 0
	for frame: int in 30: # half a second at 3 m/s, 1.5 m
		ankle.z -= 0.05
		thrown += stamper.call("_kick", 0, ankle, 0.4)
	var owed: float = 1.5 * stamper.kick_per_metre
	assert_between(float(thrown), owed - float(_snow.kick_burst), owed, "kick_per_metre clumps for every metre the foot moved, thrown a kick at a time")
	assert_eq(int(_snow.kicks[0]["clumps"]), _snow.kick_burst, "a whole kick each time")
	var last: Dictionary = _snow.kicks.back()
	assert_almost_eq((last["at"] as Vector3).y, 0.4, 0.001, "thrown from the snow's surface above the foot")
	assert_lt((last["velocity"] as Vector3).z, 0.0, "the way the foot was going")


func test_a_planted_foot_kicks_nothing() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	add_child_autofree(stamper)
	stamper.set("_dt", 1.0 / 60.0)
	for frame: int in 30:
		stamper.call("_kick", 0, Vector3(0.0, 0.1, 0.0), 0.4)
	assert_eq(_snow.kicks.size(), 0, "Standing still throws no snow")


func test_a_teleported_foot_kicks_nothing() -> void:
	var stamper: Node = FOOT_STAMPER.new()
	add_child_autofree(stamper)
	stamper.set("_dt", 1.0 / 60.0)
	stamper.call("_kick", 0, Vector3.ZERO, 0.4)
	assert_eq(stamper.call("_kick", 0, Vector3(30.0, 0.0, 0.0), 0.4), 0, "Thirty metres in a frame is a teleport, not a stride")

#endregion


#region Legs

## A leg straight down under a hip 0.9 m up: thigh to 0.5, shin to 0.1, in snow 0.4 deep.
func _leg() -> Node:
	var body := Node3D.new()
	add_child_autofree(body)
	var skeleton := Skeleton3D.new()
	body.add_child(skeleton)
	var hip: int = skeleton.add_bone("LeftUpperLeg")
	skeleton.set_bone_rest(hip, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.9, 0.0)))
	var knee: int = skeleton.add_bone("LeftLowerLeg")
	skeleton.set_bone_parent(knee, hip)
	skeleton.set_bone_rest(knee, Transform3D(Basis.IDENTITY, Vector3(0.0, -0.4, 0.0)))
	var foot: int = skeleton.add_bone("LeftFoot")
	skeleton.set_bone_parent(foot, knee)
	skeleton.set_bone_rest(foot, Transform3D(Basis.IDENTITY, Vector3(0.0, -0.4, 0.0)))
	skeleton.reset_bone_poses()
	var stamper: Node = FOOT_STAMPER.new()
	var feet: Array[StringName] = [&"LeftFoot"]
	stamper.foot_bones = feet
	body.add_child(stamper)
	return stamper


func test_the_part_of_a_leg_under_the_snow_ploughs_it() -> void:
	var stamper: Node = _leg()
	stamper.leg_radius = 0.05 # thin enough that the thigh's end stays clear of snow 0.4 deep
	stamper.call("_stamp_legs")
	assert_eq(_snow.capsules.size(), 1, "The thigh is clear of the snow; the shin is in it")
	var cut: Dictionary = _snow.capsules[0]
	assert_almost_eq(cut["radius"] as float, stamper.leg_radius, 0.0001, "as thick as the leg")
	var top_end: float = maxf((cut["a"] as Vector3).y, (cut["b"] as Vector3).y)
	assert_lt(top_end, 0.4 + 0.001, "and cut no higher than the surface")


func test_deeper_snow_takes_the_thigh_too() -> void:
	_snow.snow_depth = 0.95
	var stamper: Node = _leg()
	stamper.call("_stamp_legs")
	assert_eq(_snow.capsules.size(), 2, "Waist-deep, the thigh ploughs as well, which is what makes a trench of a stride")


func test_a_leg_cut_slopes_rather_than_drops_sheer() -> void:
	var stamper: Node = _leg()
	stamper.call("_stamp_legs")
	assert_false(_snow.capsules.is_empty())
	assert_almost_eq(_snow.capsules[0]["wall_softness"] as float, stamper.leg_wall_softness, 0.0001, "A leg's cut is laid with the leg's own wall softness")
	assert_gt(stamper.leg_wall_softness, 0.5, "which slopes, since deep snow slumps back behind a leg")

#endregion


#region Wading

## A character with the player controller's terrain_speed_scale, and a FootStamper under it.
func _wader() -> Node:
	var character_script := GDScript.new()
	character_script.source_code = "extends Node3D
var terrain_speed_scale: float = 1.0
"
	character_script.reload()
	var character: Node3D = Node3D.new()
	character.set_script(character_script)
	add_child_autofree(character)
	var stamper: Node = FOOT_STAMPER.new()
	character.add_child(stamper)
	return stamper


func test_snow_below_the_knee_does_not_slow_a_character() -> void:
	var stamper: Node = _wader()
	_snow.snow_depth = 0.35
	assert_eq(stamper.call("_wade", Vector3(0.0, 0.9, 0.0)), 1.0, "Shin-deep, a walk is a walk")
	assert_eq(stamper.get_parent().get("terrain_speed_scale"), 1.0)


func test_snow_to_the_hips_slows_a_character_to_a_wade() -> void:
	var stamper: Node = _wader()
	_snow.snow_depth = 0.95
	stamper.call("_wade", Vector3(0.0, 0.9, 0.0))
	assert_almost_eq(stamper.get_parent().get("terrain_speed_scale") as float, stamper.wading_speed, 0.001, "Hip-deep, the character wades")


func test_leaving_the_snow_gives_the_speed_back() -> void:
	var stamper: Node = _wader()
	_snow.snow_depth = 0.95
	stamper.call("_wade", Vector3(0.0, 0.9, 0.0))
	var character: Node = stamper.get_parent()
	character.remove_child(stamper)
	stamper.free()
	assert_eq(character.get("terrain_speed_scale"), 1.0, "A stamper leaving the character does not leave it wading")

#endregion



#region Surfing

## A character surfing on a shield, as far as the stamper can tell: a body with the flag it reads.
class Surfer:
	extends CharacterBody3D
	var is_shield_surfing: bool = false
	var terrain_speed_scale: float = 1.0


## A surfer with a foot marker under it, standing in snow 0.4 deep.
func _surfer() -> Node:
	var body := Surfer.new()
	add_child_autofree(body)
	body.global_position = Vector3(0.0, 0.1, 0.0)
	var foot := Marker3D.new()
	foot.name = "Foot"
	body.add_child(foot)
	var stamper: Node = FOOT_STAMPER.new()
	stamper.foot_bones = [] as Array[StringName]
	stamper.foot_markers = [NodePath("../Foot")] as Array[NodePath]
	stamper.sole_offset = 0.0
	body.add_child(stamper)
	return stamper


func _slide(stamper: Node, frames: int) -> void:
	var body: Node3D = stamper.get_parent()
	for frame: int in frames:
		body.global_position += Vector3(0.1, 0.0, 0.0) # 6 m/s
		stamper.call("_physics_process", 1.0 / 60.0)


func test_a_surfer_cuts_a_board_wide_groove_and_leaves_no_footprints() -> void:
	var stamper: Node = _surfer()
	stamper.get_parent().set("is_shield_surfing", true)
	stamper.ride_snow_while_surfing = false
	_slide(stamper, 10)
	var feet: Array = _snow.footprints.filter(func(p: Dictionary) -> bool: return (p["half_width"] as float) < stamper.board_size.x * 0.5)
	assert_eq(feet.size(), 0, "Surfing, the feet are on the board and leave no prints")
	assert_gt(_snow.capsules.size(), 5, "the board sweeps a groove")
	assert_almost_eq(_snow.capsules[-1]["radius"] as float, stamper.board_size.x * 0.5, 0.001, "as wide as the board")
	assert_gt(_snow.kicks.size(), 0, "and throws snow up behind it")


func test_the_feet_print_again_once_the_surfing_stops() -> void:
	var stamper: Node = _surfer()
	stamper.get_parent().set("is_shield_surfing", false)
	_slide(stamper, 3)
	assert_gt(_snow.footprints.size(), 0, "Off the board, a foot in the snow prints")


func test_surfing_rides_the_snow_floor_and_gives_it_back() -> void:
	var stamper: Node = _surfer()
	var body: Surfer = stamper.get_parent()
	body.collision_mask = 1
	body.is_shield_surfing = true
	stamper.call("_physics_process", 1.0 / 60.0)
	assert_ne(body.collision_mask & _snow.floor_layer, 0, "Surfing, it rides the packed snow")
	if _snow.floor_covers(Vector2.ZERO):
		assert_gte(body.global_position.y, _snow.get_floor_height(Vector2.ZERO) - 0.001, "lifted onto it from the ground under the snow")
	body.is_shield_surfing = false
	stamper.call("_physics_process", 1.0 / 60.0)
	assert_eq(body.collision_mask, 1, "and gives the layer back once it stops")


func test_a_character_without_the_flag_never_surfs() -> void:
	var body := Node3D.new()
	add_child_autofree(body)
	var stamper: Node = FOOT_STAMPER.new()
	body.add_child(stamper)
	assert_false(stamper.is_surfing(), "Nothing names it surfing, so it walks")

#endregion


#region Steps handed to the character

## A character that plays its own steps, as the player controller's Player does.
class Stepper:
	extends CharacterBody3D
	var footstep_override: AudioStream = null


func _stepper(height: float) -> Node:
	var body := Stepper.new()
	add_child_autofree(body)
	body.global_position = Vector3(0.0, height, 0.0)
	var stamper: Node = FOOT_STAMPER.new()
	stamper.foot_bones = [] as Array[StringName]
	stamper.footstep_sound = AudioStreamWAV.new()
	body.add_child(stamper)
	return stamper


func test_a_character_in_snow_is_lent_the_crunch() -> void:
	var stamper: Node = _stepper(0.1)
	stamper.call("_physics_process", 1.0 / 60.0)
	assert_eq(stamper.get_parent().get("footstep_override"), stamper.footstep_sound, "Standing in snow, its steps crunch")
	stamper.get_parent().global_position.y = 3.0
	stamper.call("_physics_process", 1.0 / 60.0)
	assert_null(stamper.get_parent().get("footstep_override"), "and out of it, they are its own again")


func test_the_stamper_stays_quiet_for_a_character_that_steps_for_itself() -> void:
	var stamper: Node = _stepper(0.1)
	stamper.call("_play_step", 0, Vector3.ZERO)
	var voices: Array = stamper.get("_voices")
	assert_true(voices.is_empty(), "No crunch of its own, so it never sounds on top of the character's step")

#endregion

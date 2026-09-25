extends GutTest
## What the two stampers decide to cut, and how deep.
##
## The manager below is a recording subclass rather than the real thing, because the real one drops
## every stamp headless (there is no RenderingDevice) and these tests are about the numbers handed to
## it, not about what the GPU then does with them.

const MANAGER: GDScript = preload("res://addons/snow_deformation/snow_deformation.gd")
const FOOT_STAMPER: GDScript = preload("res://addons/snow_deformation/foot_stamper.gd")
const BLADE_STAMPER: GDScript = preload("res://addons/snow_deformation/blade_stamper.gd")


## Writes down what it was asked to stamp instead of packing it for a GPU.
class RecordingSnow:
	extends SnowDeformation
	var footprints: Array[Dictionary] = []
	var capsules: Array[Dictionary] = []

	func add_footprint(pos: Vector3, yaw: float, half_width: float, half_length: float, depth: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4) -> void:
		footprints.append({"pos": pos, "yaw": yaw, "half_width": half_width, "half_length": half_length, "depth": depth})

	func add_capsule(a: Vector3, b: Vector3, radius: float, depth_a: float, depth_b: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4) -> void:
		capsules.append({"a": a, "b": b, "radius": radius, "depth_a": depth_a, "depth_b": depth_b})


var _snow: RecordingSnow = null


func before_each() -> void:
	_snow = RecordingSnow.new()
	_snow.snow_depth = 0.4
	_snow.create_surface = false
	add_child_autofree(_snow)


## A blade stamper wired to two markers a metre apart, both children of the node under test's parent.
func _make_blade() -> Node:
	var holder: Node3D = Node3D.new()
	add_child_autofree(holder)
	var base: Marker3D = Marker3D.new()
	base.name = "Base"
	holder.add_child(base)
	var tip: Marker3D = Marker3D.new()
	tip.name = "Tip"
	holder.add_child(tip)
	var stamper: Node = BLADE_STAMPER.new()
	stamper.base_marker = NodePath("../Base")
	stamper.tip_marker = NodePath("../Tip")
	stamper.blade_radius = 0.03
	holder.add_child(stamper)
	return stamper


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


#region Blade

func test_a_blade_held_clear_of_the_snow_cuts_nothing() -> void:
	var stamper: Node = _make_blade()
	stamper.call("_stamp_blade", Vector3(0.0, 1.5, 0.0), Vector3(1.0, 1.2, 0.0))
	assert_eq(_snow.capsules.size(), 0, "Both ends are above the surface, so there is nothing to cut")


func test_a_buried_blade_cuts_its_whole_length() -> void:
	var stamper: Node = _make_blade()
	stamper.call("_stamp_blade", Vector3(0.0, 0.1, 0.0), Vector3(1.0, 0.2, 0.0))
	assert_eq(_snow.capsules.size(), 1, "One capsule for the whole blade")
	assert_almost_eq(_snow.capsules[0]["depth_a"] as float, 0.3, 0.0001, "as deep as each end is under the surface")
	assert_almost_eq(_snow.capsules[0]["depth_b"] as float, 0.2, 0.0001, "which differs along the blade")


func test_a_half_buried_blade_is_clipped_to_the_snow_line() -> void:
	var stamper: Node = _make_blade()
	# Base 0.4 m above the surface, tip 0.4 m below it: the crossing is exactly halfway.
	stamper.call("_stamp_blade", Vector3(0.0, 0.8, 0.0), Vector3(2.0, 0.0, 0.0))
	assert_eq(_snow.capsules.size(), 1, "It still cuts")
	var a: Vector3 = _snow.capsules[0]["a"]
	assert_almost_eq(a.x, 1.0, 0.001, "but the gouge starts where the blade crosses the surface, not at the hilt")
	assert_almost_eq(a.y, 0.4, 0.001, "which is at the height of the undisturbed snow")
	assert_almost_eq(_snow.capsules[0]["depth_a"] as float, 0.0, 0.001, "so that end has no depth")
	assert_almost_eq(_snow.capsules[0]["depth_b"] as float, 0.4, 0.001, "and the buried end has all of it")


func test_the_first_frame_after_enabling_sweeps_nothing() -> void:
	var stamper: Node = _make_blade()
	stamper._physics_process(0.016)
	assert_eq(_snow.capsules.size(), 0, "There is no previous position yet, so there is no sweep from the origin to here")
	assert_true(stamper.get("_has_previous"), "but there is one from now on")


func test_a_fast_sweep_is_broken_into_overlapping_steps() -> void:
	var stamper: Node = _make_blade()
	var holder: Node3D = stamper.get_parent() as Node3D
	var tip: Node3D = holder.get_node("Tip")
	var base: Node3D = holder.get_node("Base")
	base.position = Vector3(0.0, 0.1, 0.0)
	tip.position = Vector3(0.0, 0.1, -1.0)
	stamper._physics_process(0.016)
	_snow.capsules.clear()

	# 20 cm in a frame: about what the tip of a real swing covers, and far more than the blade is
	# thick, so stamping it once would leave a dotted line rather than a gouge.
	var travel: float = 0.2
	base.position = Vector3(travel, 0.1, 0.0)
	tip.position = Vector3(travel, 0.1, -1.0)
	stamper._physics_process(0.016)

	assert_gt(_snow.capsules.size(), 1, "The sweep is substepped rather than stamped once")
	assert_lte(_snow.capsules.size(), stamper.max_substeps, "and never past the cap")
	var spacing: float = travel / float(_snow.capsules.size())
	assert_lt(spacing, stamper.blade_radius * 2.0, "with the steps closer together than the gouge is wide, so they overlap")


func test_the_substep_count_is_capped_however_fast_the_blade_moves() -> void:
	var stamper: Node = _make_blade()
	var holder: Node3D = stamper.get_parent() as Node3D
	var tip: Node3D = holder.get_node("Tip")
	var base: Node3D = holder.get_node("Base")
	base.position = Vector3(0.0, 0.1, 0.0)
	tip.position = Vector3(0.0, 0.1, -1.0)
	stamper._physics_process(0.016)
	_snow.capsules.clear()

	# A teleport rather than a swing. The cap is what stops one absurd frame filling the whole
	# per-frame stamp budget; the gouge it leaves may have gaps, and that is the intended trade.
	base.position = Vector3(500.0, 0.1, 0.0)
	tip.position = Vector3(500.0, 0.1, -1.0)
	stamper._physics_process(0.016)
	assert_eq(_snow.capsules.size(), stamper.max_substeps, "However far it moved, it costs at most max_substeps capsules")


func test_turning_a_stamper_off_and_on_does_not_drag_a_line_across_the_level() -> void:
	var stamper: Node = _make_blade()
	stamper._physics_process(0.016)
	assert_true(stamper.get("_has_previous"), "It has a previous position while running")
	stamper.active = false
	assert_false(stamper.get("_has_previous"), "and forgets it the moment it is switched off, so re-enabling it elsewhere sweeps nothing")

#endregion

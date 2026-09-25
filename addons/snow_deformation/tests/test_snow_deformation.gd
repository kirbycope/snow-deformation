extends GutTest
## Unit tests for the snow_deformation addon.
##
## These run headless, where [method RenderingServer.get_rendering_device] returns null, so the manager
## disables its compute passes. That is deliberate: it is the same path a project on the Compatibility
## renderer takes, and it has to stay working. Everything tested below is the CPU half, which runs
## either way: stamp packing, the window's snapping and scrolling arithmetic, the height providers, and
## the FootStamper's decisions about when and how deep to cut.

const MANAGER: GDScript = preload("res://addons/snow_deformation/snow_deformation.gd")
const FOOT_STAMPER: GDScript = preload("res://addons/snow_deformation/foot_stamper.gd")

## Tolerance for reading a value back out of a PackedFloat32Array, which stores float32.
const F32: float = 1e-6

var _snow: SnowDeformation = null


func before_each() -> void:
	_snow = MANAGER.new()
	_snow.snow_depth = 0.4
	_snow.world_size = 48.0
	_snow.resolution = 1024
	# No surface mesh: it loads a shader and a 256 by 256 plane that none of these tests look at.
	_snow.create_surface = false
	add_child_autofree(_snow)


#region Graceful disable

func test_it_disables_itself_when_there_is_no_rendering_device() -> void:
	assert_false(_snow.enabled, "Headless has no RenderingDevice, so the compute passes stay off")
	assert_not_null(_snow.get_deform_texture(), "and the Texture2DRD still exists, so a material sampling it is not null")


func test_stamping_while_disabled_is_counted_but_costs_nothing() -> void:
	_snow.add_footprint(Vector3.ZERO, 0.0, 0.06, 0.14, 0.3)
	assert_eq(_snow.stamps_this_frame, 1, "The stamp is counted, so a readout still shows the load")
	assert_eq(_snow.get("_stamps").size(), 0, "but nothing is packed for a GPU that is not there")

#endregion


#region Stamp packing
# The packed floats have to match `struct Stamp` in shaders/snow_update.glsl exactly. Nothing else
# checks that: a field packed in the wrong order still runs, it just carves the wrong shape.

func test_a_footprint_packs_the_sixteen_floats_the_shader_expects() -> void:
	var packed: PackedFloat32Array = _snow.call("_pack", SnowDeformation.SHAPE_ELLIPSE, Vector3(1.0, 2.0, 3.0), Vector3(1.0, 2.0, 3.0), 0.06, 0.14, 0.5, 0.35, 0.3, 0.21, 0.25, 0.4)
	assert_eq(packed.size(), SnowDeformation.STAMP_FLOATS, "One stamp is 16 floats, which is 64 bytes and a std430 stride with no padding")
	assert_eq(Vector3(packed[0], packed[1], packed[2]), Vector3(1.0, 2.0, 3.0), "a.xyz is world point A")
	assert_eq(packed[3], SnowDeformation.SHAPE_ELLIPSE, "a.w is the shape tag")
	# Compared with a tolerance throughout: the buffer is float32, so a float64 literal never matches exactly.
	assert_almost_eq(packed[8], 0.06, F32, "params0.x is the half width")
	assert_almost_eq(packed[9], 0.14, F32, "params0.y is the half length")
	assert_almost_eq(packed[10], 0.5, F32, "params0.z is the yaw")
	assert_almost_eq(packed[11], 0.35, F32, "params0.w is the rim factor")
	assert_almost_eq(packed[12], 0.3, F32, "params1.x is the depth at A")
	assert_almost_eq(packed[13], 0.21, F32, "params1.y is the depth at B")
	assert_almost_eq(packed[14], 0.25, F32, "params1.z is the wall softness")
	assert_almost_eq(packed[15], 0.4, F32, "params1.w is the rim width")


func test_a_capsule_is_tagged_as_one_and_keeps_both_ends() -> void:
	var packed: PackedFloat32Array = _snow.call("_pack", SnowDeformation.SHAPE_CAPSULE, Vector3(1.0, 0.0, 0.0), Vector3(2.0, 0.5, 0.0), 0.03, 0.03, 0.0, 0.3, 0.2, 0.1, 0.25, 0.4)
	assert_eq(packed[3], SnowDeformation.SHAPE_CAPSULE, "a.w marks it as a capsule")
	assert_eq(Vector3(packed[4], packed[5], packed[6]), Vector3(2.0, 0.5, 0.0), "b.xyz is the far end")


func test_a_stamp_can_never_ask_to_dig_deeper_than_the_snow() -> void:
	var packed: PackedFloat32Array = _snow.call("_pack", SnowDeformation.SHAPE_ELLIPSE, Vector3.ZERO, Vector3.ZERO, 0.06, 0.14, 0.0, 0.35, 99.0, -5.0, 0.25, 0.4)
	assert_almost_eq(packed[12], _snow.snow_depth, F32, "A depth past snow_depth is clamped to it, so repeated steps cannot drill through")
	assert_almost_eq(packed[13], 0.0, F32, "and a negative depth is clamped to zero")


func test_a_footprint_is_heel_heavy() -> void:
	var packed: PackedFloat32Array = _snow.call("_pack", SnowDeformation.SHAPE_ELLIPSE, Vector3.ZERO, Vector3.ZERO, 0.06, 0.14, 0.0, 0.35, 0.2, 0.14, 0.25, 0.4)
	assert_lt(packed[13], packed[12], "The toe end is shallower than the heel, which is what makes a print read as a footfall")

#endregion


#region The window

func test_the_undeformed_surface_is_the_ground_plus_the_snow() -> void:
	var flat: SnowTerrainHeightFlat = SnowTerrainHeightFlat.new()
	flat.terrain_y = 2.5
	_snow.terrain_height_provider = flat
	_snow.set("_provider", flat)
	assert_almost_eq(_snow.get_undeformed_surface_height(Vector2(10.0, -4.0)), 2.9, 0.0001, "2.5 m of ground under 0.4 m of snow")
	assert_almost_eq(_snow.get_terrain_height(Vector2(10.0, -4.0)), 2.5, 0.0001, "and the ground alone is what a foot sinks towards")


func test_the_origin_snaps_to_whole_texels() -> void:
	var texel: float = _snow.get("_texel_size")
	assert_almost_eq(texel, 48.0 / 1024.0, 1e-6, "Texel size is coverage over resolution")
	var origin: Vector2 = _snow.get("_origin")
	assert_almost_eq(fmod(origin.x, texel), 0.0, 1e-4, "The window's corner sits on a texel boundary, or tracks shimmer as it moves")
	assert_almost_eq(fmod(origin.y, texel), 0.0, 1e-4, "on both axes")


func test_the_window_only_scrolls_once_the_focus_has_moved_a_whole_texel() -> void:
	var focus: Node3D = Node3D.new()
	add_child_autofree(focus)
	_snow.set("_focus", focus)
	_snow.call("_snap_origin", true)
	_snow.set("_pending_shift", Vector2i.ZERO)

	var texel: float = _snow.get("_texel_size")
	focus.global_position = Vector3(texel * 0.25, 0.0, 0.0)
	assert_false(_snow.call("_snap_origin", false), "A quarter of a texel is not a scroll")

	focus.global_position = Vector3(texel * 4.0, 0.0, 0.0)
	assert_true(_snow.call("_snap_origin", false), "Four texels is")
	assert_eq(_snow.get("_pending_shift"), Vector2i(4, 0), "and the shift handed to the scroll pass is in whole texels")


func test_the_window_tracks_the_focus_in_both_axes() -> void:
	var focus: Node3D = Node3D.new()
	add_child_autofree(focus)
	_snow.set("_focus", focus)
	focus.global_position = Vector3(100.0, 5.0, -60.0)
	_snow.call("_snap_origin", true)
	var origin: Vector2 = _snow.get("_origin")
	var half: float = _snow.world_size * 0.5
	var texel: float = _snow.get("_texel_size")
	assert_almost_eq(origin.x, 100.0 - half, texel, "The window is centred on the focus in X")
	assert_almost_eq(origin.y, -60.0 - half, texel, "and on its Z, which is the texture's Y")

#endregion


#region Multiplayer

func test_the_window_follows_the_player_this_peer_controls() -> void:
	# Two Players in the group, as every peer has in a multiplayer game: one this peer drives and one
	# somebody else does. Centring on the wrong one puts the deformable area around a stranger and
	# leaves this screen's own tracks outside it entirely.
	var mine: Node3D = Node3D.new()
	var theirs: Node3D = Node3D.new()
	theirs.name = "RemotePlayer"
	mine.name = "LocalPlayer"
	add_child_autofree(theirs)
	add_child_autofree(mine)
	theirs.add_to_group(&"Player")
	mine.add_to_group(&"Player")
	# Peer 1 is this one with no network up, so 2 is somebody else's.
	theirs.set_multiplayer_authority(2, true)
	mine.set_multiplayer_authority(1, true)
	# The remote one was added first, so "the first in the group" would pick it.
	_snow.focus_path = NodePath()
	_snow.call("_resolve_focus")
	assert_eq(_snow.get("_focus"), mine, "The window follows the Player this peer has authority over")


func test_an_explicit_focus_still_wins() -> void:
	var chosen: Node3D = Node3D.new()
	chosen.name = "Chosen"
	_snow.add_child(chosen)
	var player: Node3D = Node3D.new()
	add_child_autofree(player)
	player.add_to_group(&"Player")
	_snow.focus_path = NodePath("Chosen")
	_snow.call("_resolve_focus")
	assert_eq(_snow.get("_focus"), chosen, "A focus set in the scene beats any search")


func test_the_deformation_is_never_sent_over_the_network() -> void:
	# The texture is derived on every peer from positions that are already replicated, so it costs no
	# bandwidth at all. If a synchronizer ever appears under this node, that has stopped being true.
	for child: Node in _snow.get_children():
		assert_false(child is MultiplayerSynchronizer, "Nothing about the snow is replicated: each peer derives it")

#endregion


#region Pressing bodies

func test_a_moving_body_presses_the_snow_and_static_scenery_does_not() -> void:
	# autofree rather than new(): a body left unfreed is an orphan and a leaked Jolt RID at exit.
	assert_true(SnowDeformation._moves(autofree(RigidBody3D.new())), "A rigid body presses")
	assert_true(SnowDeformation._moves(autofree(CharacterBody3D.new())), "so does a character")
	assert_true(SnowDeformation._moves(autofree(AnimatableBody3D.new())), "and an animated platform")
	assert_false(SnowDeformation._moves(autofree(StaticBody3D.new())), "The ground and the walls do not: they cleared their own snow when the level was built")


func test_a_body_that_stamps_for_itself_is_left_to_it() -> void:
	var body: CharacterBody3D = CharacterBody3D.new()
	add_child_autofree(body)
	assert_false(SnowDeformation._has_own_stamper(body), "A bare body is pressed as a sphere")
	body.add_child(FOOT_STAMPER.new())
	assert_true(SnowDeformation._has_own_stamper(body), "One with feet of its own is not, or the sphere would bury its own prints")


func test_a_bodys_press_is_measured_from_its_own_shapes() -> void:
	var body: RigidBody3D = RigidBody3D.new()
	var collider: CollisionShape3D = CollisionShape3D.new()
	var ball: SphereShape3D = SphereShape3D.new()
	ball.radius = 0.5
	collider.shape = ball
	body.add_child(collider)
	add_child_autofree(body)
	var measured: Vector2 = SnowDeformation._measure(body, 0.4)
	assert_almost_eq(measured.x, 0.5, 0.001, "It presses as wide as it is")
	assert_almost_eq(measured.y, 0.5, 0.001, "and its underside is a radius below its origin")


func test_a_body_with_no_measurable_shape_falls_back() -> void:
	var body: RigidBody3D = RigidBody3D.new()
	add_child_autofree(body)
	assert_almost_eq(SnowDeformation._measure(body, 0.4).x, 0.4, 0.001, "A body with nothing to measure uses the fallback rather than nothing")


## A sword as the player controller builds one: an AnimatableBody3D whose blade is a long thin box,
## 90 cm along its Z, starting 20 cm past the body's origin at the hilt.
func _sword(at: Transform3D) -> AnimatableBody3D:
	var body: AnimatableBody3D = AnimatableBody3D.new()
	body.sync_to_physics = false # As the player controller's WeaponBody has it, so it moves when told to.
	var collider: CollisionShape3D = CollisionShape3D.new()
	var blade: BoxShape3D = BoxShape3D.new()
	blade.size = Vector3(0.04, 0.147, 0.9)
	collider.shape = blade
	collider.position = Vector3(0.0, 0.0, 0.65)
	body.add_child(collider)
	add_child_autofree(body)
	body.global_transform = at
	return body


func test_a_blade_is_pressed_along_its_length_not_as_a_ball_round_the_hilt() -> void:
	var body: AnimatableBody3D = _sword(Transform3D.IDENTITY)
	var segments: Array[Dictionary] = SnowDeformation._segments(body, 0.4)
	assert_eq(segments.size(), 1, "One shape, one segment")
	var a: Vector3 = segments[0]["a"]
	var b: Vector3 = segments[0]["b"]
	assert_almost_eq(absf(b.z - a.z), 0.9 - 0.147, 0.001, "It runs the length of the blade, less the rounded ends")
	assert_almost_eq((a.z + b.z) * 0.5, 0.65, 0.001, "centred on the blade rather than the hilt")
	assert_almost_eq(segments[0]["radius"] as float, 0.147 * 0.5, 0.001, "as thick as the blade is wide")


func test_a_swing_dipping_the_tip_into_the_snow_cuts() -> void:
	# The case that used to cut nothing: the hilt stays 1 m up, well clear of snow whose top is 0.4 m,
	# while the blade points down and the tip goes below the surface.
	var before: int = _snow.stamps_total
	var hilt_up_tip_down: Transform3D = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(65.0)), Vector3(0.0, 1.0, 0.0))
	var body: AnimatableBody3D = _sword(hilt_up_tip_down)
	assert_true(_snow.call("_press_body", body), "The tip is in the snow, so the swing cuts")
	assert_gt(_snow.stamps_total, before, "and hands the manager something to carve")


func test_a_blade_held_clear_of_the_snow_cuts_nothing() -> void:
	var body: AnimatableBody3D = _sword(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, 0.0)))
	var before: int = _snow.stamps_total
	assert_false(_snow.call("_press_body", body), "Held level at 1.5 m, nothing is in the snow")
	assert_eq(_snow.stamps_total, before, "and nothing is carved")


func test_a_hidden_body_presses_nothing() -> void:
	var down: Basis = Basis(Vector3.RIGHT, deg_to_rad(90.0))
	var body: AnimatableBody3D = _sword(Transform3D(down, Vector3(0.0, 0.9, 0.0)))
	body.hide()
	var before: int = _snow.stamps_total
	assert_false(_snow.call("_press_body", body), "A pickup already taken is hidden, not freed, and cuts nothing")
	assert_eq(_snow.stamps_total, before, "however deep it sits")


func test_a_fast_slash_is_swept_between_frames() -> void:
	var down: Basis = Basis(Vector3.RIGHT, deg_to_rad(90.0)) # Blade pointing straight down.
	var body: AnimatableBody3D = _sword(Transform3D(down, Vector3(0.0, 0.9, 0.0)))
	_snow.call("_press_body", body)
	var before: int = _snow.stamps_total
	body.global_position = Vector3(0.6, 0.9, 0.0) # 60 cm in one physics frame.
	_snow.call("_press_body", body)
	var steps: int = _snow.stamps_total - before
	assert_gt(steps, 1, "A slash that far in one frame is stamped in steps, not once")
	assert_lte(steps, SnowDeformation.MAX_SWEEP_STEPS, "and never past the cap")


func _rolling(mass: float) -> RigidBody3D:
	var body: RigidBody3D = RigidBody3D.new()
	body.mass = mass
	body.gravity_scale = 0.0
	add_child_autofree(body)
	body.linear_velocity = Vector3(4.0, -1.0, 3.0)
	body.angular_velocity = Vector3(0.0, 0.0, -8.0)
	return body


func test_the_snow_holds_back_a_body_ploughing_through_it() -> void:
	var body: RigidBody3D = _rolling(1.0)
	_snow.hold_back(body, 0.5, 0.3, 1.0 / 60.0)
	assert_lt(Vector2(body.linear_velocity.x, body.linear_velocity.z).length(), 5.0, "It is slowed along the ground")
	assert_almost_eq(body.linear_velocity.y, -1.0, 0.0001, "but not stopped from falling")
	assert_lt(absf(body.angular_velocity.z), 8.0, "and its roll slows with it")
	assert_almost_eq(body.linear_velocity.x / body.linear_velocity.z, 4.0 / 3.0, 0.0001, "without being turned aside")


func test_a_light_body_is_stopped_sooner_than_a_heavy_one() -> void:
	var ball: RigidBody3D = _rolling(0.2)
	var boulder: RigidBody3D = _rolling(200.0)
	for i: int in 60:
		_snow.hold_back(ball, 0.5, 0.3, 1.0 / 60.0)
		_snow.hold_back(boulder, 0.5, 0.3, 1.0 / 60.0)
	assert_lt(ball.linear_velocity.x, 0.5, "A second in deep snow all but stops a beach ball")
	assert_gt(boulder.linear_velocity.x, 3.9, "while a boulder ploughs on")


func test_the_drag_never_pushes_a_body_backwards() -> void:
	var feather: RigidBody3D = _rolling(0.001)
	_snow.hold_back(feather, 0.5, 0.4, 1.0 / 60.0)
	assert_gte(feather.linear_velocity.x, 0.0, "However light, the snow only ever stops it")


func test_no_drag_leaves_a_body_alone() -> void:
	_snow.press_drag = 0.0
	var body: RigidBody3D = _rolling(1.0)
	_snow.hold_back(body, 0.5, 0.3, 1.0 / 60.0)
	assert_almost_eq(body.linear_velocity.x, 4.0, 0.0001, "press_drag 0 rolls as though there were no snow")

#endregion


#region Crush sound

func test_a_body_sitting_in_the_snow_makes_no_noise() -> void:
	_snow.press_sound = AudioStreamRandomizer.new()
	var body: RigidBody3D = RigidBody3D.new()
	add_child_autofree(body)
	var at: Vector3 = Vector3(1.0, 0.0, 1.0)
	_snow.call("_crush_heard", body, at)
	var heard: Dictionary = _snow.get("_press_last_heard")
	assert_true(heard.has(body), "The first frame in the snow only marks where it is")
	assert_eq((_snow.get("_press_voices") as Array).size(), 0, "and plays nothing, because resting is not ploughing")
	for i in 20:
		_snow.call("_crush_heard", body, at)
	assert_eq((_snow.get("_press_voices") as Array).size(), 0, "Still nothing while it has not moved")


func test_a_body_ploughing_is_heard_once_per_interval() -> void:
	_snow.press_sound = AudioStreamRandomizer.new()
	_snow.press_sound_interval = 0.5
	var body: RigidBody3D = RigidBody3D.new()
	add_child_autofree(body)
	_snow.call("_crush_heard", body, Vector3.ZERO) # sets the mark
	# Creeping forward in 10 cm steps: nothing until it has covered the interval.
	for i in range(1, 5):
		_snow.call("_crush_heard", body, Vector3(float(i) * 0.1, 0.0, 0.0))
	var marked: Vector3 = (_snow.get("_press_last_heard") as Dictionary)[body]
	assert_almost_eq(marked.x, 0.0, 0.001, "40 cm is not far enough to be worth another crush")
	_snow.call("_crush_heard", body, Vector3(0.6, 0.0, 0.0))
	marked = (_snow.get("_press_last_heard") as Dictionary)[body]
	assert_almost_eq(marked.x, 0.6, 0.001, "60 cm is, and the mark moves to there")


func test_the_crush_voices_are_a_pool_not_one_per_body() -> void:
	_snow.press_sound = AudioStreamRandomizer.new()
	_snow.press_voices = 3
	for i in 8:
		assert_not_null(_snow.call("_press_voice"), "There is always a voice to use")
	assert_eq((_snow.get("_press_voices") as Array).size(), 3, "but only press_voices of them, reused round robin")


func test_leaving_the_snow_forgets_where_a_body_was_last_heard() -> void:
	_snow.press_sound = AudioStreamRandomizer.new()
	var body: RigidBody3D = RigidBody3D.new()
	add_child_autofree(body)
	_snow.call("_crush_heard", body, Vector3.ZERO)
	_snow.call("_on_press_body_exited", body)
	assert_false((_snow.get("_press_last_heard") as Dictionary).has(body), "or a body that comes back much later would be judged against where it left")

#endregion


#region Packed snow floor

func test_the_floor_sits_at_the_snow_surface_less_the_sink() -> void:
	assert_almost_eq(_snow.get_floor_height(Vector2(3.0, -2.0)), 0.4 - _snow.floor_sink, 0.0001, "A body riding on it sinks floor_sink into the snow")


func test_the_floor_is_on_its_own_layer_and_covers_the_window() -> void:
	var floor_body: StaticBody3D = _snow.get_node_or_null("SnowFloor") as StaticBody3D
	assert_not_null(floor_body, "The manager lays a floor")
	assert_eq(floor_body.collision_layer, _snow.floor_layer, "on the floor layer alone, so feet and beach balls still sink through")
	assert_eq(floor_body.collision_mask, 0, "and it watches nothing")
	var holder: CollisionShape3D = floor_body.get_child(0) as CollisionShape3D
	var map: HeightMapShape3D = holder.shape as HeightMapShape3D
	assert_gte(float(map.map_width - 1) * holder.scale.x, _snow.world_size, "It spans the whole window")
	assert_almost_eq(map.map_data[0], _snow.get_floor_height(Vector2.ZERO), 0.0001, "at the floor height")
	assert_true(_snow.is_floor(floor_body), "and the manager can say it is its floor")


func test_no_floor_layer_lays_no_floor() -> void:
	var bare: SnowDeformation = MANAGER.new()
	bare.floor_layer = 0
	bare.create_surface = false
	add_child_autofree(bare)
	assert_null(bare.get_node_or_null("SnowFloor"), "floor_layer 0 turns it off")

#endregion


#region Uneven ground

## Ground rising half a metre for every metre east: a hillside.
class Slope:
	extends SnowTerrainHeight
	func height_at(xz: Vector2) -> float:
		return xz.x * 0.5


func _on_slope() -> SnowDeformation:
	var hill: SnowDeformation = MANAGER.new()
	hill.snow_depth = 0.4
	hill.terrain_height_provider = Slope.new()
	add_child_autofree(hill)
	return hill


func test_the_ground_is_baked_under_the_window() -> void:
	var hill: SnowDeformation = _on_slope()
	var image: Image = hill.bake_ground(Vector2.ZERO)
	var side: int = image.get_width()
	assert_gte(float(side) * hill.ground_cell, hill.world_size, "It covers the whole window")
	var span: float = float(side) * hill.ground_cell
	var west: float = image.get_pixel(0, side / 2).r
	var east: float = image.get_pixel(side - 1, side / 2).r
	assert_almost_eq(east - west, (span - hill.ground_cell) * 0.5, 0.01, "and rises with the hill, texel centre to texel centre")


func test_the_surface_is_laid_over_the_hill() -> void:
	var hill: SnowDeformation = _on_slope()
	await wait_process_frames(2)
	var surface: MeshInstance3D = hill.get_node_or_null("SnowSurface") as MeshInstance3D
	assert_not_null(surface, "There is a surface")
	var material: ShaderMaterial = surface.material_override as ShaderMaterial
	assert_true(material.get_shader_parameter(&"use_heightmap"), "which reads the baked ground")
	assert_not_null(material.get_shader_parameter(&"heightmap"))
	var bounds: AABB = (surface.mesh as PlaneMesh).custom_aabb
	assert_lt(bounds.position.y, -5.0, "and whose bounds reach down the hill")
	assert_gt(bounds.end.y, 5.0, "and up it, so it is not culled on a hillside")


func test_the_surface_tells_the_shader_where_its_edge_is() -> void:
	var flat: SnowDeformation = MANAGER.new()
	add_child_autofree(flat)
	await wait_process_frames(2)
	var surface: MeshInstance3D = flat.get_node("SnowSurface") as MeshInstance3D
	var material: ShaderMaterial = surface.material_override as ShaderMaterial
	assert_almost_eq(material.get_shader_parameter(&"surface_half") as float, flat.surface_size * 0.5, 0.001, "so the snow can thin to nothing at the mesh's edge")
	assert_eq(material.get_shader_parameter(&"surface_edge_taper"), flat.surface_edge_taper)
	assert_eq(material.get_shader_parameter(&"surface_centre"), Vector2(surface.global_position.x, surface.global_position.z))


func test_flat_ground_bakes_nothing() -> void:
	var flat: SnowDeformation = MANAGER.new()
	add_child_autofree(flat)
	await wait_process_frames(2)
	var surface: MeshInstance3D = flat.get_node_or_null("SnowSurface") as MeshInstance3D
	var material: ShaderMaterial = surface.material_override as ShaderMaterial
	assert_ne(material.get_shader_parameter(&"use_heightmap"), true, "A flat level needs no heights, only terrain_y")

#endregion


#region Finding the manager

func test_a_stamper_finds_the_manager_above_it_in_the_tree() -> void:
	var holder: Node3D = Node3D.new()
	_snow.add_child(holder)
	assert_eq(SnowDeformation.find(holder), _snow, "Looking up the tree finds the manager the node is inside")


func test_a_stamper_anywhere_else_finds_it_through_the_group() -> void:
	var stranger: Node3D = Node3D.new()
	add_child_autofree(stranger)
	assert_eq(SnowDeformation.find(stranger), _snow, "and a node elsewhere in the level still finds one, with no NodePath to wire")
	assert_true(_snow.is_in_group(SnowDeformation.GROUP), "because every manager joins the group")

#endregion

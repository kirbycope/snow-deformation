extends GutTest
## Unit tests for the snow_deformation addon.
##
## These run headless, where [method RenderingServer.get_rendering_device] returns null, so the manager
## disables its compute passes. That is deliberate: it is the same path a project on the Compatibility
## renderer takes, and it has to stay working. Everything tested below is the CPU half, which runs
## either way: stamp packing, the window's snapping and scrolling arithmetic, the height providers, and
## the two stampers' decisions about when and how deep to cut.

const MANAGER: GDScript = preload("res://addons/snow_deformation/snow_deformation.gd")
const FOOT_STAMPER: GDScript = preload("res://addons/snow_deformation/foot_stamper.gd")
const BLADE_STAMPER: GDScript = preload("res://addons/snow_deformation/blade_stamper.gd")

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

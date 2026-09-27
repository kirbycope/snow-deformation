extends GutTest
## The snowball: how it grows, what it weighs, where it rests, and that it holds still on another one.

const MANAGER: GDScript = preload("res://addons/snow_deformation/snow_deformation.gd")
const SNOWBALL_SCENE: PackedScene = preload("res://addons/snow_deformation/scenes/snowball.tscn")

var _snow: SnowDeformation = null


func before_each() -> void:
	_snow = MANAGER.new()
	_snow.snow_depth = 0.35
	_snow.create_surface = false
	add_child_autofree(_snow)


func _ball() -> Snowball:
	var ball: Snowball = SNOWBALL_SCENE.instantiate()
	add_child_autofree(ball)
	return ball


func test_it_starts_the_size_of_a_football() -> void:
	var ball: Snowball = _ball()
	assert_almost_eq(ball.radius * 2.0, 0.22, 0.001, "22 cm across, a size 5 ball")
	var shape: SphereShape3D = (ball.get_node("CollisionShape3D") as CollisionShape3D).shape
	assert_almost_eq(shape.radius, ball.radius, 0.0001, "and its collider matches")


func test_growing_resizes_the_collider_the_mesh_and_the_mass() -> void:
	var ball: Snowball = _ball()
	var before: float = ball.mass
	ball.radius = 0.3
	var shape: SphereShape3D = (ball.get_node("CollisionShape3D") as CollisionShape3D).shape
	var mesh: SphereMesh = (ball.get_node("MeshInstance3D") as MeshInstance3D).mesh
	assert_almost_eq(shape.radius, 0.3, 0.0001, "The collider grows")
	assert_almost_eq(mesh.radius, 0.3, 0.0001, "so does the mesh")
	assert_almost_eq(mesh.height, 0.6, 0.0001, "all the way round")
	assert_almost_eq(ball.mass, Snowball.mass_for(0.3, ball.density), 0.001, "and it weighs what that much packed snow weighs")
	assert_gt(ball.mass, before * 15.0, "which is the cube of the radius, not the radius")


func test_each_ball_grows_on_its_own() -> void:
	var one: Snowball = _ball()
	var two: Snowball = _ball()
	one.radius = 0.4
	var shape: SphereShape3D = (two.get_node("CollisionShape3D") as CollisionShape3D).shape
	assert_almost_eq(shape.radius, 0.11, 0.0001, "The shape is local to each ball, so growing one leaves the others")


func test_rolling_grows_it_fast_while_small_and_slowly_when_big() -> void:
	var small_gain: float = Snowball.grown(0.11, 1.0, 0.04) - 0.11
	var big_gain: float = Snowball.grown(0.5, 1.0, 0.04) - 0.5
	assert_gt(small_gain, 0.05, "A metre rolled puts centimetres on a small one")
	assert_lt(big_gain, small_gain / 4.0, "and far less on a big one, whose surface is larger")
	assert_eq(Snowball.grown(0.2, 0.0, 0.04), 0.2, "Standing still it gains nothing")


func test_rolling_ten_metres_makes_a_snowman_base() -> void:
	var depth: float = _ball().pick_up_depth
	var r: float = 0.11
	for step: int in 1000:
		r = Snowball.grown(r, 0.01, depth)
	assert_between(r, 0.5, 0.65, "Ten metres from a football is a ball a snowman can stand on, waist high")
	for step: int in 2000:
		r = Snowball.grown(r, 0.01, depth)
	assert_gt(r, 0.9, "and thirty one taller than the Player")


func test_pushed_on_the_flat_it_stops_within_a_few_metres() -> void:
	await wait_physics_frames(2)
	var ball: Snowball = _ball()
	ball.global_position = Vector3(0.0, _snow.get_floor_height(Vector2.ZERO) + ball.radius + 0.01, 0.0)
	await wait_seconds(0.5)
	ball.linear_velocity = Vector3(3.0, 0.0, 0.0) # a running Player's shove
	var start: float = ball.global_position.x
	await wait_seconds(4.0)
	assert_between(ball.global_position.x - start, 0.5, 3.5, "Snow stops it in a few metres, not across the field")


func test_a_ball_moved_somewhere_else_does_not_grow() -> void:
	var ball: Snowball = _ball()
	ball.set("_on_snow", true)
	ball.global_position = Vector3(20.0, 0.43, 20.0)
	ball._physics_process(1.0 / 60.0)
	assert_eq(ball.radius, 0.11, "Put ten metres away it has rolled over nothing, so it picks nothing up")
	ball.linear_velocity = Vector3(2.0, 0.0, 0.0)
	ball._physics_process(1.0 / 60.0)
	assert_gt(ball.radius, 0.11, "Rolling, it does")


func test_it_rolls_the_way_it_is_going_without_skidding() -> void:
	var spin: Vector3 = Snowball.rolling_spin(Vector3(2.0, -1.0, 0.0), 0.5)
	assert_almost_eq(spin, Vector3(0.0, 0.0, -4.0), Vector3.ONE * 0.0001, "Rolling along +X at 2 m/s with a 0.5 m radius is 4 rad/s about -Z")
	var forward_point: Vector3 = spin.cross(Vector3(0.0, -0.5, 0.0)) + Vector3(2.0, 0.0, 0.0)
	assert_almost_eq(forward_point.length(), 0.0, 0.0001, "so the point touching the snow is still, which is rolling rather than skidding")


func test_it_has_no_size_limit_unless_given_one() -> void:
	var ball: Snowball = _ball()
	ball.radius = 5.0
	assert_eq(ball.radius, 5.0, "By default it grows as big as the snow lets it")
	ball.max_radius = 0.6
	ball.radius = 5.0
	assert_eq(ball.radius, 0.6, "and a max_radius stops it there")


func test_it_rides_on_the_packed_snow_floor() -> void:
	var ball: Snowball = _ball()
	assert_true(ball.collision_mask & _snow.floor_layer != 0, "The snowball masks the floor layer, so it rides on the snow")
	assert_true(ball.collision_mask & 1 != 0, "and still collides with the world")


func test_a_ball_touching_another_holds_still() -> void:
	var bottom: Snowball = _ball()
	var top: Snowball = _ball()
	assert_false(top.is_stacked())
	top.call("_on_body_entered", bottom)
	assert_true(top.is_stacked(), "Touching another snowball it stops rolling, so it stays where it was set")
	assert_true(top.lock_rotation, "its rotation locked, since the contact solver would put back any spin zeroed by hand")
	top.call("_on_body_exited", bottom)
	assert_false(top.is_stacked(), "and rolls again once it is off")
	assert_false(top.lock_rotation)


func test_something_else_touching_it_does_not_stop_it_rolling() -> void:
	var ball: Snowball = _ball()
	var wall: StaticBody3D = autofree(StaticBody3D.new())
	ball.call("_on_body_entered", wall)
	assert_false(ball.is_stacked(), "Only another snowball holds it")
	ball.call("_on_body_exited", wall)
	assert_engine_error_count(0, "and something else leaving it is no error")


func test_a_big_ball_sinks_and_a_football_barely_marks_the_snow() -> void:
	assert_lt(Snowball.sinks_to(0.11, 250.0, 2000.0), 0.015, "A football goes in about a centimetre")
	assert_gt(Snowball.sinks_to(0.4, 250.0, 2000.0), 0.1, "a snowman's base a hand's depth")
	assert_lt(Snowball.sinks_to(0.4, 250.0, 20000.0), 0.02, "and on hard-packed snow hardly at all")


func test_sinking_is_what_slows_a_big_ball() -> void:
	var small: float = Snowball.sunk_resistance(Snowball.sinks_to(0.11, 250.0, 2000.0), 0.11)
	var big: float = Snowball.sunk_resistance(0.4 * Snowball.MAX_SINK, 0.4)
	assert_lt(small, 0.25, "A football rolls on the packed snow's own resistance")
	assert_gt(big, 0.33, "a big one sunk a quarter of its radius ploughs, at a third of its weight")


func test_a_storm_rolls_a_football_but_not_a_snowman_base() -> void:
	var storm: Vector3 = Vector3(36.0, 0.0, 0.0)
	var football: float = Snowball.wind_force(storm, 0.11, 0.47).length() / Snowball.mass_for(0.11, 250.0)
	assert_gt(football, 9.8 * 0.25, "A 36 m/s storm pushes a football harder than the snow holds it")
	var base: float = Snowball.wind_force(storm, 0.4, 0.47).length() / Snowball.mass_for(0.4, 250.0)
	assert_lt(base, 9.8 * Snowball.sunk_resistance(0.4 * Snowball.MAX_SINK, 0.4), "but not a snowman's base, sunk in")
	assert_almost_eq(Snowball.wind_force(Vector3.ZERO, 0.3, 0.47), Vector3.ZERO, Vector3.ONE * 0.0001, "Still air pushes nothing")


func test_the_wind_blows_a_ball_along() -> void:
	_snow.set_wind(20.0, Vector3(0.0, 0.0, 2.0))
	assert_almost_eq(_snow.wind, Vector3(0.0, 0.0, 20.0), Vector3.ONE * 0.0001, "set_wind takes a weather system's strength and direction")
	var ball: Snowball = _ball()
	ball.global_position = Vector3(0.0, 3.0, 0.0)
	await wait_physics_frames(20)
	assert_gt(ball.linear_velocity.z, 0.5, "and a ball in it drifts downwind")


func test_a_ball_under_the_floor_is_lifted_onto_it() -> void:
	await wait_physics_frames(2)
	assert_true(_snow.floor_covers(Vector2.ZERO), "The floor covers the middle of the window")
	assert_false(_snow.floor_covers(Vector2(500.0, 0.0)), "and not far beyond it")
	var ball: Snowball = _ball()
	ball.global_position = Vector3(0.0, 0.12, 0.0) # set in the snow, below the floor
	await wait_physics_frames(10)
	assert_gt(ball.global_position.y, _snow.get_floor_height(Vector2.ZERO), "It rides on the snow, not the ground beneath")


func test_a_big_ball_settles_into_the_snow() -> void:
	await wait_physics_frames(2)
	var ball: Snowball = _ball()
	ball.radius = 0.4
	var top: float = _snow.get_floor_height(Vector2.ZERO)
	ball.global_position = Vector3(0.0, top + 0.45, 0.0)
	await wait_seconds(1.5)
	assert_almost_eq(ball.sink, Snowball.sinks_to(0.4, ball.density, ball.snow_strength), 0.005, "It sinks until the snow bears it")
	assert_gt(ball.sink, 0.02, "which for a snowman's base is a few centimetres")
	var drawn: Node3D = ball.get_node("MeshInstance3D")
	assert_almost_eq(drawn.global_position.y - ball.radius, top - ball.sink, 0.02, "and the ball as drawn has its underside that far under the floor")


func test_ploughing_the_snow_lowers_the_floor_but_a_ball_does_not_dig_its_own() -> void:
	await wait_physics_frames(2)
	var top: float = _snow.get_floor_height(Vector2.ZERO)
	_snow.add_capsule(Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), 0.3, 0.3, 0.3, 0.35, 0.25, 0.4, false)
	assert_almost_eq(_snow.get_floor_height(Vector2.ZERO), top, 0.001, "A body riding the floor presses the snow without digging the floor out from under itself")
	_snow.add_capsule(Vector3(-1.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), 0.3, 0.3, 0.3)
	assert_almost_eq(_snow.get_floor_height(Vector2.ZERO), top - (0.3 - _snow.floor_sink), 0.001, "Anything else ploughs it out, and the floor lies in the trench")
	await wait_physics_frames(2)
	var floor_shape: HeightMapShape3D = (_snow.get_node("SnowFloor").get_child(0) as CollisionShape3D).shape
	var middle: int = (floor_shape.map_width - 1) / 2
	assert_almost_eq(floor_shape.map_data[middle * floor_shape.map_width + middle], _snow.get_floor_height(Vector2.ZERO), 0.001, "The collider itself drops there")


## A snowman's base with a head on it, settled and holding.
func _stack() -> Array[Snowball]:
	await wait_physics_frames(2)
	var top: float = _snow.get_floor_height(Vector2.ZERO)
	var base: Snowball = _ball()
	base.radius = 0.3
	base.break_speed = 0.0
	base.global_position = Vector3(0.0, top + 0.3, 0.0)
	var head: Snowball = _ball()
	head.radius = 0.2
	head.break_speed = 0.0
	head.global_position = Vector3(0.0, top + 0.3 + 0.3 + 0.2 - 0.02, 0.0)
	await wait_seconds(1.0)
	return [base, head]


func test_a_stack_comes_down_when_the_snow_is_ploughed_from_under_it() -> void:
	var stack: Array[Snowball] = await _stack()
	var head: Snowball = stack[1]
	assert_true(head.lock_rotation, "Set on the base, the head holds")
	var height: float = head.global_position.y
	# A trench ploughed along one side of the base: its floor drops and tilts, and the base goes in
	_snow.add_capsule(Vector3(-1.5, 0.0, 0.5), Vector3(1.5, 0.0, 0.5), 0.6, 0.35, 0.35)
	await wait_seconds(3.0)
	assert_lt(head.global_position.y, height - 0.15, "The head comes down with it")


func test_something_else_knocks_a_stack_loose_and_a_slow_touch_does_not() -> void:
	var stack: Array[Snowball] = await _stack()
	var base: Snowball = stack[0]
	var head: Snowball = stack[1]
	var leaning: RigidBody3D = autofree(RigidBody3D.new())
	leaning.linear_velocity = Vector3(0.1, 0.0, 0.0)
	base.call("_on_body_entered", leaning)
	assert_true(head.lock_rotation, "Something barely moving leaves it standing")
	var gentle: Snowball = _ball()
	gentle.global_position = Vector3(5.0, 3.0, 5.0)
	gentle.linear_velocity = Vector3(0.3, 0.0, 0.0)
	head.call("_on_body_entered", gentle)
	assert_true(head.lock_rotation, "Another snowball set down on it gently stacks")
	var kick: RigidBody3D = autofree(RigidBody3D.new())
	kick.linear_velocity = Vector3(2.0, 0.0, 0.0)
	base.call("_on_body_entered", kick)
	assert_false(base.lock_rotation, "A kick knocks the base loose")
	assert_false(head.lock_rotation, "and the head on it, so the stack can topple")
	var lone: Snowball = _ball()
	var thrown: Snowball = _ball()
	thrown.global_position = Vector3(-5.0, 3.0, 5.0)
	thrown.linear_velocity = Vector3(8.0, 0.0, 0.0)
	lone.call("_on_body_entered", thrown)
	assert_gt(lone._free_until, 0.0, "One thrown at it knocks it loose")
	var wall: StaticBody3D = autofree(StaticBody3D.new())
	var other: Snowball = _ball()
	other.call("_on_body_entered", wall)
	assert_eq(other._free_until, 0.0, "Ground and walls knock nothing")


func test_a_hard_landing_breaks_it_into_clumps_and_a_gentle_one_does_not() -> void:
	await wait_physics_frames(2)
	var top: float = _snow.get_floor_height(Vector2.ZERO)
	var gentle: Snowball = _ball()
	gentle.global_position = Vector3(-3.0, top + gentle.radius + 0.03, 0.0)
	var dropped: Snowball = _ball()
	dropped.radius = 0.2
	dropped.global_position = Vector3(3.0, top + 5.0, 0.0)
	var broke: Array[bool] = []
	dropped.shattered.connect(broke.append.bind(true))
	await wait_seconds(1.8)
	assert_true(is_instance_valid(gentle), "Set down gently it stays whole")
	assert_eq(broke, [true], "Dropped five metres it falls apart")
	assert_false(is_instance_valid(dropped), "and is gone")
	var clumps: int = 0
	for child: Node in get_children():
		if child.name.begins_with("SnowClump"):
			clumps += 1
			assert_eq((child as RigidBody3D).collision_layer, 0, "Clumps trip nobody")
	assert_between(clumps, 4, 14, "leaving clumps of it in the snow")
	for child: Node in get_children():
		if child.name.begins_with("SnowClump"):
			child.free()


func test_shoving_a_ball_does_not_break_it() -> void:
	await wait_physics_frames(2)
	var top: float = _snow.get_floor_height(Vector2.ZERO)
	var ball: Snowball = _ball()
	ball.radius = 0.3
	ball.global_position = Vector3(0.0, top + 0.3, 0.0)
	await wait_seconds(0.5)
	ball.apply_central_impulse(Vector3(5.0, 0.0, 0.0) * ball.mass)
	await wait_physics_frames(5)
	assert_true(is_instance_valid(ball), "Set moving at 5 m/s from rest, as a running Player shoves it, it stays whole")


## Ground falling away half a metre for every metre east: a 27 degree hillside.
class Hill:
	extends SnowTerrainHeight
	func height_at(xz: Vector2) -> float:
		return -xz.x * 0.5


func test_a_ball_on_a_hill_rolls_away_down_it_and_grows() -> void:
	_snow.free() # the flat snow every other test stands on; a ball takes the first manager it finds
	var hill: SnowDeformation = MANAGER.new()
	hill.snow_depth = 0.35
	hill.create_surface = false
	hill.terrain_height_provider = Hill.new()
	add_child_autofree(hill)
	await wait_physics_frames(3)
	var ball: Snowball = SNOWBALL_SCENE.instantiate()
	add_child_autofree(ball)
	ball.break_speed = 0.0
	ball.global_position = Vector3(-10.0, hill.get_floor_height(Vector2(-10.0, 0.0)) + 0.12, 0.0)
	await wait_seconds(4.0)
	assert_gt(ball.global_position.x + 10.0, 5.0, "Let go on a hillside it rolls away down it")
	assert_gt(ball.linear_velocity.length(), 1.5, "gathering speed")
	assert_gt(ball.radius, 0.15, "and snow")


## A steep hillside easing off as it goes down, 40 degrees at the top: the floor over it bends at every cell.
class CurvedHill:
	extends SnowTerrainHeight
	func height_at(xz: Vector2) -> float:
		return -xz.x * 0.84 + xz.x * xz.x * 0.01


func test_a_ball_rolling_down_a_curved_hill_keeps_gathering_speed() -> void:
	_snow.free()
	var hill: SnowDeformation = MANAGER.new()
	hill.snow_depth = 0.35
	hill.create_surface = false
	hill.terrain_height_provider = CurvedHill.new()
	add_child_autofree(hill)
	await wait_physics_frames(3)
	var ball: Snowball = SNOWBALL_SCENE.instantiate()
	ball.pick_up_depth = 0.0 # rolling alone, without the snow it picks up holding it back
	ball.radius = 0.2
	add_child_autofree(ball)
	ball.break_speed = 0.0
	ball.global_position = Vector3(0.0, hill.get_floor_height(Vector2.ZERO) + 0.3, 0.0)
	await wait_seconds(2.5)
	# Rolling, 5/7 of gravity along a slope of about 37 degrees, less the snow's resistance: 7.5 m/s by now. A spin set
	# every step instead of left to the floor's friction held it to 6.4.
	assert_gt(ball.linear_velocity.length(), 7.0, "It keeps gathering speed as a rolling ball does, not held to a jog")


func test_a_knocked_ball_breaks_from_less_than_one_let_go_of() -> void:
	var ball: Snowball = _ball()
	var held_drop: float = sqrt(2.0 * 9.8 * 1.6) # let go of from the hands, high
	assert_lt(held_drop, ball.breaks_at(), "A ball let go of from the hands survives the landing")
	ball.knock()
	var head_fall: float = sqrt(2.0 * 9.8 * 0.8) # knocked off a snowman's base
	assert_gt(head_fall, ball.breaks_at(), "a snowman's head knocked off its base does not")


func test_any_ball_dropped_from_the_hands_stays_whole() -> void:
	await wait_physics_frames(2)
	var balls: Array[Snowball] = []
	for i: int in 3:
		var ball: Snowball = _ball()
		ball.radius = [0.11, 0.3, 0.5][i]
		ball.global_position = Vector3(-4.0 + i * 3.0, _snow.get_floor_height(Vector2(-4.0 + i * 3.0, 0.0)) + ball.radius + 1.5, 0.0)
		balls.append(ball)
	await wait_seconds(2.0)
	for ball: Snowball in balls:
		assert_true(is_instance_valid(ball), "Dropped a metre and a half it stays whole, whatever its size")


func test_a_rolling_ball_leaves_its_track() -> void:
	await wait_physics_frames(2)
	var ball: Snowball = _ball()
	ball.global_position = Vector3(0.0, _snow.get_floor_height(Vector2.ZERO) + ball.radius + 0.01, 0.0)
	await wait_seconds(0.5)
	var before: int = _snow.stamps_total
	ball.linear_velocity = Vector3(2.0, 0.0, 0.0)
	await wait_physics_frames(10)
	assert_gt(_snow.stamps_total, before + 5, "Rolling on the snow it presses its track every step, sunk or not")


func test_a_held_ball_pushed_through_the_snow_gathers_it() -> void:
	await wait_physics_frames(2)
	var low: Snowball = _ball()
	var high: Snowball = _ball()
	low.freeze = true # held in the hands
	high.freeze = true
	var surface: float = _snow.get_undeformed_surface_height(Vector2.ZERO)
	for step: int in 120: # three metres, at a walk
		low.global_position = Vector3(-1.5 + step * 0.025, surface - 0.05, 0.0)
		high.global_position = Vector3(-1.5 + step * 0.025, surface + 0.5, 2.0)
		await wait_physics_frames(1)
	assert_gt(low.radius, 0.12, "Pushed along with its underside in the snow, it gathers snow")
	assert_eq(high.radius, 0.11, "carried above it, none")


func test_a_round_breaks_it_whatever_its_size() -> void:
	var ball: Snowball = _ball()
	ball.radius = 0.5
	var broke: Array[bool] = []
	ball.shattered.connect(broke.append.bind(true))
	ball.register_projectile_hit(null, ball.global_position, Vector3.UP)
	assert_eq(broke, [true], "Shot, even a snowman's base falls apart")


## A slope steepening over its crest: level for a few metres, then falling away ever more steeply.
class Crest:
	extends SnowTerrainHeight
	func height_at(xz: Vector2) -> float:
		return -maxf(xz.x, 0.0) * maxf(xz.x, 0.0) * 0.06


func test_a_fast_ball_keeps_to_the_snow_over_a_crest() -> void:
	_snow.free()
	var hill: SnowDeformation = MANAGER.new()
	hill.snow_depth = 0.35
	hill.create_surface = false
	hill.terrain_height_provider = Crest.new()
	add_child_autofree(hill)
	await wait_physics_frames(3)
	var ball: Snowball = SNOWBALL_SCENE.instantiate()
	ball.radius = 0.3
	add_child_autofree(ball)
	ball.break_speed = 0.0
	ball.global_position = Vector3(-4.0, hill.get_floor_height(Vector2(-4.0, 0.0)) + 0.31, 0.0)
	await wait_seconds(0.3)
	ball.linear_velocity = Vector3(9.0, 0.0, 0.0)
	var airborne: int = 0
	for frame: int in 60:
		await wait_physics_frames(1)
		if not ball._on_snow:
			airborne += 1
	assert_lt(airborne, 6, "Rolled fast over the crest, it stays on the snow, growing and leaving its track, rather than flying off")


## How far a ball [param of_radius] goes in a second of a character leaning on it from the west and adding 20 cm/s of
## eastward speed to it every step, as the physics engine does for a character moving into a rigid body.
func _shoved_by_a_character(of_radius: float) -> float:
	await wait_physics_frames(2)
	var ball: Snowball = _ball()
	ball.radius = of_radius
	ball.global_position = Vector3(0.0, _snow.get_floor_height(Vector2.ZERO) + of_radius, 0.0)
	var walker: CharacterBody3D = CharacterBody3D.new()
	add_child_autofree(walker)
	walker.global_position = ball.global_position + Vector3(-of_radius - 0.3, 0.0, 0.0)
	await wait_seconds(0.5)
	ball.call("_on_body_entered", walker) # leaning on it
	var start: float = ball.global_position.x
	for step: int in 60:
		walker.global_position = ball.global_position + Vector3(-of_radius - 0.3, 0.0, 0.0)
		ball.linear_velocity.x += 0.2
		await wait_physics_frames(1)
	return ball.global_position.x - start


func test_a_character_shoves_a_football_along_but_not_a_big_ball() -> void:
	assert_gt(await _shoved_by_a_character(0.11), 1.0, "A character walking into a football carries it along")
	assert_lt(await _shoved_by_a_character(0.7), 0.2, "one 1.4 m across is too heavy to push")

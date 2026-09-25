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
	var r: float = 0.11
	for step: int in 1000:
		r = Snowball.grown(r, 0.01, 0.04)
	assert_between(r, 0.3, 0.45, "Ten metres from a football is a ball a snowman can stand on")


func test_let_go_of_it_stops_within_a_few_metres() -> void:
	var speed: float = 3.0 # A brisk walk's push.
	var travelled: float = 0.0
	var dt: float = 1.0 / 60.0
	while speed > 0.0:
		travelled += speed * dt
		speed = maxf(speed - Snowball.slowed_by(0.25, dt), 0.0)
	assert_between(travelled, 1.0, 3.0, "Snow's rolling resistance stops it in a couple of metres, not across the field")


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


func test_it_never_grows_past_its_limit() -> void:
	var ball: Snowball = _ball()
	ball.radius = 5.0
	assert_eq(ball.radius, ball.max_radius, "It stops at max_radius")


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
	assert_almost_eq(ball.sink, 0.1, 0.01, "It sinks a quarter of its radius")
	assert_almost_eq(ball.global_position.y - ball.radius, top - ball.sink, 0.02, "and its underside is that far under the floor")


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
	var kick: RigidBody3D = autofree(RigidBody3D.new())
	kick.linear_velocity = Vector3(2.0, 0.0, 0.0)
	base.call("_on_body_entered", kick)
	assert_false(base.lock_rotation, "A kick knocks the base loose")
	assert_false(head.lock_rotation, "and the head on it, so the stack can topple")
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
	dropped.global_position = Vector3(3.0, top + 2.5, 0.0)
	var broke: Array[bool] = []
	dropped.shattered.connect(broke.append.bind(true))
	await wait_seconds(1.5)
	assert_true(is_instance_valid(gentle), "Set down gently it stays whole")
	assert_eq(broke, [true], "Dropped two metres it falls apart")
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

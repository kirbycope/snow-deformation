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

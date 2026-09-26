# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
@tool
class_name Snowball
extends RigidBody3D
## A snowball that grows as it rolls through the snow, rides on top of it, and stacks.
##
## It starts about the size of a football. Rolled across the snow it picks up a layer
## [member pick_up_depth] thick along its width, so it grows fast while it is small and more slowly
## as it gets big, the way a real one does: the volume it gains per metre is a strip of snow, spread
## over a surface that keeps getting larger. Its mass follows its volume at [member density].
##
## It rides on the manager's packed snow floor rather than sinking to the ground underneath, because it
## masks [member SnowDeformation.floor_layer]; that floor is what lets it stand, roll and carry another
## ball with real friction. A snowball touching another one stops rolling, so one set on top of another
## holds there instead of rolling off, which is what lets a snowman be stacked with nothing but the
## Player's own pickup and hold.
##
## A big one sinks. Snow bears [member snow_strength] pascals, so a ball settles in until the footprint it
## presses carries its weight: a football barely marks it, a snowman's base goes in a hand's depth. Sunk, it
## ploughs, and its rolling resistance climbs with the depth, so a ball slows as it grows and at last stops.
## The collider is a sphere [member sink] / 2 smaller, riding on the floor, and the ball is drawn as much lower, so
## its underside is in the snow while its top still meets a ball stacked on it.
##
## It catches the manager's [member SnowDeformation.wind] as air drag on its cross-section, so in a strong
## wind a small ball rolls off downwind, picks up snow, and stops once it is too heavy for the wind to push
## through the snow it has sunk into.
##
## A ball that finds itself under the floor, placed in the snow or left beyond the floor until the focus
## came near, is lifted back on top of it.
##
## A stack holds only until something disturbs it. Anything but another snowball moving into a ball faster than
## [member knock_speed] knocks it loose, as does another snowball thrown at it faster than [member thrown_speed], and a ball in a stack that starts to move (the snow ploughed out from under
## the bottom one, which drops the floor it stands on) is knocked loose too; either frees the whole stack to roll for
## [member knocked_time], so it topples as it would. A ball stopped hard, its speed falling by [member break_speed] in
## a step, falls apart ([method shatter]); nothing dropped from the hands comes near that. One knocked loose breaks
## from much less, [member knocked_break_speed], while [member knocked_time] lasts, so a head knocked off a snowman
## breaks where it lands: clumps of it scatter and lie in the snow for [member clump_life] seconds, and the
## authority tells every peer, so it breaks everywhere.
##
## Everything but the growth runs on every peer. The growth runs on the body's multiplayer authority,
## and [member radius] is the one property a synchronizer needs to carry for the others to match.

## The ball's radius in metres. Setting it resizes the collider and the mesh and sets the mass.
@export_range(0.05, 2.0, 0.005, "suffix:m") var radius: float = 0.11:
	set(value):
		radius = clampf(value, 0.05, maxf(max_radius, 0.05))
		_apply_radius()
## Growth stops here.
@export_range(0.1, 2.0, 0.01, "suffix:m") var max_radius: float = 0.6
## How thick a layer of snow the ball picks up as it rolls over it.
@export_range(0.0, 0.2, 0.001, "suffix:m") var pick_up_depth: float = 0.01
## Snow's rolling resistance: the ball loses this times gravity in speed every second it rolls on snow, so a
## push on the flat stops it within a couple of metres while a hill of 15 degrees or more rolls it away.
@export_range(0.0, 1.0, 0.01) var rolling_resistance: float = 0.1
## How fast anything but another snowball has to be moving into a ball to knock it loose from a stack.
@export_range(0.0, 5.0, 0.05, "suffix:m/s") var knock_speed: float = 0.5
## Another snowball knocks it loose only when it comes in faster than this: thrown, not set down on it to stack.
@export_range(0.0, 20.0, 0.1, "suffix:m/s") var thrown_speed: float = 2.0
## A ball held in a stack that starts moving faster than this has lost what it stood on, so it is knocked loose.
@export_range(0.0, 5.0, 0.05, "suffix:m/s") var hold_speed: float = 0.5
## Seconds a knocked ball is free to roll before it may hold on another again.
@export_range(0.0, 5.0, 0.1, "suffix:s") var knocked_time: float = 1.5
## How suddenly a ball has to be stopped to break: its speed falling by this much in one physics step, which is a
## fall of more than three metres, or a hard throw at a wall. Dropped from the hands, set down, rolled or tossed, at
## any size, it stays whole. Being set moving, shoved or struck never breaks it. 0 never breaks.
@export_range(0.0, 30.0, 0.1, "suffix:m/s") var break_speed: float = 8.0
## The same for a ball knocked loose ([method knock]), for [member knocked_time] afterwards: a snowman's head knocked
## off its base breaks where it lands, while one lifted off and set down does not.
@export_range(0.0, 30.0, 0.1, "suffix:m/s") var knocked_break_speed: float = 3.0
## Seconds the clumps of a broken ball lie in the snow before they melt away.
@export_range(1.0, 120.0, 1.0, "suffix:s") var clump_life: float = 20.0
## Packed snow, in kilograms per cubic metre. The mass is this times the ball's volume.
@export_range(50.0, 900.0, 10.0, "suffix:kg/m3") var density: float = 250.0
## What the snow bears before it gives way, in pascals. A ball sinks until its footprint carries its weight:
## fresh powder bears a few hundred, wind-packed snow tens of thousands.
@export_range(100.0, 50000.0, 100.0, "suffix:Pa") var snow_strength: float = 10000.0
## Air drag coefficient; 0.47 is a sphere's.
@export_range(0.0, 2.0, 0.01) var drag_coefficient: float = 0.47

const AIR_DENSITY: float = 1.29 ## kg/m3, at sea level and freezing.
const MAX_SINK: float = 0.25 ## The deepest a ball sinks, as a share of its radius.
const SINK_RATE: float = 0.25 ## Metres per second a ball settles in, or comes back up once off the snow.
const SKID_SPEED: float = 0.3 ## Metres per second its surface may slip over the snow before it is set rolling.
const MAX_PUSH_STEP: float = 0.5 ## Metres a held ball can be pushed in one frame; further is a warp, not a push.

## How far the ball has sunk into the snow, in metres.
var sink: float = 0.0

signal shattered ## It fell apart ([method shatter]), on every peer, just before it goes.

## Until when (engine seconds) it is free to roll rather than hold on another snowball.
var _free_until: float = 0.0
## When it last began holding on another snowball; a ball still settling onto one is not yet knocked by moving.
var _held_since: float = 0.0
var _last_velocity: Vector3 = Vector3.ZERO
var _was_frozen: bool = true
## Where a frozen ball was on the last frame, to measure how far it is pushed through the snow; INF when free.
var _pushed_from: Vector3 = Vector3.INF

var _snow: SnowDeformation = null
## True while the ball is resting on the snow, which is the only time it picks any up.
var _on_snow: bool = false
## Other snowballs it is touching. While there are any it does not roll.
var _touching: Array[Snowball] = []

@onready var _shape: CollisionShape3D = get_node_or_null("CollisionShape3D") as CollisionShape3D
@onready var _mesh: MeshInstance3D = get_node_or_null("MeshInstance3D") as MeshInstance3D


func _ready() -> void:
	# The scene marks the shape and the mesh local to scene, so each ball grows its own and not every ball's.
	_apply_radius()
	if Engine.is_editor_hint():
		return
	contact_monitor = true
	max_contacts_reported = maxi(max_contacts_reported, 4)
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_snow = SnowDeformation.find(self)


## Radius [param from] grows to after rolling [param distance] metres over snow, picking up a layer
## [param depth] thick. The strip it picks up, 2r wide, spread over the ball's surface of 4 pi r
## squared: dr = depth * distance / (2 pi r).
static func grown(from: float, distance: float, depth: float) -> float:
	if from <= 0.0 or distance <= 0.0 or depth <= 0.0:
		return from
	return from + depth * distance / (TAU * from)


## The spin of a ball [param of_radius] in radius rolling over the ground at [param velocity] without skidding.
## On a slope, [param normal] is the floor's, and the ball rolls along the floor rather than along the level.
static func rolling_spin(velocity: Vector3, of_radius: float, normal: Vector3 = Vector3.UP) -> Vector3:
	var along: Vector3 = velocity - normal * velocity.dot(normal)
	return normal.cross(along) / maxf(of_radius, 0.001)


## Speed a ball rolling on snow loses in [param seconds] to [param resistance].
static func slowed_by(resistance: float, seconds: float) -> float:
	return resistance * 9.8 * seconds


## The sudden stop that breaks it now: [member knocked_break_speed] while it is knocked loose, [member break_speed]
## otherwise.
func breaks_at() -> float:
	return knocked_break_speed if _now() < _free_until else break_speed


## The mass of a ball [param of_radius] in radius at [param at_density].
static func mass_for(of_radius: float, at_density: float) -> float:
	return at_density * 4.0 / 3.0 * PI * pow(of_radius, 3.0)


## How deep a ball [param of_radius] at [param at_density] sinks into snow bearing [param strength] pascals:
## until its footprint, about 2 pi r d for a cap d deep, carries its weight. d = 2 rho g r^2 / (3 strength).
static func sinks_to(of_radius: float, at_density: float, strength: float) -> float:
	return 2.0 * at_density * 9.8 * of_radius * of_radius / (3.0 * maxf(strength, 1.0))


## Rolling resistance of a ball [param of_radius] sunk [param depth] into the snow: the square root of the
## depth over the diameter, as for a wheel in soft ground.
static func sunk_resistance(depth: float, of_radius: float) -> float:
	return sqrt(maxf(depth, 0.0) / maxf(2.0 * of_radius, 0.001))


## The wind's push in newtons on a ball [param of_radius] with the air moving at [param relative] past it:
## half rho Cd A v squared, along the air's motion.
static func wind_force(relative: Vector3, of_radius: float, coefficient: float) -> Vector3:
	return 0.5 * AIR_DENSITY * coefficient * PI * of_radius * of_radius * relative.length() * relative


## How deep this ball sinks where it is: nothing off the snow, and never past [constant MAX_SINK] of its
## radius or the snow under the floor.
func _sink_target() -> float:
	if not _on_snow or _snow == null or not is_instance_valid(_snow):
		return 0.0
	return minf(minf(sinks_to(radius, density, snow_strength), radius * MAX_SINK), maxf(_snow.snow_depth - _snow.floor_sink, 0.0))


## The collider's radius: the ball's, less half its sink.
func _collider_radius() -> float:
	return radius - sink * 0.5


func _apply_radius() -> void:
	if _shape and _shape.shape is SphereShape3D:
		(_shape.shape as SphereShape3D).radius = radius - sink * 0.5
	if _mesh and _mesh.mesh is SphereMesh:
		(_mesh.mesh as SphereMesh).radius = radius
		(_mesh.mesh as SphereMesh).height = radius * 2.0
	mass = maxf(mass_for(radius, density), 0.01)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	# Measured from its speed, not from how far it moved: a ball put somewhere else (a respawn, a
	# correction from the network) has moved without rolling over any snow.
	var rolled: float = Vector2(linear_velocity.x, linear_velocity.z).length() * delta
	var target: float = _sink_target()
	if not is_equal_approx(sink, target):
		sink = move_toward(sink, target, SINK_RATE * delta)
		_apply_radius()
	# The ball is drawn sink / 2 lower than the collider, whichever way up it has rolled, so its underside is in the
	# snow while its top meets a ball stacked on it. The picture moves, not the collider: a collider shifted inside a
	# spinning body every step braked it to a crawl on any hill.
	if _mesh and (sink > 0.0 or _mesh.position != Vector3.ZERO):
		_mesh.position = global_basis.orthonormalized().inverse() * Vector3(0.0, -sink * 0.5, 0.0)
	# Rolling on the snow it leaves its track, as wide as it is: down to its own underside, which is below the floor it
	# rides by as much as it has sunk, and the layer it picked up besides. It does not dig the floor, or it would sink
	# through its own track.
	if _on_snow and rolled > 0.0 and _snow != null and is_instance_valid(_snow):
		var drawn: Vector3 = global_position + Vector3.DOWN * (sink * 0.5 + pick_up_depth)
		_snow.press_segment(drawn - linear_velocity * delta, drawn, radius, 0.35, 0.25, false)
	if freeze:
		_was_frozen = true
	# Held in a stack and moving: what it stood on has gone, so the stack comes down.
	if lock_rotation and _now() - _held_since > 0.3 and linear_velocity.length() > hold_speed:
		knock()
	_hold_still()
	# Only the authority grows it; the others take the radius from it.
	var pushed: float = _pushed_through_snow()
	if pushed > 0.0 and radius < max_radius and is_multiplayer_authority():
		radius = grown(radius, pushed, pick_up_depth)
	elif _on_snow and not freeze and radius < max_radius and is_multiplayer_authority():
		var before: float = mass
		var reach: float = _collider_radius()
		radius = grown(radius, rolled, pick_up_depth)
		# The snow it picked up was standing still, so the ball carries the same momentum in more mass, and spins as a
		# ball that size rolling at that speed does.
		if mass > before:
			linear_velocity *= before / mass
			angular_velocity *= before / mass * reach / maxf(_collider_radius(), 0.001)
		# Up by as much as the collider grew, so it does not grow into the floor: the solver pushing it back out of
		# the snow every frame bled away more speed than the snow picked up did.
		global_position += Vector3.UP * maxf(_collider_radius() - reach, 0.0)


## How far a frozen ball (one held in the hands) was moved through the snow since the last frame: over the ground, while
## its underside is below the snow's surface. A held ball pushed through the snow gathers it as a rolled one does.
## Nothing for a free ball, which grows by rolling, and nothing for a jump further than a push could take it.
func _pushed_through_snow() -> float:
	if not freeze or _snow == null or not is_instance_valid(_snow):
		_pushed_from = Vector3.INF
		return 0.0
	var at: Vector3 = global_position
	var from: Vector3 = _pushed_from
	_pushed_from = at
	if not from.is_finite() or at.y - radius >= _snow.get_undeformed_surface_height(Vector2(at.x, at.z)):
		return 0.0
	var step: float = Vector2(at.x - from.x, at.z - from.z).length()
	return step if step < MAX_PUSH_STEP else 0.0


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if Engine.is_editor_hint():
		return
	_on_snow = false
	# Stopped short: its speed fell sharply between two steps while touching something. Snow breaks from the stop, not
	# from being shoved, so a Player walking into a snowman knocks it over without breaking the base.
	if break_speed > 0.0 and not _was_frozen and state.get_contact_count() > 0 and is_multiplayer_authority() \
			and _last_velocity.length() - state.linear_velocity.length() >= breaks_at():
		shatter.rpc()
		return
	_last_velocity = state.linear_velocity
	_was_frozen = false
	if _snow == null or not is_instance_valid(_snow):
		return
	var normal: Vector3 = Vector3.ZERO
	for i: int in state.get_contact_count():
		if _snow.is_floor(state.get_contact_collider_object(i)):
			_on_snow = true
			var n: Vector3 = state.get_contact_local_normal(i)
			normal += n if n.y >= 0.0 else -n
	normal = normal.normalized() if normal.length_squared() > 1e-6 else Vector3.UP
	var flat: Vector3 = Vector3(state.linear_velocity.x, 0.0, state.linear_velocity.z)
	state.linear_velocity += wind_force(_snow.wind - flat, radius, drag_coefficient) / maxf(mass, 0.01) * state.step
	if not _on_snow:
		_lift_onto_floor(state)
		return
	# Along the floor, not the level: on a hillside most of the motion is down the slope.
	var into: float = state.linear_velocity.dot(normal)
	var along: Vector3 = state.linear_velocity - normal * into
	var speed: float = along.length()
	if speed > 0.0:
		var resistance: float = maxf(rolling_resistance, sunk_resistance(sink, radius))
		var kept: float = maxf(speed - slowed_by(resistance, state.step), 0.0) / speed
		along *= kept
		state.linear_velocity = along + normal * into
	# Packed snow grips it, so it rolls without skidding. The floor's friction keeps it rolling on its own; only a
	# skid is put right, such as a push below the middle, which is where a walking Player's legs meet a small ball,
	# spinning it backwards so that the backspin brakes it dead in a few centimetres. Setting the spin every step
	# instead fought the solver at each edge of the floor's cells and held a ball on a hill to a jog.
	if not lock_rotation:
		var rolling: Vector3 = rolling_spin(along, _collider_radius(), normal) # about the point it touches the floor
		if (state.angular_velocity - rolling).length() * _collider_radius() > SKID_SPEED:
			state.angular_velocity = rolling


## Puts a ball that is under the floor back on top of it: one placed in the snow, or one that rested on the
## ground beyond the floor until the floor came to it.
func _lift_onto_floor(state: PhysicsDirectBodyState3D) -> void:
	var at: Vector3 = state.transform.origin
	var xz: Vector2 = Vector2(at.x, at.z)
	if not _snow.floor_covers(xz):
		return
	var top: float = _snow.get_floor_height(xz)
	if at.y >= top:
		return
	state.transform = Transform3D(state.transform.basis, Vector3(at.x, top + radius, at.z))
	state.linear_velocity.y = maxf(state.linear_velocity.y, 0.0)


## True while it is touching another snowball and so holding still rather than rolling.
func is_stacked() -> bool:
	return not _touching.is_empty()


func _on_body_entered(body: Node) -> void:
	if body is Snowball:
		if not _touching.has(body):
			_touching.append(body as Snowball)
		if _speed_of(body) >= thrown_speed:
			knock()
		else:
			_hold_still()
	elif SnowDeformation._moves(body) and _speed_of(body) >= knock_speed:
		knock()


func _on_body_exited(body: Node) -> void:
	if body is Snowball:
		_touching.erase(body as Snowball)
		_hold_still()


## How fast [param body] is moving; something that carries no velocity of its own (a swung sword's body) counts as
## fast, since it only moves when something swings it.
static func _speed_of(body: Node) -> float:
	if body is RigidBody3D:
		return (body as RigidBody3D).linear_velocity.length()
	if body is CharacterBody3D:
		return (body as CharacterBody3D).velocity.length()
	return INF


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Frees it to roll for [member knocked_time], and every snowball it is stacked with too, so the stack comes down.
func knock() -> void:
	_free_until = _now() + knocked_time
	_hold_still()
	for other: Snowball in _touching:
		if is_instance_valid(other) and other._free_until < _free_until - 0.01:
			other.knock()


## Locks the ball's rotation while it touches another snowball and has not been knocked, so the two hold together on
## friction the way packed snow does, and frees it once they part. Zeroing the spin each step is not enough: the
## contact solver runs after, and puts the roll straight back.
func _hold_still() -> void:
	var hold: bool = not _touching.is_empty() and _now() >= _free_until
	if hold == lock_rotation:
		return
	lock_rotation = hold
	if hold:
		_held_since = _now()
		angular_velocity = Vector3.ZERO


## A round from a gun or an arrow breaks it, whatever its size, held or not. A projectile that looks for a
## [code]register_projectile_hit[/code] handler on what it hits calls this, the player controller's among them, on the
## round's own authority (the server, for a spawned round). A ball held in a client's hands answers to that client, so
## the server asks it.
func register_projectile_hit(_projectile: Node3D, _point: Vector3, _normal: Vector3) -> void:
	if is_queued_for_deletion():
		return
	if is_multiplayer_authority():
		shatter.rpc()
	elif multiplayer.is_server():
		_shatter_for_server.rpc_id(get_multiplayer_authority())


## The server's word that a round broke it, to the peer holding the ball.
@rpc("any_peer", "reliable")
func _shatter_for_server() -> void:
	if multiplayer.get_remote_sender_id() == 1 and is_multiplayer_authority() and not is_queued_for_deletion():
		shatter.rpc()


## Breaks it apart where it is, on every peer (the authority calls it as an RPC): clumps scatter from it and lie in the
## snow a while, a spray of snow is thrown up, and the ball is gone.
@rpc("authority", "call_local", "reliable")
func shatter() -> void:
	if is_queued_for_deletion():
		return
	_scatter_clumps()
	if _snow != null and is_instance_valid(_snow):
		_snow.kick(global_position, linear_velocity * 0.5 + Vector3.UP * 1.5, 10)
	shattered.emit()
	queue_free()


## The clumps of a broken ball: a handful of lumps holding about half its snow between them, the rest thrown up as
## powder. Plain rigid bodies on the same layers it rode on, so they lie on the snow; no layer of their own, so nothing
## trips on them. They shrink away after [member clump_life].
func _scatter_clumps() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return
	var count: int = clampi(roundi(radius / 0.04), 4, 14)
	var size: float = radius * pow(0.5 / float(count), 1.0 / 3.0)
	var look: Material = (_mesh.mesh as SphereMesh).material if _mesh and _mesh.mesh is SphereMesh else null
	for i: int in count:
		var r: float = size * randf_range(0.75, 1.25)
		var clump: RigidBody3D = RigidBody3D.new()
		clump.name = "SnowClump"
		clump.collision_layer = 0
		clump.collision_mask = collision_mask
		clump.mass = maxf(mass_for(r, density), 0.01)
		clump.physics_material_override = physics_material_override
		clump.angular_damp = 2.0
		var shape: CollisionShape3D = CollisionShape3D.new()
		var sphere: SphereShape3D = SphereShape3D.new()
		sphere.radius = r
		shape.shape = sphere
		clump.add_child(shape)
		var lump: MeshInstance3D = MeshInstance3D.new()
		var mesh: SphereMesh = SphereMesh.new()
		mesh.radius = r
		mesh.height = r * 1.5 # a little squashed, as broken snow is
		mesh.radial_segments = 8
		mesh.rings = 4
		mesh.material = look
		lump.mesh = mesh
		clump.add_child(lump)
		var out: Vector3 = Vector3(randf_range(-1.0, 1.0), randf_range(-0.2, 1.0), randf_range(-1.0, 1.0)).normalized()
		parent.add_child(clump, true) # SnowClump, SnowClump2, ...
		clump.global_position = global_position + out * radius * 0.5
		clump.linear_velocity = linear_velocity * 0.4 + out * randf_range(0.5, 2.0)
		var melt: Tween = clump.create_tween()
		melt.tween_interval(clump_life)
		melt.tween_property(lump, "scale", Vector3.ZERO, 3.0)
		melt.tween_callback(clump.queue_free)

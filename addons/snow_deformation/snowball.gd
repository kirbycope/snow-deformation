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
## The collider keeps the ball's shape above the snow and only its underside rides higher: a sphere
## [member sink] / 2 smaller and as much higher, kept upright however the ball turns.
##
## It catches the manager's [member SnowDeformation.wind] as air drag on its cross-section, so in a strong
## wind a small ball rolls off downwind, picks up snow, and stops once it is too heavy for the wind to push
## through the snow it has sunk into.
##
## A ball that finds itself under the floor, placed in the snow or left beyond the floor until the focus
## came near, is lifted back on top of it.
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
@export_range(0.0, 0.2, 0.005, "suffix:m") var pick_up_depth: float = 0.04
## Snow's rolling resistance: the ball loses this times gravity in speed every second it rolls on snow,
## so one let go of stops within a few metres instead of rolling on across the whole field.
@export_range(0.0, 1.0, 0.01) var rolling_resistance: float = 0.25
## Packed snow, in kilograms per cubic metre. The mass is this times the ball's volume.
@export_range(50.0, 900.0, 10.0, "suffix:kg/m3") var density: float = 250.0
## What the snow bears before it gives way, in pascals. A ball sinks until its footprint carries its weight:
## fresh powder bears a few hundred, wind-packed snow tens of thousands.
@export_range(100.0, 50000.0, 100.0, "suffix:Pa") var snow_strength: float = 2000.0
## Air drag coefficient; 0.47 is a sphere's.
@export_range(0.0, 2.0, 0.01) var drag_coefficient: float = 0.47

const AIR_DENSITY: float = 1.29 ## kg/m3, at sea level and freezing.
const MAX_SINK: float = 0.25 ## The deepest a ball sinks, as a share of its radius.
const SINK_RATE: float = 0.25 ## Metres per second a ball settles in, or comes back up once off the snow.

## How far the ball has sunk into the snow, in metres.
var sink: float = 0.0

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
static func rolling_spin(velocity: Vector3, of_radius: float) -> Vector3:
	return Vector3.UP.cross(Vector3(velocity.x, 0.0, velocity.z)) / maxf(of_radius, 0.001)


## Speed a ball rolling on snow loses in [param seconds] to [param resistance].
static func slowed_by(resistance: float, seconds: float) -> float:
	return resistance * 9.8 * seconds


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
	# The collider's underside rides sink higher than the ball's, whichever way up the ball has rolled.
	if _shape and (sink > 0.0 or _shape.position != Vector3.ZERO):
		_shape.position = global_basis.orthonormalized().inverse() * Vector3(0.0, sink * 0.5, 0.0)
	# Sunk, it ploughs a trench to its own underside, deeper than the collider riding on the floor reaches.
	if sink > 0.0 and rolled > 0.0 and _snow != null and is_instance_valid(_snow):
		_snow.press_segment(global_position - linear_velocity * delta, global_position, radius)
	# Only the authority grows it; the others take the radius from it. A held ball is frozen and grows nothing.
	if _on_snow and not freeze and radius < max_radius and is_multiplayer_authority():
		var before: float = mass
		radius = grown(radius, rolled, pick_up_depth)
		# The snow it picked up was standing still, so the ball carries the same momentum in more mass.
		if mass > before:
			linear_velocity *= before / mass
			angular_velocity *= before / mass


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if Engine.is_editor_hint():
		return
	_on_snow = false
	if _snow == null or not is_instance_valid(_snow):
		return
	for i: int in state.get_contact_count():
		if _snow.is_floor(state.get_contact_collider_object(i)):
			_on_snow = true
			break
	var flat: Vector3 = Vector3(state.linear_velocity.x, 0.0, state.linear_velocity.z)
	state.linear_velocity += wind_force(_snow.wind - flat, radius, drag_coefficient) / maxf(mass, 0.01) * state.step
	if not _on_snow:
		_lift_onto_floor(state)
		return
	var along: Vector3 = Vector3(state.linear_velocity.x, 0.0, state.linear_velocity.z)
	var speed: float = along.length()
	if speed > 0.0:
		var resistance: float = maxf(rolling_resistance, sunk_resistance(sink, radius))
		var kept: float = maxf(speed - slowed_by(resistance, state.step), 0.0) / speed
		along *= kept
		state.linear_velocity = Vector3(along.x, state.linear_velocity.y, along.z)
	# Packed snow grips it, so it rolls without skidding: the spin is whatever its speed makes it. A push
	# below the middle, which is where a walking Player's legs meet a small ball, would otherwise spin it
	# backwards, and on the floor's friction that backspin brakes it dead in a few centimetres.
	if not lock_rotation:
		state.angular_velocity = rolling_spin(along, radius - sink) # about the point it touches the floor


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
	if body is Snowball and not _touching.has(body):
		_touching.append(body as Snowball)
		_hold_still()


func _on_body_exited(body: Node) -> void:
	if body is Snowball:
		_touching.erase(body as Snowball)
		_hold_still()


## Locks the ball's rotation while it touches another snowball, so the two hold together on friction the
## way packed snow does, and frees it once they part. Zeroing the spin each step is not enough: the contact
## solver runs after, and puts the roll straight back.
func _hold_still() -> void:
	lock_rotation = not _touching.is_empty()
	if lock_rotation:
		angular_velocity = Vector3.ZERO

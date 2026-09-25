# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
@icon("res://addons/snow_deformation/assets/icons/snow_deformation_icon.svg")
class_name SnowDeformation
extends Node3D
## Real-time deformable snow: one node to drop into a level.
##
## Keeps an [code]RGBA16F[/code] texture of the snow around a focus node (the player by default) and
## exposes it to every material through global shader parameters. Stampers ([FootStamper],
## [BladeStamper]) hand it world-space shapes; two compute passes scroll the window as the focus moves
## and carve this frame's shapes into it. The node also owns the snow surface mesh, so nothing outside
## has to be wired up.
##
## The channels are R = depression in metres, G = berm height in metres, B = disturbed mask 0-1.
##
## Needs the Forward+ or Mobile renderer. Under Compatibility, or headless, there is no
## [RenderingDevice]: the node warns once, disables itself, and the snow renders flat.

## Every manager joins this group, so a stamper can find one without a [NodePath] to it.
const GROUP: StringName = &"snow_deformation"

## Floats per stamp in the storage buffer. Mirrors `struct Stamp` in shaders/snow_update.glsl:
## four vec4s, 64 bytes, no padding.
const STAMP_FLOATS: int = 16

## Shape tags, in a stamp's first vec4 w component.
const SHAPE_ELLIPSE: float = 0.0
const SHAPE_CAPSULE: float = 1.0

const _SCROLL_SHADER: String = "res://addons/snow_deformation/shaders/snow_scroll.glsl"
const _UPDATE_SHADER: String = "res://addons/snow_deformation/shaders/snow_update.glsl"
const _SURFACE_SHADER: String = "res://addons/snow_deformation/shaders/snow_surface.gdshader"
const _OVERLAY_SHADER: String = "res://addons/snow_deformation/shaders/snow_debug_overlay.gdshader"

## Matches `local_size_x/y` in both compute shaders.
const _GROUP_SIZE: int = 8

## How much the refill should take off in one go, in metres. The deformation texture is RGBA16F, and a
## half float near 0.35 resolves about 0.00024. At 120 fps a refill of 0.02 m/s wants to subtract
## 0.00017 per frame, which is finer than that: the store rounds it up to a whole step and tracks then
## fade about one and a half times faster than the rate asks, at a speed that changes again whenever a
## value crosses a float exponent. So the decay is saved up and applied in steps large enough to land
## squarely on a representable value.
const _REFILL_QUANTUM: float = 0.003

## On-screen size of the debug overlay, in pixels.
const _OVERLAY_SIZE: Vector2 = Vector2(256.0, 256.0)

@export_group("Window")
## The node the deformation window follows. Left empty, the first node in the "Player" group is used,
## and failing that the viewport's current camera, so a level usually needs no wiring at all.
@export var focus_path: NodePath = NodePath()
## Texels along each side of the deformation texture.
@export_enum("512:512", "1024:1024", "2048:2048") var resolution: int = 1024
## How many metres across the window covers. One texel is world_size / resolution.
@export_range(8.0, 256.0, 1.0) var world_size: float = 48.0

@export_group("Snow")
## Undeformed snow thickness in metres. A stamp can never dig deeper than this.
@export_range(0.0, 2.0, 0.01) var snow_depth: float = 0.35
## Ceiling on the berm a stamp may raise, in metres.
@export_range(0.0, 1.0, 0.01) var max_rim_height: float = 0.12
## Where the ground under the snow is. Left empty, a flat provider at y = 0 is used.
@export var terrain_height_provider: SnowTerrainHeight = null

@export_group("Refill")
## Metres per second that depressions and berms recover. 0 keeps tracks indefinitely.
@export_range(0.0, 0.5, 0.001) var refill_rate_geo: float = 0.0
## Units per second that the disturbed mask fades. Usually a little faster than the geometry.
@export_range(0.0, 1.0, 0.001) var refill_rate_mask: float = 0.0

@export_group("Stamp shaping")
## Cycles per metre of the noise that roughens stamp edges.
@export_range(0.5, 64.0, 0.5) var noise_scale: float = 12.0
## How far that noise pushes a stamp's edge, in units of normalised distance.
@export_range(0.0, 0.5, 0.01) var noise_strength: float = 0.08
## Stamps accepted per frame. Anything past this is dropped and counted in [member dropped_stamps].
@export_range(16, 512, 16) var max_stamps_per_frame: int = 128

@export_group("Surface mesh")
## Build and follow a snow surface mesh. Turn this off to drive an existing mesh's material instead.
@export var create_surface: bool = true
## How many metres across the snow mesh is. Smaller than [member world_size], so tracks survive
## leaving the mesh and are still there on the way back.
@export_range(4.0, 128.0, 1.0) var surface_size: float = 32.0
## Quads along each side of the snow mesh. 256 over 32 m is a vertex every 12.5 cm.
@export_range(16, 512, 16) var surface_subdivisions: int = 256

@export_group("Bodies")
## Let physics bodies moving through the snow press it, the same way a [GrassField] is pressed: a
## barrel, a ball, a ragdoll, a boulder. A body that carries its own [FootStamper] or [BladeStamper]
## is left alone, because that component already describes its shape far better than a sphere does.
@export var press_bodies: bool = true:
	set(value):
		press_bodies = value
		if _press_area != null and is_instance_valid(_press_area):
			_press_area.monitoring = value
			if not value:
				_pressers.clear()
## Radius used for a body whose shapes have none of their own, such as a box or a mesh collider.
@export_range(0.05, 5.0, 0.05, "suffix:m") var press_radius_fallback: float = 0.4
## Bodies pressed in one frame. The widest and nearest win the slots, as they do in the grass.
@export_range(1, 64, 1) var max_pressed_bodies: int = 12
## Physics layers the press area watches.
@export_flags_3d_physics var press_mask: int = 0xFFFFF
## Played where a body is ploughing through the snow: a boulder, a barrel, a ball rolling. Left empty
## the pressing is silent, so the addon ships no audio of its own.
@export var press_sound: AudioStream = null
@export_range(-40.0, 12.0, 0.5, "suffix:dB") var press_volume_db: float = -6.0
@export_range(1.0, 60.0, 1.0, "suffix:m") var press_max_distance: float = 25.0
## How far a body has to plough before it is worth another crush. A body sitting still is silent.
@export_range(0.05, 5.0, 0.05, "suffix:m") var press_sound_interval: float = 0.6
## Crushes that may be heard at once. Past this the quietest are simply not played.
@export_range(1, 12, 1) var press_voices: int = 4

@export_group("Debug")
## Show the deformation texture in the corner of the screen.
@export var debug_overlay: bool = false

## True when the compute passes are running. False under Compatibility or headless.
var enabled: bool = false
## Stamps handed in since the last upload, before the per-frame cap.
var stamps_this_frame: int = 0
## What [member stamps_this_frame] was for the frame just uploaded. The live counter is reset as soon
## as the stamps go to the GPU, so a readout reading it directly would almost always print zero.
var stamps_last_frame: int = 0
## Stamps dropped since the last [method clear], because a frame went over the cap.
var dropped_stamps: int = 0
## Every stamp ever handed in, never reset. The per-frame counters are zeroed as soon as a frame is
## uploaded, and _process can run several times between two physics frames, so anything sampling those
## from a physics loop races them and reads zero however much is being carved. This one cannot.
var stamps_total: int = 0

## World XZ of the deformation texture's min corner.
var _origin: Vector2 = Vector2.ZERO
## That corner in whole texels, which is what actually gets snapped, so the origin cannot drift.
var _origin_texel: Vector2i = Vector2i.ZERO
var _texel_size: float = 1.0
var _has_origin: bool = false

var _focus: Node3D = null
var _provider: SnowTerrainHeight = null
var _surface: MeshInstance3D = null
var _surface_material: ShaderMaterial = null
var _overlay: TextureRect = null
var _press_area: Area3D = null
## Bodies currently inside the press area, and the radius and underside each one was measured at.
var _pressers: Array[Node3D] = []
var _press_shape: Dictionary[Node3D, Vector2] = {}
## Where each body last made a crush, so the next one waits until it has ploughed a bit further.
var _press_last_heard: Dictionary[Node3D, Vector3] = {}
var _press_voices: Array[AudioStreamPlayer3D] = []
var _next_voice: int = 0

## Packed stamps for this frame, uploaded once and then cleared.
var _stamps: PackedFloat32Array = PackedFloat32Array()
var _texture: Texture2DRD = null
## Texels the window moved since the last render-thread call, consumed by the next one.
var _pending_shift: Vector2i = Vector2i.ZERO
# Loaded on the main thread in _ready: the render thread does no resource loading.
var _scroll_file: RDShaderFile = null
var _update_file: RDShaderFile = null

# Render-thread state. Nothing here is touched from the main thread once _init_compute has run.
var _rd: RenderingDevice = null
var _display: RID = RID()
var _scratch: RID = RID()
var _stamp_buffer: RID = RID()
var _update_shader: RID = RID()
var _update_pipeline: RID = RID()
var _update_set: RID = RID()
var _scroll_shader: RID = RID()
var _scroll_pipeline: RID = RID()
var _scroll_set: RID = RID()
var _compute_ready: bool = false
## Set once the texture has been handed to the shader globals, which only the main thread may do.
var _texture_published: bool = false
## Seconds of refill owed but not yet applied. See [method _accumulate_refill].
var _refill_accum: float = 0.0


func _ready() -> void:
	_provider = terrain_height_provider if terrain_height_provider != null else SnowTerrainHeightFlat.new()
	_provider.setup(get_world_3d())
	add_to_group(GROUP)
	_texel_size = world_size / float(resolution)
	_texture = Texture2DRD.new()

	if Engine.is_editor_hint():
		return

	_resolve_focus()
	_build_press_area()
	if create_surface:
		_build_surface()
	_snap_origin(true)
	_publish_globals()

	var device: RenderingDevice = RenderingServer.get_rendering_device()
	if device == null:
		push_warning("SnowDeformation: no RenderingDevice (Compatibility renderer or headless), so snow deformation is off and the snow renders flat.")
		return
	_scroll_file = load(_SCROLL_SHADER) as RDShaderFile
	_update_file = load(_UPDATE_SHADER) as RDShaderFile
	if _scroll_file == null or _update_file == null:
		push_error("SnowDeformation: a compute shader is missing, so deformation is off.")
		return
	enabled = true
	RenderingServer.call_on_render_thread(_init_compute)
	_build_overlay()


func _exit_tree() -> void:
	# Drop the RID the texture points at before the texture outlives it, then free everything on the
	# thread that made it.
	if _texture != null:
		_texture.texture_rd_rid = RID()
	if _compute_ready:
		RenderingServer.call_on_render_thread(_free_compute)
		_compute_ready = false


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _focus == null or not is_instance_valid(_focus):
		_resolve_focus()
	var decay_dt: float = _accumulate_refill(delta)
	var scrolled: bool = _snap_origin(false)
	if create_surface:
		_follow_surface()
	_follow_press_area()
	if scrolled:
		_publish_globals()
	if _overlay != null:
		_overlay.visible = debug_overlay
		# Re-asserted every frame on purpose. The Texture2DRD has no size until the render thread
		# assigns its RID, and the TextureRect resizes itself to the texture's full resolution when it
		# arrives, which puts a 2048 px square over the whole screen.
		if _overlay.size != _OVERLAY_SIZE:
			_overlay.size = _OVERLAY_SIZE

	if not enabled or not _compute_ready:
		_end_frame()
		return

	# The render thread has finished building the texture, so the main thread can publish it. Doing
	# this here rather than in _init_compute is the difference between snow that deforms and snow
	# that silently stays flat.
	if not _texture_published:
		RenderingServer.global_shader_parameter_set(&"snow_deform_tex", _texture)
		_texture_published = true

	# Nothing to do at all: no stamps, no refill due and no scroll means the texture cannot have changed.
	var count: int = _stamps.size() / STAMP_FLOATS
	if count == 0 and decay_dt <= 0.0 and not scrolled:
		_end_frame()
		return

	# Copy what the render thread needs; it must never touch the scene tree.
	var payload: PackedFloat32Array = _stamps.duplicate()
	var shift: Vector2i = _pending_shift
	_pending_shift = Vector2i.ZERO
	RenderingServer.call_on_render_thread(_render_frame.bind(payload, count, decay_dt, _origin, shift))
	_end_frame()



#region Pressing bodies
# Modelled on GrassField's press points: an Area3D notices bodies coming and going, each one's radius
# is measured from its own collision shapes once on the way in, and the nearest and widest of them are
# what gets used. The difference is that grass is pressed by a shader uniform each frame while snow
# keeps what it is given, so a body only stamps while it is actually below the surface.

## Only things that move press the snow. The ground, a wall and a rock cleared their own snow when the
## level was built; they do not also push it about. Same list as GrassField uses.
static func _moves(collider: Object) -> bool:
	return collider is CharacterBody3D or collider is RigidBody3D or collider is AnimatableBody3D or collider is PhysicalBone3D


func _build_press_area() -> void:
	_press_area = Area3D.new()
	_press_area.name = "PressArea"
	_press_area.monitoring = press_bodies
	_press_area.monitorable = false
	_press_area.collision_layer = 0
	_press_area.collision_mask = press_mask
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	# The whole deformable window, and tall enough that a body falling into the snow is already being
	# tracked by the time it arrives.
	box.size = Vector3(world_size, snow_depth + 8.0, world_size)
	shape.shape = box
	shape.position = Vector3(0.0, snow_depth - box.size.y * 0.5 + 2.0, 0.0)
	_press_area.add_child(shape)
	_press_area.body_entered.connect(_on_press_body_entered)
	_press_area.body_exited.connect(_on_press_body_exited)
	add_child(_press_area)
	_follow_press_area()


func _follow_press_area() -> void:
	if _press_area == null or not is_instance_valid(_press_area):
		return
	_press_area.global_position = Vector3(_origin.x + world_size * 0.5, 0.0, _origin.y + world_size * 0.5)


func _on_press_body_entered(body: Node3D) -> void:
	if not _moves(body) or _pressers.has(body):
		return
	if _has_own_stamper(body):
		return
	_pressers.append(body)
	_press_shape[body] = _measure(body as CollisionObject3D, press_radius_fallback)


func _on_press_body_exited(body: Node3D) -> void:
	_pressers.erase(body)
	_press_shape.erase(body)
	_press_last_heard.erase(body)


## A body that already stamps for itself is skipped: the Player's feet and a blade's edge describe far
## more than a sphere around the body's origin would, and pressing both would bury the prints.
static func _has_own_stamper(body: Node) -> bool:
	for child: Node in body.get_children():
		if child is FootStamper or child is BladeStamper:
			return true
		if _has_own_stamper(child):
			return true
	return false


## The widest radius of a body's shapes, and how far its underside sits below its origin, measured once
## when it enters. Returns them as (radius, drop).
static func _measure(body: CollisionObject3D, fallback: float) -> Vector2:
	if body == null:
		return Vector2(fallback, fallback)
	var widest: float = 0.0
	var lowest: float = 0.0
	for owner_id: int in body.get_shape_owners():
		if body.is_shape_owner_disabled(owner_id):
			continue
		var offset: Transform3D = body.shape_owner_get_transform(owner_id)
		var reach: float = Vector2(offset.origin.x, offset.origin.z).length()
		var scale: Vector3 = offset.basis.get_scale()
		for i: int in body.shape_owner_get_shape_count(owner_id):
			var shape: Shape3D = body.shape_owner_get_shape(owner_id, i)
			var extent: Vector2 = _shape_extent(shape)
			if extent.x <= 0.0:
				continue
			widest = maxf(widest, extent.x * maxf(scale.x, scale.z) + reach)
			lowest = minf(lowest, offset.origin.y - extent.y * scale.y)
	if widest <= 0.0:
		return Vector2(fallback, fallback)
	return Vector2(widest, absf(lowest) + fallback * 0.0)


## A shape's horizontal radius and half height. A shape with no radius of its own returns zero, so the
## caller falls back rather than letting a stray ray shape decide how wide a body is.
static func _shape_extent(shape: Shape3D) -> Vector2:
	if shape is SphereShape3D:
		var sphere: SphereShape3D = shape as SphereShape3D
		return Vector2(sphere.radius, sphere.radius)
	if shape is CapsuleShape3D:
		var capsule: CapsuleShape3D = shape as CapsuleShape3D
		return Vector2(capsule.radius, capsule.height * 0.5)
	if shape is CylinderShape3D:
		var cylinder: CylinderShape3D = shape as CylinderShape3D
		return Vector2(cylinder.radius, cylinder.height * 0.5)
	if shape is BoxShape3D:
		var box: BoxShape3D = shape as BoxShape3D
		return Vector2(maxf(box.size.x, box.size.z) * 0.5, box.size.y * 0.5)
	return Vector2.ZERO


## Presses every tracked body that is actually in the snow. On the physics clock, because that is when
## a body has finished moving for the frame.
func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or not press_bodies or _pressers.is_empty():
		return
	_pressers = _pressers.filter(is_instance_valid)
	if _pressers.size() > max_pressed_bodies:
		_pressers.sort_custom(_presses_more)
	var pressed: int = 0
	for body: Node3D in _pressers:
		if pressed >= max_pressed_bodies:
			break
		var measured: Vector2 = _press_shape.get(body, Vector2(press_radius_fallback, press_radius_fallback))
		var at: Vector3 = body.global_position
		var bottom: float = at.y - measured.y
		var top: float = get_undeformed_surface_height(Vector2(at.x, at.z))
		if bottom >= top:
			continue # Resting on the snow rather than in it.
		add_sphere(Vector3(at.x, bottom, at.z), measured.x, clampf(top - bottom, 0.0, snow_depth))
		_crush_heard(body, at)
		pressed += 1


## The sound of snow being shoved aside, once a body has ploughed [member press_sound_interval] further
## than where it was last heard. Measured by distance rather than by time, so a body rolling fast
## crunches often, one creeping crunches rarely, and one that has stopped makes nothing at all.
func _crush_heard(body: Node3D, at: Vector3) -> void:
	if press_sound == null:
		return
	var last: Variant = _press_last_heard.get(body)
	if last != null and at.distance_to(last as Vector3) < press_sound_interval:
		return
	_press_last_heard[body] = at
	if last == null:
		return # The first frame in the snow only sets the mark; the body may simply be resting on it.
	var voice: AudioStreamPlayer3D = _press_voice()
	if voice == null:
		return
	voice.stream = press_sound
	voice.volume_db = press_volume_db
	voice.max_distance = press_max_distance
	voice.global_position = at
	voice.play()


## A voice from the pool, round robin, built on first use.
func _press_voice() -> AudioStreamPlayer3D:
	while _press_voices.size() < press_voices:
		var made: AudioStreamPlayer3D = AudioStreamPlayer3D.new()
		made.name = "CrushVoice%d" % _press_voices.size()
		made.bus = &"SFX" if AudioServer.get_bus_index(&"SFX") >= 0 else &"Master"
		add_child(made)
		_press_voices.append(made)
	if _press_voices.is_empty():
		return null
	_next_voice = (_next_voice + 1) % _press_voices.size()
	return _press_voices[_next_voice]


## Which body gets a slot when more are in the snow than there is budget for: the widest press nearest
## the camera, exactly the order the grass uses.
func _presses_more(a: Node3D, b: Node3D) -> bool:
	return _press_weight(a) > _press_weight(b)


func _press_weight(body: Node3D) -> float:
	var eye: Vector3 = global_position
	var camera: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		eye = camera.global_position
	var radius: float = (_press_shape.get(body, Vector2(press_radius_fallback, 0.0)) as Vector2).x
	return radius / (1.0 + body.global_position.distance_to(eye))

#endregion


#region Public API

## Queue an elliptical footprint centred on [param pos], [param yaw] radians about +Y. [param depth]
## is the heel depth in metres; the toe is shallower, which is what makes a print read as a footfall.
func add_footprint(pos: Vector3, yaw: float, half_width: float, half_length: float, depth: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4) -> void:
	_push(_pack(SHAPE_ELLIPSE, pos, pos, half_width, half_length, yaw, rim_factor, depth, depth * 0.7, wall_softness, rim_width))


## Queue a capsule from [param a] to [param b]: a blade gouge, a drag mark, or any body wading through.
func add_capsule(a: Vector3, b: Vector3, radius: float, depth_a: float, depth_b: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4) -> void:
	_push(_pack(SHAPE_CAPSULE, a, b, radius, radius, 0.0, rim_factor, depth_a, depth_b, wall_softness, rim_width))


## Queue a round depression. A capsule whose ends coincide.
func add_sphere(center: Vector3, radius: float, depth: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4) -> void:
	add_capsule(center, center, radius, depth, depth, rim_factor, wall_softness, rim_width)


## Height of the snow's top surface at [param xz] before anything disturbed it: the ground under the
## snow plus [member snow_depth]. This is how a stamper works out how deep something has sunk without
## reading the texture back from the GPU.
func get_undeformed_surface_height(xz: Vector2) -> float:
	return get_terrain_height(xz) + snow_depth


## Height of the ground under the snow at [param xz].
func get_terrain_height(xz: Vector2) -> float:
	return _provider.height_at(xz) if _provider != null else 0.0


## Wipe every track. Also resets [member dropped_stamps].
func clear() -> void:
	dropped_stamps = 0
	_stamps.clear()
	stamps_this_frame = 0
	if _compute_ready:
		RenderingServer.call_on_render_thread(_render_clear)


## The deformation texture, for a material that wants it directly rather than through the globals.
func get_deform_texture() -> Texture2DRD:
	return _texture


## The nearest manager to [param from], or null. Looks up the tree first, so a level with more than one
## snow volume gives a stamper the one it is actually inside, then falls back to the group.
static func find(from: Node) -> SnowDeformation:
	var node: Node = from
	while node != null:
		if node is SnowDeformation:
			return node as SnowDeformation
		node = node.get_parent()
	if from.is_inside_tree():
		var found: Array[Node] = from.get_tree().get_nodes_in_group(GROUP)
		# Same reasoning as _resolve_focus: one game has one MultiplayerAPI and this changes nothing,
		# but a two-peer harness runs both peers in one tree and a stamper must carve its own peer's
		# snow rather than whichever manager happens to be first in the group.
		for manager: Node in found:
			if manager.multiplayer == from.multiplayer:
				return manager as SnowDeformation
		if not found.is_empty():
			return found[0] as SnowDeformation
	return null

#endregion


#region Stamp packing

## One stamp's 16 floats, in the order `struct Stamp` declares them.
func _pack(shape: float, a: Vector3, b: Vector3, radius: float, half_length: float, yaw: float, rim_factor: float, depth_a: float, depth_b: float, wall_softness: float, rim_width: float) -> PackedFloat32Array:
	return PackedFloat32Array([
		a.x, a.y, a.z, shape,
		b.x, b.y, b.z, 0.0,
		radius, half_length, yaw, rim_factor,
		clampf(depth_a, 0.0, snow_depth), clampf(depth_b, 0.0, snow_depth), wall_softness, rim_width,
	])


## Seconds of decay to apply this frame: zero on most of them, then the whole debt at once. Returns 0
## while refill is off. See [constant _REFILL_QUANTUM] for why it is not simply [param delta].
func _accumulate_refill(delta: float) -> float:
	var rate: float = maxf(refill_rate_geo, 0.0)
	if rate <= 0.0 and refill_rate_mask <= 0.0:
		_refill_accum = 0.0
		return 0.0
	_refill_accum += delta
	# How long it takes this rate to earn one quantum. Floored at a frame so a very fast refill is not
	# held back, and capped so a very slow one still moves several times a second and reads as a fade.
	var step: float = clampf(_REFILL_QUANTUM / maxf(rate, 1e-6), 1.0 / 60.0, 0.25)
	if _refill_accum < step:
		return 0.0
	var owed: float = _refill_accum
	_refill_accum = 0.0
	return owed


## Rolls the queue over once a frame's stamps have gone to the GPU, or been discarded.
func _end_frame() -> void:
	stamps_last_frame = stamps_this_frame
	stamps_this_frame = 0
	_stamps.clear()


func _push(stamp: PackedFloat32Array) -> void:
	stamps_this_frame += 1
	stamps_total += 1
	if not enabled:
		return
	if _stamps.size() / STAMP_FLOATS >= max_stamps_per_frame:
		dropped_stamps += 1
		return
	_stamps.append_array(stamp)

#endregion


#region Window

func _resolve_focus() -> void:
	if not focus_path.is_empty():
		_focus = get_node_or_null(focus_path) as Node3D
		if _focus != null:
			return
	# The player this peer controls, not simply the first one in the group. In a multiplayer game the
	# group holds every peer's Player, and centring the window on somebody else's puts the deformable
	# area around them and leaves this screen's own tracks outside it.
	var players: Array[Node] = get_tree().get_nodes_in_group(&"Player")
	var first: Node3D = null
	for player: Node in players:
		if not player is Node3D:
			continue
		# A running game has one MultiplayerAPI, so this is always true. A two-peer test harness runs
		# both peers as branches of one tree with an API each, and then the group holds the other
		# branch's Players too: a manager must not adopt one, or it follows the wrong peer entirely.
		if player.multiplayer != multiplayer:
			continue
		if first == null:
			first = player as Node3D
		if player.is_multiplayer_authority():
			_focus = player as Node3D
			return
	if first != null:
		_focus = first
		return
	var viewport: Viewport = get_viewport()
	if viewport != null:
		_focus = viewport.get_camera_3d()


## Re-centre the window on the focus, snapped to whole texels. Returns true when it moved, in which
## case a scroll pass is queued and the published origin has to be refreshed this same frame.
func _snap_origin(force: bool) -> bool:
	var centre: Vector2 = Vector2.ZERO
	if _focus != null and is_instance_valid(_focus):
		var p: Vector3 = _focus.global_position
		centre = Vector2(p.x, p.z)
	var half: float = world_size * 0.5
	# Snapping in integer texels rather than metres, so repeated float rounding cannot drift.
	var want: Vector2i = Vector2i(
		floori((centre.x - half) / _texel_size),
		floori((centre.y - half) / _texel_size)
	)
	if not force and want == _origin_texel and _has_origin:
		return false
	var shift: Vector2i = want - _origin_texel
	if force or not _has_origin:
		shift = Vector2i(resolution, resolution) # Treated as a teleport: clear rather than scroll.
	_origin_texel = want
	_origin = Vector2(_origin_texel) * _texel_size
	_has_origin = true
	_pending_shift += shift
	return true


## Publishes the window to every shader. Must happen in the same frame as the scroll, or tracks jump
## by a texel.
func _publish_globals() -> void:
	RenderingServer.global_shader_parameter_set(&"snow_deform_origin", _origin)
	RenderingServer.global_shader_parameter_set(&"snow_deform_size", world_size)
	RenderingServer.global_shader_parameter_set(&"snow_deform_texel", _texel_size)
	RenderingServer.global_shader_parameter_set(&"snow_depth", snow_depth)

#endregion

#region Surface mesh and overlay

## Builds the snow mesh as a child of this node, so a level only ever places the one node.
func _build_surface() -> void:
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(surface_size, surface_size)
	# n quads along a side needs n - 1 interior subdivisions.
	plane.subdivide_width = maxi(surface_subdivisions - 1, 0)
	plane.subdivide_depth = maxi(surface_subdivisions - 1, 0)
	# The vertex shader pushes geometry well outside the flat plane's bounds, so the AABB it reports
	# is wrong and Godot would cull the mesh at grazing angles without this.
	plane.custom_aabb = AABB(
		Vector3(-surface_size * 0.5, -snow_depth - 1.0, -surface_size * 0.5),
		Vector3(surface_size, snow_depth + max_rim_height + 2.0, surface_size)
	)

	var shader: Shader = load(_SURFACE_SHADER) as Shader
	_surface_material = ShaderMaterial.new()
	_surface_material.shader = shader
	_surface_material.set_shader_parameter(&"terrain_y", get_terrain_height(Vector2.ZERO))

	_surface = MeshInstance3D.new()
	_surface.name = "SnowSurface"
	_surface.mesh = plane
	_surface.material_override = _surface_material
	_surface.extra_cull_margin = snow_depth + max_rim_height + 1.0
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_surface)
	_follow_surface()


## Keeps the mesh under the focus, snapped to its own vertex spacing so vertices never swim between
## displaced heights.
func _follow_surface() -> void:
	if _surface == null or not is_instance_valid(_surface):
		return
	var spacing: float = surface_size / float(maxi(surface_subdivisions, 1))
	var centre: Vector2 = Vector2.ZERO
	if _focus != null and is_instance_valid(_focus):
		centre = Vector2(_focus.global_position.x, _focus.global_position.z)
	_surface.global_position = Vector3(
		snappedf(centre.x, spacing),
		0.0,
		snappedf(centre.y, spacing)
	)


## The R, G and B of the deformation texture in the corner, for checking stamps land where intended.
## Created from code, so it is this code that hides it rather than a scene saved with a hidden root.
func _build_overlay() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "SnowDebugOverlay"
	layer.layer = 128
	_overlay = TextureRect.new()
	_overlay.name = "DeformTexture"
	_overlay.texture = _texture
	_overlay.custom_minimum_size = _OVERLAY_SIZE
	_overlay.size = _OVERLAY_SIZE
	_overlay.position = Vector2(16.0, 16.0)
	_overlay.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	# Without this a TextureRect reports the texture's own 1024 px as its minimum size and fills the
	# screen, whatever size it was given.
	_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var overlay_material: ShaderMaterial = ShaderMaterial.new()
	overlay_material.shader = load(_OVERLAY_SHADER) as Shader
	overlay_material.set_shader_parameter(&"snow_depth_m", snow_depth)
	overlay_material.set_shader_parameter(&"rim_height_m", max_rim_height)
	_overlay.material = overlay_material
	_overlay.visible = debug_overlay
	layer.add_child(_overlay)
	add_child(layer)

#endregion


#region Render thread
# Nothing below here may touch the scene tree.

func _init_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or _scroll_file == null or _update_file == null:
		return

	var fmt: RDTextureFormat = RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = resolution
	fmt.height = resolution
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	var view: RDTextureView = RDTextureView.new()
	_display = _rd.texture_create(fmt, view, [])
	_scratch = _rd.texture_create(fmt, view, [])
	_rd.texture_clear(_display, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	_rd.texture_clear(_scratch, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)

	_update_shader = _rd.shader_create_from_spirv(_update_file.get_spirv())
	_scroll_shader = _rd.shader_create_from_spirv(_scroll_file.get_spirv())
	if not _update_shader.is_valid() or not _scroll_shader.is_valid():
		push_error("SnowDeformation: a compute shader failed to compile, so deformation is off.")
		_free_compute()
		return
	_update_pipeline = _rd.compute_pipeline_create(_update_shader)
	_scroll_pipeline = _rd.compute_pipeline_create(_scroll_shader)

	# One buffer at the cap, refilled each frame, so the uniform set below is built once and the RID
	# it holds never changes.
	_stamp_buffer = _rd.storage_buffer_create(max_stamps_per_frame * STAMP_FLOATS * 4)

	_update_set = _rd.uniform_set_create([
		_image_uniform(_display, 0),
		_buffer_uniform(_stamp_buffer, 1),
	], _update_shader, 0)
	_scroll_set = _rd.uniform_set_create([
		_image_uniform(_display, 0),
		_image_uniform(_scratch, 1),
	], _scroll_shader, 0)

	# The sampling side never learns a new RID: display stays put for the node's whole life and the
	# scroll pass copies back into it. Swapping this per frame is what makes tracks flicker.
	_texture.texture_rd_rid = _display
	# Publishing the texture itself is deliberately left to the main thread, in _process: a global
	# shader parameter set from here does not reach any material, and the snow renders flat with no
	# error to say why.
	_compute_ready = true


func _image_uniform(texture: RID, binding: int) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func _buffer_uniform(buffer: RID, binding: int) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _render_frame(payload: PackedFloat32Array, count: int, delta: float, origin: Vector2, shift: Vector2i) -> void:
	if not _compute_ready:
		return
	if shift != Vector2i.ZERO:
		if absi(shift.x) >= resolution or absi(shift.y) >= resolution:
			# Further than the window is wide: everything in it is out of date, so a clear is both
			# cheaper and more correct than a scroll.
			_rd.texture_clear(_display, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
		else:
			_run_scroll(shift)
	if count <= 0 and delta <= 0.0:
		return
	if count > 0:
		_rd.buffer_update(_stamp_buffer, 0, payload.size() * 4, payload.to_byte_array())
	_run_update(count, delta, origin)


func _run_scroll(shift: Vector2i) -> void:
	var push: PackedByteArray = PackedInt32Array([shift.x, shift.y, 0, 0]).to_byte_array()
	var groups: int = _group_count()
	var list: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _scroll_pipeline)
	_rd.compute_list_bind_uniform_set(list, _scroll_set, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_end()
	# Back into display, so everything sampling the Texture2DRD keeps the same RID.
	_rd.texture_copy(_scratch, _display, Vector3.ZERO, Vector3.ZERO, Vector3(resolution, resolution, 1), 0, 0, 0, 0)


func _run_update(count: int, delta: float, origin: Vector2) -> void:
	# 16 floats, 64 bytes, matching the push_constant block in snow_update.glsl exactly.
	var push: PackedByteArray = PackedFloat32Array([
		origin.x, origin.y, _texel_size, delta,
		snow_depth, refill_rate_geo, refill_rate_mask, max_rim_height,
		noise_scale, noise_strength, float(count), 0.0,
		0.0, 0.0, 0.0, 0.0,
	]).to_byte_array()
	var groups: int = _group_count()
	var list: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _update_pipeline)
	_rd.compute_list_bind_uniform_set(list, _update_set, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_end()


func _group_count() -> int:
	return (resolution + _GROUP_SIZE - 1) / _GROUP_SIZE


func _render_clear() -> void:
	if _compute_ready:
		_rd.texture_clear(_display, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)


func _free_compute() -> void:
	if _rd == null:
		return
	# Uniform sets first: they reference the textures and the buffer.
	for rid: RID in [_update_set, _scroll_set, _update_pipeline, _scroll_pipeline, _update_shader, _scroll_shader, _stamp_buffer, _display, _scratch]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_update_set = RID()
	_scroll_set = RID()
	_update_pipeline = RID()
	_scroll_pipeline = RID()
	_update_shader = RID()
	_scroll_shader = RID()
	_stamp_buffer = RID()
	_display = RID()
	_scratch = RID()

#endregion

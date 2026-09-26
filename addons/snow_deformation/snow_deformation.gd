# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
@tool
@icon("res://addons/snow_deformation/assets/icons/snow_deformation_icon.svg")
class_name SnowDeformation
extends Node3D
## Real-time deformable snow: one node to drop into a level.
##
## Keeps an [code]RGBA16F[/code] texture of the snow around a focus node (the player by default) and
## exposes it to every material through global shader parameters. [FootStamper] and pressed bodies
## hand it world-space shapes; two compute passes scroll the window as the focus moves
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
## Most steps a single shape is swept in per physics frame, however fast it moved. Enough for a sword
## tip crossing a metre in one frame to leave overlapping capsules.
const MAX_SWEEP_STEPS: int = 16

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
## Microseconds a frame may spend sampling the ground under the window, so a re-bake is spread over frames rather than
## stalling one: at about 3 us a raycast, the window's 12,500 samples take a dozen frames.
const _BAKE_BUDGET_USEC: int = 2000

@export_group("Window")
## The node the deformation window follows. Left empty, the first node in the "Player" group is used,
## and failing that the viewport's current camera, so a level usually needs no wiring at all.
@export var focus_path: NodePath = NodePath()
## Texels along each side of the deformation texture.
@export_enum("512:512", "1024:1024", "2048:2048") var resolution: int = 1024
## How many metres across the window covers. One texel is world_size / resolution.
@export_range(8.0, 256.0, 1.0) var world_size: float = 48.0

@export_group("Map")
## The part of the world, in XZ, the snow lies on and keeps every track over, however far from the focus. A second,
## fixed deformation texture covers all of it, [member map_resolution] texels a side, and every stamp is written into it
## as well, so a trail is still there seen from across the map. The window above is only a sharper layer of detail
## that follows the focus; the snow itself stays where it is. Left empty, only the window keeps tracks.
@export var map_rect: Rect2 = Rect2():
	set(value):
		map_rect = value
		_refresh_preview()
## Texels along each side of the map's deformation texture. 2048 over a 512 m map is 25 cm a texel and 32 MB.
@export_enum("1024:1024", "2048:2048", "4096:4096") var map_resolution: int = 2048
## Spacing of the ground heights baked under the whole map, once, as the level loads.
@export_range(0.5, 8.0, 0.5, "suffix:m") var map_ground_cell: float = 2.0:
	set(value):
		map_ground_cell = value
		_refresh_preview()

@export_group("Snow")
## Undeformed snow thickness in metres. A stamp can never dig deeper than this.
@export_range(0.0, 2.0, 0.01) var snow_depth: float = 0.35:
	set(value):
		snow_depth = value
		_on_depth_changed()
## Ceiling on the berm a stamp may raise, in metres.
@export_range(0.0, 1.0, 0.01) var max_rim_height: float = 0.12
## Where the ground under the snow is. Left empty, a flat provider at y = 0 is used.
@export var terrain_height_provider: SnowTerrainHeight = null:
	set(value):
		terrain_height_provider = value
		_refresh_preview()

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
@export var create_surface: bool = true:
	set(value):
		create_surface = value
		_refresh_preview()
## How many metres across the snow mesh's fine centre is. Smaller than [member world_size], so tracks survive
## leaving it and are still there on the way back.
@export_range(4.0, 128.0, 1.0) var surface_size: float = 32.0:
	set(value):
		surface_size = value
		_refresh_preview()
## Rings of coarser mesh round the fine centre, each twice as wide as the one inside it with its vertices twice as far
## apart, so the snow reaches far off for few more vertices: five take a 32 m centre to a kilometre. The mesh follows
## the focus in steps of its coarsest spacing, so no vertex ever swims. 0 is the fine centre alone.
@export_range(0, 8, 1) var surface_rings: int = 0:
	set(value):
		surface_rings = value
		_refresh_preview()
## Metres over which the snow thins to nothing at the mesh's edge, so it meets the ground beyond at ground level
## rather than standing proud of it as a ledge.
@export_range(0.0, 16.0, 0.5, "suffix:m") var surface_edge_taper: float = 4.0:
	set(value):
		surface_edge_taper = value
		_refresh_preview()
## Quads along each side of the snow mesh's centre, and of each ring. 256 over 32 m is a vertex every 12.5 cm.
@export_range(16, 512, 16) var surface_subdivisions: int = 256:
	set(value):
		surface_subdivisions = value
		_refresh_preview()

@export_group("Bodies")
## Let physics bodies moving through the snow press it, the same way a [GrassField] is pressed: a
## barrel, a ball, a ragdoll, a boulder. A body that carries its own [FootStamper]
## is left alone, because that component already describes its shape far better than a sphere does.
@export var press_bodies: bool = true:
	set(value):
		press_bodies = value
		if _press_area != null and is_instance_valid(_press_area):
			_press_area.monitoring = value
			if not value:
				_pressers.clear()
## How hard the snow holds back a rigid body ploughing through it: newtons for each metre per second
## of speed, per square metre of the body pushed through the snow. It does not scale with mass, so a
## beach ball kicked at 6 m/s through 35 cm of snow stops after about 1.8 m, while a boulder
## ploughs on. 0 lets bodies roll as though the
## snow were not there.
@export_range(0.0, 50.0, 0.1, "suffix:N s/m3") var press_drag: float = 1.5
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

@export_group("Uneven ground")
## Spacing of the ground heights the snow surface is laid over, when the ground is not flat. The manager samples
## [member terrain_height_provider] under the window at this spacing and hands the shader the result, so the snow
## follows any terrain that provider can see: a [SnowTerrainHeightRaycast] sees anything with collision, which is
## how HTerrain, Terrain3D and MTerrain all work. A flat provider skips this entirely.
@export_range(0.1, 4.0, 0.05, "suffix:m") var ground_cell: float = 0.5:
	set(value):
		ground_cell = value
		_refresh_preview()

@export_group("Kicked snow")
## Throw clumps of snow forward from feet moving through it (see [method kick]).
@export var kick_snow: bool = true
## Clumps in one kick.
@export_range(1, 64, 1) var kick_burst: int = 8
## Kicks that can be in the air at once: a pool of one-shot emitters, reused in turn.
@export_range(1, 64, 1) var kick_pool: int = 24
## Size of one clump.
@export_range(0.01, 0.2, 0.005, "suffix:m") var kick_clump_size: float = 0.04

@export_group("Packed snow floor")
## Physics layers of a collider laid on the snow's surface. A body that masks one of them rides on the
## snow, as a [Snowball] or a sled should; everything else (feet, hooves, a beach ball, a round) sinks
## through to the ground underneath and presses the snow on the way. 0 lays no floor.
@export_flags_3d_physics var floor_layer: int = 1 << 12
## How far into the snow the floor sits below its surface: how much a body riding on it sinks.
@export_range(0.0, 0.3, 0.005, "suffix:m") var floor_sink: float = 0.03
## Spacing of the floor's height samples. Only matters over uneven ground.
@export_range(0.25, 4.0, 0.25, "suffix:m") var floor_cell: float = 1.0
## How far the focus moves before the floor is rebuilt around it. It covers the whole window plus this.
@export_range(1.0, 16.0, 1.0, "suffix:m") var floor_step: float = 4.0

@export_group("Wind")
## The wind over the snow, in metres per second, which way and how hard. A [Snowball] catches it and rolls
## away downwind, growing as it goes. Wire a weather system to [method set_wind] in the scene.
@export var wind: Vector3 = Vector3.ZERO
## Metres per second for each unit of strength handed to [method set_wind], for a weather system whose
## wind strength is in units of its own.
@export_range(0.0, 5.0, 0.01) var wind_scale: float = 1.0

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
## The coarser rings round [member _surface], which cast no shadow: the terrain under them already casts the hills'.
var _rings: MeshInstance3D = null
var _surface_material: ShaderMaterial = null
var _overlay: TextureRect = null
var _press_area: Area3D = null
var _floor: StaticBody3D = null
var _ground_texture: ImageTexture = null
var _ground_centre: Vector2 = Vector2(INF, INF)
var _ground_low: float = 0.0
var _ground_high: float = 0.0
var _spray: Node3D = null
var _kicks: Array[GPUParticles3D] = []
var _next_kick: int = 0
var _floor_shape: HeightMapShape3D = null
## How deep the snow has been dug out at each floor sample, by world sample, so the floor lies in the trench and a
## snowball resting there drops into it. Kept by world position, so a trench is still there when the floor comes back.
var _dug: Dictionary[Vector2i, float] = {}
## The floor's heights as laid, before digging, and as they are now; the second goes to the shape when it changes.
var _floor_base: PackedFloat32Array = PackedFloat32Array()
var _floor_heights: PackedFloat32Array = PackedFloat32Array()
var _floor_dirty: bool = false
var _floor_centre: Vector2 = Vector2(INF, INF)
## Bodies currently inside the press area, and the radius and underside each one was measured at.
var _pressers: Array[Node3D] = []
var _press_shape: Dictionary[Node3D, Vector2] = {}
## Each body's shapes as world-space segments on the last physics frame, so a fast one is swept.
var _press_previous: Dictionary[Node3D, Array] = {}
## Where each body last made a crush, so the next one waits until it has ploughed a bit further.
var _press_last_heard: Dictionary[Node3D, Vector3] = {}
var _press_voices: Array[AudioStreamPlayer3D] = []
var _next_voice: int = 0

## Packed stamps for this frame, uploaded once and then cleared.
var _stamps: PackedFloat32Array = PackedFloat32Array()
var _texture: Texture2DRD = null
var _map_texture: Texture2DRD = null
var _map_display: RID = RID()
var _map_update_set: RID = RID()
var _map_ground: ImageTexture = null
var _map_low: float = INF
var _map_high: float = -INF
## Where this frame's stamps reach, so the map's pass covers only those texels.
var _stamp_lo: Vector2 = Vector2(INF, INF)
var _stamp_hi: Vector2 = Vector2(-INF, -INF)
## The ground bake under way, a few rows a frame: centre, origin, side, image, row, low, high.
var _bake: Dictionary = {}
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
	_map_texture = Texture2DRD.new()

	if Engine.is_editor_hint():
		_rebuild_preview()
		return

	_resolve_focus()
	_build_press_area()
	_build_floor()
	if kick_snow:
		_build_spray()
	if create_surface:
		_build_surface()
		_bake_map_ground()
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
	if _map_texture != null:
		_map_texture.texture_rd_rid = RID()
	if _compute_ready:
		RenderingServer.call_on_render_thread(_free_compute)
		_compute_ready = false


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		_follow_preview()
		return
	if _focus == null or not is_instance_valid(_focus):
		_resolve_focus()
	var decay_dt: float = _accumulate_refill(delta)
	var scrolled: bool = _snap_origin(false)
	if create_surface:
		_follow_surface()
	_follow_press_area()
	_follow_floor()
	_follow_ground()
	_step_bake()
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
		if _surface_material != null and has_map():
			_surface_material.set_shader_parameter(&"map_deform_tex", _map_texture)
			_surface_material.set_shader_parameter(&"use_map_tracks", true)
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
	RenderingServer.call_on_render_thread(_render_frame.bind(payload, count, decay_dt, _origin, shift, _map_region(count, decay_dt)))
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
	# The whole deformable window, centred on the focus's height and as tall as the window is wide, so a body on a
	# hillside up to 45 degrees above or below the focus is still pressed, and one falling into the snow is already
	# being tracked when it arrives. At a fixed height it missed everything more than four metres up a hill.
	box.size = Vector3(world_size, world_size + snow_depth + 10.0, world_size)
	shape.shape = box
	_press_area.add_child(shape)
	_press_area.body_entered.connect(_on_press_body_entered)
	_press_area.body_exited.connect(_on_press_body_exited)
	add_child(_press_area)
	_follow_press_area()


func _follow_press_area() -> void:
	if _press_area == null or not is_instance_valid(_press_area):
		return
	var height: float = _focus.global_position.y if _focus != null and is_instance_valid(_focus) else global_position.y
	_press_area.global_position = Vector3(_origin.x + world_size * 0.5, height, _origin.y + world_size * 0.5)


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
	_press_previous.erase(body)
	_press_last_heard.erase(body)


## A body that already stamps for itself is skipped: the Player's feet describe far
## more than a sphere around the body's origin would, and pressing both would bury the prints.
static func _has_own_stamper(body: Node) -> bool:
	for child: Node in body.get_children():
		if child is FootStamper:
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
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _floor_dirty and _floor_shape != null:
		_floor_dirty = false
		_floor_shape.map_data = _floor_heights
	if not press_bodies or _pressers.is_empty():
		return
	_pressers = _pressers.filter(is_instance_valid)
	if _pressers.size() > max_pressed_bodies:
		_pressers.sort_custom(_presses_more)
	var pressed: int = 0
	for body: Node3D in _pressers:
		var measured: Vector2 = _press_shape.get(body, Vector2(press_radius_fallback, press_radius_fallback))
		var at: Vector3 = body.global_position
		var bottom: float = at.y - measured.y
		var top: float = get_undeformed_surface_height(Vector2(at.x, at.z))
		# Every rigid body in the snow is held back, not only those with a stamp slot this frame.
		# A body riding the floor (a snowball) is not held back: it rolls on packed snow and answers for its own
		# ploughing, and this drag on top of it held a ball rolling down a hill to walking pace.
		if body is RigidBody3D and bottom < top and not _rides_floor(body):
			hold_back(body as RigidBody3D, measured.x, clampf(top - bottom, 0.0, snow_depth), delta)
		if pressed >= max_pressed_bodies:
			continue
		if _press_body(body):
			_crush_heard(body, at)
			pressed += 1


## Presses [param body]'s own collision shapes into the snow, each swept from where it was on the last
## physics frame so a sword slash, which covers metres in a couple of frames, cuts one continuous
## gouge rather than a dotted line. True when any part of it was below the surface.
func _press_body(body: Node3D) -> bool:
	if not body.is_visible_in_tree():
		# A pickup already taken, or a weapon put away, presses nothing, and must not sweep a cut from
		# wherever it was hidden once it is shown again.
		_press_previous.erase(body)
		return false
	var now: Array[Dictionary] = _segments(body as CollisionObject3D, press_radius_fallback)
	var before: Array = _press_previous.get(body, [])
	_press_previous[body] = now
	var cut: bool = false
	for k: int in now.size():
		var seg: Dictionary = now[k]
		var was: Dictionary = before[k] if k < before.size() else seg
		var radius: float = seg["radius"]
		var travel: float = maxf((seg["a"] as Vector3).distance_to(was["a"]), (seg["b"] as Vector3).distance_to(was["b"]))
		var count: int = clampi(ceili(travel / maxf(radius * 0.5, 0.005)), 1, MAX_SWEEP_STEPS)
		for i: int in range(1, count + 1):
			var t: float = float(i) / float(count)
			if press_segment((was["a"] as Vector3).lerp(seg["a"], t), (was["b"] as Vector3).lerp(seg["b"], t), radius, 0.35, 0.25, not _rides_floor(body)):
				cut = true
	return cut


## Presses the part of a segment [param radius] thick, from [param a] to [param b], that is under the
## snow. One end above the surface is moved to where the segment crosses it, so a blade dipped into the
## snow cuts only as far as it went in rather than a trench stretched up to the hilt.
## True for a body that rides on the packed floor (a snowball, a sled): what it presses does not dig the floor out
## from under itself, or it would sink through its own track.
func _rides_floor(body: Node3D) -> bool:
	return body is CollisionObject3D and ((body as CollisionObject3D).collision_mask & floor_layer) != 0


## [param digs_floor] false leaves the packed floor where it is: the pressing is only seen, not stood in.
func press_segment(a: Vector3, b: Vector3, radius: float, rim_factor: float = 0.35, wall_softness: float = 0.25, digs_floor: bool = true) -> bool:
	var low_a: Vector3 = a - Vector3(0.0, radius, 0.0)
	var low_b: Vector3 = b - Vector3(0.0, radius, 0.0)
	var depth_a: float = get_undeformed_surface_height(Vector2(low_a.x, low_a.z)) - low_a.y
	var depth_b: float = get_undeformed_surface_height(Vector2(low_b.x, low_b.z)) - low_b.y
	if depth_a <= 0.0 and depth_b <= 0.0:
		return false # Entirely above the snow.
	if depth_a <= 0.0 or depth_b <= 0.0:
		var at: Vector3 = low_a.lerp(low_b, clampf(depth_a / (depth_a - depth_b), 0.0, 1.0))
		if depth_a > 0.0:
			low_b = at
			depth_b = 0.0
		else:
			low_a = at
			depth_a = 0.0
	add_capsule(low_a, low_b, radius, clampf(depth_a, 0.0, snow_depth), clampf(depth_b, 0.0, snow_depth), rim_factor, wall_softness, 0.4, digs_floor)
	return true


## A body's collision shapes as world-space segments with a radius. A sphere is a segment of no
## length, a capsule or a cylinder runs along its own Y, and a box along its longest side, as thick as
## its middle one: a box the shape of a sword blade presses as the blade, not as a ball round the hilt.
## A shape with nothing to measure presses as a sphere of [param fallback] at its own position.
static func _segments(body: CollisionObject3D, fallback: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if body == null:
		return out
	for owner_id: int in body.get_shape_owners():
		if body.is_shape_owner_disabled(owner_id):
			continue
		var xf: Transform3D = body.global_transform * body.shape_owner_get_transform(owner_id)
		var grow: float = maxf(maxf(xf.basis.get_scale().x, xf.basis.get_scale().y), xf.basis.get_scale().z)
		for i: int in body.shape_owner_get_shape_count(owner_id):
			var shape: Shape3D = body.shape_owner_get_shape(owner_id, i)
			var half: Vector3 = Vector3.ZERO
			var radius: float = fallback
			if shape is SphereShape3D:
				radius = (shape as SphereShape3D).radius
			elif shape is CapsuleShape3D:
				var capsule: CapsuleShape3D = shape as CapsuleShape3D
				radius = capsule.radius
				half.y = maxf(capsule.height * 0.5 - capsule.radius, 0.0)
			elif shape is CylinderShape3D:
				var cylinder: CylinderShape3D = shape as CylinderShape3D
				radius = cylinder.radius
				half.y = cylinder.height * 0.5
			elif shape is BoxShape3D:
				var extent: Vector3 = (shape as BoxShape3D).size * 0.5
				var longest: int = extent.max_axis_index()
				var shortest: int = extent.min_axis_index()
				if longest == shortest:
					radius = extent.x # A cube: every side is the same.
				else:
					radius = extent[3 - longest - shortest]
					half[longest] = maxf(extent[longest] - radius, 0.0)
			out.append({"a": xf * -half, "b": xf * half, "radius": radius * grow})
	if out.is_empty():
		out.append({"a": body.global_position, "b": body.global_position, "radius": fallback})
	return out


## Slows [param body]'s horizontal motion for the snow it is ploughing: [param radius] wide, [param sunk]
## metres deep, for [param delta] seconds. Applied as the exact exponential decay of a linear drag
## rather than as a force, so a very light body is stopped rather than flung back the other way.
func hold_back(body: RigidBody3D, radius: float, sunk: float, delta: float) -> void:
	if press_drag <= 0.0 or sunk <= 0.0 or body.freeze or body.mass <= 0.0:
		return
	var along: Vector3 = Vector3(body.linear_velocity.x, 0.0, body.linear_velocity.z)
	if along.is_zero_approx():
		return
	var area: float = 2.0 * radius * sunk # The face it pushes through the snow.
	var kept: float = exp(-press_drag * area * delta / body.mass)
	body.linear_velocity -= along * (1.0 - kept)
	body.angular_velocity *= kept


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
func add_footprint(pos: Vector3, yaw: float, half_width: float, half_length: float, depth: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4, digs_floor: bool = true) -> void:
	_push(_pack(SHAPE_ELLIPSE, pos, pos, half_width, half_length, yaw, rim_factor, depth, depth * 0.7, wall_softness, rim_width), digs_floor)


## Queue a capsule from [param a] to [param b]: a drag mark, or any body wading through.
func add_capsule(a: Vector3, b: Vector3, radius: float, depth_a: float, depth_b: float, rim_factor: float = 0.35, wall_softness: float = 0.25, rim_width: float = 0.4, digs_floor: bool = true) -> void:
	_push(_pack(SHAPE_CAPSULE, a, b, radius, radius, 0.0, rim_factor, depth_a, depth_b, wall_softness, rim_width), digs_floor)


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
	_dug.clear()
	if _floor_shape != null and _floor_base.size() == _floor_shape.map_width * _floor_shape.map_depth:
		_lay_floor(_floor_base.duplicate())
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
	_stamp_lo = Vector2(INF, INF)
	_stamp_hi = Vector2(-INF, -INF)


## The map's texels this frame's pass must cover: those round its stamps, all of it while refill is fading the snow
## back, and none at all when there is nothing to do.
func _map_region(count: int, decay_dt: float) -> Rect2i:
	if not has_map():
		return Rect2i()
	if decay_dt > 0.0:
		return Rect2i(0, 0, map_resolution, map_resolution)
	if count <= 0:
		return Rect2i()
	var texel: float = map_texel()
	var lo: Vector2i = (Vector2i(((_stamp_lo - map_rect.position) / texel).floor()) - Vector2i(2, 2)).clamp(Vector2i.ZERO, Vector2i(map_resolution, map_resolution))
	var hi: Vector2i = (Vector2i(((_stamp_hi - map_rect.position) / texel).ceil()) + Vector2i(2, 2)).clamp(Vector2i.ZERO, Vector2i(map_resolution, map_resolution))
	if hi.x <= lo.x or hi.y <= lo.y:
		return Rect2i()
	return Rect2i(lo, hi - lo)


func _push(stamp: PackedFloat32Array, digs_floor: bool = true) -> void:
	stamps_this_frame += 1
	stamps_total += 1
	if digs_floor:
		_dig(stamp)
	if not enabled:
		return
	if _stamps.size() / STAMP_FLOATS >= max_stamps_per_frame:
		dropped_stamps += 1
		return
	_stamps.append_array(stamp)
	# How far this stamp's print and berm can reach, for the map's pass.
	var reach: float = maxf(stamp[8], stamp[9]) * (1.0 + stamp[15] + noise_strength)
	_stamp_lo = _stamp_lo.min(Vector2(minf(stamp[0], stamp[4]) - reach, minf(stamp[2], stamp[6]) - reach))
	_stamp_hi = _stamp_hi.max(Vector2(maxf(stamp[0], stamp[4]) + reach, maxf(stamp[2], stamp[6]) + reach))

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

#region Kicked snow

## The clumps a foot throws: a pool of one-shot emitters, each moved to the foot, aimed and restarted for one kick.
## Plain one-shots rather than [method GPUParticles3D.emit_particle], which drew nothing here and which the
## Compatibility renderer does not have.
func _build_spray() -> void:
	_spray = Node3D.new()
	_spray.name = "KickedSnow"
	add_child(_spray)
	# A lumpy little sphere lit like the snow it came from; a flat quad read as a grey square.
	var clump: SphereMesh = SphereMesh.new()
	clump.radius = kick_clump_size * 0.5
	clump.height = kick_clump_size * 0.8
	clump.radial_segments = 6
	clump.rings = 3
	var look: StandardMaterial3D = StandardMaterial3D.new()
	look.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	look.vertex_color_use_as_albedo = true
	look.albedo_color = Color(0.97, 0.98, 1.0)
	look.roughness = 0.85
	look.rim_enabled = true
	look.rim = 0.4
	clump.material = look
	var fade: Gradient = Gradient.new()
	fade.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	fade.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	fade.add_point(0.7, Color(1.0, 1.0, 1.0, 1.0))
	var ramp: GradientTexture1D = GradientTexture1D.new()
	ramp.gradient = fade
	for i: int in kick_pool:
		var emitter: GPUParticles3D = GPUParticles3D.new()
		emitter.name = "Kick%d" % i
		emitter.amount = kick_burst
		emitter.one_shot = true
		emitter.explosiveness = 0.85
		emitter.lifetime = 1.1
		emitter.local_coords = false
		emitter.emitting = false
		emitter.visibility_aabb = AABB(Vector3(-4.0, -2.0, -4.0), Vector3(8.0, 6.0, 8.0))
		var process: ParticleProcessMaterial = ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		process.emission_sphere_radius = 0.07
		process.spread = 25.0
		process.gravity = Vector3(0.0, -9.8, 0.0)
		process.damping_min = 0.5 # Air drag on a loose clump.
		process.damping_max = 1.5
		process.scale_min = 0.5
		process.scale_max = 1.4
		process.angle_min = -180.0
		process.angle_max = 180.0
		process.color_ramp = ramp
		emitter.process_material = process
		emitter.draw_pass_1 = clump
		_spray.add_child(emitter)
		_kicks.append(emitter)


## Throws a kick of snow from [param at] (on the snow's surface) along [param velocity] with some lift, as a foot
## pushed through the snow does. [param clumps] up to [member kick_burst] of them.
func kick(at: Vector3, velocity: Vector3, clumps: int) -> void:
	if _kicks.is_empty() or clumps <= 0:
		return
	var emitter: GPUParticles3D = _kicks[_next_kick]
	_next_kick = (_next_kick + 1) % _kicks.size()
	var speed: float = velocity.length()
	var lift: Vector3 = Vector3.UP * 1.4
	var throw: Vector3 = velocity + lift
	var process: ParticleProcessMaterial = emitter.process_material as ParticleProcessMaterial
	process.direction = throw.normalized()
	process.initial_velocity_min = throw.length() * 0.5
	process.initial_velocity_max = throw.length() * 1.1
	emitter.amount_ratio = clampf(float(clumps) / float(kick_burst), 0.0, 1.0)
	emitter.global_position = at
	emitter.restart()

#endregion

#region Uneven ground

## True when the ground is not one flat plane, so the surface needs heights baked for it.
func _ground_is_uneven() -> bool:
	return _provider != null and not (_provider is SnowTerrainHeightFlat)


## Re-samples the ground under the window in [member floor_step] jumps and hands it to the surface shader, so the
## snow lies on hills rather than cutting through them at one height. The first bake is done at once; after that a
## bake runs a few rows a frame ([method _step_bake]) while the last one stays in use, so walking never stalls on it.
func _follow_ground() -> void:
	if _surface_material == null or not _ground_is_uneven():
		return
	var centre: Vector2 = Vector2.ZERO
	if _focus != null and is_instance_valid(_focus):
		centre = Vector2(_focus.global_position.x, _focus.global_position.z)
	centre = Vector2(snappedf(centre.x, floor_step), snappedf(centre.y, floor_step))
	if centre == _ground_centre:
		return
	_ground_centre = centre
	if _ground_texture == null:
		bake_ground(centre)
		return
	_bake = _new_bake(centre)


## Samples the ground in a square round [param centre], wide enough for the whole window, and gives it to the
## surface material as its heightmap, all at once. Returns the image, for a caller that wants to look.
func bake_ground(centre: Vector2) -> Image:
	var job: Dictionary = _new_bake(centre)
	_sample_rows(job, int(job["side"]))
	_apply_bake(job)
	return job["image"]


func _new_bake(centre: Vector2) -> Dictionary:
	var side: int = ceili((world_size + floor_step * 2.0) / ground_cell)
	var span: float = float(side) * ground_cell
	return {
		"centre": centre, "origin": centre - Vector2(span, span) * 0.5, "side": side, "cell": ground_cell,
		"image": Image.create_empty(side, side, false, Image.FORMAT_RF), "row": 0, "low": INF, "high": -INF,
	}


## Samples up to [param rows] more rows of [param job]. True once it has every row.
func _sample_rows(job: Dictionary, rows: int) -> bool:
	var side: int = job["side"]
	var cell: float = job["cell"]
	var origin: Vector2 = job["origin"]
	var image: Image = job["image"]
	var end: int = mini(int(job["row"]) + rows, side)
	for z: int in range(int(job["row"]), end):
		for x: int in side:
			# Each texel's height is taken at its centre, which is where linear filtering reads it back exactly.
			var h: float = get_terrain_height(origin + (Vector2(x, z) + Vector2(0.5, 0.5)) * cell)
			image.set_pixel(x, z, Color(h, 0.0, 0.0))
			job["low"] = minf(job["low"], h)
			job["high"] = maxf(job["high"], h)
	job["row"] = end
	return end >= side


## Carries the bake under way on for [constant _BAKE_BUDGET_USEC], a row at a time, and puts it in use once done.
func _step_bake() -> void:
	if _bake.is_empty():
		return
	var start: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - start < _BAKE_BUDGET_USEC:
		if _sample_rows(_bake, 1):
			_apply_bake(_bake)
			_bake = {}
			return


## Hands a finished bake to the surface material, and to the floor, which lies on the same ground.
func _apply_bake(job: Dictionary) -> void:
	var image: Image = job["image"]
	var side: int = job["side"]
	_ground_low = job["low"]
	_ground_high = job["high"]
	if _ground_texture == null or _ground_texture.get_width() != side:
		_ground_texture = ImageTexture.create_from_image(image)
	else:
		_ground_texture.update(image)
	if _surface_material != null:
		_surface_material.set_shader_parameter(&"use_heightmap", true)
		_surface_material.set_shader_parameter(&"heightmap", _ground_texture)
		_surface_material.set_shader_parameter(&"heightmap_origin", job["origin"])
		_surface_material.set_shader_parameter(&"heightmap_size", float(side) * float(job["cell"]))
		_surface_material.set_shader_parameter(&"heightmap_scale", 1.0)
		_surface_material.set_shader_parameter(&"terrain_y", 0.0)
	_fit_surface_bounds()
	_floor_from_bake(job)


## Bakes the ground under the whole map once, at [member map_ground_cell], for the snow far from the focus to lie on.
func _bake_map_ground() -> void:
	if _surface_material == null or not has_map() or not _ground_is_uneven():
		return
	var cell: float = map_ground_cell
	var side: int = ceili(maxf(map_rect.size.x, map_rect.size.y) / cell)
	var job: Dictionary = {
		"origin": map_rect.position, "side": side, "cell": cell,
		"image": Image.create_empty(side, side, false, Image.FORMAT_RF), "row": 0, "low": INF, "high": -INF,
	}
	_sample_rows(job, side)
	_map_low = job["low"]
	_map_high = job["high"]
	_map_ground = ImageTexture.create_from_image(job["image"])
	_surface_material.set_shader_parameter(&"use_map_heightmap", true)
	_surface_material.set_shader_parameter(&"map_heightmap", _map_ground)
	_surface_material.set_shader_parameter(&"map_heightmap_origin", map_rect.position)
	_surface_material.set_shader_parameter(&"map_heightmap_size", float(side) * cell)
	_fit_surface_bounds()


## True when [member map_rect] gives the snow a map to keep its tracks over.
func has_map() -> bool:
	return map_rect.size.x > 0.0 and map_rect.size.y > 0.0


## Metres per texel of the map's deformation texture, which is square and as wide as the map's longer side.
func map_texel() -> float:
	return maxf(map_rect.size.x, map_rect.size.y) / float(map_resolution)


## The surface mesh is a flat plane the vertex shader lifts, so its bounds have to be told where the snow really is,
## or it is culled on a hillside.
func _fit_surface_bounds() -> void:
	if _surface == null or not is_instance_valid(_surface):
		return
	var low: float = get_terrain_height(Vector2.ZERO)
	var high: float = low
	if _ground_is_uneven() and _ground_low <= _ground_high:
		low = _ground_low
		high = _ground_high
	if _map_low <= _map_high:
		low = minf(low, _map_low)
		high = maxf(high, _map_high)
	var half: float = _surface_half()
	var bounds: AABB = AABB(
		Vector3(-half, low - snow_depth - 1.0, -half),
		Vector3(half * 2.0, (high - low) + 2.0 * snow_depth + max_rim_height + 2.0, half * 2.0)
	)
	_surface.mesh.set(&"custom_aabb", bounds)
	if _rings != null and is_instance_valid(_rings):
		_rings.mesh.set(&"custom_aabb", bounds)
	_surface.extra_cull_margin = snow_depth + max_rim_height + 1.0

#endregion

#region Packed snow floor

## Lays the floor a [Snowball] rides on: a heightmap over the window at the snow's surface less
## [member floor_sink], on [member floor_layer] alone, so only bodies that ask for it stand on it.
func _build_floor() -> void:
	if floor_layer == 0:
		return
	_floor = StaticBody3D.new()
	_floor.name = "SnowFloor"
	_floor.collision_layer = floor_layer
	_floor.collision_mask = 0
	_floor.add_to_group(&"SNOW") # the surface group footsteps and a shield surf go by
	var packed: PhysicsMaterial = PhysicsMaterial.new()
	packed.friction = 1.0
	_floor.physics_material_override = packed
	var holder: CollisionShape3D = CollisionShape3D.new()
	_floor_shape = HeightMapShape3D.new()
	var cells: int = ceili((world_size + floor_step * 2.0) / floor_cell)
	_floor_shape.map_width = cells + 1
	_floor_shape.map_depth = cells + 1
	holder.shape = _floor_shape
	# A heightmap's samples are a metre apart; the node's scale is what spaces them.
	holder.scale = Vector3(floor_cell, 1.0, floor_cell)
	_floor.add_child(holder)
	add_child(_floor)
	_follow_floor()


## Moves the floor with the focus in [member floor_step] jumps, re-sampling the ground under it each
## time, so it is rebuilt a few times a minute rather than every frame.
func _follow_floor() -> void:
	if _floor == null or not is_instance_valid(_floor):
		return
	if _ground_is_uneven() and _surface_material != null:
		return # Laid from each ground bake instead, which has already sampled the same ground.
	var centre: Vector2 = Vector2.ZERO
	if _focus != null and is_instance_valid(_focus):
		centre = Vector2(_focus.global_position.x, _focus.global_position.z)
	centre = Vector2(snappedf(centre.x, floor_step), snappedf(centre.y, floor_step))
	if centre == _floor_centre:
		return
	_floor_centre = centre
	var side: int = _floor_shape.map_width
	var half: float = float(side - 1) * 0.5
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(side * side)
	for z: int in side:
		for x: int in side:
			var at: Vector2 = centre + Vector2(float(x) - half, float(z) - half) * floor_cell
			heights[z * side + x] = get_undeformed_surface_height(at) - floor_sink
	_lay_floor(heights)
	_floor.global_position = Vector3(centre.x, 0.0, centre.y)


## Lays the floor on the ground [param job] sampled, rather than sampling it again: the floor covers the same square
## round the same centre, a metre a sample to the bake's half metre.
func _floor_from_bake(job: Dictionary) -> void:
	if _floor == null or not is_instance_valid(_floor) or not job.has("centre"):
		return
	var centre: Vector2 = job["centre"]
	var image: Image = job["image"]
	var origin: Vector2 = job["origin"]
	var cell: float = job["cell"]
	var last: Vector2 = Vector2(image.get_width() - 1, image.get_height() - 1)
	var side: int = _floor_shape.map_width
	var half: float = float(side - 1) * 0.5
	var lift: float = snow_depth - floor_sink
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(side * side)
	for z: int in side:
		for x: int in side:
			var at: Vector2 = centre + Vector2(float(x) - half, float(z) - half) * floor_cell
			# Bilinear, from the texel centres, as the shader reads the same image.
			var t: Vector2 = ((at - origin) / cell - Vector2(0.5, 0.5)).clamp(Vector2.ZERO, last)
			var i: Vector2i = Vector2i(t.floor()).min(Vector2i(last) - Vector2i.ONE).max(Vector2i.ZERO)
			var f: Vector2 = t - Vector2(i)
			var top: float = lerpf(image.get_pixel(i.x, i.y).r, image.get_pixel(i.x + 1, i.y).r, f.x)
			var bottom: float = lerpf(image.get_pixel(i.x, i.y + 1).r, image.get_pixel(i.x + 1, i.y + 1).r, f.x)
			heights[z * side + x] = lerpf(top, bottom, f.y) + lift
	_floor_centre = centre
	_lay_floor(heights)
	_floor.global_position = Vector3(centre.x, 0.0, centre.y)


## Hands [param heights] (the floor as laid over undisturbed snow) to the shape, lowered wherever the snow was dug.
func _lay_floor(heights: PackedFloat32Array) -> void:
	_floor_base = heights.duplicate()
	var side: int = _floor_shape.map_width
	var first: Vector2i = _floor_first_sample()
	for key: Vector2i in _dug:
		var at: Vector2i = key - first
		if at.x >= 0 and at.y >= 0 and at.x < side and at.y < side:
			heights[at.y * side + at.x] = _floor_base[at.y * side + at.x] - maxf(_dug[key] - floor_sink, 0.0)
	_floor_heights = heights
	_floor_shape.map_data = heights
	_floor_dirty = false


## The world sample (in units of [member floor_cell]) of the floor's first corner.
func _floor_first_sample() -> Vector2i:
	var half: int = (_floor_shape.map_width - 1) / 2
	return Vector2i(roundi(_floor_centre.x / floor_cell), roundi(_floor_centre.y / floor_cell)) - Vector2i(half, half)


## Records how deep [param stamp] dug the snow at the floor samples it covers, and lowers the floor there: a trench
## ploughed under a stacked snowball lets it drop in and the stack come down. A sample within half a cell of the print
## counts, since the floor's samples are a metre apart and a print is narrower.
func _dig(stamp: PackedFloat32Array) -> void:
	if _floor == null or floor_cell <= 0.0:
		return
	var a: Vector2 = Vector2(stamp[0], stamp[2])
	var b: Vector2 = Vector2(stamp[4], stamp[6])
	var ab: Vector2 = b - a
	var reach: float = maxf(stamp[8], stamp[9]) + floor_cell * 0.5
	var lo: Vector2i = Vector2i(((a.min(b) - Vector2(reach, reach)) / floor_cell).ceil())
	var hi: Vector2i = Vector2i(((a.max(b) + Vector2(reach, reach)) / floor_cell).floor())
	var side: int = _floor_shape.map_width if _floor_shape else 0
	var first: Vector2i = _floor_first_sample() if _floor_shape else Vector2i.ZERO
	for z: int in range(lo.y, hi.y + 1):
		for x: int in range(lo.x, hi.x + 1):
			var p: Vector2 = Vector2(x, z) * floor_cell
			var t: float = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0) if ab.length_squared() > 1e-8 else 0.0
			if p.distance_to(a + ab * t) > reach:
				continue
			var key: Vector2i = Vector2i(x, z)
			var depth: float = lerpf(stamp[12], stamp[13], t)
			if depth <= _dug.get(key, 0.0):
				continue
			_dug[key] = depth
			var at: Vector2i = key - first
			if side > 0 and at.x >= 0 and at.y >= 0 and at.x < side and at.y < side and _floor_base.size() == side * side:
				_floor_heights[at.y * side + at.x] = _floor_base[at.y * side + at.x] - maxf(depth - floor_sink, 0.0)
				_floor_dirty = true


## How deep the snow has been dug at [param xz], between the floor samples round it.
func dug_depth(xz: Vector2) -> float:
	if _dug.is_empty() or floor_cell <= 0.0:
		return 0.0
	var g: Vector2 = xz / floor_cell
	var i: Vector2i = Vector2i(g.floor())
	var f: Vector2 = g - Vector2(i)
	var top: float = lerpf(_dug.get(i, 0.0), _dug.get(i + Vector2i(1, 0), 0.0), f.x)
	var bottom: float = lerpf(_dug.get(i + Vector2i(0, 1), 0.0), _dug.get(i + Vector2i(1, 1), 0.0), f.x)
	return lerpf(top, bottom, f.y)


## Everything that depends on the depth, when it changes on a live node: the globals every material reads, the
## floor, the surface mesh's bounds, and the tracks, which were carved into snow of another depth.
func _on_depth_changed() -> void:
	if not is_inside_tree():
		return
	if Engine.is_editor_hint():
		_refresh_preview()
		return
	_publish_globals()
	_floor_centre = Vector2(INF, INF)
	_ground_centre = Vector2(INF, INF)
	_ground_texture = null # re-bakes at once, which lays the floor at the new depth over uneven ground
	_follow_floor()
	_fit_surface_bounds()
	clear()


## Height of the packed snow floor at [param xz]: the undisturbed surface less [member floor_sink], or less as much as
## was dug out there when that is deeper.
func get_floor_height(xz: Vector2) -> float:
	return get_undeformed_surface_height(xz) - maxf(floor_sink, dug_depth(xz))


## True for the floor collider, so a body can tell it is riding on the snow from what it touches.
func is_floor(body: Object) -> bool:
	return body != null and body == _floor


## True where the floor reaches, less a metre at its edge: it covers a square round the focus, and a body
## further out rests on the ground under the snow instead.
func floor_covers(xz: Vector2) -> bool:
	if _floor == null or not is_instance_valid(_floor) or _floor_shape == null:
		return false
	var reach: float = float(_floor_shape.map_width - 1) * 0.5 * floor_cell - 1.0
	var off: Vector2 = (xz - _floor_centre).abs()
	return off.x < reach and off.y < reach


## Sets [member wind] from a weather system's [param strength] and [param direction], as WeatherFX's
## wind_changed hands them over; the strength is scaled by [member wind_scale].
func set_wind(strength: float, direction: Vector3) -> void:
	var flat: Vector3 = Vector3(direction.x, 0.0, direction.z)
	wind = flat.normalized() * strength * wind_scale if not flat.is_zero_approx() else Vector3.ZERO

#endregion

#region Editor preview
# In the editor the snow is drawn where it will lie, undisturbed, so a level can be built to it rather than guessed at:
# the surface mesh and its rings, laid over the ground under the editor's camera and, with a map, under the whole map.
# Nothing else runs there (no compute passes, no floor, no pressing), and nothing it adds is saved with the scene.

var _preview_queued: bool = false


## Rebuilds the preview once, at the end of the frame, after an export that changes it was set in the inspector.
func _refresh_preview() -> void:
	if Engine.is_editor_hint() and is_inside_tree() and not _preview_queued:
		_preview_queued = true
		_rebuild_preview.call_deferred()


func _rebuild_preview() -> void:
	_preview_queued = false
	for old: Node in [_surface, _rings]:
		if old != null and is_instance_valid(old):
			old.queue_free()
	_surface = null
	_rings = null
	_surface_material = null
	_ground_texture = null
	_ground_centre = Vector2(INF, INF)
	_map_low = INF
	_map_high = -INF
	_bake = {}
	_provider = terrain_height_provider if terrain_height_provider != null else SnowTerrainHeightFlat.new()
	_provider.setup(get_world_3d())
	_texel_size = world_size / float(resolution)
	_focus = _editor_camera()
	if create_surface:
		_build_surface()
		_bake_map_ground()
	_snap_origin(true)
	_publish_globals()


## The surface follows the editor's camera as it would the Player.
func _follow_preview() -> void:
	var camera: Node3D = _editor_camera()
	if camera != null:
		_focus = camera
	if _surface == null or not is_instance_valid(_surface):
		return
	if _snap_origin(false):
		_publish_globals()
	_follow_surface()
	_follow_ground()
	_step_bake()


## The camera of the editor's first 3D viewport, or null outside the editor. Reached through the engine's singleton
## list, so the script still compiles in an exported game, which has no editor classes.
func _editor_camera() -> Node3D:
	if not Engine.has_singleton(&"EditorInterface"):
		return null
	var editor: Object = Engine.get_singleton(&"EditorInterface")
	var viewport: Object = editor.call(&"get_editor_viewport_3d", 0)
	return viewport.call(&"get_camera_3d") as Node3D if viewport != null else null

#endregion

#region Surface mesh and overlay

## Builds the snow mesh as a child of this node, so a level only ever places the one node.
func _build_surface() -> void:
	var plane: Mesh = null
	if surface_rings > 0:
		plane = _ring_mesh(0, 0)
	else:
		var square: PlaneMesh = PlaneMesh.new()
		square.size = Vector2(surface_size, surface_size)
		# n quads along a side needs n - 1 interior subdivisions.
		square.subdivide_width = maxi(surface_subdivisions - 1, 0)
		square.subdivide_depth = maxi(surface_subdivisions - 1, 0)
		plane = square
	# The vertex shader pushes geometry well outside the flat plane's bounds, so the AABB it reports
	# is wrong and Godot would cull the mesh at grazing angles without this.
	var half: float = _surface_half()
	plane.set(&"custom_aabb", AABB(
		Vector3(-half, -snow_depth - 1.0, -half),
		Vector3(half * 2.0, snow_depth + max_rim_height + 2.0, half * 2.0)
	))

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
	if surface_rings > 0:
		var rings: ArrayMesh = _ring_mesh(1, surface_rings)
		rings.custom_aabb = plane.get(&"custom_aabb")
		_rings = MeshInstance3D.new()
		_rings.name = "SnowRings"
		_rings.mesh = rings
		_rings.material_override = _surface_material
		_rings.extra_cull_margin = _surface.extra_cull_margin
		# Every shadow pass runs the vertex shader again, and these are most of the vertices; the terrain under them
		# casts the hills' shadows already.
		_rings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_rings)
	_follow_surface()


## Half the width of the whole snow mesh, rings and all.
func _surface_half() -> float:
	return surface_size * 0.5 * float(1 << surface_rings)


## Levels [param first] to [param last] of the snow mesh as one mesh: level 0 is the fine centre, and each level after
## it a ring, the grid of the one inside at twice the spacing, less the middle that one already covers. Every other
## vertex on a level's outer edge falls between two of the next ring's, so it carries in UV2 the offset to its
## neighbours along the edge and the shader puts it on the line between them: the rings meet without a crack.
func _ring_mesh(first: int, last: int) -> ArrayMesh:
	var n: int = maxi(surface_subdivisions / 4 * 4, 4) # a ring's hole is the middle half, so n/2 must be even
	var s0: float = surface_size / float(n)
	var vertices: PackedVector3Array = PackedVector3Array()
	var offsets: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()
	# The vertices on the edge the next ring shares, by position in units of the finest spacing.
	var shared: Dictionary[Vector2i, int] = {}
	for level: int in range(first, last + 1):
		var step: int = 1 << level
		var half: int = n / 2 * step
		var hole: int = half / 2 if level > 0 else -1
		var ids: PackedInt32Array = PackedInt32Array()
		ids.resize((n + 1) * (n + 1))
		ids.fill(-1)
		var next_shared: Dictionary[Vector2i, int] = {}
		for gz: int in n + 1:
			for gx: int in n + 1:
				var x: int = -half + gx * step
				var z: int = -half + gz * step
				var inside: bool = absi(x) < hole and absi(z) < hole
				if inside:
					continue
				var key: Vector2i = Vector2i(x, z)
				var id: int = shared.get(key, -1)
				if id < 0:
					id = vertices.size()
					vertices.append(Vector3(float(x) * s0, 0.0, float(z) * s0))
					var offset: Vector2 = Vector2.ZERO
					if level < surface_rings:
						if (gx == 0 or gx == n) and gz % 2 == 1:
							offset = Vector2(0.0, float(step) * s0)
						elif (gz == 0 or gz == n) and gx % 2 == 1:
							offset = Vector2(float(step) * s0, 0.0)
					offsets.append(offset)
				ids[gz * (n + 1) + gx] = id
				if gx == 0 or gx == n or gz == 0 or gz == n:
					next_shared[key] = id
		for cz: int in n:
			for cx: int in n:
				var a: int = ids[cz * (n + 1) + cx]
				var b: int = ids[cz * (n + 1) + cx + 1]
				var c: int = ids[(cz + 1) * (n + 1) + cx]
				var d: int = ids[(cz + 1) * (n + 1) + cx + 1]
				if a < 0 or b < 0 or c < 0 or d < 0:
					continue # in the hole the ring inside fills
				# Clockwise seen from above, which is Godot's front face.
				indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
		shared = next_shared
	var normals: PackedVector3Array = PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV2] = offsets
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Keeps the mesh under the focus, snapped to its coarsest vertex spacing, which every ring's spacing divides, so no
## vertex ever swims between displaced heights.
func _follow_surface() -> void:
	if _surface == null or not is_instance_valid(_surface):
		return
	var spacing: float = surface_size / float(maxi(surface_subdivisions, 1)) * float(1 << surface_rings)
	var centre: Vector2 = Vector2.ZERO
	if _focus != null and is_instance_valid(_focus):
		centre = Vector2(_focus.global_position.x, _focus.global_position.z)
	_surface.global_position = Vector3(
		snappedf(centre.x, spacing),
		0.0,
		snappedf(centre.y, spacing)
	)
	if _rings != null and is_instance_valid(_rings):
		_rings.global_position = _surface.global_position
	if _surface_material != null:
		_surface_material.set_shader_parameter(&"surface_centre", Vector2(_surface.global_position.x, _surface.global_position.z))
		_surface_material.set_shader_parameter(&"surface_half", _surface_half())
		_surface_material.set_shader_parameter(&"surface_edge_taper", surface_edge_taper)
		if has_map():
			_surface_material.set_shader_parameter(&"use_map_edge", true)
			_surface_material.set_shader_parameter(&"map_rect_min", map_rect.position)
			_surface_material.set_shader_parameter(&"map_rect_max", map_rect.end)
			_surface_material.set_shader_parameter(&"map_origin", map_rect.position)
			_surface_material.set_shader_parameter(&"map_size", maxf(map_rect.size.x, map_rect.size.y))
			_surface_material.set_shader_parameter(&"map_texel", map_texel())


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

	# The map's own texture: fixed to the world, so it never scrolls and needs no scratch copy.
	if has_map():
		var map_fmt: RDTextureFormat = RDTextureFormat.new()
		map_fmt.format = fmt.format
		map_fmt.width = map_resolution
		map_fmt.height = map_resolution
		map_fmt.usage_bits = fmt.usage_bits
		_map_display = _rd.texture_create(map_fmt, RDTextureView.new(), [])
		_rd.texture_clear(_map_display, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
		_map_update_set = _rd.uniform_set_create([
			_image_uniform(_map_display, 0),
			_buffer_uniform(_stamp_buffer, 1),
		], _update_shader, 0)
		_map_texture.texture_rd_rid = _map_display
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


func _render_frame(payload: PackedFloat32Array, count: int, delta: float, origin: Vector2, shift: Vector2i, map_region: Rect2i) -> void:
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
	_run_update(_update_set, count, delta, origin, _texel_size, 0.0, Rect2i(0, 0, resolution, resolution))
	if _map_update_set.is_valid() and map_region.has_area():
		# A print narrower than a map texel would fall between texel centres and leave nothing there.
		var texel: float = map_texel()
		_run_update(_map_update_set, count, delta, map_rect.position, texel, texel * 0.75, map_region)


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


## Applies the stamps (and refill) to the texture in [param uniform_set], whose min corner is at [param origin] with
## [param texel] metres a texel, over only the texels in [param region].
func _run_update(uniform_set: RID, count: int, delta: float, origin: Vector2, texel: float, min_radius: float, region: Rect2i) -> void:
	# 16 floats, 64 bytes, matching the push_constant block in snow_update.glsl exactly.
	var push: PackedByteArray = PackedFloat32Array([
		origin.x, origin.y, texel, delta,
		snow_depth, refill_rate_geo, refill_rate_mask, max_rim_height,
		noise_scale, noise_strength, float(count), min_radius,
		float(region.position.x), float(region.position.y), 0.0, 0.0,
	]).to_byte_array()
	var list: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _update_pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, (region.size.x + _GROUP_SIZE - 1) / _GROUP_SIZE, (region.size.y + _GROUP_SIZE - 1) / _GROUP_SIZE, 1)
	_rd.compute_list_end()


func _group_count() -> int:
	return (resolution + _GROUP_SIZE - 1) / _GROUP_SIZE


func _render_clear() -> void:
	if _compute_ready:
		_rd.texture_clear(_display, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
		if _map_display.is_valid():
			_rd.texture_clear(_map_display, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)


func _free_compute() -> void:
	if _rd == null:
		return
	# Uniform sets first: they reference the textures and the buffer.
	for rid: RID in [_update_set, _map_update_set, _scroll_set, _update_pipeline, _scroll_pipeline, _update_shader, _scroll_shader, _stamp_buffer, _display, _scratch, _map_display]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_update_set = RID()
	_map_update_set = RID()
	_map_display = RID()
	_scroll_set = RID()
	_update_pipeline = RID()
	_scroll_pipeline = RID()
	_update_shader = RID()
	_scroll_shader = RID()
	_stamp_buffer = RID()
	_display = RID()
	_scratch = RID()

#endregion

# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
class_name SnowTerrainHeightRaycast
extends SnowTerrainHeight
## Ground found by casting straight down against physics.
##
## Results are cached per texel-sized cell, because a walking character asks about very nearly the same
## two points every physics frame and a ray each time is pure waste.


## Layers the ground is on. The snow surface itself must not be on one of them.
@export_flags_3d_physics var collision_mask: int = 1
## Y the ray starts from. Above anything it should be able to find.
@export var ray_from_y: float = 100.0
## How far down it goes.
@export var ray_length: float = 200.0
## Height returned when the ray hits nothing at all.
@export var fallback_y: float = 0.0
## Side of a cache cell in metres. Smaller is more accurate and more rays.
@export_range(0.01, 1.0, 0.01) var cache_cell: float = 0.1

var _space: RID = RID()
var _cache: Dictionary[Vector2i, float] = {}
var _query: PhysicsRayQueryParameters3D = null


func setup(world: World3D) -> void:
	_space = world.space if world != null else RID()
	_query = PhysicsRayQueryParameters3D.new()
	_query.collision_mask = collision_mask
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_cache.clear()


func height_at(xz: Vector2) -> float:
	var cell: Vector2i = Vector2i(floori(xz.x / cache_cell), floori(xz.y / cache_cell))
	if _cache.has(cell):
		return _cache[cell]
	var y: float = fallback_y
	var state: PhysicsDirectSpaceState3D = PhysicsServer3D.space_get_direct_state(_space) if _space.is_valid() else null
	if state != null and _query != null:
		var centre: Vector2 = (Vector2(cell) + Vector2(0.5, 0.5)) * cache_cell
		_query.from = Vector3(centre.x, ray_from_y, centre.y)
		_query.to = Vector3(centre.x, ray_from_y - ray_length, centre.y)
		var hit: Dictionary = state.intersect_ray(_query)
		if not hit.is_empty():
			y = (hit["position"] as Vector3).y
	_cache[cell] = y
	return y


## Throw the cache away, after terrain has moved or been built.
func invalidate() -> void:
	_cache.clear()

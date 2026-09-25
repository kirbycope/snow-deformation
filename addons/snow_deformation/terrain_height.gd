# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
class_name SnowTerrainHeight
extends Resource
## Where the ground under the snow is, on the CPU.
##
## [SnowDeformation] needs this to work out how far a foot or a blade has sunk, because reading the
## deformation texture back from the GPU every frame is exactly what the design forbids. Subclass it
## for a real terrain; [SnowTerrainHeightFlat] and [SnowTerrainHeightRaycast] cover the usual cases.


## Called once by the manager, before the first [method height_at]. A provider that needs to query
## physics keeps the world it was given.
func setup(_world: World3D) -> void:
	pass


## Ground height in metres at world XZ [param xz].
func height_at(_xz: Vector2) -> float:
	return 0.0

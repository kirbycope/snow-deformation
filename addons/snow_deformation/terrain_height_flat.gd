# Copyright (c) 2026 Antigravity Contributors
# SPDX-License-Identifier: MIT
class_name SnowTerrainHeightFlat
extends SnowTerrainHeight
## Ground at one constant height. The default, and all a flat demo needs.


## The Y every point of ground sits at.
@export var terrain_y: float = 0.0


func height_at(_xz: Vector2) -> float:
	return terrain_y

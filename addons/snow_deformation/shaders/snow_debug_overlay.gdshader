// Copyright (c) 2026 Antigravity Contributors
// SPDX-License-Identifier: MIT
//
// Draws the deformation texture so a person can read it. The data has alpha 0 by design, which a
// plain TextureRect renders as nothing at all, and each channel is in metres rather than 0-1, so
// both need scaling before any of it is visible.
shader_type canvas_item;

// Depression, the R channel, shown as red.
uniform float snow_depth_m = 0.35;
// Berm, the G channel, shown as green. The B channel is the disturbed mask and is already 0-1.
uniform float rim_height_m = 0.12;

void fragment() {
	vec4 d = texture(TEXTURE, UV);
	COLOR = vec4(
		clamp(d.r / max(snow_depth_m, 1e-4), 0.0, 1.0),
		clamp(d.g / max(rim_height_m, 1e-4), 0.0, 1.0),
		clamp(d.b, 0.0, 1.0),
		1.0
	);
}

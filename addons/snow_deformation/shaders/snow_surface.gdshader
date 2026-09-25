// Copyright (c) 2026 Antigravity Contributors
// SPDX-License-Identifier: MIT
//
// Deformable snow. Displaces a dense grid by the deformation texture SnowDeformation maintains, then
// does the detail per pixel: footprint walls shade sharply because the normal is rebuilt from height
// differences in the fragment shader, not interpolated from vertices.
//
// world_vertex_coords puts VERTEX in world space, which is the space the deformation texture is
// indexed in, so no inverse model matrix is needed to write the displaced height back.
shader_type spatial;
render_mode world_vertex_coords, cull_back, diffuse_burley, specular_schlick_ggx;

// Published by SnowDeformation. Declared in project.godot under [shader_globals], so this shader still
// compiles in a project where no manager is present: the texture is simply empty and the snow is flat.
global uniform sampler2D snow_deform_tex;
global uniform vec2 snow_deform_origin;
global uniform float snow_deform_size;
global uniform float snow_deform_texel;
global uniform float snow_depth;

group_uniforms terrain;
// Ground height under the snow when no heightmap is supplied.
uniform float terrain_y = 0.0;
uniform bool use_heightmap = false;
uniform sampler2D heightmap : hint_default_black, filter_linear;
uniform vec2 heightmap_origin = vec2(0.0);
uniform float heightmap_size = 1024.0;
uniform float heightmap_scale = 100.0;

group_uniforms snow;
uniform vec3 fresh_albedo : source_color = vec3(0.93, 0.95, 0.98);
uniform vec3 packed_albedo : source_color = vec3(0.78, 0.84, 0.92);
uniform float fresh_roughness : hint_range(0.0, 1.0) = 0.65;
uniform float packed_roughness : hint_range(0.0, 1.0) = 0.40;
uniform float fresh_sss : hint_range(0.0, 1.0) = 0.40;
uniform float packed_sss : hint_range(0.0, 1.0) = 0.10;
// How much the depression alone counts as compressed, on top of the disturbed mask.
uniform float depth_mask_boost : hint_range(0.0, 2.0) = 0.6;
// Darkening at the bottom of a deep track.
uniform float trench_ao : hint_range(0.0, 1.0) = 0.75;

group_uniforms detail;
// Wind ripples on untouched powder. Generated rather than sampled, so the addon needs no texture asset.
uniform float ripple_scale : hint_range(0.1, 40.0) = 6.0;
uniform float ripple_strength : hint_range(0.0, 2.0) = 0.7;
// Lumpiness added to a berm, which is loose snow and should not read as a smooth ridge.
uniform float crumb_scale : hint_range(1.0, 200.0) = 40.0;
// Metres over which the fine detail above fades away, to stop it aliasing into moire at distance.
uniform float detail_near : hint_range(1.0, 40.0) = 6.0;
uniform float detail_far : hint_range(2.0, 80.0) = 22.0;
uniform float crumb_strength : hint_range(0.0, 4.0) = 1.6;

group_uniforms sparkle;
// Side of a glinting cell in metres. About 3 mm gives individual crystals at walking distance.
uniform float glint_cell : hint_range(0.0005, 0.02) = 0.003;
uniform float glint_density : hint_range(0.0, 0.3) = 0.03;
uniform float glint_roughness : hint_range(0.01, 0.5) = 0.05;
// Metres beyond which glints are gone: they alias badly at distance and cost nothing to drop.
uniform float glint_distance : hint_range(1.0, 60.0) = 15.0;

group_uniforms edges;
// Fraction of the deformation texture faded to nothing at its border, so the window's edge is invisible.
uniform float border_fade : hint_range(0.01, 0.5) = 0.1;

varying vec3 world_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float hash31(vec3 p) {
	// Wrapped, so a cell index of tens of thousands cannot exhaust float32's mantissa. The pattern
	// repeats every 2048 cells, which at a 3 mm cell is about 6 m and is not something an eye picks
	// out of random sparkle.
	p = mod(p, 2048.0);
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Gradient of the value noise at world point p. The taps are a quarter of a cycle either side, so
// this is an actual slope rather than the difference of two uncorrelated samples.
vec2 noise_gradient(vec2 p, float scale) {
	float e = 0.25 / max(scale, 1e-4);
	float dx = value_noise((p + vec2(e, 0.0)) * scale) - value_noise((p - vec2(e, 0.0)) * scale);
	float dz = value_noise((p + vec2(0.0, e)) * scale) - value_noise((p - vec2(0.0, e)) * scale);
	return vec2(dx, dz);
}

float terrain_height(vec2 world_xz) {
	if (use_heightmap) {
		vec2 uv = (world_xz - heightmap_origin) / max(heightmap_size, 1e-4);
		return terrain_y + texture(heightmap, uv).r * heightmap_scale;
	}
	return terrain_y;
}

// R = depression, G = berm, B = disturbed mask, faded to nothing towards the window's border and zero
// outside it, so the snow beyond the deformable area matches ordinary undeformed snow exactly.
vec4 sample_deform(vec2 world_xz) {
	vec2 uv = (world_xz - snow_deform_origin) / max(snow_deform_size, 1e-4);
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return vec4(0.0);
	}
	vec4 d = textureLod(snow_deform_tex, uv, 0.0);
	vec2 to_edge = min(uv, vec2(1.0) - uv);
	float fade = clamp(min(to_edge.x, to_edge.y) / max(border_fade, 1e-4), 0.0, 1.0);
	return d * fade;
}

float surface_height(vec2 world_xz) {
	vec4 d = sample_deform(world_xz);
	return terrain_height(world_xz) + snow_depth - d.r + d.g;
}

void vertex() {
	world_pos = VERTEX;
	VERTEX.y = surface_height(VERTEX.xz);
	world_pos.y = VERTEX.y;

	// A coarse normal per vertex as well: lighting and the shadow pass both want something sane at
	// distance, and the fragment shader refines it where it matters.
	float e = snow_deform_texel * 2.0;
	float hl = surface_height(VERTEX.xz - vec2(e, 0.0));
	float hr = surface_height(VERTEX.xz + vec2(e, 0.0));
	float hd = surface_height(VERTEX.xz - vec2(0.0, e));
	float hu = surface_height(VERTEX.xz + vec2(0.0, e));
	NORMAL = normalize(vec3(hl - hr, 2.0 * e, hd - hu));
}

void fragment() {
	vec2 xz = world_pos.xz;
	vec4 d = sample_deform(xz);

	// The whole point of the exercise: rebuild the normal from the height field at a texel's spacing,
	// so a footprint wall is a crisp shading edge rather than a facet of the grid.
	float e = snow_deform_texel;
	float hl = surface_height(xz - vec2(e, 0.0));
	float hr = surface_height(xz + vec2(e, 0.0));
	float hd = surface_height(xz - vec2(0.0, e));
	float hu = surface_height(xz + vec2(0.0, e));
	vec3 n = normalize(vec3(hl - hr, 2.0 * e, hd - hu));

	// How compressed this snow is: the disturbed mask, reinforced by how deep the depression is.
	float m = clamp(d.b + (d.r / max(snow_depth, 1e-4)) * depth_mask_boost, 0.0, 1.0);

	// Fine detail is only meaningful within a few metres. Past that a screen pixel covers many cycles
	// of it and the result is aliasing, so it is faded out rather than left to shimmer.
	float camera_distance = length(world_pos - CAMERA_POSITION_WORLD);
	float detail_fade = 1.0 - smoothstep(detail_near, detail_far, camera_distance);

	// Wind ripples on fresh powder, flattening out where the snow has been walked on. Two octaves,
	// because one alone reads as an even mottle rather than as drifted snow.
	vec2 ripple = noise_gradient(xz, ripple_scale)
		+ noise_gradient(xz + vec2(31.7, 11.3), ripple_scale * 3.1) * 0.45;
	n += vec3(-ripple.x, 0.0, -ripple.y) * ripple_strength * (1.0 - m) * detail_fade;

	// A berm is loose snow shoved aside, so it gets high-frequency lumps the flat snow does not.
	float berm = clamp(d.g / max(snow_depth * 0.35, 1e-4), 0.0, 1.0);
	if (berm > 0.001) {
		vec2 crumb = noise_gradient(xz, crumb_scale);
		n += vec3(-crumb.x, 0.0, -crumb.y) * crumb_strength * berm * detail_fade;
	}
	n = normalize(n);

	ALBEDO = mix(fresh_albedo, packed_albedo, m);
	float rough = mix(fresh_roughness, packed_roughness, m);
	SSS_STRENGTH = mix(fresh_sss, packed_sss, m);

	// Individual crystals catching the sun. A hashed fraction of small world-space cells gets a tilted
	// micro-normal and near-mirror roughness, and the engine's own specular does the rest.
	float glint_fade = (1.0 - clamp(camera_distance / max(glint_distance, 1e-4), 0.0, 1.0)) * (1.0 - m * 0.85);
	if (glint_fade > 0.001) {
		vec3 cell = floor(world_pos / max(glint_cell, 1e-5));
		float pick = hash31(cell);
		if (pick < glint_density) {
			vec3 tilt = normalize(vec3(
				hash31(cell + vec3(1.7)) - 0.5,
				0.35,
				hash31(cell + vec3(3.1)) - 0.5
			));
			n = normalize(mix(n, tilt, glint_fade));
			rough = mix(rough, glint_roughness, glint_fade);
		}
	}

	ROUGHNESS = rough;
	// A deep track is a hole, and the bottom of a hole sees less of the sky.
	AO = mix(1.0, trench_ao, clamp(d.r / max(snow_depth, 1e-4), 0.0, 1.0));
	AO_LIGHT_AFFECT = 0.5;
	// Godot wants the fragment normal in view space.
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}

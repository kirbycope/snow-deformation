// Copyright (c) 2026 Antigravity Contributors
// SPDX-License-Identifier: MIT
shader_type canvas_item;
render_mode unshaded, blend_disabled;

// The Compatibility renderer's stand-in for snow_scroll.glsl and snow_update.glsl, which need compute and so a
// RenderingDevice. SnowDeformation draws this over the whole of one of two SubViewports, reading the other, which
// holds the snow as it was: every texel takes the value that sat `shift` texels along (the scroll), decays it (the
// refill) and carves this frame's stamps into it, the same maths as the compute passes. The stamps come in as a
// float texture, four texels a stamp in the order `struct Stamp` declares its vec4s.
//
// R = depression in metres, G = berm height in metres, B = disturbed mask 0-1, A = reserved.

uniform sampler2D previous : filter_nearest, repeat_disable;
uniform sampler2D stamps : filter_nearest, repeat_disable;
uniform int stamp_count = 0;
uniform float resolution = 1024.0; // Texels a side.
uniform ivec2 shift = ivec2(0);    // How far the window's min corner moved, in texels; a whole window or more clears.
uniform vec2 deform_origin;        // World XZ of the texture's min corner.
uniform float texel_size = 0.046875;
uniform float delta_time = 0.0;
uniform float snow_depth = 0.35;
uniform float refill_rate_geo = 0.0;
uniform float refill_rate_mask = 0.0;
uniform float max_rim_height = 0.12;
uniform float noise_scale = 12.0;
uniform float noise_strength = 0.08;
uniform float min_radius = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
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

vec2 segment_distance(vec2 p, vec2 a, vec2 b) {
	vec2 ab = b - a;
	float denom = dot(ab, ab);
	float t = denom > 1e-12 ? clamp(dot(p - a, ab) / denom, 0.0, 1.0) : 0.0;
	return vec2(length(p - (a + ab * t)), t);
}

void fragment() {
	// Texel coordinates by UV rather than FRAGCOORD, and sampled by UV rather than texelFetch, so the texture reads
	// the same way up however the renderer stores its render targets.
	ivec2 size = ivec2(int(resolution));
	ivec2 p = clamp(ivec2(floor(UV * resolution)), ivec2(0), size - 1);
	ivec2 from = p + shift;
	vec4 v = vec4(0.0);
	if (from.x >= 0 && from.y >= 0 && from.x < size.x && from.y < size.y) {
		v = texture(previous, (vec2(from) + 0.5) / resolution);
	}

	vec2 world = deform_origin + (vec2(p) + 0.5) * texel_size;
	v.r = max(v.r - refill_rate_geo * delta_time, 0.0);
	v.g = max(v.g - refill_rate_geo * delta_time, 0.0);
	v.b = max(v.b - refill_rate_mask * delta_time, 0.0);

	for (int i = 0; i < stamp_count; i++) {
		vec4 a = texelFetch(stamps, ivec2(0, i), 0);
		vec4 b = texelFetch(stamps, ivec2(1, i), 0);
		vec4 params0 = texelFetch(stamps, ivec2(2, i), 0);
		vec4 params1 = texelFetch(stamps, ivec2(3, i), 0);
		float d;
		float depth;

		if (a.w < 0.5) {
			vec2 local = world - a.xz;
			float c = cos(-params0.z);
			float sn = sin(-params0.z);
			local = vec2(local.x * c - local.y * sn, local.x * sn + local.y * c);
			vec2 half_axes = max(params0.xy, vec2(max(min_radius, 1e-4)));
			d = length(local / half_axes);
			float along = clamp(local.y / half_axes.y * 0.5 + 0.5, 0.0, 1.0);
			depth = mix(params1.x, params1.y, along);
		} else {
			vec2 hit = segment_distance(world, a.xz, b.xz);
			float radius = max(params0.x, max(min_radius, 1e-4));
			d = hit.x / radius;
			depth = mix(params1.x, params1.y, hit.y);
		}

		if (depth <= 0.0) {
			continue;
		}
		float rim_width = max(params1.w, 1e-4);
		if (d > 1.0 + rim_width + noise_strength) {
			continue;
		}

		d += (value_noise(world * noise_scale) - 0.5) * 2.0 * noise_strength;

		float wall_softness = clamp(params1.z, 1e-3, 1.0);
		float core = 1.0 - smoothstep(1.0 - wall_softness, 1.0, d);
		float depress = depth * core;

		float rt = clamp((d - 1.0) / rim_width, 0.0, 1.0);
		float rim = (d > 1.0 && d < 1.0 + rim_width) ? 4.0 * rt * (1.0 - rt) : 0.0;
		float rim_h = depth * params0.w * rim;
		float core_mask = 1.0 - smoothstep(0.8, 1.0, d);

		v.r = max(v.r, depress);
		v.g = max(v.g * (1.0 - core_mask), rim_h);
		v.b = max(v.b, 1.0 - smoothstep(1.0, 1.0 + rim_width, d));
	}

	v.r = clamp(v.r, 0.0, snow_depth);
	v.g = clamp(v.g, 0.0, max_rim_height);
	v.b = clamp(v.b, 0.0, 1.0);
	// Alpha 1, not the compute pass's 0: nothing samples it, and a render target's alpha is the one channel a
	// driver may treat specially.
	COLOR = vec4(v.rgb, 1.0);
}

#[compute]
#version 450

// Decays the deformation texture and applies this frame's stamps to it, in place. Every invocation
// reads and writes only its own texel, so there is no race and no barrier is needed.
//
// R = depression in metres, G = berm height in metres, B = disturbed mask 0-1, A = reserved.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D deform_image;

// Mirrors SnowDeformation.STAMP_FLOATS exactly. Four vec4s, so the std430 stride is 64 bytes with no
// padding of its own and the CPU can pack straight into a PackedFloat32Array.
struct Stamp {
	vec4 a;       // xyz = world point A, w = shape (0 = ellipse, 1 = capsule)
	vec4 b;       // xyz = world point B, w = unused
	vec4 params0; // x = radius / half width, y = half length, z = yaw, w = rim_factor
	vec4 params1; // x = depth at A, y = depth at B, z = wall_softness, w = rim_width
};

layout(std430, set = 0, binding = 1) restrict readonly buffer Stamps {
	Stamp data[];
} stamps;

layout(push_constant, std430) uniform Params {
	vec2 deform_origin;     // World XZ of the texture's min corner.
	float texel_size;       // World metres per texel.
	float delta_time;
	float snow_depth;
	float refill_rate_geo;  // Metres per second the geometry recovers.
	float refill_rate_mask; // Units per second the disturbed mask fades.
	float max_rim_height;
	float noise_scale;      // Cycles per metre of the edge-perturbing noise.
	float noise_strength;   // How far that noise pushes the normalised distance.
	float stamp_count;
	float reserved0;        // Keeps the block at 64 bytes; the border fade lives in the surface shader.
	vec4 reserved1;
} params;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Smooth value noise, sampled in world space so a print's crumbly edge stays put as the window scrolls.
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

// Shortest distance from `p` to segment `a`-`b`, and how far along the segment the closest point sits.
vec2 segment_distance(vec2 p, vec2 a, vec2 b) {
	vec2 ab = b - a;
	float denom = dot(ab, ab);
	float t = denom > 1e-12 ? clamp(dot(p - a, ab) / denom, 0.0, 1.0) : 0.0;
	return vec2(length(p - (a + ab * t)), t);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(deform_image);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}

	// Texel centre in world XZ.
	vec2 world = params.deform_origin + (vec2(p) + 0.5) * params.texel_size;
	vec4 v = imageLoad(deform_image, p);

	// Refill. Both rates default to zero, in which case this is a no-op and the caller has already
	// skipped the dispatch unless there are stamps to apply.
	v.r = max(v.r - params.refill_rate_geo * params.delta_time, 0.0);
	v.g = max(v.g - params.refill_rate_geo * params.delta_time, 0.0);
	v.b = max(v.b - params.refill_rate_mask * params.delta_time, 0.0);

	int count = int(params.stamp_count);
	for (int i = 0; i < count; i++) {
		Stamp s = stamps.data[i];
		float d;
		float depth;

		if (s.a.w < 0.5) {
			// Ellipse: a footprint. Into the stamp's local frame, then scaled by its two half axes so
			// the edge of the print is d == 1 whatever its proportions.
			vec2 local = world - s.a.xz;
			float c = cos(-s.params0.z);
			float sn = sin(-s.params0.z);
			local = vec2(local.x * c - local.y * sn, local.x * sn + local.y * c);
			vec2 half_axes = max(s.params0.xy, vec2(1e-4));
			d = length(local / half_axes);
			// Heel-heavy: params1.x is the depth at the heel, params1.y at the toe. Local +Y is forward.
			float along = clamp(local.y / half_axes.y * 0.5 + 0.5, 0.0, 1.0);
			depth = mix(s.params1.x, s.params1.y, along);
		} else {
			// Capsule: a blade gouge, a drag mark or a body. Depth runs along the segment.
			vec2 hit = segment_distance(world, s.a.xz, s.b.xz);
			float radius = max(s.params0.x, 1e-4);
			d = hit.x / radius;
			depth = mix(s.params1.x, s.params1.y, hit.y);
		}

		if (depth <= 0.0) {
			continue;
		}

		float rim_width = max(s.params1.w, 1e-4);
		if (d > 1.0 + rim_width + params.noise_strength) {
			continue; // Outside the print and its berm, so nothing to add.
		}

		// Push the boundary about with world-space noise so walls and rims read as crumbled snow
		// rather than as a mathematical ellipse.
		d += (value_noise(world * params.noise_scale) - 0.5) * 2.0 * params.noise_strength;

		float wall_softness = clamp(s.params1.z, 1e-3, 1.0);
		float core = 1.0 - smoothstep(1.0 - wall_softness, 1.0, d);
		float depress = depth * core;

		float rt = clamp((d - 1.0) / rim_width, 0.0, 1.0);
		float rim = (d > 1.0 && d < 1.0 + rim_width) ? 4.0 * rt * (1.0 - rt) : 0.0;
		float rim_h = depth * s.params0.w * rim;
		float core_mask = 1.0 - smoothstep(0.8, 1.0, d);

		// max() rather than +=, so standing in one place does not drill a hole.
		v.r = max(v.r, depress);
		// A fresh print flattens whatever berm used to sit inside it before raising its own.
		v.g = max(v.g * (1.0 - core_mask), rim_h);
		v.b = max(v.b, 1.0 - smoothstep(1.0, 1.0 + rim_width, d));
	}

	// The border fade is deliberately NOT applied here. This pass runs every frame, so scaling the
	// stored value by a fixed factor would compound into an exponential decay of the outer band. The
	// surface shader fades what it samples instead, which costs nothing and leaves the data intact.
	v.r = clamp(v.r, 0.0, params.snow_depth);
	v.g = clamp(v.g, 0.0, params.max_rim_height);
	v.b = clamp(v.b, 0.0, 1.0);
	v.a = 0.0;
	imageStore(deform_image, p, v);
}

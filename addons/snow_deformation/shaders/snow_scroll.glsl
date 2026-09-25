#[compute]
#version 450

// Scrolls the deformation texture by a whole number of texels, so the window can follow the player
// without the tracks inside it appearing to move. Reads the display texture and writes the scratch
// one, because an in-place shift would race: neighbouring invocations would read texels another
// invocation had already overwritten. The caller copies scratch back over display afterwards.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst_image;

layout(push_constant, std430) uniform Params {
	ivec2 shift; // How far the window's min corner moved, in texels.
	ivec2 reserved;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst_image);
	if (p.x >= size.x || p.y >= size.y) {
		return;
	}
	// A texel keeps the world position it had, so it takes the value that used to sit `shift` texels
	// further along. Anything that comes from outside the old window is snow nobody has touched yet.
	ivec2 from = p + params.shift;
	vec4 value = vec4(0.0);
	if (from.x >= 0 && from.y >= 0 && from.x < size.x && from.y < size.y) {
		value = imageLoad(src_image, from);
	}
	imageStore(dst_image, p, value);
}

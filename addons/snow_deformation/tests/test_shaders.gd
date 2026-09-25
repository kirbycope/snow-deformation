extends GutTest
## The three shaders and the project settings they depend on.
##
## Nothing else compiles the compute shaders: a GLSL error makes the import produce a SPIR-V with an
## error string and an empty bytecode, which is silent until the moment something tries to run it.

const SCROLL: String = "res://addons/snow_deformation/shaders/snow_scroll.glsl"
const UPDATE: String = "res://addons/snow_deformation/shaders/snow_update.glsl"
const SURFACE: String = "res://addons/snow_deformation/shaders/snow_surface.gdshader"
const OVERLAY: String = "res://addons/snow_deformation/shaders/snow_debug_overlay.gdshader"

## Every global the surface shader reads. A project missing one of these fails to compile the shader,
## which is why they live in project.godot rather than being registered at run time by the manager.
const GLOBALS: Array[StringName] = [
	&"snow_deform_tex", &"snow_deform_origin", &"snow_deform_size", &"snow_deform_texel", &"snow_depth",
]


func _compiles(path: String) -> void:
	var file: RDShaderFile = load(path) as RDShaderFile
	assert_not_null(file, "%s imports as an RDShaderFile" % path.get_file())
	if file == null:
		return
	var spirv: RDShaderSPIRV = file.get_spirv()
	var error: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	assert_eq(error, "", "%s compiles with no error" % path.get_file())
	assert_gt(spirv.get_stage_bytecode(RenderingDevice.SHADER_STAGE_COMPUTE).size(), 0, "and produces bytecode")


func test_the_scroll_pass_compiles() -> void:
	_compiles(SCROLL)


func test_the_update_pass_compiles() -> void:
	_compiles(UPDATE)


func test_the_surface_shader_loads() -> void:
	var shader: Shader = load(SURFACE) as Shader
	assert_not_null(shader, "The snow surface shader loads")
	assert_eq(shader.get_mode(), Shader.MODE_SPATIAL, "and is a spatial shader")


func test_the_debug_overlay_shader_loads() -> void:
	var shader: Shader = load(OVERLAY) as Shader
	assert_not_null(shader, "The overlay shader loads")
	assert_eq(shader.get_mode(), Shader.MODE_CANVAS_ITEM, "and draws on a canvas item")


func test_every_global_the_surface_shader_reads_is_declared_in_the_project() -> void:
	var declared: Array = RenderingServer.global_shader_parameter_get_list()
	for name: StringName in GLOBALS:
		assert_true(declared.has(name), "%s is declared, so the snow shader compiles even with no manager in the level" % name)


func test_the_surface_shader_reads_exactly_the_globals_that_are_declared() -> void:
	var source: String = FileAccess.get_file_as_string(SURFACE)
	assert_false(source.is_empty(), "The shader source is readable")
	for line: String in source.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with("global uniform "):
			continue
		# "global uniform <type> <name>;" - the name is the last token before the semicolon.
		var name: String = trimmed.trim_suffix(";").split(" ")[-1]
		assert_true(GLOBALS.has(StringName(name)), "The shader reads global '%s', which this test and project.godot both know about" % name)


func test_the_stamp_struct_in_the_shader_matches_what_the_manager_packs() -> void:
	var source: String = FileAccess.get_file_as_string(UPDATE)
	var fields: int = 0
	var inside: bool = false
	for line: String in source.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("struct Stamp"):
			inside = true
			continue
		if inside:
			if trimmed.begins_with("};"):
				break
			if trimmed.begins_with("vec4 "):
				fields += 1
	assert_eq(fields, 4, "Stamp is four vec4s in the shader")
	assert_eq(fields * 4, SnowDeformation.STAMP_FLOATS, "which is exactly the float count the manager packs per stamp")

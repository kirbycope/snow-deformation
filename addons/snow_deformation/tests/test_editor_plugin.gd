extends GutTest
## Purpose: the editor plugin is the one script nothing else here reaches, so it needs a guard of its own.

const PLUGIN_PATH: String = "res://addons/snow_deformation/plugin.gd"


## No test instantiates an [EditorPlugin] and the demo project does not enable this one, so a plugin that has
## stopped compiling is invisible to every other check: the addon simply fails to enable in a project that
## installs it, which is the last place anyone wants to find out. Loading a GDScript compiles it, and a
## preload of a file that is not there is a compile error, so a plugin in that state comes back null.
func test_the_editor_plugin_still_compiles() -> void:
	assert_not_null(load(PLUGIN_PATH), "plugin.gd compiles, so everything it preloads is there")


## Says which path is missing when one is, rather than leaving a bare null to work backwards from. A preload
## written relative to the file is the dangerous kind, because a search for "res://" never lands on it.
func test_every_path_the_plugin_preloads_resolves() -> void:
	var source: String = FileAccess.get_file_as_string(PLUGIN_PATH)
	assert_false(source.is_empty(), "plugin.gd is readable")
	var folder: String = PLUGIN_PATH.get_base_dir() + "/"
	var checked: int = 0
	for line: String in source.split("\n"):
		var opens: int = line.find("preload(\"")
		if opens < 0:
			continue
		var from: int = opens + 9
		var path: String = line.substr(from, line.find("\"", from) - from)
		var absolute: String = path if path.begins_with("res://") else folder.path_join(path)
		checked += 1
		assert_true(ResourceLoader.exists(absolute), "plugin.gd preloads %s, which resolves to %s and is not there" % [path, absolute])
	assert_gt(checked, 0, "and there were preloads to check, so the scan is not passing on an empty list")


## The custom types the plugin puts in the Create New Node dialog have to be types this addon actually has,
## and every one added on the way in has to come off again on the way out, or a project that disables the
## plugin keeps a dialog entry pointing at nothing.
func test_the_custom_types_it_registers_are_the_ones_it_removes() -> void:
	var source: String = FileAccess.get_file_as_string(PLUGIN_PATH)
	var added: Array[String] = _names_passed_to(source, "add_custom_type(")
	var removed: Array[String] = _names_passed_to(source, "remove_custom_type(")
	assert_gt(added.size(), 0, "The plugin registers at least one type")
	added.sort()
	removed.sort()
	assert_eq(added, removed, "Every type added in _enter_tree is removed in _exit_tree")


## The quoted name in each call to [param call_name], in the order they appear.
func _names_passed_to(source: String, call_name: String) -> Array[String]:
	var names: Array[String] = []
	var at: int = source.find(call_name)
	while at >= 0:
		var opens: int = source.find("\"", at)
		if opens >= 0:
			var closes: int = source.find("\"", opens + 1)
			if closes > opens:
				names.append(source.substr(opens + 1, closes - opens - 1))
		at = source.find(call_name, at + call_name.length())
	return names

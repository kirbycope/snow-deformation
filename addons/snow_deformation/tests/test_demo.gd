extends GutTest
## The demo scene ships inside the addon, so installing the addon brings it. These check it loads and
## is wired to nothing outside the addons it declares.

const DEMO_PATH: String = "res://addons/snow_deformation/scenes/demo/demo.tscn"
## The only addons the demo may reach into. A path anywhere else is a file the installing project
## does not have.
const ALLOWED_PREFIXES: Array[String] = [
	"res://addons/snow_deformation/",
	"res://addons/3d_player_controller/",
	"res://addons/weather_fx/",
]


func test_the_demo_is_the_main_scene() -> void:
	assert_eq(ProjectSettings.get_setting("application/run/main_scene") as String, DEMO_PATH)


func test_the_demo_only_references_its_addons() -> void:
	var source: String = FileAccess.get_file_as_string(DEMO_PATH)
	var regex: RegEx = RegEx.create_from_string("path=\"(res://[^\"]+)\"")
	for found: RegExMatch in regex.search_all(source):
		var path: String = found.get_string(1)
		var allowed: bool = ALLOWED_PREFIXES.any(func(prefix: String) -> bool: return path.begins_with(prefix))
		assert_true(allowed, "%s is outside the addons the demo depends on" % path)


func test_the_demo_is_wired() -> void:
	var packed: PackedScene = load(DEMO_PATH) as PackedScene
	assert_not_null(packed, "the demo loads")
	var demo: Node3D = packed.instantiate() as Node3D
	add_child_autofree(demo)
	assert_not_null(demo.get("snow"), "snow is assigned")
	assert_not_null(demo.get("player"), "player is assigned")
	assert_not_null(demo.get("sword"), "sword is assigned")
	assert_not_null(demo.get("readout"), "readout is assigned")
	assert_not_null(demo.get("weather"), "weather is assigned")
	assert_not_null(demo.get_node_or_null("Player/FootStamper"), "the Player leaves footprints")
	assert_not_null(demo.get_node_or_null("Player/Sword/BladeStamper"), "the sword gouges")
	assert_eq(demo.get_node("PhysicsProps").get_child_count(), 3, "three balls to shove")
	assert_not_null(demo.get_node("Player/FootStamper").get("footstep_sound"), "footsteps are heard")
	assert_not_null(demo.get_node("SnowDeformation").get("press_sound"), "ploughed snow is heard")

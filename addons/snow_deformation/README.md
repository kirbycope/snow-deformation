# Snow Deformation

Real-time deformable snow for Godot 4.8+ on the Forward+ renderer. Deep footprints with steep walls
and a crumbly raised rim, continuous gouges from a blade moving metres between frames, and snow that
is visibly a different material inside a track than it is outside one.

## Installing

Copy `addons/snow_deformation/` into your project and enable **Snow Deformation** in
Project Settings, Plugins.

Then add these five entries under Project Settings, Shader Globals. The surface shader reads them, so
a project without them fails to compile it. They are in this project's `project.godot` already:

| Name | Type | Default |
| --- | --- | --- |
| `snow_deform_tex` | sampler2D | (empty) |
| `snow_deform_origin` | vec2 | `Vector2(0, 0)` |
| `snow_deform_size` | float | `48.0` |
| `snow_deform_texel` | float | `0.046875` |
| `snow_depth` | float | `0.35` |

Drop one **SnowDeformation** node into the level. That is the whole setup: it builds and follows its
own snow surface mesh, finds the player by itself, and publishes the deformation to every material
through those globals. Everything on it is an exported property, so there is nothing to wire.

## Leaving tracks

Two components hand the manager shapes to carve. Both find the manager themselves, so neither needs a
`NodePath` to it.

**FootStamper** goes under a character. Point it at a `Skeleton3D` and name the foot bones, and it
presses an elliptical print wherever a foot is below the snow's surface:

```gdscript
# In the scene, not in code: a FootStamper child of the Player with
#   skeleton_path = ../PlayerModel/Armature/GeneralSkeleton
#   foot_bones    = ["LeftFoot", "RightFoot"]
```

It stamps every physics frame a foot is in contact, which is deliberate. Prints combine with `max()`,
so a planted foot re-stamping its own hole changes nothing, while a foot that slides lays down a drag
mark for free. A character that runs fast enough for its feet to slide ploughs a trench, which is what
a real one does in deep snow.

For feet to sink at all the character's collision has to rest on the ground **underneath** the snow.
The snow surface mesh carries no collider, so that is what happens by default.

A four-legged character is the same node with four bones, for example
`["Hand_L", "Hand_R", "Toe_L", "Toe_R"]` on a horse.

**BladeStamper** goes on a weapon, with a marker at the base of the cutting edge and one at the tip. A
swing covers metres in a couple of frames, so it walks the sweep in substeps fine enough that
consecutive capsules overlap, and clips each one to the part of the blade that is actually under the
snow.

Anything else can call the manager directly:

```gdscript
var snow: SnowDeformation = SnowDeformation.find(self)
snow.add_footprint(position, yaw, 0.06, 0.14, depth)
snow.add_capsule(from, to, radius, depth_from, depth_to)
snow.add_sphere(centre, radius, depth)
snow.clear()
```

## Physics objects

Anything that moves and has a collider presses the snow, the same way a `GrassField` is pressed: the
manager keeps an `Area3D` over its window, notices bodies entering and leaving, and measures each
one's radius and underside from its own collision shapes once on the way in. A ball rolling through
deep snow ploughs a rounded trough with berms down both sides; a body sitting still holds its dent and
nothing more.

Only things that move count, the same list the grass uses: `CharacterBody3D`, `RigidBody3D`,
`AnimatableBody3D` and `PhysicalBone3D`. The ground, walls and rocks cleared their own snow when the
level was built and do not also push it about.

A body carrying its own `FootStamper` or `BladeStamper` is skipped. Feet and a blade edge describe far
more than a sphere around the body's origin would, and pressing both would bury the prints under a
circle. `press_bodies` turns the whole thing off, `max_pressed_bodies` caps how many are pressed in one
frame, and when more are in the snow than that the widest and nearest win, again as in the grass.

## Sound

The slots stay silent until something is put in them. The addon ships two ready to use,
`resources/snow_footsteps.tres` and `resources/snow_crush.tres`, built from Gravity Sound's Snow Sound
Effects (see `CREDITS.md`). Give `FootStamper.footstep_sound` and `SnowDeformation.press_sound` an `AudioStreamRandomizer` holding
several takes and it builds the `AudioStreamPlayer3D` voices itself.

A footstep fires on the frame a foot **arrives** in the snow, not every frame it stays there: a planted
foot re-stamps its own hole constantly, and a crunch each time would be a drone rather than a
footstep. Measured on a running character, that is about one crunch every 1.6 m, which is its stride.
`footstep_min_depth` keeps a foot brushing the surface silent while still letting it leave a print.
Each foot gets its own voice, so two landing together are heard as two steps.

A crush fires once per `press_sound_interval` **of travel**, not of time, so a body rolling fast
crunches often, one creeping crunches rarely, and one that has stopped makes nothing at all. The
voices are a small round-robin pool rather than one per body.

Both play on an `SFX` bus when the project has one, and on `Master` when it does not.

## Ground under the snow

The CPU needs to know where the ground is, to work out how far something has sunk, because reading
the deformation texture back from the GPU every frame is exactly what this design avoids.
`terrain_height_provider` takes a **SnowTerrainHeightFlat** (a constant Y, which is all a flat level
needs) or a **SnowTerrainHeightRaycast** (a downward ray against a collision mask, cached per cell).
Subclass `SnowTerrainHeight` for anything else.

The surface shader needs the same heights on the GPU. It takes an optional heightmap
(`use_heightmap`, `heightmap`, `heightmap_origin`, `heightmap_size`, `heightmap_scale`) and otherwise
uses the constant `terrain_y`.

## How it works

```
 stampers ──► SnowDeformation ──► scroll pass ──► update pass ──► RGBA16F texture
   (CPU)          (CPU queue)      (compute)       (compute)            │
                                                                        ▼
                                                        global shader parameters
                                                                        │
                                                                        ▼
                                                   snow_surface.gdshader on a dense grid
```

A single `RGBA16F` texture holds the snow around the focus: **R** is the depression in metres, **G**
the berm height in metres, **B** a disturbed mask from 0 to 1. It is centred on the focus and snapped
to whole texels, and when the focus moves a texel the scroll pass shifts the contents to match, so
tracks stay exactly where they were laid however far the player walks.

The update pass then decays the texture and carves this frame's stamps into it, in place: every
invocation reads and writes only its own texel, so there is no race and no barrier.

Detail comes from the fragment shader, not from geometry. The grid is 12.5 cm between vertices, far
coarser than a footprint, so the surface normal is rebuilt from height differences one texel apart per
pixel. That is what makes a print wall a crisp shading edge rather than a facet of the grid.

## Tuning

The two numbers that matter most:

- **`world_size` over `resolution` is the texel size**, and a footprint is about 12 cm across. The
  defaults, 48 m over 1024, give 4.7 cm texels, which is two and a half texels per print: enough for a
  trench, not enough for a crisp print. The demo runs 2048 over 48 m, which is 2.3 cm, and that is
  where prints start to look right. 2048² costs 64 MB of VRAM for the pair of textures.
- **`snow_depth`** is how deep the snow is, and a stamp can never dig past it however many times it is
  walked over.

`refill_rate_geo` and `refill_rate_mask` fill tracks back in, in metres and units per second; both
default to 0, which keeps tracks indefinitely. In the demo they are driven by how hard Weather FX says
it is snowing.

## What it does not do

Tracks outside the coverage window are gone: nothing is saved and restored as tiles. There are no snow
puffs on footfall, no accumulation on objects, and no clipmap rings for a larger deformable area.

## Notes worth knowing

**No RenderingDevice, no deformation.** Under the Compatibility renderer, and in a headless run, there
is none. The node warns once, disables its compute passes, and the snow renders flat and undeformed.
That path is what every headless test exercises, so it stays working.

**Refill is saved up rather than applied every frame.** An `RGBA16F` half float resolves about
0.00024 near 0.35. At 120 fps a refill of 0.02 m/s wants to subtract 0.00017 per frame, which is finer
than that, so the store rounds it up to a whole step and tracks fade about one and a half times faster
than asked, at a rate that changes again whenever a value crosses a float exponent. The manager
therefore accumulates the decay and applies it in steps large enough to land on a representable value.
Measured over five seconds, that took the error from 47% to 4.5%.

**The texture is published from the main thread.** `RenderingServer.global_shader_parameter_set` called
from inside `call_on_render_thread` does not reach any material, and there is no error to say so: the
snow simply stays flat.

## The demo

`scenes/demo/demo.tscn` ships with the addon and is this repository's main scene: an arctic tundra in
a blizzard, 35 cm of snow over flat ground, the player controller's Player with a sword, and three
balls to shove. It needs `addons/3d_player_controller`, `addons/controls` and `addons/weather_fx`,
which `python tools/pull_addons.py` fetches here.

Walk and the feet cut prints with steep walls and raised rims; run and they merge into a ploughed
trench. Left click swings the sword through the snow and leaves one continuous gouge. Shove a ball and
it ploughs a trough with berms down both sides.

- **F1** shows the deformation texture: red is the depression, green the berm, blue the disturbed mask.
- **F2** wipes every track.
- **F3** lets the falling snow fill tracks back in, at a rate following Weather FX's precipitation.

Footsteps and the crush of shoved snow use the addon's own `snow_footsteps.tres` and `snow_crush.tres`.

## Tests

`tests/` holds the unit tests: stamp packing against the shader's struct, the window's snapping and
scrolling, the height providers, both stampers' decisions, that the demo loads and reaches only the addons it depends on, and that every shader compiles and every
global it reads is declared. They run headless, where the compute half is off by design.

## Licence

MIT. See `LICENSE`. Third-party attributions are in `CREDITS.md`.

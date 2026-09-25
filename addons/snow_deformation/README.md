# Snow Deformation

Real-time deformable snow for Godot 4.8+ on the Forward+ renderer. Deep footprints with steep walls
and a crumbly raised rim, troughs ploughed by anything rolling through it, and snow that
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

Anything else can call the manager directly:

```gdscript
var snow: SnowDeformation = SnowDeformation.find(self)
snow.add_footprint(position, yaw, 0.06, 0.14, depth)
snow.add_capsule(from, to, radius, depth_from, depth_to)
snow.add_sphere(centre, radius, depth)
snow.clear()
```

## Legs in deep snow

In snow deeper than a footprint the legs plough too. `FootStamper.leg_bones` names bone pairs, thigh and
shin on both sides by default, and each is pressed as a capsule `leg_radius` thick wherever it is under the
surface, so a character wading through snow up to the hips cuts a trench rather than a line of post holes.
A pair naming a bone the rig lacks is skipped, so a horse keeps its hoof prints. The legs' cuts are laid with
`leg_wall_softness` 0.65, so their walls slope as deep snow slumps back behind a leg, and a wide capsule between
the two `hip_bones` (`hip_radius` beyond the joints) pushes the top of the snow aside once it is up to the hips:
the trench is as wide as the body at the top and narrows to the legs at the bottom, which is how Red Dead
Redemption 2's troughs look.

Snow above the knee slows the character. `FootStamper` sets the character's `terrain_speed_scale`, when it has
one (the player controller's Player does), from 1 at `wading_starts` (half hip height) down to `wading_speed`
(0.4) at the hips, and back to 1 when the stamper leaves the tree.

## Kicked snow

A foot moving through the snow throws clumps of it forward from the surface above it: `kick_per_metre`
clumps for every metre it moves, thrown a kick of `SnowDeformation.kick_burst` at a time, at
`kick_speed_factor` of the foot's own speed with some lift. A planted foot throws nothing, nor does one
slower than `kick_min_speed`. The manager keeps a pool of `kick_pool` one-shot emitters, each moved to the
foot, aimed and restarted for one kick; `SnowDeformation.kick(at, velocity, clumps)` throws one by hand.
`kick_snow` turns it off.

`snow_depth` can be changed on a live node: the globals, the floor and the surface mesh follow, and the
tracks are cleared, since they were carved into snow of another depth.

## Physics objects

Anything that moves and has a collider presses the snow, the same way a `GrassField` is pressed: the
manager keeps an `Area3D` over its window, notices bodies entering and leaving, and presses each
one's own collision shapes into the snow every physics frame. A sphere presses as a ball; a capsule or
cylinder along its length; a box along its longest side, as thick as its middle one. So a ball rolling
through deep snow ploughs a rounded trough with berms down both sides, and a sword swing cuts a gouge
wherever the blade goes under the surface, with nothing added to the weapon: the player controller's
`WeaponBody` is an `AnimatableBody3D` with a blade-shaped box, and that is what gets pressed. Each
shape is swept from where it was on the last physics frame, up to 16 steps, so a slash covering most of
a metre in one frame still leaves one continuous cut. Only the part below the surface is carved, so a
blade dipped in cuts as far as it went and no further.

Only things that move count, the same list the grass uses: `CharacterBody3D`, `RigidBody3D`,
`AnimatableBody3D` and `PhysicalBone3D`. The ground, walls and rocks cleared their own snow when the
level was built and do not also push it about.

A body carrying its own `FootStamper` is skipped. Feet describe far
more than a sphere around the body's origin would, and pressing both would bury the prints under a
circle. `press_bodies` turns the whole thing off, `max_pressed_bodies` caps how many are pressed in one
frame, and when more are in the snow than that the widest and nearest win, again as in the grass.

The snow also holds a `RigidBody3D` back while it ploughs. `press_drag` is a drag in newtons per metre
per second for each square metre of the body pushed through the snow, so it does not scale with mass:
the default 1.5 stops a beach ball kicked at 6 m/s through 35 cm of snow after about 1.8 m, while a
boulder ploughs on. Every rigid body in the snow is held
back, including ones past the `max_pressed_bodies` stamp budget. Set it to 0 for no drag.

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

The surface shader needs the same heights on the GPU, and the manager provides them: when the provider is not
flat it samples the ground under the window every `ground_cell` metres, re-baking in `floor_step` jumps as the
focus moves, and gives the shader that heightmap. So the snow lies on any terrain its provider can see, and a
`SnowTerrainHeightRaycast` sees anything with collision. That is how it works on HTerrain, and the same holds
for Terrain3D and MTerrain, which also build collision from their heightmaps. Put the terrain's collision on a
layer of its own and give the raycast only that mask, or the snow is laid over whatever else the ray meets
first: the Player, a horse, a ball.

The snow mesh covers `surface_size` around the focus and thins to nothing over its last `surface_edge_taper`
metres, so it meets the ground beyond at ground level rather than as a ledge. Texture the terrain itself as
snow and the two read as one field.

## Snowballs

`scenes/snowball.tscn` is a `Snowball`, a `RigidBody3D` that starts the size of a football (22 cm across)
and grows as it rolls over the snow. It picks up a layer `pick_up_depth` thick along its width, so it
grows quickly while small and more slowly as it gets big: ten metres of rolling takes a football to a
ball a snowman can stand on. Its mass follows its volume at `density`, and the snow it picks up was
standing still, so it slows as it grows. `rolling_resistance` stops one that is let go of within a
couple of metres, and on packed snow it rolls without skidding.

It rides on the snow instead of sinking through it, because it masks the manager's floor layer (next
section). A snowball touching another one locks its rotation, so one set on top of another holds there
on friction: a snowman is stacked with nothing more than a pickup that can carry a `RigidBody3D`, such
as the player controller's own pickup and hold. `max_radius` caps the growth.

A big one sinks. The snow bears `snow_strength` pascals (2000 by default, soft settled snow), and a ball
settles in until the footprint it presses carries its weight: `Snowball.sinks_to` is 2 rho g r^2 / (3 strength),
about a centimetre for a football and a hand's depth for a snowman's base, never past a quarter of the radius
(`MAX_SINK`) or the snow there is. It ploughs a trench to its own underside as it rolls, and its rolling
resistance becomes the square root of the depth over the diameter (`sunk_resistance`, as for a wheel in soft
ground) once that is more than `rolling_resistance`, so a ball slows as it grows and at last stops. The
collider keeps the ball's shape above the snow and only its underside rides higher, kept upright however the
ball turns, so a ball stacked on it sits on what is drawn.

It catches the wind. `SnowDeformation.wind` is in metres per second, and each ball takes air drag on its
cross-section from it (`Snowball.wind_force`, half rho Cd A v^2 with `drag_coefficient` 0.47). Drag grows with
the square of the radius and the mass with the cube, so in a strong wind a football rolls off downwind, grows,
and stops once it is too heavy to push through the snow it has sunk into: in a 36 m/s storm, at about 0.3 m.
Wire a weather system to `SnowDeformation.set_wind(strength, direction)` in the scene, as both demos wire
WeatherFX's `wind_changed`; `wind_scale` converts a strength in units of the weather system's own.

A ball found under the floor, set down in the snow or left resting on the ground beyond the floor until the
focus came near, is lifted back on top of it (`SnowDeformation.floor_covers` says where the floor reaches).

Only the body's multiplayer authority grows it. `radius` is the one property a synchronizer has to
carry for the other peers to match.

## The packed snow floor

The snow has no collision of its own: feet, hooves and a beach ball sink through it to the ground
underneath and press it on the way. Something that should ride on the snow (a snowball, a sled) masks
`floor_layer`, layer 13 by default, and the manager lays a heightmap collider for it at the snow's
surface less `floor_sink`, with friction 1. It covers the whole window and moves with the focus in
`floor_step` jumps. Set `floor_layer` to 0 for no floor.

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
a blizzard, 35 cm of snow over flat ground, the player controller's Player, and three
balls to shove, and three snowballs to roll and stack. It needs `addons/3d_player_controller`, `addons/controls` and `addons/weather_fx`,
which `python tools/pull_addons.py` fetches here.

Walk and the feet cut prints with steep walls and raised rims; run and they merge into a ploughed
trench. Shove a ball and it ploughs a trough with berms down both sides.

- **F1** shows the deformation texture: red is the depression, green the berm, blue the disturbed mask.
- **F2** wipes every track.
- **F3** lets the falling snow fill tracks back in, at a rate following Weather FX's precipitation.
- **F4** switches to waist-deep snow (95 cm, the depth of Red Dead Redemption 2's opening) and back.

Footsteps and the crush of shoved snow use the addon's own `snow_footsteps.tres` and `snow_crush.tres`.

## Tests

`tests/` holds the unit tests: stamp packing against the shader's struct, the window's snapping and
scrolling, the height providers, the FootStamper's decisions, the drag on bodies ploughing through, a sword blade pressed along its length and swept between frames, the snowball's growth, weight, rolling and stacking, the packed snow floor, that the demo loads and reaches only the addons it depends on, and that every shader compiles and every
global it reads is declared. They run headless, where the compute half is off by design.

## Licence

MIT. See `LICENSE`. Third-party attributions are in `CREDITS.md`.

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

**Surfing.** A character surfing down the snow on a shield or a board says so through a boolean property the stamper
reads by name, `surfing_property` (`is_shield_surfing`, what the player controller's Player will call it), so the
character needs nothing from this addon. While it is true the feet leave no prints: the board presses a groove
instead, swept from where it was last frame, `board_size` (0.5 by 0.75 m) across and as deep as the board sits plus
`board_groove`, without digging the floor, and throws snow up behind it (`spray_per_metre`). With
`ride_snow_while_surfing` (on), the character gets the snow's `floor_layer` in its collision mask while it surfs and is
lifted onto that floor as it starts, so it skims the top of the snow the way a snowball rolls on it; when it stops,
the layer goes again and it sinks back to the ground under the snow. The stamper only gives the layer when the
character did not already have it, and only lifts the character on its own peer.

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
manager keeps an `Area3D` over its window, at the height of whatever it follows so a body on a hilltop is in it
as surely as one in the valley, notices bodies entering and leaving, and presses each
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
Subclass `SnowTerrainHeight` for anything else, and make the subclass a `@tool` script too, so the editor can
run it (next section).

The surface shader needs the same heights on the GPU, and the manager provides them: when the provider is not
flat it samples the ground under the window every `ground_cell` metres, re-baking in `floor_step` jumps as the
focus moves, and gives the shader that heightmap. After the first, each bake runs a few rows a frame, 2 ms at
most, while the last one stays in use, and the packed snow floor is laid from the same samples rather than
taking its own: walking over uneven ground used to stall a frame for about 35 ms every 4 m. So the snow lies on any terrain its provider can see, and a
`SnowTerrainHeightRaycast` sees anything with collision. That is how it works on HTerrain, and the same holds
for Terrain3D and MTerrain, which also build collision from their heightmaps. Put the terrain's collision on a
layer of its own and give the raycast only that mask, or the snow is laid over whatever else the ray meets
first: the Player, a horse, a ball.

The snow mesh covers `surface_size` around the focus and thins to nothing over its last `surface_edge_taper`
metres, so it meets the ground beyond at ground level rather than as a ledge. Texture the terrain itself as
snow and the two read as one field.

## Snow over the whole map

Set `map_rect` to the terrain's extent in world XZ and the snow lies on all of it and keeps every track, seen from
anywhere: across the valley, through a telescope. Only the level of detail follows the focus; the snow stays where
it is.

- **A map texture.** A second `RGBA16F` deformation texture covers `map_rect`, `map_resolution` texels a side (2048
  over 512 m is 25 cm a texel, 32 MB). It is fixed to the world and never scrolls, and every stamp is written into it
  as well as into the window, over only the texels round that frame's stamps. A print narrower than a map texel is
  widened to three quarters of one, or it would fall between texel centres. The window stays the fine layer, 2.3 cm
  in the demo, and the surface shader blends from it into the map over the window's border, so a trail keeps its
  crisp prints near the focus and is still there, coarser, when the focus has gone.
- **Mesh rings.** `surface_rings` puts rings of coarser mesh round the fine centre, each twice as wide as the one
  inside it with its vertices twice as far apart: five take a 32 m centre to a kilometre across. The mesh follows the
  focus in steps of its coarsest spacing, which every ring's spacing divides, so no vertex swims, and every other
  vertex on a ring's outer edge is put on the line between its neighbours (the offset to them is in its `UV2`), so the
  rings meet without cracks. The rings cast no shadow: every shadow pass runs the vertex shader again, and the terrain
  under them casts the hills' shadows already.
- **The map's ground**, baked once as the level loads at `map_ground_cell` (2 m, 0.17 s of raycasts over 512 m) and
  read with a cubic B-spline filter, because linear filtering between samples that far apart leaves creases a low
  sun turns into flat facets. The fine bake round the focus takes over within the window.

The snow ends at the map's edge, thinning over `surface_edge_taper`.

Measured on the v3 snow demo at 1600x900, RTX 4080 Laptop, vsync off, the Player walking at 6 m/s:

| | Mean frame | Worst frame | Load |
| --- | --- | --- | --- |
| No snow | 1.62 ms | 4.5 ms | |
| 48 m window, 32 m mesh | 3.02 ms | 19.1 ms | 1.08 s |
| 512 m map, 5 rings (1 km mesh) | 3.87 ms | 9.8 ms | 1.53 s |

The GPU was never the limit; the ground bake on the CPU was, which is why it now runs over several frames.

## In the editor

`SnowDeformation` is a `@tool`: in the editor it draws the snow where it will lie, undisturbed, so a level is
built to it rather than guessed at. The surface mesh and its rings follow the editor's camera as they would the
Player, over the ground baked round it, and with a `map_rect` the whole map's ground is baked too, so the snow
shows everywhere it will be. Changing `snow_depth`, the surface sizes, the rings, `map_rect`, `map_ground_cell`,
`ground_cell` or the height provider in the inspector redraws it. Nothing else runs there: no compute passes,
no floor, no pressing, and the preview's nodes are not saved with the scene. The height providers are `@tool`
scripts too, since the editor only runs a resource's script when it is one; a `SnowTerrainHeightRaycast` sees
HTerrain's collider in the editor as it does in the game.

## Snowballs

`scenes/snowball.tscn` is a `Snowball`, a `RigidBody3D` that starts the size of a football (22 cm across), drawn
with ambientCG's Snow 010 A mapped triplanar in its own space (`resources/snowball_material.tres`), so the grain
rolls with it and stays the same size as it grows,
and grows as it rolls over the snow, the way a Zelda snowball does. It picks up a layer `pick_up_depth` (3 cm)
thick along its width, so it grows quickly while small and more slowly as it gets big: ten metres of rolling takes a
football to a ball a snowman can stand on, and it keeps growing for as long as it rolls through snow. There is no
size limit unless `max_radius` sets one (0, the default, is none). Held in the hands and pushed through the snow, its underside below the
surface, it gathers snow the same way by the ground it covers, so a ball can be grown by carrying it low and walking.
Its mass follows its volume at `density`, but it keeps its speed as it grows rather than sharing its momentum with
the snow it picks up, which held a ball on a hill to a jog: let go at the top of the v3 snow demo's 40 degree hill,
into the blizzard, a football is rolling at 5 m/s and a metre across by the bottom, 21 m down.
`rolling_resistance` (0.15) stops one shoved on the flat within a few metres, while a hill of 12 degrees or more
rolls it away. Wherever it rolls on the snow it leaves its track, as wide as it is and as deep as its underside plus
the layer it picked up, pressed where it touches the snow: on a steep slope the snow straight below its middle is
lower than that, and a track pressed there vanished.

A rolling ball keeps to the snow. Going fast over a crest or a bump it would fly off the slope, growing nothing and
leaving no track, so while the floor is within `FLOOR_SNAP` (25 cm) below a ball that was rolling on it, the ball is
set back on it and loses the speed carrying it away. Off a real drop the floor is further than that and it flies; a
thrown ball, which was not rolling, is not held.

It takes only so much pushing. A character walking into a rigid body moves it as if the character were infinitely
heavy, in the physics engine and in the shove the Player gives what it walks into, so a ball the weight of a car
rolled off at walking pace. The ball cuts what a touching character adds to its speed back to what `push_strength`
(300 N, about a person's shove) could give it: a football is carried along, a ball a metre across still rolls, and
one grown past about 1.2 m, whose rolling in the snow resists more than that, will not budge on the flat. Picking it
up, carrying and throwing it are not limited, and 0 removes the limit.

On packed snow it rolls along the floor without skidding, uphill, downhill or across. The floor's friction keeps it
rolling; the script only puts a skid right (the surface slipping faster than `SKID_SPEED`, 0.3 m/s), such as a
Player's legs pushing a small ball below its middle and spinning it backwards. Setting the spin every step instead
fought the solver at each edge of the floor's cells and held a ball on a hill to a jog.

Rolling on the snow, it answers for its own resistance, so the manager's ploughing drag (`press_drag`) leaves any
body that rides the floor alone. Growing, it rises by as much as its collider grows, so it never grows into the
floor; the solver pushing a ball back out of the snow every frame had held one on a hill to walking pace.

It rides on the snow instead of sinking through it, because it masks the manager's floor layer (next
section). A snowball touching another one locks its rotation, so one set on top of another holds there
on friction: a snowman is stacked with nothing more than a pickup that can carry a `RigidBody3D`, such
as the player controller's own pickup and hold.

A stack holds only until something disturbs it. Anything but another snowball moving into a ball faster than
`knock_speed` (0.5 m/s: a Player walking into it, a swung sword) knocks it loose, as does another
snowball thrown at it faster than `thrown_speed` (2 m/s, where one set down on it to stack is slower), and so does
a ball in a stack that starts moving faster than `hold_speed`, which is what happens when the snow is
ploughed out from under the bottom one and the floor it stands on drops (next section). Either frees the whole
stack to roll for `knocked_time` (`Snowball.knock()`), so it topples the way it would. A ball stopped short, its
speed falling in one physics step by `break_speed` (8 m/s, a fall of more than three metres, or a hard throw at a
wall), falls apart. Nothing dropped from the hands comes near that, at any size: a ball picked up and let go of,
set down, rolled or tossed stays whole. A ball knocked loose breaks from much less, `knocked_break_speed` (3 m/s),
for `knocked_time` afterwards (`Snowball.breaks_at()`), so a snowman's head knocked off its base breaks where it
lands. Being set moving, shoved or struck never breaks it, so a Player walking into a snowman knocks the head off
without breaking the base. A round from a gun or an arrow does break it, at any size, held or not: a projectile
that calls `register_projectile_hit(projectile, point, normal)` on what it hits, as the player controller's do, gets
`Snowball.register_projectile_hit`, and the server asks a client holding the ball to break it. It falls apart
(`Snowball.shatter()`, with a `shattered` signal): half its snow scatters as a handful of clumps, plain rigid
bodies on no layer of their own that lie in the snow for `clump_life` seconds and melt away, and the rest goes
up as a spray. A head knocked off a snowman breaks where it lands; one set down by hand does not. Only the
body's authority decides it breaks, and it tells every peer by RPC.

A big one sinks. The snow bears `snow_strength` pascals (10000 by default, settled snow), and a ball
settles in until the footprint it presses carries its weight: `Snowball.sinks_to` is 2 rho g r^2 / (3 strength),
a couple of millimetres for a football, a centimetre and a half for a snowman's base and four for a ball a metre
across, so small and middling balls roll freely and only big ones bog down, never past a quarter of the radius
(`MAX_SINK`) or the snow there is. It ploughs a trench to its own underside as it rolls, and its rolling
resistance becomes the square root of the depth over the diameter (`sunk_resistance`, as for a wheel in soft
ground) once that is more than `rolling_resistance`, so a ball that grows big enough slows and at last stops. The
collider is a sphere half the sink smaller, riding on the floor, and the ball is drawn as much lower, so its
underside is in the snow while its top still meets a ball stacked on it. The picture moves, not the collider: a
collider shifted inside a spinning ball every step braked it to a crawl on any hill.

It catches the wind. `SnowDeformation.wind` is in metres per second, and each ball takes air drag on its
cross-section from it (`Snowball.wind_force`, half rho Cd A v^2 with `drag_coefficient` 0.47). Drag grows with
the square of the radius and the mass with the cube, so in a strong wind a football rolls off downwind, grows,
and stops once it is too heavy to push through the snow it has sunk into.
Wire a weather system to `SnowDeformation.set_wind(strength, direction)` in the scene, as both demos wire
WeatherFX's `wind_changed`; `wind_scale` converts a strength in units of the weather system's own. Both demos
set it to 0.43, which makes WeatherFX's blizzard (36) a 15.5 m/s wind, a real blizzard's.

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

The floor lies in whatever is dug out of the snow. Every stamp records how deep it went at the floor samples it
covers (within half a cell, since the samples are `floor_cell` apart and a print is narrower), and the floor is
lowered there, so a trench ploughed beside or under a snowball tips it in, and a stack on it comes down. The
record is kept by world position, so a trench is still there when the floor comes back to it; `get_floor_height`
and `dug_depth` read it. What a floor-riding body presses (a snowball's own track) does not dig the floor out from
under itself: `press_segment` and the `add_*` stamps take `digs_floor`, and the manager passes false for a body
that masks `floor_layer`.

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

Without a `map_rect`, tracks outside the coverage window are gone. With one, they are kept at the map's
coarser texel, but nothing is saved: a reloaded level starts with fresh snow. There is no accumulation on
objects.

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

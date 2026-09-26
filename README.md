# Snow Deformation for Godot 4.8+

Real-time deformable snow: footprints with berms, ploughed troughs behind physics
bodies that drag them to a stop, and compressed-snow shading inside every track.

**[Read the full documentation](addons/snow_deformation/README.md)**, which ships with the addon so it
is there however you installed it.

## This repository

It uses the layout the [Godot Asset Library](https://docs.godotengine.org/en/stable/community/asset_library/submitting_to_assetlib.html) expects, so it is both the addon and a
project you can open and edit it in:

```
project.godot              the demo project, which is this repository
addons/snow_deformation/   the addon itself, demo scene included
```

The demo also needs the player controller, its controls HUD and Weather FX, and the tests need GUT.
None of them are committed: `python tools/pull_addons.py` fetches them after cloning, pinned to the
commits in `tools/addons.lock.json`, and CI runs the same pull before the tests and the web export.

Clone it, run the pull, open `project.godot` in Godot, and press play. The addon is mounted at
`res://addons/snow_deformation/` exactly as it is in a game, so it is edited in place.

The web demo runs on the browser's Compatibility renderer, which has no compute, so the snow there is
carved by the addon's fragment fallback rather than the compute passes; the readout says which is running.

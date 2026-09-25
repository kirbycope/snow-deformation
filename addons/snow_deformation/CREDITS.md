# Credits

## Third-party assets

- **Gravity Sound** - *Snow Sound Effects* ([gravity-sound.itch.io/snow-sound-effects](https://gravity-sound.itch.io/snow-sound-effects)) - the 8 `snow_crunch` takes used for footsteps and the 5 `shovel_snow` takes used when something ploughs through the snow (`assets/audio/gravitysound/Snow Sound Effects/`), gathered into `resources/snow_footsteps.tres` and `resources/snow_crush.tres`. 13 of the pack's 103 files, converted from the pack's 16-bit 44.1 kHz WAV to Ogg Vorbis with `oggenc -q 6`. Licence not recorded: the store page states no terms and the download carries no licence file.

Everything else is original work: the two compute shaders, the surface and overlay shaders, the
GDScript, and the three node icons in `assets/icons/`. The wind ripples, the berm crumbs and the snow
glints are generated in the shader rather than sampled from a texture.

## Licence

The addon's code is MIT licensed; see `LICENSE`. The Gravity Sound files are not covered by it.

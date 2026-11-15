# Glide

Glide is a mod for Baldur's Gate II: Enhanced Edition. It makes walking creatures, and their selection circles, glide smoothly at high frame rates between the game's movement steps. Without it, a creature jumps from step to step.

Only the picture moves. The real positions of creatures are never changed, so clicking and targeting work as before.

## Requirements

- Baldur's Gate II: Enhanced Edition, version 2.7.3.0.
- [EEex](https://github.com/Bubb13/EEex), a mod framework for the Enhanced Edition games.
- The game must be started through InfinityLoader (the program that loads EEex).

Without EEex, Glide does nothing.

## Install and remove

Install: copy `M_Glide.lua` into the `override` folder of the game.

Remove: delete `M_Glide.lua` from the `override` folder.

## Settings

In the game, open the EEex Options and choose the tab "Glide". There is no key for switching the mod on or off.

| Setting | What it does | Default |
| --- | --- | --- |
| Smooth movement | Switches the whole mod on or off. | on |
| Selection circles glide | A walking creature's selection circle glides with its body. When off, the circle steps with the game while the body still glides. | on |
| Circle: glide into place on pause | When the game is paused and a circle is still on its way, it glides to the creature's real position over the glide-in time. When off, it arrives at the speed of the walk. | on |
| Body: glide into place on pause | The same for the creature's body. | off |
| Glide-in time on pause (ms) | The glide-in time in milliseconds, from 0 to 5000. 0 has the same effect as switching both "glide into place on pause" settings off. | 60 |

EEex saves these settings in the game's settings file, in the section "Glide". A change lasts across game starts, and it wins over the defaults written at the top of `M_Glide.lua`.

## If Glide is not installed

If the game's program code is not where Glide expects it (another game version, or another mod changed it), Glide installs nothing. It shows one error box that starts with "[Glide] not installed:" and the reason. The game then runs normally, without smooth movement.

## How it works

Glide places two hooks in the game's program while the game runs. One is in the function that draws a creature's body. The other is in the function that draws a selection circle. Both ask the same Lua code where the creature's picture belongs, so the circle and the body are drawn at the same place.

## Offline tests

The `tests` folder has three tests that run without the game. They need Lua 5.2 or later. Run them from this folder:

```
lua tests/glide-toggle-test.lua M_Glide.lua
lua tests/glide-circle-test.lua M_Glide.lua
lua tests/glide-refusal-test.lua M_Glide.lua
```

- `glide-toggle-test.lua` checks the settings and that no key is registered.
- `glide-circle-test.lua` checks that a selection circle is drawn where the body is drawn.
- `glide-refusal-test.lua` checks that Glide installs its hooks only when it should.

Each test ends with a line such as "0 failure(s)" when everything passes.

## License

All rights reserved. You may download Glide and play with it; re-uploading it or publishing modified versions needs the author's written permission. See the file `LICENSE`.

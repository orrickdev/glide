# Glide

Glide is a mod for Baldur's Gate II: Enhanced Edition. It makes walking creatures, and their selection circles, glide smoothly at high frame rates between the game's movement steps. Without it, a creature jumps from step to step.

Only the picture moves. The real positions of creatures are never changed, so clicking and targeting work as before.

The optional second file, Glide View (`M_GlideV.lua`), makes the view glide too when it follows a character: while you hold a party member's number key, after a double-click on the portrait of a character who is off-screen, or while the view is locked on a creature. Without it, the view jumps in steps of several pixels as the character walks.

## Requirements

- Baldur's Gate II: Enhanced Edition, version 2.7.3.0.
- [EEex](https://github.com/Bubb13/EEex), a mod framework for the Enhanced Edition games.
- The game must be started through InfinityLoader (the program that loads EEex).

Without EEex, Glide does nothing.

## Install and remove

Install: copy `M_Glide.lua` into the `override` folder of the game. For Glide View, also copy `M_GlideV.lua` there. Glide View needs `M_Glide.lua` for its settings and its On/Off.

Remove: delete `M_Glide.lua` and `M_GlideV.lua` from the `override` folder. To keep Glide without Glide View, delete only `M_GlideV.lua`.

## Settings

In the game, open the EEex Options and choose the tab "Glide". There is no key for switching the mod on or off.

| Setting | What it does | Default |
| --- | --- | --- |
| On/Off | Switches the whole mod on or off, Glide View included. | on |
| Selection circles glide | A walking creature's selection circle glides with its body. When off, the circle steps with the game while the body still glides. | on |
| Circle: Glide-in on pause | When the game is paused and a circle is still on its way, it glides to the creature's real position over the glide-in time. When off, it arrives at the speed of the walk. | on |
| Body: Glide-in on pause | The same for the creature's body. | off |
| Glide-in time on pause (ms) | The glide-in time in milliseconds, from 0 to 5000. 0 has the same effect as switching both "Glide-in on pause" settings off. | 60 |
| View Damping | Glide View only: the view glides when it follows a character. When off, the view moves the game's own way. | on |
| Follow Damping (ms) | Glide View only: how long the view takes to catch up with the character it follows. 0 means instant. | 120 |
| Jump Damping (ms) | Glide View only: how long the view takes to reach an off-screen character. 0 means instant. | 300 |

EEex saves these settings in the game's settings file, in the section "Glide". A change lasts across game starts, and it wins over the defaults written at the top of `M_Glide.lua`.

## If Glide is not installed

If the game's program code is not where Glide expects it (another game version, or another mod changed it), Glide installs nothing. It shows one error box that starts with "[Glide] not installed:" and the reason. The game then runs normally, without smooth movement.

Glide View checks its own hook place the same way. If it does not match, Glide View installs nothing and writes a line starting with "[GlideView] not installed:" to the loader's log (only if `LogFile` is set in `InfinityLoader.ini`); it shows no error box. Glide itself keeps working.

## How it works

Glide places two hooks in the game's program while the game runs. One is in the function that draws a creature's body. The other is in the function that draws a selection circle. Both ask the same Lua code where the creature's picture belongs, so the circle and the body are drawn at the same place.

Glide View places one more hook, in the function that draws the area, after the game's logic has run and before anything is drawn. There it moves the view with a critically damped spring towards where the game puts it: smooth speed-up and slow-down, no overshoot. It changes only the view's position, never a creature's. It does nothing during cutscenes and while the game shakes the screen.

Every hook changes the game's program code while the game runs. Switching a setting off stops what the hook does, but the hook stays in place until the game is closed. To run the game without the Glide View hook, delete `M_GlideV.lua`.

## Offline tests

The `tests` folder has three tests that run without the game. They test `M_Glide.lua`; Glide View has no offline test. They need Lua 5.2 or later. Run them from this folder:

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

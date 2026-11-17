# Changelog

## 2 - 2026-11-17

- New optional file Glide View (`M_GlideV.lua`): the view glides when it follows a character (a held party number key, a double-click on an off-screen character's portrait, or a lock on a creature).
- Three new settings in the "Glide" tab for Glide View: "View Damping" (on/off), "Follow Damping (ms)" (120) and "Jump Damping (ms)" (300).
- "Smooth movement" is now called "On/Off" and also switches Glide View.
- "Circle: glide into place on pause" and "Body: glide into place on pause" are now called "Circle: Glide-in on pause" and "Body: Glide-in on pause". Saved settings are kept.

## 1.0.0 - 2026-11-15

- Walking creatures glide smoothly between the game's movement steps.
- Selection circles glide with the bodies and are drawn at the same place as the body.
- Real positions are never changed, so clicking and targeting work as before.
- When the game is paused, a circle or body that is still on its way can glide into place over a set time.
- A tab "Glide" in the EEex Options holds the settings. EEex saves them in the game's settings file.
- If the game's code is not what Glide expects, it installs nothing and shows a message starting "[Glide] not installed:".

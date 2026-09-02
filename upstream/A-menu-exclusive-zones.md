# Draft A — Omarchy: the menu and overlays should respect layer-shell exclusive zones

**File against:** basecamp/omarchy (shell, `plugins/menu/Menu.qml` and the
other full-screen overlays: image selector, emojis, clipboard, keyboard
panel).
**Version:** Omarchy 4.0.0 "Quattro", Quickshell 0.3.1.
**Status:** draft; a human files it after filling in the measurement below.

## Summary

The menu is a full-screen overlay-layer `PanelWindow` with
`exclusionMode: ExclusionMode.Ignore`, and it centres its card on the whole
screen. An on-screen keyboard is a bottom-anchored layer surface that
reserves its height with an exclusive zone, as every keyboard does. Because
the menu ignores that reservation, a long menu's card runs under the
keyboard: the rows at the bottom are covered by the thing you would type
into them with.

## Measurement

_(filled in at the hands-on checkpoint: with the keyboard up in landscape,
open Setup › Plugins and record where the card's bottom edge sits relative
to the keyboard's top edge, in logical pixels; the keyboard occupies
y 412..750 on the 1200x750 panel, top edge at 412.)_

    card bottom: ___ px      keyboard top: 412 px      overlap: ___ px

## Expected

`exclusionMode: ExclusionMode.Normal` on the menu window (keep
`exclusiveZone: 0`, so it reserves nothing itself) — the compositor then
hands it the area not reserved by the bar and the keyboard, and
`panel.height` becomes that area, so the existing centring and the
`Math.round(panel.height * 0.7)` cap in `availableRowsHeight()` do the rest.
The Gimbal plugin's own swipe strips used exactly that arrangement to place
themselves around the bar and the keyboard without duplicating any geometry.

Happy to send the PR; it is a one-line change per overlay, and the scrim
would then also stop short of the keyboard, which is what a tap on the
keyboard should not be: a tap on the scrim.

## Notes

- The keyboard sits *above* the menu today by re-inserting itself when the
  menu opens (a layer bounce; Hyprland's Lua `order` rule is inert, see
  draft C), so typing into the menu works. What does not is seeing the
  bottom rows of a long menu.
- Tested with `io.github.mechanicsunlocked.gimbal`'s `fw12-oskbd`, namespace
  `fw12tab-osk`, exclusive zone = its height.

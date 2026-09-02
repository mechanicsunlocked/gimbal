# Draft D — Omarchy: the menu should take keyboard focus on demand, not exclusively

**File against:** basecamp/omarchy (shell, `plugins/menu/Menu.qml`; the same
applies to every full-screen overlay using `WlrKeyboardFocus.Exclusive`).
**Version:** Omarchy 4.0.0 "Quattro", Quickshell 0.3.1, Hyprland 0.56.2.
**Status:** draft; a human files it.

## Summary

With the menu open, no touch can reach any other surface on that monitor —
not an on-screen keyboard stacked above it, not anything. Hyprland routes
every pointer and touch event to layer surfaces with *exclusive* keyboard
interactivity before it hit-tests anything else
(`InputManager.cpp`, `mouseMoveUnified`, "forced above all", keyed on
`m_exclusiveLSes`, which is exactly the mapped surfaces set to
`ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE`). The menu's
full-screen `MouseArea` then cancels it. On a tablet that means the menu
cannot be typed into at all: the keyboard you would type with is the thing
that closes it.

## The change

    -    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    +    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

## Why nothing is lost

Measured on Hyprland 0.56.2 with a scratch full-screen overlay carrying a
key catcher, a key injected through the compositor after it mapped:

| `keyboardFocus` | focus on map | key received |
|---|---|---|
| `Exclusive` | yes | yes |
| `OnDemand` | yes | yes |

Hyprland grants keyboard focus on map to any layer whose interactivity is
not `NONE` (`LayerSurface.cpp`, `GRABSFOCUS`), and a later touch on a
surface whose interactivity *is* `NONE` — an on-screen keyboard — does not
move focus away (`InputManager.cpp` line 733). The scrim keeps working: a
tap on it is a tap on the menu, since nothing else is under the finger there.
What changes is only that a surface stacked above the menu can now be
touched.

The same reasoning applies to the polkit prompt, emojis, clipboard,
reminders and image selector overlays.

One caveat, measured after the first version of this draft: with a second
monitor and the mouse on it, an on-demand overlay can lose keyboard focus to
a window under the pointer (`allowKeyboardRefocus` is only held false for
exclusive layers, and `refocusLastWindow()` skips on-demand ones). Gimbal's
clones therefore switch to on demand only while the machine is folded, where
there is no mouse. Upstream could do the same on a touchscreen, or keep
exclusive focus and ask Hyprland (draft C's neighbour) not to route input
past surfaces stacked above an exclusive layer.

## Context

`io.github.mechanicsunlocked.gimbal` puts a layer-shell keyboard above the
menu on a Framework Laptop 12 in tablet mode (a `set_layer` bounce, since the
Lua `order` rule is inert — draft C). Everything about stacking is right and
the finger still lands on the scrim. Happy to send the one-line PR.

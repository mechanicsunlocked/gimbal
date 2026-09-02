# Draft C — Hyprland: the Lua `layer_rule` accepts `order` and never applies it

**File against:** hyprwm/Hyprland
**Version:** 0.56.2 (commit efb5099, built 2026-08-05), Lua config manager as
shipped by Omarchy 4.0.0.
**Status:** draft; a human files it.

## Summary

`hl.layer_rule({ match = { namespace = ... }, order = N })` is accepted by
the Lua API — the field is in `HL.LayerRuleSpec` in the shipped
`stubs/hl.meta.lua`, an unknown field is refused with
`hl.layer_rule: unknown field`, and a rule object comes back — but it has no
effect on stacking within a layer, in any combination tried. Other layer
rules through the same path apply immediately.

## Reproduction

Two 200x200 Quickshell `PanelWindow`s on the overlay layer of one monitor,
namespaces `gimbal-scratch-a` (red, mapped first) and `gimbal-scratch-b`
(blue, mapped second), overlapping. The pixel in the overlap read back with
`grim -s 1 -g "500,400 1x1" -t ppm`.

| step | rule | applied | pixel | `hyprctl layers` |
|---|---|---|---|---|
| 1 | none | — | blue | a, b |
| 2 | `order = 5` on a | while mapped | blue | a, b |
| 3 | `order = 5` on a | before both remapped | blue | a, b |
| 4 | `order = 5` on a and `order = 9` on b | while mapped | blue | a, b |
| 5 | `order = 5` on a before map, then another overlay surface mapped and unmapped to force a re-arrange | | blue | a, b |
| 6 | `order = -9` on a, re-arranged again | | blue | a, b |

Control: `hl.layer_rule({ match = { namespace = "^gimbal-scratch-b$" }, dim_around = true })`
via the same `hyprctl eval` darkened the wallpaper within a second while
mapped, and stayed applied across a remap. So Lua layer rules apply live;
`order` specifically is parsed and stored and not consulted.

    $ hyprctl eval 'hl.layer_rule({ match = { namespace = "^x$" }, bogus = 5 })'
    error: ...: hl.layer_rule: unknown field 'bogus'
    $ hyprctl eval 'hl.layer_rule({ match = { namespace = "^x$" }, order = 5 })'
    ok
    $ hyprctl configerrors
    (empty)

Second observation that may help: a mapped layer surface that changes layer
(`zwlr_layer_surface_v1.set_layer`, Top then back to Overlay in two commits)
is re-inserted at the top of its new level, so map order can be
re-established that way. That is what an on-screen keyboard has to do today
to sit above a full-screen overlay menu.

## Expected

`order` orders surfaces within a level as the legacy `layerrule = order, N`
documented: higher on top.

## Why it matters

An on-screen keyboard on the overlay layer has to be above a full-screen
overlay menu whose scrim cancels on any click, or the keyboard cannot type
into the menu. Map order is the wrong tool for that (the menu maps later),
and `order` is exactly the right one.

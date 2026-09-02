# The overlay clones: one line each

(No `manifest.json` here: `omarchy plugin clone` writes it, and a second one
in the repo would make it look like two plugins to Omarchy's tooling and the
marketplace.)

`install.sh` clones five of Omarchy's overlays — the menu, the polkit
password prompt, the emoji picker, the clipboard picker and the reminder
prompt — and changes one line in each. This directory keeps the menu's file
as the worked example (a verbatim commit, then the change); the other four
get the identical edit at install time, applied to the clone's own current
file, and `uninstall.sh` removes a clone only if that edit is the only
difference.

The change, in `Menu.qml` and its four siblings: the overlay takes keyboard
focus on demand *while the machine is folded*, and exactly as Omarchy shipped
it otherwise. It reads the same one-word mode file Gimbal's knobs read.

    -    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    +    WlrLayershell.keyboardFocus: gimbalMode.tablet ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
    +    FileView { id: gimbalMode; property bool tablet: false; path: ... "/gimbal-mode"; watchChanges: true; ... }

Only while folded, because on demand has a cost on a laptop with a second
monitor: a mouse moving onto a window there takes keyboard focus away from
the open overlay, which exclusive focus prevents (FINDINGS 20). Folded, there
is no mouse and the screen is the overlay.

## Why

With the stock menu open, a finger on the on-screen keyboard closes the menu.
Not because of stacking — the keyboard is drawn above the menu, pixel-verified
— but because Hyprland routes every pointer and touch event to layer surfaces
with *exclusive* keyboard interactivity before it hit-tests anything else
(`InputManager.cpp`, `mouseMoveUnified`, "forced above all"). The finger lands
on the menu's scrim, which cancels it. An on-demand layer is not in that list,
still takes keyboard focus when it maps, and still receives typed keys
(FINDINGS 19.1, 19.3). Reproduced and then fixed with a virtual-pointer click
on the keyboard's `a` key: exclusive, the menu closed; on-demand, the menu
filtered on `as` and stayed, and a click on the scrim still closed it.

This is Omarchy's file, so it is a clone rather than a plugin change, and
upstream draft **D** (`upstream/D-menu-ondemand-focus.md`) asks for the word
to change at the source. When it does, remove the clone.

## Installing it by hand

`install.sh` does this; by hand it is, for each of the five:

```bash
omarchy plugin clone omarchy.menu          # creates ~/.config/omarchy/plugins/<you>.menu, switches to it
# then apply the edit shown above to the clone's Menu.qml (install.sh's patch_overlay function is the exact form)
omarchy-restart-shell
```

The same for `omarchy.polkit` (`PolkitAgent.qml`), `omarchy.emojis`
(`Emojis.qml`), `omarchy.clipboard` (`Clipboard.qml`) and `omarchy.reminders`
(`ReminderFlow.qml`). Each is one `keyboardFocus` line.

The restart is not optional. Saving a plugin file hot-reloads it, but Qt
caches compiled components by URL and a component that was already loaded
keeps its old code until the shell restarts (FINDINGS 3.1i, and 19.2 where
it cost a test). The namespace stays `omarchy-menu`, so every keybind, the
`omarchy-menu` command, and Gimbal's keyboard keep working unchanged.

## Taking it out

```bash
omarchy plugin remove <you>.menu           # and .polkit, .emojis, .clipboard, .reminders
```

Removing an active clone switches back to the built-in.

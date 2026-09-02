# The overlay clones: one word each

`install.sh` clones five of Omarchy's overlays — the menu, the polkit
password prompt, the emoji picker, the clipboard picker and the reminder
prompt — and changes one word in each. This directory keeps the menu's file
as the worked example (a verbatim commit, then the one-word commit); the
other four get the identical change by `sed` at install time, and
`uninstall.sh` removes a clone only if that word is the only difference.

A clone of Omarchy's menu (`omarchy.menu`) that differs from the stock file by
one word, in `Menu.qml`:

    -    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    +    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

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

```bash
omarchy plugin clone omarchy.menu          # creates ~/.config/omarchy/plugins/<you>.menu, switches to it
sed -i 's/WlrKeyboardFocus.Exclusive/WlrKeyboardFocus.OnDemand/' ~/.config/omarchy/plugins/<you>.menu/Menu.qml
omarchy-restart-shell
```

The same three lines for `omarchy.polkit` (`PolkitAgent.qml`),
`omarchy.emojis` (`Emojis.qml`), `omarchy.clipboard` (`Clipboard.qml`) and
`omarchy.reminders` (`ReminderFlow.qml`). Each is one `keyboardFocus` line.

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

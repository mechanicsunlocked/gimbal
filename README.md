# Gimbal

**Turns a Framework Laptop 12 into a real tablet on Omarchy.**

Fold the screen back and the display, touch and pen rotate with you, an
on-screen keyboard appears when you tap a text field, two thumb knobs give you
gestures, and the lock screen gets a keypad. Unfold it and it all goes away
again. Nothing runs while the machine is a laptop.

<!-- preview.png: the Omarchy menu with the keyboard and a knob, folded -->

## Install

Two commands. No root, nothing outside your home folder.

```bash
omarchy plugin add https://github.com/mechanicsunlocked/gimbal.git --enable --yes
~/.config/omarchy/plugins/io.github.mechanicsunlocked.gimbal/install.sh
```

The second one asks a single question — whether to set up the lock-screen
keypad and let the keyboard type into Omarchy's menu and prompts (say yes) —
then builds the keyboard, installs the rotation module, and restarts the
shell. It prints one optional extra step at the end that needs root; see
[The boot fix](#the-boot-fix-optional).

**To update:** run the same two commands again.

**To remove:**

```bash
~/.config/omarchy/plugins/io.github.mechanicsunlocked.gimbal/uninstall.sh
omarchy plugin remove io.github.mechanicsunlocked.gimbal
```

Requirements: Omarchy 4 on a Framework Laptop 12. The packages it builds
against (`gtk4`, `gtk4-layer-shell`, `libxkbcommon`, `wayland`, `pkgconf`,
`gcc`) are all in Omarchy's own repositories; the installer checks and tells
you the one `pacman` line if any is missing. Nothing from the AUR.

## Using it

### Fold

Fold the screen all the way back. Within a moment the picture turns to match
how you are holding the machine, and two round knobs appear at the bottom
corners. Fold it back into a laptop and everything returns to normal.

Hold the machine flat and it keeps the last orientation rather than guessing.
`SUPER + R` locks the rotation where it is, for reading in bed; unfolding
unlocks it again.

### The keyboard

It comes up by itself when you tap a text field, and goes away when you tap
somewhere else. It also comes up for the things Omarchy asks you to type
into: the menu (type to filter, arrows, Enter, Esc; tap beside it to
dismiss), a password prompt, the emoji and clipboard pickers, a reminder.

For everything else — keyboard shortcuts, a terminal, a field that already had
focus before you folded — you can call it yourself, and the same action puts
it away:

| | |
|---|---|
| **tap a knob** | while folded |
| **swipe up on a knob** | while folded |
| **the keyboard icon** in the top bar | while folded; it lights up while the keyboard is out |
| **`SUPER + B`** | in laptop mode too |

A keyboard you called yourself stays until you put it away. One that came up
by itself goes away by itself.

It is half-transparent and sits over your windows rather than pushing them
up, so it costs less of the screen; both are settings.

It is laid out like the Laptop 12's own keyboard, so your hands already know
it: function row under `fn`, real `ctrl` / `alt` / `alt gr`, the Framework
key as Super, a proper arrow cluster. Tap a modifier once for the next key,
twice to lock it. Accents and dead keys work exactly as on the real keyboard,
and it follows whatever keyboard layout Hyprland is set to. Every Omarchy
shortcut works from it: tap the Framework key, then the rest of the chord.

If you type on a Bluetooth keyboard while folded, the on-screen keyboard
stops appearing by itself until you tap a knob once. That is deliberate.

### The knobs

Two round knobs sit where your thumbs are. Both do the same things:

| Do this | Get this |
|---|---|
| **tap** | show / hide the keyboard |
| **drag up** | show / hide the keyboard |
| **drag down** | the Omarchy menu |
| **drag left / right** | next / previous workspace |
| **press and hold** | unlock the knob — now drag it anywhere, then press and hold to stick it down |

A knob fills with your accent colour while the keyboard is out, and swells
while it is unlocked for moving. Positions are remembered. Each knob can be
switched off in the settings, so you can run one thumb or two.

### The lock screen

Locked and folded, a keypad is already on the lock screen: type your password
on it and press `⏎`. The `⌄` key hides it; tapping the password field brings
it back. Fingerprint unlock works as before. In laptop mode the lock screen is
unchanged.

### Settings

Two icons appear in the top bar while folded: the keyboard, and an attitude
indicator that opens the settings.

| Setting | What it does |
|---|---|
| **Interaction** | each knob on or off |
| **Keyboard** | whether it appears by itself; how solid it is; whether it pushes windows up or covers them |
| **Gestures** | the command each knob drag runs |
| **Gaming** | hold the keyboard and the menu back while a Moonlight stream is on screen |

### Streaming a game

While you are on the workspace a Moonlight window is on, nothing brings the
keyboard or the menu up — not a tap, not a swipe, not a text field. Workspace
swipes still work, so you can always leave.

### The boot fix (optional)

The Framework 12's fold switch sometimes loses a race at boot, about one boot
in three. Gimbal copes — it falls back to the hinge angle, so folding still
works, just noticed within five seconds instead of instantly. If you would
rather have instant, this one root command closes the race for good:

```bash
sudo ~/.config/omarchy/plugins/io.github.mechanicsunlocked.gimbal/system/install.sh
```

It adds two kernel modules to the boot image and a small service that binds
the switch if it still came up unbound. `uninstall.sh` prints how to take it
out again rather than doing it.

## If something is off

**The mouse cursor is gone and the touchpad seems dead**, but taps still
work. Not Gimbal: the Framework 12's touchpad sometimes comes up in the wrong
mode after a cold boot or a hibernate. Check `hyprctl cursorpos` — if it reads
the bottom-right corner and only ever moves towards it, see the rebind in
[KNOWN-ISSUES.md](KNOWN-ISSUES.md).

**A text field does not bring the keyboard up.** Not every program tells the
system it has a text field; a terminal rarely does. Tap a knob. The full list
of what does and does not is in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

**Something else.** [KNOWN-ISSUES.md](KNOWN-ISSUES.md) is the honest list of
rough edges, and the bottom of it says what to grab before reporting one at
<https://github.com/mechanicsunlocked/gimbal/issues>.

---

## For the technically curious

Everything above this line is all you need. Everything below is how it works,
for anyone who wants to know or wants to change it.

### What is in the box

| Piece | What it is |
|---|---|
| `lua/gimbal.lua` | ~500 lines of Lua loaded into Hyprland's own config: reads the fold switch and the accelerometer, rotates display, touch and pen together, sets `follow_mouse` while the keyboard is out. No daemon. |
| `osk/fw12-oskbd` | the keyboard: a GTK4 layer-shell program in C. Resident while folded, started on fold and killed on unfold; shown and hidden by signal; fcitx5's virtual keyboard over D-Bus, which is how it knows a text field took focus. It uploads the system's own xkb keymap and sends real key codes, which is why shortcuts, dead keys and AltGr all work. |
| `Panel.qml`, `BarWidget.qml` | the Omarchy shell plugin: the knobs, the bar icons, the settings panel, and the policy for when the keyboard may appear by itself. |
| `lock-clone/`, `menu-clone/` | the things that cannot live in a plugin: a keypad inside a clone of Omarchy's lock screen, and a one-word change to clones of the menu, the password prompt and the pickers, so a touch on the keyboard reaches them. `install.sh` sets them up with `omarchy plugin clone`; each has a README. |
| `tools/fw12-foldstate` | reads the fold switch as a level, so a missed event cannot leave the machine stuck in the wrong mode. |
| `system/` | the optional root boot fix. |
| `upstream/` | four issue drafts for Omarchy and Hyprland, each with its measurement. |

### Checking on it

```bash
cat "$XDG_RUNTIME_DIR/gimbal-mode"           # tablet | laptop
cat "$XDG_RUNTIME_DIR/gimbal-osk"            # visible | hidden
cat "$XDG_RUNTIME_DIR/gimbal-autoshow"       # on | off
fw12-foldstate                               # what the fold switch says right now
pgrep -x fw12-oskbd                          # the keyboard daemon (only while folded)
hyprctl layers | grep -E 'osk|gimbal|menu'   # what is on screen, bottom to top
busctl --user list | grep VirtualKeyboard    # who fcitx5 thinks its keyboard is
hyprctl eval 'require("hypr.gimbal").status()'
```

### Setting things by hand

The settings panel writes `~/.config/omarchy/gimbal.json`. The same keys can
also go in this plugin's entry in `~/.config/omarchy/shell.json`; values in
`gimbal.json` win.

```json
{
  "padLeft": true,
  "padRight": true,
  "swipeUp": "@keyboard",
  "swipeDown": "@menu",
  "swipeLeft": "hyprctl dispatch 'hl.dsp.focus({ workspace = \"r+1\" })'",
  "swipeRight": "hyprctl dispatch 'hl.dsp.focus({ workspace = \"r-1\" })'",
  "swipeThreshold": 30,
  "autoShow": true,
  "keyboardOpacity": 0.5,
  "keyboardReservesSpace": false,
  "blockOnMoonlight": true
}
```

`@keyboard` and `@menu` are the two built-in actions; anything else runs as a
shell command; `""` disables a swipe. Note that `hyprctl dispatch` takes a Lua
expression on Omarchy 4, and that the `r` workspace selectors move exactly one
workspace where the `e` ones skip empty ones. Set `tabletOnly` to `false` at
the top of `Panel.qml` to keep the knobs in laptop mode.

To put the knobs back where they started, delete
`~/.local/state/omarchy/gimbal-pads.json` and restart the shell.

### The documents

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit and why each decision was made.
- [FINDINGS.md](FINDINGS.md) — the measurements behind every one of those decisions, with the commands.
- [KNOWN-ISSUES.md](KNOWN-ISSUES.md) — where it is still rough, and what has and has not been tested by hand.
- [TESTING.md](TESTING.md) — the by-hand checklist.
- [LUKS.md](LUKS.md) — why there is no keyboard at the disk-unlock prompt, and what to do instead.

### Layout notes

The board follows `input:kb_layout` and `input:kb_variant`. **US International
is the same keyboard as US** with `'` `"` `` ` `` `~` `^` as dead keys and more
characters under AltGr; `altgr-intl` keeps the apostrophe an apostrophe and
puts the accents behind `AltGr`. The layout is read when the shell starts, so
change it, then `omarchy-restart-shell`.

### About the install

Omarchy's installer deliberately never runs code from a plugin it has just
cloned, which is why there are two commands rather than one; the second is
yours to read first. `install.sh` also works from a plain `git clone`. It is
idempotent, doubles as the upgrade step, and touches nothing outside `$HOME`.
The clones it sets up are ordinary `omarchy plugin clone` copies and go away
with `omarchy plugin remove`.

### Trademarks

Gimbal is an independent community project, not made by, endorsed by, or
affiliated with Framework Computer Inc. "Framework" and the Framework logo are
trademarks of Framework Computer Inc. The logo appears in one place,
descriptively: on the Super key of the on-screen keyboard, reproducing the
legend printed on that key of the actual laptop. It is an optional asset; if
`~/.local/share/gimbal/framework-logo.svg` is removed, the key shows `❖`
instead and nothing else changes.

MIT. See `LICENSE`.

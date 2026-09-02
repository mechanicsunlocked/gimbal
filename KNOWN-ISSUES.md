# Known issues

Gimbal works, and it is also unfinished in specific ways. This page is the
honest list, so that anything you run into is something you were warned about
rather than something you had to discover.

If you hit something that is *not* here, that is worth reporting — see the
bottom.

## What it has actually been tested on

One machine. Everything in this repo was measured on:

| | |
|---|---|
| Framework Laptop 12 | eDP-1 1920×1200, scale 1.6 |
| Omarchy | 4.0.0 "Quattro", released 14 August 2026 |
| Hyprland | 0.56.2 |
| Quickshell | 0.3.0 |
| Kernel | 7.1.8-arch |

If you are on a different convertible, the parts most likely to need changing
are the fold switch (`SW_TABLET_MODE` is found by capability, so it should just
work) and the accelerometer mount matrix in `lua/gimbal.lua`, which is specific
to how this display is fitted.

Omarchy 4 is new rather than unstable — Quattro shipped on 14 August 2026 and
rewrote the whole desktop shell in Quickshell. That still matters here, because
the shell plugin API it introduced is the newest thing Gimbal depends on and
the most likely to move under it. Not a warning about the distribution; a note
about which part of Gimbal is standing on the freshest ground.

(If you check `/usr/share/omarchy/version` and see `4.0.0.alpha`, that string
is stale in the release itself. `pacman -Q omarchy` is the one to trust.)

---

## Rough edges

### Keyboard focus can still wobble

**What you see.** Occasionally, after touching the on-screen keyboard, what you
type does not reach the window you expected.

**Why.** A finger resting on the keyboard detaches keyboard focus, because what
is under the finger is a layer surface, not a window. Gimbal buys that back by
setting `follow_mouse = 2` while the keyboard is up — but that setting has its
own open bug upstream, where keyboard focus can be lost after focus returns
from a layer surface ([hyprwm/Hyprland#9980][9980]).

**Status.** Mitigated, not fixed. It used to be held for the entire time the
machine was folded; it is now held only while the keyboard is actually on
screen, which is the only time it does anything. **That shrinks the window the
bug can bite in. It does not close it.** The real fix is upstream and is not
ours to make.

**If it happens.** Tap the window you meant to type into. Putting the keyboard
away and bringing it back also clears it.

[9980]: https://github.com/hyprwm/Hyprland/issues/9980

### Where the keyboard does not appear by itself

**What you see.** You tap a text field while folded and nothing comes up.

**Why, and what does work.** The keyboard appears when fcitx5 says a text
field took focus, and fcitx5 only hears about fields from clients that speak
`zwp_text_input_v3` or its own Qt and GTK modules. Measured here (FINDINGS
17.5): foot and a GTK4 entry ask, and get it; the Omarchy menu does not ask
but is handled on our side, since opening it is the request. Still open:

| Client | State |
|---|---|
| ghostty | not installed on this machine. One earlier measurement saw auto-show fire (3.1f), another table had it with no `text_input_v3` at all. Until it is measured again, treat it as the ceiling: summon by hand. |
| a Qt text field | the scratch field never took focus in the automated run; on the hands-on list |
| Chromium | on the hands-on list |
| a field that already had focus when you folded | fcitx5 sends the show on focus-in, and the fold came after it; tap the field again |

**A hardware keyboard turns it off.** fcitx5 stops offering an on-screen
keyboard the moment it sees a key it did not inject, which while folded means
a Bluetooth keyboard — and then not popping the keyboard is right. The next
knob tap turns auto-show back on (FINDINGS 17.8).

**Enter in the menu can leave it up.** The keyboard ignores any hide that
arrives within 300 ms of its own keystroke, because fcitx5 sends one for
every key it types (FINDINGS 17.1). A menu closed by Enter loses focus inside
that window, so if the window underneath is not a text field the keyboard
stays until the next real hide or a knob tap.

**If you want none of it.** The `Keyboard` switch in the settings panel, or
`"autoShow": false` in `~/.config/omarchy/gimbal.json`. The knobs, the bar
icon and `SUPER + B` are unaffected.

### fcitx5 can be left with no user interface

**What you see.** After the keyboard process was killed outright, fcitx5
shows no candidate window or popups; `fcitx5-remote` still answers.

**Why.** While the keyboard is registered, fcitx5 is in on-screen mode.
Releasing the registration in that mode leaves it with no valid UI, and the
only thing that puts the mode back is a hardware-looking key from the
registered keyboard (FINDINGS 17.4). The daemon sends one before it leaves,
so a clean exit — unfold, `SIGTERM`, a shell restart — ends on `classicui`
every time. A `SIGKILL` skips it.

**If it happens.** `systemctl --user restart omarchy-fcitx5.service`.
Check with `gdbus call --session --dest org.fcitx.Fcitx5 --object-path
/controller --method org.fcitx.Fcitx.Controller1.CurrentUI`.

### The layout is read when the shell starts

**What you see.** You change `input:kb_layout`, and the on-screen keyboard
keeps the old legends until the shell restarts.

**Why.** The plugin reads the layout once when it loads and passes it to the
daemon on every start. This was already so; a resident daemon makes it
slightly more visible, because the daemon lives for the whole fold.

**Status.** Not built yet; a shell restart picks it up.

### A knob takes the whole screen while you are moving it

**What you see.** Nothing, normally. But while a knob is unlocked for dragging,
its surface covers the display.

**Why.** The knob is a layer surface with an input mask cut to the circle.
While locked it is knob-sized (101×101), so a masking slip costs a small patch.
While *unlocked* it goes full-screen, because that is the area it has to be
draggable across.

**Status.** Deliberate, and the safer of the options — the alternative was
measuring drag translation against a surface that is itself moving. The
full-screen state has to be entered with a deliberate triple tap and is marked
by the accent ring the whole time it lasts.

**If it happens.** Triple-tap again to stick the knob back down.

### Touch can die inside a streamed game

**What you see.** Using a knob to open the Omarchy menu over a fullscreen
Moonlight stream, and then the stream stops answering touch at all.

**Why.** The menu is a fullscreen layer surface that takes keyboard focus, and a
client capturing input for a stream does not reliably take that capture back
afterwards. Ruled out by measurement that it was ours: the menu unmaps cleanly
and focus does return to the window.

**Status.** Not ours to fix, only to avoid. While you are on the workspace a
Moonlight window is on, the keyboard and the menu are both held back. Workspace
swipes still work, because leaving is what you still want.

### Without the boot fix, a fold takes up to five seconds

**What you see.** You fold the machine and nothing happens for a moment.

**Why.** The Framework 12 exposes its fold switch through ACPI `INT33D3`, and
whether that binds is a race, lost on roughly one boot in three. When it loses,
there is no fold switch on the machine at all and Gimbal falls back to the
hinge angle, which it re-reads every five seconds.

**Status.** Working as intended, and much better than it was — a lost race used
to mean rotation was simply dead until the next boot. Run the optional root step
in the README if you want folds noticed instantly.

### The cursor "disappears" and this one is not Gimbal

**What you see.** The mouse cursor is gone. The touchpad seems dead, but taps
and gestures still work, and so do the keyboard and the touchscreen. Looks
exactly like the Gimbal fault below, and is not related to it.

**Why.** The Framework 12's PIXA3854 touchpad sometimes comes up in legacy
**mouse mode** instead of Precision Touchpad mode -- seen after a cold boot, and
reliably after resuming from hibernation. In that mode the pointer is driven by
the device's legacy Mouse collection, which is malformed in firmware: its
relative X/Y axes are declared with an *unsigned* 0..255 range, so a movement of
-1 is delivered as +255. The pointer can then only travel down and to the right,
and pins itself in the bottom-right corner within one stroke. The kernel logs
nothing; good and bad boots are indistinguishable in `dmesg`.

**Status.** Not Gimbal, and not fixable from Gimbal -- it is below the
compositor entirely. Worked around outside this repo with a rebind at boot and
after resume:

```bash
sudo sh -c 'echo 0018:093A:0239.0002 > /sys/bus/hid/drivers/hid-multitouch/unbind
            echo 0018:093A:0239.0002 > /sys/bus/hid/drivers/hid-multitouch/bind'
```

**If it happens.** Check `hyprctl cursorpos` first. If it reads the bottom-right
corner of your logical screen and only ever moves toward it, this is it -- run
the rebind above. If instead the mode file says `tablet` while the machine is
open, that is the Gimbal fault and it clears itself within five seconds.

---

## Not tested by hand yet

Said plainly, because it is the difference between "verified" and "should
work". These were changed and verified by measurement and by injecting the
failure, but not yet by a person touching the screen:

* **Triple-tap unlock and drag**, since the knob surface now changes size when
  you unlock it.
* **A real fold cycle** since the fold detection moved onto the switch level,
  and since the keyboard became a process the fold starts and stops.
* **Everything the keyboard now does by itself** — appearing for a text
  field, for the menu, staying up while you type on it, going away, and
  fcitx5 being whole afterwards. All of it was measured with the fold
  simulated and the keys sent by a script (FINDINGS 16, 17); none of it has
  been touched with a finger.
* **The keyboard above the menu**, and a knob resting on the keyboard.

`TESTING.md` has the list, in the order to do it.

---

## If you hit something else

Worth grabbing before you report — these are the things that get asked first:

```bash
hyprctl cursorpos                            # pinned to a corner? see above
cat "$XDG_RUNTIME_DIR/gimbal-mode"           # tablet | laptop
fw12-foldstate                               # what the fold switch says now
cat "$XDG_RUNTIME_DIR/gimbal-fold"           # what Gimbal last read from it
pgrep -x fw12-oskbd                          # is the keyboard daemon running (while folded, it should be)
cat "$XDG_RUNTIME_DIR/gimbal-osk"            # visible | hidden
cat "$XDG_RUNTIME_DIR/gimbal-autoshow"       # on | off: may it appear by itself right now
hyprctl layers | grep -E 'osk|gimbal|menu'   # what is on screen, bottom to top
hyprctl getoption input:follow_mouse         # 2 while the keyboard is visible and folded
busctl --user list | grep VirtualKeyboard    # who fcitx5 thinks its keyboard is
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
  --method org.fcitx.Fcitx.Controller1.CurrentUI   # virtualkeyboard while folded, classicui otherwise
hyprctl eval 'require("hypr.gimbal").status()'
omarchy plugin validate .
```

Then open an issue at
<https://github.com/mechanicsunlocked/gimbal/issues>, with what you expected,
what happened, and whether the machine was folded at the time.

A report that says "the mouse cursor keeps vanishing" is genuinely useful even
when it sounds unrelated — that exact symptom turned out to be tablet mode
latching on with two full-screen knob surfaces over the desktop, and it took a
while to connect the two.

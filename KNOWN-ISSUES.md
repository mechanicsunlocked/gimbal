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

### The keyboard does not appear by itself

**What you see.** Tapping a text field does nothing. You have to summon the
keyboard yourself — knob tap, knob swipe up, the bar icon, or `SUPER + B`.

**Why.** Auto-show needs the compositor to tell an input method that a text
field took focus, which needs the *application* to implement
`zwp_text_input_v3`. Measured on the two terminals installed here:

| Terminal | `text_input_v3` | Auto-show would |
|---|---|---|
| foot | bound | work |
| ghostty | absent | never fire |

**Status.** Not built. It is worth adding for GTK and Qt apps, browsers and
foot — but it can never be the only way in, because in ghostty there is no text
field as far as Wayland is concerned. Two things also have to be settled first:
fcitx5 already occupies the seat's input-method slot, and only one client can
hold it; and the keyboard would have to run persistently rather than being
started and stopped, which is a change to how it works rather than an addition
to it.

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
* **A real fold cycle** since the fold detection moved onto the switch level.

Both are the first things to try, and the first things to report if they
misbehave.

---

## If you hit something else

Worth grabbing before you report — these are the things that get asked first:

```bash
hyprctl cursorpos                            # pinned to a corner? see above
cat "$XDG_RUNTIME_DIR/gimbal-mode"           # tablet | laptop
fw12-foldstate                               # what the fold switch says now
cat "$XDG_RUNTIME_DIR/gimbal-fold"           # what Gimbal last read from it
pgrep -x fw12-oskbd                          # is the keyboard up
hyprctl layers | grep -E 'osk|gimbal'        # what is on screen
hyprctl getoption input:follow_mouse
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

# Testing Gimbal by hand

Most of Gimbal has been verified by measurement — by reading the switch, by
injecting the failure and watching it recover, by decoding what actually
reaches the compositor. That is good for proving mechanisms and useless for
proving the thing is pleasant to use. Fingers find what measurement does not.

This is the list to work through before a release, and the list to work through
again when something feels off. Tick as you go; note what you saw rather than
just pass or fail, because "worked, but the second tap felt late" is the useful
kind of report.

## Before you start

Know which machine state you are in, so a surprise is attributable:

```bash
fw12-foldstate                               # 0 laptop, 1 folded
cat "$XDG_RUNTIME_DIR/gimbal-mode"           # tablet | laptop
hyprctl cursorpos                            # see the note on the touchpad below
```

**One confound to rule out first.** On the Framework 12 the touchpad sometimes
comes up in legacy mouse mode, and then the pointer only travels down and right
and pins in the bottom-right corner. That is not Gimbal — see
[KNOWN-ISSUES.md](KNOWN-ISSUES.md). If `hyprctl cursorpos` reads the corner and
only ever moves toward it, fix that first, or you will spend the session
blaming the wrong thing.

## Fold detection

- [ ] Fold the machine. Tablet mode arrives without a visible delay.
- [ ] Unfold. Laptop mode returns, bar icons disappear, knobs unmap.
- [ ] Fold and unfold ten times in a row. No state gets stuck.
- [ ] **Pause mid-fold** and hold it there for several seconds, then continue.
      The hinge angle reports `500` as an indeterminate sentinel through that
      range; the switch level should carry it anyway.
- [ ] Fold, then close and reopen the lid without unfolding.
- [ ] Fold while an application is fullscreen.

## Rotation

- [ ] Rotate through all four orientations. The screen follows.
- [ ] In each orientation, **touch lands where you aim**. Drag a window by its
      title bar to be sure — a transform error shows up as drift, not as an
      obvious failure.
- [ ] In each orientation, **the stylus lands where you aim**, and agrees with
      touch. These are transformed separately and can disagree.
- [ ] Rotate quickly, several times, and stop at an angle. It settles rather
      than oscillating.
- [ ] Lock rotation, rotate the machine, confirm the screen stays put.

## Knobs

The knob surface is knob-sized (101x101) while locked and goes full-screen while
unlocked for dragging, so unlocking changes the thing you are touching. That is
the part most likely to feel wrong.

- [ ] Single tap opens the keyboard.
- [ ] Swipe up from a knob opens the keyboard.
- [ ] **Triple-tap unlocks.** The accent ring appears.
- [ ] Drag the unlocked knob. It tracks your finger without jumping.
- [ ] Drag it to each of the four screen edges and triple-tap to lock there.
      Check it sits sensibly at each, in both orientations.
- [ ] While a knob is unlocked, confirm the rest of the screen still works
      where you expect it to, and that you can get out with a triple-tap.

## Keyboard

- [ ] Opens in foot, and typing reaches foot.
- [ ] Opens in a browser text field, and typing reaches the field.
- [ ] Keybinds still work while the keyboard is up — `SUPER` combinations in
      particular, since these were broken by an earlier approach.
- [ ] Rest a finger on the keyboard for a few seconds, then type. Focus should
      survive; this is the known-wobbly one.
- [ ] Close and reopen the keyboard several times.
- [ ] `SUPER + B` and the bar icon both open it.
- [ ] Bar icons are absent in laptop mode and present in tablet mode.

## Gestures and the safety net

- [ ] Workspace swipes, in both directions, in each orientation.
- [ ] On a workspace with a fullscreen Moonlight stream, confirm the keyboard
      and the menu are held back, and that swiping away still works.
- [ ] Leave the machine folded and idle for a minute, then use it. Nothing has
      drifted.

## Boot and resume

The parts most likely to be wrong after a change, and the least likely to be
noticed until they matter.

- [ ] Reboot several times. On boots where `gpio-keys` loses its ACPI race,
      folding is noticed within about five seconds rather than never.
- [ ] Hibernate and resume. Gimbal recovers its fold state, **and** the
      touchpad workaround fires (see KNOWN-ISSUES.md).
- [ ] Suspend and resume. Same.
- [ ] Fold *while* the machine is suspended, then resume folded.

## Before publishing

- [ ] `omarchy plugin validate .` exits 0.
- [ ] `hyprctl configerrors` is clean after `hyprctl reload`.
- [ ] Installed copies match the repo.
- [ ] Uninstall works, and leaves nothing behind.
- [ ] Install on a clean state and confirm the documented steps are the ones
      that actually work.
- [ ] Decide the Framework logo question — ship the `❖` fallback by default,
      or resolve permission first. See the Trademarks section of the README.

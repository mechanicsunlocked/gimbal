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

- [ ] Single tap opens the keyboard, at once -- there is no longer a wait.
- [ ] Swipe up from a knob opens the keyboard.
- [ ] **Press and hold for half a second unlocks.** The accent ring appears.
- [ ] Drag the unlocked knob. It tracks your finger without jumping.
- [ ] Drag it to each of the four screen edges and press-and-hold to lock there.
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

## The keyboard inside the menu (checkpoint 1)

Folded, keyboard up, then the menu:

- [ ] Typing on the keyboard filters the menu, and the menu stays.
- [ ] Arrows move the cursor, Enter activates, Esc closes.
- [ ] A tap *outside* the keyboard still dismisses the menu.
- [ ] Setup › Plugins, a long one: note where the card's bottom edge sits
      against the keyboard's top edge, in pixels if you can (`hyprctl
      layers` gives the keyboard's `y`; a screenshot gives the card). That
      number goes into `upstream/A-menu-exclusive-zones.md`.
- [ ] A knob resting on the keyboard is drawn on top of it and can still be
      dragged (three taps, drag, three taps).
- [ ] The Moonlight workspace and laptop mode behave as before.

What the script already checked: `hyprctl layers` lists `fw12tab-osk` above
`omarchy-menu` while both are mapped, opening and closing the menu leaves the
keyboard mapped, and the knob is listed above the keyboard again after the
menu closes (FINDINGS 15.5). And, after the first hands-on round found a tap
closing the menu: with the menu clone (`menu-clone/`, one word) a
virtual-pointer click on the `a` key types into the menu and a click on the
scrim still closes it (FINDINGS 19.3). The overlap is measured too: 253 px
of the root card under the keyboard, landscape.

## The resident keyboard (checkpoint 2)

- [ ] Fold. `pgrep -x fw12-oskbd` finds exactly one process, and
      `$XDG_RUNTIME_DIR/gimbal-osk` says `hidden`.
- [ ] Tap a knob: it is on screen at once. There should be nothing to wait
      for — it is a surface being mapped, not a program starting. Note if it
      ever feels late.
- [ ] Tap the knob, the bar icon and `SUPER + B` in turn; each toggles, and
      the bar icon lights while it is out.
- [ ] Unfold with the keyboard up: it goes, and `pgrep` finds nothing.
- [ ] Laptop mode: `SUPER + B` brings it up and puts it away as before, and
      `pgrep` finds nothing afterwards.
- [ ] `hyprctl getoption input:follow_mouse` reads `2` while it is up and
      folded, `1` otherwise.

Already checked by script: one process through 20 rapid toggles, the state
file and `follow_mouse` tracking every one of them, nothing surviving a
simulated unfold (FINDINGS 16.3).

## Appearing by itself (checkpoint 3)

Folded, keyboard hidden. Note what each does; "works", "never", or "came up
then went away" are all useful.

- [ ] foot: tap into it. Expect the keyboard. Tap the desktop or a non-text
      window: expect it to go after a moment.
- [ ] ghostty (`extra/ghostty`, not installed here at the time of writing):
      expected never; two earlier measurements disagree. Write down which.
- [ ] Chromium: the address bar, then a page's text field.
- [ ] A GTK app's text field. (A GTK4 entry did in the script.)
- [ ] A Qt app's text field. (Unverified: the scratch field never took focus.)
- [ ] The Omarchy menu: open it with the keyboard hidden. Expect the keyboard;
      close it, expect it to go — unless a text field is under it.
- [ ] A password prompt (start something that needs `pkexec`, or a VM):
      the keyboard comes up, typing puts dots in the field, Esc cancels.
- [ ] The emoji picker, the clipboard picker, and a reminder: typing on the
      keyboard reaches each, and a tap beside them still dismisses them.
- [ ] Tap the Framework key, then Shift: the number row must still read
      `1..0`, and `Super+Shift+1` must move the window to workspace 1.
- [ ] Type a few words on the on-screen keyboard into a field. It must stay.
      This is the risk the whole design turns on (FINDINGS 17.1, 17.7).
- [ ] Summon it with a knob, then tap a non-text window. It must stay: you
      asked for it.
- [ ] Turn `Keyboard` off in the settings panel. Tap a field: nothing. The
      knob still works. Turn it back on.
- [ ] Laptop mode never shows it by itself. Tap fields, open the menu.
- [ ] After every unfold: `gdbus call --session --dest org.fcitx.Fcitx5
      --object-path /controller --method org.fcitx.Fcitx.Controller1.CurrentUI`
      says `classicui`, and `~/.XCompose` sequences still work.
- [ ] If you have a Bluetooth keyboard: type on it while folded. The on-screen
      keyboard goes and stays away for text fields until you tap a knob.

## The lock screen (checkpoint 4)

Only with the `phase4-lock` branch's clone installed (see
`lock-clone/README.md`). The clone is the stock lock screen plus a keypad;
until you have used it once, keep a way to unlock that does not depend on it.

- [ ] Laptop mode, `SUPER + CTRL + L`: the lock screen looks exactly as
      before. No keypad.
- [ ] Folded, lock: the keypad is already there (it opens on fold; ⌄ hides
      it, a tap on the field brings it back). Type the password on it; Enter
      unlocks. If nothing is there, `journalctl --user -t omarchy-shell | grep
      'gimbal lock'` says whether the fold reached it.
- [ ] A wrong password shows the error state, and the keypad stays.
- [ ] Fingerprint still unlocks with the keypad up.
- [ ] Leave it to idle-lock while folded; unlock by keypad.
- [ ] Fold, lock, unfold: unlock with the physical keyboard.

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

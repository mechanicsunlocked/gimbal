# The lock screen keypad

A clone of Omarchy's own lock screen (`omarchy.lock`) with one addition: while
the machine is folded, tapping the password field brings up a keypad, drawn by
the lock screen itself. In laptop mode nothing is different.

## Why it cannot ship in the plugin

Two reasons, and both are hard limits rather than preferences.

**The protocol.** The lock screen is an `ext-session-lock` surface. While the
session is locked, the compositor renders *only* lock surfaces and delivers
input *only* to them; every layer surface, including Gimbal's keyboard, is
neither drawn nor touchable. A keyboard for the lock screen therefore has to
be part of the lock screen. There is no protocol path around this, and that is
by design — it is what makes a lock screen a lock screen.

**The plugin system.** Omarchy's lock screen is a first-party plugin of kind
`service`, and a third-party plugin cannot shadow a first-party id or add
itself to another plugin's surface. What Omarchy does offer is
`omarchy plugin clone`: it copies a built-in plugin into your own config as
`<username>.lock`, switches to it, and routes every `lock` IPC call to it. So
the keypad lives in a clone, and the clone lives here, on this branch, as a
diff against the stock files — not in the plugin.

Upstream draft **B** (`upstream/B-lock-extension-slot.md`) asks for a proper
extension point, with these files as the proof of shape.

## What is in here

| file | state |
|---|---|
| `manifest.json` | as `omarchy plugin clone` wrote it: id `msa.lock`, `clonedFrom: omarchy.lock` |
| `Service.qml` | untouched |
| `LockView.qml` | stock, plus the fold-state reader, the tap on the field, and the keypad |
| `LockView.patch` | the same change as a patch against the stock file; `install.sh` applies it to Omarchy's current file and refuses, with a warning, if that has changed |
| `LockKeypad.qml` | new: plain QWERTY, digits, a symbols page, one-shot shift |

`git log -- lock-clone/` shows the stock files as their own commit, so the
diff is the whole change.

## Installing it by hand

The id carries your username — Omarchy does this so shared clones cannot
collide — so it is created on your machine, not copied from here:

```bash
omarchy plugin clone omarchy.lock                     # creates ~/.config/omarchy/plugins/<you>.lock, switches to it
cp lock-clone/LockView.qml lock-clone/LockKeypad.qml ~/.config/omarchy/plugins/<you>.lock/
```

Then restart the shell. This is not optional: saving a plugin file hot-reloads
it, but Qt caches compiled components by URL and an already-loaded `LockView`
keeps its old code until the shell restarts (FINDINGS 3.1i and 19.3).

```bash
omarchy-restart-shell
```

Check it took:

```bash
journalctl --user -t omarchy-shell --since -1min | grep -i -E 'lock|error'
omarchy-shell lock status
omarchy-shell lock preview      # the stock view, a click closes it; no keypad in laptop mode
```

Then lock by hand (`SUPER + CTRL + L`) once while you still have a physical
keyboard to hand, before relying on it folded.

## Taking it out

```bash
omarchy plugin remove <you>.lock
rm -rf ~/.config/omarchy/plugins/.<you>.lock.bak.*    # the hidden backup `plugin remove` keeps
```

Removing an active clone switches back to the built-in (`shell/README.md`,
"Cloning"). `uninstall.sh` does both.

## What it does not do yet

- It is not the Framework 12 replica; it is a keypad for a password.
- The layout is QWERTY whatever `input:kb_layout` says. A password typed on
  it is the characters shown on it.
- Fingerprint, the idle blank and the wrong-password state are the stock
  code paths, untouched; the checklist in `TESTING.md` covers them with the
  keypad up.
- The keypad opens by itself when the machine folds while locked, and the ⌄
  key puts it away; tapping the field brings it back.

# Draft B — Omarchy: an extension slot for the lock screen, or a replaceable `lock` kind

**File against:** basecamp/omarchy (shell, `plugins/lock/`).
**Version:** Omarchy 4.0.0 "Quattro", Quickshell 0.3.1.
**Status:** draft; a human files it. Attach `lock-clone/` from the
`phase4-lock` branch of `mechanicsunlocked/gimbal` as the proof of shape.

## Summary

A convertible in tablet mode has no keyboard at the lock screen, and no
on-screen keyboard can help: under `ext-session-lock` the compositor renders
only lock surfaces and delivers input only to them, so a layer-surface
keyboard is neither drawn nor touchable. The only place a keyboard can live is
inside the lock screen. Today a third-party plugin has no way to put anything
there: `omarchy.lock` is a first-party `service`, its `LockView` is
instantiated inside `Service.qml`, and a third-party id cannot shadow a
first-party one.

`omarchy plugin clone omarchy.lock` works, and it is what the attached
change uses — but a clone is a fork of the whole lock screen. Every upstream
fix to `LockView.qml` or `Service.qml` has to be merged by hand into every
user's `<username>.lock`, on the one component where being behind is a
security problem.

## What would do

Either of:

1. **A slot.** `LockView.qml` gains an `extras` area — a `Loader` or
   `Repeater` over components that enabled plugins declare through a new
   kind (`lock-extra`?) or manifest field — with a small API: read
   `passwordText`, call `passwordTextEdited(text)` and
   `submitPassword(text)`, know `inputEnabled` and `failureMessage`. That is
   exactly the surface the attached keypad uses, and nothing more.
2. **A replaceable kind.** As `bar` can be replaced by enabling another
   bar, let a plugin declare `kinds: ["lock"]` and replace the lock screen
   wholesale, with the PAM plumbing (`Service.qml`) staying first-party.

(1) is smaller and keeps the security-sensitive code first-party; it is the
one asked for.

## Proof of shape

The attached `lock-clone/` is stock `omarchy.lock` plus:

- `LockKeypad.qml`, a plain QWERTY keypad with digits and a symbols page,
  ~190 lines, no dependencies beyond `qs.Commons`;
- 69 added lines in `LockView.qml`: a `FileView` on a runtime file that says
  whether the machine is folded, a `MouseArea` on the password field that
  opens the keypad (disabled in laptop mode, so nothing changes there), and
  the keypad instance wired to `passwordTextEdited` and `submitPassword`.

Nothing in `Service.qml` changed. That is the whole API a slot would need.

## Why it matters

Framework Laptop 12 in tablet mode, and every other convertible: fold it,
let it idle-lock, and there is no way back in without unfolding. The rest of
tablet mode on Omarchy (rotation, gestures, an on-screen keyboard that
appears for text fields) can be done from a plugin; the lock screen is the
one piece that cannot.

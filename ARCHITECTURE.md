# Architecture — `io.github.mechanicsunlocked.gimbal`

Design derived from measured Phase 0 results. See `FINDINGS.md` for the
evidence behind every claim here.

**Revised 2026-08-15** after discovering Hyprland's Lua config can do the
hardware work itself. The earlier draft proposed a C daemon for tablet
detection and rotation; that has been removed. Nothing is kept here because it
was already written.

---

## The one-paragraph version

One piece. **Tablet detection and auto-rotation are ~200 lines of Lua** loaded
into Hyprland's own config: the compositor already receives the
`SW_TABLET_MODE` switch and can read the accelerometer from sysfs, so no
separate process, socket, or systemd unit is involved. Plus a one-time root
fix for a firmware probe race that otherwise costs the tablet switch on some
boots.

Plus **the keyboard**: `fw12-oskbd`, a GTK4 layer-shell board laid out like the
machine's own. While the machine is folded it is a resident process that
appears when a text field takes focus — it registers with fcitx5 as its
virtual keyboard over D-Bus, and fcitx5, which holds the input method, says
when — and when the Omarchy menu opens. Two draggable knobs summon it for
everything else. See Component B.

---

## Component A — `lua/gimbal.lua` (no daemon)

Installed to `~/.config/hypr/gimbal.lua`, activated by one line in
`~/.config/hypr/hyprland.lua`:

```lua
require("hypr.gimbal")
```

`package.path` includes `~/.config/?.lua` (set by Omarchy's `bootstrap.lua`),
and Omarchy's own config file invites exactly this: *"Add any other personal
Hyprland configuration below."*

### How each part works

| Concern | Mechanism | Evidence |
|---|---|---|
| Tablet enter/exit | `hl.bind("switch:on\|off:gpio-keys", …, {locked=true})` | binds fire, both directions, verified |
| Initial state on load | hinge angle `>= 200°` from `cros-ec-lid-angle` | binds are edge-triggered and cannot report current position |
| Orientation | `io.open` on `accel-display` `in_accel_{x,y,z}_raw` at 4 Hz | 82 µs mean / 291 µs worst per 3-axis read |
| Apply rotation | `hl.monitor{transform=…}` + `hl.config{input={touchdevice,tablet}}` | applied and reverted live |
| Rotation lock | `hl.bind("SUPER + R", …)` | SUPER+R free; existing R binds are SUPER+CTRL variants |

### The decisions that are not obvious

**Sensors are resolved by `label`/`name`, never by index.** IIO numbering moves
between boots — `cros-ec-accel.11.auto` was `accel-base` on one boot and
`accel-display` on the next. An index would silently rotate to the *keyboard*
half of the laptop and look like flaky hardware. Lua has no directory listing,
so the module probes `iio:device0..15` and matches the attribute.

**The switch is the source of truth, not the hinge angle.** The firmware owns
the hysteresis (enters 220–257°, leaves 106–170°) and emits one clean debounced
event per transition. The angle reads `500` — an "indeterminate" sentinel —
reliably *during* the fold, exactly where detection matters most. The angle is
used only to seed initial state at load, where `> 360` is treated as unknown.

**Flat means hold, not guess.** With the screen horizontal, gravity is on Z and
X/Y carry no orientation information. The classifier returns "no opinion" and
the previous orientation stands, rather than snapping to a default.

**Monitor, touch and stylus rotate together**, always, or the pen and finger
stop landing where the user is pointing.

**Reload safety.** Omarchy's `bootstrap.lua` clears every `hypr.*` module from
`package.loaded` on config reload, so this file re-executes on every `hyprctl
reload`. State lives on a global and prior binds and timers are torn down
first; otherwise each reload stacks another 4 Hz timer and a duplicate bind.

**`hyprctl keyword` does not work here.** Omarchy 4 uses the Lua config
manager, which refuses it outright (`keyword can't work with non-legacy
parsers. Use eval.`) while `hyprctl` still exits 0. Any port from an
Omarchy 3 / hyprlang setup fails silently. Direct `hl.*` calls avoid the issue
entirely.

### The trade-off, stated honestly

The 4 Hz poll runs **inside the compositor process**. A callback that blocks or
throws degrades the whole desktop, which a separate process could not. Measured
cost is 82 µs mean and 291 µs worst per sample — 0.03% of compositor time, and
under 2% of one 60 Hz frame even at worst. That is comfortably safe, but it is
the reason the tick does nothing at all outside tablet mode and never retries
in a loop.

---

## Component B — `osk/` and `plugin/` (the keyboard, and the button)

`osk/fw12-oskbd` is a GTK4 layer-shell keyboard laid out like the Framework
Laptop 12's own board: function row under `Fn`, real Ctrl / Alt / AltGr, the
Framework key as Super, and a faithful arrow cluster. It was written for
[`fw12tab`](https://github.com/mechanicsunlocked/fw12tab) and is vendored here
(same author, same MIT licence).

`Panel.qml` and `BarWidget.qml` are an Omarchy shell plugin installed to
`~/.config/omarchy/plugins/io.github.mechanicsunlocked.gimbal/`. They draw two
round, draggable knobs, the two bar icons, and the settings panel; they own
the keyboard's lifetime; and they hold the policy for when it may appear on
its own.

### The daemon

While the machine is folded, `fw12-oskbd` is a resident process: the plugin
starts it hidden when the mode file says `tablet` and kills it when the mode
goes back to `laptop`, so laptop mode carries nothing resident. Showing and
hiding it is a signal — `SIGUSR1` maps the surface, `SIGUSR2` unmaps it — so
the path a finger is waiting on never spawns a process, and so there is
something already running for fcitx5's show to arrive at. `SIGTERM` leaves
cleanly, releasing every latched modifier.

It publishes `visible` or `hidden` to `$XDG_RUNTIME_DIR/gimbal-osk`, from its
own map and unmap rather than from the last request, so a reader sees the
truth of the surface; if it dies the word goes to `hidden` and the next tap
starts it again. The bar icon, the knobs and the Lua's `follow_mouse` all read
that one file. `g_file_set_contents` renames a complete file into place, and
the Quickshell watchers survive the rename (§16.1). It dies with its parent
(`PR_SET_PDEATHSIG`), so a shell restart cannot leave a second one behind.

Laptop mode keeps the old shape: `SUPER + B` starts it showing and it lives
exactly as long as it is on screen. Measured in §16.3: exactly one process
through any number of toggles, the state file and `follow_mouse` tracking
twenty rapid toggles with no mismatch, nothing surviving an unfold.

### Why it appears by itself, and why the knobs stay

fcitx5 holds Hyprland's single `input-method-v2` slot. Measured twice, not
assumed — Hyprland answers a second client with `unavailable` (§8.1, §15.1).
Any on-screen keyboard here is therefore blind to which text field has
focus. fcitx5 is not: it is the input method, so it knows exactly when a
field takes or loses focus, and its "DBus Virtual Keyboard" addon hands that
to whoever owns the bus name `org.fcitx.Fcitx5.VirtualKeyboard` as
`ShowVirtualKeyboard` and `HideVirtualKeyboard` calls. While folded, the
daemon owns that name, exports the object fcitx5 expects, and maps or
unmaps on those two calls. The contract is read from fcitx5's own source and
measured here (§15.4, §17); nothing in fcitx5 is configured, stopped or
replaced — the addon is on demand and loads when asked.

Two gates, both read per event from one-word runtime files: `gimbal-mode`
must say `tablet`, and `gimbal-autoshow`, which the plugin writes from the
`autoShow` setting and the Moonlight hold-back, must not say `off`. Policy
stays in the plugin, mechanism in the daemon, and nothing polls.

The knobs stay because not everything a keyboard is wanted for is a text
field: keybinds, the terminal that never activates an input method, a
password prompt that a hardware keyboard has just claimed. And who asked
matters: a keyboard the user summoned stays until the user puts it away;
one that came up by itself goes away by itself, after a 300 ms wait that any
Show cancels, since focus moving between fields is a Hide and a Show a few
milliseconds apart (§3.1i).

**The one real fight, and how it is won.** fcitx5 hides its keyboard the
moment it sees a key that did not come through its own D-Bus injection — it
takes any such key for a hardware keyboard and switches mode — and our keys
come through the compositor, so every key we send is one of those. Measured:
the Hide arrives within 20 ms of the keystroke, every time, and the source
has no switch for it (§15.4, §17.1). So a Hide within 300 ms of our own key
is ours: ignored, and answered by asserting the on-screen mode again. Measured
through the daemon's own key path, the board stays up and fcitx5 is back in
on-screen mode within 200 ms (§17.7). A hardware keyboard — Bluetooth, while
folded — still turns auto-show off, which is fcitx5's design and the right
call; one knob tap turns it back on (§17.8).

**Leaving without breaking fcitx5.** Releasing the name while fcitx5 is in
on-screen mode leaves it with no user interface at all, and nothing but a
hardware-looking key puts the mode back (§17.4). So the daemon's last act is
one key with no symbol on it, evdev 240, then the name goes. fcitx5 ends
every run on `classicui`.

**The menu is not a text field**, as far as fcitx5 can tell: opening it
activates an input context and never asks for the keyboard, because its
search is a key catcher rather than a `TextInput` (§17.3). It is driven by
typing, so the daemon treats `openlayer>>omarchy-menu` as a field taking
focus, on the same gate, and `closelayer` as it losing focus — unless a
field takes over, whose Show cancels the pending hide.

### Above the menu

The menu is a full-screen overlay-layer surface whose scrim cancels on any
click, and within one layer Hyprland stacks by map order, so a menu opened
after the keyboard sat on top of it. The keyboard moved to the overlay layer,
and on `openlayer>>omarchy-menu` it steps to the top layer and back in two
commits: Hyprland re-inserts a surface that changes layer at the top of its
new one, with no unmap, no flash and no reflow (§15.5). The clean fix would
be a layer-rule `order`; this Hyprland accepts one from Lua and ignores it
(§15.2, upstream draft C). The knobs share the overlay layer now, so the
plugin bounces them the same way whenever the keyboard maps or the menu
closes, and a knob resting on the keyboard stays on top and draggable.

### Why it uploads the system keymap instead of inventing one

This is the decision the whole component turns on, and three things fall out of
it (measured, §9):

**Keybinds work as shipped.** Hyprland matches binds by *keycode* unless
`input:resolve_binds_by_sym` is on, and it is off by default. A keyboard that
brings its own keymap brings its own keycodes, so none of them match and not a
single bind fires — verified with `wtype`, where even an unmodified `F9` bind
did nothing until the option was turned on. `fw12-oskbd` sends real evdev codes
against the real keymap, so SUPER+K from the on-screen Framework key does what
it does from the physical one, and bind behaviour on the physical keyboard is
not altered to achieve it.

**AltGr and dead keys behave.** Because the keymap is the real one, `AltGr ' e`
gives `é` on screen exactly as it does on the hardware. This is what an
international layout actually needs, and it is not something a keyboard with a
synthesised keymap can fake.

**There is one copy of the layout.** Key legends are read back out of the
keymap at runtime, so `input:kb_layout` is the only place the layout is
configured. With `kb_layout = de` the same binary comes up with ü ö ä ß, y/z
swapped and Strg on the modifier caps.

**fcitx5 is untouched throughout.** The keys arrive as ordinary hardware
events, so fcitx5 sees everything typed on screen and compose sequences keep
working.

### The decisions that are not obvious

**The window is full-screen and masked down to the button.** A layer surface
covering the display, with `set_input_region` reduced to the button's 56×56
rectangle — verified in the protocol trace. Everything outside it passes
through to whatever is underneath.

**Overlay layer, not top.** The moment you most want a keyboard is inside a
fullscreen Moonlight session, and `top` sits below fullscreen windows. The
keyboard joined the knobs there for the menu's sake; see "Above the menu".

**The internal panel, by connector name.** Both the knobs and the keyboard
pick `eDP-*` and fall back to the first monitor only if there is none. GDK's
monitor 0 was the external display when docked, so the board sized itself
for 3440x1440 and mapped wherever focus happened to be.

**Position is stored as a fraction of each axis, not in pixels.** This machine
rotates; 1200×750 becomes 750×1200, and a pixel position would land off screen
or under the bar. It also keeps `x` and `y` as plain bindings, so nothing has
to reposition anything by hand after a rotation.

**The drag handler moves nothing itself.** It reports how far the finger has
travelled, and that is converted straight back into the same two fractions. A
rotation mid-drag therefore cannot desync the button from its stored position.

**It is round even under the square themes.** Everything else the shell draws
is attached to an edge and takes its shape from the theme to match its
neighbours. This floats in the middle of whatever you are using, with nothing
to match.
### Focus while folded

Folding sets `input:follow_mouse = 2`; unfolding puts it back. Without it,
keyboard focus detaches from the window being typed into for as long as a
finger rests on the keyboard: with `follow_mouse = 1` the surface under the
finger is a layer surface, so there is no window to focus and the current one is
simply dropped. Measured on the event socket — `activewindow` goes *empty* on
touch-down and returns on release (§11). A tap is too short to notice; a swipe
or a resting hand holds it, and everything typed in that time goes nowhere.

The change is made by Component A, not by the keyboard, because it has to be
reverted on unfold whether or not the keyboard was ever shown. It is held
only while the state file says `visible`, and the daemon is the one writer
of that file.

### The palm guard

A hand laid on the board breaks it two ways, and both were seen in one sitting
(§12). A modifier under the heel of the hand *locks*, because the second of two
imperfect contacts lands inside the double-tap window; everything after it
carries Ctrl or AltGr. And a key never comes up, because `GtkGestureClick`
tracks one touch sequence at a time — a second contact on the same key can end
the first without a `released`, so the key stays down and the compositor repeats
it.

Three contacts inside 150 ms is a hand and not fingers: drop them all, clear
every latch, and stay quiet until every contact has lifted. Separately, the
stuck-key watchdog does not time keys out — holding backspace is legitimate — it
asks GTK whether the held key's gesture is still active and frees the key only
when it is not. That is the actual fault condition, so nothing legitimate is cut
short.

### Edge gestures, without a compositor plugin

Hyprland's gesture system is trackpad-only; touchscreen gestures normally mean
the `hyprgrass` plugin, which is AUR-only and, being a compositor plugin, must
be rebuilt against every Hyprland release — the exact fragility this project set
out to avoid.

Three thin layer surfaces do the job as ordinary Wayland clients, so a Hyprland
update cannot break them, and they carry four gestures between them: swipe up
from the bottom for the keyboard, down on either side edge for `omarchy-menu`,
sideways from the left and right edges for the neighbouring workspace. All four
are configurable, and the strips exist only while folded.

Their placement solves itself with `exclusionMode: Normal` and
`exclusiveZone: 0` — reserve nothing, respect what others reserve. The
compositor puts each strip in whatever space the bar and the keyboard are not
using, so a strip can never sit on top of a key and the button can never be
dragged onto one. No geometry is duplicated and nothing has to be kept in step
(§13).

There is no top strip: the bar owns the real top edge and gets the gesture
first. The menu is on the side edges rather than the bottom because a downward
swipe starting on the bottom strip has only the strip's own height before the
finger leaves the display, so it could never reach the threshold.

### `SUPER + B`, bound in both modes

The keyboard's Framework key is a real Super, so the most useful thing the bind
does is the reverse of what it sounds like: dismissing the on-screen keyboard
*from* the on-screen keyboard. Two taps, no aiming for a 32 px strip. It is in
Component A's Lua rather than the plugin because that is where Hyprland binds
live; it calls the plugin over `omarchy-shell shell call`.

### The keyboard we wrote, and dropped

It was built — a C daemon acting as fcitx5's virtual-keyboard backend,
injecting through `zwp_virtual_keyboard_v1`, plus a Quickshell panel — and
every individual piece could be demonstrated: auto-show on focus, uppercase,
AltGr, dead keys, live layout following.

It was still bad to type on, and that is the only test that counts. Keys were
missed, the space bar worst of all; each fix found a real defect and the thing
underneath was still unpleasant.

The rendering went; the fcitx5 half came back. What `FINDINGS.md` 3.x learned
about the virtual-keyboard protocol is now inside `fw12-oskbd`, where the
keys are drawn by GTK and typed over `zwp_virtual_keyboard_v1` as before, and
only the show and hide come from fcitx5.

### What was tried instead, and why it is not here

`squeekboard` from `extra` got closest — it runs on Hyprland, coexists with
fcitx5, and a full six-row layout was written for it that does work. Two limits
ruled it out: it has **no AltGr** (`modifier: Mod5` is rejected outright, so an
international layout has to bolt the accents on beside the keyboard rather than
under a key), and it synthesises its own keymap, so every keybind on the
machine would have to be resolved by symbol instead of keycode to make the
on-screen ones fire. See §9.3.

`stevia`, the current Phosh keyboard, cannot run on Hyprland at all: it
requires eight Wayland globals and the eighth, `zphoc_device_state_v1`, exists
only in phoc. Seven of eight are present here. See §8.2. `plasma-keyboard`
binds `input-method-v1` / `input-panel-v1`, neither of which Hyprland
implements. `onboard` is X11. `wvkbd` and `hyprkbd` are AUR-only.

---

## System integration

Two one-shot root pieces, addressing the non-deterministic probe race (§1.3):

1. `/etc/mkinitcpio.conf.d/fw12-tablet.conf` → `MODULES+=(pinctrl_tigerlake)`
   so the pin controller is up before `soc_button_array` probes. **The actual
   fix.**
2. A systemd system unit binding `INT33D3:*` at boot if still unbound, plus a
   `system-sleep` hook re-binding after resume. Belt and braces.

Neither is needed at runtime by Component A, which degrades gracefully: with no
switch device the binds simply never fire, and the module stays in laptop mode.

---
## Known limitations, stated up front

- **Not every text field asks for the keyboard.** fcitx5 hears about a field
  only from clients that speak `text-input-v3` or its own Qt and GTK modules.
  The Omarchy menu is handled on our side; a terminal that never activates
  an input method is not, and a Qt field is unverified (§17.5). The knobs
  and `SUPER + B` are there for those.
- **A hardware keyboard turns auto-show off** until the next knob tap
  (§17.8). fcitx5's design, and the right one for a Bluetooth keyboard.
- **The bar is hard to hit by touch** (§5.4) — 6.9 mm targets, and a missed tap
  reaching the wallpaper opens the picker on double-click. Out of scope here by
  decision; worth reporting upstream.
- **One boot in N has no switch** until the initramfs fix is applied. Applied on
  this machine, after it cost a boot.
- **Cosmetic, on rotation:** the wallpaper blanks for a moment, and in portrait
  it is cropped to roughly a third of the image. Both are Omarchy's own
  background plugin (`asynchronous: true` on a transparent window, and
  `PreserveAspectCrop` on a 16:9 wallpaper in a 750x1200 frame), not ours.
  Diagnosed, left alone by decision.

---

## Where this stands

**Working on hardware, verified with a finger:**

| | |
|---|---|
| Component A | fold in and out, all four orientations, `SUPER + R` lock, `hyprctl reload` idempotency, suspend/resume |
| System fix | installed; the probe race has not recurred |
| Keyboard | types, keybinds fire, AltGr and dead keys work, layout follows `input:kb_layout`, geometry matches the real board and re-lays out on rotation |
| Daemon | resident while folded, signal show/hide, one process through 20 rapid toggles, gone on unfold (§16) — by measurement, not yet by hand |
| Auto-show | GTK4 entry and foot show and hide it; the menu shows it; our own keys do not dismiss it; fcitx5 ends on `classicui` (§17) — by measurement, not yet by hand |
| Menu | keyboard listed above `omarchy-menu` while both are mapped, knob above the keyboard (§15.5) — by measurement, not yet by hand |
| Button | tap toggles, drag moves it, position survives a rotation and a shell restart |
| Swipes | all four gestures; strips place themselves around the bar and the keyboard |
| Focus | survives a resting hand while folded |
| Palm guard | a hand on the board no longer locks a modifier or sticks a key |
| Install | `omarchy plugin add` from a clone, then `install.sh`, both from a clone and from the plugin directory |
| Layouts | `de` in daily use; `us`/`intl` checked from a screenshot of the running board |

**Packaging.** There is no PKGBUILD and there should not be one. Omarchy
installs a third-party plugin by cloning its git repo into
`~/.config/omarchy/plugins/<id>/`, so the manifest sits at the repo root and
`omarchy plugin add` is the install path. The parts a package manager would
own — one binary into `~/.local/bin`, one Lua file into `~/.config/hypr` — are
per-user, need no root, and are done by `install.sh`, which is idempotent and
doubles as the upgrade step. A PKGBUILD would add a second, partly overlapping
mechanism for one binary. There is also no marketplace to submit to: Omarchy 4
has none, and a git URL is the whole distribution story.

**Left to do:**

1. **A second machine.** Every measurement here is from one Framework 12. The
   accelerometer axis convention is the part most likely to differ — it depends
   on how the panel and its sensor are mounted — so it is now a single table at
   the top of the Lua with a comment saying which pair to swap for each of the
   three ways it can come out wrong. That reduces the cost of being wrong; it
   does not verify anything.
2. **The physical US International keyboard**, when it arrives — to confirm the
   on-screen board and the real one agree key for key, which a screenshot
   cannot show.
3. **Hands on the machine** for everything in §16 and §17: the fold is
   simulated there, and the keys came from a script. `TESTING.md` has the
   list.
4. **The lock screen.** Under `ext-session-lock` only lock surfaces render
   or receive input, so the daemon's surface cannot appear there by
   protocol. The keypad for it is QML inside a clone of `omarchy.lock`, on
   the `phase4-lock` branch, with its own README on why it cannot ship in
   this plugin.

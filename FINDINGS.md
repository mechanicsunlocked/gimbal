# FINDINGS — Phase 0

Framework Laptop 12 tablet-mode support for Omarchy 4 "Quattro".
All facts below were measured on this machine unless marked otherwise.

Date: 2026-08-15. Host: `fw12-omarchy-quattro`.

---

## 0. Platform baseline

| Item | Value |
|---|---|
| Vendor / product | Framework / Laptop 12 (13th Gen Intel Core) |
| Board / BIOS | FRAPMACP05 / 03.07 |
| CPU | 13th Gen Intel Core i5-1334U |
| OS | Omarchy 4.0.0 (`ID=omarchy`, `ID_LIKE=arch`) |
| Kernel | 7.1.8-arch1-3 |
| Hyprland | 0.56.2 (commit efb5099, 2026-08-05) |
| Quickshell | 0.3.0.r20.g28771c7 |
| Session | Wayland, `XDG_CURRENT_DESKTOP=Hyprland` |
| `$OMARCHY_PATH` | `/usr/share/omarchy` |

Not installed: `iio-sensor-proxy`, `squeekboard`, `qt6-virtualkeyboard`,
`wayland-utils`, `evtest`, `rust`/`rustup`. All are in the `extra` repo except
`wvkbd`, which is not in the repos at all.

Toolchain present: `gcc`, `cc`, `pkg-config`, `make`, `wayland-scanner`,
`wayland-client` 1.26.0. **No Rust toolchain is installed.**

---

## 1. Tablet-mode detection — RESOLVED: the switch works, but the race is real

> **Status update after reboot (2026-08-15 14:34).** On the *first* boot the
> switch was absent. After a plain reboot with **no configuration change**, it
> came up bound and fully working. Everything in §1.1–1.2 below describes the
> failing boot and is retained because it is the failure mode we must defend
> against; §1.4 is the working state.

### 1.4 CONFIRMED WORKING — the switch, its stable path, and its thresholds

Second boot, `soc_button_array` won the race:

```
N: Name="gpio-keys"
S: Sysfs=/devices/platform/INT33D3:00/gpio-keys.1.auto/input/input7
H: Handlers=event5
B: EV=21     B: SW=2         <- bit 1 only = SW_TABLET_MODE, nothing else
```

**Stable path** (the brief's step-1 deliverable):

```
/dev/input/by-path/platform-gpio-keys.1.auto-event -> ../event5
```

Live `evtest` capture of a real fold and unfold:

```
Event: time 1786797750.287562, type 5 (EV_SW), code 1 (SW_TABLET_MODE), value 1
Event: time 1786797761.190068, type 5 (EV_SW), code 1 (SW_TABLET_MODE), value 0
```

Clean, debounced, one event per transition. No chatter.

**Measured firmware hysteresis**, from a 1 Hz log of switch state against hinge
angle:

| | angle |
|---|---|
| last `laptop` sample before entering | 220° |
| first `TABLET` sample | 257° |
| last `TABLET` sample before leaving | 170° |
| first `laptop` sample after | 106° |

So enter is somewhere in 220–257° and exit in 106–170°. The firmware owns these
thresholds; they are not tunable. That is *good* — it is real hysteresis, which
is exactly what an angle-based state machine would have had to invent.

### 1.5 The `500` sentinel clusters exactly where tablet detection matters

From the same capture, during the fold through full 360°:

```
14 sw=TABLET angle=346
15 sw=TABLET angle=500     <- sentinel
16 sw=TABLET angle=500
17 sw=TABLET angle=500
18 sw=TABLET angle=360
```

`500` is not a rare motion artifact — it appears **reliably near full fold**,
where the two accelerometers are close to antiparallel and the EC cannot solve
the angle. That is precisely the posture in which we most need to know we are in
tablet mode.

**This settles the detection design: use `SW_TABLET_MODE` as the source of
truth, not the hinge angle.** The switch has firmware hysteresis, fires clean
single events, is immune to the sentinel, and is what GNOME and Windows gate
on. The angle's only remaining role is optional corroboration and diagnostics.

### 1.6 libinput already disables the keyboard and touchpad — we get that free

Strings in `/usr/lib/libinput.so.10`:

```
tablet-mode: paired %s<->%s
tablet-mode: activated for %s<->%s
tablet-mode: suspending device
tablet-mode: suspending touchpad
tablet-mode: resuming device
tablet-mode: resume touchpad
device is an unreliable tablet mode switch, filtering events.
```

libinput **pairs** the tablet-mode switch with the internal keyboard and
touchpad and suspends them while the switch is on, resuming on exit. This is
built-in behaviour, not something a compositor or client arranges.

**Consequence:** the testing-checklist item *"flip to tablet → physical
keyboard off"* is satisfied by the kernel/libinput stack with no code from us.
`fw12d` must **not** try to disable input devices itself — doing so would
double up on libinput and risk leaving devices suspended when our daemon dies.

Note also the last string: libinput carries a quirk for switches it considers
unreliable, in which case it filters their events. If tablet mode ever appears
dead on a machine where the switch is bound and `evtest` shows transitions,
that quirk is the thing to check
(`/usr/share/libinput/*.quirks`, `LIBINPUT_MODEL_*`).

### 1.7 Hyprland can bind to switch transitions

`strings /usr/bin/Hyprland` shows `switch:`, `switch:on:`, `switch:off:` — the
`bindl = ,switch:on:<device>, ...` binding form. This is an alternative trigger
path and a useful escape hatch, but `fw12d` reading evdev directly is preferred:
it gets the *initial* state via `EVIOCGSW` (a binding only ever sees edges), and
it does not depend on the user's Hyprland config being wired up.

### 1.1 On the first boot there was no `SW_TABLET_MODE` device

Dumping the `EV_SW` capability bitmask of every input device:

```
input0   sw=1     Lid Switch                   -> SW_LID only (bit 0)
input21  sw=4     HDA Intel PCH Headphone      -> jack sense
input22  sw=140   HDA Intel PCH HDMI/DP        -> jack sense
input23  sw=140   ...
```

`SW_TABLET_MODE` is bit 1 (`0x2`). **No device sets it.** `evtest` /
`libinput debug-events` would therefore have nothing to report, and step 1 of
the brief as written cannot be performed.

`intel_vbtn` and `intel_hid` are not loaded and have no ACPI device here — the
FW12 does not use that path.

### 1.2 Why: the `soc_button_array` probe race is live on this install

```
/sys/bus/platform/devices/INT33D3:00          EXISTS
/sys/bus/platform/drivers/soc_button_array/   loaded, ZERO devices bound
pinctrl_tigerlake                             loaded (3 users)
```

The ACPI device `INT33D3` — the gpio-keys node that carries `SW_TABLET_MODE` —
is present, and its driver is loaded, but **the two are not bound**. This is
exactly the boot probe race Framework's knowledgebase documents: if
`soc_button_array` probes before `pinctrl_tigerlake` has registered the pin
controller, the probe fails and the device is left unbound with no retry.

### 1.3 The race is NON-DETERMINISTIC — this is the key result

| | boot 1 (13:41) | boot 2 (14:34) |
|---|---|---|
| `INT33D3:00` present | yes | yes |
| bound to `soc_button_array` | **NO** | **YES** |
| `SW_TABLET_MODE` device | none | `gpio-keys`, event5 |
| `pinctrl_tigerlake` users | 3 | 5 |

**Same kernel, same initramfs, same config, no changes in between.** The switch
simply lost the race on one boot and won on the next.

This is the single most important robustness finding in Phase 0. It means:

- Any design that assumes the switch exists at startup will break on roughly
  some fraction of boots, silently, with no tablet mode at all.
- The bind helper is **not** optional hardening — it is required for the
  feature to work reliably.
- Putting `pinctrl_tigerlake` in `MODULES=()` in mkinitcpio is the actual fix
  (load the pin controller from the initramfs so it is always up first); the
  bind service is the belt-and-braces for boots and resumes where it still
  loses.
- fw12tab's `system/` directory was solving a real, reproducible problem, and
  its approach (initramfs module + boot unit + `system-sleep` post hook) is
  correct. Neither is currently applied on this install:
  `MODULES=()` is empty and there is no bind unit.

Binding by hand works and requires root:

```
echo INT33D3:00 > /sys/bus/platform/drivers/soc_button_array/bind
```

### 1.3 Omarchy does nothing with tablet mode

Grepping all of `$OMARCHY_PATH` for tablet / rotate / accel / OSK /
input-method terms returns only unrelated hits (`accel_profile` in an input
config comment, a `transform:` comment for portrait monitors, and CSS/QML
`rotation` properties on widgets).

**There is no physical-keyboard auto-disable on tablet mode in Omarchy.** The
brief's claim that this "already proves the switch works" does not hold — there
is no such feature, and consequently nothing for us to fight or coordinate
with. We own this behaviour entirely.

---

## 2. Sensors — better than the brief assumed

The FW12 does **not** expose a generic `iio-buffer-accel` / HID-sensor
accelerometer. It exposes the Framework EC sensor stack (ChromeOS-EC derived):

```
iio:device0   cros-ec-lid-angle    in_angl_raw
iio:device1   cros-ec-accel        label=accel-display   scale=0.000598550
iio:device2   cros-ec-accel        label=accel-base      scale=0.000598550
```

All three live under `platform/FRMWC004:00/cros-ec-dev.1.auto/cros-ec-sensorhub.2.auto/`.
`/dev/cros_ec` exists (root-only, mode 0600).

Live readings confirm the sensors work: `in_angl_raw` was observed changing
from `142` to `99` as the lid was moved during this session, and
`accel-display` reports plausible three-axis values.

Consequences:

- There are **two** accelerometers. Rotation must follow `accel-display`
  (the lid), not `accel-base`. A naive "first accel" pick is a 50/50 coin flip.
- The **hinge angle is directly readable**, which most convertibles do not
  offer. It is a viable tablet-mode signal on its own and a useful cross-check
  against the switch.
- The brief's note about commenting out an `iio-buffer-accel` udev rule is not
  applicable — that rule targets a different driver family. There is no such
  packaging problem here.

### 2.1 CRITICAL: IIO device numbering is not stable across boots

Comparing the two boots directly:

| identifier | boot 1 | boot 2 |
|---|---|---|
| lid-angle | `iio:device0` | `iio:device1` |
| accel-display | `iio:device1` | `iio:device0` |
| accel-base | `iio:device2` | `iio:device2` |
| cros-ec-dev | `cros-ec-dev.1.auto` | `cros-ec-dev.2.auto` |
| sensorhub | `.2.auto` | `.3.auto` |
| **`cros-ec-accel.11.auto`** | **accel-base** | **accel-display** |
| lid-angle platform | `cros-ec-lid-angle.12.auto` | `cros-ec-lid-angle.13.auto` |

Note the bolded row. The platform path `cros-ec-accel.11.auto` referred to the
**base** accelerometer on one boot and the **display** accelerometer on the
next. Anything that pins an `iio:deviceN` index or a `cros-ec-accel.N.auto`
path will, on some boots, silently read the keyboard half of the laptop instead
of the screen — producing rotation that is wrong in a way that looks
intermittent and hardware-ish rather than like a bug.

**The only stable identifiers are:**

- `name` — `cros-ec-lid-angle` / `cros-ec-accel`
- `label` — `accel-display` / `accel-base`
- `id` — `0` (display) / `1` (base)

Every read must resolve through `label`/`name` at open time. This is also a
plausible alternative explanation for the original "hinge stopped working after
resume" report: not a dead sensor, but a renumbered one.

### 2.2 `iio-sensor-proxy` works, but is the wrong dependency here

Installed and started (`iio-sensor-proxy 3.9-1`). It does report orientation:

```
=== Has accelerometer (orientation: normal, tilt: vertical)
net.hadess.SensorProxy AccelerometerOrientation = "normal"
```

But its own log shows the buffered path failing on this hardware:

```
Could not find trigger name associated with .../cros-ec-accel.11.auto/iio:device0
Buffer '/dev/iio:device0' did not have data within 0.5s
```

The cros-ec accelerometer exposes no IIO trigger, so the proxy's preferred
triggered-buffer read fails and it falls back to polling. Worse, it selected
**`iio:device0` by index** — which happened to be `accel-display` on this boot,
but per §2.1 that is luck, not logic.

Against that, reading the sensor ourselves costs three `open`/`read`/`close`
calls on a label-resolved path, with no DBus, no daemon, and no ambiguity about
which sensor we got.

### 2.2a The proxy only polls while a client holds a claim

An early test appeared to show the proxy frozen at `normal` through a full
four-orientation rotation. **That test was invalid.** `iio-sensor-proxy` does
not read the sensor until a client calls `ClaimAccelerometer`; a bare
`busctl get-property` does not claim it, so the property was simply stale.

Re-run with `monitor-sensor` held open for the whole capture (which does
claim), the proxy tracks correctly:

```
Accelerometer orientation changed: right-up
Accelerometer orientation changed: normal
Accelerometer orientation changed: right-up
Accelerometer orientation changed: bottom-up
Accelerometer orientation changed: left-up
Accelerometer orientation changed: normal
```

**Both paths work.** The proxy is a legitimate option, not a broken one. It
does lag the raw sensor by roughly one sample (~1 s) — at sample 50 the raw
data had already reached `bottom-up` while the proxy still reported `right-up`,
catching up at 51.

### 2.2b Empirically pinned axis convention — my first guess was inverted

The side-by-side comparison disagreed on 40 of 90 samples, and the pattern was
systematic: agreement on the Y axis (`normal` / `bottom-up`), consistent
disagreement on the X axis.

```
sample 30   x=+13600   proxy=right-up   naive=left-up
sample 70   x=-16784   proxy=left-up    naive=right-up
```

My initial classifier had the X sign backwards. The correct convention for
`accel-display` on this unit, matching `iio-sensor-proxy`:

| condition | orientation | Hyprland transform |
|---|---|---|
| \|y\| dominant, y > 0 | `normal` | 0 |
| \|x\| dominant, **x > 0** | `right-up` | 3 |
| \|y\| dominant, y < 0 | `bottom-up` | 2 |
| \|x\| dominant, **x < 0** | `left-up` | 1 |
| \|z\| dominant | flat — hold previous | — |

This is exactly the trap fw12tab documents in its README: *"Rotation comes out
mirrored? Swap the `1` and `3` in `_transform()` (panel mounting differs between
units)."* It is a real hazard, it is easy to get backwards, and it is not
guessable from first principles — it has to be measured. It is now measured on
**this** unit.

### 2.2c Recommendation

**Read `in_accel_{x,y,z}_raw` directly from the `accel-display`-labelled
device; do not depend on `iio-sensor-proxy`.**

The case is now narrower than it first appeared, since the proxy does work:

- no extra runtime dependency, systemd unit, or DBus round trip
- no claim/release lifecycle to manage, and no risk of reading a stale property
  because nothing currently holds a claim
- ~1 s lower latency
- the proxy selects its accelerometer by index (§2.1), which is not stable
  across boots; resolving by `label` ourselves is unambiguous
- it is genuinely less code than a correct DBus client would be

The proxy remains valuable as the **cross-check that established the axis
convention above**, and is worth keeping installed for diagnostics. This
diverges from the brief's proposed architecture deliberately, on measured
grounds.

### 2.3 Flat means "no orientation" — the state machine must hold, not guess

During the tablet-fold capture the screen ended up roughly horizontal and the
readings were dominated by Z:

```
12 sw=TABLET angle=257 disp=(944,-672,16816)     <- z ≈ +1 g, screen face-up
16 sw=TABLET angle=500 disp=(5744,2112,14928)
```

With gravity along Z, X and Y carry no orientation information and
`AccelerometerOrientation` stayed `normal` throughout. This is correct
behaviour, not a fault — but it means the rotation logic must detect the flat
case (|Z| dominant, X and Y both small) and **hold the last known orientation**
rather than snapping to a default. A naive `atan2(x, y)` on near-zero inputs
will jitter wildly.

**VERIFIED.** A second capture with the tablet held upright and rotated through
all four positions produced clean, unambiguous readings on the raw sensor:

```
normal      x=   784  y= 13856  z= 8832
right-up    x= 13600  y=  7424  z=-4224      (|x| dominant, positive)
bottom-up   x= -1056  y=-17024  z=-1040
left-up     x=-16784  y= -4448  z= -992      (|x| dominant, negative)
```

All four orientations are detected reliably, and the flat case correctly falls
through to "hold previous". Magnitudes sit near ±16384 (≈1 g at
`scale=0.000598550`), so a simple dominant-axis test with a dead zone is
sufficient — no filtering or trigonometry needed.

---

## 3. Wayland protocols — the showstopper check passed

`wayland-info` is not installed, so I compiled a small `wayland-client` C
program and enumerated the registry of the **running** compositor directly.
Relevant globals advertised:

```
zwp_input_method_manager_v2        v1
zwp_virtual_keyboard_manager_v1    v1
zwp_text_input_manager_v3          v1
zwp_text_input_manager_v1          v1
zwlr_layer_shell_v1                v5
zwp_tablet_manager_v2              v1
zwlr_output_manager_v1             v4
```

Everything the design needs is present.

### Does the shell own the input-method slot? No — but **fcitx5 does**

`omarchy-shell` is not the problem. The `quickshell` binary contains no
`zwp_input_method_manager_v2`, `zwp_input_method_v2`,
`zwp_virtual_keyboard_manager_v1`, or `zwp_text_input_manager_v3` symbols — the
only one of these it contains is `zwlr_layer_shell_v1`. The shell binds
layer-shell and nothing else.

**The seat's input-method slot is taken by fcitx5, which Omarchy 4 ships and
runs by default.**

```
$ pgrep -a fcitx5
1304 /usr/bin/fcitx5 --disable notificationitem

$ systemctl --user list-units --state=running | grep fcitx
omarchy-fcitx5.service   loaded active running   Fcitx5 input method (XCompose sequences)
```

- `fcitx5`, `fcitx5-gtk`, `fcitx5-qt` are in `install/omarchy-base.packages`.
- `$OMARCHY_PATH/default/systemd/user/omarchy-fcitx5.service` is
  `WantedBy=graphical-session.target`. Its stated purpose: *"fcitx5 turns the
  CapsLock compose sequences in `~/.XCompose` into text for Wayland clients."*
- `$OMARCHY_PATH/default/environment.d/10-omarchy-fcitx.conf` exports
  `INPUT_METHOD=fcitx`, `QT_IM_MODULE=fcitx`, `XMODIFIERS=@im=fcitx`,
  `SDL_IM_MODULE=fcitx`. All four are live in this session.
- `/usr/lib/fcitx5/libwaylandim.so` binds `zwp_input_method_manager_v2`,
  `zwp_input_method_v2`, **and** `zwp_virtual_keyboard_manager_v1`.

And it is demonstrably *connected*, not merely installed — `hyprctl devices`
lists a virtual keyboard fcitx5 created on the seat:

```
hl-virtual-keyboard-fcitx5   |layout: de |active: German
```

So the brief's showstopper scenario is real, but the culprit is fcitx5 rather
than the shell. A daemon that tries to bind `get_input_method` will be told
`unavailable`.

### This is good news, not bad

Displacing fcitx5 would cost the user their `~/.XCompose` CapsLock compose
sequences — which for a Luxembourg user typing `é ë ä à` is likely the main way
they produce accented characters today. That is a regression we should not
ship.

The better path is to **integrate with fcitx5 instead of evicting it**. fcitx5
already is the input method, so it already knows exactly when a text field is
focused — which is the hard half of auto-show/hide. It exposes a virtual
keyboard interface on the session bus:

```
$ busctl --user introspect org.fcitx.Fcitx5 /virtualkeyboard
org.fcitx.Fcitx.VirtualKeyboard1   interface
.HideVirtualKeyboard               method  -  -
.ShowVirtualKeyboard               method  -  -
.ToggleVirtualKeyboard             method  -  -
```

plus `org.fcitx.Fcitx.Controller1` on `/controller` with
`AvailableKeyboardLayouts`, `CurrentInputMethod`, `CurrentInputMethodInfo`, and
`SetCurrentIM` — i.e. a ready-made layout-following surface that is more
authoritative than scraping Hyprland's socket2.

`/usr/lib/fcitx5/libkimpanel.so` is also present; kimpanel is fcitx5's
DBus protocol for driving an *external* panel UI, and is the standard way a
separate process is told about input-context focus and state.

### 3.1 RESOLVED — fcitx5's virtual-keyboard backend protocol

fcitx5 ships a `virtualkeyboard` addon, present and known to the running
instance:

```
/usr/share/fcitx5/addon/virtualkeyboard.conf
  Library=libvirtualkeyboard   Category=UI   UIType=OnScreenKeyboard
  OnDemand=True                Dependencies: dbus, core
```

It is `OnDemand`, so by default it is not the active UI (`CurrentUI` is
`classicui`) and its objects are not exported. **Two conditions together
activate it**, established experimentally:

1. a client owns the bus name `org.fcitx.Fcitx5.VirtualKeyboard`, and
2. something calls `ShowVirtualKeyboard`.

Holding the name alone does nothing; calling `ShowVirtualKeyboard` alone does
nothing. With both, `CurrentUI` flips to `virtualkeyboard`. Verified with a
small GDBus probe (`tools/vkprobe.c`) that owns the name, plus a `busctl` call:

```
=== calling ShowVirtualKeyboard while name is held ===
=== CurrentUI now ===
s "virtualkeyboard"
```

In that mode fcitx5 exports the full contract on `/virtualkeyboard`:

```
org.fcitx.Fcitx.VirtualKeyboard1
  .ShowVirtualKeyboard      ()
  .HideVirtualKeyboard      ()
  .ToggleVirtualKeyboard    ()

org.fcitx.Fcitx5.VirtualKeyboardBackend1
  .ProcessKeyEvent                  (uuubu)
  .ProcessVisibilityEvent           (b)
  .SelectCandidate                  (i)
  .NextPage                         ()
  .PrevPage                         ()
  .SetVirtualKeyboardFunctionMode   (u)
```

**`ProcessKeyEvent(uuubu)` is the injection path.** Our keyboard calls it and
fcitx5 does the rest — keymap, layout, AltGr, dead keys, `~/.XCompose`
sequences, candidates. The signature is (keysym, keycode, state, isRelease,
time).

The reciprocal half is that the client exports
`/org/fcitx/virtualkeyboard/impanel` under the name it owns; fcitx5 calls into
that to drive show/hide and candidate updates. That object is *not* on
`org.fcitx.Fcitx5` — confirmed by introspection failing there in every state —
because it belongs to the client, which is us.

### 3.1a The client-side contract, captured empirically

Method *names* are visible in `libvirtualkeyboard.so`, but their **signatures
are not**, and a guessed signature fails silently. So `tools/vkspy.c` owns the
bus name, installs an sd-bus message filter that logs every incoming call with
its member and signature, and replies generically. Captured live while focusing
and unfocusing text fields:

**fcitx5 → us**, on `/org/fcitx/virtualkeyboard/impanel`, interface
`org.fcitx.Fcitx5.VirtualKeyboard1`:

| method | signature | meaning |
|---|---|---|
| `ShowVirtualKeyboard` | — | show the keyboard |
| `HideVirtualKeyboard` | — | hide it |
| `NotifyIMActivated` | `s` | input method name, e.g. `"keyboard-us"` |
| `NotifyIMDeactivated` | `s` | same |
| `UpdatePreeditArea` | `s` | preedit text |
| `UpdatePreeditCaret` | `i` | caret index; `-1` = none |
| `UpdateCandidateArea` | `asbbii` | candidates, hasPrev, hasNext, page, cursor |
| `NotifyIMListChanged` | — | present in the `.so`, not observed |

**us → fcitx5**, on `/virtualkeyboard`:

| interface | method | signature |
|---|---|---|
| `org.fcitx.Fcitx5.VirtualKeyboardBackend1` | `ProcessKeyEvent` | `uuubu` |
| | `ProcessVisibilityEvent` | `b` |
| | `SelectCandidate` | `i` |
| | `NextPage` / `PrevPage` | — |
| | `SetVirtualKeyboardFunctionMode` | `u` |
| `org.fcitx.Fcitx.VirtualKeyboard1` | `Show`/`Hide`/`ToggleVirtualKeyboard` | — |

### 3.1b Auto-show is confirmed working

The observed pattern on focusing a text field is:

```
NotifyIMActivated("keyboard-us")   ->  ShowVirtualKeyboard()
NotifyIMDeactivated("keyboard-us") ->  HideVirtualKeyboard()
```

**This is the auto-show/hide source the brief asked for, and it is protocol
truth rather than a focus heuristic.** No window-class matching, no polling, no
guessing.

Two practical notes for the implementation:

- **Show/hide churns rapidly.** The capture shows many
  activate/show/deactivate/hide cycles as focus moves between windows and
  fields. The UI must tolerate this without flicker — debounce the hide, or
  animate in a way that survives a hide immediately followed by a show.
- `UpdatePreeditArea`/`UpdatePreeditCaret` arrive with empty/`-1` values for a
  plain Latin layout. They matter only for composing input methods, so a first
  release can accept and ignore them, but it must still **reply** to them.

### 3.1c Injection: fcitx5 cannot type uppercase on Wayland

Four rounds of measurement against a GTK4 entry that logs what it receives
(`tools/typetarget.c`, so the result is machine-read rather than eyeballed).
`ProcessKeyEvent(keysym, keycode, states, isRelease, time)`:

| sent | appeared | conclusion |
|---|---|---|
| keysym `z` + keycode of `a` | `a` | **keycode wins, keysym ignored** |
| keysym `A` + keycode `a` + states=shift | `a` | **states mask ignored** |
| Shift_L held as real key events across `a` | `a` | **held modifier ignored** |
| CapsLock toggled, then `a` | `a` | **CapsLock ignored** |
| KEY_SEMICOLON / KEY_Y / KEY_Z | `ö` `z` `y` | **applies the system layout (de), not fcitx5's own `keyboard-us`** |
| keysym `ä` alone, keycode 0 | `ä` | keysym-only works for some characters |
| keysym `€` alone | `€` | likewise |
| keysym `A`, `Q`, `Ä` alone | nothing | **no uppercase, accented or not** |

So through fcitx5 we can type lowercase and a few special characters, and
**cannot type a single capital letter**.

This is a known upstream limitation, not a mistake in our usage:
[fcitx5-osk](https://github.com/fortime/fcitx5-osk) documents that *"Fcitx5
doesn't forward modifier events correctly on Wayland, which prevents uppercase
letters from being input"*, and works around it with a separate evdev keyboard
purely for modifiers.

One good result survives: fcitx5 derives characters from the **system** layout,
so layout-following is free and needs no work from us.

### 3.1d Revised injection design: use each mechanism for what it does well

| concern | mechanism | why |
|---|---|---|
| auto-show / auto-hide | fcitx5 DBus `ShowVirtualKeyboard` / `HideVirtualKeyboard` | protocol truth, already proven working |
| layout / IM name | fcitx5 `NotifyIMActivated` | already delivered |
| **key injection** | **`zwp_virtual_keyboard_v1`** | full modifier support, and already proven on this exact hardware |

`zwp_virtual_keyboard_v1` is advertised by Hyprland (§3) and is what fw12tab's
`oskbd.c` already uses: it uploads the system xkb keymap with
`zwp_virtual_keyboard_v1.keymap` and then sends evdev keycodes plus an explicit
modifier mask via `zwp_virtual_keyboard_v1.modifiers`. Shift, AltGr, dead keys
and compose all work because the **compositor** resolves them, and fcitx5 --
still the input method on the seat -- continues to see the resulting keys, so
`~/.XCompose` keeps working.

Unlike input-method-v2, the protocol permits **multiple** virtual keyboards per
seat, so ours coexists with the `hl-virtual-keyboard-fcitx5` fcitx5 already
creates. fw12tab ran exactly this arrangement.

**Cost of the correction:** the claim in ARCHITECTURE.md that this design needs
no Wayland protocol client is now wrong. The keyboard daemon needs a small
`wayland-client` + `libxkbcommon` component after all. That is still far less
than the original brief's design, which additionally wanted input-method-v2
ownership, and ~200 lines of it already exist and are proven in fw12tab.

### 3.1e Injection over virtual-keyboard-v1 works, with one silent trap

The revised design types correctly. Self-test on a `de` layout, read back from
a GTK4 entry rather than eyeballed:

```
sent:      Shift+KEY_H   KEY_A   KEY_SEMICOLON   AltGr+KEY_E
received:  H             a       ö               €
hex: 48 61 c3 b6 e2 82 ac
```

All four are things fcitx5's `ProcessKeyEvent` could not produce, uppercase
most of all. The keymap also drives the legends, and they agreed: `KEY_H`
shift level reported `H`, `KEY_SEMICOLON` base `ö`, `KEY_E` AltGr `€`. Since
labels and keystrokes come from the same compiled keymap, they cannot drift.

Hyprland registers the keyboard as `hl-virtual-keyboard-fw12-oskd`, layout
`de`, alongside the physical keyboard.

**The trap: `wl_display_flush` after the keymap upload is not enough.** With
only a flush, everything appears to work -- the keyboard is created, the
compositor lists it with the right layout, every request returns success -- and
**not one keystroke arrives**. There is no error on any side.

`wl_display_roundtrip` after `zwp_virtual_keyboard_v1.keymap` fixes it: the
compositor has to have processed the keymap before it will accept keys.

Isolated by reverting each change separately: with the round-trip in place a
naive incrementing counter for the event `time` works fine, so **the
round-trip was the fix and the timestamp was not**. A real monotonic
millisecond timestamp is used regardless, being both more correct and free.

An initial `modifiers(0,0,0,0)` is also sent after the keymap so the compositor
starts from a known state.

### 3.1f Ghostty works -- the brief's expected limitation does not apply

The brief flags Ghostty as the known weak spot, to be reported plainly if it
never activates the input method. Measured, it does both halves:

**Auto-show fires.** With Ghostty focused (`com.mitchellh.ghostty`), fcitx5
calls `NotifyIMActivated` and `ShowVirtualKeyboard` exactly as it does for GTK.

**Injected keys arrive.** Typing `KEY_H KEY_A KEY_S KEY_ENTER` into a Ghostty
running `read -r line` captured `has`.

That makes sense in hindsight: virtual-keyboard-v1 events go through the
compositor and reach the focused surface as ordinary keyboard input, so an
application cannot really opt out of them the way it can opt out of
text-input-v3.

**A false negative worth recording.** A first attempt captured 0 bytes and
looked like a real Ghostty limitation. The fault was the test harness --
`stty raw -echo` plus `dd`/`cat` inside `ghostty -e` -- not Ghostty. Re-testing
through an ordinary shell `read` showed the keys arriving normally. The control
that caught it was checking that the same injection still reached the GTK
target in the same run.

### 3.1g Layout: `us(intl)` verified, but only read at startup

`--dump` prints every key at all four shift levels. Switching Hyprland to
`us(intl)` and re-running required no code change:

```
        base   shift  altgr  sh+agr
E       e      E      é      É
Q       q      Q      ä      Ä
Y       y      Y      ü      Ü
A       a      A      á      Á
APOSTR  ´      ¨      '      "        <- dead acute / dead diaeresis
```

So the user's planned move to `us(intl)` gives the whole Luxembourg accent set
through AltGr plus two dead keys, with no custom layout and no `lb` needed.
Under `de` the same dump is correct QWERTZ with `ü ö ä ß`, AltGr `€`, and ISO
`< > |`.

**RESOLVED.** The daemon now subscribes to Hyprland's `.socket2.sock` and
reacts to `activelayout` (and `configreloaded`, since a layout can change that
way without an activelayout event). Verified live:

```
de -> us(intl):  layout changed to 'us' variant intl (ISO body)
us(intl) -> de:  layout changed to 'de' (ISO body)
```

Two details that matter:

- Hyprland emits **one `activelayout` event per input device** -- six or more
  per actual change. The event also carries a display name ("German", "English
  (US, intl., with dead keys)"), not an xkb code, so it is used only as a
  trigger and the authoritative value is re-queried from `input:kb_layout`.
  `vkbd_set_layout` compares against the current names and returns early when
  unchanged, so six events produce one keymap rebuild.
- **Our own virtual keyboard emits `activelayout` events too** when we
  re-upload the keymap (`hl-virtual-keyboard-fw12-oskd,German`). That is a
  feedback loop waiting to happen, and the same dedup is what breaks it.

A keymap that fails to compile keeps the previous one rather than leaving the
daemon with none: a bad layout string degrades to stale legends, not to "cannot
type".

### 3.1h Two things fcitx5 requires that are easy to miss

Both were found by the keyboard silently not appearing, with no error anywhere.

**`ProcessVisibilityEvent(true)` is mandatory, not optional.** Owning the bus
name and calling `ShowVirtualKeyboard` is enough to flip `CurrentUI` to
`virtualkeyboard` -- but if the keyboard never reports itself visible, fcitx5
concludes there is none and quietly reverts to `classicui`. We keep the bus
name and simply stop receiving show/hide. Nothing looks wrong from our side.

Confirmed it is a revert and not a crash: fcitx5's pid was unchanged across it
(1398 before and after).

**Correction: `hl-virtual-keyboard-fcitx5` on the seat is not a tell.** An
earlier version of this section offered it as one. It is wrong. That device was
present on the seat at the same moment the keyboard was up, working, and
receiving show events. Ignore it.

**fcitx5 restarting also drops the mode**, while we keep the name it watches.
A new instance has no idea we are its keyboard. The daemon now watches
`NameOwnerChanged` for `org.fcitx.Fcitx5` and re-asserts.

### 3.1j What actually makes fcitx5 leave virtual-keyboard mode

`CurrentUI` is the reliable check, and the only one. Note it is a **method** on
`org.fcitx.Fcitx.Controller1`, not a property -- reading it through
`org.freedesktop.DBus.Properties.Get` fails with `UnknownProperty`, which is
easy to misread as fcitx5 being broken:

    gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
      --method org.fcitx.Fcitx.Controller1.CurrentUI

**The trigger is our own typing.** fcitx5 hides the on-screen keyboard as soon
as it sees a key event, on the assumption that the user has reached for the
hardware keyboard -- and leaves virtual-keyboard mode along with it. Every key
we inject is a key event, so the keyboard closed itself after every single tap.
One tap produced, in order:

    fcitx5 -> HideVirtualKeyboard
    activelayout>>hl-virtual-keyboard-fcitx5,German
    CurrentUI: classicui

Things that do **not** trigger it, each tried specifically to provoke it:
focus moving between a text field and a terminal, killing the focused client
outright, `omarchy-restart-shell` (25 samples, all `virtualkeyboard`),
`ReloadConfig`, and `HideVirtualKeyboard`.

Two fixes, because they cover different failures:

- The daemon ignores a hide arriving within 300 ms of its own injection and
  re-asserts immediately. This is the only place a time window is the honest
  answer: fcitx5's hide carries no reason, and DBus replies do not arrive in
  step with Wayland events, so "did we cause this?" can only be answered by
  when it arrived. A real hide needs a tap elsewhere and cannot fit in 300 ms.
- The daemon re-checks `CurrentUI` every 3 s and re-registers if it has been
  dropped, which covers causes I have not found. There is no signal to hang
  this off: `org.fcitx.Fcitx.Controller1` exposes exactly one,
  `InputMethodGroupsChanged`, and since `CurrentUI` is a method it does not
  emit `PropertiesChanged` either. Polling is the only mechanism offered.

Recovery is the same call as startup: with fcitx5 reverted,
`ShowVirtualKeyboard` flips `CurrentUI` straight back and a show arrives
immediately. Verified against a real revert -- restarting fcitx5 produced
`fcitx5 stopped using the on-screen keyboard; re-registering` followed by
working show/hide.

### 3.1i Quickshell notes from building the plugin

- **`visible` cannot be a property name on an `Item`.** It is FINAL on
  `QQuickItem`, and overriding it fails the whole component with
  `Cannot override FINAL property`. Renamed to `shown`.
- **Editing a plugin QML file hot-reloads, but a component that previously
  failed to compile stays failed.** The shell logged the same error at the same
  line long after the line had become a comment, and the file compiled cleanly
  standalone. Qt caches compiled components by URL, and `rescanPlugins` does not
  clear that cache. `omarchy-restart-shell` does. Worth knowing before spending
  time on a fix that is already correct.
- **A failed `Socket` cannot be revived by setting its properties again.** This
  is what kept the keyboard from appearing at all, and it hid behind the fcitx5
  investigation for a whole session. After the daemon restarted, the shell
  logged `PeerClosedError`, then `ServerNotFoundError`, then nothing. A 2 s
  retry that set `connected = false`, cleared `path`, restored it and set
  `connected = true` never reconnected -- measured over 8 s with the daemon up
  and listening. The Socket keeps the failed state internally and re-assigning
  the same values is a no-op it never acts on. The fix is to put the Socket in
  a `Loader` and toggle `active` false/true, which destroys the object and
  builds a fresh one. Reconnect then takes ~4 s, and the daemon logs
  `shell connected`.
- **Silence is the failure mode on both sides.** A daemon that is not running
  looks exactly like one that is running with nothing to say, and the panel
  hides itself when `rows` is empty, so a broken link renders as a keyboard
  that simply never appears. One log line per connect/disconnect transition,
  and one per show/hide, is what made this findable at all.
- **fcitx5's show/hide churn is visible as flicker.** The keyboard appeared and
  vanished as focus moved, exactly as the §3.1a capture predicted. A 300 ms
  debounce on hide -- cancelled by any show -- fixes it.

### 3.2 What this means for the architecture

This replaces the brief's "fw12d becomes the seat's input-method client" design
wholesale, and it is a strictly better position:

| | brief's design | fcitx5-backend design |
|---|---|---|
| input-method-v2 slot | must seize it from fcitx5 | never touched |
| `~/.XCompose` compose keys | broken | preserved |
| auto-show/hide source | our own IM state machine | fcitx5 tells us |
| text injection | `commit_string` + virtual-keyboard-v1 | `ProcessKeyEvent` |
| layout following | scrape Hyprland socket2 | fcitx5 `CurrentInputMethod` |
| dead keys / AltGr | our problem | fcitx5's, already working |
| conflicts with Omarchy defaults | yes | no |

We stop being an input method and become a *rendering surface plus key source*
for the input method Omarchy already ships. Far less protocol state to own, and
nothing to fight over.

**Caveat to verify in Phase 1:** whether fcitx5 in `virtualkeyboard` UI mode
still delivers the auto-show trigger for apps whose text-input support is weak
(notably Ghostty). fcitx5 knows about focus only for clients that speak
text-input/IM protocols at all, so a client that never activates an input
context will not trigger the keyboard under *any* design. That limitation is
app-side and unavoidable, not something this architecture introduces.

**Housekeeping:** the probe left `CurrentUI` empty (`""`) after releasing the
name. `systemctl --user restart omarchy-fcitx5.service` restores
`classicui` + `keyboard-us` and the seat virtual keyboard. Any real
implementation must restore the UI on exit rather than leaving fcitx5 without
one.

### 3.3 Consequence for Phase 0.5 (squeekboard)

squeekboard is itself an input-method-v2 client and **will collide with
fcitx5**. Installing it would demonstrate the conflict rather than provide a
working baseline, and under the design above it is no longer on the
implementation path at all. Recommend **skipping the squeekboard interim step**
and reporting that, rather than installing a keyboard we already know cannot
coexist with the shipped input method.

---

## 4. Omarchy shell plugin contract

The brief points at `$OMARCHY_PATH/manual/32-shell-plugins.md`. **That file and
the entire `manual/` directory do not exist** in this install. The authoritative
docs are:

- `$OMARCHY_PATH/shell/README.md` (297 lines) — architecture, manifest schema,
  IPC contract, `shell.json` storage rules
- `$OMARCHY_PATH/shell/plugins/README.md` (116 lines) — first-party catalogue

### Manifest

```json
{
  "schemaVersion": 1,
  "id": "vendor.name",
  "name": "Display name",
  "version": "1.0.0",
  "author": "...",
  "description": "...",
  "kinds": ["service", "panel", "bar-widget"],
  "keepLoaded": true,
  "entryPoints": { "service": "Service.qml", "panel": "Panel.qml" }
}
```

Kinds: `bar-widget`, `panel`, `overlay`, `menu`, `service`, `bar`.
Services and `keepLoaded` panels mount at shell startup; other panels/overlays/
menus load on summon.

### Install path

A plugin is a **git repo with `manifest.json` at its root**, cloned to
`~/.config/omarchy/plugins/<manifest-id>/`:

```
omarchy plugin add <git-url> --enable --yes
omarchy plugin update <id>
omarchy plugin remove <id>
```

Plugins land **disabled** so the user can review code first. The installer
never runs plugin code, install hooks, or sudo. Saving any file under
`~/.config/omarchy/plugins/` hot-reloads plugin code.

Enabled state lives in `~/.config/omarchy/shell.json`; a third-party plugin is
enabled iff its id appears in that file. `version: 1` is required at top level.

### IPC

Single `shell` target plus per-plugin registered targets:

```
omarchy-shell shell ping | summon <id> <json> | hide <id> | toggle <id> <json>
              shell call <id> <method> <arg>
              shell rescanPlugins | reloadConfig | listPlugins
              shell setPluginEnabled <id> <"true"|other>
```

Note `setPluginEnabled` takes a **string**; only the literal `"true"` enables.

### Layer surfaces and focus

The OSD panel is the model for a bottom-anchored keyboard:

```qml
PanelWindow {
  anchors { top: true; bottom: true; left: true; right: true }
  WlrLayershell.namespace: "omarchy-osd"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None   // <- no focus stealing
}
```

`WlrKeyboardFocus.None` is the documented, first-party-proven mechanism for the
"must not steal focus" requirement.

### Theming

Not a "24-color system". `qs.Commons`'s `Color.qml` singleton exposes a small
foundational palette — `foreground`, `background`, `accent`, `urgent`, `muted`
— plus per-surface roles loaded from the active theme's `shell.toml`, with
fallback to the foundational palette. `Style.space(n)` provides scaled spacing.
Reassigning `shellValues` wholesale is what triggers re-binding on theme swap.

---

## 5. Prior art on this machine: `fw12tab`

`~/fw12/Downloads/src/fw12tab` — MIT, Sven Mathieu, remote
`github.com/mechanicsunlocked/fw12tab`, 17 commits, June–July 2026. Written for
Omarchy 3 / hyprlang. It already implements a large part of this brief.

| Component | Language | What it does |
|---|---|---|
| `bin/fw12tab` | bash, 241 ln | orchestrator: daemons, toggles, setup, doctor |
| `lib/tabletmode.c` | C, 73 ln | finds the `SW_TABLET_MODE` evdev device, streams 1/0 on change |
| `lib/oskbd.c` | C/GTK4, 417 ln | layer-shell on-screen keyboard, virtual-keyboard-v1 |
| `lib/osk-button.c` | C/GTK4, 177 ln | floating draggable toggle button |
| `lib/touchlaunch.c` | C/GTK4, 149 ln | touch app launcher |
| `lib/edgeswipe.c` | C/GTK4, 91 ln | top-edge pull-down opener |
| `system/*` | bash + unit | `soc_button_array` bind at boot **and after resume** |

### What is worth keeping

**`oskbd.c`'s keymap strategy is better than the brief's Qt Virtual Keyboard
plan for this user's requirements.** It compiles the system xkb keymap with
`xkb_keymap_new_from_names()`, uploads it to the compositor over
`zwp_virtual_keyboard_v1.keymap`, and then sends **real evdev keycodes**. Key
legends are derived from the keymap at runtime via
`xkb_keymap_key_get_syms_by_level()`, including a dead-key glyph table
(`^ ´ \` ~ ¨ ° ˇ ¸ ...`), and are relabelled live as Shift/AltGr/Caps latch.

The consequence is that AltGr level-3, dead keys, and composition are handled
by **xkb**, not by the keyboard app. Any layout xkb can compile — including
`lb` — works with no per-locale layout file. Qt Virtual Keyboard would require
a hand-maintained QML layout per locale and has **no `lb` layout at all**,
which is precisely the gap the brief flags as an open question.

It also already solves focus: `gtk_layer_set_keyboard_mode(..., NONE)`.

Modifier latching is implemented as single-tap = one-shot, double-tap = lock,
with `on_cancel` wired alongside `on_released` so a key can never stick down.

### What is broken or missing relative to the new brief

1. **No auto-show/hide.** `oskbd` binds only `zwp_virtual_keyboard_v1`. It
   never binds `zwp_input_method_v2`, so it has no idea when a text field is
   focused. Showing it is manual (a floating button or `Super+Shift+K`). This
   is the single largest piece of new work.
2. **Layout detection reads `~/.config/hypr/input.conf`** — hyprlang. Omarchy 4
   is Lua (`input.lua`) and that file does not exist, so it silently falls
   through to `localectl` and then `"us"`. Broken on this install.
3. **Does not follow live layout changes.** Layout is read once at spawn; there
   is no `activelayout>>` subscription on Hyprland's socket2.
4. **Hardcoded German-ish legends** (`Strg`) on fixed-label keys, while derived
   keys come from the keymap — inconsistent under fr/lb.
5. **The orchestrator is bash** with `pgrep`/`pkill -x` process management,
   `sleep 0.3` restacking, and `sleep 2` reconnect loops. The new brief
   explicitly rules this out as a final mechanism.
6. **`tabletmode.c` exits when the device disappears** — the read loop just
   ends. Combined with the resume unbind (§7) this matters; the bash wrapper
   papers over it with a `sleep 2` retry loop.
7. Wires itself in via `source = ...` into `hyprland.conf`, which no longer
   matches Omarchy 4's Lua config.

### Contradiction in its own history, now resolved

Its README says the FW12 "exposes no tablet-mode switch or sensor interrupt"
and uses a 2 s hinge-angle poll. But commit `3d12479` is
*"Replace wvkbd with our own GTK4 keyboard; switch-based tablet detection"* and
`11a76c2` is *"Add tablet-switch bind service (boot + resume) for the
soc_button_array probe race"*.

Per the user: the project moved from hinge angle to the switch **because the
hinge sensor stopped working after resume from hibernation**. The README was
never updated. So the ordering is: hinge angle first → found to break across
hibernate → switched to `SW_TABLET_MODE` → which then needed the bind service
to exist at all, at boot and again after every resume.

**This is the most important open question in Phase 0** and is what §7 tests.

---

## 5.4 Omarchy's bar is hard to hit by touch — the real cause is target size

Observed live: tapping bar widgets on the touchscreen did nothing, and repeated
tapping produced a full-screen animation that looked like a wallpaper switch.

**Root cause: the taps were missing the bar entirely and landing on the
wallpaper behind it.** The background layer opens the wallpaper picker on
**double-click** — `$OMARCHY_PATH/shell/plugins/background/Background.qml:312`:

```qml
MouseArea {
  anchors.fill: parent
  acceptedButtons: Qt.LeftButton | Qt.RightButton
  onDoubleClicked: function(mouse) {
    if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
    else root.openSelector()
  }
}
```

Two taps in quick succession near the top edge, both missing the 26 px bar,
register as a double-click on the background and open the image selector. That
is the animation that was reported.

> **Correction.** An earlier version of this section attributed the animation to
> `Bar.qml:1402`'s `pressAndHoldInterval: 200` bar-move drag gesture. That code
> is real, and 200 ms *is* short for touch, but it is **not** what was being
> hit. The observed symptom is a missed tap reaching the background layer. The
> size problem below is the actual defect; the hold interval is at most a
> secondary one.

**The actual defect — target size.** The bar is 26 logical px tall at
`scale: 2` on this panel:

```
eDP-1  1920x1200  scale: 2  transform: 0    -> 960x600 logical
reserved: 0 26 0 0
```

26 logical px = 52 device px. At 1200 px over 160 mm (7.5 px/mm) that is
**≈6.9 mm** — under the ~9 mm minimum usually recommended for touch targets.

**Confirmed not a regression from this session's work:** `omarchy-shell` (pid
1251) has been running untouched since boot at 14:34:54; every relevant
`hyprctl getoption` reports `set: false` (no runtime overrides were ever
issued); monitor is `transform: 0`, `scale: 2`, both defaults; and no stray
Quickshell, evtest, or layer surface remains from the probes.

**Why it appeared to be fixed by a reboot.** It was not. Measured before and
after, the geometry and source are byte-identical:

```
before:  xywh: 0 0 960 26   reserved: 0 26 0 0   scale: 2   transform: 0
after:   xywh: 0 0 960 26   reserved: 0 26 0 0   scale: 2   transform: 0
Bar.qml:1402  pressAndHoldInterval: 200   (unchanged)
```

The variable is aim, not system state. A 6.9 mm target near a screen edge is
hit-or-miss by finger, so the same bar genuinely works sometimes and not
others — which is exactly the intermittent behaviour observed across sessions.

**Implication for the plugin.** The fix is a bigger touch target in tablet
mode, which a plugin cannot impose on the first-party bar. Options:

1. File upstream: on a touchscreen, the bar needs a larger hit area (or an
   invisible extended input region) in tablet mode. Independent of this
   project. **Decided: do this.**
2. Ship a `kind: "bar"` replacement that is touch-tuned. The plugin system
   supports replacing the bar outright, but it is a large amount of work.
3. `omarchy plugin clone omarchy.bar` → `drotiesel.bar` and enlarge it. Quick,
   but forks the bar and drifts from upstream on every update.

**Decided (2026-08-15): option 1 only.** (2) and (3) are out of scope for the
first release.

A cheap mitigation worth noting in the README: the bar's hit area is only a
problem because a *miss* does something dramatic. Users bothered by accidental
wallpaper-picker launches can avoid it entirely, since the trigger is a
double-click on the background rather than anything the bar does.

### Note: `Ui/KeyboardPanel.qml` is **not** an on-screen keyboard

Despite the name, `$OMARCHY_PATH/shell/Ui/KeyboardPanel.qml` (418 lines) is a
layer-shell **popup container** for bar widget panels, "designed for
click-driven AND keyboard-driven panels (e.g. SUPER+CTRL+W summon)". It is used
by the clock, audio, network, bluetooth, power, weather, monitor, tailscale and
agents panels. "Keyboard" refers to keyboard *summoning*, not a virtual
keyboard. There is no existing OSK anywhere in Omarchy.

It is, however, the correct model for our own panel: it documents Omarchy's
working approach to layer-shell focus (`WlrKeyboardFocus.Exclusive` prime then
`OnDemand`), and why `PopupWindow`/xdg-popup was rejected.

## 5.5 Keyboard layout: there is no `lb` xkb layout, and the live layout is `de`

The brief treats Luxembourgish as an xkb layout that Qt Virtual Keyboard lacks.
In fact **xkb has no `lb` layout either**:

```
/usr/share/X11/xkb/symbols/lb                    does not exist
grep '^\s*lb\s' rules/base.lst, rules/evdev.lst  no match
grep -ri luxem /usr/share/X11/xkb/               no match
```

There is no Luxembourgish entry anywhere in `xkeyboard-config`. Luxembourg
users conventionally use `fr`, `de`, `ch(fr)`, or `ch(de)`.

The live configuration confirms this — every keyboard on the seat currently
reports:

```
at-translated-set-2-keyboard   |layout: de |active: German
```

So the machine is on plain `de` right now, and `~/.config/hypr/input.lua` has
its `kb_layout` block entirely commented out (Omarchy's default). fcitx5's own
profile says `Default Layout=us`, `DefaultIM=keyboard-us` — i.e. fcitx5 has
never been configured and is passing through.

**This dissolves the brief's `lb` question and replaces it with a better one.**
There is no `lb` layout to follow, in xkb or Qt VK. What a Luxembourg user
actually needs is either `fr`/`de`/`ch` layouts plus working compose sequences
for the accents — which is exactly what Omarchy's fcitx5 + `~/.XCompose`
already provides — or a genuinely new custom xkb symbols file.

### DECIDED (2026-08-15)

**Follow the active xkb layout; rely on dead keys and `~/.XCompose` for
accents. Do not author an `lb` layout.**

The user's stated plan makes this cleaner still: currently on `de`, **moving to
US International (`us(intl)`)**. That layout provides `´ \` ¨ ^ ~` as dead keys
natively, which composes é è ë ê ñ ä ö ü à — i.e. essentially the full
French/German/Luxembourgish accent set — without any custom layout, and AltGr
level-3 for `€ @ ~` etc.

Consequences for the design:

1. The OSK **must not** hardcode a layout. Legends have to be derived from the
   live xkb keymap, because the layout is changing from `de` to `us(intl)`
   under us. fw12tab's `oskbd.c` already does exactly this via
   `xkb_keymap_key_get_syms_by_level()`, and already ships the dead-key glyph
   table (`^ ´ \` ~ ¨ ° ˇ ¸ …`) that `us(intl)` depends on.
2. Dead keys are now load-bearing rather than a nice-to-have. Under the §3
   design fcitx5 composes them, which is the well-tested path.
3. **Open sub-question: physical key shape.** `oskbd.c` hardcodes an ISO body —
   `KEY_102ND` (the extra `< > |` key) and a tall ISO Enter. A US layout is
   ANSI: no `KEY_102ND`, wide flat Enter. If the user's FW12 is physically ISO
   but running `us(intl)`, the *keymap* is ANSI while the *hardware* is ISO.
   The OSK should follow the keymap, so it needs both an ISO and an ANSI body
   selected by whether the active keymap binds `KEY_102ND`. Small, but it must
   be handled or the OSK will show a key that types nothing.

---

## 5.6 Qt Virtual Keyboard inside Quickshell — loads, but is not usable as-is

`qt6-virtualkeyboard 6.11.1-1` installed. The QML module is present at
`/usr/lib/qt6/qml/QtQuick/VirtualKeyboard/` with `InputPanel.qml`.

A minimal Quickshell config (`tools/qsvktest/shell.qml`) importing
`QtQuick.VirtualKeyboard` and instantiating `InputPanel` inside a `PanelWindow`
was run against the live compositor:

```
DEBUG qml: QSVK: ShellRoot loaded
DEBUG qml: QSVK: available locales = []
DEBUG qml: QSVK: active locale =
DEBUG qml: QSVK: InputPanel INSTANTIATED ok
INFO : Configuration Loaded
WARN : input method is not set
WARN : input method is not set          (repeating)
```

**Result: it instantiates, but it is inert.**

1. `VirtualKeyboardSettings.availableLocales` is **empty**. Layouts are
   compiled into `libqtvkblayoutsplugin.so` as Qt resources
   (`prefer :/qt-project.org/imports/.../Layouts/`), and none are exposed at
   runtime here.
2. `input method is not set`, repeating indefinitely. Qt VK is designed to *be*
   the Qt platform input method — it expects `QT_IM_MODULE=qtvirtualkeyboard`.

Omarchy sets `QT_IM_MODULE=fcitx` globally
(`default/environment.d/10-omarchy-fcitx.conf`). Making Qt VK functional would
mean overriding that for the shell process, which would take Qt VK's input
method *instead of* fcitx5 inside `omarchy-shell` — reintroducing exactly the
conflict §3 avoids.

Combined with §5.5 (Qt VK has no `lb` layout, and neither does xkb), the Qt
Virtual Keyboard path is **not recommended**. The brief's stated goal — "the
Plasma 6 keyboard experience" — is better served by fcitx5's own virtual
keyboard protocol, which already provides the layouts, dead keys, compose
sequences and candidate handling that Qt VK would have to reimplement.

### Upstream state (checked 2026-08-15)

| project | state |
|---|---|
| `KDE/plasma-keyboard` | active (pushed 2026-08-13) but README still states it "uses the **input-method-v1** Wayland protocol"; KWin-configured via `kwriteconfig6 ... InputMethod`. Hyprland advertises **no** `zwp_input_method_manager_v1`, only v2 — so plasma-keyboard cannot run here. Brief's assumption holds. |
| `JeanSchoeller/hyprkbd` | **abandoned** — last commit 2024-07-23, 4 stars, C. No input-method-v2 auto-show landed. Not viable. |
| Omarchy marketplace | registry live, updated 2026-08-15, **164 plugin sources**. Searching every `id`/`name`/`description`/`tags` for tablet, keyboard, osk, rotate, touch, stylus, pen returns **zero matches**. This would indeed be the first. |

---

## 5.7 Hyprland's Lua config can do rotation itself — possibly no daemon needed

Discovered late (2026-08-15), while implementing the daemon. **This may remove
most of Component A and needs resolving before more code is written.**

### `keyword` does not work on Omarchy 4

The first implementation used `hyprctl keyword monitor ...` over the IPC socket,
as fw12tab did. Hyprland refuses it:

```
$ hyprctl keyword monitor "eDP-1,preferred,auto,2,transform,1"
keyword can't work with non-legacy parsers. Use eval.
```

Omarchy 4 configures Hyprland in **Lua**, and the Lua config manager rejects
`keyword` outright. The two are mutually exclusive — the binary also carries
`eval is only supported with the lua config manager`. Anything ported from an
Omarchy 3 / hyprlang setup will silently do nothing here: note that `hyprctl`
still **exits 0** while refusing the command.

The working form is `eval` with a Lua statement, verified applying and
reverting a real rotation:

```lua
local ms = hl.get_monitors()
local t = nil
for _, m in ipairs(ms) do if m.name:sub(1,3) == "eDP" then t = m break end end
if not t then t = ms[1] end
if t then hl.monitor({output=t.name, mode="preferred", position="auto",
                      scale=t.scale, transform=N}) end
hl.config({input={touchdevice={transform=N}, tablet={transform=N}}})
```

Result: `transform: 1`, `input:touchdevice:transform 1`,
`input:tablet:transform 1`, scale preserved at 2. Reverting to 0 restores it.

Note `eval` returns `"ok"` on the socket regardless of what the Lua returns —
return values are **not** surfaced. To get data out of Lua, write a file.

### The Lua environment is far more capable than expected

Verified by having Lua write its results to a file:

```
accel-display: iio:device0          <- found by label, probing iio:device0..9
raw: x=224 y=11472 z=11760          <- io.open on sysfs works
hl.timer exists: function           <- {timeout=ms, type="repeat"|"oneshot"}
hl.bind exists: function
hl.bind("switch:on:gpio-keys", ...) <- registers without error
```

So Hyprland's Lua has an unrestricted `io` library, can read the accelerometer
directly, has a repeating timer, and accepts `switch:on:` / `switch:off:` bind
keys. Lua has no directory listing, but probing `iio:device0..9` and matching
`label` sidesteps that and is boot-stable (§2.1).

**If the switch bind actually fires** — registered cleanly but *not yet observed
firing*, which needs a physical fold — then tablet detection and auto-rotation
can both live in a Lua config file with **no daemon at all**: no evdev watcher,
no inotify hotplug logic, no poll loop, no Hyprland IPC client, no socket
protocol, no systemd user unit.

### What Lua still cannot do

- **No UI.** The entire 1777-line `hl.meta.lua` API is configuration — binds,
  monitors, rules, dispatchers, notifications. There is no drawing, surface, or
  widget call. **An on-screen keyboard cannot be written in Hyprland Lua.**
- **No DBus.** So the fcitx5 virtual-keyboard bridge (§3.1) cannot be Lua
  either.

### The trade-off to weigh before deciding

A Lua timer polling the accelerometer runs **inside the compositor process**. A
callback that blocks or throws degrades the whole desktop, where a separate
process cannot. Three small sysfs reads at 4 Hz is cheap, and the reads are
from a kernel-backed virtual filesystem rather than disk — but it is still
compositor time, and it is the honest argument for keeping a daemon.

Against that: the Lua version deletes roughly 400 lines of C and every moving
part between the daemon and Hyprland, which is exactly the "as simple as
possible, bulletproof across versions" goal.

### RESOLVED — the Lua path works end to end

Switch binds fire in both directions:

```
16:00:32 TABLET ON  fired
16:00:39 TABLET OFF fired
```

And the full cycle was captured live, sampling switch state and all three
transforms at 1.5 s:

```
42  switch=1  mon=0  touch=0  pen=0     <- fold detected
43  switch=1  mon=3  touch=3  pen=3     <- rotation applied, all three together
    ...
    switch=0  mon=0  touch=0  pen=0     <- unfold reset everything
```

Monitor, touch and stylus move in lockstep, which is the property that has to
hold or the pen stops landing where the user points. Hyprland sits at **0.2%
CPU** with the 4 Hz poll running inside it.

### `hyprctl reload` rebuilds the entire Lua state

Worth recording because it removed code rather than adding it. The first
implementation carried reload-safety machinery — state kept on a global,
unbind-before-bind, timer teardown — on the assumption that Omarchy's
`bootstrap.lua` clearing `package.loaded` could leave stale binds and timers
behind.

It cannot. Setting a marker global and reloading three times:

```
marker before reload:  "set-before-reload"
marker after 3 reloads: nil
switch binds:          exactly 1 of each
SUPER+R binds:         1
Hyprland CPU:          0.2%
```

Hyprland destroys and rebuilds the Lua state on every reload, so nothing
survives to duplicate. The teardown code was guarding an impossible condition
and has been deleted.

**Install must go through `require()`, not `dofile`.** A module loaded with
`dofile` via `hyprctl eval` works until the first `hyprctl reload`, which
rebuilds the config from `hyprland.lua` and silently drops every bind the
module registered. The line
`require("hypr.fw12-tablet")` in `~/.config/hypr/hyprland.lua` is what makes it
survive.

### Still unverified

- More than one orientation change within a single tablet session.
- `SUPER + R` rotation lock behaviour.
- Suspend/resume while folded.

---

## 6. Language choice: C vs Rust

The brief mandates Rust or C for the daemon and prefers Rust.

Evidence pulling toward **C** on this specific machine:

- No Rust toolchain installed; `gcc`, `pkg-config` and `wayland-scanner` are.
- ~750 lines of working, readable, MIT-licensed C already exist here solving
  the same problems, by the same author, with correct protocol handling.
- The keyboard must link `libxkbcommon` and drive raw Wayland protocol; the C
  bindings are the reference implementation, and `wayland-scanner` generates
  C directly. The Rust path (`wayland-client`, `smithay-client-toolkit`) is
  good but would be a rewrite of code that already works.
- Every runtime dep is already a C library (gtk4-layer-shell, xkbcommon).

Evidence pulling toward **Rust**: the new daemon is materially more complex
than the old one (input-method-v2 state machine + Hyprland socket2 event
subscription + IIO/DBus + a Unix socket protocol), and that is where Rust's
error handling and lifetime discipline pay off most.

**Recommendation deferred to the architecture proposal**, but the honest read
is that C is the lower-risk choice here purely because so much of the hard part
is already written and proven on this exact hardware.

---

## 7. Open questions — blocked, and the hibernate test

### 7.1 Still to establish about the hinge/resume failure

The first hibernate cycle did not reproduce it. Before designing around it:

- Repeat hibernate at least once more, and test **s2idle/suspend** separately —
  the failure may be specific to one sleep path.
- Retest **after the switch is bound**, since binding `soc_button_array` changes
  what touches these ACPI/GPIO paths across sleep.
- Retest with a **poller actively reading** `in_angl_raw` across the transition;
  fw12tab polled every 2 s, and a read racing the EC's resume may be what broke
  it rather than sleep alone.
- Confirm touchscreen and stylus still work after resume, given the i2c
  `ENXIO` above.

### Blocked on root (user is enabling passwordless sudo)

- Bind `INT33D3:00` and confirm a `SW_TABLET_MODE` device appears.
- Install `iio-sensor-proxy`; confirm `monitor-sensor --accel` fires in all
  four orientations and that it follows `accel-display`, not `accel-base`.
- Install `wayland-utils`, `evtest`, `squeekboard`.
- Confirm whether `pinctrl_tigerlake` in `MODULES=` in mkinitcpio actually
  fixes the race at boot on this install, or whether the systemd bind unit is
  still required.

### fcitx5 integration (highest priority — decides the architecture)

- Which fcitx5 mechanism emits focus-in/focus-out to an external process:
  kimpanel DBus signals, or the `virtualkeyboard` addon?
- Does enabling fcitx5's `virtualkeyboard` addon give us show/hide events
  without also spawning fcitx5's own keyboard UI?
- Can our keyboard inject via `zwp_virtual_keyboard_v1` while fcitx5 also holds
  a virtual keyboard on the same seat? (Multiple virtual keyboards are allowed
  by the protocol — unlike input-method — but this needs confirming in
  Hyprland.)
- Confirm empirically that a second `get_input_method` really is refused, by
  installing squeekboard and watching it fail.

### Blocked on network

- `JeanSchoeller/hyprkbd` — has input-method-v2 auto-show landed?
- `KDE/plasma-keyboard` — still input-method-v1/KWin-only?
- omarchyplugins.com / `HANCORE-linux/omarchy-plugin-marketplace` registry —
  any existing OSK/tablet plugin, and the exact publish requirements.
- Qt VK inside Quickshell — needs `qt6-virtualkeyboard` installed to test.

### The hibernate test (planned)

The user will hibernate and resume. Pre-hibernate baseline is captured. On
resume, re-check, in order:

1. `/sys/bus/platform/devices/INT33D3:00` still present?
2. `soc_button_array` still bound to it?
3. `SW_TABLET_MODE` device still present and readable?
4. `/sys/bus/iio/devices/` — do all three cros-ec IIO devices survive?
5. `in_angl_raw` — **does the hinge angle still update?** This is the reported
   failure.
6. `/dev/cros_ec` still present?
7. Does `cros_ec` need a re-probe the way `soc_button_array` does?

### RESULT: hibernate test run 2026-08-15, S4 entry 14:28:21 → exit 14:29:42

**The reported failure did not reproduce.** A real hibernation cycle completed
(`PM: hibernation: hibernation entry` … `hibernation exit`, state S4, 19.5 GB
image) and afterwards:

| Check | Result |
|---|---|
| `INT33D3:00` present | yes (unchanged) |
| `soc_button_array` bound | still UNBOUND — same as before, so unrelated to sleep |
| all three cros-ec IIO devices | **all survived** |
| `/dev/cros_ec` | present, unchanged |
| cros_ec modules loaded | 12, unchanged |
| **hinge angle still tracks** | **yes** |

A 30-second sample at 1 Hz with the lid deliberately moved:

```
01 angle=124   07 angle=120   13 angle=123   19 angle=500   25 angle=74
02 angle=116   08 angle=127   14 angle=123   20 angle=122   26 angle=78
03 angle=116   09 angle=500   15 angle=123   21 angle=74    27 angle=81
04 angle=116   10 angle=119   16 angle=123   22 angle=85    28 angle=74
05 angle=115   11 angle=122   17 angle=123   23 angle=103   29 angle=75
06 angle=116   12 angle=123   18 angle=500   24 angle=76    30 angle=67
```

The angle follows the lid faithfully across 124° → 116° → 127° → 123° → 74° →
67°, and `accel-display` tracks alongside it. Post-hibernate the sensor is
fully alive.

**So the hinge angle is not inherently broken by hibernation on this kernel
(7.1.8-arch1-3).** Either it was fixed upstream since the June/July fw12tab
work, or the failure is intermittent, or it is specific to a different sleep
path (s2idle vs S4) or to a re-probe that fw12tab's own polling was provoking.
This needs at least one more cycle before we design around it — see §7.1.

### The `500` sentinel is real and must be handled

Samples 09, 18 and 19 read **`angle=500`** — during rapid lid movement, and
correlated with out-of-range accelerometer magnitudes (sample 09 reads
`z=-21200`, about −1.3 g). 500 is the EC's "angle indeterminate" sentinel, not
a 500° hinge.

fw12tab hit this too — commit `1a28707` *"watcher ignores >360 deg sensor
sentinel"* and `1f12e3c` *"angle state machine; 500 holds mode, not flips it"*.

Any angle-based state machine **must treat `>360` as "no reading, hold current
state"**, never as "past 360° therefore tablet". A naive threshold comparison
would flip into tablet mode every time the user moves the screen quickly. This
is a strong argument for preferring the `SW_TABLET_MODE` switch as the primary
signal once it is bound, with the angle as corroboration only.

### Unrelated but noted: i2c does not restore cleanly

```
spd5118 17-0050: PM: dpm_run_callback(): spd5118_resume [spd5118] returns -6
spd5118 17-0050: PM: failed to restore async: error -6
```

`-6` is `ENXIO`. This is the memory SPD sensor, not ours, but the touchscreen
(`ILIT2901:00`, i2c-0), stylus, and touchpad (`PIXA3854:00`, i2c-2) sit on the
same bus family. Touch and pen must be re-tested explicitly after resume.

### Reboot caveat

This install has not been rebooted since the initial install + update. Running
kernel `7.1.8-arch1-3` matches the installed `linux 7.1.8.arch1-3` package and
its module tree is intact, so there is no stale-module hazard. But the
`pinctrl_tigerlake` / `soc_button_array` probe order is decided at boot, so the
unbound switch must be re-confirmed on a fresh boot before we conclude the race
is deterministic here.

**Pre-hibernate baseline, 2026-08-15T14:20:09+02:00, uptime 38 min:**

```
INT33D3:00                   present
soc_button_array bound       UNBOUND
pinctrl_tigerlake            loaded (3 users)
SW_TABLET_MODE device        NONE
iio:device0  cros-ec-lid-angle
iio:device1  cros-ec-accel  label=accel-display
iio:device2  cros-ec-accel  label=accel-base
in_angl_raw                  99
accel-display raw            x=3440  y=15376  z=-1232
/dev/cros_ec                 present (crw------- root root 10,262)
```

Note the switch is already unbound *before* any suspend, so the boot race and
any resume race are separate failures that must be distinguished.

---

## 8. The on-screen keyboard, revisited: squeekboard works

Constraints for this pass: fcitx5 must not be touched, Omarchy must not be
modified, official Arch repos only, and the result must be a light plugin.
All of the below was measured on this machine on 2026-08-16, by extracting
packages from the mirror into a scratch directory and running them against the
live session. **Nothing was installed and no configuration was changed.**

### 8.1 fcitx5 does hold the input-method-v2 slot — proven

Written down before as an inference; now it is measured. Running squeekboard
with fcitx5 up produced, in `WAYLAND_DEBUG`:

```
 -> zwp_input_method_manager_v2#37.get_input_method(wl_seat#36, new id zwp_input_method_v2#35)
    zwp_input_method_v2#35.unavailable()
 -> zwp_input_method_v2#35.destroy()
```

Hyprland answers a second input-method client with `unavailable`. So no OSK
can use input-method-v2 here without stopping fcitx5 first. That is the whole
reason auto-show is hard, and it is a protocol fact, not a bug.

### 8.2 Stevia (`extra/stevia`) cannot run on Hyprland — one missing global

Stevia is the current Phosh keyboard and looked like the obvious answer: it is
in `extra`, it is maintained, and it exposes `sm.puri.OSK0` for show/hide. It
starts on Hyprland, finds the output, and takes the DBus name, then stops at:

```
phosh-osk-stevia-DEBUG: Wayland not yet ready, skipping input surface creation
```

`pos_wayland_has_wl_protcols()` requires eight globals. Seven are present on
Hyprland. The eighth, `zphoc_device_state_v1`, is phoc-only — it is how phoc
tells the keyboard about the lid and tablet-mode switches. Hyprland will never
advertise it, and only a compositor can advertise a global, so this cannot be
worked around from outside. Checked against the packaged 0.56.0 binary:

```
zphoc_device_state_v1        *** MISSING ***
zphoc_lid_switch_v1
zphoc_tablet_mode_switch_v1
```

Stevia is therefore out, permanently, not pending a fix at our end.

### 8.3 squeekboard (`extra/squeekboard` 1.43.1) does work

squeekboard predates the phoc dependency. `strings` shows zero `zphoc_`
references; it uses only `zwlr_layer_shell_v1`, `zwp_input_method_v2` and
`zwp_virtual_keyboard_v1`, and Hyprland advertises all three.

Run against the live session with fcitx5 up and untouched:

* takes `sm.puri.OSK0` on the session bus
* is told `unavailable` for input-method-v2 (§8.1) and **carries on**
* `busctl call --user sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b true`
  maps a layer surface — `namespace: osk, xywh: 0 550 1200 200`,
  `set_exclusive_zone(200)`, `set_keyboard_interactivity(0)`
* `SetVisible b false` unmaps it cleanly; zero `osk` layers afterwards
* creates `zwp_virtual_keyboard_v1` and uploads a keymap on show

`set_keyboard_interactivity(0)` matters: the keyboard never takes focus, so the
window being typed into keeps it. `set_exclusive_zone(200)` matters too — tiled
windows shrink instead of being covered.

Keys are emitted as `zwp_virtual_keyboard_v1` events, i.e. as if typed on real
hardware. **fcitx5 sees them and processes them normally**, so compose
sequences and input methods keep working from the on-screen keyboard. This is
the opposite of the old design, which fought fcitx5 for control of the same
job.

### 8.4 What squeekboard gives us for free

Built-in layouts include `us`, `de`, `us_wide`, `de_wide`, and — worth noting
for this machine — `terminal/us` and `terminal/de`, a layout with Ctrl, Esc,
Tab and arrows. There are also `number`, `emoji`, `url`, `email` and `pin`
views. Layout selection follows `org.gnome.desktop.input-sources sources`,
which is currently unset here (`@a(ss) []`), producing a
`WARNING: No system layout present` and a default US layout.

### 8.5 What is still missing: nothing knows when to show it

Without input-method-v2, squeekboard cannot see text-field focus, so it will
never show itself. Something has to call `SetVisible`. Two options:

**A — manual toggle.** A bar button, a keybind, or a gesture calls `SetVisible`.
Perhaps ten lines. No daemon, no fcitx5 interaction, nothing to go wrong. This
is the "simple, fast, bulletproof" answer.

**B — let fcitx5 decide.** fcitx5 already tracks text-field focus perfectly. Its
`virtualkeyboard` UI addon (`libvirtualkeyboard.so`, `UIType=OnScreenKeyboard`,
`OnDemand=True`) calls a registered client to show and hide. A small daemon
that registers as that client and forwards to `SetVisible` gets real auto-show
with no UI code at all. Most of it already exists in git history as `oskd`'s
`fcitx.c`. The known wrinkle is §3.1j: fcitx5 hides the keyboard whenever it
sees a key event, and squeekboard's keys *are* key events, so the 300 ms
self-hide suppression window from the old daemon is still required.

Note the DBus object at `/virtualkeyboard` exposes only `ShowVirtualKeyboard`,
`HideVirtualKeyboard` and `ToggleVirtualKeyboard` — there is no key-input path
through fcitx5, which is why the keyboard itself must inject.

### 8.6 Ruled out

| Candidate | Verdict |
| --- | --- |
| `extra/stevia` | needs `zphoc_device_state_v1`; phoc only (§8.2) |
| `extra/plasma-keyboard` | binds `zwp_input_method_v1`/`zwp_input_panel_v1`; Hyprland implements neither |
| `extra/onboard` | X11/XTEST; cannot reach native Wayland clients |
| `extra/qt6-virtualkeyboard` | a framework, Qt apps only, and would fight `QT_IM_MODULE=fcitx` |
| wvkbd, hyprkbd, fcitx5-osk | AUR only |
| disabling fcitx5's `waylandim` | frees the input-method slot and gives full auto-show, but is a compromise on fcitx5 — explicitly excluded |

---

## 9. Why an on-screen keyboard's keybinds work, or do not

The point of a full keyboard on a tablet is to reach the compositor's own
keybinds. Whether that works at all comes down to one Hyprland setting and one
choice inside the keyboard, and it is not obvious from either end.

### 9.1 Hyprland matches binds by keycode, and an OSK brings its own keycodes

Measured on 2026-08-17. A temporary bind was added over IPC and then driven
with `wtype`, which creates a `zwp_virtual_keyboard_v1` exactly as an on-screen
keyboard does:

```
hyprctl eval 'hl.bind("F9", function() ... end)'   -> registered (confirmed in `hyprctl binds`)
wtype -k F9                                         -> bind did NOT fire
wtype -M logo -k F12 -m logo                        -> bind did NOT fire
```

The binds were present and correct. The reason nothing fired is that
`input:resolve_binds_by_sym` defaults to **false**, so Hyprland matches binds
by *keycode*. `wtype` uploads its own minimal keymap, in which F9 sits at
whatever keycode it chose, and that never matches the keycode the bind was
compiled against.

Turning the option on fixes it outright:

```
hyprctl eval 'hl.config({ input = { resolve_binds_by_sym = true } })'
wtype -k F9              -> FIRED
wtype -M logo -k F12 -m logo  -> FIRED
```

So any on-screen keyboard that invents its own keymap -- squeekboard does --
needs `resolve_binds_by_sym = true` before a single keybind will work from it.

### 9.2 Uploading the system keymap avoids the whole problem

`fw12-oskbd` instead uploads the machine's *own* xkb keymap and sends real
evdev codes (`KEY_Q`, `KEY_LEFTMETA`, …). Its keys are therefore
indistinguishable from the built-in keyboard's, and binds match by keycode with
no configuration change at all. Three things follow from the same decision:

* keybinds work as shipped, and `resolve_binds_by_sym` can stay off, so bind
  behaviour on the physical keyboard is not altered either;
* AltGr and dead keys behave exactly as they do on the real keyboard, which is
  what makes an international layout usable -- squeekboard cannot do this at
  all, see §9.3;
* key legends are read back out of the keymap at runtime, so the on-screen
  keyboard follows `input:kb_layout` with no second copy of the layout to keep
  in step. Verified: with `kb_layout = de` the on-screen keyboard came up with
  ü ö ä ß, y/z swapped and Strg on the modifier caps, from the same binary.

### 9.3 What squeekboard cannot do, for the record

A full layout was written for squeekboard and it does work -- six rows, Super
via `modifier: Mod4`, function keys, arrows, and an accents view. Two hard
limits killed it:

* **No AltGr.** `squeekboard-test-layout` rejects `modifier: Mod5` with
  "Modifier Mod5 unsupported"; only Control, Shift and Mod1..Mod4 parse. An
  international layout without AltGr is a layout with the accents bolted on
  beside it rather than a real one.
* **Its own keymap**, hence §9.1, hence a global change to how Hyprland
  resolves every bind on every keyboard.

Also worth writing down, since it cost time: **gdk-pixbuf on this system has no
SVG loader** -- librsvg no longer ships one. `gtk_icon_theme_load_surface()`
therefore fails on any scalable icon with "Unrecognized image file format", and
icons installed into `hicolor/scalable/` silently do not render. PNGs at fixed
sizes work. GTK4's `gtk_picture_new_for_filename()` is unaffected and loads SVG
directly, which is how the Framework mark on the Super key renders.

---

## 10. The Framework 12 keyboard, measured

The on-screen keyboard's proportions were guessed until now (1u = 4 sub-columns,
height = width/3). This section replaces the guess with numbers taken off a
top-down photograph of the machine's own keyboard, because "feels natural" is
a geometry problem and geometry can be measured.

### 10.1 Method

The photo is a straight-on product shot, 1056x1290. Key faces sit at grey
160-190 against a 205-240 chassis, so a threshold at 200 separates them
cleanly. From there: a horizontal projection gives the row bands, a vertical
projection inside each band gives the key edges, and runs split by a legend are
merged when the break is under 4 px.

### 10.2 What came out

The six rows all begin at x=28 and end at x=833. **They share one left edge and
one right edge**; the stagger is entirely the width of each row's leading key,
not a ragged margin. Every row spans the same width, and that width is
**14.25u** — the shift row makes it exact and unambiguous: 2u + 10x1u + 2.25u.

Unit pitch is therefore 811/14.25 = **56.9 px**, key face 51 px, **gap 6 px =
0.105u**. Vertical pitch measured 57 px, so the alphanumeric grid is square.

| Row | Leading key | Body | Trailing key | Sum |
|---|---|---|---|---|
| function | esc 1.125 | 12 x 1 | del 1.125 | 14.25 |
| number | ` 0.875 | 12 x 1 | backspace 1.375 | 14.25 |
| top | tab 1.2 | 12 x 1 | \ 1.05 | 14.25 |
| home | caps 1.5 | 11 x 1 | enter 1.75 | 14.25 |
| bottom | shift 2.0 | 10 x 1 | shift 2.25 | 14.25 |
| modifier | ctrl/fn/super/alt 4 x 1 | space 5 | altgr, ctrl, arrows | 14.25 |

Measurement noise was +/-0.02u throughout, and every row summed to 14.25 within
that. The function row is **0.7u tall** against 1u for the rest; the arrow
cluster is a 1.25u column of half-height up/down between full-height left and
right. Total height 5.7u, so the keyboard's aspect is exactly **2.5:1**.

The photographed machine is US/ANSI, so there is no ISO 102nd key, and the
Enter is a plain 1.75u home-row key rather than the tall ISO shape the previous
layout drew. Enter's top-right corner does poke about 7 px up into the row gap
on the real keyboard; that is not reproduced.

### 10.3 Two implementation traps

**GtkGrid cannot express this.** The fractions need 40 sub-columns per unit,
i.e. 570 across, and at the rendered width of 845 px that is 1.48 px per
column. GtkGrid allocates whole pixels, so a homogeneous 570-column grid gives
1 px to some columns and 2 px to others; a span of 40 accumulates the error and
the right-hand half of every row comes out visibly narrower. Replaced with a
GtkFixed and one rounding per key edge.

**A label will not let its key shrink.** GtkLabel's minimum width is its text,
every key inherits that, and 570 columns multiply it: the keyboard came out
1140 px wide when 845 was asked for. `PANGO_ELLIPSIZE_END` removes the floor.
The half-height arrow keys had the same problem vertically -- their legends
alone demanded more than half a row, and the whole keyboard grew from 338 px to
399 px to satisfy them, quietly destroying the 2.5:1 proportion. They get a
smaller font.

### 10.4 Landscape and portrait

Proportions are held in both; only the width changes.

* **Portrait** (600x960 logical): full width, 600x240. A quarter of the screen.
  Measured on the machine with the display rotated.
* **Landscape** (1200x750): full width would give 1200x480, nearly two thirds
  of the display. The height is capped at 45% and the keyboard is
  **letterboxed** -- 845x338, centred -- rather than stretched. Stretching is
  precisely what would stop it feeling like the real keyboard.

Keys land at ~12.8 mm across in landscape and ~11.2 mm in portrait, both well
past the ~9 mm where taps start being missed (section 5.4).

Centring is done by the compositor: the surface is anchored to the bottom edge
only and sized to 845, rather than anchored left and right and centred
internally -- a widget cannot be held narrower than its natural width, so the
internal approach does not work.

### 10.5 Sizing once is not enough

The first version read the monitor geometry at startup and never looked again,
which is wrong on the one machine it was written for: fold it and the keyboard
keeps its landscape size on a portrait screen. Measured -- 845 px wide on a
750 px display, placed at **x = -48**, hanging off the left edge, because the
compositor centres whatever size it is handed.

Layout is now recomputed from `notify::geometry` on the monitor. Rotating the
panel changes that monitor's geometry rather than replacing the monitor, so one
signal catches a fold. Verified live, in both directions, with the keyboard
open throughout:

| | surface | aspect |
|---|---|---|
| landscape | 845x338 at x=178 | 2.50 |
| portrait | 750x300 at x=0 | 2.50 |
| back to landscape | 845x338 at x=178 | 2.50 |

---

## 11. Touching a layer surface detaches keyboard focus

Reported as "swiping on the keyboard steals focus". It does, and the mechanism
is not the keyboard's.

Captured on Hyprland's event socket while it happened:

```
   6.53  activewindow>>,
   9.29  activewindow>>com.mitchellh.ghostty,...
  20.94  activewindow>>,
  22.50  activewindow>>com.mitchellh.ghostty,...
```

Focus goes to **nothing** -- not to another window -- and comes back on
release. That is `input:follow_mouse = 1` doing what it says: the surface under
the finger is a layer surface, not a window, so there is no window to focus and
the current one is dropped. A tap is too brief to notice. A swipe, or a hand
resting while typing, holds it for the whole gesture, and every key sent in
that time goes nowhere.

Ruled out first, with evidence:

* the keyboard taking focus itself -- `WAYLAND_DEBUG` shows
  `zwlr_layer_surface_v1.set_keyboard_interactivity(0)`, so it never can;
* an overlay opening -- no `openlayer` in the trace between the two events;
* a workspace gesture -- `gestures:workspace_swipe_touch` is false, and the
  workspace changes in the trace are accounted for by the user opening an app.

**Fix:** `input:follow_mouse = 2` while folded, restored on unfold. Keyboard
focus then follows clicks into windows rather than the pointer, which is what a
tablet wants anyway, and laptop behaviour is untouched. Confirmed by the user
after applying it live.

---

## 12. A resting hand breaks a touch keyboard two ways

Both seen in one sitting, and both worth writing down because neither is
obvious from the code.

**A locked modifier.** `mod_tap()` treats a second press inside the
double-tap window as "lock this modifier". The back of a hand does not make one
clean contact, so a modifier under it locks, and everything typed afterwards
silently carries Ctrl or AltGr. There is a tell -- a locked key is drawn blue --
but nothing else says so.

**A key that never comes up.** `GtkGestureClick` derives from
`GtkGestureSingle` and tracks one touch sequence at a time; a second contact on
the same key can end the first without emitting `released`. The key stays down
and the compositor repeats it. Observed output: a screenful of `ÄÄÄÄÄÄ...`,
which also shows Shift was locked at the time, i.e. both failures at once.

**Fixes.** Three contacts inside 150 ms is a hand, not fingers: drop them all,
clear every latch, and stay quiet until all contacts lift. Separately, rather
than time keys out -- holding backspace is legitimate -- the watchdog asks GTK
whether each held key's gesture is still active, and frees the key only when it
is not. That is the actual fault condition, so nothing legitimate is cut short.

---

## 13. Edge gestures without a compositor plugin

Hyprland's gesture system is trackpad only; its wiki opens with "Hyprland
supports 1:1 gestures for the trackpad". Touchscreen gestures normally mean the
`hyprgrass` plugin, which is AUR-only and, being a compositor plugin, must be
rebuilt against every Hyprland release -- the exact fragility this project set
out to avoid.

A thin layer surface per edge does the job with no plugin at all: it is an
ordinary Wayland client, so a Hyprland update cannot break it.

The placement problem solves itself with `exclusionMode: Normal` and
`exclusiveZone: 0` -- reserve nothing, but respect what others reserve. The
compositor then places each strip in whatever area is left, and no geometry has
to be duplicated or kept in step. Measured, with the keyboard occupying
y 412..750:

| surface | keyboard hidden | keyboard shown |
|---|---|---|
| `fw12-swipe-up` | y 734..750 (screen bottom) | y 396..412 (above the keyboard) |
| `fw12-swipe-down` | y 26..42 (below the bar) | unchanged |
| side strips | y 26..750 | y 26..412 (stop at the keyboard) |
| the button's window | y 26..750 | y 26..412 |

So a strip can never sit on top of a key, and the button can never be dragged
onto one.

---

## 14. A swipe strip that steps aside for the keyboard stops being a swipe strip

The side strips are placed with `exclusionMode: Normal` and `exclusiveZone: 0`
— reserve nothing, respect what others reserve — which is what lets them sit
around the bar and the keyboard without any geometry being duplicated (§13).

The cost only shows once the keyboard is up. Measured, keyboard occupying
y 412..750:

| surface | keyboard hidden | keyboard shown |
|---|---|---|
| `fw12-swipe-left` / `-right` | y 26..750 | y 26..412 |

So while the keyboard is out, the entire lower half of the display has nowhere
to start a gesture from, and the workspace and menu swipes are simply gone.
That reads as a bug, not as a boundary — nothing on screen says the live area
moved.

### The fix has to reserve space, not overlay it

The obvious repair — run the strips full height and let them sit over the
keyboard — is worse than the problem. In landscape the board is 845 px on a
1200 px screen, so a 30 px strip at each edge lands in empty space. In portrait
the board is *full width*, so the same strip covers the leftmost and rightmost
key of every row: esc, tab, shift, ctrl, fn on one side, and del, backspace,
enter, the arrows on the other.

So the keyboard gives the space up instead. `oskbd` takes the gutter width as
`argv[4]` and sizes itself to `screen_width - 2 * gutter`, and the gutters are
separate surfaces with `exclusionMode: Ignore`, which is what stops them
stepping aside like the ordinary strips do.

### What it costs, measured at 30 px

| | board | side margin | key pitch |
|---|---|---|---|
| landscape, before | 845x338 | 177 | 13.0 mm |
| landscape, after | 845x338 | 177 | 13.0 mm |
| portrait, before | 750x300 | 0 | 11.5 mm |
| portrait, after | 690x276 | 30 | 10.6 mm |

**Landscape is unchanged**, because the height cap already held the board to
845 px and left 177 px of margin — far more than the gutter needs. Only
portrait pays, and it pays 0.9 mm of key pitch, landing at 10.6 mm against the
~9 mm where taps start being missed (§5.4).

Confirmed on hardware in both orientations:

```
landscape  osk 178 412 845 338   gutters 0..30, 1170..1200
portrait   osk  30 924 690 276   gutters 0..30,  720..750
```

In portrait the gutters abut the board exactly and overlap it nowhere.

### The gutters have to say where they are

While the keyboard is hidden the whole edge works, so a marker would be
clutter. Once it is up the live area is no longer where anyone would guess, so
each gutter draws a thin bar down its middle for exactly as long as the
keyboard is out. Nobody discovers an invisible 30 px strip by accident.

---

## 15. Phase 0 for the keyboard integration (2026-09-02)

Four questions asked before any code was changed, each answered on this
machine. Same host as §0; since then the packages have moved on to
Hyprland 0.56.2 (efb5099), Quickshell 0.3.1, fcitx5 5.1.21, gtk4-layer-shell
1.3.0, GLib 2.88.3, kernel 7.1.9-arch1-2. The machine was docked (eDP-1 plus
DP-3) and in laptop mode throughout, and every scratch surface and rule below
was removed again afterwards (`hyprctl reload`, `hyprctl configerrors` empty).

### 15.1 fcitx5 runs and holds the seat's input-method-v2 slot — yes

Running, as Omarchy's own user service, with the Wayland IM addon loaded and
its virtual keyboard on the seat:

    $ pgrep -a fcitx5
    1353 /usr/bin/fcitx5 --disable notificationitem
    $ systemctl --user is-active omarchy-fcitx5.service
    active
    $ grep -c libwaylandim /proc/$(pgrep -x fcitx5)/maps
    5
    $ hyprctl devices | grep -A1 hl-virtual-keyboard
                hl-virtual-keyboard-fcitx5
                    rules: r "", m "", l "us", v "altgr-intl", o "compose:caps,shift:both_capslock_cancel"

Holding the slot was re-measured rather than carried over from §8.1. A
40-line `wayland-client` program binds `zwp_input_method_manager_v2`, calls
`get_input_method` on the seat, and reports which event comes back. (The
protocol XML came from fcitx5's own tree,
`src/lib/fcitx-wayland/input-method-v2/`, because `wlr-protocols` is not
packaged here.)

    zwp_input_method_manager_v2 advertised: yes
    get_input_method -> UNAVAILABLE: another client already holds the seat's input method (activate=0 done=0)

So the design holds: we never claim `zwp_input_method_v2`; fcitx5 keeps it.
`fcitx5-remote` prints `1` — running, no input context active — which is its
ordinary idle state.

### 15.2 `hl.layer_rule` accepts `order`, and it does nothing — no

The Lua stub (`/usr/share/hypr/stubs/hl.meta.lua`, `HL.LayerRuleSpec`)
declares `order? integer|boolean`, and the API genuinely knows the field: an
unknown one is refused, `order` is not, and a rule object comes back:

    $ hyprctl eval 'hl.layer_rule({ match = { namespace = "^x$" }, bogus_key_xyz = 5 })'
    error: ...: hl.layer_rule: unknown field 'bogus_key_xyz'
    $ hyprctl eval 'hl.layer_rule({ match = { namespace = "^x$" }, order = 5 })'
    ok                                              (hyprctl configerrors: empty)
    -- written from Lua to a file:
    HL.LayerRule(0x55fb057687d0) enabled=true type=userdata

It has no effect on stacking. Two 200x200 Quickshell `PanelWindow`s on the
overlay layer of eDP-1, `gimbal-scratch-a` (red, mapped first) and
`gimbal-scratch-b` (blue, mapped second), overlapping at (500,400); the pixel
there read back with `grim -s 1 -g "500,400 1x1" -t ppm`:

| step | rule on `gimbal-scratch-a` | applied | pixel at overlap | `hyprctl layers` |
|---|---|---|---|---|
| 1 | none | — | blue | a, b |
| 2 | `order = 5` | while both were mapped | blue | a, b |
| 3 | `order = 5` | before both were remapped | blue | a, b |
| 4 | `order = 5`, plus `order = 9` on b | while mapped | blue | a, b |
| 5 | `order = 5` before map, then the menu summoned and hidden to force a re-arrange | | blue | a, b |
| 6 | `order = -9`, re-arranged the same way | | blue | a, b |

The control that says the eval path itself works: `dim_around = true` on
`gimbal-scratch-b`, through the same `hyprctl eval`, darkened the wallpaper
pixel at (100,400) from `22 21 23` to `13 13 14` within a second, while
mapped, and stayed applied across a remap. Layer rules from Lua apply live;
`order` in particular is parsed, stored, and never consulted for stacking in
this build. Upstream issue **C** is warranted (`upstream/C-layer-rule-order.md`).

Also settled on the way: `hyprctl layers` lists each level bottom to top. In
every row above the listing agreed with the pixel, and in §15.5 both flipped
together.

### 15.3 socket2 emits `openlayer` / `closelayer` for the menu — yes

    $ socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock STDOUT &
    $ omarchy-shell shell summon omarchy.menu '{}'; sleep 1.5; omarchy-shell shell hide omarchy.menu
    openlayer>>omarchy-menu
    closelayer>>omarchy-menu

Nothing else fired for the menu itself. Two side facts from the same capture:
the menu maps on the *focused* monitor (DP-3, where the terminal was), and
fcitx5's own virtual keyboard emits an `activelayout` pair as the menu takes
and releases keyboard focus, so anything reacting to `activelayout` still has
to de-duplicate, as §3.1g found.

### 15.4 The fcitx5 "DBus Virtual Keyboard" addon, and its exact contract — present

    $ grep -E '^(Library|Category|OnDemand|UIType|Version)' /usr/share/fcitx5/addon/virtualkeyboard.conf
    Library=libvirtualkeyboard
    Category=UI
    Version=5.1.21
    OnDemand=True
    UIType=OnScreenKeyboard

The contract below is read from fcitx5's own source at the same version
(`src/ui/virtualkeyboard/virtualkeyboard.cpp`, cloned read-only into a
scratch directory), not from `strings`. It agrees with what §3.1a captured
live and with the two reference clients: `fcitx5-osk` (`src/dbus/server.rs`,
which cites the same file), and `fcitx-virtualkeyboard-adapter`, which turned
out to be an fcitx5 *addon* that runs a shell command on IM activate and
deactivate rather than a client of this interface — a comparison for the
event source, not for the protocol.

**What we own.** Bus name `org.fcitx.Fcitx5.VirtualKeyboard`, object
`/org/fcitx/virtualkeyboard/impanel`, interface
`org.fcitx.Fcitx5.VirtualKeyboard1`. fcitx5 calls these on us, each as a
plain method call it never waits on (`createMethodCall(...).send()`):

| method | in | meaning |
|---|---|---|
| `ShowVirtualKeyboard` | — | map |
| `HideVirtualKeyboard` | — | unmap |
| `NotifyIMActivated` | `s` | IM unique name, e.g. `keyboard-us` |
| `NotifyIMDeactivated` | `s` | same |
| `NotifyIMListChanged` | — | the IM group changed |
| `UpdatePreeditArea` | `s` | preedit text |
| `UpdatePreeditCaret` | `i` | caret index, `-1` for none |
| `UpdateCandidateArea` | `asbbii` | candidates, hasPrev, hasNext, pageIndex, cursor |

**What fcitx5 owns**, object `/virtualkeyboard` on `org.fcitx.Fcitx5`:

| interface | method | in | exported |
|---|---|---|---|
| `org.fcitx.Fcitx.VirtualKeyboard1` | `ShowVirtualKeyboard`, `HideVirtualKeyboard`, `ToggleVirtualKeyboard` | — | always (§3 introspected it) |
| `org.fcitx.Fcitx5.VirtualKeyboardBackend1` | `ProcessKeyEvent` | `uuubu` | only while the addon is resumed |
| | `ProcessVisibilityEvent` | `b` | " |
| | `SelectCandidate` | `i` | " |
| | `PrevPage`, `NextPage` | — | " |
| | `SetVirtualKeyboardFunctionMode` | `u` | " |

**How activation works, from the source.** fcitx5 watches our bus name with
a `ServiceWatcher`; the addon is `available_` exactly while someone owns it.
`ShowVirtualKeyboard` on `/virtualkeyboard` is `showVirtualKeyboardForcibly()`:
it sets `InputMethodMode::OnScreenKeyboard`, which makes
`UserInterfaceManager::updateAvailability()` switch the UI addon to
`virtualkeyboard` (what `CurrentUI` reports) and call `resume()` — and only a
resumed addon exports the backend interface and turns focus-in and focus-out
into `ShowVirtualKeyboard` / `HideVirtualKeyboard` on us. That is the "two
conditions" of §3.1, with the mechanism attached. Nothing in `~/.config/fcitx5`
has to change for it: the addon is `OnDemand` and loads when asked.

**How it leaves that mode, from the source.** `resume()` installs a
`PreInputMethod` watcher on `InputContextKeyEvent`: any key whose state lacks
`KeyState::Virtual` calls `setInputMethodMode(PhysicalKeyboard)`, the UI
switches back to `classicui`, and `suspend()` sends one `HideVirtualKeyboard`
on the way out. Keys injected through `ProcessKeyEvent` are stamped `Virtual`
(`VirtualKeyboardEvent::toKeyEvent`); keys arriving through the compositor —
ours, over `zwp_virtual_keyboard_v1` — are not. This is §3.1j's "our own
typing hides it", now with the line of code behind it. There is **no
configuration switch**: `virtualKeyboardAutoShow_` and `AutoHide_` have
setters and nothing in the tree calls them. So the first rung of the Phase 3
mitigation ladder is empty, and the second — ignore a Hide inside a grace
window after our own key, and re-assert — is the one to measure.

**One claim in §3.1h does not survive the source.** `ProcessVisibilityEvent`
is `void processVisibilityEvent(bool) {}` in 5.1.21 — a no-op. §3.1h saw
fcitx5 revert when it was not sent; whatever caused that, it was not this
method. Re-measured in Phase 3 (§16) before anything depends on it either way.

### 15.5 Restacking without unmapping: a live `set_layer` bounce works

With `order` inert, the brief's fallback is a remap on
`openlayer>>omarchy-menu`. Something cheaper was tried first: layer-shell v2+
lets a mapped surface change layer, and Hyprland puts a surface that changes
layer at the top of its new one. Same two scratch surfaces, `a` under `b`;
at t=6 s `a` set `WlrLayershell.layer = WlrLayer.Top`, at t=6.5 s back to
`WlrLayer.Overlay`:

    t=5.8  overlap: 0 0 255     hyprctl layers: a, b
    t=8    overlap: 255 0 0     hyprctl layers: b, a

No unmap, no exclusive-zone reflow, no `openlayer`/`closelayer` event. The
two `set_layer` requests have to land in *separate* commits — Hyprland only
moves a surface when the committed layer differs from the one it holds —
which is why it is two steps and not one. This is the Phase 1 mechanism, for
the keyboard above the menu and for the knobs above the keyboard now that
both live on the overlay layer.

---

## 16. Phase 2: a resident keyboard, measured (2026-09-02)

The keyboard became a long-running process, started on fold and killed on
unfold, shown and hidden by signal (`SIGUSR1` maps, `SIGUSR2` unmaps), and
publishing `visible` or `hidden` to `$XDG_RUNTIME_DIR/gimbal-osk` from its
own map and unmap. Numbers from this machine, docked, with the fold
simulated through the same file `fw12-foldstate` feeds the Lua (§16.2).

### 16.1 The state file's writer, and its readers

`g_file_set_contents()` renames a complete file into place, so no reader can
see a half-written word. The open question was whether a Quickshell
`FileView` with `watchChanges: true` survives that rename, since a watcher
on an inode does not. Measured with a scratch FileView logging every load:
in-place write, rename-over, rename-over, in-place write — four changes,
four loads, in order. It survives.

### 16.2 Simulating a fold without a hinge

The Lua reads `$XDG_RUNTIME_DIR/gimbal-fold` every ~5 s, and that file is
exactly what `fw12-foldstate` writes on its behalf, so writing `1 event3`
into it is the same pipeline a real fold goes through. It self-corrects —
the Lua immediately asks `fw12-foldstate` again, which answers `0` — so the
word is rewritten every 400 ms for as long as the simulated fold should
hold, then `0 event3` once. Rotation is locked first
(`require("hypr.gimbal").set_locked(true)`): `enter_tablet` takes one
accelerometer sample regardless of the lock, but applying needs two
agreeing ticks and the lock stops the second. The accelerometer read
`y=+15040` (normal) throughout anyway, so nothing would have moved.

### 16.3 What the brief asked for, measured

Standalone, the binary run from the build directory:

    start (no argv[5])   procs=1  state=hidden   mapped=0
    SIGUSR1              state=visible  mapped=1        (within 500 ms)
    SIGUSR2              state=hidden   mapped=0
    20 toggles, 100 ms apart, file checked after each:   0 mismatches
    20 toggles back-to-back, then 600 ms:   state=hidden  mapped=0  procs=1
    SIGTERM              procs=0  state=hidden
    start with "shown"   state=visible  mapped=1

Through the plugin, with the fold simulated:

    folded              mode=tablet procs=1 state=hidden  mapped=0 follow_mouse=1
    plugin toggle       mode=tablet procs=1 state=visible mapped=1 follow_mouse=2
    plugin toggle       mode=tablet procs=1 state=hidden  mapped=0 follow_mouse=1
    20 toggles by signal, 350 ms apart, file AND follow_mouse checked after each:  0 mismatches
    shown, then unfold  mode=laptop procs=0 state=hidden  mapped=0 follow_mouse=1
    laptop, SUPER+B path (plugin toggle)   procs=1 state=visible mapped=1 follow_mouse=1
    and again                              procs=0 state=hidden

So: repeated show and hide leave exactly one process; the state file tracks
visibility through 20 rapid toggles; `follow_mouse` is 2 exactly while
visible and folded; and no process survives an unfold, keyboard up or not.
The plugin's log no longer reports `fw12-oskbd exited 15` on unfold — the
daemon now leaves on `SIGTERM` with status 0 after releasing its modifiers.

Two smaller facts from the same run: the daemon dies with its parent
(`PR_SET_PDEATHSIG`), so `omarchy-restart-shell` cannot leave a second one
behind; and in laptop mode nothing is resident until `SUPER+B` asks, after
which the process lives exactly as long as the keyboard is on screen.

---

## 17. Phase 3: appearing by itself, measured (2026-09-02)

The brief's known risk was tested before any daemon code was written, with
the spy from §3.1a (`tools/vkspy.c` in git history: owns the bus name, calls
`ShowVirtualKeyboard`, logs every call fcitx5 makes on the client object and
replies to it). Keys were injected with a 40-line `zwp_virtual_keyboard_v1`
client that uploads the system keymap and sends one evdev code, exactly as
`fw12-oskbd` does. `CurrentUI` is the method on
`org.fcitx.Fcitx.Controller1`, as in §3.1j.

### 17.1 The risk is real: one key from a virtual keyboard hides it

    spy registered                          CurrentUI=virtualkeyboard
    foot window focused                     <- NotifyIMActivated("keyboard-us"), ShowVirtualKeyboard
    wtype a  (a second virtual keyboard)    <- HideVirtualKeyboard        CurrentUI=classicui
    ShowVirtualKeyboard on /virtualkeyboard <- ShowVirtualKeyboard        CurrentUI=virtualkeyboard
    wtype abc (three keys)                  <- HideVirtualKeyboard, once  CurrentUI=classicui

Exactly as the source predicts (§15.4): the first non-`Virtual` key flips
the input-method mode, the UI switches to `classicui`, and the addon's
`suspend()` sends one Hide. Re-asserting with `ShowVirtualKeyboard` is a
complete recovery. Three keys in a row cost one Hide, because after the
first the addon is suspended and its key watcher is gone with it.

### 17.2 `ProcessVisibilityEvent` is not needed

The spy never sends it. Registered, 8 s of nothing: `CurrentUI` still
`virtualkeyboard`, and the foot focus afterwards still produced a Show. The
daemon does not send it. Whatever §3.1h saw, it was not this.

### 17.3 The Omarchy menu is not a text field, as far as fcitx5 can tell

With foot focused and the keyboard shown, summoning the menu produced:

    <- NotifyIMDeactivated("keyboard-us")   (foot lost focus)
    <- HideVirtualKeyboard
    <- NotifyIMActivated("keyboard-us")     (the menu's input context)
    ... and no ShowVirtualKeyboard

The menu is a Qt window whose search is a key catcher (`Keys.onPressed` on
an `Item`, `Menu.qml`), not a `TextInput`, so Qt never asks its input method
to show. fcitx5-qt activates an input context for the window and that is
all. Hiding the menu refocused foot and a Show came back. So the daemon
treats `openlayer>>omarchy-menu` as a text field taking focus, on the same
gate, and `closelayer>>omarchy-menu` as it losing focus.

### 17.4 Releasing the name leaves fcitx5 with no user interface

    spy stopped (HideVirtualKeyboard, then the name released)    CurrentUI=''
    wtype z into foot                                             CurrentUI=''

§3.2 saw the empty `CurrentUI` and blamed the release. The source says why
and adds the worse half: `isUserInterfaceValid()` accepts `classicui` only
in `PhysicalKeyboard` mode, the mode is still `OnScreenKeyboard`, and the
one thing that flips it back — the key watcher — lives in the addon that
was just suspended. So a later hardware key does not repair it either; only
a restart of fcitx5 did, until now.

The repair is to flip the mode *before* letting go, and a key with no
symbol on it does that without typing anything:

    spy registered, foot focused
    vkraw 0    (KEY_RESERVED, xkb 8, NoSymbol)     <- HideVirtualKeyboard   CurrentUI=classicui
    re-asserted                                                             CurrentUI=virtualkeyboard
    vkraw 240  (KEY_UNKNOWN, xkb 248, NoSymbol)    <- HideVirtualKeyboard   CurrentUI=classicui
    re-asserted, then vkraw 240, then the spy stopped                       CurrentUI=classicui

foot, running `cat >/dev/null`, was still alive afterwards. `fw12-oskbd`
sends evdev 240 on `SIGTERM`, waits 80 ms, and releases the name; it also
ignores the Hide that key provokes. Measured at the end of every run below:
`CurrentUI=classicui` after unfold. What nothing can repair is a `SIGKILL`;
`systemctl --user restart omarchy-fcitx5.service` is the way back then.

### 17.5 Which text fields ask for the keyboard

| client | mechanism | Show arrives | keys arrive |
|---|---|---|---|
| foot | `zwp_text_input_v3` → waylandim | yes | yes (§3.1e) |
| GTK4 entry (`tools/typetarget.c`, git history) | `zwp_text_input_v3` → waylandim | yes | yes: `hi` logged from evdev 35, 23 |
| Omarchy menu | fcitx5-qt D-Bus frontend | no (§17.3) | yes, by the menu filtering (checkpoint) |
| a Quickshell `TextInput` in a scratch window | fcitx5-qt D-Bus frontend | not measured: the field never took focus (`activeFocus=false`), only the window's context activated | — |
| ghostty | — | not installed here (`extra/ghostty 1.3.1-2`); §3.1f saw it fire, KNOWN-ISSUES had it absent | — |

The Qt and ghostty rows are on the hands-on checklist.

### 17.6 The daemon, end to end

Installed, folded through §16.2's simulation, rotation locked. `st` prints
the state file, whether `fw12tab-osk` is mapped, `CurrentUI`, and who owns
the bus name.

| step | result |
|---|---|
| folded | procs=1 state=hidden mapped=0 CurrentUI=virtualkeyboard owner=fw12-oskbd |
| a GTK4 entry took focus | state=visible mapped=1 |
| a non-text window took focus (Quickshell, exclusive keyboard focus) | state=hidden after ~300 ms |
| `SIGUSR1`, then the non-text window | state=visible — a user-summoned board stays |
| `SIGUSR2` there | state=hidden |
| menu summoned with the non-text window focused | state=visible, `fw12tab-osk` listed above `omarchy-menu` |
| menu hidden, back to the non-text window | state=hidden after ~300 ms |
| non-text window closed, entry focused | state=visible |
| `autoShow: false` written to `gimbal.json` | plugin wrote `gimbal-autoshow=off`; the same focus churn left it hidden |
| restored | `gimbal-autoshow=on` |
| unfold | procs=0 state=hidden CurrentUI=classicui owner=(none) |

### 17.7 The grace window, through the daemon's own keys

A key from a second virtual keyboard is correctly not "ours" — in the run
above such a key hid the board, and no Show came again until the next
summon (§17.8). To measure the real path the daemon taps a key through its
own press and release code 700 ms after each map when
`FW12_OSKBD_SELFTEST_KEY=<evdev>` is set (never by the plugin):

    entry focused, map, tap 'a' at +700 ms
    +200 ms after the tap:   state=visible mapped=1 CurrentUI=virtualkeyboard entry='a'
    +800 ms:                 unchanged
    SIGUSR2, SIGUSR1, tap again at +700 ms:   state=visible  CurrentUI=virtualkeyboard  entry='aa'
    then a non-text window:  state=visible (user-summoned stays)
    SIGUSR2, entry refocused (auto), then the non-text window:   state=hidden

So the Hide fcitx5 sends for our own key arrives inside the window, is
ignored, and the re-assert has fcitx5 back in on-screen mode before the
next thing happens. Auto-hide is intact afterwards.

### 17.8 A hardware keyboard turns auto-show off until the next summon

That is fcitx5's design, not a defect: a key it did not inject means the
user has a keyboard, so it stops offering an on-screen one. While folded the
built-in keyboard is off (§1.6), so the case is a Bluetooth keyboard — and
then not popping the on-screen keyboard is right. The daemon re-asserts
on every `SIGUSR1`, so one knob tap brings auto-show back, and a fold
restarts the daemon, which registers afresh. There is no poll for it.

---

## 18. Phase 4: the lock screen keypad, validated without locking (2026-09-02)

The session was never locked. Two things were checked instead.

### 18.1 The modified `LockView` renders, in both modes

A scratch Quickshell config hosting `lock-clone/LockView.qml` inside a
full-screen `PanelWindow` on eDP-1, with Omarchy's `Commons` and `Ui`
symlinked in so `qs.Commons` and `qs.Ui` resolve exactly as in the shell.
`grim -o eDP-1` after 3.5 s, each time:

| `gimbal-mode` says | `keypadOpen` | what rendered |
|---|---|---|
| `laptop` (the real file) | set true by the harness | the stock field with its dots and nothing else — `onFoldedChanged` had already cleared `keypadOpen`, which is the laptop-mode guarantee working |
| `tablet` (a fake file the harness points `gimbalModePath` at) | true | the field, and below it five rows of keys, 900 logical px wide at x 150, y 442..726 on the 750-tall panel: `1..0`, `q..p`, `a..l`, `⇧ z..m ⌫`, `?123 [space] ⏎ ⌄` |

The first render of the keypad had every key invisible: `Color.lock.background`
is the page background in the stock theme (`#1a1b26`), and a key face painted
in it is not there. Faces are a 14 % tint of `Color.lock.text` with a 28 %
edge now; the second screenshot is the one described above.

The harness log carried no QML error either time; the one warning is
Quickshell's file scanner declining to follow an absolute `import` URL,
which the engine itself resolved.

### 18.2 The live clone

`omarchy plugin clone omarchy.lock` created `~/.config/omarchy/plugins/msa.lock`
with `clonedFrom: omarchy.lock`, enabled it, and disabled the built-in
(`shell.json`: `plugins: [msa.lock]`, `disabledPlugins: [omarchy.lock]`).
The two edited files were copied in; the shell logged
`Local plugin changed, reloading: msa.lock` and nothing else.

    $ omarchy-shell lock status
    {"locked":false,"requested":false,"pending":false,"sessionLocked":false,"secure":false,"realScreens":2,"passwordPam":true,"fingerprint":false,...}
    $ omarchy-shell lock preview      # then grim -o DP-3; then hidePreview
    the stock view: blurred wallpaper, "Enter Password", no keypad (laptop mode)

`fingerprint: false` — no fingerprint is enrolled on this machine, so that row
of the checklist cannot be done here.

### 18.3 What only a lock can tell

Whether taps reach the keypad under `ext-session-lock`, whether the
`MouseArea` on the field opens it, the wrong-password state with the keypad
up, the idle-blank interplay, and portrait. All on the hands-on list; the
clone is the stock code for everything the keypad does not touch.

---

## 19. Hands-on report, and what it turned out to be (2026-09-02)

Two reports from the first real test, both reproduced or explained on this
machine the same afternoon.

### 19.1 "Opening the menu brings the keyboard up, and a key press closes the menu"

Not stacking. Reproduced in every ordering — keyboard shown for the menu,
keyboard re-shown then the menu, and the user's exact sequence twice — the
keyboard is listed above `omarchy-menu` in `hyprctl layers`, and a pixel on a
key face reads `43 43 43` with the menu open exactly as without it, while a
pixel beside the keyboard goes from wallpaper to scrim. A key injected while
the menu is open, from a second virtual keyboard or through the daemon's own
key path, filters the menu and does not close it (`closelayer` never fires).

What closes it is the *touch*. Hyprland 0.56.2's `mouseMoveUnified()`
(`src/managers/input/InputManager.cpp`, fetched at tag `v0.56.2`), which
`onTouchDown()` calls through `refocus()`:

    // forced above all
    if (!g_pInputManager->m_exclusiveLSes.empty()) {
        if (!foundSurface) foundSurface = ...layerPopupSurfaceAt(mouseCoords, &m_exclusiveLSes, ...);
        if (!foundSurface) foundSurface = ...layerSurfaceAt(mouseCoords, &m_exclusiveLSes, ...);
        if (!foundSurface) foundSurface = (*m_exclusiveLSes.begin())->wlSurface()->resource();
    }

and `m_exclusiveLSes` is exactly the mapped layer surfaces whose keyboard
interactivity is `EXCLUSIVE` (`LayerSurface.cpp` lines 185–188, 382–387).
The Omarchy menu is `WlrKeyboardFocus.Exclusive`. So while it is open, every
pointer and touch event on that monitor goes to the menu, before the
compositor looks at what is drawn above it — the keyboard, the knobs,
anything. The finger lands on the menu's full-screen `MouseArea`, which is
`onClicked: root.cancel()`. Stacking never entered into it, which is why
Phase 1's measurements passed and the finger failed.

**An on-demand layer is not in that list, and loses nothing.** Measured with
a scratch full-screen overlay `PanelWindow` carrying a key catcher, once as
`Exclusive` and once as `OnDemand`, a key injected over
`zwp_virtual_keyboard_v1` after it mapped:

    exclusive:  activeFocus=true   key text='a'
    ondemand:   activeFocus=true   key text='a'

`LayerSurface.cpp` line 190 is why: on map, `GRABSFOCUS` is true for any
interactivity other than `NONE`, so an on-demand layer takes keyboard focus
exactly as an exclusive one does. And a touch on the keyboard afterwards
does not move focus away from it: line 733 refocuses onto a layer surface
only if that surface's interactivity is not `NONE`, and the keyboard's is
`NONE`. The whole fix, then, is one word in `plugins/menu/Menu.qml`:

    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

That file is Omarchy's. Draft **D** asks for it upstream; a clone
(`omarchy plugin clone omarchy.menu`) with the same one-word change is the
local version, and it is a decision for the owner of the machine, not for
this repo. Nothing on our side can route a touch past an exclusive layer:
the only surfaces Hyprland consults before that list are input-method
popups, its own permission windows, and the session lock. Making the
keyboard exclusive too would win the touch and lose the keys, since
Hyprland would then focus the keyboard's own surface and the typed keys
would go to it.

### 19.2 "Locked in laptop mode, then folded: no keypad"

The fold did reach the lock screen: the shell log has `lock-requested` at
12:03:48 and `unlocked` at 12:04:12, and `gimbal-mode` was last rewritten at
12:04:09 — an unfold, under lock, which means the fold before it was seen
and acted on. What did not happen was a tap on the field, or the tap did not
open the keypad; the journal cannot say which, because nothing logged. So
the keypad now opens by itself the moment the mode says `tablet` — locked
first and folded second is the case with no other way in — and logs one
line per fold change and per open, in the lock service's own voice. Rendered
in the harness: keypad up with the mode faked to `tablet`, stock view with
`laptop`. Whether a touch reaches the keypad under `ext-session-lock` is
still a hands-on question; the log will now say whether the fold arrived.

### 19.3 Both, fixed and measured with a pointer instead of a finger

Hyprland advertises `zwlr_virtual_pointer_v1`, so a 60-line client
(`create_virtual_pointer_with_output` on eDP-1, `motion_absolute`, one
`BTN_LEFT` press and release) can put a click exactly where a finger would
go, and a click takes the same `refocus()` path through `mouseMoveUnified()`
that a touch does. The `a` key sits at (296, 602) on the 1200x750 panel with
the keyboard at 178,412 845x338.

**The failure, reproduced.** Folded, the stock (exclusive) menu summoned,
the keyboard shown for it, one click on `a`:

    openlayer>>omarchy-menu
    openlayer>>fw12tab-osk
    closelayer>>omarchy-menu          <- the click
    closelayer>>fw12tab-osk           <- the keyboard follows, 300 ms later

**The fix, measured.** `omarchy plugin clone omarchy.menu`, one word in the
clone (`WlrKeyboardFocus.OnDemand`), `omarchy-restart-shell`. Same fold,
same menu route, clicks on `a` then `s`, then one on the scrim at (100, 380):

    after a, s:   menu open, keyboard visible, no closelayer
    screenshot:   the card's header reads "as", rows filtered to 1Password, Basecamp, JavaScript, Password
    after scrim:  closelayer>>omarchy-menu, keyboard hidden 300 ms later

So a click on the keyboard types into the menu and a click beside it still
dismisses the menu, which is the whole contract. The clone is mirrored in
`menu-clone/` as a verbatim commit plus the one-word commit.

**The lock screen was never running the new code.** The shell process had
started at 10:36:21, before the clone at 10:45 and every edit after it. A
saved plugin file is hot-reloaded, but Qt caches compiled components by URL
and the already-loaded `LockView` kept its stock code — §3.1i, again, and it
cost two test rounds. After `omarchy-restart-shell`, the live clone's view
in `omarchy-shell lock preview` under a simulated fold logged

    gimbal lock: folded=true inputEnabled=false
    gimbal lock: keypadOpen=true

and drew the keypad; on unfold, `folded=false`, `keypadOpen=false`. Both
READMEs now say the restart is not optional.

**The overlap for upstream draft A**, measured on the way: with the keyboard
hidden the root menu card spans y 85..665 on the 750-tall panel (bright rows
at the centre column of a `grim -s 1` capture). The keyboard's top edge is at
y 412, so 253 px of a 580 px card sit under it — the keyboard covers the
card's last rows, and with the keyboard up the row "Password" is cut in half
by it.

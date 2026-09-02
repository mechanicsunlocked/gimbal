# What to ask upstream for, in the order it matters

Gimbal works today, with two clones of Omarchy's own plugins and one
compositor workaround. Each of the drafts here would remove one of those.
Every claim in them is measured in `FINDINGS.md`; the section is named.

| # | Ask | Of | What it removes | Size of the change |
|---|---|---|---|---|
| **D** | The menu (and the other full-screen overlays) take keyboard focus *on demand*, not exclusively. Hyprland routes every touch to an exclusive-focus layer before hit-testing anything above it, so no on-screen keyboard can type into the menu (FINDINGS 19.1, 19.3). | Omarchy | the whole `menu-clone/` | one word in `Menu.qml` |
| **B** | A slot in the lock screen for a keyboard, or a replaceable `lock` kind. Under `ext-session-lock` nothing but the lock screen is drawn or touchable, so the keypad has to be part of it, and a plugin cannot get there (FINDINGS 18). | Omarchy | the whole `lock-clone/`, and the risk of a fork of the lock screen drifting behind upstream | a `Loader` and four properties, or a new kind |
| **A** | The menu respects layer-shell exclusive zones, so its card stops above a keyboard instead of running 253 px under it (FINDINGS 19.3). | Omarchy | the cut-off bottom rows of a long menu | `ExclusionMode.Normal` on the overlay window |
| **C** | The Lua `layer_rule` `order` field does what it says. It is accepted and inert (FINDINGS 15.2). | Hyprland | the `set_layer` bounce the keyboard and the knobs do to stay on top | a compositor fix |
| — | Bar touch targets in tablet mode: the bar is 6.9 mm tall on this panel and a missed tap opens the wallpaper picker (FINDINGS 5.4). | Omarchy | mis-taps | a larger hit area when a touchscreen is present |

**If only one thing were to change, it is D.** It is one word, it costs the
menu nothing measurable, and it is the difference between a tablet that can
use the menu and one that cannot. B is the next: a lock-screen fork is the one
piece of this that a user should not have to carry.

Everything Gimbal does on its own side — rotation, the resident keyboard,
auto-show through fcitx5, the knobs — needs nothing from upstream and would
stay exactly as it is.

## Filing them

Each draft is complete and self-contained: copy it into a new issue on the
project it names. For **B**, attach or link `lock-clone/` as the proof of
shape. Draft **C** goes to `hyprwm/Hyprland`; the others to `basecamp/omarchy`.

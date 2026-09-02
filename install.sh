#!/bin/bash
# Gimbal -- install everything except the optional root boot fix.
#
# No sudo, no install hooks, nothing outside $HOME. Idempotent: running it
# twice is the same as running it once, and it is also how you upgrade.
#
# Five parts, and they are genuinely separate pieces of software:
#
#   1. fw12-oskbd    the keyboard          -> ~/.local/bin
#      (plus a check that fcitx5 can drive it; nothing of fcitx5's is edited)
#   2. gimbal.lua  rotation           -> ~/.config/hypr, plus one require
#                                             line in hyprland.lua
#   3. the shell plugin  knobs + bar icons -> ~/.config/omarchy/plugins/<id>
#   4. clones of Omarchy's own plugins    -> ~/.config/omarchy/plugins/<you>.lock
#      (the lock-screen keypad, and the       ~/.config/omarchy/plugins/<you>.{menu,polkit,
#      one-word fix that lets a touch on        emojis,clipboard,reminders}
#      the keyboard reach the menu, the
#      password prompt and the pickers;
#      asked first)
#   5. the boot fix                        -> root, printed at the end, skipped
#                                             here
#
# Run it from a git clone, or from the plugin directory after
# `omarchy plugin add` -- it works out which it is and does not copy the
# plugin over itself. `-y` answers yes to the one question it asks.
set -euo pipefail

PLUGIN_ID="io.github.mechanicsunlocked.gimbal"
here=$(cd "$(dirname "$0")" && pwd)
plugin_dir="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
warnings=()

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { warnings+=("$*"); printf '    \033[33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0; }
assume_yes=0; [[ ${1:-} == -y || ${1:-} == --yes ]] && assume_yes=1

ask() {   # ask "question" -> 0 for yes; -y answers yes, a non-terminal answers no
    (( assume_yes )) && return 0
    [[ -t 0 ]] || return 1
    local a; read -r -p "    $1 [Y/n] " a; [[ -z $a || $a == [Yy]* ]]
}

# --------------------------------------------------------------------------
# 0. Dependencies
#
# All of these are in the official repositories (core/extra). Nothing here
# wants the AUR, and the script will not reach for it.
# --------------------------------------------------------------------------
say "Checking dependencies"
missing=()
for pkg in gtk4 gtk4-layer-shell libxkbcommon wayland pkgconf gcc; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    die "missing packages: ${missing[*]}
    All are in the official repos:
        sudo pacman -S --needed ${missing[*]}"
fi
note "all present"

command -v omarchy-shell >/dev/null 2>&1 || die "omarchy-shell not found; this needs Omarchy 4."

# --------------------------------------------------------------------------
# 1. The keyboard and the fold-switch reader
# --------------------------------------------------------------------------
say "Building and installing fw12-oskbd"
make -C "$here/osk" --no-print-directory
make -C "$here/osk" --no-print-directory install
note "$HOME/.local/bin/fw12-oskbd"

# Reads SW_TABLET_MODE as a level, which is what stops a missed switch event
# from latching the wrong mode. Rotation still works without it -- the hinge
# angle is the fallback -- so a build failure here is not fatal to the install.
say "Building and installing fw12-foldstate"
if make -C "$here/tools" --no-print-directory && make -C "$here/tools" --no-print-directory install; then
    note "$HOME/.local/bin/fw12-foldstate"
else
    warn "fw12-foldstate did not build; folding falls back to the hinge angle (noticed within five seconds)"
fi

# The plugin starts the keyboard by name, so it has to be findable in the
# environment omarchy-shell inherited -- which is the session's, not this
# shell's. A PATH that is fine here and wrong there is the one failure of this
# script that would look like a broken button rather than a missing directory.
session_path=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p' | tail -n 1)
: "${session_path:=$PATH}"
case ":${session_path}:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "$HOME/.local/bin is not on the session's PATH; the knobs will not find the keyboard.
             Add it to ~/.config/environment.d/ (or ~/.config/uwsm/env) and log out and in." ;;
esac

# --------------------------------------------------------------------------
# 1b. fcitx5, which is how the keyboard learns that a text field took focus
#
# Nothing is changed here, and nothing needs to be: the keyboard registers
# with fcitx5's "DBus Virtual Keyboard" addon over the session bus at runtime,
# and that addon is on demand -- it loads when asked and is left alone
# otherwise (FINDINGS 15.4). What this checks is that the pieces exist, and
# says exactly what to do if one does not, because a missing piece here would
# otherwise show up as a keyboard that never appears by itself.
# --------------------------------------------------------------------------
say "Checking fcitx5 for auto-show"
if [[ -f /usr/share/fcitx5/addon/virtualkeyboard.conf ]]; then
    note "DBus Virtual Keyboard addon present ($(pacman -Q fcitx5 2>/dev/null || echo fcitx5))"
else
    warn "fcitx5's virtualkeyboard addon is missing; the keyboard will not appear by itself.
             It ships in the fcitx5 package:  sudo pacman -S --needed fcitx5"
fi
fcitx_conf="$HOME/.config/fcitx5/config"
if [[ -f $fcitx_conf ]] && { grep -qs '^DisabledAddons=.*virtualkeyboard' "$fcitx_conf" \
        || sed -n '/^\[Behavior\/DisabledAddons\]/,/^\[/p' "$fcitx_conf" | grep -qE '^[0-9]+=virtualkeyboard$'; }; then
    warn "virtualkeyboard is listed in DisabledAddons in ~/.config/fcitx5/config.
             Auto-show needs it. Not changed here -- that file is yours. To allow it,
             remove 'virtualkeyboard' from that line (or drop the line) and run:
                 fcitx5-remote -r"
else
    note "addon not disabled in ~/.config/fcitx5/config"
fi
if pgrep -x fcitx5 >/dev/null 2>&1; then
    note "fcitx5 is running"
else
    warn "fcitx5 is not running; Omarchy starts it as omarchy-fcitx5.service.
             Auto-show waits for it and works once it is up."
fi

# --------------------------------------------------------------------------
# 2. Rotation
# --------------------------------------------------------------------------
say "Installing the rotation module"
install -Dm644 "$here/lua/gimbal.lua" "$HOME/.config/hypr/gimbal.lua"
note "$HOME/.config/hypr/gimbal.lua"

hl="$HOME/.config/hypr/hyprland.lua"
if [[ ! -f $hl ]]; then
    warn "no $hl -- add this line to your Hyprland config by hand:
             require(\"hypr.gimbal\")"
elif grep -q 'require("hypr.gimbal")' "$hl"; then
    note "already required from hyprland.lua"
else
    cat >>"$hl" <<'LUA'

-- Framework 12 tablet mode and auto-rotation (gimbal).
require("hypr.gimbal")
LUA
    note "added the require line to hyprland.lua"
fi

# --------------------------------------------------------------------------
# 3. The plugin
#
# `omarchy plugin add` has already put the whole repo here, in which case
# copying it onto itself is at best pointless. Detect that by inode, not by
# path text, so a symlinked or differently-spelled clone is still recognised.
# --------------------------------------------------------------------------
say "Installing the shell plugin"
if [[ -d $plugin_dir ]] && [[ $here -ef $plugin_dir ]]; then
    note "already installed here by 'omarchy plugin add'"
else
    mkdir -p "$plugin_dir"
    install -Dm644 "$here/manifest.json" "$plugin_dir/manifest.json"
    install -Dm644 "$here/Panel.qml"     "$plugin_dir/Panel.qml"
    install -Dm644 "$here/BarWidget.qml" "$plugin_dir/BarWidget.qml"
    note "$plugin_dir"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || warn "rescanPlugins failed; is the shell running?"
if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" \
        'any(.[]; .id == $id and .enabled == true)' >/dev/null 2>&1; then
    note "already enabled"
else
    omarchy-plugin-enable "$PLUGIN_ID" >/dev/null 2>&1 \
        || omarchy-shell shell setPluginEnabled "$PLUGIN_ID" true >/dev/null 2>&1 \
        || warn "could not enable the plugin; run: omarchy plugin enable $PLUGIN_ID"
    note "enabled"
fi

# --------------------------------------------------------------------------
# 4. The clones
#
# Two things cannot live inside this plugin, and both are one small change to
# plugins Omarchy already ships:
#
#   * the lock screen: under a session lock only the lock screen itself is
#     drawn or touchable, so its keypad has to be part of the lock screen;
#   * the typed overlays -- the menu, the polkit password prompt, the emoji
#     and clipboard pickers, the reminder prompt: Hyprland sends every touch
#     to a surface with *exclusive* keyboard focus, whatever is drawn above
#     it, so a finger on the keyboard lands on them instead. While folded they
#     take focus on demand instead, and typing works unchanged (FINDINGS
#     19.3). Only while folded: on demand also lets a mouse on a second
#     monitor take the focus away, which is a laptop problem, so laptop mode
#     keeps Omarchy's exclusive focus exactly.
#
# The changes are applied to the clone's own, current files -- a patch for the
# lock view, an edit for the overlays -- never copied over them, so an Omarchy
# update that changes one of those files is noticed rather than clobbered.
#
# Omarchy's answer for editing a built-in plugin is `omarchy plugin clone`,
# which copies it to ~/.config/omarchy/plugins/<you>.<name> and switches to
# the copy; removing the copy switches back. Nothing outside $HOME, and
# reversible with `omarchy plugin remove`. Asked, because it does replace
# things you may have edited yourself.
# --------------------------------------------------------------------------
say "The lock-screen keypad, and typing into the menu and the prompts"
me=${USER:-$(id -un)}
clone_dir="$HOME/.config/omarchy/plugins"
# plugin:entry-file for the one-word change
typed_overlays="menu:Menu.qml polkit:PolkitAgent.qml emojis:Emojis.qml clipboard:Clipboard.qml reminders:ReminderFlow.qml"
note "these clone Omarchy's lock screen, menu, polkit prompt, emoji and clipboard pickers"
note "and reminder prompt into $clone_dir/$me.<name>, each with a small change"
# The one edit every typed overlay gets: its keyboard focus follows the fold
# state Gimbal publishes, and a Quickshell.Io import if the file lacks one.
# Idempotent -- a file already carrying the edit matches nothing here.
patch_overlay() {
    local f=$1
    grep -q '^import Quickshell.Io' "$f" || sed -i '0,/^import Quickshell$/s//import Quickshell\nimport Quickshell.Io/' "$f"
    sed -i -E 's|^(\s*)WlrLayershell\.keyboardFocus: WlrKeyboardFocus\.(Exclusive\|OnDemand)$|\1WlrLayershell.keyboardFocus: gimbalMode.tablet ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive\n\1FileView { id: gimbalMode; property bool tablet: false; path: (Quickshell.env("XDG_RUNTIME_DIR") \|\| "/tmp") + "/gimbal-mode"; watchChanges: true; printErrors: false; onFileChanged: reload(); onLoaded: tablet = text().trim() === "tablet"; onLoadFailed: tablet = false }|' "$f"
}

if ask "Set them up?"; then
    for spec in lock:LockView.qml $typed_overlays; do
        src=${spec%%:*}; entry=${spec#*:}; target="$clone_dir/$me.$src"; created=0
        if [[ ! -d $target ]]; then
            omarchy plugin clone "omarchy.$src" >/dev/null 2>&1 \
                || { warn "omarchy plugin clone omarchy.$src failed; skipping it"; continue; }
            created=1
        fi
        [[ -f $target/$entry ]] || { warn "$target/$entry not found; skipping it"; continue; }
        if [[ $src == lock ]]; then
            # Always rebuilt from Omarchy's current file plus our patch, so an
            # update to the keypad reaches an existing clone and an Omarchy
            # change to the lock view is noticed rather than clobbered.
            stock_lock="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/lock/LockView.qml"
            scratch=$(mktemp -d); cp "$stock_lock" "$scratch/LockView.qml"
            if patch -d "$scratch" -p1 -s -N < "$here/lock-clone/LockView.patch" >/dev/null 2>&1; then
                install -Dm644 "$scratch/LockView.qml"           "$target/LockView.qml"
                install -Dm644 "$here/lock-clone/LockKeypad.qml" "$target/LockKeypad.qml"
                note "$target"
            elif grep -q 'gimbal: a keypad' "$target/LockView.qml"; then
                warn "Omarchy's lock screen has changed since this keypad was written; keeping the
             keypad you already have (see lock-clone/README.md)"
            else
                warn "Omarchy's lock screen has changed since this keypad was written; leaving it stock
             (see lock-clone/README.md; the keypad needs updating for the new LockView.qml)"
                (( created )) && omarchy plugin remove "$me.lock" --yes >/dev/null 2>&1
            fi
            rm -rf "$scratch"
        else
            patch_overlay "$target/$entry"
            grep -q 'gimbalMode.tablet' "$target/$entry" && note "$target" \
                || warn "$target/$entry has no keyboardFocus line to edit; Omarchy's overlay has changed"
        fi
    done
else
    note "skipped; run this again and answer yes, or see lock-clone/README.md and menu-clone/README.md"
fi

# --------------------------------------------------------------------------
# 5. Make it live
#
# The shell restart is not optional the first time: enabling a third-party
# panel hot does mount it, but a later rescanPlugins leaves it unmounted until
# the shell restarts. `hyprctl reload` is what picks up the rotation module.
# --------------------------------------------------------------------------
say "Restarting the shell and reloading Hyprland"
omarchy-restart-shell >/dev/null 2>&1 || warn "omarchy-restart-shell failed; restart it by hand"
if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || warn "hyprctl reload failed; log out and in"
else
    warn "no hyprctl; log out and in to load the rotation module"
fi

# --------------------------------------------------------------------------
say "Done"
cat <<EOF

    Fold the machine into a tablet and the knobs appear; tap a text field
    and the keyboard comes up. SUPER + B toggles it from either mode.

    One optional step is left, and it is the only one that needs root:

        sudo $here/system/install.sh

    It closes a firmware probe race that costs the tablet switch on roughly
    one boot in three. Gimbal does not depend on winning that race -- with no
    switch it falls back to the hinge angle and folding still works -- so this
    only buys sharpness: a fold noticed instantly rather than within five
    seconds, on the firmware's own hysteresis rather than the EC's angle.
EOF

if (( ${#warnings[@]} )); then
    printf '\n\033[33m    %d warning(s) above.\033[0m\n' "${#warnings[@]}"
fi

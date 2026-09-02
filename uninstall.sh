#!/bin/bash
# Gimbal -- remove everything install.sh put in $HOME.
#
# The root boot fix is left alone: it is a generic kernel-module ordering fix
# that does no harm on its own, and removing it is printed rather than done so
# that nobody loses their tablet switch to a script they ran to tidy up.
set -euo pipefail

PLUGIN_ID="io.github.mechanicsunlocked.gimbal"
here=$(cd "$(dirname "$0")" && pwd)
plugin_dir="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

say "Stopping the keyboard"
pkill -x fw12-oskbd 2>/dev/null && note "stopped" || note "not running"

say "Removing the keyboard"
rm -fv "$HOME/.local/bin/fw12-oskbd" \
       "$HOME/.local/bin/fw12-foldstate" \
       "$HOME/.local/share/gimbal/framework-logo.svg" | sed 's/^/    /'
rmdir "$HOME/.local/share/gimbal" 2>/dev/null || true

say "Removing the rotation module"
hl="$HOME/.config/hypr/hyprland.lua"
if [[ -f $hl ]] && grep -q 'require("hypr.gimbal")' "$hl"; then
    # Take the comment with it only when it is ours and directly above; a line
    # someone wrote themselves is not this script's to delete.
    python3 - "$hl" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n*-- Framework 12 tablet mode and auto-rotation \(gimbal\)\.\n'
           r'require\("hypr\.gimbal"\)\n', '\n', s)
s = re.sub(r'^require\("hypr\.gimbal"\)\n', '', s, flags=re.M)
open(p, 'w').write(s)
PY
    note "removed the require line from hyprland.lua"
fi
rm -fv "$HOME/.config/hypr/gimbal.lua" | sed 's/^/    /'

say "Removing the plugin"
omarchy-plugin-disable "$PLUGIN_ID" >/dev/null 2>&1 || true
if [[ $here -ef $plugin_dir ]]; then
    note "this script is inside $plugin_dir; remove it with:"
    note "    omarchy plugin remove $PLUGIN_ID"
else
    rm -rf "$plugin_dir"
    note "removed $plugin_dir"
fi
# The two clones, only if they are ours: the lock clone carries our keypad
# file, and the menu clone differs from Omarchy's file by the one word we put
# there. A clone with other edits in it is yours, and is left alone with a
# note. Removing an active clone switches Omarchy back to its built-in.
say "Removing the clones (lock screen, menu, prompts and pickers)"
me=${USER:-$(id -un)}
lock_clone="$HOME/.config/omarchy/plugins/$me.lock"
# `omarchy plugin remove` keeps a hidden backup of a non-git plugin directory
# (.<id>.bak.<timestamp>). For a clone we made, that is ours to delete too, or
# every install/uninstall cycle leaves another copy behind.
remove_clone() {
    local id=$1
    if omarchy plugin remove "$id" --yes >/dev/null 2>&1; then
        rm -rf "$HOME/.config/omarchy/plugins/.$id.bak."*
        note "removed $id"
    else
        note "could not remove $id; run: omarchy plugin remove $id"
    fi
}
# Undo the edit patch_overlay in install.sh makes, for comparison with stock.
unpatched() {
    sed -e '/FileView { id: gimbalMode;/d' \
        -e 's/gimbalMode.tablet ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive/WlrKeyboardFocus.Exclusive/' \
        -e 's/WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand$/WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive/' \
        -e '/^import Quickshell.Io$/d' "$1"
}
if [[ -d $lock_clone ]]; then
    if [[ -f $lock_clone/LockKeypad.qml ]]; then
        remove_clone "$me.lock"
    else
        note "$lock_clone is not ours; left alone"
    fi
fi
for spec in menu:Menu.qml polkit:PolkitAgent.qml emojis:Emojis.qml clipboard:Clipboard.qml reminders:ReminderFlow.qml; do
    src=${spec%%:*}; entry=${spec#*:}; clone="$HOME/.config/omarchy/plugins/$me.$src"
    [[ -d $clone ]] || continue
    stock="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/$src/$entry"
    if [[ -f $stock ]] && diff -q <(unpatched "$clone/$entry") <(sed '/^import Quickshell.Io$/d' "$stock") >/dev/null 2>&1; then
        remove_clone "$me.$src"
    else
        note "$clone has edits of its own; left alone"
    fi
done

rm -f "$HOME/.local/state/omarchy/gimbal-button.json"
rm -f "$HOME/.local/state/omarchy/gimbal-pads.json"
rm -f "$HOME/.config/omarchy/gimbal.json"
rm -f "${XDG_RUNTIME_DIR:-/tmp}/gimbal-fold" "${XDG_RUNTIME_DIR:-/tmp}/gimbal-mode" \
      "${XDG_RUNTIME_DIR:-/tmp}/gimbal-osk" "${XDG_RUNTIME_DIR:-/tmp}/gimbal-autoshow"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy-restart-shell >/dev/null 2>&1 || true
command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true

say "Done"
cat <<EOF

    The root boot fix, if you installed it, is still in place. It is a
    module-ordering fix and harmless on its own. To take it out too:

        sudo systemctl disable --now fw12-tablet-switch.service
        sudo rm -f /usr/lib/systemd/system/fw12-tablet-switch.service \\
                   /usr/lib/systemd/system-sleep/fw12-tablet-switch \\
                   /etc/mkinitcpio.conf.d/fw12-tablet.conf
        sudo rm -rf /usr/lib/fw12-tablet
        sudo mkinitcpio -P
EOF

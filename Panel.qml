// Two draggable knobs that show and hide the on-screen keyboard, and the
// policy for when it may show by itself.
//
// fcitx5 holds Hyprland's single input-method-v2 slot (measured -- Hyprland
// answers a second client with `unavailable`, FINDINGS.md 8.1 and 15.1), so
// no on-screen keyboard here can see which text field has focus. fcitx5 can,
// and it will tell a virtual keyboard registered with it over D-Bus; the
// daemon is that keyboard while the machine is folded. fcitx5 is not
// configured, stopped or replaced for it. The knobs stay, because some
// things a keyboard is wanted for are not text fields.
//
// The keyboard is `fw12-oskbd` (see ../osk/). It uploads the system's own xkb
// keymap, so its keys arrive with the same keycodes as the built-in keyboard's
// and Hyprland matches binds against them without any special configuration --
// SUPER+K from the on-screen Framework key does what it does from the real
// one. It is also why AltGr and dead keys work, which is what an international
// layout needs.
//
// While the machine is folded the keyboard is a resident process, started on
// fold and killed on unfold, and showing or hiding it is a signal that maps or
// unmaps a surface it has already built: no process spawn on the path a finger
// is waiting on, and something already running for fcitx5's auto-show to
// arrive at. Laptop mode keeps the old arrangement -- SUPER+B starts it
// showing and it lives exactly as long as it is on screen -- so an unfolded
// machine carries nothing resident.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

Item {
    id: root

    // Handed to us by the shell's panel loader when it mounts this plugin.
    property var shell: null
    property var manifest: null

    // -----------------------------------------------------------------------
    // Where the button is allowed to appear
    //
    // Folded state comes from the Lua half of this project, which is what
    // actually sees the SW_TABLET_MODE switch. It writes one word to a file on
    // every transition.
    //
    // An absent file means unknown -- the Lua is not installed, or Hyprland
    // has not reloaded since it was -- and unknown shows the button. Failing
    // visible beats failing invisible: a button you did not expect is obvious
    // and can be dragged out of the way, while a missing one is
    // indistinguishable from a broken plugin.
    // -----------------------------------------------------------------------
    readonly property bool tabletOnly: true

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string modePath: runtimeDir + "/gimbal-mode"
    readonly property string oskStatePath: runtimeDir + "/gimbal-osk"
    readonly property string autoShowPath: runtimeDir + "/gimbal-autoshow"
    readonly property string padPath: home + "/.local/state/omarchy/gimbal-pads.json"
    readonly property string userConfigPath: home + "/.config/omarchy/gimbal.json"

    property string tabletState: ""
    readonly property bool folded: tabletState !== "laptop"
    readonly property bool showButton: !tabletOnly || folded

    // The internal panel. This is a tablet button; on a docked external
    // monitor it has nothing to do.
    readonly property var targetScreens: {
        var ss = Quickshell.screens;
        for (var i = 0; i < ss.length; i++) {
            if (String(ss[i].name).indexOf("eDP") === 0)
                return [ss[i]];
        }
        return ss.length > 0 ? [ss[0]] : [];
    }

    // -----------------------------------------------------------------------
    // Geometry
    //
    // The position is stored as a fraction of the free travel on each axis
    // rather than in pixels, so it survives the thing this machine does most:
    // rotating. 1200x750 becomes 750x1200, where a pixel position would land
    // off screen or under the bar, while a fraction keeps the button roughly
    // where it looked like it was. It also means x and y stay plain bindings
    // -- nothing has to reposition anything by hand after a rotation.
    // -----------------------------------------------------------------------
    // The two swipe pads, in the same fractions and for the same reason. They
    // start where your thumbs already are when you hold the machine: the two
    // lower corners. Kept as four plain numbers rather than one object per pad
    // because a binding cannot see through a nested property change, and the
    // pads' x and y are bindings.
    property real padLeftFx: 0.0
    property real padLeftFy: 1.0
    property real padRightFx: 1.0
    property real padRightFy: 1.0

    function padFx(id) {
        return id === "left" ? root.padLeftFx : root.padRightFx;
    }
    function padFy(id) {
        return id === "left" ? root.padLeftFy : root.padRightFy;
    }
    function setPadPos(id, fx, fy) {
        if (id === "left") {
            root.padLeftFx = fx;
            root.padLeftFy = fy;
        } else {
            root.padRightFx = fx;
            root.padRightFy = fy;
        }
    }

    // One window per enabled knob per screen. Variants takes a flat model, so
    // the two lists are crossed here rather than nested, and a knob that is
    // switched off simply never gets a surface.
    readonly property var padSurfaces: {
        var out = [];
        var ss = root.targetScreens;
        for (var i = 0; i < ss.length; i++) {
            if (root.padLeftOn)
                out.push({
                    screen: ss[i],
                    pad: "left"
                });
            if (root.padRightOn)
                out.push({
                    screen: ss[i],
                    pad: "right"
                });
        }
        return out;
    }

    // 56 logical px is ~12 mm across on this panel, comfortably past the ~9 mm
    // that section 5.4 measured as the point where touch targets start being
    // missed. Style.space() also scales it with the user's text size setting.
    readonly property int buttonSize: Style.space(56)
    readonly property int edgeMargin: Style.space(8)

    function clamp01(v) {
        return Math.max(0, Math.min(1, v));
    }

    // -----------------------------------------------------------------------
    // Keyboard
    //
    // The daemon is resident for exactly as long as the machine is folded --
    // the same condition that puts the knobs on screen, so a knob is never
    // there with nothing behind it -- and is shown or hidden by signal:
    // SIGUSR1 maps, SIGUSR2 unmaps. It publishes whether it is on screen to a
    // one-word file, `visible` or `hidden`, written from its own map and
    // unmap, so what is read here is the truth of the surface rather than the
    // last request: if it dies, the word goes to `hidden` and the next tap
    // starts it again. The bar widget and the Lua's follow_mouse read the
    // same file. One writer, three readers, no polling.
    //
    // Resident waits for the mode file to have been read once. Before that
    // the knobs already fail visible, which costs a surface for a moment; a
    // daemon started and killed on every shell start in laptop mode would
    // cost a process.
    // -----------------------------------------------------------------------
    property bool modeKnown: false
    // Both hyprctl getoption calls have answered (or failed); before that the
    // layout would be the "us" fallback and the daemon, started once per fold,
    // would keep it for the whole fold.
    property int layoutAnswers: 0
    readonly property bool layoutKnown: root.layoutAnswers >= 2
    readonly property bool resident: root.modeKnown && root.layoutKnown && root.showButton
    property bool keyboardShown: false

    // Linux signal numbers; Process.signal() takes the integer.
    readonly property int sigShow: 10   // SIGUSR1
    readonly property int sigHide: 12   // SIGUSR2

    FileView {
        id: oskStateFile

        path: root.oskStatePath
        watchChanges: true
        printErrors: false

        onFileChanged: reload()
        onLoaded: root.keyboardShown = text().trim() === "visible"
        onLoadFailed: root.keyboardShown = false
    }

    // Quickshell keeps `running` true from the moment we ask the process to
    // stop until it has actually exited, and the daemon's exit does real work
    // (fcitx5 is handed its UI back over D-Bus). A request that lands in that
    // window used to be signalled at a dying process and lost, and a fold
    // that arrived in it left the machine folded with no daemon at all. So
    // stopping is a state of its own, and what was wanted in the meantime is
    // carried out when the exit comes.
    property bool daemonStopping: false
    property bool showAfterExit: false

    function startDaemon(shown) {
        // Positional: layout, variant, options, the gutter to keep clear,
        // and how to start. Set right before each start because the last
        // argument depends on who is asking.
        keyboard.command = ["fw12-oskbd", root.kbLayout || "us", root.kbVariant, "", "0", shown ? "shown" : "hidden"];
        keyboard.running = true;
    }

    function stopDaemon() {
        root.daemonStopping = true;
        root.showAfterExit = false;
        keyboard.running = false;
    }

    // Fold starts it hidden. Unfold kills it, on screen or not: a keyboard
    // left up would strand its exclusive zone with no knob left to dismiss
    // it. Laptop mode never starts one here; see requestKeyboard.
    function syncDaemon() {
        if (root.resident && !keyboard.running)
            root.startDaemon(false);
        else if (!root.resident && keyboard.running && !root.daemonStopping)
            root.stopDaemon();
    }
    onResidentChanged: syncDaemon()

    Component.onCompleted: {
        // A stale `visible` from a session that ended with the keyboard out
        // would light the bar icon over nothing. The daemon rewrites the
        // word the moment it starts, but in laptop mode nothing starts.
        oskStateFile.setText("hidden");
        root.syncDaemon();
    }

    // -----------------------------------------------------------------------
    // Holding the keyboard back for a game
    //
    // Streaming a desktop game to the tablet, every gesture you make is aimed
    // at the remote machine, and a keyboard sliding up over the picture is
    // never what you meant. So while a Moonlight window is open, nothing
    // summons the keyboard: not a swipe, not the button, not SUPER+B. The
    // gestures themselves keep working, because switching workspace away from
    // the game is exactly what you still want.
    //
    // Detected from the Wayland toplevel list rather than by polling for a
    // process: the list is already live in this process and changes arrive as
    // a signal, so there is no interval to pick and nothing to be stale by.
    // It also asks the right question -- a Moonlight window on screen is what
    // matters, not a Moonlight binary that happens to be resident.
    // -----------------------------------------------------------------------
    readonly property bool blockOnMoonlight: root.opt("blockOnMoonlight", true) === true

    function looksLikeMoonlight(t) {
        if (!t)
            return false;
        var w = t.wayland;
        if (String((w && w.appId) || "").toLowerCase().indexOf("moonlight") >= 0)
            return true;
        var o = t.lastIpcObject;
        return String((o && o.class) || "").toLowerCase().indexOf("moonlight") >= 0;
    }

    // Blocked only on the workspace the game is actually on. A stream running
    // on workspace 2 is no reason to lose the keyboard on workspace 1, and
    // switching away from the game is the ordinary way to go and do something
    // else on the tablet. Which workspace a window is on is a Hyprland
    // question rather than a Wayland one -- the foreign-toplevel protocol has
    // no notion of workspaces -- so it is asked of Hyprland directly.
    readonly property bool moonlightFocused: {
        var fw = Hyprland.focusedWorkspace;
        if (!fw)
            return false;
        var m = Hyprland.toplevels;
        var vs = m ? m.values : [];
        for (var i = 0; i < vs.length; i++) {
            var t = vs[i];
            if (!root.looksLikeMoonlight(t))
                continue;
            var ws = t.workspace;
            if (ws && ws.id === fw.id)
                return true;
        }
        return false;
    }

    // Everything that would land on top of the game is held back, not just the
    // keyboard. The menu is a full-screen layer surface that takes keyboard
    // focus, and a client capturing input for a stream does not reliably get
    // it back afterwards -- which is how one swipe for the menu ends with a
    // game that no longer answers the touchscreen. Switching workspace stays
    // available, because leaving is the thing you still want.
    readonly property bool interruptionsBlocked: root.blockOnMoonlight && root.moonlightFocused
    readonly property bool keyboardBlocked: root.interruptionsBlocked

    // -----------------------------------------------------------------------
    // Appearing by itself
    //
    // The daemon shows the keyboard when fcitx5 reports a text field taking
    // focus, and when the Omarchy menu opens, and hides it again when they
    // go. Whether it may is policy, and policy lives here: the `autoShow`
    // setting, and the Moonlight hold-back, which has to stop an automatic
    // show as surely as it stops a knob. The daemon reads one word from a
    // runtime file on every such event, so a change takes effect at once and
    // nothing polls. Written whenever the answer changes, and once at start.
    // -----------------------------------------------------------------------
    readonly property bool autoShow: root.opt("autoShow", true) === true
    readonly property bool autoShowAllowed: root.autoShow && !root.interruptionsBlocked

    onAutoShowAllowedChanged: autoShowFile.setText(root.autoShowAllowed ? "on" : "off")

    FileView {
        id: autoShowFile

        path: root.autoShowPath
        printErrors: false

        Component.onCompleted: autoShowFile.setText(root.autoShowAllowed ? "on" : "off")
    }

    // A game that starts while the keyboard is out takes the screen back.
    onKeyboardBlockedChanged: {
        if (root.keyboardBlocked)
            root.requestKeyboard(false);
    }

    function requestKeyboard(on) {
        if (on && root.keyboardBlocked)
            return;
        if (root.resident) {
            if (keyboard.running && !root.daemonStopping)
                keyboard.signal(on ? root.sigShow : root.sigHide);
            else if (on && keyboard.running)
                root.showAfterExit = true;   // on its way out; come back showing
            else if (on)
                root.startDaemon(true);      // it died; this tap brings it back, showing
            return;
        }
        // Laptop mode. SUPER+B works here too, and the keyboard lives exactly
        // as long as it is on screen, so an unfolded machine carries nothing
        // resident.
        if (!on) {
            if (keyboard.running && !root.daemonStopping)
                root.stopDaemon();
        } else if (keyboard.running) {
            if (root.daemonStopping)
                root.showAfterExit = true;
            else
                keyboard.signal(root.sigShow);
        } else {
            root.startDaemon(true);
        }
    }

    // Reachable from a keybind as
    //   omarchy-shell shell call io.github.mechanicsunlocked.gimbal toggle ''
    // which is what SUPER+K in the Lua half runs. Aiming for a 32 px strip is
    // not always what you want.
    function toggle(arg) {
        var want = !root.keyboardShown;
        if (want && root.keyboardBlocked)
            return "blocked";
        root.requestKeyboard(want);
        return want ? "shown" : "hidden";
    }

    // The layout is read from Hyprland rather than configured here, so the
    // on-screen keyboard is whatever the real keyboard is -- change
    // `input:kb_layout` and this follows, with no second copy to update.
    // `hyprctl getoption` answers as two lines, `str: <value>` and `set: ...`.
    property string kbLayout: ""
    property string kbVariant: ""

    function readOption(line, setter) {
        var s = String(line);
        if (s.indexOf("str:") !== 0)
            return;
        // A multi-layout setting like "de,us" starts in the first one.
        setter(s.substring(4).trim().split(",")[0]);
    }

    Process {
        command: ["hyprctl", "getoption", "input:kb_layout"]
        running: true
        stdout: SplitParser {
            onRead: function (line) {
                root.readOption(line, function (v) {
                    root.kbLayout = v;
                });
            }
        }
        onExited: root.layoutAnswers += 1
    }

    Process {
        command: ["hyprctl", "getoption", "input:kb_variant"]
        running: true
        stdout: SplitParser {
            onRead: function (line) {
                root.readOption(line, function (v) {
                    root.kbVariant = v;
                });
            }
        }
        onExited: root.layoutAnswers += 1
    }

    Process {
        id: keyboard

        // The gutter is 0: with the edge strips gone the keyboard has the
        // full width of the screen, which is worth the most in portrait where
        // the key pitch is tightest. The real command is set by startDaemon().
        command: ["fw12-oskbd", root.kbLayout || "us", root.kbVariant, "", "0", "hidden"]
        running: false

        onExited: function (exitCode) {
            if (exitCode !== 0)
                console.warn("gimbal: fw12-oskbd exited " + exitCode);
            // Its own unmap wrote `hidden` if it left cleanly. A crash did
            // not, and a stale `visible` would hold follow_mouse and light
            // the bar icon over nothing.
            oskStateFile.setText("hidden");
            root.daemonStopping = false;
            if (root.showAfterExit) {
                root.showAfterExit = false;
                root.startDaemon(true);
            } else if (root.resident) {
                // A fold that landed while it was leaving, or a mode flap
                // faster than its exit: the fold owns a daemon, so have one.
                Qt.callLater(root.syncDaemon);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Persistence
    // -----------------------------------------------------------------------
    FileView {
        id: modeFile

        path: root.modePath
        watchChanges: true
        printErrors: false

        // text() is stale inside the change signal itself, so both the first
        // load and every later change are routed through reload -> onLoaded.
        onFileChanged: reload()
        onLoaded: {
            root.tabletState = text().trim();
            root.modeKnown = true;
        }
        onLoadFailed: {
            root.tabletState = "";
            root.modeKnown = true;
        }
    }

    FileView {
        id: padFile

        path: root.padPath
        watchChanges: false
        printErrors: false

        onLoaded: {
            try {
                var p = JSON.parse(text());
                if (p.left) {
                    if (typeof p.left.fx === "number")
                        root.padLeftFx = root.clamp01(p.left.fx);
                    if (typeof p.left.fy === "number")
                        root.padLeftFy = root.clamp01(p.left.fy);
                }
                if (p.right) {
                    if (typeof p.right.fx === "number")
                        root.padRightFx = root.clamp01(p.right.fx);
                    if (typeof p.right.fy === "number")
                        root.padRightFy = root.clamp01(p.right.fy);
                }
            } catch (e) {}
        }
    }

    // -----------------------------------------------------------------------
    // Swipe actions
    //
    // Read out of this plugin's own entry in ~/.config/omarchy/shell.json,
    // which is where Omarchy keeps per-plugin settings ("the fields on each
    // entry are the values the plugin sees"). Nothing new to learn and nothing
    // extra to install; an absent field falls back to the default below.
    //
    //   { "id": "io.github.mechanicsunlocked.gimbal",
    //     "swipeUp":    "@keyboard",
    //     "swipeDown":  "@menu",
    //     "swipeRight": "hyprctl dispatch 'hl.dsp.focus({ workspace = \"r-1\" })'",
    //     "swipeLeft":  "hyprctl dispatch 'hl.dsp.focus({ workspace = \"r+1\" })'",
    //     "padLeft":    true,
    //     "padRight":   true,
    //     "swipeThreshold": 30 }
    //
    // Swipes are named for the direction your finger travels. "@keyboard" and
    // "@menu" are the two built-in actions; anything else is run as a command.
    // -----------------------------------------------------------------------
    property var settings: ({})

    // What the bar widget writes. It is a separate file rather than an edit to
    // shell.json because shell.json belongs to Omarchy, and a plugin that
    // rewrites another program's config file will eventually lose a race with
    // it. Values here win over the shell.json entry, which stays usable for
    // anyone who would rather set things by hand.
    property var userSettings: ({})

    function opt(name, fallback) {
        var v = root.userSettings ? root.userSettings[name] : undefined;
        if (v !== undefined && v !== null)
            return v;
        v = root.settings ? root.settings[name] : undefined;
        if (v !== undefined && v !== null)
            return v;
        return fallback;
    }

    FileView {
        id: userConfigFile

        path: root.userConfigPath
        watchChanges: true
        printErrors: false

        onFileChanged: reload()
        onLoaded: {
            try {
                root.userSettings = JSON.parse(text()) || ({});
            } catch (e) {}
        }
        onLoadFailed: root.userSettings = ({})
    }

    // Which of the two mechanisms is live: "edges", "pads" or "both".
    readonly property string mode: String(root.opt("mode", "both"))
    // Three independent switches rather than one three-way mode: edges, pads
    // and the floating button are not alternatives to each other, and asking
    // which combination you want is a question with an "all off" answer that
    // a three-way choice cannot express. `mode` stays readable as a fallback
    // so a config written before this still means what it meant.
    readonly property string swipeUp: root.opt("swipeUp", "@keyboard")
    readonly property string swipeDown: root.opt("swipeDown", "@menu")
    // `hyprctl dispatch` takes a *Lua expression* on Omarchy 4, not the
    // hyprland-1 words: `hyprctl dispatch workspace e+1` fails with a Lua
    // syntax error and does nothing. This is the form Omarchy's own workspace
    // widget uses.
    // The two directions are deliberately not the same form. Measured on this
    // machine with workspaces 1..4 live:
    //
    //   from 1, focus("-1")  -> 1     a wall
    //   from 4, focus("+1")  -> 5     a new workspace
    //   from 1, focus("e-1") -> 4     wraps to the last one that exists
    //   from 4, focus("e+1") -> 1     wraps to the first
    //
    // Forward is "+1": swiping past the end opens a new workspace, which is
    // the point of swiping past the end. Hyprland drops it again when you
    // leave it empty, so it does not accumulate.
    //
    // Back is "e-1": it wraps to the last workspace that exists rather than
    // stopping dead at 1. "-1" is the only one of the four that can do
    // nothing at all, and a swipe that does nothing reads as a broken gesture
    // -- there is no feedback to tell you that you are simply at the end.
    // r-1 and r+1 rather than e-1 and +1: the "e" selectors walk to the next
    // workspace that has a window on it, so swiping back from 5 lands on 2 if
    // 3 and 4 happen to be empty. A swipe should move one workspace, and the
    // "r" selectors are the ones that count in plain numbers. They stop at 1
    // rather than wrapping.
    readonly property string swipeRight: root.opt("swipeRight", "hyprctl dispatch 'hl.dsp.focus({ workspace = \"r-1\" })'")
    readonly property string swipeLeft: root.opt("swipeLeft", "hyprctl dispatch 'hl.dsp.focus({ workspace = \"r+1\" })'")
    // How far the finger travels before a swipe counts. A knob sits away from
    // every edge, so all four directions have the whole screen and one number
    // covers them; an edge strip needed the threshold scaled to whatever room
    // was left in that direction, which is most of what made it feel
    // unreliable. Short on purpose: 60 px felt like a drag rather than a flick.
    readonly property int swipeThreshold: root.opt("swipeThreshold", Style.space(30))

    // Each knob is its own switch, so you can run one thumb or two. `pads`,
    // and `mode` before that, are still read as the fallback for both.
    readonly property bool padsOn: root.opt("pads", root.mode !== "edges") === true
    readonly property bool padLeftOn: root.opt("padLeft", root.padsOn) === true
    readonly property bool padRightOn: root.opt("padRight", root.padsOn) === true

    FileView {
        id: settingsFile

        path: root.home + "/.config/omarchy/shell.json"
        watchChanges: true
        printErrors: false

        onFileChanged: reload()
        onLoaded: {
            var found = ({});
            try {
                var list = JSON.parse(text()).plugins || [];
                for (var i = 0; i < list.length; i++) {
                    if (list[i] && list[i].id === "io.github.mechanicsunlocked.gimbal") {
                        found = list[i];
                        break;
                    }
                }
            } catch (e) {}
            root.settings = found;
        }
    }

    function actionFor(key) {
        if (key === "up") return root.swipeUp;
        if (key === "down") return root.swipeDown;
        if (key === "left") return root.swipeLeft;
        return root.swipeRight;
    }

    // Which surface the last gesture came from. Only for the log, but the
    // log is how the last two swipe reports were settled, and "it fired" and
    // "it fired *there*" are different facts.
    property string lastSwipeFrom: ""

    // The two built-in actions are the two that put something on top of what
    // you are looking at, which is why they are named rather than spelled as
    // commands: naming them is what lets a game refuse both. Anything you type
    // in yourself is your business and always runs.
    function runAction(key) {
        var cmd = String(root.actionFor(key) || "");
        if (cmd === "")
            return;
        if (cmd === "@keyboard") {
            root.requestKeyboard(!root.keyboardShown);
            return;
        }
        if (cmd === "@menu") {
            if (root.interruptionsBlocked)
                return;
            menuProc.running = false;
            menuProc.running = true;
            return;
        }
        console.log("gimbal: swipe " + key + " on " + root.lastSwipeFrom + " -> " + cmd);
        actionProc.running = false;
        actionProc.command = ["sh", "-c", cmd];
        actionProc.running = true;
    }

    Process {
        id: menuProc

        command: ["omarchy-menu"]
    }

    // `sh -c` because the value is a command line written by a person, and
    // splitting one correctly is the shell's job. One shot per swipe.
    Process {
        id: actionProc

        onExited: function (exitCode) {
            if (exitCode !== 0)
                console.warn("gimbal: swipe command exited " + exitCode + ": " + actionProc.command.join(" "));
        }
    }

    // Knobs above the keyboard.
    //
    // Both now sit on the overlay layer -- the keyboard moved there to get
    // above the menu, FINDINGS 15 -- and within one layer Hyprland stacks by
    // map order. A keyboard mapped after the knobs would therefore cover any
    // knob resting where the keyboard lands, which is the bottom corners,
    // which is where the knobs start. The documented behaviour is the other
    // way round: a knob over the keyboard is drawn above it and still takes
    // the touch, so it can be dragged clear.
    //
    // A layer bounce puts that back. A surface that changes layer is
    // re-inserted on top of its new one without unmapping (FINDINGS 15.5),
    // so each knob steps to the top layer and straight back. Done whenever
    // the keyboard maps, and whenever the menu closes, because the keyboard
    // bounces itself above the menu the same way and would otherwise be left
    // above the knobs.
    function restackPads() {
        var inst = padWindows.instances;
        for (var i = 0; i < inst.length; i++)
            inst[i].restack();
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            var name = event.name;
            if (name !== "openlayer" && name !== "closelayer")
                return;
            var ns = String(event.data);
            if ((name === "openlayer" && ns === "fw12tab-osk") || (name === "closelayer" && ns === "omarchy-menu"))
                root.restackPads();
        }
    }

    function savePads() {
        padFile.setText(JSON.stringify({
            left: {
                fx: root.padLeftFx,
                fy: root.padLeftFy
            },
            right: {
                fx: root.padRightFx,
                fy: root.padRightFy
            }
        }));
    }

    // -----------------------------------------------------------------------
    // Swipe pads
    //
    // Two round pads that take all four gestures, sitting where your thumbs
    // already are when you hold the machine. They exist because an edge strip
    // is the one place a swipe can never be given room in every direction: at
    // the left edge there is nothing to the left of your finger, so the
    // outward gesture has to fire on a few millimetres of travel or not at
    // all. A pad away from the edge has the whole screen in all four
    // directions, and the same threshold everywhere.
    //
    // Press and drag to fire. There is no hold delay and no flick-versus-move
    // ambiguity to arbitrate, because moving a pad is behind a separate
    // gesture entirely: press and hold unlocks it, press and hold again sticks
    // it down. That is deliberately not something a hand does by accident,
    // and it is why the press-and-drag can start acting immediately.
    //
    // It used to be three taps. That forced every single tap -- the one that
    // shows the keyboard -- to wait out a 380 ms window first, in case two
    // more were coming, and a keyboard that arrives a third of a second after
    // the finger is a keyboard that feels slow. A hold is as deliberate as a
    // triple tap and costs the tap nothing: it acts the moment the finger
    // lifts.
    // -----------------------------------------------------------------------
    Variants {
        id: padWindows

        model: root.padSurfaces

        PanelWindow {
            id: padSurface

            required property var modelData

            readonly property string padId: modelData.pad

            screen: modelData.screen
            visible: root.showButton

            // The surface is only as big as the knob, except while the knob is
            // unlocked for moving.
            //
            // It used to be full-screen always, with mask/Region as the only
            // thing keeping the pointer out of the other 99% of it. That is a
            // design where the safe state depends on a property staying true
            // every frame -- through drags, animations and reconfigures -- and
            // any lapse hands the whole display to a transparent surface. It
            // is not hypothetical: with two of these stacked on the overlay
            // layer, the symptom is a mouse cursor that vanishes and comes
            // back, on a desktop that looks perfectly fine.
            //
            // Small while locked, which is essentially always, so a slip costs
            // a knob-sized patch. Full-screen only while loose, which you have
            // to triple-tap to enter, which is visibly marked by the accent
            // ring, and which is exactly when the knob needs the whole screen
            // to be dragged across.
            //
            // Swipes do not need the big surface: the touch lands on the knob
            // and the implicit grab follows the finger off it.
            readonly property bool moving: pad.loose
            readonly property int surfaceSize: Math.round(root.buttonSize * 1.8)

            anchors {
                top: true
                left: true
                bottom: padSurface.moving
                right: padSurface.moving
            }
            implicitWidth: padSurface.moving ? 0 : padSurface.surfaceSize
            implicitHeight: padSurface.moving ? 0 : padSurface.surfaceSize
            margins {
                left: padSurface.moving ? 0 : padSurface.restX
                top: padSurface.moving ? 0 : padSurface.restY
            }
            color: "transparent"

            WlrLayershell.namespace: "gimbal-pad-" + padSurface.padId
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            // Reserve nothing, and ignore what others reserve. A pad is a
            // control you learn the position of with your thumb, so it has to
            // be in the same place every time -- if the window shrank to the
            // space left by the keyboard, every pad would jump the moment the
            // keyboard appeared. A pad left over the keyboard is kept above it
            // by restackPads(), so it still takes the touch; it covers
            // whatever key is under it, which is the reason they can be
            // dragged.
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0

            mask: Region {
                item: pad
            }

            // See restackPads(). Two steps because Hyprland only moves a
            // surface whose committed layer differs from the one it holds;
            // both changes in one commit cancel out.
            function restack() {
                padSurface.WlrLayershell.layer = WlrLayer.Top;
                restackTimer.restart();
            }

            Timer {
                id: restackTimer

                interval: 40
                onTriggered: padSurface.WlrLayershell.layer = WlrLayer.Overlay
            }

            // Travel is measured against the screen, not against this
            // surface, so it means the same thing in both sizes.
            readonly property real sw: padSurface.screen ? padSurface.screen.width : 0
            readonly property real sh: padSurface.screen ? padSurface.screen.height : 0
            readonly property real travelX: Math.max(0, padSurface.sw - root.buttonSize - root.edgeMargin * 2)
            readonly property real travelY: Math.max(0, padSurface.sh - root.buttonSize - root.edgeMargin * 2)

            // Where the knob sits, in screen coordinates.
            readonly property real padX: root.edgeMargin + padSurface.travelX * root.padFx(padSurface.padId)
            readonly property real padY: root.edgeMargin + padSurface.travelY * root.padFy(padSurface.padId)

            // The small surface centres the knob, except near an edge, where
            // it is clamped on screen and the knob sits off-centre inside it
            // instead. Growing room for the swipe ring is why it is wider than
            // the knob at all.
            readonly property real halo: (padSurface.surfaceSize - root.buttonSize) / 2
            readonly property real restX: Math.max(0, Math.min(padSurface.sw - padSurface.surfaceSize, padSurface.padX - padSurface.halo))
            readonly property real restY: Math.max(0, Math.min(padSurface.sh - padSurface.surfaceSize, padSurface.padY - padSurface.halo))

            Item {
                id: pad

                width: root.buttonSize
                height: root.buttonSize

                x: padSurface.moving ? padSurface.padX : (padSurface.padX - padSurface.restX)
                y: padSurface.moving ? padSurface.padY : (padSurface.padY - padSurface.restY)

                // Unlocked by a press-and-hold, and stays unlocked until another.
                property bool loose: false
                // 0..1 toward committing a swipe, same as the strips use.
                property real progress: 0

                opacity: padDrag.active ? 1.0 : 0.6
                scale: pad.loose ? 1.18 : 1.0

                Behavior on opacity {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on scale {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }

                // A ring that grows as a swipe commits. The pad does not move
                // under the finger -- moving is what the unlocked state does
                // -- so this is the only thing that can report the gesture.
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * (1 + 0.5 * pad.progress)
                    height: width
                    radius: width / 2
                    color: "transparent"
                    border.width: Math.max(1, Style.space(2))
                    border.color: pad.progress >= 1 ? Color.accent : Util.alpha(Color.popups.text, 0.45)
                    opacity: (padDrag.active && !pad.loose) ? pad.progress : 0
                    visible: opacity > 0

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 90
                        }
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    // Filled while the keyboard is out. A control that toggles
                    // something has to say which way it is set, and the fill
                    // is readable from the corner of an eye in a way a change
                    // of outline is not.
                    color: root.keyboardShown ? Util.alpha(Color.accent, 0.55) : Util.alpha(Color.popups.background, 0.82)
                    border.width: Math.max(1, Style.space(2))
                    border.color: pad.loose ? Color.accent : Util.alpha(Color.popups.border, 0.7)

                    Behavior on color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                    Behavior on border.color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                }

                // Four arrowheads. The pad has to say what it is without a
                // label, because nothing about a plain circle suggests that
                // dragging off it does anything.
                Shape {
                    anchors.centerIn: parent
                    width: root.buttonSize * 0.5
                    height: width

                    ShapePath {
                        fillColor: pad.loose ? Color.accent : Util.alpha(Color.popups.text, 0.8)
                        strokeWidth: 0
                        strokeColor: "transparent"
                        scale: Qt.size(root.buttonSize * 0.5 / 100, root.buttonSize * 0.5 / 100)

                        PathSvg {
                            path: "M50 6 L66 30 L34 30 Z M50 94 L34 70 L66 70 Z M6 50 L30 34 L30 66 Z M94 50 L70 66 L70 34 Z"
                        }
                    }
                }

                DragHandler {
                    id: padDrag

                    target: null

                    property real startFx: 0
                    property real startFy: 0
                    property bool fired: false

                    onActiveChanged: {
                        if (padDrag.active) {
                            padDrag.startFx = root.padFx(padSurface.padId);
                            padDrag.startFy = root.padFy(padSurface.padId);
                            padDrag.fired = false;
                        } else {
                            if (pad.loose)
                                root.savePads();
                            pad.progress = 0;
                        }
                    }

                    onActiveTranslationChanged: {
                        if (!padDrag.active)
                            return;

                        if (pad.loose) {
                            var nx = padDrag.startFx;
                            var ny = padDrag.startFy;
                            if (padSurface.travelX > 0)
                                nx = root.clamp01(padDrag.startFx + padDrag.activeTranslation.x / padSurface.travelX);
                            if (padSurface.travelY > 0)
                                ny = root.clamp01(padDrag.startFy + padDrag.activeTranslation.y / padSurface.travelY);
                            root.setPadPos(padSurface.padId, nx, ny);
                            return;
                        }

                        if (padDrag.fired)
                            return;

                        var t = padDrag.activeTranslation;
                        var horizontal = Math.abs(t.x) > Math.abs(t.y);
                        var along = horizontal ? t.x : t.y;
                        pad.progress = Math.min(1, Math.abs(along) / root.swipeThreshold);
                        if (Math.abs(along) < root.swipeThreshold)
                            return;
                        padDrag.fired = true;
                        root.lastSwipeFrom = "pad-" + padSurface.padId;
                        root.runAction(horizontal ? (along < 0 ? "left" : "right") : (along < 0 ? "up" : "down"));
                    }
                }

                // A swipe takes an exclusive grab past the drag threshold,
                // which cancels this, so a gesture never counts as a tap. A
                // press held past the threshold is not a tap either: Qt emits
                // longPressed instead, and nothing on release.
                TapHandler {
                    longPressThreshold: 0.5

                    onTapped: {
                        if (!pad.loose)
                            root.requestKeyboard(!root.keyboardShown);
                    }
                    onLongPressed: {
                        pad.loose = !pad.loose;
                        if (!pad.loose)
                            root.savePads();
                    }
                }
            }
        }
    }

}

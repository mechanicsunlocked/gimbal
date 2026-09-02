import QtQuick
import qs.Commons

// A keypad for the lock screen, drawn by the lock screen itself.
//
// Under ext-session-lock only lock surfaces render or receive input, so the
// session keyboard -- a layer surface -- cannot appear here by protocol. This
// is the one place a keyboard has to be part of the thing it types into.
//
// Plain QWERTY, a digit row, a symbols page for everything a password tends to
// contain, and nothing else: it exists to get a password in, not to be the
// Framework 12's board. Keys act on press, not release, so a thumb feels the
// key land; each key has its own touch handler, so two thumbs do not have to
// wait for each other. Shift is one-shot.
Item {
    id: keypad

    signal typed(string ch)
    signal backspace
    signal submit
    signal dismiss

    property bool shift: false
    property bool symbols: false

    // Plain pixels, not Style.space(): the password field is a fixed 381x67
    // box, and a keypad that grew with the shell font walked up over it at
    // larger text sizes. The lock view hands in a height that stops short of
    // the field.
    property int keyHeight: 52
    readonly property int gap: 6
    // Faces are a tint of the ink, not the lock background: in the stock
    // theme that background is the page background, and a key painted in it
    // is a key you cannot see (measured -- a screenshot of exactly that).
    readonly property color ink: Color.lock.text
    readonly property color keyColor: Util.alpha(keypad.ink, 0.14)
    readonly property color keyEdge: Util.alpha(keypad.ink, 0.28)
    readonly property color keyDown: Util.alpha(Color.lock.borderActive, 0.85)

    implicitHeight: 5 * keypad.keyHeight + 4 * keypad.gap

    readonly property var letters: [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"]
    ]
    readonly property var symbolPage: [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"],
        ["-", "_", "=", "+", "[", "]", "{", "}", ";", ":"],
        ["`", "~", "'", "\"", ",", ".", "<", ">", "/", "?", "\\", "|"]
    ]

    // One entry per key: what it shows, what it types, how wide it is
    // relative to a letter, and what it does.
    function rowModel(i) {
        var src = keypad.symbols ? keypad.symbolPage : keypad.letters;
        var r = src[i].map(function (c) {
            return {
                label: (keypad.shift && !keypad.symbols) ? c.toUpperCase() : c,
                ch: c,
                w: 1,
                act: "type"
            };
        });
        if (i === 3) {
            if (!keypad.symbols)
                r.unshift({
                    label: "⇧",
                    ch: "",
                    w: 1.5,
                    act: "shift"
                });
            r.push({
                label: "⌫",
                ch: "",
                w: 1.5,
                act: "backspace"
            });
        }
        return r;
    }

    readonly property var bottomRow: [
        {
            label: keypad.symbols ? "abc" : "?123",
            ch: "",
            w: 1.5,
            act: "symbols"
        },
        {
            label: "",
            ch: " ",
            w: 5,
            act: "type"
        },
        {
            label: "⏎",
            ch: "",
            w: 1.5,
            act: "submit"
        },
        {
            label: "⌄",
            ch: "",
            w: 1,
            act: "dismiss"
        }
    ]

    // Rebuilt whenever shift or the page flips; the arrays are tiny.
    readonly property var model: [rowModel(0), rowModel(1), rowModel(2), rowModel(3), keypad.bottomRow]

    function act(k) {
        if (k.act === "type") {
            keypad.typed((keypad.shift && !keypad.symbols) ? k.ch.toUpperCase() : k.ch);
            if (keypad.shift)
                keypad.shift = false;
        } else if (k.act === "shift") {
            keypad.shift = !keypad.shift;
        } else if (k.act === "symbols") {
            keypad.symbols = !keypad.symbols;
            keypad.shift = false;
        } else if (k.act === "backspace") {
            keypad.backspace();
        } else if (k.act === "submit") {
            keypad.submit();
        } else if (k.act === "dismiss") {
            keypad.dismiss();
        }
    }

    Column {
        id: column

        anchors.fill: parent
        spacing: keypad.gap

        Repeater {
            model: keypad.model

            delegate: Row {
                id: rowItem

                required property var modelData

                readonly property real totalWeight: {
                    var t = 0;
                    for (var i = 0; i < rowItem.modelData.length; i++)
                        t += rowItem.modelData[i].w;
                    return t;
                }
                readonly property real unit: (keypad.width - keypad.gap * (rowItem.modelData.length - 1)) / rowItem.totalWeight

                anchors.horizontalCenter: parent.horizontalCenter
                spacing: keypad.gap

                Repeater {
                    model: rowItem.modelData

                    delegate: Rectangle {
                        id: key

                        required property var modelData

                        readonly property bool on: (key.modelData.act === "shift" && keypad.shift) || (key.modelData.act === "symbols" && keypad.symbols)

                        width: Math.floor(rowItem.unit * key.modelData.w)
                        height: keypad.keyHeight
                        radius: Style.cornerRadius
                        color: (key.on || tap.pressed) ? keypad.keyDown : keypad.keyColor
                        border.width: 1
                        border.color: keypad.keyEdge

                        Text {
                            anchors.centerIn: parent
                            text: key.modelData.label
                            color: keypad.ink
                            font.family: Style.font.family
                            font.pixelSize: Style.font.title
                        }

                        TapHandler {
                            id: tap

                            onPressedChanged: {
                                if (tap.pressed)
                                    keypad.act(key.modelData);
                            }
                        }
                    }
                }
            }
        }
    }
}

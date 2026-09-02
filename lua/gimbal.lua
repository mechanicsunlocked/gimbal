-- gimbal -- tablet mode and auto-rotation for the Framework Laptop 12
-- on Omarchy 4 / Hyprland.
--
-- Install:
--   cp gimbal.lua ~/.config/hypr/
--   then add to ~/.config/hypr/hyprland.lua:
--       require("hypr.gimbal")
--
-- There is deliberately no daemon. Everything here is measured rather than
-- assumed; see FINDINGS.md for the numbers behind each choice.
--
--   * Tablet mode comes from the kernel SW_TABLET_MODE switch (INT33D3 /
--     soc_button_array), via Hyprland's switch binds. The firmware owns the
--     hysteresis: it enters around 220-257 deg and leaves around 106-170 deg.
--   * Rotation reads the *display* accelerometer directly from sysfs. A
--     3-axis read costs 82 us on average and 291 us at worst, so at 4 Hz this
--     is ~0.03% of compositor time.
--   * Switch binds are edge-triggered, so they cannot report the current
--     position and a missed edge would latch the wrong mode forever. The same
--     switch also has a *level*, read through fw12-foldstate, which seeds the
--     state on load and re-checks it every few seconds. The hinge angle is
--     only the fallback for a machine with no such switch.

local M = {}

-- ---------------------------------------------------------------------------
-- State
--
-- `hyprctl reload` destroys and rebuilds the whole Lua state -- verified by
-- setting a marker global, reloading three times, and finding it gone. So
-- there is deliberately no teardown code here: nothing survives to duplicate.
-- Measured after three consecutive reloads: exactly one of each switch bind,
-- one SUPER+R, and Hyprland at 0.2% CPU.
--
-- Exposed on _G purely so it can be inspected live:
--   hyprctl eval 'local S=_G.__fw12_tablet ...'
-- ---------------------------------------------------------------------------
local S = {}
_G.__fw12_tablet = S

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local POLL_MS = 250 -- accelerometer sample interval while in tablet mode
local SETTLE_TICKS = 2 -- consecutive agreeing samples before rotating (~500 ms)
local ONE_G = 16384 -- raw counts per g (scale = 0.000598550 m/s^2/count)
local DEAD_ZONE = math.floor(ONE_G * 2 / 5) -- 40% of 1 g to call an axis dominant
local TABLET_ANGLE = 200 -- hinge angle treated as "already folded" at load
local LAPTOP_ANGLE = 170 -- and the angle we treat as "unfolded again"
local RESYNC_TICKS = 20 -- ticks between fold-state safety checks (~5 s)
local SWITCH_DEV = "gpio-keys" -- as Hyprland names the SW_TABLET_MODE device

-- Focus handling while folded.
--
-- With follow_mouse = 1 the keyboard focus detaches from the window you are
-- typing into for as long as a finger rests on the on-screen keyboard, because
-- what is under the finger is a layer surface and not a window. A tap is too
-- brief to notice; a swipe or a resting hand holds it, and every key pressed in
-- that time goes nowhere. Measured on the Hyprland event socket: `activewindow`
-- goes empty on touch-down and comes back on release.
--
-- 2 means keyboard focus follows clicks into windows rather than the pointer.
--
-- It is applied only while the on-screen keyboard is actually up, not for all
-- of tablet mode, and that narrowing is deliberate. follow_mouse = 2 has its
-- own open focus bug upstream -- keyboard focus can be lost after focus
-- returns from a layer surface (hyprwm/Hyprland#9980) -- so this trades one
-- reliable failure for one intermittent one. Holding it only for the seconds
-- the keyboard is on screen is the difference between a window that is always
-- open and one that is open when it has to be. It is a mitigation, not a fix;
-- the fix is upstream.
local TABLET_FOLLOW_MOUSE = 2
local LAPTOP_FOLLOW_MOUSE = 1 -- Omarchy's default; change here if yours differs

-- Where the folded state is published for anything outside Hyprland to read.
-- The shell plugin watches this to decide whether to show its keyboard button.
-- A file rather than IPC because the reader is a Quickshell FileView, which
-- already does inotify, and because a plain word on disk is trivial to check
-- by hand when something looks wrong.
local MODE_PATH = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/gimbal-mode"

-- Written by the keyboard daemon from its own map and unmap: "visible" while
-- it is on screen, "hidden" otherwise. Read rather than pushed because the
-- daemon already publishes it for the bar icon and the knobs, and one more
-- reader of an existing file beats a second channel.
local OSK_PATH = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/gimbal-osk"

-- ---------------------------------------------------------------------------
-- sysfs helpers
--
-- IIO device numbering is NOT stable across boots: cros-ec-accel.11.auto was
-- accel-base on one boot and accel-display on the next. Only `label` and
-- `name` are safe, so every lookup goes through them. Lua has no directory
-- listing, but probing a small fixed range is enough and avoids the dependency.
-- ---------------------------------------------------------------------------
local IIO = "/sys/bus/iio/devices/iio:device"

local function read_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local function read_number(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*n")
    f:close()
    return v
end

local function write_mode(mode)
    local f = io.open(MODE_PATH, "w")
    if not f then return end
    f:write(mode)
    f:close()
end

local function find_iio(attr, want)
    for i = 0, 15 do
        local dir = IIO .. i
        if read_line(dir .. "/" .. attr) == want then return dir end
    end
    return nil
end

-- Hinge angle in degrees, or nil when there is no reading worth trusting.
--
-- Values above 360 are the EC's "indeterminate" sentinel rather than a real
-- angle, and it appears reliably during the fold itself, so it is reported
-- here as "no reading" instead of "past 360, therefore folded".
local function lid_angle()
    local dir = find_iio("name", "cros-ec-lid-angle")
    if not dir then return nil end
    local angle = read_number(dir .. "/in_angl_raw")
    if not angle or angle > 360 then return nil end
    return angle
end

-- Fold state from SW_TABLET_MODE, the switch the firmware uses to cut the
-- built-in keyboard. It is a level rather than an edge, so it answers "are we
-- folded" outright and a missed switch event cannot latch us in the wrong
-- mode.
--
-- It has to come through a helper because reading it is an EVIOCGSW ioctl and
-- Lua has no ioctl. The helper is asked for it *asynchronously*, and that is
-- not fastidiousness: closing an evdev file descriptor costs ~7 ms inside the
-- kernel's input core, measured, and this runs on the compositor's thread.
-- Blocking there for most of a frame every few seconds is the kind of stutter
-- this plugin exists to avoid.
--
-- So the helper writes its answer to a file and we read the file, which is
-- free. The answer names the device it came from and we hand that back next
-- time, so the helper can skip its own search.
local function fold_file()
    return (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/gimbal-fold"
end

-- Discard any outstanding answer. Called on every real transition, so a
-- reading taken before the fold can never be applied after it.
local function fold_invalidate()
    os.remove(fold_file())
    S.fold_asked = false
end

local function fold_request()
    local path = fold_file()
    os.remove(path)
    hl.dispatch(hl.dsp.exec_cmd(string.format(
        "fw12-foldstate %s > %s.part 2>/dev/null && mv %s.part %s",
        S.fold_dev or "", path, path, path)))
    S.fold_asked = true
end

-- Synchronous read, for load time only.
--
-- Worth the ~10 ms here and nowhere else: at load there is no previous answer
-- to fall back on, and starting in the wrong mode means the knobs are missing
-- (or worse, mapped over the desktop) until the first safety check comes
-- round. Once running, everything goes through fold_request/fold_read.
local function fold_now()
    local p = io.popen("fw12-foldstate 2>/dev/null")
    if not p then return nil end
    local line = p:read("*l")
    p:close()
    if not line then return nil end
    local level, dev = line:match("^([01])%s+(%S+)$")
    if not level then return nil end
    S.fold_dev = dev
    return level == "1"
end

-- true folded, false unfolded, nil no answer yet or no such switch.
local function fold_read()
    if not S.fold_asked then return nil end
    local f = io.open(fold_file())
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    local level, dev = line:match("^([01])%s+(%S+)$")
    if not level then return nil end
    S.fold_dev = dev
    return level == "1"
end

-- Only touched when the answer changes, so this costs one small file read per
-- tick while folded and nothing at all in laptop mode.
local function apply_follow_mouse()
    local want = LAPTOP_FOLLOW_MOUSE
    if S.tablet and read_line(OSK_PATH) == "visible" then
        want = TABLET_FOLLOW_MOUSE
    end
    if want == S.follow_mouse then return end
    hl.config({ input = { follow_mouse = want } })
    S.follow_mouse = want
end

local function accel_dir()
    if S.accel and read_line(S.accel .. "/label") == "accel-display" then
        return S.accel
    end
    S.accel = find_iio("label", "accel-display")
    if not S.accel then
        hl.notification.create({
            text = "gimbal: no accel-display sensor; rotation disabled",
            timeout = 5000,
        })
    end
    return S.accel
end

-- ---------------------------------------------------------------------------
-- Orientation
--
-- Which way up the panel is, per dominant gravity axis. Measured on this
-- machine against iio-sensor-proxy and replayed over 90 captured samples.
--
-- This is the one table in the file that is NOT guessable, and the one most
-- likely to be wrong on a machine that is not mine: it depends on how the
-- panel and its sensor are mounted, which differs between units and even
-- between panel suppliers for the same model. Every other number here is
-- either read from the hardware or a threshold with slack in it.
--
-- So it is a table rather than four literals buried in a branch. If rotation
-- is wrong on your machine, it is almost certainly only this:
--
--   sideways      -- landscape and portrait swapped -- swap the y_* and x_*
--                    pairs with each other
--   mirrored      -- rotates the wrong way round     -- swap x_pos and x_neg
--   upside down   -- 180 degrees out                 -- swap y_pos and y_neg
--
-- Transform numbers are Wayland's: 0 normal, 1 left-up, 2 bottom-up,
-- 3 right-up. |z| dominant means lying flat, which carries no orientation
-- information at all, so the previous one stands.
local ORIENT = {
    y_pos = 0, -- normal
    y_neg = 2, -- bottom-up
    x_pos = 3, -- right-up
    x_neg = 1, -- left-up
}
-- ---------------------------------------------------------------------------
local function classify(x, y, z)
    local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
    if az > ax and az > ay then return nil end -- lying flat: no information
    if ay > ax then
        if ay < DEAD_ZONE then return nil end
        return y > 0 and ORIENT.y_pos or ORIENT.y_neg
    end
    if ax < DEAD_ZONE then return nil end
    return x > 0 and ORIENT.x_pos or ORIENT.x_neg
end

-- ---------------------------------------------------------------------------
-- Apply
--
-- Monitor, touch and stylus must move together or the pen and finger stop
-- landing where the user is pointing. Note `hyprctl keyword` does NOT work on
-- a Lua config -- Hyprland refuses it -- which is why this is a direct call
-- rather than an IPC command.
-- ---------------------------------------------------------------------------
local function apply(transform)
    local monitors = hl.get_monitors()
    local target = nil
    for _, m in ipairs(monitors) do
        if m.name:sub(1, 3) == "eDP" then
            target = m
            break
        end
    end
    target = target or monitors[1]
    if not target then return end

    hl.monitor({
        output = target.name,
        mode = "preferred",
        position = "auto",
        scale = target.scale,
        transform = transform,
    })
    hl.config({
        input = {
            touchdevice = { transform = transform },
            tablet = { transform = transform },
        },
    })
    S.applied = transform
end

-- ---------------------------------------------------------------------------
-- Poll
-- ---------------------------------------------------------------------------
-- Declared here because the safety net below can change mode; both are
-- defined further down with the rest of the transitions.
local enter_tablet, leave_tablet

-- Rotation, from the accelerometer. Only meaningful while folded.
local function rotate_tick()
    local dir = accel_dir()
    if not dir then return end

    local x = read_number(dir .. "/in_accel_x_raw")
    local y = read_number(dir .. "/in_accel_y_raw")
    local z = read_number(dir .. "/in_accel_z_raw")
    if not (x and y and z) then
        S.accel = nil -- renumbered or unbound; re-resolve next tick
        return
    end

    local want = classify(x, y, z)
    if want == nil or want == S.applied then
        S.pending, S.pending_n = nil, 0
        return
    end

    if want == S.pending then
        S.pending_n = S.pending_n + 1
        if S.pending_n >= SETTLE_TICKS then
            apply(want)
            S.pending, S.pending_n = nil, 0
        end
    else
        S.pending, S.pending_n = want, 1
    end
end

-- Fold-state safety net.
--
-- The switch binds are edge-triggered: switch:on enters tablet mode,
-- switch:off leaves it, and until this existed nothing ever re-checked. One
-- missed edge latched the wrong mode indefinitely -- knob overlays mapped
-- over the desktop, follow_mouse on the tablet value, rotation live -- with
-- no way back until a later fold happened to land an edge. It does not even
-- present as a mode bug: the knob surfaces are full-screen with only an input
-- mask holding the pointer out, so what you see is a cursor that keeps
-- vanishing and coming back on a desktop that looks fine.
--
-- SW_TABLET_MODE is a level, so it answers the question outright and no
-- amount of missed events can survive one cycle of this. The hinge angle is
-- the fallback and a poorer one: it needs a threshold, and mid-fold it
-- reports a sentinel instead of an angle.
local function resync()
    S.resync_n = (S.resync_n or 0) + 1
    if S.resync_n < RESYNC_TICKS then return false end
    S.resync_n = 0

    local folded = fold_read()
    if folded == nil then
        local angle = lid_angle()
        if angle then
            if S.tablet and angle < LAPTOP_ANGLE then
                folded = false
            elseif not S.tablet and angle >= TABLET_ANGLE then
                folded = true
            end
        end
    end

    local changed = false
    if folded ~= nil and folded ~= S.tablet then
        if folded then enter_tablet() else leave_tablet() end
        changed = true
    end

    -- Asked for after acting, not before: a transition discards any answer in
    -- flight, so requesting first would just throw this one away.
    fold_request()
    return changed
end

local function tick()
    if resync() then return end
    apply_follow_mouse()
    if not S.tablet or S.locked then return end
    rotate_tick()
end

-- ---------------------------------------------------------------------------
-- Mode transitions
-- ---------------------------------------------------------------------------

-- Rotation lock. SUPER+R is free in Omarchy (the existing R binds are all
-- SUPER+CTRL variants).
--
-- Bound only while folded. It has no meaning in laptop mode, where nothing
-- rotates anyway, so leaving it live there just means an accidental press can
-- arm a setting that does nothing now and breaks rotation later.
local function toggle_lock()
    S.locked = not S.locked
    hl.notification.create({
        text = S.locked and "Rotation locked" or "Rotation unlocked",
        timeout = 1500,
    })
    if not S.locked then rotate_tick() end
end

function enter_tablet()
    S.tablet = true
    fold_invalidate()
    S.pending, S.pending_n = nil, 0
    write_mode("tablet")
    apply_follow_mouse()
    if not S.lock_bound then
        hl.bind("SUPER + R", toggle_lock, { description = "Toggle auto-rotation lock" })
        S.lock_bound = true
    end
    rotate_tick() -- catch up to however the device is being held right now
end

function leave_tablet()
    S.tablet = false
    fold_invalidate()
    S.pending, S.pending_n = nil, 0
    write_mode("laptop")
    apply_follow_mouse()
    -- Unfolding clears the rotation lock.
    --
    -- The lock is for holding the device at an angle you do not want followed
    -- -- reading in bed, mostly -- which is a thing that ends when you fold it
    -- back into a laptop. Carrying it forward meant it could sit on silently
    -- for days: nothing shows it is set, and the symptom is auto-rotation
    -- simply not working, which looks exactly like a bug in the sensor path.
    -- That happened, and it cost an evening looking in the wrong place.
    S.locked = false
    if S.lock_bound then
        hl.unbind("SUPER + R")
        S.lock_bound = false
    end
    if S.applied ~= 0 then apply(0) end
end

-- Switch binds are edge-triggered, so on load they cannot say where the hinge
-- currently is. The switch level can, and the angle is the fallback for a
-- machine that has no such switch.
local function seed_initial_state()
    local folded = fold_now()
    if folded ~= nil then return folded end
    local angle = lid_angle()
    return angle ~= nil and angle >= TABLET_ANGLE
end

-- ---------------------------------------------------------------------------
-- Wire up
-- ---------------------------------------------------------------------------
S.locked = false
S.lock_bound = false
S.applied = 0
S.follow_mouse = LAPTOP_FOLLOW_MOUSE
S.pending, S.pending_n = nil, 0

-- Toggle the on-screen keyboard.
--
-- Bound always, not only while folded, because its most useful job is the
-- reverse of what it sounds like: dismissing the on-screen keyboard *from* the
-- on-screen keyboard, whose Framework key is a real Super. Aiming for a 32 px
-- strip is not always what you want, and there is nothing else to press.
--
-- SUPER + B for "board". SUPER + K is Omarchy's own keybindings menu
-- (bindings/utilities.lua), so it is not available; the free SUPER letters on
-- a stock install are A B D E H I M N Q U Y Z.
hl.bind("SUPER + B", function()
    hl.dispatch(hl.dsp.exec_cmd(
        "omarchy-shell shell call io.github.mechanicsunlocked.gimbal toggle ''"))
end, { description = "Toggle the on-screen keyboard" })

hl.bind("switch:on:" .. SWITCH_DEV, enter_tablet, { locked = true })
hl.bind("switch:off:" .. SWITCH_DEV, leave_tablet, { locked = true })

S.timer = hl.timer(tick, { timeout = POLL_MS, type = "repeat" })

-- Publish a state before deciding, so a reader that starts between here and
-- the seed below never sees a stale word from the previous Hyprland session.
write_mode("laptop")
if seed_initial_state() then enter_tablet() end

function M.status()
    return {
        tablet = S.tablet,
        locked = S.locked,
        applied = S.applied,
        accel = S.accel,
    }
end

-- Clear the lock without a config reload.
--
-- Added because diagnosing a stuck lock ended with `hyprctl reload` as the
-- only way out, which throws away the whole Lua state to change one boolean.
--
--   hyprctl eval 'require("hypr.gimbal").set_locked(false)'
function M.set_locked(v)
    S.locked = v and true or false
    if not S.locked then rotate_tick() end
end

return M

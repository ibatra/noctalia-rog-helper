# Sleep & lid: a caffeinate-style section for rog-helper

Status: design, awaiting review. Branch `awake`.

## Why

The laptop (GU606AW, s2idle) had three problems. It turned off right after waking,
because the press that woke it reached logind as a power-key press. The lid was
handled by root-owned logind drop-ins that could only be changed with sudo. And
there was no quick way to stay awake for a while. The user wants all of this as
live controls in the rog-helper panel, with Amphetamine-style modes, timers and
safety stops.

What the user asked for, in their words:
- "wire these settings in … as a section in my top bar settings … so i can keep toggling"
- "different mode options … something like caffeinate etc with more features, nicer ux + ui"
- Use cases, all four: lid shut while jobs keep going; lid shut with an external
  monitor; screen stays on; awake for a while. "just let me set whatever".
- Decisions: it goes in the rog-helper panel with no new bar icon; clamshell
  screen handling is picked in the panel; the power button is a panel setting;
  `20-lid.conf` is deleted once the plugin owns the lid.

## Facts this rests on

These were checked on this machine (systemd 261.3, Noctalia 5.1.0, Hyprland 0.56.2).

- **Locks need no root and no prompt.** An active-session user may take
  `handle-lid-switch`, `sleep` (block and block-weak) and `idle` locks
  (`pkcheck`, org.freedesktop.login1.policy: allow_active=yes).
- **A held `handle-lid-switch` lock makes logind ignore the lid completely.**
  HandleLidSwitch, HandleLidSwitchExternalPower and HandleLidSwitchDocked are
  then irrelevant. A `sleep` lock does **not** stop lid suspend, because
  LidSwitchIgnoreInhibited=yes.
- **Releasing the lid lock while the lid is closed suspends immediately if
  logind's own rule says so** (for example on battery). logind re-checks the lid
  after every event while it is closed, and closing the lock's FIFO is an event
  (logind-button.c, logind-inhibit.c v261).
- **Noctalia's idle timers respect a `--what=idle --mode=block` lock.** They do
  not respect `block-weak` (screensaver_service.cpp watches only
  BlockInhibited). Its caffeine is the same kind of lock, but it resets to off
  when Noctalia restarts and has no status IPC, so the plugin keeps its own.
- **`--mode=block-weak` for sleep** still lets the user's own explicit suspend
  (session menu) and root's suspend (UPower critical battery) through. A plain
  `block` would refuse both.
- **The lid state** is readable without privileges from
  `/proc/acpi/button/lid/LID0/state`. **The charger** is on
  `/sys/class/power_supply/ACAD/online` (type Mains), with change events through
  udev. **Temperature**: `x86_pkg_temp` thermal zone (millidegrees).
- **Hyprland**: `hyprctl dispatch 'hl.dsp.dpms({ action = "off", monitor = "<eDP>" })'`
  turns a single panel off and keeps its output (no workspace moves). `hl.monitor({ …,
  disabled = true })` removes the output. On 0.56.2 that is exposed to the
  "global wl_output is unavailable" client-kill race (Hyprland #15635, omarchy
  #7853), so disabling is never paired with a reload and never used when eDP is
  the only output. `hyprctl keyword` is rejected on Lua configs. The eDP name can
  change (eDP-1 or eDP-2 in dGPU MUX mode), so it is discovered, never hard-coded.
- **Any all-monitor DPMS-on relights a DPMS-off eDP**, for example Noctalia's idle
  resume. While the lid is closed the watcher re-asserts off.

## What the user sees

### Panel: main view

The keyboard track sits in the tracks group of the main view. Below it goes one
track row, iconRow with glyph `coffee`:

```
☕   Off · 1h · 2h · ∞          1:42
```

Picking a duration starts a session in the last-used kind (System or Screen on;
System by default). Picking Off ends it. The trailing caption shows the time
left, "∞", or nothing. A fourth nav button, **Sleep** (glyph `moon`), joins
Power, Fans and Lighting.

### Panel: Sleep sub-view

This sub-view uses the existing building blocks (tiles, tracks, toggleRow, slider
row, caption, notes) and copy tone.

```
‹ Sleep & lid                         Awake · 1:42 left
 [ ☾ Normal ] [ ⚙ System ] [ ☕ Screen on ]        tiles
 For            30m · 1h · 2h · 4h · ∞             track
 Lid closed
   On charger     Sleep · Stay awake                track
   On battery     Sleep · While awake · Stay awake  track
   Screen         Off · Off + lock                  track
   With monitor   Turn off · Move windows           track
 Power button     Nothing · Lock · Sleep · Menu     track
 Stop when
   Battery below   ───●───  20%                     slider (5–50, off at 0)
   Unplugged                            ○           toggle
   Hot with lid shut on battery         ●           toggle
 Awake because: lid closed on charger · ends 17:40  caption
```

- **Normal / System / Screen on**
  - Normal: no session.
  - System: the machine doesn't sleep, and the screen still turns off and locks
    on Noctalia's timers.
  - Screen on: no screen-off, no lock, no sleep.
  - Picking System or Screen on starts a session for the selected **For**.
    Changing **For** during a session restarts the timer from now, the way
    PowerToys does.
- **Lid closed, per power source.**
  - On charger defaults to Stay awake, which matches today's `20-lid.conf`.
  - On battery defaults to Sleep.
  - "While awake" keeps the lid-closed laptop up only while a session is running.
- **Screen**: what happens to the internal panel when the lid closes and the
  machine stays up. Off turns eDP off with DPMS; Off + lock also locks the
  session with `noctalia msg session lock`.
- **With monitor**: only when an external output is connected.
  - Turn off: DPMS off. This is the default and the safe choice.
  - Move windows: disable eDP so its workspaces move to the external monitor.
    It is re-enabled with the full rule (preferred mode, scale 1.25) when the
    lid opens or the monitor is unplugged. The caption warns that this is
    experimental on this Hyprland build.
- **Power button**: what a short press does.
  - Nothing is the default and matches today.
  - Lock, Sleep, or Menu, which opens Noctalia's session panel.
  - A long press stays logind's poweroff.
  - A press within 5 s of waking from suspend is always ignored, which is the
    original bug.
- **Stop when.** These end a session. They also end lid-closed stay-awake on
  battery, which makes the laptop sleep.
  - Battery below N%, default 20.
  - Unplugged, default off.
  - Hot: `x86_pkg_temp` ≥ 95 °C for 60 s with the lid closed on battery, default
    on. The threshold is a guess, to be checked against this CPU's normal load
    temperatures before release.
  - Every stop sends a notification saying why, for example "Awake ended:
    battery 19%" or "Sleeping: CPU at 96 °C with the lid shut on battery".
  - Lid-closed stay-awake on battery stays suppressed while its stop condition
    holds, that is battery below the floor or still hot. It comes back by itself
    once the condition clears. A session that was ended does not restart.
- **Awake because**: a single caption naming the reasons locks are held, plus the
  end time if there is one.

### Bar and elsewhere

- **Bar**: the rog glyph gets a small primary dot while a session is running.
  Standing lid rules don't count, or the dot would be on whenever the charger is
  in. It uses `barWidget.render` with the glyph plus a 5 px dot and keeps the
  glyph in `secondary`. The tooltip gains `Awake: 1:42 left`, and `Lid: stays
  awake on charger` when that rule is active.
- **Control Center tile** (`[[shortcut]]`): "Stay awake". Click toggles a session
  in the last kind and duration; the tile shows active. The user adds it to the
  Control Center themselves.
- **IPC and keybinds**: `rogctl awake toggle|start <kind> <mins|inf>|stop`, and
  `noctalia msg plugin ishaan/rog-helper:panel all act awake:toggle`.

## Architecture

```
panel.luau ──require──▶ awake_view.luau        (UI only; reads/writes via awakectl)
widget.luau / shortcut.luau                     (dot, tooltip, tile; read awake status)
        │ runAsync
        ▼
bin/awakectl  ── status | set k=v | start | stop | toggle | power-key | watch
        │ writes ~/.config/rog-helper/awake (key=value), signals the watcher
        ▼
rog-helper-awake.service  →  awakectl watch
        ├─ inputs: config file, ACAD/online (udev), lid (/proc), BAT1 capacity,
        │          x86_pkg_temp, clock, external monitors (hyprctl monitors -j)
        ├─ decide(): pure function → wanted locks + screen action + stop reason
        └─ effects: systemd-inhibit children (one per lock kind), DPMS / monitor
                    rule for eDP, notifications, session end
```

### Why a separate `awakectl` and view file

`rogctl` already has 1035 lines and `panel.luau` has 1055. The new feature gets its own
backend script, `bin/awakectl`, and its own view module, `awake_view.luau`, loaded
with `require` (API 22). Both follow rog-helper's conventions:
- `set -u`, `run()` dry-run wrapper with `dry-run:` lines on fd 9
- exit codes 0/1/2/3
- `key=value` output
- `cfg_set` with flock and atomic mv
- section dividers
- a usage header that doubles as help

`ac_online` is copied verbatim from rogctl so both agree on what "on charger" means.

### Config and state (`~/.config/rog-helper/awake`)

```
kind=system|screen          last-used session kind
session=none|system|screen  current session
until=<epoch>|inf|          session deadline
mins=60                     last-used duration
lid_ac=awake|sleep
lid_bat=sleep|session|awake
lid_screen=off|lock
lid_monitor=dpms|disable
power_key=none|lock|sleep|menu
stop_battery=20             0 = off
stop_unplug=0
stop_hot=1
```

The deadline is an absolute epoch, so it survives a restart of the watcher. A
session that expired while nothing was running is cleared on start. A session
is also cleared on boot, the way GNOME Caffeine's restore-state=false works:
the watcher compares the boot id it recorded.

### The decision function

`decide` is a pure bash function. Its inputs:
- config
- ac (0/1)
- lid (open/closed)
- battery %
- hot (0/1: over threshold for 60 s)
- now
- external (0/1)

Its outputs:
- `want_idle` (screen session)
- `want_sleep` (any session)
- `want_lid` (lid rule for the current source, or `session` with a live session)
- `screen=on|dpms|disable`
- `stop=<reason>|` (ends the session and clears lid stay-awake on battery)

Every rule in "What the user sees" maps to a line in `decide`, and the tests
exercise every one of them.

### Locks

Each lock is one `systemd-inhibit --no-ask-password --who="ROG helper" --why=<reason>
--what=<w> --mode=<m> sleep infinity` child, started or killed as `decide` changes:

| lock | what | mode |
|---|---|---|
| idle | `idle` | `block` (Noctalia ignores block-weak) |
| sleep | `sleep` | `block-weak` |
| lid | `handle-lid-switch` | `block-weak` |

- On exit, the watcher's trap kills the children. systemd-inhibit's
  FORK_DEATHSIG covers `sleep`.
- On start, it kills any stale `who="ROG helper"` locks owned by this uid, found
  with `systemd-inhibit --list --json=short`.
- The watcher is a systemd user unit, not a Noctalia runStream, so it survives
  Noctalia restarts and settings reloads.

### Watch loop

- The loop blocks on `read -t 2` from `udevadm monitor --udev
  --subsystem-match=power_supply`, rog-helper's pattern. That gives an instant
  reaction to plug and unplug, and polls lid, battery, temperature and deadline
  every 2 s.
- It re-reads config on SIGHUP. awakectl sends it after every `set`, `start`,
  `stop` or `toggle`.
- On each pass: read the inputs, run `decide`, apply the difference, and write a
  status file (`~/.config/rog-helper/awake.status`, key=value) for the UI.
- Order matters on a stop or unplug with the lid closed on battery:
  1. Run the notification.
  2. Release the lid lock last. logind then suspends by its own rule.
  3. If logind doesn't suspend within 5 s (for example because it treats USB-C
     PD as external power), run `systemctl suspend`.
- **Screen actions** run only on a lid edge or when re-asserting while the lid
  is closed:
  - DPMS through `hyprctl dispatch 'hl.dsp.dpms({ action = "off", monitor = "<eDP>" })'`.
  - Checked once per pass with `hyprctl monitors -j` (dpmsStatus), so it is sent
    only when needed.
  - `disable` only with an external output connected, never together with a
    reload, and only 2 s after that output first appeared.
  - Undone on lid open, on the external output going away, and on watcher exit.

### Unit lifecycle

- `rog-helper-awake.service` is written by `awakectl` and rewritten whenever its
  content differs. This avoids rogctl's stale-unit problem.
- It hangs off `graphical-session.target`, like rog-helper-auto.
- It is enabled whenever any setting needs it: a session, or a lid rule other
  than Sleep. Otherwise it is disabled, and the file stays. The power key needs
  no watcher, because `awakectl power-key` runs on its own.
- With lid_ac=awake as the default, it runs whenever the user is logged in. That
  is the intended replacement for 20-lid.conf.

### Power key

- One line is added to `~/.config/hypr/config/binds.lua`:
  `hl.bind("XF86PowerOff", hl.dsp.exec_cmd("<pluginDir>/bin/awakectl power-key"), { locked = true })`.
  The implementation checks that Hyprland actually receives `XF86PowerOff` while
  `HandlePowerKey=ignore`. If it doesn't, the row is hidden.
- `awakectl power-key` ignores the press if systemd-suspend.service finished
  within the last 5 s (`systemctl show -p ExecMainExitTimestamp`, realtime). It
  then runs the configured action:
  - lock: `noctalia msg session lock`
  - sleep: `systemctl suspend`
  - menu: Noctalia's session panel, through its panel id
- `10-power-key.conf` (HandlePowerKey=ignore) stays. It is what hands the short
  press to Hyprland.

## Rollout

1. Build on branch `awake` in `~/.local/share/noctalia-plugins`, with dry-run first.
2. The user deletes `20-lid.conf`, runs `sudo rm
   /etc/systemd/logind.conf.d/20-lid.conf && sudo systemctl kill -s HUP
   systemd-logind`, only once the watcher is running with lid_ac=awake.
3. The user adds the power-key bind (or accepts a reviewed diff for binds.lua).

## Testing

- **`decide` table tests**: `rog-helper/tests/awake_decide.sh`, plain bash and
  no framework, since the repo has none. One case per rule: sessions × lid
  rules × ac × lid × battery × hot × deadline × external, plus the stop reasons.
- **Watcher integration in dry-run with a fake machine**:
  - `AWAKE_SYSROOT` redirects the lid, ACAD, BAT1 and thermal paths to a temp
    tree.
  - `AWAKE_HYPRCTL` stubs hyprctl.
  - The test flips files and asserts which systemd-inhibit or hyprctl commands
    the `dry-run:` lines show.
- **Real locks, lid untouched**: start a session and check `systemd-inhibit --list`
  plus logind `BlockInhibited` / `BlockWeakInhibited`. Stop it and check the
  locks are gone. This needs no hardware action.
- **Hyprland DPMS and disable** only in the nested harness
  (`~/.cache/hands-port/nested`) against headless outputs, never live first.
- **Physical checks by the user**, with a checklist:
  - lid close on charger and on battery
  - unplug while closed
  - external monitor with each screen choice
  - power key after a wake
  - the hot stop, by watching temperature under a build with the lid shut on
    battery
- **UI**: open the panel through `noctalia msg plugin … all view sleep`, and have
  the user check it by eye. Every row can also be driven with `act awake:<…>` IPC.

## Out of scope

- "Until a clock time", and "while a process runs" (`caffeinate -w`).
- App or fullscreen triggers, and Amphetamine's trigger matrix.
- Hibernate. It isn't available: zram only, no resume device.
- Editing logind drop-ins from the panel.
- The lid-open-doesn't-wake problem. That's firmware or s2idle, and is tracked
  separately (`deep` sleep is the next experiment).

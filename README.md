# noctalia-rog-helper

A [G-Helper](https://github.com/seerge/g-helper)-style control panel for ASUS ROG laptops, as a
[Noctalia](https://noctalia.dev) shell plugin. One bar icon, one compact panel: performance mode,
GPU mode, refresh rate, battery limit, keyboard lighting, fans and power limits.

<p align="center"><img src="docs/panel.png" alt="The rog-helper panel" width="360"></p>

Not affiliated with G-Helper or ASUS; it drives the same knobs through `asusctl`/`asusd`,
`power-profiles-daemon` and sysfs.

## What's in it

- **Header**: battery %, charger type, power draw on battery (charge rate while charging), with a
  6-minute trace, CPU temperature and dGPU state. The trace only samples on battery, where it is
  useful for spotting the dGPU waking up.
- **Performance**: Silent / Balanced / Turbo, per power source (plugged in vs battery).
- **GPU**: Eco / Standard / Optimized (Eco on battery, Standard on AC) / Ultimate (MUX, needs a
  restart).
- **Screen**: 60 Hz / max / Auto (60 Hz on battery).
- **Battery**: charge limit plus "charge to 100% once".
- **Keyboard**: brightness, effect (Static, Breathe, Pulse, Cycle, Wave), colours, speed,
  lighting power states.
- **Fans**: CPU/GPU curves per profile, with Stock / Quiet / Cool presets. Curves that would run
  cooler than stock at high temperatures are rejected.
- **Power**: CPU PL1/PL2 limits per mode via Intel RAPL, 5 W up to the firmware default (can only lower power; like G-Helper, no custom limits unless you set them), CPU boost.
- **Slash** LED bar and boot sound, on models that have them.

Controls the machine doesn't have (dGPU switch, MUX, internal display refresh rate, keyboard
backlight, charge limit, CPU power limits, CPU boost, fan curves, Aura, Slash, boot sound) are
hidden. Only the GU606AW has been tested, so other models may still show a control that does
nothing.

## Sleep & lid

A caffeinate-style "Stay awake" session, plus lid, power-key and stop rules, live in a **Sleep**
sub-view of the panel (the moon icon next to Power, Fans and Lighting) and on a **☕ Awake** row on
the main view. The bar glyph gets a small dot while a session is running.

- **Normal / System / Screen on**: Normal is no session. System means the machine doesn't sleep,
  and the screen still turns off and locks on Noctalia's timers. Screen on means no screen-off, no
  lock, no sleep. Picking System or Screen on starts a session for the chosen **For** duration
  (30m / 1h / 2h / 4h / ∞); changing **For** during a session restarts the timer from now.
- **Lid closed**, set separately for on charger and on battery: Sleep, Stay awake, or (on battery)
  While awake, which keeps the lid-closed laptop up only while a session is running. On charger
  defaults to Stay awake, which matches what `20-lid.conf` did; on battery it defaults to Sleep.
- **Screen** (while the lid is closed and the machine stays up): Off turns the internal panel off
  with DPMS; Off + lock also locks the session.
- **With monitor**, shown only with an external output connected: Turn off (DPMS; the default and
  the safe choice) or Move windows (disables the internal panel so its workspaces move to the
  external monitor; experimental on this Hyprland build).
- **Power button**: what a short press does. Nothing is the default and matches today; the other
  choices are Lock, Sleep, or Menu (Noctalia's session panel). A long press still means poweroff; a
  press within 5 s of waking from suspend is always ignored.
- **Stop when**: these end a session (and lid-closed stay-awake on battery, which then lets the
  laptop sleep) — battery below a percentage (default 20%, 0 = off), unplugged (default off), or
  hot: the CPU package at or above 95 °C for 60 s with the lid closed on battery (default on).
  Every stop sends a notification saying why.

### Power key

The press that wakes the machine also reaches logind as a power-key press, which used to power it
straight back off. `HandlePowerKey=ignore` in `logind.conf` must stay as it is — it's what hands
the key to Hyprland instead of letting logind act on it — and one bind picks it up from there. Add
to `~/.config/hypr/config/binds.lua`:

```lua
hl.bind("XF86PowerOff", hl.dsp.exec_cmd("~/.local/share/noctalia-plugins/rog-helper/bin/awakectl power-key"), { locked = true })
```

### Taking over from `20-lid.conf`

Once the watcher is running with "On charger" set to Stay awake, the old lid override is
redundant. Remove it once (needs sudo):

```sh
sudo rm /etc/systemd/logind.conf.d/20-lid.conf && sudo systemctl kill -s HUP systemd-logind
```

### Locks

Every idle, sleep or lid lock the plugin holds shows in `systemd-inhibit --list` as `ROG helper`.

### Control Center tile

Add a "Stay awake" tile to Noctalia's Control Center yourself:

```toml
[[control_center.shortcuts]]
type = "ishaan/rog-helper:awake"
```

Click toggles the last-used session; right-click opens the panel's Sleep view.

### Keybind

Bind any key to toggle Stay awake without opening the panel:

```sh
~/.local/share/noctalia-plugins/rog-helper/bin/awakectl toggle
```

## Requirements

- Noctalia 5.1+ (plugin API 30)
- `asusctl` / `asusd` 6.5+
- `power-profiles-daemon`
- `pkexec` and a polkit agent (Noctalia's built-in one works) for the few root-only actions
- `fuser` (`psmisc`); without it Eco is always deferred to the next login
- Hyprland for the refresh-rate control (everything else is compositor-agnostic)
- For the automations (Optimized, Auto refresh, Silent on battery, per-source profiles, custom
  CPU limits): a systemd-managed graphical session, e.g. Hyprland started through
  [uwsm](https://github.com/Vladimir-csp/uwsm). The units hang off `graphical-session.target`,
  which plain Hyprland from a TTY or a display manager never starts, so they would silently not
  run.

## Install

```sh
git clone https://github.com/ibatra/noctalia-rog-helper ~/.local/share/noctalia-rog-helper
noctalia msg plugins source add local path ~/.local/share/noctalia-rog-helper
noctalia msg plugins enable ishaan/rog-helper
```

Then add the `rog` widget to a bar:

```toml
[widget.rog]
type = "ishaan/rog-helper:bar"
```

To open the panel from a key (for example the ROG key in Hyprland):

```lua
hl.bind("XF86Launch1", hl.dsp.exec_cmd("noctalia msg panel-toggle ishaan/rog-helper:panel"))
```

## Things to know

- **Silent may need your password.** When `asusctl profile list` offers Quiet, Silent goes
  through asusd like the other modes. On Intel Panther Lake models the kernel hides Quiet (see
  [asusctl#387](https://github.com/OpenGamingCollective/asusctl/issues/387)), so until a fixed
  kernel or asusd is installed, Silent writes each platform-profile handler directly through
  `pkexec`, and Silent on battery asks for the password after every unplug. CPU power limits and
  CPU boost also use `pkexec`; limits only prompt when they actually need to change.
- **Eco waits for the next login** if anything has the dGPU open or awake (the compositor,
  `nvidia-powerd`, `nvidia-persistenced`), because cutting its power under a running session can
  crash it. Ultimate needs a restart.
- **Optimized, Auto refresh, Silent on battery, deferred per-source profiles and custom CPU
  limits** install two small systemd user units (`rog-helper-login`, `rog-helper-auto`). They
  are disabled when nothing needs them; the files stay in `~/.config/systemd/user`.
- The plugin never uses `nvidia-smi` or NVML, since that would wake a sleeping dGPU.
- `touch ~/.config/rog-helper/dry-run` (or the plugin's `dry_run` setting, which creates that
  file for the background units) turns every action into a notification or log line showing the
  command it would run.

## Status

Built and tested on a ROG Zephyrus G16 GU606AW (2026, Intel Panther Lake, RTX dGPU), CachyOS,
kernel 7.2. Performance modes (including Silent), refresh rate, battery limit, keyboard lighting,
Slash and boot sound have been used live. GPU mode switching, RAPL limits, fan presets and the
Optimized/Auto watchers have so far only been exercised in dry-run mode. Reports from other
models are welcome.

## License

MIT

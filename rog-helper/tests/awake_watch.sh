#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mk() { mkdir -p "$(dirname "$T/$1")"; printf '%s\n' "$2" > "$T/$1"; }
mk sys/class/power_supply/ACAD/type Mains; mk sys/class/power_supply/ACAD/online 1
mk sys/class/power_supply/BAT1/capacity 80
mk proc/acpi/button/lid/LID0/state "state:      open"
mk sys/class/thermal/thermal_zone0/type x86_pkg_temp; mk sys/class/thermal/thermal_zone0/temp 50000
mk sys/class/drm/card0-eDP-1/status connected
mkdir -p "$T/conf"
cat > "$T/hyprctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/hypr.log"
case "\$*" in "monitors"*) echo '[{"name":"eDP-1","dpmsStatus":true}]' ;; esac
EOF
chmod +x "$T/hyprctl"
pass() {  # pass <now> -> stderr of one dry-run pass
  AWAKE_SYSROOT=$T AWAKE_CONF_DIR=$T/conf AWAKE_HYPRCTL=$T/hyprctl AWAKE_NOW=$1 \
    AWAKE_NOTIFY="echo notify" AWAKE_SUSPEND="echo suspend" AWAKE_KEEP=1 \
    "$AWAKECTL" --dry-run watch --once 2>&1
}
conf() { printf '%s\n' "$@" > "$T/conf/awake"; }

conf "lid_ac=awake"
out=$(pass 1000)
has "charger: lid lock taken" "dry-run: inhibit lid on" "$out"
lacks "charger: no sleep lock" "inhibit sleep on" "$out"
has "status written" "held=lid" "$(cat "$T/conf/awake.status")"

conf "session=screen" "until=5000"
out=$(pass 1000)
has "screen session: idle lock" "dry-run: inhibit idle on" "$out"
has "screen session: sleep lock" "dry-run: inhibit sleep on" "$out"

mk proc/acpi/button/lid/LID0/state "state:      closed"
out=$(pass 1000)
has "lid closed on charger: dpms off" "hl.dsp.dpms({ action = \"off\", monitor = \"eDP-1\" })" "$out"

mk sys/class/power_supply/ACAD/online 0
conf "lid_bat=sleep"
out=$(pass 1000)
lacks "unplugged with lid closed: lid not held" "inhibit lid on" "$out"
# Review Focus 1: the suspend fallback fires after 10 s with nothing holding the machine up
out=$(AWAKE_SYSROOT=$T AWAKE_CONF_DIR=$T/conf AWAKE_HYPRCTL=$T/hyprctl AWAKE_NOW=1000 \
  AWAKE_NOTIFY="echo notify" AWAKE_SUSPEND="echo suspend" AWAKE_TEST_SUSPEND_AFTER=0 AWAKE_TEST_RESUMED_AT=0 \
  "$AWAKECTL" --dry-run watch --once 2>&1)
has "suspend fallback" "dry-run: echo suspend" "$out"

# timer end notifies and clears the session
mk sys/class/power_supply/ACAD/online 1; mk proc/acpi/button/lid/LID0/state "state:      open"
conf "session=system" "until=900"
out=$(pass 1000)
has "time end notifies" "Awake ended: time's up" "$out"
eq "time end clears session" "" "$(grep '^session=system' "$T/conf/awake" || true)"
has "time end recorded" "ended=time@1000" "$(cat "$T/conf/awake.status")"

# exit without AWAKE_KEEP drops every lock and reports nothing held
conf "session=system" "until=inf"
out=$(AWAKE_SYSROOT=$T AWAKE_CONF_DIR=$T/conf AWAKE_HYPRCTL=$T/hyprctl AWAKE_NOW=1000 \
  AWAKE_NOTIFY="echo notify" AWAKE_SUSPEND="echo suspend" "$AWAKECTL" --dry-run watch --once 2>&1)
has "exit drops the sleep lock" "dry-run: inhibit sleep off" "$out"
has "exit drops the lid lock" "dry-run: inhibit lid off" "$out"
eq "exit reports nothing held" "held=" "$(grep '^held=' "$T/conf/awake.status")"
eq "exit leaves the session alone" "session=system" "$(grep '^session=' "$T/conf/awake")"

# a new boot ends the session silently (restore-state=false)
mk proc/sys/kernel/random/boot_id new-boot
conf "session=system" "until=inf" "boot_id=old-boot"
out=$(pass 1000)
eq "boot ends session" "session=none" "$(grep '^session=' "$T/conf/awake")"
lacks "boot end is silent" "notify" "$out"
has "boot end recorded" "ended=boot@1000" "$(cat "$T/conf/awake.status")"
conf "session=system" "until=inf" "boot_id=new-boot"
out=$(pass 1000)
eq "same boot keeps session" "session=system" "$(grep '^session=' "$T/conf/awake")"
rm "$T/proc/sys/kernel/random/boot_id"

# ── Review Focus 3: real (non-dry) children, with a fake inhibitor ──
# The fake records its pid per --what and becomes a sleep. Everything else a
# non-dry run could reach is stubbed, on PATH as well.
mkdir -p "$T/bin" "$T/xdg"
for c in systemd-inhibit systemctl noctalia; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/stub.log"\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done
cat > "$T/inhibit" <<EOF
#!/usr/bin/env bash
for a; do case "\$a" in --what=*) w=\${a#--what=} ;; esac; done
echo \$\$ > "$T/inh.\$w"
exec sleep 30
EOF
chmod +x "$T/inhibit"
real() {  # real <extra env...>: one non-dry pass, output to $T/real.out
  env -u ROG_DRY_RUN PATH="$T/bin:$PATH" XDG_CONFIG_HOME=$T/xdg AWAKE_SYSROOT=$T AWAKE_CONF_DIR=$T/conf \
    AWAKE_HYPRCTL=$T/hyprctl AWAKE_NOW=1000 AWAKE_INHIBIT=$T/inhibit \
    AWAKE_NOTIFY="echo notify" AWAKE_SUSPEND="echo suspend" "$@" "$AWAKECTL" watch --once >"$T/real.out" 2>&1
}
pid_of() {  # pid_of <what>: wait up to 2 s for the fake to record itself
  local i; for i in $(seq 20); do [ -s "$T/inh.$1" ] && break; sleep 0.1; done
  cat "$T/inh.$1" 2>/dev/null
}
gone() {  # gone <pid>: true once it has exited (up to 2 s)
  local i; for i in $(seq 20); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1
}
conf "lid_ac=awake"
real AWAKE_KEEP=1
p1=$(pid_of handle-lid-switch)
kill -0 "$p1" 2>/dev/null; eq "kept lid lock child alive" 0 $?
lacks "real run prints no dry-run lines" "dry-run:" "$(cat "$T/real.out")"
has "real run reports the lock" "held=lid" "$(cat "$T/conf/awake.status")"
kill "$p1" 2>/dev/null
rm -f "$T/inh.handle-lid-switch"
real
p2=$(pid_of handle-lid-switch)
[ -n "$p2" ] && [ "$p2" != "$p1" ]; eq "second run took its own lock" 0 $?
gone "$p2"; eq "cleanup killed the lock child" 0 $?
lacks "no job noise on stderr" "Terminated" "$(cat "$T/real.out")"
eq "cleanup reports nothing held" "held=" "$(grep '^held=' "$T/conf/awake.status")"
eq "no stubbed command ran" "" "$(cat "$T/stub.log" 2>/dev/null)"

# ── the loop itself (dry run, fake udevadm that never sends an event) ──
cat > "$T/bin/udevadm" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$T/udev.pid"
exec sleep 30
EOF
chmod +x "$T/bin/udevadm"
loop() {  # start a dry-run watcher in the background; its pid in $W
  rm -f "$T/udev.pid" "$T/conf/awake.status"
  PATH="$T/bin:$PATH" AWAKE_SYSROOT=$T AWAKE_CONF_DIR=$T/conf AWAKE_HYPRCTL=$T/hyprctl \
    AWAKE_NOTIFY="echo notify" AWAKE_SUSPEND="echo suspend" "$AWAKECTL" --dry-run watch >"$T/loop.out" 2>&1 &
  W=$!
}
wait_for() {  # wait_for <ms> <cmd...>: poll every 50 ms, true once cmd holds within ms
  local s=${EPOCHREALTIME/./} lim=$(( $1 * 1000 )); shift
  until "$@"; do
    [ $(( ${EPOCHREALTIME/./} - s )) -ge "$lim" ] && return 1
    sleep 0.05
  done
}
status_is() { grep -qx "$1" "$T/conf/awake.status" 2>/dev/null; }
conf "lid_ac=awake"
loop
wait_for 3000 status_is held=lid; eq "loop: first pass" 0 $?
conf "lid_ac=awake" "session=system" "until=inf"
kill -HUP "$W"
wait_for 1500 status_is held=sleep,lid; eq "loop: SIGHUP wakes it before the 2 s poll" 0 $?
kill -0 "$W" 2>/dev/null; eq "loop: SIGHUP is not fatal" 0 $?
up=$(cat "$T/udev.pid")
kill -TERM "$W"; wait "$W"; eq "loop: SIGTERM exits 143" 143 $?
eq "loop: exit dropped the locks" "held=" "$(grep '^held=' "$T/conf/awake.status")"
has "loop: exit logged the drops" "dry-run: inhibit lid off" "$(cat "$T/loop.out")"
gone "$up"; eq "loop: udevadm reaped" 0 $?
loop
wait_for 3000 test -s "$T/udev.pid"
kill "$(cat "$T/udev.pid")"
wait_for 4000 eval '! kill -0 $W 2>/dev/null'; eq "loop: a dead udev monitor ends it" 0 $?
kill -0 "$W" 2>/dev/null && kill -TERM "$W"   # still up only if the check above failed
wait "$W"; eq "loop: ...with exit 1" 1 $?
has "loop: says why" "udev monitor ended" "$(cat "$T/loop.out")"

# ── several passes of one watcher, through the library (dry run) ──
export AWAKE_SYSROOT=$T AWAKE_CONF_DIR=$T/conf AWAKE_HYPRCTL=$T/hyprctl \
  AWAKE_NOTIFY="echo notify" AWAKE_SUSPEND="echo suspend" ROG_DRY_RUN=1
AWAKE_LIB=1 . "$AWAKECTL"
exec 9>>"$T/dry.log"
step() {  # step <now>: one pass of the same watcher; its dry-run lines land in $out
  : > "$T/dry.log"; export AWAKE_NOW=$1
  watch_pass 2>/dev/null
  out=$(cat "$T/dry.log"); printf '%s\n' "$out" >> "$T/all.log"
}
fresh() {  # a new watcher's state
  for k in idle sleep lid; do unset "PID[$k]"; done
  SCREEN_DPMS=0 SCREEN_DPMS_EDP= SCREEN_DISABLED= EXT_SINCE= HOT_SINCE= SUSPEND_SINCE=
  LAST_PASS= PREV_AC= PREV_LID= ENDED= FIRST_PASS=1 RESUMED_AT=0
}
line_of() { grep -n -F -- "$1" <<<"$out" | head -n1 | cut -d: -f1; }

# new locks are taken before old ones go
fresh; conf "session=screen" "until=inf" "lid_ac=sleep"
step 1000
conf "lid_ac=awake"
step 1002
has "switch: lid taken" "inhibit lid on" "$out"
has "switch: idle dropped" "inhibit idle off" "$out"
[ "$(line_of 'inhibit lid on')" -lt "$(line_of 'inhibit idle off')" ] 2>/dev/null
eq "switch: take before drop" 0 $?

# lid close on charger: panel off and lock once, lid open: panel back on
fresh; conf "lid_screen=lock"
step 2000
lacks "lid open: no lock" "session lock" "$out"
mk proc/acpi/button/lid/LID0/state "state:      closed"
step 2002
has "lid closes: lock" "noctalia msg session lock" "$out"
has "lid closes: dpms off" 'action = "off", monitor = "eDP-1"' "$out"
has "status: panel off" "screen=dpms" "$(cat "$T/conf/awake.status")"
step 2004
lacks "lid stays closed: no second lock" "session lock" "$out"
has "lid stays closed: dpms re-asserted" 'action = "off"' "$out"
mk proc/acpi/button/lid/LID0/state "state:      open"
step 2006
has "lid opens: dpms on" 'hl.dsp.dpms({ action = "on", monitor = "eDP-1" })' "$out"
step 2008
lacks "lid open: screen left alone" "hl.dsp.dpms" "$out"

# with a monitor and Move windows: disable 2 s after it appears, re-enable on open
fresh; conf "lid_monitor=disable"
mk sys/class/drm/card0-DP-3/status connected
mk proc/acpi/button/lid/LID0/state "state:      closed"
step 3000
lacks "monitor just appeared: not yet" "disabled = true" "$out"
step 3002
has "monitor settled: eDP disabled" 'hl.monitor({ output = "eDP-1", disabled = true })' "$out"
has "status: disabled" "screen=disable" "$(cat "$T/conf/awake.status")"
step 3004
lacks "disabled once" "hl.monitor" "$out"
mk proc/acpi/button/lid/LID0/state "state:      open"
step 3006
has "lid opens: full rule back" 'hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1.25, disabled = false })' "$out"
# unplugging the monitor with the lid closed also brings the panel back
mk proc/acpi/button/lid/LID0/state "state:      closed"
step 3008
has "lid closes again: disabled at once" "disabled = true" "$out"
mk sys/class/drm/card0-DP-3/status disconnected
step 3012
has "monitor gone: eDP enabled" "disabled = false" "$out"
mk proc/acpi/button/lid/LID0/state "state:      open"
step 3014

# heat with the lid shut on battery: after 60 s the session ends, notify, then the lid lock goes
fresh; conf "session=system" "until=inf" "lid_bat=awake"
mk sys/class/power_supply/ACAD/online 0
mk proc/acpi/button/lid/LID0/state "state:      closed"
mk sys/class/thermal/thermal_zone0/temp 97000
for t in 4000 4015 4030 4045; do step $t; done
lacks "hot for 45 s: nothing yet" "notify" "$out"
has "hot for 45 s: lid still held" "held=sleep,lid" "$(cat "$T/conf/awake.status")"
step 4060
has "hot 60 s: notified" "Sleeping: CPU at 97 °C with the lid shut on battery" "$out"
has "hot 60 s: lid dropped" "inhibit lid off" "$out"
[ "$(line_of 'Sleeping: CPU')" -lt "$(line_of 'inhibit lid off')" ] 2>/dev/null
eq "hot: notify before the lid lock goes" 0 $?
eq "hot: session cleared" "session=none" "$(grep '^session=' "$T/conf/awake")"
lacks "hot: no suspend before 10 s" "echo suspend" "$out"
step 4070
has "hot: suspend backstop after 10 s" "dry-run: echo suspend" "$out"
step 4072
lacks "suspend sent once" "echo suspend" "$out"
# a wall-clock jump is a resume: no backstop for 30 s after it
step 4200
lacks "resume seen: no suspend" "echo suspend" "$out"
step 4212
lacks "12 s after resume: no suspend" "echo suspend" "$out"
mk sys/class/thermal/thermal_zone0/temp 50000

# the battery floor ends lid-closed stay-awake on battery without a session, and says so
fresh; conf "lid_bat=awake"
mk sys/class/power_supply/BAT1/capacity 25
step 5000
has "battery above floor: lid held" "inhibit lid on" "$out"
mk sys/class/power_supply/BAT1/capacity 15
step 5002
has "battery below floor: notified" "Sleeping: battery at 15% with the lid shut" "$out"
has "battery below floor: lid dropped" "inhibit lid off" "$out"
step 5004
lacks "floor notified once" "notify" "$out"
mk sys/class/power_supply/BAT1/capacity 80
mk sys/class/power_supply/ACAD/online 1
mk proc/acpi/button/lid/LID0/state "state:      open"

eq "hyprctl never reloaded" "" "$(grep -E 'reload|keyword' "$T/all.log" || true)"
finish

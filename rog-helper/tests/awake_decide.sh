#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
AWAKE_LIB=1 . "$AWAKECTL"

base() {
  C_session=none C_until= C_lid_ac=awake C_lid_bat=sleep C_lid_screen=off C_lid_monitor=dpms
  C_stop_battery=20 C_stop_unplug=0 C_stop_hot=1
  I_ac=1 I_prev_ac=1 I_lid=open I_bat=80 I_hot=0 I_now=1000 I_ext=0
}
run_case() {  # run_case "k=v k=v ..." -> "idle sleep lid screen lock suspend end"
  base; local kv; for kv in $1; do eval "$kv"; done
  decide
  printf '%s %s %s %s %s %s %s' "$W_idle" "$W_sleep" "$W_lid" "$W_screen" "$W_lock" "$W_suspend" "${W_end:--}"
}
t() { eq "$1" "$2" "$(run_case "$3")"; }

# no session, lid rules
t "idle machine on charger holds lid"             "0 0 1 on 0 0 -"      ""
t "on battery with lid rule sleep holds nothing"  "0 0 0 on 0 0 -"      "I_ac=0 I_prev_ac=0"
t "lid closed on charger: panel off"              "0 0 1 dpms 0 0 -"    "I_lid=closed"
t "lid closed on charger with lock"               "0 0 1 dpms 1 0 -"    "I_lid=closed C_lid_screen=lock"
t "lid closed on battery, rule sleep: suspend"    "0 0 0 on 0 1 -"      "I_ac=0 I_prev_ac=0 I_lid=closed"
t "charger rule sleep, lid closed: suspend"       "0 0 0 on 0 1 -"      "C_lid_ac=sleep I_lid=closed"
t "battery rule awake holds lid"                  "0 0 1 on 0 0 -"      "I_ac=0 I_prev_ac=0 C_lid_bat=awake"
t "battery rule session without session"          "0 0 0 on 0 0 -"      "I_ac=0 I_prev_ac=0 C_lid_bat=session"
# sessions
t "system session"                                "0 1 1 on 0 0 -"      "C_session=system C_until=inf"
t "screen session"                                "1 1 1 on 0 0 -"      "C_session=screen C_until=2000"
t "battery rule session with session"             "0 1 1 on 0 0 -"      "I_ac=0 I_prev_ac=0 C_lid_bat=session C_session=system C_until=inf"
# endings
t "timer expired"                                 "0 0 1 on 0 0 time"   "C_session=screen C_until=1000"
t "timer expired while watcher was down"          "0 0 1 on 0 0 time"   "C_session=system C_until=10 I_now=99999"
t "battery floor ends session on battery"         "0 0 0 on 0 0 battery" "I_ac=0 I_prev_ac=0 I_bat=19 C_session=system C_until=inf"
t "battery floor ignored on charger"              "0 1 1 on 0 0 -"      "I_bat=5 C_session=system C_until=inf"
t "battery floor off at 0"                        "0 1 0 on 0 0 -"      "I_ac=0 I_prev_ac=0 I_bat=3 C_stop_battery=0 C_session=system C_until=inf"
t "unknown battery never trips the floor"         "0 1 0 on 0 0 -"      "I_ac=0 I_prev_ac=0 I_bat= C_session=system C_until=inf"
t "unplug ends session when enabled"              "0 0 0 on 0 0 unplug" "I_ac=0 I_prev_ac=1 C_stop_unplug=1 C_session=screen C_until=inf"
t "unplug ignored when disabled"                  "0 1 0 on 0 0 -"      "I_ac=0 I_prev_ac=1 C_session=system C_until=inf"
t "hot, lid closed on battery: end + suspend"     "0 0 0 on 0 1 hot"    "I_ac=0 I_prev_ac=0 I_lid=closed I_hot=1 C_lid_bat=awake C_session=system C_until=inf"
t "hot with lid open is ignored"                  "0 1 1 on 0 0 -"      "I_ac=0 I_prev_ac=0 I_hot=1 C_lid_bat=awake C_session=system C_until=inf"
t "hot stop disabled"                             "0 0 1 dpms 0 0 -"    "I_ac=0 I_prev_ac=0 I_lid=closed I_hot=1 C_lid_bat=awake C_stop_hot=0"
t "lid stay-awake on battery suppressed by floor" "0 0 0 on 0 0 -"      "I_ac=0 I_prev_ac=0 I_bat=10 C_lid_bat=awake"
# clamshell
t "external monitor, lid closed, dpms"            "0 0 1 dpms 0 0 -"    "I_lid=closed I_ext=1"
t "external monitor, lid closed, disable"         "0 0 1 disable 0 0 -" "I_lid=closed I_ext=1 C_lid_monitor=disable"
t "external monitor on battery rule sleep: no suspend, panel off" "0 0 0 dpms 0 0 -" "I_ac=0 I_prev_ac=0 I_lid=closed I_ext=1"
t "disable never without external"                "0 0 1 dpms 0 0 -"    "I_lid=closed C_lid_monitor=disable"

base; C_session=system C_until=inf; decide; has "why names session" "Awake session" "$W_why"
base; I_lid=closed; decide; has "why names lid on charger" "lid closed on charger" "$W_why"
base; I_ac=0 I_prev_ac=0; decide; eq "why empty when nothing held" "" "$W_why"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sys/class/power_supply/ACAD" "$T/sys/class/power_supply/BAT1" "$T/proc/acpi/button/lid/LID0" "$T/conf"
echo Mains > "$T/sys/class/power_supply/ACAD/type"; echo 1 > "$T/sys/class/power_supply/ACAD/online"
echo 55 > "$T/sys/class/power_supply/BAT1/capacity"; echo "state:      open" > "$T/proc/acpi/button/lid/LID0/state"
printf 'session=system\nuntil=10\n' > "$T/conf/awake"
out=$(AWAKE_SYSROOT=$T AWAKE_CONF_DIR=$T/conf AWAKE_NOW=500 AWAKE_HYPRCTL=true "$AWAKECTL" status)
has "status: expired session reads none" "session=none" "$out"
has "status: ac" "ac=1" "$out"
has "status: battery" "battery=55" "$out"
has "status: lid" "lid=open" "$out"
has "status: default lid_ac" "lid_ac=awake" "$out"

finish

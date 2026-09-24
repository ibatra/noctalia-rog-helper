#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/conf"
ctl() { AWAKE_CONF_DIR=$T/conf AWAKE_NOW=1000 XDG_CONFIG_HOME=$T "$AWAKECTL" "$@"; }

out=$(ctl set lid_bat=bogus 2>&1); rc=$?
eq "bad value exit" 2 "$rc"; has "bad value note" "Bad value for lid_bat" "$out"
out=$(ctl set nope=1 2>&1); eq "unknown key exit" 2 "$?"

# real writes (no dry run), but with systemctl stubbed on PATH
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "systemctl $*" >> %s/sysctl.log\n[ "$2" = is-active ] && exit 3\nexit 0\n' "$T" > "$T/bin/systemctl"; chmod +x "$T/bin/systemctl"
P="$T/bin:$PATH"
PATH=$P ctl start screen 90
eq "start sets session" "session=screen" "$(grep '^session=' "$T/conf/awake")"
eq "start sets deadline" "until=6400" "$(grep '^until=' "$T/conf/awake")"
has "start writes unit" "ExecStart=" "$(cat "$T/systemd/user/rog-helper-awake.service")"
has "start enables unit" "systemctl --user enable -q rog-helper-awake.service" "$(cat "$T/sysctl.log")"
PATH=$P ctl stop
eq "stop clears session" "session=none" "$(grep '^session=' "$T/conf/awake")"
PATH=$P ctl toggle
eq "toggle starts last kind" "session=screen" "$(grep '^session=' "$T/conf/awake")"
eq "toggle uses last mins" "until=6400" "$(grep '^until=' "$T/conf/awake")"
PATH=$P ctl start system inf
eq "inf deadline" "until=inf" "$(grep '^until=' "$T/conf/awake")"
: > "$T/sysctl.log"
PATH=$P ctl set lid_ac=sleep lid_bat=sleep session=none
has "nothing needed: unit disabled" "disable -q --now rog-helper-awake.service" "$(cat "$T/sysctl.log")"
# unit rewritten when it differs
echo stale > "$T/systemd/user/rog-helper-awake.service"
PATH=$P ctl set lid_ac=awake
has "stale unit rewritten" "ExecStart=" "$(cat "$T/systemd/user/rog-helper-awake.service")"
# power key: Review Focus 5
PATH=$P ctl set power_key=sleep
out=$(AWAKE_LAST_RESUME=998 ctl --dry-run power-key 2>&1)
lacks "wake press ignored" "systemctl suspend" "$out"
out=$(AWAKE_LAST_RESUME=900 ctl --dry-run power-key 2>&1)
has "later press suspends" "dry-run: systemctl suspend" "$out"
PATH=$P ctl set power_key=lock
out=$(AWAKE_LAST_RESUME=0 ctl --dry-run power-key 2>&1)
has "lock action" "dry-run: noctalia msg session lock" "$out"
finish

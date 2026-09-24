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
# STUB_ACTIVE: is-active's exit (3 = inactive); STUB_SHOW: what `show` prints
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$T/sysctl.log"
[ "\$2" = is-active ] && exit \${STUB_ACTIVE:-3}
[ "\$1" = show ] && printf '%b\n' "\${STUB_SHOW:-}"
exit 0
EOF
chmod +x "$T/bin/systemctl"
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
# a running watcher is signalled alone: a HUP to the whole cgroup kills its
# inhibitor children and udevadm, dropping every lock
: > "$T/sysctl.log"
STUB_ACTIVE=0 PATH=$P ctl set lid_ac=awake lid_bat=session
has "active unit: HUP to the watcher only" "systemctl --user kill --kill-whom=main -s HUP rog-helper-awake.service" "$(cat "$T/sysctl.log")"
lacks "active unit: not started again" "start rog-helper-awake.service" "$(cat "$T/sysctl.log")"

# a session started before the watcher ran this boot is not ended as a stale one
mkdir -p "$T/root/proc/sys/kernel/random"; echo newboot > "$T/root/proc/sys/kernel/random/boot_id"
PATH=$P ctl set lid_ac=sleep lid_bat=sleep session=none boot_id=oldboot
AWAKE_SYSROOT=$T/root PATH=$P ctl start system 60
eq "start records this boot" "boot_id=newboot" "$(grep '^boot_id=' "$T/conf/awake")"
out=$(AWAKE_SYSROOT=$T/root AWAKE_HYPRCTL=true AWAKE_KEEP=1 AWAKE_NOTIFY="echo notify" ctl --dry-run watch --once 2>&1)
lacks "fresh session survives the boot check" "session ended: boot" "$out"
eq "fresh session still set" "session=system" "$(grep '^session=' "$T/conf/awake")"
# ...while one left over from the last boot still ends
PATH=$P ctl set boot_id=oldboot
out=$(AWAKE_SYSROOT=$T/root AWAKE_HYPRCTL=true AWAKE_KEEP=1 AWAKE_NOTIFY="echo notify" ctl --dry-run watch --once 2>&1)
has "stale session ends on boot" "session ended: boot" "$out"

# power key: Review Focus 5. The press that wakes the machine lands while
# systemd-suspend.service is still activating (systemd-sleep runs its
# post-resume hooks before it exits), or within 5 s of it exiting.
PATH=$P ctl set power_key=sleep
pk() { STUB_SHOW=$1 PATH=$P ctl --dry-run power-key 2>&1; }
out=$(pk 'ActiveState=activating\nExecMainExitTimestamp=@900')
lacks "wake press ignored while suspend is activating" "systemctl suspend" "$out"
out=$(pk 'ActiveState=deactivating\nExecMainExitTimestamp=@900')
lacks "wake press ignored while suspend is deactivating" "systemctl suspend" "$out"
out=$(pk 'ActiveState=inactive\nExecMainExitTimestamp=@998')
lacks "wake press ignored within 5 s of the exit" "systemctl suspend" "$out"
has "the lookup asks for unix timestamps" "show -p ActiveState,ExecMainExitTimestamp --timestamp=unix systemd-suspend.service" "$(cat "$T/sysctl.log")"
out=$(pk 'ActiveState=inactive\nExecMainExitTimestamp=@900')
has "later press suspends" "dry-run: systemctl suspend" "$out"
out=$(pk 'ActiveState=inactive\nExecMainExitTimestamp=')
has "never suspended this boot: press suspends" "dry-run: systemctl suspend" "$out"
PATH=$P ctl set power_key=lock
out=$(pk 'ActiveState=inactive\nExecMainExitTimestamp=')
has "lock action" "dry-run: noctalia msg session lock" "$out"
finish

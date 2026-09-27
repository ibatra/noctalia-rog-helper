# rog-lib.sh - helpers shared by rogctl and awakectl. Sourced, not run.
#
# Expects DRY (0/1) set by the caller, fd 9 open for dry-run notes, and SYS
# (a test sysroot prefix, empty on a real machine).

log() { printf '%s\n' "$*" >&2; }

# Run a mutating command, or just describe it in dry-run mode.
run() {
  if [ "$DRY" = 1 ]; then
    printf 'dry-run: %s\n' "$*" >&9
    return 0
  fi
  "$@"
}

# First line of a (one-line sysfs/proc) file, or $2 when it can't be read.
# A builtin read, no cat: the watchers read a dozen of these every pass.
rd() {
  local v=
  if { IFS= read -r v || [ -n "$v" ]; } 2>/dev/null <"$1"; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi
}

# 1 while a Mains power supply is online, else 0.
ac_online() {
  local f
  for f in "$SYS"/sys/class/power_supply/A*/online "$SYS"/sys/class/power_supply/*/online; do
    [ -f "$f" ] || continue
    [ "$(rd "${f%/online}/type")" = "Mains" ] || continue
    rd "$f" 0; return
  done
  echo 0
}

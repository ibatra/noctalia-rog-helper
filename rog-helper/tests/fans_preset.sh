#!/usr/bin/env bash
# The Fans view previews Quiet and Cool without asking rogctl (fans_view.luau
# presetSpec). Check the preview is the curve `rogctl fan` would write, for
# both presets and both stock curves the GU606AW reports.
set -u
. "$(dirname "$0")/lib.sh"
ROGCTL=$HERE/../bin/rogctl
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/rog-helper"
CPU="0,55,59,63,67,71,75,79;2,12,28,45,56,86,112,130"
GPU="0,49,53,57,61,65,68,71;2,12,28,43,56,81,102,117"
printf '%s\n' "fan_default_balanced_CPU=$CPU" "fan_default_balanced_GPU=$GPU" > "$T/rog-helper/state"

# what the panel previews: "temps;pwms" from Fans.presetSpec
preview() {  # preview <stock> <preset>
  lua - "$HERE/../fans_view.luau" "$1" "$2" <<'EOF'
local Fans = assert(loadfile(arg[1]))()
io.write(Fans.presetSpec(arg[2], arg[3]))
EOF
}
# what rogctl sends asusd, "0c:2,55c:12,..." turned back into "temps;pwms"
written() {  # written <preset> <CPU|GPU>
  XDG_CONFIG_HOME=$T "$ROGCTL" --dry-run fan balanced "$1" 2>&1 >/dev/null |
    sed -n "s/.*--fan ${2,,} --data \([^ ]*\).*/\1/p" |
    awk -F, '{ t = ""; p = ""; for (i = 1; i <= NF; i++) { split($i, a, "c:"); t = t (i > 1 ? "," : "") a[1]; p = p (i > 1 ? "," : "") a[2] } print t ";" p }'
}
for preset in quiet cool; do
  eq "$preset CPU preview matches rogctl" "$(written "$preset" CPU)" "$(preview "$CPU" "$preset")"
  eq "$preset GPU preview matches rogctl" "$(written "$preset" GPU)" "$(preview "$GPU" "$preset")"
done
eq "stock preview is the stock curve" "$CPU" "$(preview "$CPU" default)"
finish

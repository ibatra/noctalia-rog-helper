# Minimal assertions for the awakectl tests. Source, then call; `finish` exits
# non-zero if anything failed.
FAILS=0; PASSES=0
eq() {  # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASSES=$((PASSES + 1))
  else FAILS=$((FAILS + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}
has() {  # has <name> <needle> <haystack>
  case "$3" in *"$2"*) PASSES=$((PASSES + 1)) ;; *) FAILS=$((FAILS + 1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$2" "$3" ;; esac
}
lacks() {
  case "$3" in *"$2"*) FAILS=$((FAILS + 1)); printf 'FAIL %s\n  unexpected: %s\n' "$1" "$2" ;; *) PASSES=$((PASSES + 1)) ;; esac
}
finish() { printf '%d passed, %d failed\n' "$PASSES" "$FAILS"; [ "$FAILS" = 0 ]; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AWAKECTL=$HERE/../bin/awakectl

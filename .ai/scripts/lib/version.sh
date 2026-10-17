# Framework software version (semver). Independent of the spec document version.
# shellcheck shell=bash
JIG_VERSION="0.29.0"
export JIG_VERSION

# jig_version_lt <a> <b> — true when dotted-integer version <a> is older than
# <b>. Compares up to three numeric components (major.minor.patch); a
# missing component reads as 0, so "0.16" is equal to "0.16.0". Neither
# version.sh nor any caller here needs more than that shape.
#
# <a> that is empty or not shaped like a version — "unknown", the value
# _upgrade_message substitutes for a project with no recorded jig.version —
# reads as older than anything (ADR-0017's "unknown is not zero": a step
# this cautious about is shown rather than silently skipped).
jig_version_lt() {
  local a="$1" b="$2" i av bv
  case "$a" in
    [0-9]*) : ;;
    *) return 0 ;;
  esac
  for i in 1 2 3; do
    av=$(printf '%s\n' "$a" | cut -d. -f"$i")
    bv=$(printf '%s\n' "$b" | cut -d. -f"$i")
    [ -n "$av" ] || av=0
    [ -n "$bv" ] || bv=0
    if [ "$av" -lt "$bv" ] 2>/dev/null; then return 0; fi
    if [ "$av" -gt "$bv" ] 2>/dev/null; then return 1; fi
  done
  return 1
}

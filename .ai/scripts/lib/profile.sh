# Library for profile verify.sh scripts (adr-20260918-profiles-narrow-per-check-with-project-tools; domains/verify).
#
# A profile sources it relative to its own file:
#
#   . "$(dirname "$0")/../../scripts/lib/profile.sh"
#
# which resolves to scripts/lib/ in the framework source and to
# .ai/scripts/lib/ in a project, in copy and link mode alike: profiles and
# scripts sit at the same depth in both layouts. No capability is needed —
# the library is installed with every jig.
#
# The functions below are a distributed interface. A profile a user edited
# is kept by `upgrade` (keep-modified) and meets whatever library the
# upgrade installed, so a function here is never renamed or given a new
# meaning; a new behaviour is a new function.
#
# Contract recap (ARCHITECTURE.md, profile contract): a profile runs from the
# repository root, prints one line per check — `<profile>: <check>:
# pass|fail|skip|incomplete (<note>)` — and exits 0 pass, 1 fail, 2 when no
# check ran, 3 when a check did not finish
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).
# Scope (ADR-0013): JIG_VERIFY_SCOPE=changed and JIG_VERIFY_FILES name the
# changed paths. Map (ADR-0041): JIG_VERIFY_MAPPED carries `jig verify`'s
# decision per path, `?` where the project's map had no line.
# bash 3.2 compatible.
# shellcheck shell=bash

JP_PROFILE=""
JP_STATUS=0
JP_RAN=0
JP_SCOPED=0
JP_INCOMPLETE=0

# jp_plan <check> <state> <reason> — one line of the optional explain
# protocol. Keep it separate from jp_run/jp_skip: installed user profiles
# depend on their existing meanings and exit codes.
jp_plan() {
  local check="$1" state="$2" reason="$3"
  if [ "$JP_SCOPED" = 1 ] && [ ! -s "$JIG_VERIFY_FILES" ]; then
    state=skip
    reason="scope: changed, no changed files"
  fi
  case "$state" in
    full|filtered|skip|conditional) ;;
    *) return 1 ;;
  esac
  reason=${reason//$'\n'/, }
  printf 'PLAN %s: %s: %s (%s)\n' "$JP_PROFILE" "$check" "$state" "$reason"
}

# jp_plan_selection <check> <selection> <label> — a common shape for checks
# whose narrowed filters come from jp_decide. Callers handle missing filters
# and tool-specific uncertainty before using this helper.
jp_plan_selection() {
  local check="$1" selection="$2" label="$3" listed
  if ! jp_scoped; then
    jp_plan "$check" full "full scope"
  elif [ -z "$selection" ]; then
    jp_plan "$check" skip "no changed file maps to this check"
  elif [ "$selection" = ALL ]; then
    jp_plan "$check" full "changed paths require the full set"
  else
    listed=$(printf '%s\n' "$selection" | paste -sd, -)
    jp_plan "$check" filtered "$label: $listed"
  fi
}

# jp_begin <profile> — start a profile run: name it and read the scope.
jp_begin() {
  JP_PROFILE="$1"
  JP_STATUS=0
  JP_RAN=0
  JP_SCOPED=0
  JP_INCOMPLETE=0
  if [ "${JIG_VERIFY_SCOPE:-}" = changed ] && [ -n "${JIG_VERIFY_FILES:-}" ] \
     && [ -f "${JIG_VERIFY_FILES:-}" ]; then
    JP_SCOPED=1
  fi
  return 0
}

# jp_scoped — exit 0 when this run is narrowed to changed files.
jp_scoped() { [ "$JP_SCOPED" = 1 ]; }

# jp_has_line <line> <text> — exit 0 when <line> is a whole line of <text>,
# compared as a string: common.sh's jig_has_line for profiles, which source
# this file alone. A `case`, never `printf | grep -q`: bash writes a pipe line
# by line, and under pipefail the SIGPIPE a reader that quit early leaves
# printf with turns a match into a failure (conventions/shell.md).
jp_has_line() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# jp_changed [<ext>...] — changed paths that still exist, one per line; with
# extensions (`py`, `ts`), only those. Empty outside a scoped run.
jp_changed() {
  local f ext
  jp_scoped || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if [ $# -eq 0 ]; then
      printf '%s\n' "$f"
      continue
    fi
    for ext in "$@"; do
      case "$f" in
        *."$ext") printf '%s\n' "$f"; break ;;
      esac
    done
  done < "$JIG_VERIFY_FILES"
  return 0
}

# jp_changed_any <glob>... — exit 0 when a changed path, deleted ones
# included, matches one of the globs (`*` crosses `/`). For the files whose
# change sends a check to its full set: a manifest, a lock file, a config.
jp_changed_any() {
  local f g
  jp_scoped || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for g in "$@"; do
      # shellcheck disable=SC2254
      case "$f" in
        $g) return 0 ;;
      esac
    done
  done < "$JIG_VERIFY_FILES"
  return 1
}

# _jp_decide_raw <builtin-fn> — jp_decide's answers before deduplication.
# A function of its own because bash 3.2 misparses a `case` written inside
# `$( )`.
_jp_decide_raw() {
  # A decision's filters are space-separated whatever IFS the caller left.
  local fn="$1" f decision tok IFS=$' \t\n'
  if [ -n "${JIG_VERIFY_MAPPED:-}" ] && [ -f "${JIG_VERIFY_MAPPED:-}" ]; then
    while IFS="$(printf '\t')" read -r f decision; do
      [ -n "$f" ] || continue
      case "$decision" in
        '?') "$fn" "$f" ;;
        -) ;;
        *)
          # A decision comes from a hand-edited file: a token must never
          # expand against the project's files.
          set -f
          for tok in $decision; do printf '%s\n' "$tok"; done
          set +f
          ;;
      esac
    done < "$JIG_VERIFY_MAPPED"
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      "$fn" "$f"
    done < "$JIG_VERIFY_FILES"
  fi
  return 0
}

# jp_decide <builtin-fn> — the tests a narrowed run needs, one per line:
# filters, or the single token ALL. For each changed path the project map
# decides (`-` nothing, `ALL`, filters); where it has no line (`?`), or there
# is no map, <builtin-fn> <path> answers with the same vocabulary — nothing,
# ALL, or filters. Sorted and deduplicated; ALL wins over everything.
jp_decide() {
  local out
  jp_scoped || return 0
  out=$(_jp_decide_raw "$1")
  if jp_has_line ALL "$out"; then
    printf 'ALL\n'
  else
    printf '%s\n' "$out" | sed '/^$/d' | LC_ALL=C sort -u
  fi
  return 0
}

# jp_path_matches <path> <glob-list> — exit 0 when <path> matches one of the
# space-separated globs in <glob-list> (`*` crosses `/`). The list is split
# with pathname expansion off: `for g in $list` would otherwise expand
# `config/*` against the files on disk, so a deleted or nested file would
# stop matching the pattern meant to send its change to the full set.
jp_path_matches() {
  # The list is space-separated whatever IFS the calling profile left set.
  local f="$1" g IFS=$' \t\n'
  set -f
  for g in $2; do
    # shellcheck disable=SC2254
    case "$f" in
      $g) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}

# jp_is_doc <path> — exit 0 for documentation and jig's own state: prose
# (`*.md`, `*.mdx`, `*.rst`, `docs/`) and anything under `.ai/`. No stack's
# check reads them, so a built-in rule answers "nothing" for them rather than
# running a check for a change it cannot see.
jp_is_doc() {
  case "$1" in
    *.md|*.mdx|*.rst|docs/*|.ai/*) return 0 ;;
  esac
  return 1
}

# jp_first_missing <path>... — print the first argument that is not an
# existing file or directory; exit 1 when all exist. A filter that names
# nothing selects no test, and a narrowing that selects nothing is not a pass
# (ADR-0041): the caller runs the full set instead.
jp_first_missing() {
  local p
  for p in "$@"; do
    if [ ! -e "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# jp_files — every file of the project, one per line. Inside git the list
# comes from git (tracked and untracked, not ignored), so a virtualenv,
# node_modules or a nested worktree is never walked; outside git, a find
# that prunes the usual dependency directories.
jp_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -co --exclude-standard 2>/dev/null \
      | while IFS= read -r f; do
          [ -f "$f" ] && printf '%s\n' "$f"
        done
    return 0
  fi
  find . \( -name .git -o -name node_modules -o -name vendor -o -name .venv \
            -o -name venv -o -name target -o -name build -o -name .dart_tool \) -prune \
    -o -type f -print 2>/dev/null | sed 's#^\./##'
  return 0
}

# jp_version <cmd...> — the first non-empty line of a tool's version answer
# (Gradle's banner starts with a blank line), or `unknown`. Never fails the
# profile: a tool that cannot answer --version must not abort the check it
# only annotates (domains/verify RULES).
jp_version() {
  local v
  v=$("$@" 2>/dev/null | sed '/^[[:space:]]*$/d' | sed -n '1p') || v=""
  [ -n "$v" ] || v="unknown"
  printf '%s\n' "$v"
}

# jp_run <check> <note> <cmd...> — run a check and print its line. <note> is
# what the verdict must carry (the tool version, the scope); empty for none.
# A check killed by a signal is reported apart from one that failed. bash
# returns 128+N for a child that died on signal N, so `Killed: 9` arrives here
# as 137 and `Terminated: 15` as 143 — and until now both read as "the tests
# failed". They are not the same answer: a run that died produced no verdict,
# and reading one out of it cost hours three times in one night, none of them
# with a cause in the code
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass). Every
# stack profile runs its checks through here, so this one place answers for
# all of them.
jp_run() {
  local check="$1" note="$2" suffix="" rc=0
  shift 2
  [ -z "$note" ] || suffix=" ($note)"
  JP_RAN=1
  "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s: %s: pass%s\n' "$JP_PROFILE" "$check" "$suffix"
  elif [ "$rc" -ge 128 ]; then
    jp_incomplete "$check" "killed by signal $((rc - 128))${note:+, $note}"
  else
    printf '%s: %s: fail%s\n' "$JP_PROFILE" "$check" "$suffix"
    JP_STATUS=1
  fi
}

# jp_pass / jp_fail <check> <note> — record a verdict a profile computed
# itself (a runner exit code that needs translating, e.g. pytest's 5).
jp_pass() {
  JP_RAN=1
  printf '%s: %s: pass%s\n' "$JP_PROFILE" "$1" "${2:+ ($2)}"
}
jp_fail() {
  JP_RAN=1
  JP_STATUS=1
  printf '%s: %s: fail%s\n' "$JP_PROFILE" "$1" "${2:+ ($2)}"
}

# jp_incomplete <check> <reason> — a check that started and did not finish.
# Neither a pass nor a fail: it means run it again. For a profile that reads a
# runner's own answer rather than an exit code jp_run saw.
jp_incomplete() {
  JP_RAN=1
  JP_INCOMPLETE=1
  printf '%s: %s: incomplete%s\n' "$JP_PROFILE" "$1" "${2:+ ($2)}"
}

# jp_skip <check> <reason> — a check that did not run, and why.
jp_skip() {
  printf '%s: %s: skip (%s)\n' "$JP_PROFILE" "$1" "$2"
}

# jp_end — exit as the contract says: 3 when a check did not finish, 2 when no
# check ran, else 0 or 1.
#
# Incomplete comes first because a run something was killed in is not evidence:
# the failures beside it cannot be trusted either, and the honest instruction is
# to run it again.
jp_end() {
  if [ "$JP_INCOMPLETE" = 1 ]; then
    exit 3
  fi
  if [ "$JP_RAN" = 0 ]; then
    exit 2
  fi
  exit "$JP_STATUS"
}

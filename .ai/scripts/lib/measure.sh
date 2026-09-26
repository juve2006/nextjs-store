# `jig measure` — the Phase 6 report: knowledge quality, process weight and the
# size of the change each class produced.
#
# Every number is derived, never stored: it is computed from sources that
# already exist and already outlive the task — knowledge frontmatter, task
# `state`, git history, and the purge lines of `.ai/runtime/housekeeping.log`.
# There is no series on disk, no collection mechanism and no telemetry
# (ADR-0027), and nothing here calls an LLM (ADR-0001). The same reasoning
# ADR-0005 applies to remote merge state applies here: a fact that must be
# true *now* is cheaper to derive than to keep correct forever.
#
# What the report deliberately cannot say is printed by the report itself:
# stage timing, session count and the cost of agent work are recorded nowhere,
# and a proxy presented as a measurement would be a lie with a decimal point.
# shellcheck shell=bash

# Held by the EXIT trap, which fires after the function has returned — so it
# must not be `local` (convention-shell).
_MEASURE_TMP=""

cmd_measure() {
  [ $# -eq 0 ] || jig_die "measure: unknown argument: $1"
  jig_require_init

  # shellcheck source=lib/task.sh
  . "$JIG_LIB/task.sh"

  _MEASURE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jig-measure.XXXXXX") \
    || jig_die "measure: cannot create a temporary directory"
  trap '[ -n "${_MEASURE_TMP:-}" ] && rm -rf "$_MEASURE_TMP"' EXIT INT TERM

  _measure_knowledge
  _measure_collect_tasks
  _measure_process
  _measure_change

  printf 'blind spots: stage timing, session count, whether a human gate was passed, token and time cost are recorded nowhere\n'
}

# --- shared parsing ----------------------------------------------------------

# _measure_num <text> <literal-prefix> <n> — the n-th number on the line of
# <text> that starts with <prefix>, or 0 when there is no such line.
#
# Every prefix passed here is a literal with no regex metacharacter, and the
# digits are pulled out positionally rather than by a full pattern, so a
# summary line that gains a word keeps parsing. A missing line yields 0 only
# because the callers below ask for counts; nothing here turns an *absent*
# fact into a zero — that distinction is made by the caller.
_measure_num() {
  local n
  n=$(printf '%s\n' "$1" \
    | sed -n "s/^$2//p" \
    | tr -cs '0-9' ' ' \
    | awk -v i="$3" 'NR == 1 { print $i + 0 }')
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

# _measure_median <file> <column> — the lower median of a numeric column.
# Lower, not interpolated: the numbers counted here are commits and files, and
# half a file is not a thing a report should print.
_measure_median() {
  local f="$1" col="$2" n
  n=$(awk 'END { print NR + 0 }' "$f")
  if [ "$n" -eq 0 ]; then
    printf '0\n'
    return 0
  fi
  awk -v c="$col" '{ print $c }' "$f" \
    | sort -n \
    | awk -v n="$n" 'NR == int((n + 1) / 2) { print }'
}

# _measure_floor_days <seconds> — whole days, rounded towards minus infinity.
#
# Shell division truncates towards zero, so a tip older than its own fork point
# — a branch rebased onto a rewritten base, a stale `base_commit` (ADR-0026) —
# would come back as `0d` and read as "finished the same day". A measurement
# command may print a number that looks wrong; it may not print a plausible one
# that is.
_measure_floor_days() {
  local s="$1"
  if [ "$s" -lt 0 ]; then
    printf '%d\n' $(( -(( -s + 86399 ) / 86400) ))
  else
    printf '%d\n' $(( s / 86400 ))
  fi
}

# --- knowledge ---------------------------------------------------------------

# The three knowledge reports are consumed through their own summary lines
# rather than recomputed here. `knowledge` owns the answer to "how many
# documents are stale" and this command must not be able to disagree with it
# (ARCHITECTURE.md, scripts layout); a second implementation is exactly how the
# two would drift.
_measure_knowledge() {
  # shellcheck source=lib/knowledge.sh
  . "$JIG_LIB/knowledge.sh"
  # Its own prologue, not a copy of one: `cmd_knowledge` runs the same call, so
  # a setup step added there reaches this command too.
  km_init

  # Each of the three exits non-zero when it found something wrong, which is
  # the normal case for a report about defects: capture the output, keep going.
  local check stale paths
  if check=$(km_check); then :; fi
  if stale=$(km_stale); then :; fi
  if paths=$(km_paths); then :; fi

  local docs invalid warnings
  docs=$(_measure_num "$check" 'knowledge check: ' 1)
  invalid=$(_measure_num "$check" 'knowledge check: ' 2)
  warnings=$(_measure_num "$check" 'knowledge check: ' 3)

  local with_paths stale_n unreviewed orphaned planned
  with_paths=$(_measure_num "$stale" 'knowledge stale: ' 1)
  stale_n=$(_measure_num "$stale" 'knowledge stale: ' 2)
  unreviewed=$(_measure_num "$stale" 'knowledge stale: ' 3)
  orphaned=$(_measure_num "$stale" 'knowledge stale: ' 4)
  planned=$(_measure_num "$stale" 'knowledge stale: ' 5)

  local uncovered unmatched proposals
  uncovered=$(_measure_num "$paths" 'knowledge paths: ' 1)
  unmatched=$(_measure_num "$paths" 'knowledge paths: ' 2)
  proposals=$(km_proposed_count)

  printf 'knowledge:  %d documents, %d invalid, %d warnings\n' \
    "$docs" "$invalid" "$warnings"
  printf '            %d with paths, %d stale, %d unreviewed, %d orphaned, %d planned\n' \
    "$with_paths" "$stale_n" "$unreviewed" "$orphaned" "$planned"
  printf '            %d uncovered directories, %d unmatched globs, %d proposals awaiting decision\n' \
    "$uncovered" "$unmatched" "$proposals"
}

# --- tasks -------------------------------------------------------------------

# Build `$_MEASURE_TMP/tasks`: one `id<TAB>class<TAB>status<TAB>origin` row per
# task the repository still has any evidence of.
#
# Two origins, because a task workspace is designed to be destroyed (ADR-0006).
# `live` is a workspace that still exists. `purged` is a task whose workspace
# is gone and whose facts survive only in the housekeeping log — the one gate
# every workspace passes through on its way out, which is why the purge line is
# where those facts are written.
_measure_collect_tasks() {
  local rows="$_MEASURE_TMP/tasks" purged="$_MEASURE_TMP/tasks.purged"
  : > "$rows"
  : > "$purged"

  local state_file id class st
  for state_file in "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"/*/state; do
    [ -f "$state_file" ] || continue
    id=$(basename "$(dirname "$state_file")")
    # A directory that is not a well-formed task id is not ours to read
    # (RULES.md): task_state_get would refuse the path anyway.
    _task_valid_id "$id" || continue
    class=$(task_state_get "$id" class)
    st=$(task_state_get "$id" status)
    [ -n "$class" ] || class="unclassified"
    [ -n "$st" ] || st="unknown"
    printf '%s\t%s\t%s\tlive\n' "$id" "$class" "$st" >> "$rows"
  done

  local log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  if [ -f "$log" ]; then
    # `class=` was added to the purge line by this phase, so a line written
    # before it exists carries none. That is unclassified — an unknown, not a
    # zero, and never a T0.
    awk '
      /(^| )action=purge( |$)/ {
        id = ""; cls = "unclassified"; st = "unknown"
        for (i = 1; i <= NF; i++) {
          if      ($i ~ /^task=/)   { id  = substr($i, 6) }
          else if ($i ~ /^class=/)  { cls = substr($i, 7) }
          else if ($i ~ /^status=/) { st  = substr($i, 8) }
        }
        if (id != "") { printf "%s\t%s\t%s\tpurged\n", id, cls, st }
      }
    ' "$log" > "$purged"
    # A live workspace wins over a purge record of the same id: an id can be
    # reused after its workspace was erased, and the workspace on disk is the
    # newer fact.
    #
    # The empty case is handled separately on purpose. `NR == FNR` identifies
    # the first file only while that file has lines: with no live workspaces at
    # all it is true for every line of the *second* file as well, and every
    # purge record would be discarded as if it were live. Written to a third
    # file either way — appending to `$rows` while awk still reads it is how a
    # reader chases its own writes.
    if [ -s "$rows" ]; then
      awk -F'\t' 'NR == FNR { live[$1] = 1; next } !($1 in live)' \
        "$rows" "$purged" > "$_MEASURE_TMP/tasks.new"
    else
      cp "$purged" "$_MEASURE_TMP/tasks.new"
    fi
    cat "$_MEASURE_TMP/tasks.new" >> "$rows"
  fi

  LC_ALL=C sort -o "$rows" "$rows"
}

# --- process -----------------------------------------------------------------

# How much process the work asked for, and how it ended. The classes are the
# point: a distribution with nothing in T0 or T1 says either the rubric runs
# high or cheap work never becomes a task, and both are answers §3.3 wants.
_measure_process() {
  local rows="$_MEASURE_TMP/tasks" counts="$_MEASURE_TMP/counts"

  awk -F'\t' '
    { total++ }
    $4 == "live"   { live++ }
    $4 == "purged" { purged++ }
    { cls[$2]++; st[$3]++ }
    END {
      printf "%d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
        total + 0, live + 0, purged + 0,
        cls["T0"] + 0, cls["T1"] + 0, cls["T2"] + 0, cls["T3"] + 0, cls["T4"] + 0,
        cls["unclassified"] + 0,
        st["active"] + 0, st["ready"] + 0, st["consolidated"] + 0,
        st["abandoned"] + 0,
        total - (st["active"] + st["ready"] + st["consolidated"] + st["abandoned"])
    }
  ' "$rows" > "$counts"

  local total live purged t0 t1 t2 t3 t4 unclassified
  local active ready consolidated abandoned other
  read -r total live purged t0 t1 t2 t3 t4 unclassified \
    active ready consolidated abandoned other < "$counts"

  if [ "$total" -eq 0 ]; then
    printf 'process:    no task workspaces and no purge records\n'
    return 0
  fi

  printf 'process:    %d tasks (%d live, %d recorded at purge)\n' \
    "$total" "$live" "$purged"
  printf '            class: T0 %d, T1 %d, T2 %d, T3 %d, T4 %d, unclassified %d\n' \
    "$t0" "$t1" "$t2" "$t3" "$t4" "$unclassified"
  printf '            outcome: consolidated %d, abandoned %d, active %d, ready %d, other %d\n' \
    "$consolidated" "$abandoned" "$active" "$ready" "$other"
}

# --- change ------------------------------------------------------------------

# The size of the change each class actually produced — the honest half of what
# the roadmap called "cost measurement". It is process weight against change
# size, not cost: tokens, turns and wall-clock effort are not recorded and
# cannot be, so nothing here pretends to price the work.
#
# Measurable only where ADR-0026 applies: a task needs the fork point it
# recorded (`base_commit`) and a branch that still exists. Tasks that predate
# ADR-0026, were filed but never started, or whose branch was deleted after merging
# are counted as unmeasurable and named as such rather than dropped silently.
_measure_change() {
  local rows="$_MEASURE_TMP/change" tasks="$_MEASURE_TMP/tasks"
  : > "$rows"

  local total measured=0
  total=$(awk 'END { print NR + 0 }' "$tasks")

  local state_file id class base branch files lines commits fork tip days
  for state_file in "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"/*/state; do
    [ -f "$state_file" ] || continue
    id=$(basename "$(dirname "$state_file")")
    _task_valid_id "$id" || continue

    base=$(task_state_get "$id" base_commit)
    branch=$(task_state_get "$id" branch)
    if [ -z "$base" ] || [ -z "$branch" ]; then
      continue
    fi
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "$base^{commit}" >/dev/null || continue
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || continue

    class=$(task_state_get "$id" class)
    [ -n "$class" ] || class="unclassified"

    # `--no-renames` is not a detail: rename detection is on by default but a
    # developer may switch it off globally, and with it a renamed file counts as
    # one file and one line instead of two files and all their lines. A number
    # that changes with whose machine printed it is not a measurement
    # (convention-shell; the same reason jig_git_change_rows pins it).
    commits=$(git -C "$JIG_PROJECT" rev-list --count "$base..refs/heads/$branch")
    files=$(git -C "$JIG_PROJECT" diff --no-renames --name-only "$base" "refs/heads/$branch" \
      | awk 'END { print NR + 0 }')
    # A binary file's numstat columns are `-`; counting them as zero lines is
    # the only honest option, since the diff has no lines to count.
    lines=$(git -C "$JIG_PROJECT" diff --no-renames --numstat "$base" "refs/heads/$branch" \
      | awk '{ a += ($1 == "-" ? 0 : $1) + ($2 == "-" ? 0 : $2) } END { print a + 0 }')
    fork=$(git -C "$JIG_PROJECT" log -1 --format=%ct "$base")
    tip=$(git -C "$JIG_PROJECT" log -1 --format=%ct "refs/heads/$branch")
    days=$(_measure_floor_days $(( tip - fork )))

    printf '%s %s %s %s %s\n' "$class" "$commits" "$files" "$lines" "$days" >> "$rows"
    measured=$((measured + 1))
  done

  printf 'change:     measurable for %d of %d tasks (needs base_commit and a live branch)\n' \
    "$measured" "$total"
  [ "$measured" -gt 0 ] || return 0

  local class sub n
  for class in T0 T1 T2 T3 T4 unclassified; do
    sub="$_MEASURE_TMP/change.$class"
    awk -v c="$class" '$1 == c' "$rows" > "$sub"
    n=$(awk 'END { print NR + 0 }' "$sub")
    [ "$n" -gt 0 ] || continue
    printf '            %s: %d task(s), median %s commits, %s files, %s lines, %sd fork to tip\n' \
      "$class" "$n" \
      "$(_measure_median "$sub" 2)" \
      "$(_measure_median "$sub" 3)" \
      "$(_measure_median "$sub" 4)" \
      "$(_measure_median "$sub" 5)"
  done
}

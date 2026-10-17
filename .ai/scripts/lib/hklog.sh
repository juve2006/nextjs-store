# The housekeeping log, read: which tasks the last `jig housekeeping` run
# flagged, and which of those flags still stand. A shared parser
# (ARCHITECTURE.md, Scripts layout): `status` reads it for its report and the
# status page, `task list --json` for the data it prints, and the answer "does
# this flag still stand" is decided here once so the three cannot disagree.
#
# The log is the housekeeping domain's (domains/housekeeping); this file only
# reads it. The rechecks ask a task's own state through `task_state_get`, so a
# command sources lib/task.sh before calling them — both readers already do.
# Read-only, local: nothing here asks the forge or the network.
# shellcheck shell=bash

# hklog_ids <regex> — the tasks whose line in the last housekeeping run
# matches <regex>, distinct and in log order; nothing when housekeeping has
# never logged. The one reader of the log's task lines here; what the log said
# is where a flag starts, not where it ends -- hklog_flagged_ids asks this
# disk whether the flag still stands.
hklog_ids() {
  local hk_log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  [ -f "$hk_log" ] || return 0
  hklog_ids_in "$hk_log" "$1"
}

hklog_ids_in() {
  JIG_HK_RE="$2" awk '
    # split("", seen) clears the array portably; `delete seen` is an
    # extension not every awk on a supported machine has.
    /^--- run / { split("", seen); n = 0; next }
    $0 ~ ENVIRON["JIG_HK_RE"] {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^task=/) {
          id = substr($i, 6)
          if (!(id in seen)) { seen[id] = 1; ids[++n] = id }
        }
      }
    }
    END { for (i = 1; i <= n; i++) print ids[i] }
  ' "$1"
}

# hklog_last_run — "<UTC time>\t<forge>" of the last housekeeping run, from its
# `--- run` marker; <forge> is github|gitlab|none|failed, `-` when the marker
# predates the field. Nothing when housekeeping has never logged a run.
hklog_last_run() {
  local hk_log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  [ -f "$hk_log" ] || return 0
  awk '
    /^--- run / {
      at = $3; forge = "-"
      for (i = 4; i <= NF; i++) if ($i ~ /^forge=/) forge = substr($i, 7)
    }
    END { if (at != "") printf "%s\t%s\n", at, forge }
  ' "$hk_log"
}

# hklog_flagged_ids <flag> — the tasks <flag> still stands for: the ones the
# last housekeeping run flagged with it, minus the ones a fact read from this
# disk already contradicts. The one place that answer is decided; the status
# page's cards, the counts in both reports and `task list --json` call it, so
# they cannot disagree.
#
# The cut is the cost of asking again, not the kind of card. What a task's own
# state file says, and whether a worktree is still on disk, are read here for
# nothing, and the page is redrawn after every command -- so a card those
# facts contradict is not built at all. What the forge saw (merged, closed,
# open, work that landed on another branch) costs a network request, which
# this page never makes on the write path
# (adr-20260924-the-status-page-keeps-the-readers-place): those stay borrowed
# and keep saying "as of" the run that saw them.
hklog_flagged_ids() {
  local flag="$1" re
  case "$flag" in
    # The one flag whose name is not a literal regex.
    'abandoned?') re='flags=[^ ]*abandoned[?]' ;;
    *) re="flags=[^ ]*$flag" ;;
  esac
  _hklog_recheck "$flag" "$(hklog_ids "$re")"
}

# _hklog_recheck <flag> <ids> — <ids> without those the live answer
# contradicts.
#
# A recheck may only contradict, never invent. A task with no state file, and
# a kept worktree the log recorded no path for, keep their card: absence of an
# answer is not an answer, and a page that hid cards because it failed to look
# would be worse than one a run behind.
_hklog_recheck() {
  local flag="$1" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # The log is a file, and a line edited by hand can carry an id no command
    # would accept. Asking a peer about one dies in `task_dir` -- inside a
    # report, which may not fail on a peer's data, and by way of `jig_die`,
    # which redraws the very page being drawn. So it is not asked: an id
    # there is no way to check keeps its card, like every other answer the
    # page does not have.
    jig_valid_id "$id" || { printf '%s\n' "$id"; continue; }
    case "$flag" in
      needs-consolidation)
        # "Merged" is borrowed and stays so; "nobody has closed it yet" is
        # free to ask again, and closing the task is exactly what the card
        # asks for (ADR-0030).
        case "$(task_state_get "$id" status)" in
          consolidated | abandoned) continue ;;
        esac
        ;;
      'abandoned?')
        # housekeeping_decide drops this flag for a task already abandoned
        # (abandoned:closed). The page says the same thing a run earlier,
        # instead of asking a question that has been answered.
        [ "$(task_state_get "$id" status)" != abandoned ] || continue
        ;;
      worktree-kept)
        _hklog_worktree_kept "$id" || continue
        ;;
      # wrong-base and anything new: only the forge and the history know, so
      # the flag stands until the next run.
    esac
    printf '%s\n' "$id"
  done <<EOF
$2
EOF
}

# _hklog_worktree_kept <id> — false when the worktree housekeeping kept for
# <id> is gone from disk.
#
# The path comes from housekeeping's own `worktree=<path> action=keep` line,
# not from the task's branch. The flag has two shapes -- a worktree of its own
# and this checkout with the branch in it (_hk_checkout_keep) -- and a branch
# lookup sees neither the second nor a worktree the page is being drawn
# inside, since _task_worktrees leaves out the current checkout.
_hklog_worktree_kept() {
  local path
  path=$(hklog_worktree "$1")
  # Nothing recorded (an older log, or the checkout shape before it was
  # logged): no contradiction, so the card stands.
  [ -n "$path" ] || return 0
  [ -d "$path" ]
}

# hklog_worktree <id> — the path of the worktree the last housekeeping run
# kept for <id>, from its `action=keep` line; nothing when there is none.
#
# The task id is matched on the whole `task=` field, never as a substring:
# `task=wk` must not answer for `task=wk2`. The path is cut between
# ` worktree=` and the ` action=keep` that follows it rather than read as a
# field, because the log writes it unquoted and a worktree path may hold
# spaces; read field-wise it would come back truncated, and a truncated path
# is not a directory, which would drop exactly the card this function is
# meant to keep.
hklog_worktree() {
  local hk_log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  [ -f "$hk_log" ] || return 0
  JIG_HK_ID="$1" awk '
    /^--- run / { p = ""; next }
    {
      id = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^task=/) id = substr($i, 6)
      if (id != ENVIRON["JIG_HK_ID"]) next
      a = index($0, " worktree=")
      b = index($0, " action=keep")
      if (a > 0 && b > a) p = substr($0, a + 10, b - a - 10)
    }
    END { if (p != "") print p }
  ' "$hk_log"
}


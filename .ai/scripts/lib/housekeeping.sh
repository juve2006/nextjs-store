# cmd_housekeeping — reconcile task workspaces with remote merge state and
# retire what is finished (domains/housekeeping; ADR-0005, ADR-0006).
# Sourced by scripts/jig; defines cmd_housekeeping.
#
# Deterministic and unattended: no LLM (ADR-0001), no prompt, no interactive
# input. It runs from a terminal, from `scripts/jig-session-hook` and from an
# external scheduler with identical semantics, so every decision it makes has
# to be reconstructable afterwards from the log alone.
#
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# Derived remote state is never written into a task `state` file (ADR-0005);
# it lives in these run-scoped globals and in the log.
_HK_VIA=""          # tier that decided the last remote state: forge|ancestry|none
_HK_FORGE_KIND=""   # github|gitlab|none — resolved once per run
_HK_FORGE_PRS=""    # "<head><TAB><base><TAB><state>" lines, fetched once per run (C1)
_HK_STALE_REMOTE=0  # 1 when the fetch or the forge tier could not answer
_HK_FORGE_TOKEN=""  # github|gitlab|none|failed — the run marker's forge= field
_HK_VERBOSE=0       # 1 with --verbose: also print one decision line per task
_HK_ROWS=""         # "<group>\t<task>\t<note>" per task, printed as the report
_HK_WT_LINE=""      # what _hk_worktree_retire did, as a --verbose line
_HK_WT_NOTE=""      # ... and as a note in the grouped report
_HK_BASE_LOG=""     # "<base>\t<ref>\t<epoch>\t<sha>" reflog of every task base's refs, newest first, read once per run
_HK_WRONG_NOTE=""   # why the last task was flagged wrong-base, as a note in the grouped report
_HK_DEFAULT_BASE="" # git.base_branch, read once per run

cmd_housekeeping() {
  jig_require_init
  # shellcheck source=lib/task.sh
  . "$JIG_LIB/task.sh"

  local dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --verbose) _HK_VERBOSE=1; shift ;;
      *) jig_die "usage: jig housekeeping [--dry-run] [--verbose]" ;;
    esac
  done

  # The report is printed once every task is decided, grouped by outcome:
  # forty identical lines in id order said nothing a person could act on.
  _HK_ROWS=$(mktemp "${TMPDIR:-/tmp}/jig-housekeeping.XXXXXX")
  trap 'rm -f "$_HK_ROWS"' EXIT

  local runtime="$JIG_PROJECT/$JIG_AI_DIR/runtime"
  # Every walk of this path below is `find "$tasks_dir" ...` with no trailing
  # slash, and that is load-bearing. In a worktree the path is a link to the
  # owner's directory (_task_link_workspace), and find descends a symlink
  # named as its starting point only when the slash is written. Without it
  # housekeeping in a borrowing checkout finds no task at all, which is the
  # point: a workspace is purged and its worktree retired by the checkout it
  # was filed in, never by one that borrowed it (ADR-0008).
  local tasks_dir="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"

  local trash_ttl abandoned_ttl stale_after
  trash_ttl=$(cfg housekeeping.trash_ttl 7d)
  abandoned_ttl=$(cfg housekeeping.abandoned_ttl 14d)
  stale_after=$(cfg housekeeping.stale_after 60d)
  # Validate all three before touching anything: a typo in config.yaml must
  # fail the run, not silently become "0 days" and expire every trash entry.
  local trash_ttl_days abandoned_ttl_days stale_after_days
  trash_ttl_days=$(( $(jig_duration_seconds "$trash_ttl") / 86400 ))
  abandoned_ttl_days=$(( $(jig_duration_seconds "$abandoned_ttl") / 86400 ))
  stale_after_days=$(( $(jig_duration_seconds "$stale_after") / 86400 ))

  _HK_DEFAULT_BASE=$(cfg git.base_branch main)
  _hk_fetch "$dry"
  _hk_forge_init
  _hk_base_reflog_init "$tasks_dir"

  # A run boundary in the log. Without it the log is an undifferentiated
  # append-only history, and any reader asking "what does the latest run say"
  # has to guess with a line count — which is how `jig status` came to report
  # one unconsolidated task as three. Its forge= field says whether the run's
  # pull request states came from a forge (github|gitlab), from nowhere
  # (none) or were missing because the forge did not answer (failed): the
  # status page shows `remote=open` only as fresh as that.
  if [ "$dry" != 1 ]; then
    _hk_log "--- run $(date -u +%Y-%m-%dT%H:%M:%SZ) forge=$_HK_FORGE_TOKEN"
  fi

  local needs_consolidation=0 wrong_base=0 found=0
  local state_file tid st paused age branch base_commit task_base remote remote_pair via landed released decision action flags dest facts wt retire

  # Worktrees tasks were started in, from git's own list, read once per run.
  # A task's worktree goes when the task is closed and its branch landed on its
  # own base, or when its workspace goes (ADR-0029 as amended 2026-09-22).
  local worktrees here
  worktrees=$(_task_worktrees)
  # The branch this checkout has out, which `_task_worktrees` leaves out of its
  # list: a task worked on here has no worktree to keep its workspace for it.
  here=$(_task_current_branch)

  if [ -d "$tasks_dir" ]; then
    while IFS= read -r state_file; do
      [ -z "$state_file" ] && continue
      tid=$(basename "$(dirname "$state_file")")
      # A directory that is not a well-formed task id is not ours to touch:
      # report it and never build a path from it (RULES.md, convention-shell).
      if ! _task_valid_id "$tid"; then
        [ "$_HK_VERBOSE" != 1 ] || printf 'skip %s (invalid task id)\n' "$tid"
        printf 'skipped\t%s\t\n' "$tid" >> "$_HK_ROWS"
        continue
      fi
      found=1

      st=$(task_state_get "$tid" status)
      paused=$(task_state_get "$tid" paused)
      branch=$(task_state_get "$tid" branch)
      age=$(_hk_task_age_days "$tid")

      base_commit=$(task_state_get "$tid" base_commit)
      task_base=$(jig_task_base "$tid")
      remote_pair=$(_hk_remote_state "$branch" "$base_commit" "$task_base")
      read -r remote via landed <<EOF
$remote_pair
EOF
      _HK_VIA=$via

      # A task of an epic that landed on its epic has not reached the default
      # branch yet; its records are kept for the epic's final review
      # (ADR-0040). Asked only where it could matter: a merged task whose base
      # is not the project's.
      released=true
      if [ "$remote" = merged ] && [ "$task_base" != "$_HK_DEFAULT_BASE" ]; then
        released=$(_hk_released "$branch" "$base_commit" "$task_base")
      fi

      decision=$(housekeeping_decide \
        "$st" "$remote" "$paused" "$age" "$abandoned_ttl_days" "$stale_after_days" "$released")
      action=${decision%% *}
      flags=${decision#* }
      [ "$flags" = "$decision" ] && flags=""

      # Work that landed on another branch than the task's base. The remote
      # state stays `unknown`, so the policy keeps the workspace; the flag is
      # what tells a person why (ADR-0039).
      _HK_WRONG_NOTE=""
      if [ -n "$landed" ]; then
        flags="${flags:+$flags,}wrong-base"
        wrong_base=1
        if [ "$via" = "forge" ]; then
          _HK_WRONG_NOTE="pull request merged into $landed, not $task_base"
        else
          _HK_WRONG_NOTE="its branch is merged into $landed, not $task_base"
        fi
      fi

      case "$flags" in
        *needs-consolidation*) needs_consolidation=1 ;;
      esac

      # A task's worktree goes when its workspace is purged, and also as soon
      # as the task is closed and its branch landed on its own base — an epic
      # included — whether or not the work has been released yet: the records
      # a phase keeps for the epic's review live in the workspace, not in the
      # worktree (ADR-0029 as amended 2026-09-22, ADR-0040).
      # A worktree that has to stay keeps its workspace too when it is purged.
      # Purging the workspace would leave the worktree's link dangling beside
      # whatever made it stay — and the uncertain direction is always preserve.
      _HK_WT_LINE=""
      _HK_WT_NOTE=""
      retire=0
      [ "$action" = "purge" ] && retire=1
      [ "$st" = "consolidated" ] && [ "$remote" = "merged" ] && retire=1
      if [ "$retire" = 1 ] && [ -n "$branch" ]; then
        wt=$(_task_worktree_for "$branch" "$worktrees")
        if [ -n "$wt" ] && ! _hk_worktree_retire "$dry" "$tid" "$wt"; then
          if [ "$action" = "purge" ]; then
            action="preserve"
            flags="worktree-kept"
          else
            flags="${flags:+$flags,}worktree-kept"
          fi
        elif [ -z "$wt" ] && [ "$action" = "purge" ] && [ "$branch" = "$here" ] \
             && ! _hk_checkout_keep "$dry" "$tid"; then
          action="preserve"
          flags="worktree-kept"
        fi
        if [ "$_HK_VERBOSE" = 1 ] && [ -n "$_HK_WT_LINE" ]; then
          printf '%s\n' "$_HK_WT_LINE"
        fi
      fi

      dest=""
      facts=""
      if [ "$action" = "purge" ]; then
        # Read the facts a measurement needs *before* the workspace moves:
        # after `_hk_purge` the state file is in trash and this task's class
        # and age exist nowhere else (jig measure, ADR-0006).
        facts=$(_hk_task_facts "$tid")
        if [ "$dry" = 1 ]; then
          dest=$(_hk_trash_dest "$tid")
        else
          dest=$(_hk_purge "$tid")
        fi
      fi

      _hk_report "$dry" "$tid" "$st" "$remote" "$action" "$flags" "$dest" "$facts"
      _hk_record "$tid" "$st" "$remote" "$action" "$flags" "$age" \
        "$abandoned_ttl_days" "$branch" "$base_commit" "$task_base"
    done < <(find "$tasks_dir" -mindepth 2 -maxdepth 2 -name state -type f 2>/dev/null | LC_ALL=C sort)
  fi

  # The report is for a person; every decision it describes is already made
  # and logged. A failure to print it must not stop trash expiry, the stamp or
  # exit code 3 from happening.
  _hk_print_report "$dry" "$trash_ttl_days" \
    || jig_warn "housekeeping: could not print the report; the decisions are in .ai/runtime/housekeeping.log"
  [ "$found" = 1 ] || printf 'no task workspaces\n'

  _hk_trash_expire "$dry" "$trash_ttl_days"

  [ "$_HK_STALE_REMOTE" = 1 ] && printf 'stale-remote: remote state could not be refreshed\n'

  if [ "$dry" = 1 ]; then
    printf 'dry run: nothing was changed\n'
    return 0
  fi

  mkdir -p "$runtime"
  : > "$runtime/last-housekeeping"

  # The status page shows this run's flags and pull requests, and a run is
  # also when its cached counts are refreshed: a full redraw, when there is a
  # page at all. Never changes this command's output or exit code.
  jig_status_page_touch --full

  # Exit 3, not 1: a hook or a cron job must be able to tell "someone has to
  # consolidate this" from "the command crashed" (jig_die uses 1), and 2 is
  # already `task current`'s ambiguity code (domains/housekeeping).
  if [ "$needs_consolidation" = 1 ]; then
    printf 'action needed: consolidate the tasks flagged needs-consolidation\n'
  fi
  if [ "$wrong_base" = 1 ]; then
    printf 'action needed: check the tasks flagged wrong-base; their work landed outside their base\n'
  fi
  if [ "$needs_consolidation" = 1 ] || [ "$wrong_base" = 1 ]; then
    return 3
  fi
  return 0
}

# --- policy ------------------------------------------------------------------

# housekeeping_decide <status> <remote> <paused> <age_days> <abandoned_ttl_days>
#                     <stale_after_days> [released]
# Print "<action> [flags]" where action is purge|preserve and flags is a
# comma-separated subset of needs-consolidation, abandoned?, base-unreleased,
# STALE_CANDIDATE. `released` (default true) is false for a task merged into a
# base that has not reached the default branch yet — a phase of an open epic:
# closed and merged, it is kept rather than purged (ADR-0040).
#
# A pure function of six strings: no filesystem, no git, no config. That is
# what makes the domains/housekeeping policy table exhaustively testable, and it is the reason
# the destructive decision is separated from the destructive act.
housekeeping_decide() {
  local status="$1" remote="$2" paused="$3" age="$4" abandoned_ttl="$5" stale_after="$6"
  local released="${7:-true}"
  local action="preserve" flags=""

  case "$status:$remote" in
    consolidated:merged)
      if [ "$released" = true ]; then
        action="purge"
      else
        flags="base-unreleased"
      fi
      ;;
    active:merged|ready:merged)
      flags="needs-consolidation"
      ;;
    # Already abandoned: "abandoned?" would ask a question that has been
    # answered.
    abandoned:closed) ;;
    *:closed)
      flags="abandoned?"
      ;;
  esac

  # A merged task that was paused before consolidation still needs
  # consolidating: pause is orthogonal to status (ADR-0012) and never
  # suppresses a flag. An abandoned task has nothing to consolidate, whatever
  # its branch did — five abandoned, paused tasks on this repository were
  # flagged on every run, and made exit code 3 mean nothing.
  if [ "$paused" = "true" ] && [ "$remote" = "merged" ]; then
    case "$status" in
      consolidated | abandoned) ;;
      *) flags="needs-consolidation" ;;
    esac
  fi

  # `abandoned` is the one status whose purge is driven by a TTL rather than
  # by remote state, because a closed PR gives the workspace no other end.
  if [ "$status" = "abandoned" ] && [ "$age" -gt "$abandoned_ttl" ]; then
    action="purge"
    flags=""
  fi

  # Reported, never acted on: age is a hint, semantic lifecycle has priority
  # over TTL (domains/housekeeping).
  if [ "$age" -gt "$stale_after" ] && [ "$action" != "purge" ]; then
    if [ -n "$flags" ]; then
      flags="$flags,STALE_CANDIDATE"
    else
      flags="STALE_CANDIDATE"
    fi
  fi

  if [ -n "$flags" ]; then
    printf '%s %s\n' "$action" "$flags"
  else
    printf '%s\n' "$action"
  fi
}

# --- remote state ------------------------------------------------------------

# _hk_remote_state <branch> <base_commit> <base> — print "<state> <via>
# [<landed-on>]" where state is merged|open|closed|unknown, via is the tier that
# decided it (domains/housekeeping), and <landed-on> — present only with
# `unknown` — names the branch the work was merged into instead of <base>
# (the wrong-base flag, ADR-0039). There is no fifth state: work in the wrong
# place is as unknown to the policy as work nowhere.
#
# Both values are printed rather than one of them assigned to a global,
# because every caller reads this through `$(...)` and a subshell would
# discard the assignment — the log would then report a tier that never ran.
_hk_remote_state() {
  local branch="$1" base_commit="${2:-}" base="${3:-}" state default

  if [ -z "$branch" ] || [ "$branch" = "detached" ]; then
    # `detached` is task.sh:100's fallback when HEAD is not on a branch, not a
    # ref name: there is nothing to resolve and nothing to infer from.
    printf 'unknown none\n'
    return 0
  fi

  [ -n "$base" ] || base=$(cfg git.base_branch main)

  state=$(_hk_forge_state "$branch" "$base")
  case "$state" in
    '') ;;
    wrong-base\ *)
      printf 'unknown forge %s\n' "${state#wrong-base }"
      return 0
      ;;
    *)
      printf '%s forge\n' "$state"
      return 0
      ;;
  esac

  state=$(_hk_ancestry_state "$branch" "$base_commit" "$base")
  if [ "$state" = "merged" ]; then
    printf 'merged ancestry\n'
    return 0
  fi

  # Without a forge the one wrong place git can show is the project's base: a
  # task of another base whose branch is merged there. Asked only while the
  # task's own base still resolves — with it gone, "not on the base" is
  # nothing more than "the base is not here". And only with a fork point: without
  # one, a branch that never moved reads as merged into anything it came from.
  default=$(cfg git.base_branch main)
  if [ -n "$base_commit" ] && [ "$base" != "$default" ] && [ -n "$(jig_base_ref "$base")" ] \
     && [ "$(_hk_ancestry_state "$branch" "$base_commit" "$default")" = "merged" ]; then
    printf 'unknown ancestry %s\n' "$default"
    return 0
  fi

  printf 'unknown none\n'
}

# _hk_released <branch> <base_commit> <base> — true|false: whether the work of a
# task merged into <base> has also reached the default branch. Forge first: a
# merged pull request from <base> into the default branch. Then ancestry of the
# task's own branch against the default branch, which sees a merge commit and
# a rebase of the epic but not a squash — a squashed epic reads as not
# released, and its phases' workspaces stay (ADR-0040; when uncertain,
# preserve).
_hk_released() {
  local branch="$1" base_commit="$2" base="$3" default="$_HK_DEFAULT_BASE"
  [ -n "$default" ] || default=$(cfg git.base_branch main)
  if [ "$base" = "$default" ]; then
    printf 'true\n'
    return 0
  fi
  if [ "$_HK_FORGE_KIND" != none ] && [ -n "$_HK_FORGE_PRS" ] \
     && printf '%s\n' "$_HK_FORGE_PRS" | awk -F '\t' -v h="$base" -v b="$default" '
          $1 == h && $2 == b && tolower($3) == "merged" { found = 1; exit }
          END { exit !found }'; then
    printf 'true\n'
    return 0
  fi
  if [ "$(_hk_ancestry_state "$branch" "$base_commit" "$default")" = merged ]; then
    printf 'true\n'
    return 0
  fi
  printf 'false\n'
}

# _hk_fetch <dry> — refresh remote refs once per run when allowed. A failure
# is not fatal: the run continues on local state and says so (domains/housekeeping).
_hk_fetch() {
  local dry="$1"
  if ! cfg_bool housekeeping.fetch true; then
    return 0
  fi
  if [ "$dry" = 1 ]; then
    return 0
  fi
  if ! git -C "$JIG_PROJECT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "$JIG_PROJECT" fetch --quiet origin >/dev/null 2>&1; then
    _HK_STALE_REMOTE=1
  fi
  return 0
}

# _hk_forge_init — resolve which forge CLI to use (jig_forge_kind, common.sh)
# and pull every pull request in one call (alternatives.md C1). One network
# call per run, not per task: this command may fire at the start of every
# agent session.
_hk_forge_init() {
  _HK_FORGE_PRS=""
  _HK_FORGE_KIND=$(jig_forge_kind) || exit 1
  _HK_FORGE_TOKEN=$_HK_FORGE_KIND

  case "$_HK_FORGE_KIND" in
    github)
      _HK_FORGE_PRS=$(gh pr list --state all --limit 200 \
        --json headRefName,baseRefName,state \
        --jq '.[] | "\(.headRefName)\t\(.baseRefName)\t\(.state)"' 2>/dev/null || printf '__failed__')
      ;;
    gitlab)
      # A row needs a branch and a state; jig_glab_fields (common.sh) splits
      # glab's compact array and drops objects without a source branch.
      _HK_FORGE_PRS=$(glab mr list --all --output json 2>/dev/null \
        | jig_glab_fields source_branch target_branch state \
        | awk -F '\t' '$3 != ""' \
        || printf '__failed__')
      ;;
    *) return 0 ;;
  esac

  if [ "$_HK_FORGE_PRS" = "__failed__" ]; then
    # The tier is abandoned for the whole run rather than retried per task:
    # a forge that failed once will fail 40 times, slowly.
    _HK_FORGE_PRS=""
    _HK_FORGE_KIND="none"
    _HK_FORGE_TOKEN="failed"
    _HK_STALE_REMOTE=1
    return 0
  fi
  return 0
}

# _hk_forge_state <branch> <base> — merged|open|closed from the newest pull
# request of <branch> into <base>; `wrong-base <other>` when there is none but
# one into another branch was merged; nothing otherwise (fall through to
# ancestry). A pull request into another base is not the task's landing —
# that is how a phase merged into `main` instead of its epic, or stacked on
# another phase's branch, would read as done (ADR-0039).
_hk_forge_state() {
  local branch="$1" base="$2" line raw
  [ "$_HK_FORGE_KIND" = "none" ] && return 0
  [ -n "$_HK_FORGE_PRS" ] || return 0

  line=$(printf '%s\n' "$_HK_FORGE_PRS" | awk -F'\t' -v b="$branch" -v base="$base" '
    $1 == b && $2 == base { print $3; found = 1; exit }
    $1 == b && other == "" && tolower($3) == "merged" { other = $2 }
    END { if (!found && other != "") print "wrong-base " other }')
  [ -n "$line" ] || return 0
  case "$line" in
    wrong-base\ *) printf '%s\n' "$line"; return 0 ;;
  esac

  raw=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    merged) printf 'merged\n' ;;
    open|opened) printf 'open\n' ;;
    closed|locked) printf 'closed\n' ;;
    *) return 0 ;;
  esac
}

# _hk_ancestry_state <branch> <base_commit> <base> — merged|unknown, judged
# against <base> as jig_base_ref resolves it.
#
# Deliberately narrower than domains/housekeeping (design.md §2): git knows whether work
# landed and knows nothing about pull requests, so "not an ancestor" is not
# evidence of an open PR. The housekeeping policy gives `open` and `unknown` the same
# action, so this costs no behaviour and keeps the report honest.
_hk_ancestry_state() {
  local branch="$1" base_commit="${2:-}" base_name="${3:-}" base tip mb combined c
  [ -n "$base_name" ] || base_name=$(cfg git.base_branch main)

  # The task never had a branch of its own: it was worked on directly on the
  # base branch. "Did it merge?" is then unanswerable locally, because
  # `merge-base --is-ancestor main main` is trivially true — a commit is its
  # own ancestor — and would report every such task as merged.
  #
  # This is not hypothetical. On this repository, where 17 of 19 workspaces
  # carry `branch: main`, the earlier version of this function reported
  # `merged` for all of them, which turned 13 `consolidated` workspaces into
  # would-purge on the first real run. Trunk-based work has no local evidence
  # of landing, so the honest answer is `unknown` and the workspace is
  # preserved; only a forge can resolve these (domains/housekeeping: when uncertain,
  # preserve).
  if [ "$branch" = "$base_name" ]; then
    printf 'unknown\n'
    return 0
  fi

  base=$(jig_base_ref "$base_name")
  [ -n "$base" ] || { printf 'unknown\n'; return 0; }

  tip=$(_hk_resolve_ref "$branch")
  if [ -z "$tip" ]; then
    printf 'unknown\n'
    return 0
  fi

  # 0. The branch has contributed nothing since the task forked it, so there
  # is nothing that could have landed. Without this, a freshly created task
  # branch answers `merged` — its tip *is* the base's — and a task that
  # reaches `consolidated` without ever committing gets purged while all of
  # its work sits uncommitted in the working tree. Measured, not theorised.
  #
  # Only tasks that recorded a fork point can be asked this; a workspace from
  # before `base_commit` existed skips the check and behaves as it always did.
  # `cat-file -e <sha>^{commit}`, not `rev-parse --verify`: the latter accepts
  # the all-zero SHA as a well-formed object name and reports success, so a
  # stale fork point from a rewritten history would pass the check and then
  # make every rev-list against it empty — reading as "did nothing" for a
  # branch that may well have landed.
  if [ -n "$base_commit" ] \
     && git -C "$JIG_PROJECT" cat-file -e "$base_commit^{commit}" 2>/dev/null; then
    if [ -z "$(git -C "$JIG_PROJECT" rev-list -n 1 "$base_commit..$tip" 2>/dev/null)" ]; then
      printf 'unknown\n'
      return 0
    fi
    # ... and commits since the fork are not yet the branch's own. A branch
    # fast-forwarded onto a newer base carries the base's commits, its tip is
    # an ancestor of the base, and step 1 would call it merged. Observed on
    # 2026-09-13: `merge origin/main` onto a task branch with no commits of its
    # own, and housekeeping flagged the task for closing (ADR-0032).
    if [ "$(_hk_own_work "$tip" "$base_commit" "$base_name")" != "own" ]; then
      printf 'unknown\n'
      return 0
    fi
  fi

  # 1. Fast-forward or a real merge commit.
  if git -C "$JIG_PROJECT" merge-base --is-ancestor "$tip" "$base" 2>/dev/null; then
    printf 'merged\n'
    return 0
  fi

  mb=$(git -C "$JIG_PROJECT" merge-base "$base" "$tip" 2>/dev/null || printf '')
  if [ -z "$mb" ]; then
    printf 'unknown\n'
    return 0
  fi

  # 2. Squash merge: the branch's whole contribution collapses into one commit
  # on the base, so its patch-id matches the combined diff — not any single
  # commit's. Comparing commit-by-commit is what gets this case wrong.
  # Guarded: an unguarded pipeline assignment under `set -e` + `pipefail`
  # would abort the whole run mid-loop, and every git call here silences its
  # own stderr, so there would be no diagnostic to explain the silence.
  combined=$(git -C "$JIG_PROJECT" diff "$mb" "$tip" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1) || combined=""
  if [ -n "$combined" ]; then
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      if [ "$c" = "$combined" ]; then
        printf 'merged\n'
        return 0
      fi
    done < <(_hk_base_patch_ids "$mb" "$base")
  fi

  # 3. Rebase merge: every commit is upstream individually. `git cherry`
  # marks those with `-`; a single `+` means something did not land.
  local cherry plus
  cherry=$(git -C "$JIG_PROJECT" cherry "$base" "$tip" 2>/dev/null || printf '')
  if [ -n "$cherry" ]; then
    plus=$(printf '%s\n' "$cherry" | grep -c '^+' || true)
    if [ "$plus" = "0" ]; then
      printf 'merged\n'
      return 0
    fi
  fi

  printf 'unknown\n'
}

# _hk_reflog <ref> — "<epoch> <sha>" for every reflog entry of <ref>, newest
# first. Empty when the ref has no reflog.
_hk_reflog() {
  local out
  out=$(git -C "$JIG_PROJECT" reflog show --format='%gd %H' --date=unix "$1" 2>/dev/null \
    | sed -n 's/^.*@{\([0-9][0-9]*\)} \([0-9a-f][0-9a-f]*\)$/\1 \2/p') || out=""
  [ -z "$out" ] || printf '%s\n' "$out"
}

# _hk_base_reflog_init <tasks-dir> — read the reflog of the local and the
# remote-tracking ref of every distinct task base, and of the configured base,
# once per run into _HK_BASE_LOG, each line tagged with its base.
# `_hk_own_work` runs inside `$(...)` for every task, and a cache filled there
# would be discarded with the subshell. Per base, never `main` alone: judged
# against `main`'s reflog, every commit an epic gained would count as a task
# branch's own work (ADR-0032, ADR-0039).
_hk_base_reflog_init() {
  local tasks_dir="${1:-}" bases base ref lines tid state_file
  _HK_BASE_LOG=""
  bases=$(cfg git.base_branch main)
  if [ -n "$tasks_dir" ] && [ -d "$tasks_dir" ]; then
    while IFS= read -r state_file; do
      [ -n "$state_file" ] || continue
      tid=$(basename "$(dirname "$state_file")")
      jig_valid_id "$tid" || continue
      bases="$bases
$(jig_task_base "$tid")"
    done < <(find "$tasks_dir" -mindepth 2 -maxdepth 2 -name state -type f 2>/dev/null)
  fi
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    for ref in "refs/heads/$base" "refs/remotes/origin/$base"; do
      lines=$(_hk_reflog "$ref")
      [ -n "$lines" ] || continue
      _HK_BASE_LOG="$_HK_BASE_LOG$(printf '%s\n' "$lines" | awk -v b="$base" -v r="$ref" '{ print b "\t" r "\t" $1 "\t" $2 }')
"
    done
  done <<EOF
$(printf '%s\n' "$bases" | LC_ALL=C sort -u)
EOF
  return 0
}

# _hk_own_work <tip-ref> <base_commit> <base> — own|none|nolog: whether the
# branch holds a commit of its own, one <base> did not have when the branch
# took it. Only <base>'s reflog lines are read.
#
# Git's refs cannot tell "merged by fast-forward" from "fast-forwarded onto the
# base with nothing of its own": in both, the tip is an ancestor of the base
# and commits exist since the fork. Only time separates them — did the base
# contain the commit before the branch moved onto it, or after — and the
# reflog is where git records that time (ADR-0032). Positions are compared,
# never reflog messages: IDEs and GUI clients write those as they please.
#
# A position counts as the branch's own when it is not the fork point or
# behind it, is still contained in the tip (a commit reset away landed
# nothing), and neither base ref contained it at the latest entry no later
# than the branch's. A tie in the second goes to the base: `git pull` moves
# both in one second. With no base entry that early the position cannot be
# judged, and it is not counted — every uncertainty here resolves to
# `unknown` (RULES.md).
_hk_own_work() {
  local tip="$1" fork="$2" base="${3:-}" log t p bases b foreign undecided=0 base_log
  [ -n "$base" ] || base=$(cfg git.base_branch main)
  base_log=$(printf '%s' "$_HK_BASE_LOG" | awk -F '\t' -v b="$base" '$1 == b { print $2 "\t" $3 "\t" $4 }')
  log=$(_hk_reflog "$tip")
  if [ -z "$log" ] || [ -z "$base_log" ]; then
    printf 'nolog\n'
    return 0
  fi
  while read -r t p; do
    [ -n "$p" ] || continue
    [ "$p" != "$fork" ] || continue
    ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$p" "$fork" 2>/dev/null || continue
    git -C "$JIG_PROJECT" merge-base --is-ancestor "$p" "$tip" 2>/dev/null || continue
    bases=$(printf '%s\n' "$base_log" \
      | awk -F '\t' -v t="$t" '$2 <= t && !($1 in seen) { seen[$1] = 1; print $3 }')
    if [ -z "$bases" ]; then
      undecided=1
      continue
    fi
    foreign=0
    for b in $bases; do
      if git -C "$JIG_PROJECT" merge-base --is-ancestor "$p" "$b" 2>/dev/null; then
        foreign=1
        break
      fi
    done
    if [ "$foreign" = 0 ]; then
      printf 'own\n'
      return 0
    fi
  done <<EOF
$log
EOF
  if [ "$undecided" = 1 ]; then
    printf 'nolog\n'
  else
    printf 'none\n'
  fi
}

# _hk_base_patch_ids <merge-base> <base> — patch-id of every commit the base
# gained since the merge base, one per line.
_hk_base_patch_ids() {
  local mb="$1" base="$2" sha
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    git -C "$JIG_PROJECT" show "$sha" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
  done < <(git -C "$JIG_PROJECT" rev-list "$mb..$base" 2>/dev/null)
}

# _hk_resolve_ref <name> — print the first of <name> / origin/<name> that
# resolves to a commit, or nothing.
_hk_resolve_ref() {
  local name="$1"
  [ -n "$name" ] || return 0
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1; then
    printf '%s\n' "refs/heads/$name"
    return 0
  fi
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
    printf '%s\n' "refs/remotes/origin/$name"
    return 0
  fi
  return 0
}

# --- purge -------------------------------------------------------------------

# _hk_trash_dest <task-id> — the trash path this task would be moved to,
# avoiding collision with an entry purged earlier the same day. The rule is
# shared with `jig spec remove` and lives in common.sh (jig_trash_dest).
_hk_trash_dest() {
  jig_trash_dest "$1"
}

# _hk_purge <task-id> — move the workspace to trash. Prints the destination.
# Phase one of ADR-0006: this function contains no `rm`.
_hk_purge() {
  local id="$1" dir dest expect
  # task_dir applies _task_valid_id, the single choke point for every path
  # built from a task id (RULES.md). ADR-0006's own text states a weaker
  # pattern that matches `..`; the implementation is the correct one and is
  # not restated here.
  dir=$(task_dir "$id")
  [ -d "$dir" ] || jig_die "housekeeping: not a directory: $dir"

  # Belt and braces: after resolution the path must still be a task workspace
  # inside this project's .ai/ tree.
  expect="$(cd "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks" && pwd -P)"
  case "$(cd "$dir" && pwd -P)" in
    "$expect"/*) ;;
    *) jig_die "housekeeping: refusing to move a path outside $expect: $dir" ;;
  esac

  dest=$(_hk_trash_dest "$id")
  mkdir -p "$(dirname "$dest")"
  mv "$dir" "$dest"
  printf '%s\n' "$dest"
}

# _hk_worktree_retire <dry> <task-id> <path> — remove the worktree a task was
# started in, once the task is closed and its branch landed on its own base, or
# as its workspace is purged (ADR-0029 as amended). Non-zero, having said why,
# when the worktree has to stay.
#
# The one deletion outside .ai/ (RULES.md), so it is narrow on purpose:
# - git lists <path> as the worktree of the task's branch (the caller's lookup);
# - <path> lies under git.worktree_root, so a worktree somebody made by hand,
#   or an agent runtime made for its session, is never touched;
# - nothing under its .ai/workspace/tasks/ is anything but a link: `git
#   worktree remove` deletes ignored files silently, and a real workspace
#   there is one this checkout knows nothing about;
# - git does the deleting, without --force, so tracked changes and untracked
#   files make it refuse. At agent.git none (the default, config.sh) agents
#   do not commit, so uncommitted work in a task worktree is the normal state
#   before review, not debris; at a higher level `jig task ship` is what
#   commits it, and the same refusal still protects whatever it has not
#   reached yet.
# - no git repository inside the files the project ignores holds work that is
#   nowhere else. That refusal git does not make: it deletes ignored files
#   without a word, so a nested repository's unpushed commits went with the
#   worktree (adr-20260925-a-worktree-goes-only-when-every-git-in-it-agrees).
#   `status --porcelain` is deliberately still asked without `--ignored`: a
#   worktree that only holds node_modules/ is a worktree with nothing to lose,
#   and keeping it would make the cleanup stop cleaning.
#
# A worktree outside the root is left in place, and when it is clean and not
# locked it no longer holds the workspace back: the task is closed, its work
# landed, and nothing waits there. Keeping the workspace would put the task
# under "needs you" on every run until somebody removed a tree jig does not
# own (ADR-0029 as amended). Uncommitted work, or a lock — Claude Code locks the
# worktree of a running agent — still keeps it.
_hk_worktree_retire() {
  local dry="$1" tid="$2" path="$3" root="" reason="" own="" ours=0
  local ignored="" nested="" gone=""
  root=$(cd -P "$(_task_worktree_root)" 2>/dev/null && pwd -P) || root=""
  if [ -n "$root" ]; then
    case "$path" in
      "$root"/*) ours=1 ;;
    esac
  fi
  if [ "$ours" = 1 ]; then
    # A worktree that borrows the owner's `tasks/` directory whole holds no
    # workspace of its own, and this walk says so by itself: the path is
    # written without a trailing slash, and find does not descend a symlink
    # named as its own starting point. Add the slash and this answers with the
    # owner's tasks, every borrowing worktree reads as holding a workspace, and
    # no such worktree is ever retired again -- which is what
    # test_housekeeping_removes_the_worktree_of_a_purged_task fails on.
    own=$(find "$path/$JIG_AI_DIR/workspace/tasks" -mindepth 1 -maxdepth 1 ! -type l -print -quit 2>/dev/null) || own=""
    [ -z "$own" ] || reason="own-workspace"
  fi
  if [ -z "$reason" ] && [ -n "$(git -C "$path" status --porcelain 2>/dev/null || true)" ]; then
    reason="uncommitted-changes"
  fi
  # A lock keeps any worktree. For one of ours git would refuse anyway; asking
  # first names the real reason, which in a phase run is most likely a live
  # agent, and keeps a dry run from promising a removal git would refuse.
  if [ -z "$reason" ] && _hk_worktree_locked "$path"; then
    reason="locked"
  fi
  # What git will delete without a word, asked once and used twice: to find the
  # repositories hiding in it, and to name what went when there was none. Last
  # of the questions, because it is the only one that walks the tree.
  if [ -z "$reason" ] && [ "$ours" = 1 ]; then
    if ignored=$(_hk_worktree_ignored "$path"); then
      if [ -n "$ignored" ]; then
        nested=$(_hk_worktree_unshared "$path" "$ignored") && reason="nested-repository"
      fi
    else
      # Git did not say which files it ignores, and those are the files it would
      # delete without a word. An unanswered question keeps the worktree, as
      # every other uncertainty here does — the opposite reading, "nothing is
      # ignored", turns a failed question into a deletion.
      ignored=""
      reason="ignored-unknown"
    fi
  fi
  if [ -z "$reason" ] && [ "$ours" = 1 ] && [ "$dry" != 1 ]; then
    git -C "$JIG_PROJECT" worktree remove "$path" >/dev/null 2>&1 || reason="git-refused"
    if [ -z "$reason" ] && [ -e "$path" ]; then
      _hk_worktree_leftover "$path" || reason="leftover"
    fi
  fi

  # Recorded, not printed: the caller shows it as a --verbose line and as a
  # note in the grouped report.
  if [ -n "$reason" ]; then
    _HK_WT_LINE="worktree $path kept ($reason)"
    case "$reason" in
      own-workspace) _HK_WT_NOTE="worktree kept, it holds a task workspace of its own ($path)" ;;
      uncommitted-changes) _HK_WT_NOTE="worktree kept, it has uncommitted changes ($path)" ;;
      locked) _HK_WT_NOTE="worktree kept, it is locked, a session may still be using it ($path)" ;;
      nested-repository) _HK_WT_NOTE="worktree kept, an ignored folder in it holds a git repository with work that is nowhere else ($nested)" ;;
      ignored-unknown) _HK_WT_NOTE="worktree kept, git would not say which of its files are ignored, and those are the ones it deletes without a word ($path)" ;;
      leftover) _HK_WT_NOTE="worktree removed by git, but files remain in its directory ($path)" ;;
      *) _HK_WT_NOTE="worktree kept, git refused to remove it ($path)" ;;
    esac
    [ "$dry" = 1 ] || _hk_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) task=$tid worktree=$path action=keep reason=$reason"
    return 1
  fi
  if [ "$ours" = 0 ]; then
    _HK_WT_LINE="worktree $path left in place (outside-worktree-root)"
    _HK_WT_NOTE="worktree left in place, jig did not create it ($path)"
    [ "$dry" = 1 ] || _hk_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) task=$tid worktree=$path action=leave reason=outside-worktree-root"
    return 0
  fi
  if [ "$dry" = 1 ]; then
    _HK_WT_LINE="would-remove worktree $path"
    _HK_WT_NOTE="worktree would be removed"
  else
    _HK_WT_LINE="remove worktree $path"
    _HK_WT_NOTE="worktree removed"
    # The ignored files git deleted without a word are named here, where the
    # record outlives the run: none of them held a repository, but a .env or a
    # local database is still gone, and a person who has to ask "what was in
    # there" can no longer look.
    gone=$(_hk_ignored_summary "$ignored")
    _hk_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) task=$tid worktree=$path action=remove${gone:+ ignored=$gone}"
  fi
  return 0
}

# _hk_worktree_ignored <path> — the paths `git worktree remove` would delete
# without a word: what the project ignores, as git reports it, one per line and
# relative to the worktree. Whole ignored directories come back as one entry,
# so a tree full of dependencies is a handful of lines, not thousands. `-z`
# spares the quoting git otherwise puts around a path with a space, a quote or a
# byte above ASCII in it — measured: without `-z` those come back as
# `"with space/"` and no `[ -e ]` finds them again. The NUL stays inside the
# pipe on purpose: a command substitution drops NUL bytes, which would glue
# every entry into one line. A path with a newline in it is beyond this, and
# beyond the loops that read it.
#
# Non-zero when git did not answer: `set -o pipefail` (scripts/jig) makes the
# pipeline carry git's failure out, and the caller reads that as an uncertainty,
# never as "nothing is ignored".
_hk_worktree_ignored() {
  git -C "$1" status --porcelain -z --ignored 2>/dev/null \
    | tr '\0' '\n' \
    | sed -n 's/^!! //p'
}

# _hk_repo_holds_work <repo> — true when this repository holds work no other
# repository has. Asked of the repository's own git, because nothing outside it
# knows: the project around it does not track a line of it. A git that cannot
# answer keeps the worktree, like every other uncertainty here.
#
# The questions were chosen by measuring the cases, not by reasoning about them
# (git 2.48.1):
# - a working tree that is not clean, which needs no remote to be work;
# - no remote configured at all: then there is nowhere anything could have been
#   pushed to, and one commit is one commit that exists here only;
# - otherwise `--all --not --remotes --tags`, which catches a local branch, a
#   stash and a commit made on a detached HEAD, and stays quiet on a dependency
#   pinned to a tag. Tags are on the excluding side because a dependency cloned
#   with `--depth 1 --branch <tag>` or `--single-branch --branch <tag>` has no
#   remote-tracking ref at all — only `refs/tags/<tag>` — so `--not --remotes`
#   excludes nothing and the pin would read as unpushed work. That would keep
#   every worktree with a pinned dependency in it for ever, which is the
#   cleanup not cleaning. The cost is named in the ADR: in a repository that
#   does have a remote, a local commit reachable only from a local tag is
#   missed.
_hk_repo_holds_work() {
  local repo="$1" out
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
  out=$(git -C "$repo" status --porcelain 2>/dev/null) || return 0
  [ -z "$out" ] || return 0
  if [ -z "$(git -C "$repo" remote 2>/dev/null)" ]; then
    # "Has a commit", not "HEAD resolves": after `git checkout --orphan` HEAD is
    # unborn while the commits are still on another branch, and reading that as
    # an empty repository deletes the only copy of them.
    out=$(git -C "$repo" rev-list --max-count=1 --all 2>/dev/null) || return 0
    [ -z "$out" ] || return 0
    return 1
  fi
  out=$(git -C "$repo" rev-list --max-count=1 --all --not --remotes --tags 2>/dev/null) || return 0
  [ -z "$out" ] || return 0
  return 1
}

# _hk_worktree_unshared <path> <ignored> — the first repository inside the
# ignored files of <path> that holds work nowhere else, printed; non-zero when
# there is none. Only ignored paths are walked: anything untracked git refuses
# to delete by itself, so this is exactly its blind spot.
#
# `-prune` keeps the walk out of the object store of a repository it just
# found, and find is not given -L, so neither a starting point that is a link
# nor a link inside one is followed — .ai/workspace/tasks is itself the link
# that borrows another checkout's workspaces (the fallback shape holds one link
# per task under it instead), and it leads into another checkout entirely.
_hk_worktree_unshared() {
  local path="$1" list="$2" rel dot repo
  while IFS= read -r rel; do
    # git marks a directory with a trailing slash; find implementations differ
    # on whether they double it into the paths they print.
    rel=${rel%/}
    [ -n "$rel" ] || continue
    [ -e "$path/$rel" ] || continue
    while IFS= read -r dot; do
      repo=${dot%/.git}
      [ "$repo" != "$dot" ] || continue
      _hk_repo_holds_work "$repo" || continue
      printf '%s\n' "$repo"
      return 0
    done < <(find "$path/$rel" -name .git -prune -print 2>/dev/null)
  done < <(printf '%s\n' "$list")
  return 1
}

# _hk_ignored_summary <ignored> — those paths on one line, for the log entry of
# a removal. Jig's own ignored paths are left out: .ai/runtime is derived and
# .ai/workspace holds nothing here but the link to the tasks directory, which
# stays where it was filed. Five names, then a count: the line is a record of what
# was lost, not an inventory.
#
# Comma-separated without a space, and the caller puts the field last: the log
# line is a space-separated `key=value` record three readers parse (domains/
# housekeeping/OVERVIEW.md), and a path with a space in it must not read as the
# next field.
_hk_ignored_summary() {
  printf '%s\n' "$1" | awk -v ai="$JIG_AI_DIR/" '
    NF == 0 { next }
    index($0, ai) == 1 { next }
    { n++; if (n <= 5) out = out (out == "" ? "" : ",") $0 }
    END { if (n > 5) out = out ",+" n - 5 "-more"; print out }'
}

# _hk_worktree_leftover <path> — clear what `git worktree remove` leaves behind
# on Windows. There git removed the tracked files but left the directory, with
# `.ai/…` and the junction that borrowed the tasks directory still in it
# (measured on windows-latest, 2026-09-14). Removes links only, never what they point at —
# `find` does not follow them — and then empty directories, deepest first;
# `rmdir` cannot remove a directory that still holds anything. Non-zero when
# anything else remains, which stays where it is. Called only after git
# removed the worktree, on a path `_hk_worktree_retire` already proved is ours.
_hk_worktree_leftover() {
  local path="$1" entry
  while IFS= read -r entry; do
    [ -L "$entry" ] || continue
    rm -f "$entry" 2>/dev/null || rmdir "$entry" 2>/dev/null || true
  done < <(find "$path" -type l 2>/dev/null)
  find "$path" -depth -type d -exec rmdir {} \; 2>/dev/null || true
  [ ! -e "$path" ]
}

# _hk_worktree_locked <path> — true when git lists the worktree at <path> as
# locked, and also when git cannot list worktrees at all: an unanswered
# question keeps the workspace, like every other uncertainty here. Paths are
# compared physically, as `_task_worktrees` prints them.
_hk_worktree_locked() {
  local want="$1" list p
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p=$(cd -P "$p" 2>/dev/null && pwd -P) || continue
    [ "$p" != "$want" ] || return 0
  done < <(printf '%s\n' "$list" \
    | awk '/^worktree / { cur = substr($0, 10) } /^locked/ { print cur }')
  return 1
}

# _hk_checkout_keep <dry> <task-id> — the guard `_hk_worktree_retire` gives a
# task worktree, for a task whose branch is checked out in this checkout.
# Non-zero, having said why, when uncommitted changes sit here: they are most
# likely the task's own, and a `merged` that turned out wrong must not take the
# workspace from beside them.
_hk_checkout_keep() {
  local dry="$1" tid="$2"
  [ -n "$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null || true)" ] || return 0
  _HK_WT_LINE="checkout $JIG_PROJECT kept (uncommitted-changes)"
  _HK_WT_NOTE="this checkout has uncommitted changes on the task's branch"
  [ "$dry" = 1 ] || _hk_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) task=$tid worktree=$JIG_PROJECT action=keep reason=uncommitted-changes"
  return 1
}

# _hk_trash_expire <dry> <ttl_days> — phase two of ADR-0006. The age comes
# from the <date> directory name, not from mtime, so moving a workspace into
# trash does not restart its clock.
_hk_trash_expire() {
  local dry="$1" ttl="$2" trash day entry age
  trash="$JIG_PROJECT/$JIG_AI_DIR/runtime/trash"
  [ -d "$trash" ] || return 0

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    day=$(basename "$entry")
    case "$day" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) continue ;;
    esac
    age=$(_hk_days_since "$day")
    [ "$age" -gt "$ttl" ] || continue

    case "$(cd "$entry" && pwd -P)" in
      "$(cd "$trash" && pwd -P)"/*) ;;
      *) jig_die "housekeeping: refusing to delete outside $trash: $entry" ;;
    esac

    if [ "$dry" = 1 ]; then
      printf 'would-delete trash/%s (%d days old)\n' "$day" "$age"
    else
      rm -rf "$entry"
      printf 'delete trash/%s (%d days old)\n' "$day" "$age"
      _hk_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) trash=$day action=delete age=${age}d"
    fi
  done < <(find "$trash" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)
}

# --- reporting ---------------------------------------------------------------

# _hk_report <dry> <task> <status> <remote> <action> <flags> <dest> [facts]
# One log line for the audit trail, and the same decision as a stdout line
# with --verbose; the grouped report is _hk_record's. The log
# records `via=` — the tier that decided — because "why was this deleted" has
# to be answerable from the log alone, months later.
#
# `facts` carries the purged task's own attributes and is logged, not printed:
# a purge is the last moment they exist anywhere, and the log is the only thing
# that outlives the workspace. It is empty for every non-purge decision, so a
# preserve line keeps repeating the same short shape on every run.
_hk_report() {
  local dry="$1" tid="$2" st="$3" remote="$4" action="$5" flags="$6" dest="$7"
  local facts="${8:-}"
  local shown="$action" rel=""

  if [ "$action" = "purge" ]; then
    rel=$(jig_relpath "$dest" "$JIG_PROJECT")
    [ "$dry" = 1 ] && shown="would-purge"
  fi

  local line="$tid status=$st remote=$remote via=$_HK_VIA action=$shown"
  [ -n "$rel" ] && line="$line dest=$rel"
  [ -n "$flags" ] && line="$line flags=$flags"
  [ "$_HK_VERBOSE" != 1 ] || printf '%s\n' "$line"

  [ "$dry" = 1 ] && return 0
  _hk_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) task=$tid status=$st remote=$remote via=$_HK_VIA action=$shown${rel:+ dest=$rel}${flags:+ flags=$flags}${facts:+ $facts}"
}

# _hk_record <task> <status> <remote> <action> <flags> <age_days>
#            <abandoned_ttl_days> <branch> <base_commit> <base>
# File one task under the report group its outcome belongs to, with a note a
# person can act on. Groups: needs (something only a human can do), removed,
# waiting (consolidated, pull request open), progress, unknown (kept because
# jig cannot tell whether the work landed), expiring (abandoned, TTL running),
# skipped.
_hk_record() {
  local tid="$1" st="$2" remote="$3" action="$4" flags="$5" age="$6" ttl="$7"
  local branch="$8" base_commit="$9" base="${10:-}" group note=""

  if [ "$action" = "purge" ]; then
    group="removed"
    note="$_HK_WT_NOTE"
  else
    case ",$flags," in
      *,worktree-kept,*) group="needs"; note="$_HK_WT_NOTE" ;;
      *,wrong-base,*) group="needs"; note="$_HK_WRONG_NOTE" ;;
      *,base-unreleased,*)
        group="waiting"
        note="waiting for $base to reach $_HK_DEFAULT_BASE${_HK_WT_NOTE:+, $_HK_WT_NOTE}"
        ;;
      *,needs-consolidation,*) group="needs"; note="merged but not consolidated, run jig-consolidate" ;;
      *,abandoned?,*) group="needs"; note="pull request closed, run jig task abandon or reopen it" ;;
      *)
        case "$st" in
          abandoned) group="expiring"; note="expires in $((ttl - age + 1)) days" ;;
          consolidated)
            if [ "$remote" = "open" ]; then
              group="waiting"
            else
              group="unknown"
              note=$(_hk_unknown_reason "$branch" "$base_commit" "$base")
            fi
            ;;
          *)
            group="progress"
            if [ "$remote" = "open" ]; then note="pull request open"; fi
            ;;
        esac
        ;;
    esac
  fi
  case ",$flags," in
    *,STALE_CANDIDATE,*) note="${note:+$note, }untouched for more than the stale_after period" ;;
  esac
  printf '%s\t%s\t%s\n' "$group" "$tid" "$note" >> "$_HK_ROWS"
}

# _hk_unknown_reason <branch> <base_commit> <base> — why the remote state of a
# consolidated task came out `unknown`, in words. It answers the question the
# report exists for: this workspace is kept, so what would it take for it not
# to be? Mirrors the order _hk_ancestry_state gives up in.
_hk_unknown_reason() {
  local branch="$1" base_commit="$2" base="${3:-}" tip
  [ -n "$base" ] || base=$(cfg git.base_branch main)
  case "$branch" in
    '') printf 'never started, so there is no branch to check\n'; return 0 ;;
    detached) printf 'recorded on a detached HEAD, so there is no branch to check\n'; return 0 ;;
  esac
  if [ "$branch" = "$base" ]; then
    printf 'worked on %s directly, which leaves no trace of landing\n' "$base"
    return 0
  fi
  tip=$(_hk_resolve_ref "$branch")
  if [ -z "$tip" ]; then
    printf 'its branch %s no longer exists\n' "$branch"
    return 0
  fi
  if [ -n "$base_commit" ] \
     && git -C "$JIG_PROJECT" cat-file -e "$base_commit^{commit}" 2>/dev/null \
     && [ -z "$(git -C "$JIG_PROJECT" rev-list -n 1 "$base_commit..$tip" 2>/dev/null || true)" ]; then
    printf 'its branch has no commits since the task started\n'
    return 0
  fi
  if [ -n "$base_commit" ] \
     && git -C "$JIG_PROJECT" cat-file -e "$base_commit^{commit}" 2>/dev/null; then
    case "$(_hk_own_work "$tip" "$base_commit" "$base")" in
      none)
        printf 'its branch has no commits of its own (only commits %s already had)\n' "$base"
        return 0
        ;;
      nolog)
        printf "no reflog for its branch, so its own commits cannot be told from %s's\n" "$base"
        return 0
        ;;
    esac
  fi
  printf 'no sign that its branch landed on %s\n' "$base"
}

# _hk_print_report <dry> <trash_ttl_days> — the grouped report: what needs a
# person first, then what happened, then what is simply being kept. Within a
# group, tasks sharing a note are listed together after it, wrapped. Empty
# groups are not printed.
#
# Nothing here may look like a log line: the session hook and the scheduler
# templates append this output to the log that `jig status` and `jig measure`
# read by `task=` fields and `--- run` markers.
_hk_print_report() {
  local dry="$1" ttl="$2" day
  [ -s "$_HK_ROWS" ] || return 0
  day=$(jig_today)
  awk -F '\t' -v dry="$dry" -v day="$day" -v ttl="$ttl" '
    function emit(prefix, names,   n, p, i, w, line) {
      n = split(names, p, SUBSEP)
      line = prefix
      for (i = 1; i <= n; i++) {
        w = p[i] (i < n ? "," : "")
        if (line == prefix) line = prefix w
        else if (length(line) + 1 + length(w) > 88) { print line; line = "    " w }
        else line = line " " w
      }
      print line
    }
    {
      g = $1; note = $3
      count[g]++
      key = g SUBSEP note
      if (!(key in names)) { order[g, ++notes[g]] = note; names[key] = $2 }
      else names[key] = names[key] SUBSEP $2
    }
    END {
      split("needs removed waiting progress unknown expiring skipped", groups, " ")
      head["needs"] = "needs you (%d):"
      if (dry == 1) head["removed"] = "would remove (%d): would move to .ai/runtime/trash/" day "/"
      else head["removed"] = "removed (%d): moved to .ai/runtime/trash/" day "/, recoverable for " ttl " days"
      head["waiting"] = "waiting for merge (%d): consolidated, pull request still open"
      head["progress"] = "in progress (%d):"
      head["unknown"] = "kept, cannot tell whether it landed (%d):"
      head["expiring"] = "abandoned, waiting to expire (%d):"
      head["skipped"] = "skipped (%d): not a valid task id, left alone"
      for (gi = 1; gi <= 7; gi++) {
        g = groups[gi]
        if (!(g in count)) continue
        printf head[g] "\n", count[g]
        if ((g SUBSEP "") in names) emit("  ", names[g SUBSEP ""])
        for (k = 1; k <= notes[g]; k++) {
          if (order[g, k] == "") continue
          emit("  " order[g, k] ": ", names[g SUBSEP order[g, k]])
        }
      }
    }
  ' "$_HK_ROWS"
}

_hk_log() {
  local runtime="$JIG_PROJECT/$JIG_AI_DIR/runtime"
  mkdir -p "$runtime"
  printf '%s\n' "$1" >> "$runtime/housekeeping.log"
}

# _hk_task_facts <id> — the attributes a purged task takes with it, as log
# fields: `class=`, `created=`, `consolidated=`. A value the state file does not
# carry is omitted entirely rather than defaulted, so a reader can tell "this
# task had no class" from "this line predates the field" — neither of which is
# a T0 (jig measure).
#
# Recording them here rather than in a series of its own is the whole storage
# decision: measurement is derived from evidence that already exists, and the
# purge is the one gate every workspace passes through on its way out.
_hk_task_facts() {
  local id="$1" class created consolidated out=""
  class=$(task_state_get "$id" class)
  created=$(task_state_get "$id" created_at)
  consolidated=$(task_state_get "$id" knowledge_consolidated)
  [ -z "$class" ] || out="class=$class"
  [ -z "$created" ] || out="${out:+$out }created=$created"
  [ -z "$consolidated" ] || out="${out:+$out }consolidated=$consolidated"
  printf '%s\n' "$out"
}

# --- age ---------------------------------------------------------------------

# _hk_task_age_days <id> — days since the task was last touched. `updated_at`
# is refreshed by every `jig task set`, so it measures "how long since anyone
# worked on this", which is what both TTLs are about.
_hk_task_age_days() {
  local id="$1" d
  d=$(task_state_get "$id" updated_at)
  [ -n "$d" ] || d=$(task_state_get "$id" created_at)
  _hk_days_since "$d"
}

# _hk_days_since <YYYY-MM-DD> — whole days elapsed, 0 when unparsable.
# Mirrors jig_file_age_days's BSD/GNU `date` portability trick.
_hk_days_since() {
  local d="$1" ts now
  [ -n "$d" ] || { printf '0\n'; return; }
  if ts=$(date -j -f '%Y-%m-%d' "$d" +%s 2>/dev/null); then :; else
    ts=$(date -d "$d" +%s 2>/dev/null) || { printf '0\n'; return; }
  fi
  now=$(date +%s)
  printf '%d\n' $(( (now - ts) / 86400 ))
}

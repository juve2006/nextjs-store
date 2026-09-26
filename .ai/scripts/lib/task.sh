# cmd_task — task workspace and state (domains/task; schemas/state.md;
# ARCHITECTURE.md, Scripts layout; ADR-0005; ADR-0008).
# Sourced by scripts/jig; defines cmd_task plus the reusable readers
# `task_dir` and `task_state_get` that other libraries (context.sh) source
# this file for. bash 3.2 compatible: no associative arrays, no ${var,,},
# no mapfile.
# shellcheck shell=bash

cmd_task() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    help | -h | --help) _task_usage; return 0 ;;
  esac
  # `jig task <sub> -h|--help` prints that subcommand's usage and does nothing
  # else. Only the first argument counts: it is where every subcommand reads
  # its task id, and a later `--help` is a value (`pause --reason --help`).
  case "${1:-}" in
    -h | --help)
      if _task_usage "$sub"; then return 0; fi
      ;;
  esac
  case "$sub" in
    new) task_new "$@" ;;
    set) task_set "$@" ;;
    start) task_start "$@" ;;
    bootstrap) task_bootstrap "$@" ;;
    abandon) task_abandon "$@" ;;
    pause) task_pause "$@" ;;
    resume) task_resume "$@" ;;
    list) task_list "$@" ;;
    show) task_show "$@" ;;
    current) task_current "$@" ;;
    changes) task_changes "$@" ;;
    artifacts) task_artifacts "$@" ;;
    artifact) task_artifact "$@" ;;
    finding) task_finding "$@" ;;
    findings) task_findings "$@" ;;
    receipt) task_receipt "$@" ;;
    ship) task_ship "$@" ;;
    autopilot) task_autopilot "$@" ;;
    gate) task_gate "$@" ;;
    *) jig_die "$(_task_usage)" ;;
  esac
  # One redraw of the status page for however many writes the command made
  # (jig_status_page_dirty, common.sh). A command that stops early redraws on
  # its own way out: jig_die flushes, and so does the one `return 3` below.
  jig_status_page_flush
}

# _task_usage [sub] — the usage line of <sub>, or of `jig task` as a whole
# when <sub> is empty; non-zero, printing nothing, for an unknown <sub>. The
# one source for both `--help` and the usage errors the subcommands die with.
_task_usage() {
  case "${1:-}" in
    '') printf 'usage: jig task new|start|bootstrap|set|abandon|pause|resume|list|show|current|changes|artifacts|artifact|finding|findings|receipt|ship|autopilot|gate ...\n' ;;
    new) printf 'usage: jig task new <id> [--class T0..T4] [--domains a,b] [--from <file>]\n' ;;
    start) printf 'usage: jig task start <id> [--worktree] [--no-bootstrap]\n' ;;
    bootstrap) printf 'usage: jig task bootstrap <id>\n' ;;
    set) printf 'usage: jig task set <id> <key> <value>\n' ;;
    abandon) printf 'usage: jig task abandon <id>\n' ;;
    pause) printf 'usage: jig task pause <id> [--reason <text>] [--stash]\n' ;;
    resume) printf 'usage: jig task resume <id>\n' ;;
    list) printf 'usage: jig task list [--all] [--status <status>]\n' ;;
    show) printf 'usage: jig task show <id>\n' ;;
    current) printf 'usage: jig task current\n' ;;
    changes) printf 'usage: jig task changes <id> --base <ref> [--files <list>|-] [--format report|paths]\n' ;;
    artifacts) printf 'usage: jig task artifacts <id> [--provided discovery,design,...]\n' ;;
    artifact)
      printf 'usage: jig task artifact write <id> <kind> [--from <file>|-]\n'
      printf '       jig task artifact append <id> <kind> [--from <file>|-]\n'
      printf '       <kind>: task discovery spec alternatives design plan review verification handoff\n'
      ;;
    finding)
      printf 'usage: jig task finding add <id> --severity P0|P1|P2|P3 --where <path[:line]|-> --summary <text>\n'
      printf '       jig task finding set <id> <F-id> open|fixed|closed|dismissed [--reason <text>]\n'
      ;;
    findings) printf 'usage: jig task findings <id> [--blocking]\n' ;;
    receipt)
      printf 'usage: jig task receipt <id> --stage review|architecture-review\n'
      printf '       jig task receipt <id> --check\n'
      ;;
    ship) printf 'usage: jig task ship <id> --message-file <file> [--title <t>] [--body-file <file>] [--draft]\n' ;;
    autopilot)
      printf 'usage: jig task autopilot <id> start [--phase <spec-id>/<n>]\n'
      printf '       jig task autopilot <id> stage <name>\n'
      printf '       jig task autopilot <id> repair --reason <text>\n'
      printf '       jig task autopilot <id> stop --reason <text>\n'
      printf '       jig task autopilot <id> approve --reason <text>\n'
      printf '       jig task autopilot <id> decide --reason <text>\n'
      printf '       jig task autopilot <id> resume\n'
      printf '       jig task autopilot <id> end\n'
      printf '       jig task autopilot <id> report\n'
      ;;
    gate) printf 'usage: jig task gate <id> approved [--by human|agent]\n' ;;
    *) return 1 ;;
  esac
}

# --- reusable readers (also used by scripts/lib/context.sh) -----------------

# task_dir <id> — absolute path of the task's workspace directory. Pure
# string computation; does not check the workspace exists.
task_dir() {
  # Every subcommand goes through here, so an id like `..` or `../x` can never
  # resolve to a path outside the tasks directory (RULES.md invariant).
  _task_valid_id "$1" || jig_die "invalid task id: $1"
  printf '%s/%s/workspace/tasks/%s\n' "$JIG_PROJECT" "$JIG_AI_DIR" "$1"
}

# task_state_get <id> <key> — print the value of <key> from the task's state
# file, or nothing when the task or the key does not exist. Never dies:
# callers that need "unknown task" to be an error check for the state file
# themselves (see task_show, task_set).
task_state_get() {
  local id="$1" key="$2" file
  file="$(task_dir "$id")/state"
  [ -f "$file" ] || return 0
  # One awk rather than `sed | head`: the first `<key>:` line, its value after
  # the colon and any blanks. Half the processes for the most called reader in
  # jig, which the status page's redraw runs after every task command.
  awk -v k="$key:" 'index($0, k) == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' "$file"
}

# --- validation ---------------------------------------------------------------

_task_valid_id() {
  # The grammar is shared with spec ids (common.sh, jig_valid_id).
  jig_valid_id "$1"
}

_task_valid_class() {
  case "$1" in
    T0 | T1 | T2 | T3 | T4) return 0 ;;
    *) return 1 ;;
  esac
}

_task_valid_status() {
  case "$1" in
    active | ready | consolidated | abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

_task_valid_bool() {
  case "$1" in
    true | false) return 0 ;;
    *) return 1 ;;
  esac
}

# Comma-separated `^[a-z0-9-]+(,[a-z0-9-]+)*$` (schemas/state.md). Rejects
# empty, leading/trailing/doubled commas explicitly: field-splitting a
# trailing comma does not yield a trailing empty field in bash, so that case
# needs its own check rather than relying on the per-item loop below.
_task_valid_domains() {
  local val="$1" d
  case "$val" in
    '' | ,* | *, | *,,*) return 1 ;;
  esac
  local IFS=','
  for d in $val; do
    case "$d" in
      '' | *[!a-z0-9-]*) return 1 ;;
    esac
  done
  return 0
}

# --- findings ledger validation (design §1-2, findings-ledger) -----------------

_task_valid_severity() {
  case "$1" in P0 | P1 | P2 | P3) return 0 ;; *) return 1 ;; esac
}

_task_valid_finding_status() {
  case "$1" in open | fixed | closed | dismissed) return 0 ;; *) return 1 ;; esac
}

# A ledger field (where, summary, reason) may not contain a tab (the TSV
# delimiter) or a newline (would split the record across two lines).
_task_finding_valid_field() {
  local nl=$'\n' tab
  tab=$(printf '\t')
  case "$1" in
    *"$nl"* | *"$tab"*) return 1 ;;
  esac
  return 0
}

# --- branch -------------------------------------------------------------------

# Current branch of the checkout, or "detached" (ADR-0008: a workspace
# belongs to the checkout it was created in).
_task_current_branch() {
  local b
  if b=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null); then
    printf '%s\n' "$b"
  else
    printf 'detached\n'
  fi
}

# --- worktrees (ADR-0029) -------------------------------------------------------

# _task_worktree_root — the directory `task start --worktree` creates task
# worktrees under: `git.worktree_root`, relative to the project root unless it
# is absolute. By default a sibling of the project, `<project>.worktrees`.
#
# Beside the repository rather than inside it: a nested copy of the whole tree
# is found twice by every tool that walks the directory — test runners, type
# checkers, IDE indexers — and jig can teach its own profiles to prune it but
# not the tools of the project that adopted it (ADR-0029).
_task_worktree_root() {
  local root
  root=$(cfg git.worktree_root "")
  [ -n "$root" ] || root="../$(basename "$JIG_PROJECT").worktrees"
  case "$root" in
    /*) printf '%s\n' "$root" ;;
    *) printf '%s/%s\n' "$JIG_PROJECT" "$root" ;;
  esac
}

# _task_worktrees — "<branch><TAB><path>" for every worktree of this
# repository other than this checkout that has a branch checked out and still
# exists on disk. Paths are physical.
#
# This reads git's list of worktrees, never another checkout's .ai/, so it is
# not the cross-worktree lookup ADR-0008 rules out: it says where a branch is
# checked out, which only git knows.
_task_worktrees() {
  local list self path branch t
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 0
  self=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || return 0
  t=$(printf '\t')
  while IFS="$t" read -r path branch; do
    [ -n "$branch" ] || continue
    path=$(cd -P "$path" 2>/dev/null && pwd -P) || continue
    [ "$path" != "$self" ] || continue
    printf '%s\t%s\n' "$branch" "$path"
  done < <(printf '%s\n' "$list" | awk '
    /^worktree / { if (p != "") print p "\t" b; p = substr($0, 10); b = "" }
    /^branch refs\/heads\// { b = substr($0, 19) }
    END { if (p != "") print p "\t" b }
  ')
  return 0
}

# _task_worktree_for <branch> <worktrees> — the path of the worktree that has
# <branch> checked out, from a `_task_worktrees` listing; empty when none.
_task_worktree_for() {
  printf '%s\n' "$2" | awk -F '\t' -v b="$1" '!f && $1 == b { print $2; f = 1 }'
}

# _task_worktree_note <path> — how a task started in its own worktree is shown
# by `task list` and `jig status`: where it is, and how many files there wait
# for review. At agent.git none (the default, config.sh) agents do not
# commit, so that count is the whole review queue; at a higher level it is
# whatever `jig task ship` has not carried further yet.
_task_worktree_note() {
  local n
  n=$(_task_count_lines "$(git -C "$1" status --porcelain 2>/dev/null || true)")
  printf 'worktree=%s uncommitted=%s\n' "$1" "$n"
}

# _task_borrowed_tasks_root — the physical path of `.ai/workspace/tasks` when
# this checkout borrows the whole directory from another worktree of this
# repository. Non-zero for a directory of its own, and for any other link,
# which could point anywhere.
_task_borrowed_tasks_root() {
  local link real list p
  link="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  [ -L "$link" ] || return 1
  real=$(cd -P "$link" 2>/dev/null && pwd -P) || return 1
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r p; do
    case "$p" in
      "worktree "*) p=${p#worktree } ;;
      *) continue ;;
    esac
    p=$(cd -P "$p" 2>/dev/null && pwd -P) || continue
    if [ "$real" = "$p/$JIG_AI_DIR/workspace/tasks" ]; then
      printf '%s\n' "$real"
      return 0
    fi
  done < <(printf '%s\n' "$list")
  return 1
}

# _task_link_workspace <owner-task-dir> <tree> <id> — give <tree> the task
# workspaces of the checkout that owns <id>. Non-zero when no link could be
# made; the caller undoes the start.
#
# The whole `tasks/` directory, not the one task (ADR-0029 as amended). A task
# filed from inside the worktree then lands where every other one is, instead
# of in a directory that is gitignored, invisible to the checkout that keeps
# the queue, and deleted without a word when the tree goes; and a task filed
# outside is visible here, so an agent can confirm one exists before filing a
# duplicate. The link is still given at creation, never looked up, so
# ADR-0008's rule stands.
#
# What keeps ownership of the lifecycle where it was is `find`: housekeeping
# walks `find "$tasks_dir" -mindepth 2`, and find does not descend a symlink
# named as its own starting point, so a borrowing checkout finds no task to
# purge or retire. The globs the reporting commands use do follow it, and that
# asymmetry is exactly the split this change wants. It turns on the absence of
# a trailing slash in those two find calls, which is why they carry a comment
# saying so.
#
# The fallback to ADR-0029's single-task link is not a nicety. A path git does
# not ignore reads as untracked, and `git worktree remove` without --force --
# the only removal jig performs -- then refuses that worktree for the rest of
# its life. A rule ending in `/` matches only a directory, so a project that
# ignores `.ai/workspace/tasks/` would earn exactly that. Being blind is the
# lesser harm, so git is asked first and the old shape taken when it says no.
_task_link_workspace() {
  local owner="$1" tree="$2" id="$3" tasks rel
  rel="$JIG_AI_DIR/workspace/tasks"
  tasks="$tree/$rel"
  mkdir -p "$tree/$JIG_AI_DIR/workspace" 2>/dev/null || return 1
  if git -C "$tree" check-ignore -q "$rel" 2>/dev/null; then
    rmdir "$tasks" 2>/dev/null || true
    if [ ! -e "$tasks" ] && [ ! -L "$tasks" ]; then
      jig_link_dir "$(dirname "$owner")" "$tasks" && return 0
    fi
  fi
  mkdir -p "$tasks" 2>/dev/null || return 1
  jig_link_dir "$owner" "$tasks/$id"
}

# _task_borrowed_workspace <id> — the physical path of this task's workspace
# when it is reached through the link `task start --worktree` made. Two shapes
# are accepted, because both exist on disk: the whole `tasks/` directory
# borrowed from another worktree of this repository (what a start makes now),
# and a symlink to this same task's workspace inside a directory of this
# checkout's own (what a start made before, and what a project whose gitignore
# cannot carry a directory link still gets). Non-zero for any other link, which
# could point anywhere.
_task_borrowed_workspace() {
  local id="$1" link real list p root
  # The whole directory borrowed: every task under it is the owner's, and this
  # task's workspace is simply the one named after it.
  if root=$(_task_borrowed_tasks_root); then
    [ -d "$root/$id" ] || return 1
    printf '%s\n' "$root/$id"
    return 0
  fi
  link=$(task_dir "$id")
  [ -L "$link" ] || return 1
  real=$(cd -P "$link" 2>/dev/null && pwd -P) || return 1
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r p; do
    case "$p" in
      "worktree "*) p=${p#worktree } ;;
      *) continue ;;
    esac
    p=$(cd -P "$p" 2>/dev/null && pwd -P) || continue
    if [ "$real" = "$p/$JIG_AI_DIR/workspace/tasks/$id" ]; then
      printf '%s\n' "$real"
      return 0
    fi
  done < <(printf '%s\n' "$list")
  return 1
}

# --- candidates (design §1) -----------------------------------------------------

# Number of non-empty lines in <text>. Avoids `wc -l`'s BSD/GNU leading-space
# quirk; used everywhere a count feeds an `[ -eq ]`/`[ -gt ]` comparison.
_task_count_lines() {
  printf '%s\n' "$1" | sed '/^$/d' | awk 'END { print NR }'
}

# _task_candidates_for_branch <branch> — ids, one per line and sorted, of
# every task whose `branch` equals <branch>, whose `status` is `active` or
# `ready`, and which is not paused (design §1). `consolidated` and
# `abandoned` are excluded on purpose: their work is finished and they stay
# reachable by explicit id, which is what keeps a trunk-based repository from
# becoming permanently ambiguous once finished-but-unmerged workspaces pile
# up on the same branch.
_task_candidates_for_branch() {
  local branch="$1" base dir id br st paused list=""
  base="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  for dir in "$base"/*/; do
    [ -f "${dir}state" ] || continue
    id=$(basename "$dir")
    # A directory that is not a well-formed task id is not ours to read
    # (RULES.md): task_state_get would die on it, and take `task current` with it.
    _task_valid_id "$id" || continue
    br=$(task_state_get "$id" branch)
    [ "$br" = "$branch" ] || continue
    st=$(task_state_get "$id" status)
    case "$st" in
      active | ready) ;;
      *) continue ;;
    esac
    paused=$(task_state_get "$id" paused)
    [ "$paused" = "true" ] && continue
    list="$list
$id"
  done
  printf '%s\n' "$list" | sed '/^$/d' | sort
}

# The single candidate on <branch>, or nothing when there are zero or several
# (an advisory hint for `task start`'s dirty-tree refusal, not a resume
# decision — ambiguity there is fine, it just means the message stays
# generic rather than naming a task it cannot be sure of).
_task_likely_owner() {
  local branch="$1" candidates
  candidates=$(_task_candidates_for_branch "$branch")
  [ "$(_task_count_lines "$candidates")" -eq 1 ] || return 0
  printf '%s\n' "$candidates"
}

# --- task.md template ----------------------------------------------------------

# Write <dest> with {{TASK_ID}} substituted, from <from> when given
# (task_new --from: a path, or "-" for stdin — the user's own document,
# copied as-is), otherwise from templates/task.md. Uses jig_source_root when
# the running copy is a framework source checkout (dev mode, and every test
# run); an installed copy (`.ai/scripts/`) ships no templates/ directory at
# all — jig init only ever places files *sourced from* templates/, never the
# directory itself — so that case falls back to a minimal built-in copy of
# the same template. Written atomically.
#
# The substitution is a single `sed s/{{TASK_ID}}/<id>/g` over the source
# stream: <id> is restricted to `[A-Za-z0-9._-]` (_task_valid_id) so it is
# safe as a sed replacement, and sed passes every byte outside the matched
# placeholder through unchanged — no reformatting, no whole-body rewrite, so
# a --from document with backslashes, `&`, backticks, tabs or non-ASCII
# survives byte-for-byte except at the placeholder itself. A document
# without the placeholder is copied verbatim.
_task_write_task_md() {
  local id="$1" dest="$2" from="${3:-}" source tmpl tmp
  tmp="$dest.tmp.$$"
  if [ -n "$from" ]; then
    if [ "$from" = "-" ]; then
      sed "s/{{TASK_ID}}/$id/g" > "$tmp"
    else
      sed "s/{{TASK_ID}}/$id/g" "$from" > "$tmp"
    fi
  else
    source=$(jig_source_root)
    tmpl=""
    [ -n "$source" ] && [ -f "$source/templates/task.md" ] && tmpl="$source/templates/task.md"
    if [ -n "$tmpl" ]; then
      sed "s/{{TASK_ID}}/$id/g" "$tmpl" > "$tmp"
    else
      cat > "$tmp" <<EOF
# $id

## Goal

<!-- One paragraph: what must be true when this task is done. -->

## Scope

<!-- In / out. Affected areas or files if known; \`jig context --files\` uses the diff, not this list. -->

## Notes

<!-- Working notes for this task. Nothing here survives the task unless consolidation moves it to .ai/knowledge/. -->
EOF
    fi
  fi
  mv "$tmp" "$dest"
}

# --- state file rewriting -------------------------------------------------------

# Rewrite <dir>/state with <key> set to <value> (replacing an existing line,
# or inserting one before `created_at:` when the key is absent) and
# `updated_at` refreshed to today. Atomic write (ADR-0008): state.tmp.$$
# then mv. awk, not sed, does the substitution: <value> is printed literally
# rather than used as a sed replacement, so it needs no escaping.
_task_rewrite_state() {
  local dir="$1" key="$2" value="$3" file tmp today
  file="$dir/state"
  tmp="$dir/state.tmp.$$"
  today=$(jig_today)
  awk -v key="$key" -v value="$value" -v today="$today" '
    {
      line = $0
      if (line ~ ("^" key ":")) {
        print key ": " value
        done = 1
      } else if (!done && line ~ /^created_at:/) {
        print key ": " value
        print line
        done = 1
      } else if (line ~ /^updated_at:/) {
        print "updated_at: " today
      } else {
        print line
      }
    }
    END {
      if (!done) print key ": " value
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  jig_status_page_dirty
}

# Rewrite <dir>/state with the <key> line removed (companion to
# _task_rewrite_state above, same atomic write and `updated_at` refresh).
# A no-op, beyond refreshing `updated_at`, when <key> is already absent.
_task_rewrite_state_remove() {
  local dir="$1" key="$2" file tmp today
  file="$dir/state"
  tmp="$dir/state.tmp.$$"
  today=$(jig_today)
  awk -v key="$key" -v today="$today" '
    {
      line = $0
      if (line ~ ("^" key ":")) {
        next
      } else if (line ~ /^updated_at:/) {
        print "updated_at: " today
      } else {
        print line
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  jig_status_page_dirty
}

# _task_touch_state <dir> — refresh `updated_at` and mark the status page,
# for a write that changed a workspace without changing a key. Rewriting an
# artifact is such a write: state carries no artifact field, but a task whose
# plan was rewritten today is not a task last touched last week, and a status
# page that still shows the old date says the task is untouched (ADR-0008:
# the page never shows less than the files do). Same atomic write as
# _task_rewrite_state, and a no-op when the state file is gone.
_task_touch_state() {
  local dir="$1" file tmp today
  file="$dir/state"
  [ -f "$file" ] || return 0
  tmp="$dir/state.tmp.$$"
  today=$(jig_today)
  awk -v today="$today" '
    /^updated_at:/ { print "updated_at: " today; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  jig_status_page_dirty
}

# --- pause / resume helpers (design §4, §5) --------------------------------------

# Whole days between <date> (YYYY-MM-DD) and today; 0 when <date> is empty or
# unparsable. Mirrors jig_file_age_days's BSD/GNU `date` portability trick
# (ADR-0002: no GNU-only tools assumed).
_task_days_since() {
  local d="$1" ts now
  [ -n "$d" ] || { printf '0\n'; return; }
  if ts=$(date -j -f '%Y-%m-%d' "$d" +%s 2>/dev/null); then :; else
    ts=$(date -d "$d" +%s 2>/dev/null) || { printf '0\n'; return; }
  fi
  now=$(date +%s)
  printf '%d\n' $(( (now - ts) / 86400 ))
}

# _task_resume_overlap <id> — files this task changed that were also changed
# on the task's base since the merge base (design §5: overlap, not distance).
# Empty, rather than an error, when the base or the merge base is missing —
# the resume report simply omits the section then.
_task_resume_overlap() {
  local base ref mb task_files base_files
  base=$(jig_task_base "$1")
  ref=$(jig_base_ref "$base")
  [ -n "$ref" ] || return 0
  mb=$(git -C "$JIG_PROJECT" merge-base "$ref" HEAD 2>/dev/null) || return 0
  task_files=$(jig_git_touched_files --base-branch "$base")
  base_files=$(git -C "$JIG_PROJECT" diff --name-only "$mb" "$ref" 2>/dev/null)
  comm -12 \
    <(printf '%s\n' "$task_files" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$base_files" | sed '/^$/d' | sort -u)
}

# _task_branch_name <id> — the branch this task will live on, from
# `git.branch_template` with {id} substituted. Dies on a name git would
# reject, using git's own rules rather than a hand-rolled regex: the set of
# invalid ref names is long (`..`, a trailing `.lock`, control characters, a
# leading dash) and getting it wrong here means creating a ref nobody can
# delete without plumbing.
_task_branch_name() {
  local id="$1" template name
  template=$(cfg git.branch_template "task/{id}")
  case "$template" in
    *'{id}'*) ;;
    *) jig_die "task start: git.branch_template must contain {id}: $template" ;;
  esac
  name=${template%%'{id}'*}$id${template#*'{id}'}
  git check-ref-format --branch "$name" >/dev/null 2>&1 \
    || jig_die "task start: git rejects the branch name: $name"
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1; then
    jig_die "task start: branch already exists: $name (reusing it would attach this task to someone else's work)"
  fi
  printf '%s\n' "$name"
}

# Refuse to start a task on a dirty working tree (design §6): untracked files
# never block (build output is not work in progress), only tracked changes do —
# a `git status --porcelain` line that is not `??`. There is no override: the
# changes would ride into the new branch and become this task's first commit,
# which is how four tasks recorded someone else's work on 2026-09-11.
#
# The refusal is a fork, not a dead end, when branches are per task: the other
# road is a worktree of its own, which leaves this checkout — and the work in
# it — untouched (ADR-0029).
_task_refuse_dirty_tree() {
  local branch="$1" id="${2:-}" tracked owner fork=""
  tracked=$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null | grep -v '^??' || true)
  [ -n "$tracked" ] || return 0

  if [ -n "$id" ] && cfg_bool git.branch_per_task true; then
    fork=", or start it in its own worktree: \`jig task start $id --worktree\`"
  fi
  owner=$(_task_likely_owner "$branch")
  if [ -n "$owner" ]; then
    jig_die "task start: uncommitted changes in the working tree, likely from task $owner; run \`jig task pause $owner --stash\` first$fork"
  else
    jig_die "task start: uncommitted changes in the working tree; commit them, or pause the task that owns them with --stash$fork"
  fi
}

# --- subcommands ----------------------------------------------------------------

task_new() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage new)"
  local id="$1"
  shift
  local class="" domains="" from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --class) [ $# -ge 2 ] || jig_die "task new: --class requires a value"; class="$2"; shift 2 ;;
      --domains) [ $# -ge 2 ] || jig_die "task new: --domains requires a value"; domains="$2"; shift 2 ;;
      --from) [ $# -ge 2 ] || jig_die "task new: --from requires a value"; from="$2"; shift 2 ;;
      *) jig_die "task new: unknown argument: $1" ;;
    esac
  done

  _task_valid_id "$id" || jig_die "task new: invalid task id: $id"

  # A task filed in a worktree that keeps a task directory of its own dies with
  # that worktree: the directory is gitignored, the checkout holding the queue
  # never sees it, and `git worktree remove` deletes ignored files without a
  # word. Three statements written by agents at the end of their own work were
  # nearly lost that way in one shift. A worktree from `jig task start
  # --worktree` borrows the owner's directory whole and files the task with
  # every other one, so it never reaches this check; any other worktree is told
  # where the task belongs instead of losing it quietly.
  local clone_root
  if ! _task_borrowed_tasks_root >/dev/null 2>&1; then
    clone_root=$(jig_config_clone_root)
    [ "$clone_root" = "$JIG_PROJECT" ] \
      || jig_die "task new: this worktree keeps a $JIG_AI_DIR/workspace/tasks/ of its own, so a task filed here would be invisible to $clone_root and would go when the worktree goes; file it in $clone_root"
  fi

  local dir
  dir=$(task_dir "$id")
  [ -e "$dir" ] && jig_die "task new: task already exists: $id"

  [ -z "$class" ] || _task_valid_class "$class" || jig_die "task new: invalid class: $class"
  [ -z "$domains" ] || _task_valid_domains "$domains" || jig_die "task new: invalid domains: $domains"

  # --from is validated here, before the workspace directory exists, so a
  # missing/unreadable/non-regular source (a directory, for instance) never
  # leaves a half-created task behind. "-" means stdin: nothing to check.
  if [ -n "$from" ] && [ "$from" != "-" ]; then
    [ -e "$from" ] || jig_die "task new: --from: no such file: $from"
    [ -f "$from" ] || jig_die "task new: --from: not a regular file: $from"
    [ -r "$from" ] || jig_die "task new: --from: file not readable: $from"
  fi

  # No dirty-tree check here: filing touches neither the checkout nor the
  # branch, so there is nothing for uncommitted work to leak into. The check
  # lives in `task start`, and filing a task for later in the middle of other
  # work is the case this split exists for.
  mkdir -p "$dir"

  # `branch` and `base_commit` are written by `task start`, not here. A task
  # filed for later has no branch, and saying so by *omission* is what makes
  # it invisible to `_task_candidates_for_branch`: an absent value matches no
  # branch name, so the task cannot become an ambiguous `task current`
  # candidate. Before this, a filed task claimed whatever branch the checkout
  # happened to be on, and four of them claimed a branch they had nothing to
  # do with in a single day (ADR-0026, as amended).
  local tmp="$dir/state.tmp.$$"
  {
    printf 'task_id: %s\n' "$id"
    [ -z "$class" ] || printf 'class: %s\n' "$class"
    printf 'status: active\n'
    printf 'knowledge_consolidated: false\n'
    [ -z "$domains" ] || printf 'domains: %s\n' "$domains"
    printf 'created_at: %s\n' "$(jig_today)"
    printf 'updated_at: %s\n' "$(jig_today)"
  } > "$tmp"
  mv "$tmp" "$dir/state"
  jig_status_page_dirty

  _task_write_task_md "$id" "$dir/task.md" "$from"

  jig_relpath "$dir" "$JIG_PROJECT"
}

# task_start <id> — begin work on a filed task: cut its branch, check it out
# and record where it forked from.
#
# Separate from `resume` on purpose. `resume` means "undo a pause", and a task
# can be *both* unstarted and paused — every task filed on 2026-09-11 was. One
# verb doing either thing depending on hidden state would collapse the two
# absences this design just separated, which is the ambiguity ADR-0012 refused
# for `task current`.
#
# The branch is cut here rather than at `task new` because a fork point
# recorded weeks before work begins is a fact that is false by the time it is
# first needed (ADR-0026, as amended).
task_start() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage start)"
  local id="$1" worktree=0 bootstrap=1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) worktree=1; shift ;;
      --no-bootstrap) bootstrap=0; shift ;;
      *) jig_die "task start: unknown argument: $1" ;;
    esac
  done
  [ "$bootstrap" = 1 ] || [ "$worktree" = 1 ] \
    || jig_die "task start: --no-bootstrap says what not to carry into a worktree; it needs --worktree"
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task start: unknown task: $id"

  # A `branch` with no `base_commit` was recorded at filing, before starting
  # was a separate step: it is the branch the checkout happened to be on, not
  # one the task forked. Such a task was never started, and starting it is how
  # its record gets repaired — by the script that owns the key, not by hand
  # (ADR-0008). A task with a fork point is started, and stays refused.
  local existing
  existing=$(task_state_get "$id" branch)
  if [ -n "$existing" ]; then
    [ -z "$(task_state_get "$id" base_commit)" ] \
      || jig_die "task start: already started on $existing"
    jig_info "task start: $id recorded $existing when it was filed, with no fork point; starting it now"
  fi

  # The base the task is cut from and has to land on, recorded beside the
  # fork point so that everything judging the task later reads the same
  # answer (ADR-0039). Checked before anything is created.
  local base
  base=$(_task_start_base "$id") || exit 1

  # A repository with no commit has nothing to fork from: git cannot cut a
  # branch there, and "could not create branch" named the symptom, not the
  # cause.
  git -C "$JIG_PROJECT" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
    || jig_die "task start: the repository has no commits yet; commit something first (even a README), then start the task"

  if [ "$worktree" -eq 1 ]; then
    _task_start_in_worktree "$id" "$dir" "$base" "$bootstrap"
    return 0
  fi

  # Before either path, not only before a branch is cut: with one shared
  # branch the leak is the same — base_commit would name a point the
  # uncommitted work is already on top of.
  _task_refuse_dirty_tree "$(_task_current_branch)" "$id"

  local branch base_commit
  if cfg_bool git.branch_per_task true; then
    branch=$(_task_branch_name "$id")
    base_commit=$(_task_start_branch "$branch" "$base") \
      || jig_die "task start: could not create branch $branch"
  else
    # A project that works on one branch by choice still gets a start: the
    # task records where it began, which is what housekeeping needs to tell
    # "did nothing" from "landed".
    branch=$(_task_current_branch)
    base_commit=$(git -C "$JIG_PROJECT" rev-parse HEAD 2>/dev/null) \
      || jig_die "task start: cannot resolve HEAD"
  fi

  _task_rewrite_state "$dir" branch "$branch"
  _task_rewrite_state "$dir" base_commit "$base_commit"
  _task_rewrite_state "$dir" base_branch "$base"
  _task_base_hint "$id" "$base"
  _task_paused_hint "$id" ""
  printf '%s\n' "$branch"
}

# _task_start_in_worktree <id> <dir> — start the task on its own branch in a
# new worktree, leaving this checkout exactly as it was (ADR-0029).
#
# The workspace does not move. The worktree gets one link to the owner's whole
# `tasks/` directory (_task_link_workspace), so the checkout the task was filed
# in keeps seeing every task — including the ones filed from inside the
# worktree, which a link to this one task alone left stranded — and the
# workspace's lifecycle — housekeeping, trash — stays in one place. The link is
# absolute because git keeps worktree paths absolute too; moving the repository
# breaks both alike, and `git worktree repair` is the answer to that.
#
# No dirty-tree check: nothing uncommitted here can reach a tree cut fresh
# from the base. The command prints the path and stops there: a script cannot
# move the agent session that called it. Getting a session into the worktree —
# switching one there, where the runtime allows it, or opening a new one — is
# the agent's and the human's step, not jig's (ADR-0029 as amended).
_task_start_in_worktree() {
  local id="$1" dir="$2" base="$3" bootstrap="${4:-1}" branch path owner base_commit
  cfg_bool git.branch_per_task true \
    || jig_die "task start: --worktree needs git.branch_per_task: true (one branch cannot be checked out in two worktrees)"
  branch=$(_task_branch_name "$id")
  path="$(_task_worktree_root)/$id"
  if [ -e "$path" ] || [ -L "$path" ]; then
    jig_die "task start: worktree path already exists: $path"
  fi
  owner=$(cd -P "$dir" && pwd -P) || jig_die "task start: cannot resolve the workspace of $id"
  # Before anything is created: without a directory link the worktree could
  # only get a copy of the workspace, and a copy is two tasks from its first
  # write (jig_link_detect).
  jig_link_detect
  [ "$_JIG_LINK_KIND" != none ] \
    || jig_die "task start: --worktree needs a directory link, and neither a symlink nor a junction can be made here; start the task in this checkout instead"

  local start
  start=$(jig_fresh_base_ref "$base" "task start") || exit 1
  base_commit=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$start^{commit}" 2>/dev/null) \
    || jig_die "task start: cannot resolve $start"

  if ! git -C "$JIG_PROJECT" worktree add -q -b "$branch" "$path" "$base_commit" >/dev/null 2>&1; then
    _task_undo_worktree_start "$branch" "$path" "$base_commit"
    jig_die "task start: could not create worktree $path"
  fi
  if ! _task_link_workspace "$owner" "$path" "$id"; then
    _task_undo_worktree_start "$branch" "$path" "$base_commit"
    jig_die "task start: could not link the workspace of $id into $path"
  fi
  path=$(cd -P "$path" && pwd -P) || jig_die "task start: cannot resolve worktree $path"

  _task_rewrite_state "$dir" branch "$branch"
  _task_rewrite_state "$dir" base_commit "$base_commit"
  _task_rewrite_state "$dir" base_branch "$base"

  # Only now, with the task started and its workspace linked, is the state git
  # does not track carried over. Last, and never fatal: a tree missing a
  # dependency is not a broken task, and what a failed carry leaves behind --
  # the tree and the branch -- is exactly what `jig task bootstrap` needs to
  # try again (adr-20260924-a-worktree-carries-what-git-does-not).
  if [ "$bootstrap" = 1 ]; then
    _task_carry_into "$JIG_PROJECT" "$path" "task start"
  fi

  _task_base_hint "$id" "$base"
  _task_paused_hint "$id" " there"
  jig_info "task start: $id is on $branch in its own worktree; open a new agent session in $path"
  printf '%s\n' "$path"
}

# _task_carry_into <owner-abs> <tree-abs> <verb> — load the bootstrap library
# and carry the declared state into a task worktree. A wrapper so that
# `task start --worktree` and `task bootstrap` load the same two libraries the
# same way, and so that every other task command pays for neither (verify.sh
# sources profiles.sh on the same terms).
_task_carry_into() {
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"
  # shellcheck source=lib/bootstrap.sh
  . "$JIG_LIB/bootstrap.sh"
  jig_bootstrap_worktree "$1" "$2" "$3"
}

# task_bootstrap <id> — carry the declared state into the task's existing
# worktree again.
#
# It exists because the carry is deliberately the last and least important
# step of `task start --worktree`: when it fails halfway — no disk left, a
# path declared wrong — the worktree and the branch are fine and must not be
# rolled back, but a second `task start` refuses on the path that now exists.
# Without this verb the only repair is by hand, which is the cleanup by manual
# discipline RULES.md rejects (adr-20260924-a-worktree-carries-what-git-does-not).
#
# Idempotent by construction: it carries only what the worktree does not have,
# the same rule `task start` uses, so running it twice changes nothing.
#
# It works from either side. Run in the owning checkout, git says where the
# task's branch is checked out; run inside the task's own worktree, the
# borrowed workspace link says which checkout owns it.
task_bootstrap() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage bootstrap)"
  local id="$1" dir branch tree owner workspace
  shift
  [ $# -eq 0 ] || jig_die "task bootstrap: unknown argument: $1"

  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task bootstrap: unknown task: $id"
  branch=$(task_state_get "$id" branch)
  [ -n "$branch" ] || jig_die "task bootstrap: $id has not been started yet"

  if workspace=$(_task_borrowed_workspace "$id"); then
    tree=$(cd -P "$JIG_PROJECT" && pwd -P) \
      || jig_die "task bootstrap: cannot resolve this checkout"
    owner=${workspace%"/$JIG_AI_DIR/workspace/tasks/$id"}
  else
    owner=$(cd -P "$JIG_PROJECT" && pwd -P) \
      || jig_die "task bootstrap: cannot resolve this checkout"
    tree=$(_task_worktree_for "$branch" "$(_task_worktrees)")
    [ -n "$tree" ] || jig_die "task bootstrap: $id has no worktree of its own"
  fi
  [ -d "$owner" ] || jig_die "task bootstrap: cannot find the checkout that owns $id"
  [ "$owner" != "$tree" ] || jig_die "task bootstrap: $id is not in a worktree of its own"

  _task_carry_into "$owner" "$tree" "task bootstrap"
}

# _task_base_hint <id> <base> — a task cut from anything but the project's base
# says where its pull request goes, at the moment nobody has opened it yet.
# A pull request into the default branch would read, to housekeeping, as work
# in the wrong place (wrong-base), long after it could have been prevented.
_task_base_hint() {
  [ "$2" != "$(cfg git.base_branch main)" ] || return 0
  jig_info "task start: $1 is cut from $2; open its pull request into $2"
}

# _task_paused_hint <id> <where> — starting is not resuming (a task can be
# both unstarted and paused), so a paused task stays paused; say how to go on.
_task_paused_hint() {
  [ "$(task_state_get "$1" paused)" = "true" ] || return 0
  jig_info "task start: $1 is paused; run \`jig task resume $1\`$2 to make it current"
}

# _task_start_base <id> — the base a task being started is cut from, after
# refreshing it from origin (ADR-0040).
#
# A task linked to a spec whose roadmap declares an open epic is cut from the
# epic; every other task from `git.base_branch`. Each way a phase could end up
# on `main` without anyone noticing is refused instead of falling back: a spec
# this checkout does not have, an epic branch that exists nowhere, an epic
# already finished. The fetch runs for every task: a stale local `main` cuts a
# stale branch just as surely as a missing epic does.
_task_start_base() {
  local id="$1" default base spec="" line="" rc=0 roadmap
  default=$(cfg git.base_branch main)
  base=$default
  if [ -f "$(task_dir "$id")/task.md" ]; then
    spec=$(jig_spec_link "$(task_dir "$id")/task.md") || rc=$?
    [ "$rc" -ne 2 ] || jig_die "task start: $id links to more than one spec; keep one Spec: line"
  fi
  if [ -n "$spec" ]; then
    roadmap="$JIG_PROJECT/$JIG_AI_DIR/specs/$spec/roadmap.md"
    [ -f "$roadmap" ] \
      || jig_die "task start: $id links to spec $spec, which this checkout does not have; switch to a branch that has it"
    rc=0
    line=$(jig_spec_epic "$roadmap") || rc=$?
    [ "$rc" -ne 2 ] || jig_die "task start: spec $spec declares more than one epic; keep one Epic: line"
    if [ -n "$line" ]; then
      base=${line% *}
      [ "${line##* }" = open ] \
        || jig_die "task start: spec $spec marks epic $base finished; drop \"— finished\" from its Epic: line to cut tasks from it, or link the task to another spec"
    fi
  fi
  git check-ref-format --branch "$base" >/dev/null 2>&1 \
    || jig_die "task start: git rejects the base branch name: $base"

  if [ "$base" = "$default" ]; then
    jig_fetch_branches "task start" "$default"
  else
    jig_fetch_branches "task start" "$default" "$base"
    [ -n "$(jig_base_ref "$base")" ] \
      || jig_die "task start: epic $base of spec $spec exists neither here nor on origin; push it, or create it with \`jig spec epic $spec\`"
  fi
  printf '%s\n' "$base"
}

# _task_start_branch <name> <base> — create <name> off the freshest <base>,
# check it out here, and print the commit it starts from.
#
# Cut from the commit, not the ref: a branch started from origin/<base> would
# otherwise get origin/<base> as its upstream, and `git status` would report
# the task as "ahead of origin/main" — a branch that is never pushed there.
_task_start_branch() {
  local name="$1" base="$2" start commit
  start=$(jig_fresh_base_ref "$base" "task start") || exit 1
  commit=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$start^{commit}" 2>/dev/null) || return 1
  git -C "$JIG_PROJECT" checkout -q -b "$name" "$commit" >/dev/null 2>&1 || return 1
  printf '%s\n' "$commit"
}

# _task_undo_worktree_start <branch> <path> <commit> — take back what a failed
# `task start --worktree` made, so that running it again can succeed rather
# than hitting "branch already exists" forever. `git worktree add -b` creates
# the branch before the directory, so a failure can leave either behind.
#
# Only what this very call created is removed, and without force. The path
# did not exist before (checked), and a fresh checkout has nothing to lose, so
# `git worktree remove` needs no --force; if it refuses, the worktree stays.
# The branch is deleted with `update-ref -d <ref> <commit>`, which deletes only
# while it still points at the commit it was cut at — a branch anyone has
# committed to since is never touched — and only when no worktree has it
# checked out.
_task_undo_worktree_start() {
  local branch="$1" path="$2" commit="$3"
  git -C "$JIG_PROJECT" worktree remove "$path" >/dev/null 2>&1 || true
  git -C "$JIG_PROJECT" worktree prune >/dev/null 2>&1 || true
  if [ -z "$(_task_worktree_for "$branch" "$(_task_worktrees)")" ]; then
    git -C "$JIG_PROJECT" update-ref -d "refs/heads/$branch" "$commit" >/dev/null 2>&1 || true
  fi
}

task_set() {
  [ $# -eq 3 ] || jig_die "$(_task_usage set)"
  jig_require_init
  local id="$1" key="$2" value="$3" dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task set: unknown task: $id"

  case "$key" in
    class) _task_valid_class "$value" || jig_die "task set: invalid class: $value" ;;
    status) _task_valid_status "$value" || jig_die "task set: invalid status: $value" ;;
    knowledge_consolidated) _task_valid_bool "$value" || jig_die "task set: invalid knowledge_consolidated: $value" ;;
    domains) _task_valid_domains "$value" || jig_die "task set: invalid domains: $value" ;;
    task_id | branch | base_commit | base_branch | created_at | updated_at | paused | paused_at | paused_reason | paused_stash \
      | autopilot | autopilot_repairs | autopilot_mode | autopilot_phase | gate | gate_design | gate_by | pr_url)
      jig_die "task set: key is not writable: $key" ;;
    *) jig_die "task set: unknown key: $key" ;;
  esac

  # ADR-0030: a task closes only after the knowledge decision is recorded.
  # Without this order check, `status consolidated` could be written by hand
  # ahead of `knowledge_consolidated`, which is exactly how a task ended up
  # closed with no recorded knowledge decision. Idempotent: re-setting
  # `status consolidated` on an already-consolidated task still succeeds,
  # since its flag is already true by then.
  if [ "$key" = status ] && [ "$value" = consolidated ] && [ "$(task_state_get "$id" knowledge_consolidated)" != "true" ]; then
    jig_die "task set: status consolidated requires knowledge_consolidated true; record the knowledge decision first: jig task set $id knowledge_consolidated true"
  fi
  if [ "$key" = knowledge_consolidated ] && [ "$value" = false ] && [ "$(task_state_get "$id" status)" = consolidated ]; then
    jig_die "task set: knowledge_consolidated cannot be false on a consolidated task: $id"
  fi

  # Completion stops here (design §4): `status ready` is verify's own
  # sign-off, and `knowledge_consolidated true` is consolidation's. A P0/P1
  # finding still open, or fixed but not re-reviewed, refuses both.
  local gate=0
  case "$key:$value" in
    status:ready) gate=1 ;;
    knowledge_consolidated:true) gate=1 ;;
  esac
  if [ "$gate" -eq 1 ]; then
    local blocking
    blocking=$(_task_blocking_findings "$id")
    [ -z "$blocking" ] || jig_die "task set: $(_task_gate_blocking_message "$id" "$blocking")"
    # review-receipt (design.md §3): a receipt that no longer matches what was
    # reviewed, or a T4 task with none at all, refuses the same way. Checked
    # after the findings gate, same order as the two ledger checks above.
    local receipt_msg
    receipt_msg=$(_task_receipt_gate_message "$id")
    [ -z "$receipt_msg" ] || jig_die "task set: $receipt_msg"
  fi

  _task_rewrite_state "$dir" "$key" "$value"
}

task_abandon() {
  [ $# -eq 1 ] || jig_die "$(_task_usage abandon)"
  task_set "$1" status abandoned
}

# --- autopilot run (design.md, .ai/workspace/tasks/autopilot-run) --------------
#
# `.ai/workspace/tasks/<id>/autopilot` — gitignored workspace file, TSV, one
# line per event: `<UTC ISO time>\t<event>\t<text>` where event is one of
# start, stage, repair, stop, resume, approve, decide, end and text is a
# single line with no tab (validated the same way as a findings-ledger field,
# _task_finding_valid_field).
#
# State: `autopilot: on|stopped|done` (absent before the first `start`),
# `autopilot_repairs: <n>` (the repair count for the current run, reset to 0
# by `start` and by `resume`), `autopilot_mode: attended|unattended` (read
# from `autopilot.unattended` once, by `start`, so changing the key halfway
# changes nothing about a run). All three are script-owned, alongside `paused`
# and the other keys `task set` refuses to write by hand (schemas/state.md).
#
# An unattended run asks nothing
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci): where an
# attended run would stop, the skill takes the safe default and says so with
# `approve` (it approved its own design at a gate) or `decide` (it chose for
# the human), and `report` lists both for the pull request. Only an
# unattended run may record either: in an attended one they are stops.
#
# The repair limit (2 per run, design's gate decision) is enforced here, not
# by the calling skill: a script-side stop is a stop no orchestration prompt
# can talk its way past.

# _task_autopilot_now — UTC ISO-8601 timestamp for one journal line (same
# format housekeeping.sh's log lines use, conventions/shell.md).
_task_autopilot_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _task_autopilot_valid_stage <name> — same grammar as one item of
# _task_valid_domains: `[a-z0-9-]+`, nothing else.
_task_autopilot_valid_stage() {
  case "$1" in
    '' | *[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

# _task_autopilot_repairs <id> — the current run's repair count, "0" when
# the state key is absent or not a plain integer (a task that never
# repaired).
_task_autopilot_repairs() {
  local n
  n=$(task_state_get "$1" autopilot_repairs)
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# _task_autopilot_log <id> <event> <text> — append one line to the run
# journal. Atomic the same way task_finding_add's ledger write is
# (conventions/shell.md): copy the existing journal into a temp file (or
# start an empty one), append the new line, then `mv` it into place. Chosen
# over a bare `>>`, which is already "atomic enough" for a single `printf`
# whose line fits in one write(2) call, because `report` reads this file
# with a plain `read` loop and a torn write — the one failure `>>` does not
# rule out on every filesystem — would misalign every line after it, not
# just the interrupted one; copy-then-`mv` can only ever yield the file
# exactly as it was before the append, or exactly as it is after.
_task_autopilot_log() {
  local id="$1" event="$2" text="$3" dir file tmp
  dir=$(task_dir "$id")
  file="$dir/autopilot"
  tmp="$file.tmp.$$"
  if [ -f "$file" ]; then
    cp "$file" "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$(_task_autopilot_now)" "$event" "$text" >> "$tmp"
  mv "$tmp" "$file"
  jig_status_page_dirty
}

# _task_autopilot_note <id> — "autopilot=on" or "autopilot=stopped" for
# `jig status`'s task line; empty for `done` or no run at all (same shape as
# _task_worktree_note — the caller prepends its own separating space).
_task_autopilot_note() {
  case "$(task_state_get "$1" autopilot)" in
    on) printf 'autopilot=on\n' ;;
    stopped) printf 'autopilot=stopped\n' ;;
  esac
}

# _task_autopilot_facts <id> — the run as data, for `report` and the status
# page (ARCHITECTURE.md, Scripts layout: a report consumes an unformatted
# producer rather than parsing a formatted one). One line,
# `<state>\t<repairs>\t<stage>\t<stage-at>\t<stop-reason>\t<stop-at>\t<phase>`,
# every empty field written `-` so a tab-split read cannot collapse it;
# nothing at all for a task that never started a run. The stage is the last
# one the current run reached — since its last `start` or `resume` — and the
# stop is the journal's last, which is the one a `stopped` run is waiting on.
# <phase> is `autopilot_phase` when a coordinator started this run as one task
# of a roadmap phase (adr-20260922-a-phase-run-is-coordinated).
_task_autopilot_facts() {
  local id="$1" state file
  state=$(task_state_get "$id" autopilot)
  [ -n "$state" ] || return 0
  file="$(task_dir "$id")/autopilot"
  {
    if [ -f "$file" ]; then cat "$file"; fi
  } | awk -F '\t' -v state="$state" -v repairs="$(_task_autopilot_repairs "$id")" \
        -v phase="$(task_state_get "$id" autopilot_phase)" '
    $2 == "start" || $2 == "resume" { stage = ""; stage_at = "" }
    $2 == "stage" { stage = $3; stage_at = $1 }
    $2 == "stop"  { stop = $3; stop_at = $1 }
    function v(x) { return x == "" ? "-" : x }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", state, repairs, v(stage), v(stage_at), v(stop), v(stop_at), v(phase) }
  '
}

# jig task autopilot <id> start|stage|repair|stop|resume|end|report —
# dispatches to the functions below. The task id comes before the action
# (same order as `task set <id> <key> <value>`), so every action function
# below takes <id> as its first argument.
task_autopilot() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage autopilot)"
  local id="$1"
  shift
  local action="${1:-}"
  [ $# -gt 0 ] && shift
  case "$action" in
    start) _task_autopilot_start "$id" "$@" ;;
    stage) _task_autopilot_stage "$id" "$@" ;;
    repair) _task_autopilot_repair "$id" "$@" ;;
    stop) _task_autopilot_stop "$id" "$@" ;;
    approve) _task_autopilot_unattended_event "$id" approve "$@" ;;
    decide) _task_autopilot_unattended_event "$id" decide "$@" ;;
    resume) _task_autopilot_resume "$id" "$@" ;;
    end) _task_autopilot_end "$id" "$@" ;;
    report) _task_autopilot_report "$id" "$@" ;;
    *) jig_die "$(_task_usage autopilot)" ;;
  esac
}

# _task_autopilot_valid_phase <value> — exit 0 when <value> is `<spec-id>/<n>`:
# a spec id by jig_valid_id (the grammar task and spec ids share, common.sh)
# and a phase number, one slash between them. Neither is resolved against a
# roadmap: a worktree cut before the wave's tags landed has no roadmap to
# check against, and a wrong id here costs a journal line, not a wrong action.
_task_autopilot_valid_phase() {
  local value="$1" spec num
  case "$value" in
    */*/* | /* | */) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  spec=${value%/*}
  num=${value##*/}
  jig_valid_id "$spec" || return 1
  case "$num" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# start [--phase <spec-id>/<n>]: refused while a run is already `on`; on a
# `stopped` run it points at `resume` rather than silently restarting; after
# `done`, or on a task that never ran one, it starts a fresh run (design §2
# open question 2: `resume`, not `start`, is what resets the count — `start`
# here resets it too, but only because there is no prior count left to
# preserve).
#
# `--phase` marks the run as one task of a phase run: a coordinator started it
# alongside the rest of a roadmap wave, owns the spec and ships the task
# itself (adr-20260922-a-phase-run-is-coordinated). It is recorded as
# `autopilot_phase`, so the two readers that must behave differently see it
# without being told — `jig spec done` refuses in this task's branch, and the
# status page sends the person to the coordinator's session instead of this
# task's.
_task_autopilot_start() {
  local id="$1"
  shift
  local phase=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        [ $# -ge 2 ] || jig_die "task autopilot start: --phase requires a value"
        phase="$2"
        shift 2 ;;
      *) jig_die "task autopilot start: unknown argument: $1" ;;
    esac
  done
  if [ -n "$phase" ]; then
    _task_autopilot_valid_phase "$phase" \
      || jig_die "task autopilot start: --phase takes <spec-id>/<n>, the spec and its phase number: $phase"
  fi
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot start: unknown task: $id"
  case "$(task_state_get "$id" autopilot)" in
    on) jig_die "task autopilot start: already running: $id" ;;
    stopped) jig_die "task autopilot start: $id is stopped; run: jig task autopilot $id resume" ;;
  esac
  local mode=attended
  if jig_unattended; then mode=unattended; fi
  _task_rewrite_state "$dir" autopilot on
  _task_rewrite_state "$dir" autopilot_repairs 0
  _task_rewrite_state "$dir" autopilot_mode "$mode"
  if [ -n "$phase" ]; then
    _task_rewrite_state "$dir" autopilot_phase "$phase"
    _task_autopilot_log "$id" start "$mode phase $phase"
  else
    _task_autopilot_log "$id" start "$mode"
  fi
  if [ "$mode" = unattended ]; then
    printf 'autopilot: on (unattended)\n'
  else
    printf 'autopilot: on\n'
  fi
  [ -z "$phase" ] || printf 'phase: %s\n' "$phase"
}

# _task_autopilot_mode <id> — the mode the current run recorded at `start`:
# `unattended`, or `attended` for anything else, a run started before modes
# existed included.
_task_autopilot_mode() {
  if [ "$(task_state_get "$1" autopilot_mode)" = unattended ]; then
    printf 'unattended\n'
  else
    printf 'attended\n'
  fi
}

# stage <name>: logs which stage the run just reached. Requires an active
# run — a run only ever moves through stages while `on`.
_task_autopilot_stage() {
  local id="$1"
  shift
  [ $# -ge 1 ] || jig_die "$(_task_usage autopilot)"
  local name="$1"
  shift
  [ $# -eq 0 ] || jig_die "task autopilot stage: unknown argument: $1"
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot stage: unknown task: $id"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot stage: no active autopilot run: $id; run: jig task autopilot $id start"
  _task_autopilot_valid_stage "$name" \
    || jig_die "task autopilot stage: invalid name: $name (expected [a-z0-9-]+)"
  _task_autopilot_log "$id" stage "$name"
  printf 'stage: %s\n' "$name"
}

# repair --reason <text>: one repair attempt, limited to 2 per run (gate
# decision, task.md human gate). Attempts 1 and 2 increment the count and
# keep the run `on`; the 3rd does not count as a repair at all — it is the
# mechanical stop the design calls for, so the skill can never argue its way
# past the limit. Exit 3 on that stop, distinct from the plain `jig_die`
# exit 1 every other refusal here uses, so a caller can tell "you gave bad
# arguments" apart from "the run just stopped".
_task_autopilot_repair() {
  local id="$1"
  shift
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot repair: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task autopilot repair: unknown argument: $1" ;;
    esac
  done
  [ "$has_reason" -eq 1 ] || jig_die "task autopilot repair: --reason is required"
  [ -n "$reason" ] || jig_die "task autopilot repair: --reason must not be empty"
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot repair: --reason must be a single line with no tab"

  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot repair: unknown task: $id"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot repair: no active autopilot run: $id; run: jig task autopilot $id start"

  local count
  count=$(_task_autopilot_repairs "$id")
  if [ "$count" -lt 2 ]; then
    count=$((count + 1))
    _task_rewrite_state "$dir" autopilot_repairs "$count"
    _task_autopilot_log "$id" repair "$reason"
    printf 'repair %s/2\n' "$count"
    return 0
  fi

  # The 3rd attempt does not increment: the count stays at the limit it
  # already reached, and the run stops instead.
  _task_rewrite_state "$dir" autopilot stopped
  _task_autopilot_log "$id" stop "repair limit reached (2): $reason"
  printf 'stop: repair limit reached (2)\n'
  # `return 3` ends the command under errexit before cmd_task's own flush.
  jig_status_page_flush
  return 3
}

# stop --reason <text>: the stop an agent notices for itself (design §3's
# table — the T3/T4 gate, a re-classification, an unowned decision, a
# destructive operation). Requires an active run, same as repair.
_task_autopilot_stop() {
  local id="$1"
  shift
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot stop: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task autopilot stop: unknown argument: $1" ;;
    esac
  done
  [ "$has_reason" -eq 1 ] || jig_die "task autopilot stop: --reason is required"
  [ -n "$reason" ] || jig_die "task autopilot stop: --reason must not be empty"
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot stop: --reason must be a single line with no tab"

  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot stop: unknown task: $id"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot stop: no active autopilot run: $id; run: jig task autopilot $id start"

  _task_rewrite_state "$dir" autopilot stopped
  _task_autopilot_log "$id" stop "$reason"
  printf 'autopilot: stopped\n'
}

# approve|decide --reason <text>: what an unattended run did instead of
# stopping — `approve` for its own design at a gate, `decide` for a choice
# nobody made or a destructive step it left out. Requires an active run whose
# recorded mode is unattended: in an attended run each of these is a stop, and
# a journal line cannot stand in for the human's answer.
_task_autopilot_unattended_event() {
  local id="$1" event="$2"
  shift 2
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot $event: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task autopilot $event: unknown argument: $1" ;;
    esac
  done
  [ "$has_reason" -eq 1 ] || jig_die "task autopilot $event: --reason is required"
  [ -n "$reason" ] || jig_die "task autopilot $event: --reason must not be empty"
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot $event: --reason must be a single line with no tab"

  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot $event: unknown task: $id"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot $event: no active autopilot run: $id; run: jig task autopilot $id start"
  [ "$(_task_autopilot_mode "$id")" = unattended ] \
    || jig_die "task autopilot $event: $id's run is attended; stop and ask the human instead: jig task autopilot $id stop --reason <text>"

  _task_autopilot_log "$id" "$event" "$reason"
  printf '%s: %s\n' "$event" "$reason"
}

# resume: after the human answers a stop. Requires `stopped` and resets the
# repair count to 0 — the human just gave the run a new direction, so the
# two repairs already spent no longer count against it (task.md human gate).
_task_autopilot_resume() {
  local id="$1"
  shift
  [ $# -eq 0 ] || jig_die "task autopilot resume: unknown argument: $1"
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot resume: unknown task: $id"
  [ "$(task_state_get "$id" autopilot)" = "stopped" ] \
    || jig_die "task autopilot resume: not stopped: $id"

  _task_rewrite_state "$dir" autopilot on
  _task_rewrite_state "$dir" autopilot_repairs 0
  _task_autopilot_log "$id" resume ""
  printf 'autopilot: on\n'
}

# end: the run reached the end of its route (design §1 step 5, after
# consolidation). Requires an active run.
_task_autopilot_end() {
  local id="$1"
  shift
  [ $# -eq 0 ] || jig_die "task autopilot end: unknown argument: $1"
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot end: unknown task: $id"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot end: no active autopilot run: $id; run: jig task autopilot $id start"

  _task_rewrite_state "$dir" autopilot "done"
  _task_autopilot_log "$id" end ""
  printf 'autopilot: done\n'
}

# report: the journal in readable form, then a final summary line. A task
# that never ran `start` at all — no journal file — is not an error: "no
# autopilot run", exit 0.
_task_autopilot_report() {
  local id="$1"
  shift
  [ $# -eq 0 ] || jig_die "task autopilot report: unknown argument: $1"
  local dir file
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot report: unknown task: $id"
  file="$dir/autopilot"
  if [ ! -f "$file" ]; then
    printf 'no autopilot run\n'
    return 0
  fi

  local ts event text
  while IFS=$'\t' read -r ts event text; do
    if [ -n "$text" ]; then
      printf '%s %s: %s\n' "$ts" "$event" "$text"
    else
      printf '%s %s\n' "$ts" "$event"
    fi
  done < "$file"

  # What an unattended run chose instead of asking, in blocks the skill
  # copies into the pull request as they are: the human reads them there.
  local block
  block=$(awk -F '\t' '$2 == "decide" { print "- " $3 }' "$file")
  [ -z "$block" ] || printf '\nDecided without you:\n%s\n' "$block"
  block=$(awk -F '\t' '$2 == "approve" { print "- " $3 }' "$file")
  [ -z "$block" ] || printf '\nApproved by the agent, not a human:\n%s\n' "$block"

  local facts state repairs mode=""
  facts=$(_task_autopilot_facts "$id")
  state=$(printf '%s\n' "$facts" | cut -f 1)
  repairs=$(printf '%s\n' "$facts" | cut -f 2)
  [ -n "$repairs" ] || repairs=0
  [ "$(_task_autopilot_mode "$id")" != unattended ] || mode=", unattended"
  printf 'autopilot: %s, repairs: %s/2%s\n' "$state" "$repairs" "$mode"
}

# --- findings ledger (design.md, findings-ledger) ------------------------------
#
# `.ai/workspace/tasks/<id>/findings` — gitignored workspace file, TSV, one
# line per finding:
#   F<n>  P0|P1|P2|P3  open|fixed|closed|dismissed  where  summary  date  reason
# `where` is `path[:line]` or `-`; `summary` is one line; `date` is the date
# of the last change to the line; `reason` (7th column) holds the dismissal
# reason and is empty for every other status. Written atomically
# (conventions/shell.md: tmp.$$ then mv), and every check on the arguments
# runs before the file is touched, so a refused call leaves it byte-identical.
#
# "Blocking" (severity P0/P1, status open or fixed — fixed still blocks until
# a re-review closes it) is computed once, in _task_blocking_findings, so
# `task set`, `task ship` and `jig status` cannot disagree about it
# (ARCHITECTURE.md, Scripts layout: a reporting command consumes a peer's
# answer, never recomputes it).

# _task_finding_next_id <file> — "F<n>", n one more than the highest existing
# F<n> id in <file> ("F1" when <file> is absent). One awk pass rather than a
# shell loop reading ids one at a time, so a malformed id already on disk
# cannot desync a hand-kept counter from what gets printed.
_task_finding_next_id() {
  local file="$1" max
  if [ -f "$file" ]; then
    max=$(awk -F '\t' '{ n = $1; sub(/^F/, "", n); if (n + 0 > max + 0) max = n + 0 } END { print max + 0 }' "$file")
  else
    max=0
  fi
  printf 'F%d\n' "$((max + 1))"
}

# _task_blocking_findings <id> — "<F-id> <severity> <status> <where>", one
# line per P0/P1 finding still open or fixed. Empty, not an error, when the
# task has no ledger file at all — a task with no findings behaves exactly as
# it did before this feature existed.
_task_blocking_findings() {
  local file
  file="$(task_dir "$1")/findings"
  [ -f "$file" ] || return 0
  awk -F '\t' '
    ($2 == "P0" || $2 == "P1") && ($3 == "open" || $3 == "fixed") { print $1, $2, $3, $4 }
  ' "$file"
}

# _task_gate_blocking_message <id> <blocking-lines> — the refusal text for a
# gate that found <blocking-lines> (as _task_blocking_findings prints them)
# non-empty: names every blocking finding and how to clear one (design §4).
_task_gate_blocking_message() {
  local id="$1" blocking="$2" n names="" sep="" first_fid="" line
  n=$(_task_count_lines "$blocking")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    names="$names$sep$line"
    sep="; "
    [ -n "$first_fid" ] || first_fid=${line%% *}
  done < <(printf '%s\n' "$blocking")
  if [ "$n" -eq 1 ]; then
    printf '%s blocking finding (%s); fix it and have a re-review close it (jig task finding set %s %s closed), or dismiss it with the human'"'"'s yes (jig task finding set %s %s dismissed --reason <text>)' \
      "$n" "$names" "$id" "$first_fid" "$id" "$first_fid"
  else
    printf '%s blocking findings (%s); fix each and have a re-review close it (jig task finding set %s <F-id> closed), or dismiss it with the human'"'"'s yes (jig task finding set %s <F-id> dismissed --reason <text>)' \
      "$n" "$names" "$id" "$id"
  fi
}

# jig task finding add|set — dispatches to task_finding_add / task_finding_set.
task_finding() {
  jig_require_init
  local action="${1:-}"
  [ $# -gt 0 ] && shift
  case "$action" in
    add) task_finding_add "$@" ;;
    set) task_finding_set "$@" ;;
    *) jig_die "$(_task_usage finding)" ;;
  esac
}

# task_finding_add <id> --severity P0|P1|P2|P3 --where <path[:line]|->
# --summary <text> — append a finding in status `open`, printing its new id
# (F<n>) on stdout.
task_finding_add() {
  [ $# -ge 1 ] || jig_die "$(_task_usage finding)"
  local id="$1"
  shift
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task finding add: unknown task: $id"

  local severity="" where="" summary="" has_severity=0 has_where=0 has_summary=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --severity)
        [ $# -ge 2 ] || jig_die "task finding add: --severity requires a value"
        severity="$2"; has_severity=1; shift 2 ;;
      --where)
        [ $# -ge 2 ] || jig_die "task finding add: --where requires a value"
        where="$2"; has_where=1; shift 2 ;;
      --summary)
        [ $# -ge 2 ] || jig_die "task finding add: --summary requires a value"
        summary="$2"; has_summary=1; shift 2 ;;
      *) jig_die "task finding add: unknown argument: $1" ;;
    esac
  done
  [ "$has_severity" -eq 1 ] || jig_die "task finding add: --severity is required"
  [ "$has_where" -eq 1 ] || jig_die "task finding add: --where is required"
  [ "$has_summary" -eq 1 ] || jig_die "task finding add: --summary is required"

  _task_valid_severity "$severity" || jig_die "task finding add: invalid severity: $severity (expected P0|P1|P2|P3)"
  [ -n "$summary" ] || jig_die "task finding add: --summary must not be empty"
  _task_finding_valid_field "$where" || jig_die "task finding add: --where must be a single line with no tab"
  _task_finding_valid_field "$summary" || jig_die "task finding add: --summary must be a single line with no tab"

  local file fid tmp
  file="$dir/findings"
  fid=$(_task_finding_next_id "$file")
  tmp="$file.tmp.$$"
  if [ -f "$file" ]; then
    cp "$file" "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\topen\t%s\t%s\t%s\t\n' "$fid" "$severity" "$where" "$summary" "$(jig_today)" >> "$tmp"
  mv "$tmp" "$file"
  jig_status_page_dirty

  printf '%s\n' "$fid"
}

# task_finding_set <id> <F-id> open|fixed|closed|dismissed [--reason <text>]
# — rewrite one ledger line's status (and, for dismissed, its reason).
# `closed` and `dismissed` are final except for a return to `open`
# (regression, design §2); every other listed transition is allowed.
task_finding_set() {
  [ $# -ge 3 ] || jig_die "$(_task_usage finding)"
  local id="$1" fid="$2" new_status="$3"
  shift 3
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task finding set: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task finding set: unknown argument: $1" ;;
    esac
  done

  local dir file
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task finding set: unknown task: $id"
  file="$dir/findings"
  [ -f "$file" ] || jig_die "task finding set: no findings recorded for task: $id"

  _task_valid_finding_status "$new_status" \
    || jig_die "task finding set: invalid status: $new_status (expected open|fixed|closed|dismissed)"

  if [ "$new_status" = dismissed ]; then
    if [ "$has_reason" -eq 0 ] || [ -z "$reason" ]; then
      jig_die "task finding set: dismissed requires --reason"
    fi
    _task_finding_valid_field "$reason" || jig_die "task finding set: --reason must be a single line with no tab"
  else
    [ "$has_reason" -eq 0 ] || jig_die "task finding set: --reason is only valid with dismissed"
  fi

  local cur_status
  cur_status=$(JIG_F_ID="$fid" awk -F '\t' '$1 == ENVIRON["JIG_F_ID"] { print $3; found = 1 } END { if (!found) exit 1 }' "$file") \
    || jig_die "task finding set: unknown finding: $fid"

  case "$cur_status" in
    closed | dismissed)
      [ "$new_status" = open ] \
        || jig_die "task finding set: $fid is $cur_status; only \`open\` follows it (regression)"
      ;;
  esac

  local tmp today
  tmp="$file.tmp.$$"
  today=$(jig_today)
  # Values reach awk through the environment, not `-v`: awk expands escape
  # sequences in a `-v` value, so a reason spelling a literal backslash-t
  # would be written as a tab and split the record the check above allowed.
  JIG_F_ID="$fid" JIG_F_STATUS="$new_status" JIG_F_TODAY="$today" JIG_F_REASON="$reason" \
    awk -F '\t' -v OFS='\t' '
      $1 == ENVIRON["JIG_F_ID"] {
        $3 = ENVIRON["JIG_F_STATUS"]; $6 = ENVIRON["JIG_F_TODAY"]; $7 = ENVIRON["JIG_F_REASON"]
      }
      { print }
    ' "$file" > "$tmp"
  mv "$tmp" "$file"
  jig_status_page_dirty
}

# jig task findings <id> [--blocking] — a table of every recorded finding,
# then `blocking: <n>`. --blocking prints only the blocking lines and sets
# the exit code a script or skill can act on directly: 1 when n > 0, 0
# otherwise (mirroring `context guard`). A task with no ledger file at all:
# `no findings`, `blocking: 0`, exit 0.
task_findings() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage findings)"
  local id="$1" blocking_only=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --blocking) blocking_only=1; shift ;;
      *) jig_die "task findings: unknown argument: $1" ;;
    esac
  done

  local dir file blocking bcount
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task findings: unknown task: $id"
  file="$dir/findings"

  blocking=$(_task_blocking_findings "$id")
  bcount=$(_task_count_lines "$blocking")

  if [ "$blocking_only" -eq 1 ]; then
    [ "$bcount" -eq 0 ] || printf '%s\n' "$blocking"
    printf 'blocking: %s\n' "$bcount"
    if [ "$bcount" -eq 0 ]; then
      return 0
    else
      return 1
    fi
  fi

  if [ ! -f "$file" ]; then
    printf 'no findings\n'
  else
    awk -F '\t' '{
      line = $1" "$2" "$3" "$4" "$5" "$6
      if ($7 != "") line = line" reason="$7
      print line
    }' "$file"
  fi
  printf 'blocking: %s\n' "$bcount"
  return 0
}

# --- review receipt (design.md, review-receipt) --------------------------------
#
# `.ai/workspace/tasks/<id>/receipt` — gitignored workspace file, flat
# `key: value`, one review's worth of state (design.md §1): `stage`,
# `reviewed_at`, `tree` (a git tree id — everything `git add -A` would stage
# from the project root, except `.ai/knowledge/` and `.ai/specs/`, which
# consolidation writes after review), `base_commit` and `head` (read by
# people, not compared), `design` (a hash of the approved design document(s))
# and `findings` (a hash of the findings ledger at review time). Written
# atomically (tmp.$$ then mv), like every other workspace file here.
#
# Pins the reviewed tree's *content*, not a commit: review most often runs
# against an uncommitted working tree (agent.git: none), where HEAD is the
# base, not what was reviewed, and a commit made after review (by hand or
# `task ship`) must not by itself make the receipt stale.

# _task_review_dir <id> — the checkout that holds <id>'s working tree: the
# one git lists with the task's branch checked out, this checkout or a task
# worktree (ADR-0029). A task with no branch of its own answers this
# checkout. Non-zero when the branch is checked out nowhere: its working tree
# cannot be read, and fingerprinting whatever this checkout holds instead
# would pin, or check, the wrong change.
_task_review_dir() {
  local branch dir
  branch=$(task_state_get "$1" branch)
  if [ -z "$branch" ] || [ "$branch" = "$(_task_current_branch)" ]; then
    printf '%s\n' "$JIG_PROJECT"
    return 0
  fi
  dir=$(_task_worktree_for "$branch" "$(_task_worktrees)")
  [ -n "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# _task_review_tree <dir> — the git tree id of everything `git add -A` would
# stage right now in the checkout <dir>, minus `.ai/knowledge/` and
# `.ai/specs/`. Computed through a temporary index so the real one is never
# touched: every git call below is pointed at a throwaway `GIT_INDEX_FILE`,
# cleaned up on every return path rather than through an EXIT trap, because
# this function can run many times in one process — once per task with a
# receipt, from `jig status` — and a single process-wide trap variable (the
# convention `task_ship`'s PR body file uses) would only remember the last one.
#
# A repository with no commits yet has no HEAD to read: `read-tree` is
# skipped in that case rather than treated as a failure, and the temporary
# index simply starts empty (a missing GIT_INDEX_FILE reads as one).
_task_review_tree() {
  local dir="$1" tmp tree
  tmp=$(mktemp "${TMPDIR:-/tmp}/jig-task-review-tree.XXXXXX") || return 1
  rm -f "$tmp"

  if git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    if ! GIT_INDEX_FILE="$tmp" git -C "$dir" read-tree HEAD 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  fi
  if ! GIT_INDEX_FILE="$tmp" git -C "$dir" add -A 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  GIT_INDEX_FILE="$tmp" git -C "$dir" rm -r -q --cached --ignore-unmatch \
    -- "$JIG_AI_DIR/knowledge" "$JIG_AI_DIR/specs" >/dev/null 2>&1 || true
  tree=$(GIT_INDEX_FILE="$tmp" git -C "$dir" write-tree 2>/dev/null) || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$tree"
}

# _task_receipt_design_hash <id> — the receipt's `design` field: the hash of
# design.md, and for a T4 task also spec.md and alternatives.md when they
# exist, combined by hashing their own "<name> <hash>" lines together so any
# one of the documents changing changes the combined value too. "-" when
# design.md itself is absent — nothing has been approved yet to pin.
_task_receipt_design_hash() {
  local id="$1" dir class lines file
  dir=$(task_dir "$id")
  [ -f "$dir/design.md" ] || { printf -- '-\n'; return 0; }
  lines="design.md $(jig_hash "$dir/design.md")"
  class=$(task_state_get "$id" class)
  if [ "$class" = T4 ]; then
    for file in spec.md alternatives.md; do
      [ -f "$dir/$file" ] || continue
      lines="$lines
$file $(jig_hash "$dir/$file")"
    done
  fi
  printf '%s\n' "$lines" | git hash-object --stdin
}

# _task_receipt_findings_hash <id> — the receipt's `findings` field: the hash
# of the findings ledger file, or "-" when the task has none. Any later edit
# to the ledger — including the author closing their own finding — changes
# this and makes the receipt stale (design.md §3: the ledger tie-in).
_task_receipt_findings_hash() {
  local file
  file="$(task_dir "$1")/findings"
  if [ -f "$file" ]; then
    jig_hash "$file"
  else
    printf -- '-\n'
  fi
}

# _task_receipt_get <id> <key> — the value of <key> from the task's receipt
# file, or nothing when the task has no receipt or the key is absent.
# Companion to task_state_get, same shape, different file.
_task_receipt_get() {
  local id="$1" key="$2" file
  file="$(task_dir "$id")/receipt"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -n 1
}

# _task_receipt_changed <id> — "tree", "design", "findings", any combination
# joined by ", ", or empty, for the parts of an existing receipt that no
# longer match the task's current state; empty (not an error) when the task
# has no receipt at all. One function decides staleness so `--check`, the
# three completion gates and `jig status` cannot disagree about what "stale"
# means (ARCHITECTURE.md, Scripts layout: a reporting command consumes a
# peer's answer, never recomputes it).
_task_receipt_changed() {
  local id="$1" file changed="" sep="" cur dir
  file="$(task_dir "$id")/receipt"
  [ -f "$file" ] || return 0

  # A tree that cannot be read — the branch checked out nowhere — counts as
  # changed: the gate must not pass on a change it could not look at.
  cur=""
  if dir=$(_task_review_dir "$id"); then
    cur=$(_task_review_tree "$dir") || cur=""
  fi
  if [ "$cur" != "$(_task_receipt_get "$id" tree)" ]; then
    changed="$changed${sep}tree"
    sep=", "
  fi
  cur=$(_task_receipt_design_hash "$id")
  if [ "$cur" != "$(_task_receipt_get "$id" design)" ]; then
    changed="$changed${sep}design"
    sep=", "
  fi
  cur=$(_task_receipt_findings_hash "$id")
  if [ "$cur" != "$(_task_receipt_get "$id" findings)" ]; then
    changed="$changed${sep}findings"
    sep=", "
  fi
  printf '%s\n' "$changed"
}

# _task_receipt_gate_message <id> — empty when the task's review receipt
# needs no attention; otherwise the refusal text (the caller still prefixes
# it with "<command>: ", same as _task_gate_blocking_message) for a stale
# receipt, or for a T4 task with no receipt at all (design.md §3). Read by
# task_set's two gates and task_ship's recheck — the same three call sites
# _task_blocking_findings has, right after it.
_task_receipt_gate_message() {
  local id="$1" changed class
  if [ -f "$(task_dir "$id")/receipt" ]; then
    changed=$(_task_receipt_changed "$id")
    [ -n "$changed" ] || return 0
    printf 'review is stale: code changed since review on %s (%s); re-review and run: jig task receipt %s --stage %s' \
      "$(_task_receipt_get "$id" reviewed_at)" "$changed" "$id" "$(_task_receipt_get "$id" stage)"
    return 0
  fi
  class=$(task_state_get "$id" class)
  if [ "$class" = T4 ]; then
    printf 'T4 needs a review receipt; run the independent review, then: jig task receipt %s --stage review' "$id"
  fi
  return 0
}

# jig task receipt <id> --stage review|architecture-review — write the
# receipt and print it; jig task receipt <id> --check — report whether it
# still matches.
task_receipt() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage receipt)"
  local id="$1"
  shift
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task receipt: unknown task: $id"

  local stage="" has_stage=0 check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage)
        [ $# -ge 2 ] || jig_die "task receipt: --stage requires a value"
        stage="$2"; has_stage=1; shift 2 ;;
      --check) check=1; shift ;;
      *) jig_die "task receipt: unknown argument: $1" ;;
    esac
  done
  [ "$check" -eq 0 ] || [ "$has_stage" -eq 0 ] || jig_die "task receipt: --stage and --check are mutually exclusive"

  if [ "$check" -eq 1 ]; then
    task_receipt_check "$id"
    return
  fi

  [ "$has_stage" -eq 1 ] || jig_die "$(_task_usage receipt)"
  case "$stage" in
    review | architecture-review) ;;
    *) jig_die "task receipt: invalid stage: $stage (expected review|architecture-review)" ;;
  esac

  task_receipt_write "$id" "$stage"
}

# task_receipt_write <id> <stage> — write the task's receipt (design.md §1)
# and print it. One receipt per task: a repeated call, most often a
# re-review, replaces it outright — the stage most recently written wins, and
# nothing reads the one it overwrote.
task_receipt_write() {
  local id="$1" stage="$2" dir tree base_commit head design findings file tmp
  dir=$(task_dir "$id")
  local review_dir
  review_dir=$(_task_review_dir "$id") \
    || jig_die "task receipt: $(task_state_get "$id" branch) is not checked out in any worktree; review the task where its branch is"
  tree=$(_task_review_tree "$review_dir") || jig_die "task receipt: could not read the working tree"
  base_commit=$(task_state_get "$id" base_commit)
  head=$(git -C "$review_dir" rev-parse --verify --quiet HEAD 2>/dev/null) || head=""
  design=$(_task_receipt_design_hash "$id")
  findings=$(_task_receipt_findings_hash "$id")

  file="$dir/receipt"
  tmp="$file.tmp.$$"
  {
    printf 'stage: %s\n' "$stage"
    printf 'reviewed_at: %s\n' "$(jig_today)"
    printf 'tree: %s\n' "$tree"
    printf 'base_commit: %s\n' "$base_commit"
    printf 'head: %s\n' "$head"
    printf 'design: %s\n' "$design"
    printf 'findings: %s\n' "$findings"
  } > "$tmp"
  mv "$tmp" "$file"
  jig_status_page_dirty
  cat "$file"
}

# task_receipt_check <id> — `receipt: current|stale (...)|none`, exit 1 for
# stale and for a T4 task with none at all (design.md §3), exit 0 otherwise.
task_receipt_check() {
  local id="$1" file changed class
  file="$(task_dir "$id")/receipt"
  if [ ! -f "$file" ]; then
    class=$(task_state_get "$id" class)
    if [ "$class" = T4 ]; then
      printf 'receipt: none (required for T4)\n'
      return 1
    fi
    printf 'receipt: none\n'
    return 0
  fi

  changed=$(_task_receipt_changed "$id")
  if [ -z "$changed" ]; then
    printf 'receipt: current\n'
    return 0
  fi
  printf 'receipt: stale (%s, reviewed %s)\n' "$changed" "$(_task_receipt_get "$id" reviewed_at)"
  return 1
}

# --- the human gate (adr-20260924-the-status-page-keeps-the-readers-place)
#
# A T3/T4 design is approved by a human in conversation, and the jig-task
# skill writes the decision into task.md in prose (ADR-0031). `jig task gate`
# records the same decision as data: `gate: approved` and `gate_design`, the
# hash of the documents approved (_task_receipt_design_hash, the same value a
# review receipt pins). It is a claim, like every record here (ADR-0020): the
# script cannot tell who approved. What it adds is that a design changed after
# its approval becomes visible without anyone rereading task.md.

# task_gate <id> approved [--by human|agent] — record the approval of the
# design as it is now, and who gave it (`gate_by`, human by default). Refused
# for a class without a gate and for a task with no design.md, since there is
# nothing to pin. `--by agent` is the self-approval of an unattended run
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci), and is
# refused anywhere else: outside such a run the gate is a human's.
task_gate() {
  jig_require_init
  [ $# -eq 2 ] || [ $# -eq 4 ] || jig_die "$(_task_usage gate)"
  local id="$1" decision="$2" by=human dir class design
  if [ $# -eq 4 ]; then
    [ "$3" = --by ] || jig_die "task gate: unknown argument: $3"
    case "$4" in
      human | agent) by="$4" ;;
      *) jig_die "task gate: invalid --by: $4 (expected human|agent)" ;;
    esac
  fi
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task gate: unknown task: $id"
  [ "$decision" = approved ] || jig_die "task gate: unknown decision: $decision (expected approved)"
  if [ "$by" = agent ]; then
    if [ "$(task_state_get "$id" autopilot)" != on ] || [ "$(_task_autopilot_mode "$id")" != unattended ]; then
      jig_die "task gate: --by agent is an unattended run's self-approval; $id has no unattended autopilot run on, so the gate is the human's"
    fi
  fi
  class=$(task_state_get "$id" class)
  case "$class" in
    T3 | T4) ;;
    *) jig_die "task gate: $id is ${class:-unclassified}; only T3 and T4 tasks have a human gate" ;;
  esac
  design=$(_task_receipt_design_hash "$id")
  [ "$design" != "-" ] || jig_die "task gate: $id has no design.md to approve"
  _task_rewrite_state "$dir" gate approved
  _task_rewrite_state "$dir" gate_design "$design"
  _task_rewrite_state "$dir" gate_by "$by"
  if [ "$by" = agent ]; then
    printf 'gate: approved by the agent\n'
  else
    printf 'gate: approved\n'
  fi
}

# _task_gate_state <id> — where a T3/T4 task stands at its human gate:
# `waiting` (a design.md exists and no approval is recorded), `changed` (the
# design moved after the approval), `approved`; nothing for a task without a
# gate or without a design yet. The status page's "needs you" reads it.
_task_gate_state() {
  local id="$1" design
  case "$(task_state_get "$id" class)" in
    T3 | T4) ;;
    *) return 0 ;;
  esac
  design=$(_task_receipt_design_hash "$id")
  [ "$design" != "-" ] || return 0
  if [ "$(task_state_get "$id" gate)" != approved ]; then
    printf 'waiting\n'
  elif [ "$(task_state_get "$id" gate_design)" != "$design" ]; then
    printf 'changed\n'
  else
    printf 'approved\n'
  fi
}

# --- pause / resume ---------------------------------------------------------------

# Pause is a field, not a status (design §3): it is orthogonal to `status`
# and must return the task to wherever `status` left it. --stash is opt-in
# and never the default (an unwanted default that loses work cannot be
# undone; the reverse costs one flag) and records the stash's SHA, not its
# index, because `stash@{0}` shifts as other entries are pushed.
task_pause() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage pause)"
  local id="$1"
  shift
  local reason="" stash=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) [ $# -ge 2 ] || jig_die "task pause: --reason requires a value"; reason="$2"; shift 2 ;;
      --stash) stash=1; shift ;;
      *) jig_die "task pause: unknown argument: $1" ;;
    esac
  done

  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task pause: unknown task: $id"
  [ "$(task_state_get "$id" paused)" != "true" ] || jig_die "task pause: already paused: $id"

  # paused_reason is one flat `key: value` line (schemas/state.md); an
  # embedded newline would corrupt the state file, so it is refused up front
  # rather than silently truncated or split across lines. $'\n', not
  # $(printf '\n'): command substitution strips trailing newlines, which
  # would leave nl empty and turn the pattern below into a bare `*`.
  local nl=$'\n'
  case "$reason" in
    *"$nl"*) jig_die "task pause: --reason must be a single line" ;;
  esac

  local stash_sha=""
  if [ "$stash" -eq 1 ]; then
    # --stash sets aside *this checkout's* changes and records them as the
    # task's. When the task's branch is checked out somewhere else — its own
    # worktree, most often (ADR-0029) — those changes are not the task's, and
    # its real work would stay where it is while the record said otherwise.
    local state_branch
    state_branch=$(task_state_get "$id" branch)
    if [ -n "$state_branch" ] && [ "$state_branch" != "$(_task_current_branch)" ]; then
      jig_die "task pause: --stash stashes this checkout, but $id is on $state_branch; run it where $state_branch is checked out"
    fi
    local changed count
    changed=$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null)
    count=$(_task_count_lines "$changed")
    if [ "$count" -gt 0 ]; then
      git -C "$JIG_PROJECT" stash push -u -m "jig: $id" >/dev/null \
        || jig_die "task pause: git stash push failed"
      stash_sha=$(git -C "$JIG_PROJECT" rev-parse "stash@{0}")
      printf 'stashed %s file(s): %s\n' "$count" "$stash_sha"
    else
      printf 'working tree is clean; nothing to stash\n'
    fi
  fi

  _task_rewrite_state "$dir" paused true
  _task_rewrite_state "$dir" paused_at "$(jig_today)"
  [ -z "$reason" ] || _task_rewrite_state "$dir" paused_reason "$reason"
  [ -z "$stash_sha" ] || _task_rewrite_state "$dir" paused_stash "$stash_sha"

  printf 'paused %s\n' "$id"
}

# resume refuses when the task is not paused and when the current branch
# differs from the state's `branch` (design §4). A failed stash apply clears
# nothing and exits non-zero: a conflicted restore must not silently look
# like a successful resume. `apply`, never `pop` — the stash entry survives
# as a backup, which is why `paused_stash` itself is not cleared here.
task_resume() {
  jig_require_init
  [ $# -eq 1 ] || jig_die "$(_task_usage resume)"
  local id="$1" dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task resume: unknown task: $id"
  [ "$(task_state_get "$id" paused)" = "true" ] || jig_die "task resume: not paused: $id"

  # A task that was filed and paused before it was ever started has no branch
  # to switch to; the check applies only once `task start` gave it one.
  local state_branch cur_branch
  state_branch=$(task_state_get "$id" branch)
  if [ -n "$state_branch" ]; then
    cur_branch=$(_task_current_branch)
    [ "$cur_branch" = "$state_branch" ] || jig_die "task resume: switch to $state_branch first"
  fi

  local sha stash_line=""
  sha=$(task_state_get "$id" paused_stash)
  if [ -n "$sha" ]; then
    if git -C "$JIG_PROJECT" stash apply "$sha" >/dev/null 2>&1; then
      stash_line="stash: applied $sha (kept; drop with git stash drop $sha)"
    else
      jig_die "task resume: git stash apply failed for $sha (conflicts); resolve them, then run \`jig task resume $id\` again"
    fi
  fi

  local days
  days=$(_task_days_since "$(task_state_get "$id" paused_at)")

  _task_rewrite_state_remove "$dir" paused
  _task_rewrite_state_remove "$dir" paused_at
  _task_rewrite_state_remove "$dir" paused_reason

  printf 'resumed %s (paused %s days)\n' "$id" "$days"

  local uncommitted n
  uncommitted=$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null)
  n=$(_task_count_lines "$uncommitted")
  [ "$n" -eq 0 ] || printf 'uncommitted: %s files\n' "$n"

  [ -z "$stash_line" ] || printf '%s\n' "$stash_line"

  local overlap k base
  overlap=$(_task_resume_overlap "$id")
  k=$(_task_count_lines "$overlap")
  if [ "$k" -gt 0 ]; then
    base=$(jig_task_base "$id")
    printf 'overlap: %s files you changed also changed on %s\n' "$k" "$base"
    printf '%s\n' "$overlap" | sed 's/^/  /'
  fi
}

# Live work: unfinished, whether or not it is dormant. A paused task is still
# live — it is listed, with its marker. `consolidated` and `abandoned` are done
# and pile up on a long-lived branch, so they are hidden unless asked for. Same
# convention as `jig context`, which hides superseded and deprecated documents
# behind --all.
_task_is_live() {
  case "$1" in
    active | ready) return 0 ;;
    *) return 1 ;;
  esac
}

task_list() {
  jig_require_init
  local show_all=0 want_status=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) show_all=1; shift ;;
      --status)
        [ $# -ge 2 ] || jig_die "task list: --status requires a value"
        _task_valid_status "$2" || jig_die "task list: invalid status: $2"
        want_status="$2"
        shift 2
        ;;
      *) jig_die "task list: unknown argument: $1" ;;
    esac
  done

  local base="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  local dir id class status branch base_branch default_base paused line lines="" hidden=0 worktrees wt
  worktrees=$(_task_worktrees)
  # The base is shown only where it is not the project's: a listing where
  # every line says base=main says nothing.
  default_base=$(cfg git.base_branch main)
  for dir in "$base"/*/; do
    [ -f "${dir}state" ] || continue
    id=$(basename "$dir")
    # Same rule as _task_candidates_for_branch: skip, never die on, a
    # directory whose name is not a task id.
    _task_valid_id "$id" || continue
    class=$(task_state_get "$id" class)
    status=$(task_state_get "$id" status)
    branch=$(task_state_get "$id" branch)
    paused=$(task_state_get "$id" paused)
    if [ -n "$want_status" ]; then
      [ "$status" = "$want_status" ] || continue
    elif [ "$show_all" -eq 0 ] && ! _task_is_live "$status"; then
      hidden=$((hidden + 1))
      continue
    fi
    [ -n "$class" ] || class="-"
    # A task with no branch has not been started. Saying so is the whole
    # point of representing "not started" as an absence: without a marker the
    # listing shows it as indistinguishable from work in progress.
    if [ -n "$branch" ]; then
      line="$id class=$class status=$status branch=$branch"
      wt=$(_task_worktree_for "$branch" "$worktrees")
      [ -z "$wt" ] || line="$line $(_task_worktree_note "$wt")"
    else
      line="$id class=$class status=$status not-started"
    fi
    base_branch=$(task_state_get "$id" base_branch)
    if [ -n "$base_branch" ] && [ "$base_branch" != "$default_base" ]; then
      line="$line base=$base_branch"
    fi
    [ "$paused" = "true" ] && line="$line paused"
    lines="$lines
$line"
  done
  lines=$(printf '%s\n' "$lines" | sed '/^$/d')
  if [ -z "$lines" ]; then
    if [ "$hidden" -gt 0 ]; then
      printf 'no live tasks (%d finished; jig task list --all)\n' "$hidden"
    else
      printf 'no tasks\n'
    fi
    return 0
  fi
  printf '%s\n' "$lines" | sort
  [ "$hidden" -gt 0 ] && printf '(%d finished; jig task list --all)\n' "$hidden"
  return 0
}

task_show() {
  jig_require_init
  [ $# -eq 1 ] || jig_die "$(_task_usage show)"
  local file
  file="$(task_dir "$1")/state"
  [ -f "$file" ] || jig_die "task show: unknown task: $1"
  cat "$file"
}

# The task for this checkout's current branch (design §2). Deterministic,
# never a ranking: exactly one candidate (design §1: branch matches, status
# `active` or `ready`, not paused) prints its id on stdout and exits 0; zero
# candidates is a normal, silent outcome (exit 1, a warning on stderr) so
# `jig context` can treat "no current task" as ordinary rather than fatal;
# several candidates is refused outright (exit 2, one line per candidate on
# stderr, nothing on stdout) rather than picked by any tie-break — silently
# guessing wrong here is exactly the bug this replaced.
task_current() {
  jig_require_init
  local branch candidates count
  branch=$(_task_current_branch)
  candidates=$(_task_candidates_for_branch "$branch")
  count=$(_task_count_lines "$candidates")

  if [ "$count" -eq 0 ]; then
    jig_warn "no current task for branch: $branch"
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$candidates"
    return 0
  fi

  local cid cst cupd
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    cst=$(task_state_get "$cid" status)
    cupd=$(task_state_get "$cid" updated_at)
    printf '%s  %s  updated_at=%s\n' "$cid" "$cst" "$cupd" >&2
  done < <(printf '%s\n' "$candidates")
  return 2
}

# Read-only review inventory; the task ID establishes context, not hunk ownership.
task_changes() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage changes)"
  local id="$1" base="" head format=report files="" has_files=0 row path layer rows selected="" candidates kept t
  shift
  [ -f "$(task_dir "$id")/state" ] || jig_die "task changes: unknown task: $id"
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || jig_die "task changes: --base requires a value"; base="$2"; shift 2 ;;
      --files)
        [ $# -ge 2 ] || jig_die "task changes: --files requires a value"
        [ "$has_files" -eq 0 ] || jig_die "task changes: duplicate --files"
        has_files=1
        if [ "$2" = - ]; then files=$(cat); else
          case "$2" in *'
'*) jig_die "task changes: use stdin for a multiline scope" ;; esac
          files=$(printf '%s' "$2" | tr ',' '\n')
        fi
        shift 2 ;;
      --format) [ $# -ge 2 ] || jig_die "task changes: --format requires a value"; format="$2"; shift 2 ;;
      *) jig_die "task changes: unknown argument: $1" ;;
    esac
  done
  case "$format" in report | paths) ;; *) jig_die "task changes: invalid format: $format" ;; esac
  [ -n "$base" ] || jig_die "task changes: --base is required; establish the task baseline first"
  base=$(jig_review_commit "$base") || return 1
  head=$(jig_review_commit HEAD) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    jig_check_review_path "$path"
  done < <(printf '%s\n' "$files")
  rows=$(jig_git_change_rows "$base" "$head") || return 1
  t=$(printf '\t')
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    path=${row%%"$t"*}
    if [ "$has_files" -eq 1 ] && ! jig_has_line "$path" "$files"; then continue; fi
    selected="$selected$row
"
  done < <(printf '%s\n' "$rows")
  if [ "$format" = paths ]; then
    printf '%s' "$selected" | cut -f1 | LC_ALL=C sort -u
  else
    candidates=$(printf '%s\n' "$rows" | sed '/^$/d' | cut -f1 | sort -u | wc -l | tr -d ' ')
    kept=$(printf '%s' "$selected" | cut -f1 | sort -u | wc -l | tr -d ' ')
    printf 'task: %s\nbase: %s\nhead: %s\nselected: %s paths; excluded: %s candidate paths\n' "$id" "$base" "$head" "$kept" "$((candidates - kept))"
    while IFS="$t" read -r path layer; do
      [ -n "$path" ] || continue
      printf '%-10s %s\n' "$layer" "$path"
    done < <(printf '%s' "$selected")
    printf 'inventory only; task ownership and review remain unassessed\n'
  fi
}

# _task_workspace_root <id> <command> — the physical directory holding this
# task's artifacts and `state`, with the one path check every command that
# reads or writes an artifact must pass (RULES.md: the check lives at a single
# function, not once per caller).
#
# A linked task directory can point outside the validated checkout workspace,
# and only one of the two shapes is checked here. A symlink at the task's own
# path goes through `_task_borrowed_workspace`, which confirms the target is
# this task's workspace in another worktree of this repository. A link at the
# parent -- the whole `tasks/` directory, which `task start --worktree` now
# makes the usual shape -- does not reach that check: `-L` asks about the last
# component only, so this falls to the comparison below, where both sides
# resolve through the same link and it cannot fail. That gap is older than the
# borrowed directory (the body of this function is unchanged by the change
# that introduced it) and belongs to task
# `artifact-write-trusts-a-borrowed-directory-link`; it is not a property to
# rely on. <command> names the caller in the refusals, so the message still
# says which verb refused.
_task_workspace_root() {
  local id="$1" cmd="$2" root tasks_root
  root=$(task_dir "$id") || return 1
  [ -f "$root/state" ] || jig_die "$cmd: unknown task: $id"
  if [ -L "$root" ]; then
    _task_borrowed_workspace "$id" \
      || jig_die "$cmd: linked task workspace is unsupported unless it is this task's workspace in another worktree"
    return 0
  fi
  root=$(cd -P "$root" && pwd -P) || jig_die "$cmd: cannot inspect workspace"
  tasks_root=$(cd -P "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks" && pwd -P) || return 1
  case "$root" in "$tasks_root"/"$id") ;; *) jig_die "$cmd: workspace outside task root" ;; esac
  printf '%s\n' "$root"
}

_task_artifact_kind() {
  case "$1" in discovery | spec | alternatives | design | plan | review | verification | handoff) return 0 ;; *) return 1 ;; esac
}

# Resolve links without readlink -f. Do not read an artifact outside the workspace.
_task_artifact_fact() {
  local root="$1" kind="$2" provided="$3" path target parent hops=0
  if jig_has_line "$kind" "$provided"; then
    printf 'provided-claim (caller must substantiate)\n'; return 0
  fi
  path="$root/$kind.md"
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then printf 'unavailable (symlink loop)\n'; return 0; fi
    target=$(readlink "$path") || { printf 'unavailable (unreadable link)\n'; return 0; }
    case "$target" in /*) path="$target" ;; *) path="$(dirname "$path")/$target" ;; esac
  done
  parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P) || { printf 'unavailable (missing parent)\n'; return 0; }
  path="$parent/$(basename "$path")"
  case "$path" in "$root"/*) ;; *) printf 'unavailable (outside workspace)\n'; return 0 ;; esac
  if [ ! -f "$path" ]; then printf 'unavailable (missing or not a regular file)\n'
  elif [ ! -r "$path" ]; then printf 'unavailable (unreadable)\n'
  elif [ ! -s "$path" ]; then printf 'unavailable (empty)\n'
  else printf 'present\n'; fi
}

# stage|documentary inputs|unassessed semantic prerequisites. This is not a router.
_task_artifact_route() {
  case "$1" in
    T0) printf '%s\n' 'implement|task|task intent' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T1) printf '%s\n' 'analyze|task|task intent' 'implement|task discovery|analysis sufficiency' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T2) printf '%s\n' 'analyze|task|task intent' 'plan|task discovery|analysis sufficiency' 'implement|task plan|plan sufficiency' 'review|task plan|implementation' 'verify|task plan|implementation and review outcome' 'consolidate|task plan|implementation, review and verification outcomes' ;;
    T3) printf '%s\n' 'discover|task|task intent' 'design|task discovery|discovery sufficiency' 'human-gate|task design|human design decision' 'implement|task design|human design approval' 'architecture-review|task design|implementation' 'verify|task design|implementation and architecture review outcome' 'consolidate|task verification|implementation, review and verification outcomes' ;;
    T4) printf '%s\n' 'discover|task|task intent' 'specify|task discovery|discovery sufficiency' 'alternatives|task spec|specification sufficiency' 'design|task spec alternatives|alternatives evaluated' 'human-gate|task spec design|human design decision' 'implement|task spec design|human design approval' 'review|task spec design|implementation and independent reviewer' 'verify|task spec design|implementation and independent review outcome' 'consolidate|task verification|implementation, review and verification outcomes' ;;
  esac
}

task_artifacts() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage artifacts)"
  local id="$1" root class provided="" seen=0 kinds kind fact stage inputs semantic availability facts="" t
  shift
  root=$(_task_workspace_root "$id" "task artifacts") || return 1
  class=$(task_state_get "$id" class)
  _task_valid_class "$class" || jig_die "task artifacts: invalid or missing class: $class"
  while [ $# -gt 0 ]; do
    case "$1" in
      --provided)
        [ $# -ge 2 ] || jig_die "task artifacts: --provided requires a value"
        [ "$seen" -eq 0 ] || jig_die "task artifacts: duplicate --provided"
        seen=1
        case "$2" in '' | ,* | *, | *,,* | *[!a-z,]*) jig_die "task artifacts: malformed --provided: $2" ;; esac
        provided=$(printf '%s' "$2" | tr ',' '\n')
        kinds=""
        while IFS= read -r kind; do
          _task_artifact_kind "$kind" || jig_die "task artifacts: unknown provided kind: $kind"
          case " $kinds " in *" $kind "*) jig_die "task artifacts: duplicate provided kind: $kind" ;; esac
          kinds="$kinds $kind"
        done < <(printf '%s\n' "$provided")
        shift 2 ;;
      *) jig_die "task artifacts: unknown argument: $1" ;;
    esac
  done
  t=$(printf '\t')
  printf 'task: %s; class: %s\nartifacts (optional unless consumed by a route stage):\n' "$id" "$class"
  for kind in task discovery spec alternatives design plan review verification handoff; do
    fact=$(_task_artifact_fact "$root" "$kind" "$provided")
    facts="$facts$kind$t$fact
"
    printf '  %-14s %s\n' "$kind" "$fact"
  done
  while IFS='|' read -r stage inputs semantic; do
    availability="inputs-available"
    for kind in $inputs; do
      fact=$(printf '%s' "$facts" | awk -F "$t" -v k="$kind" '$1 == k {print $2}')
      case "$fact" in unavailable*) availability="needs-input" ;; esac
    done
    printf '%s: %s; inputs: %s\n  unassessed: %s\n' "$stage" "$availability" "$inputs" "$semantic"
  done < <(_task_artifact_route "$class")
  printf 'Presence and provided claims do not prove approval, quality or completion; state unchanged.\n'
}

# --- artifact writes (ADR-0029: a worktree never writes through the link) ----

# The kinds `task artifact` will write. One wider than _task_artifact_kind
# above, which serves `--provided` and has no use for `task`: `task.md` is
# where jig-analyze puts its analysis and where an unattended run records the
# gate it approved, so it is the most edited document of all. The two
# predicates stay separate on purpose — widening the `--provided` vocabulary
# would let a caller claim an input that is never an input.
_task_artifact_writable_kind() {
  case "$1" in task | discovery | spec | alternatives | design | plan | review | verification | handoff) return 0 ;; *) return 1 ;; esac
}

# task_artifact write|append <id> <kind> [--from <file>|-]
#
# Writes one of a task's artifacts, so that nothing but jig needs to know
# where a task's workspace physically is. That is the point of the verb: in a
# task worktree the workspace is reached through a link (ADR-0029), an agent's
# editing tools refuse a path that resolves outside their sandbox, and the
# workaround — writing the link with plain shell — is a rule against the
# tool's own default, which is the class of rule agents break.
#
# Four things a shell redirection does not do:
#   1. resolves the workspace through _task_workspace_root, accepting exactly
#      the borrowed link and no other;
#   2. writes atomically (tmp + mv), so an interrupted write leaves the old
#      document whole rather than half a new one;
#   3. takes a closed vocabulary of kinds, so a misspelt name cannot become a
#      file `task artifacts` will never look at;
#   4. refreshes `updated_at` and redraws the status page, so a rewritten plan
#      does not leave the task looking untouched from outside.
#
# Content comes from the caller: `--from <file>`, or stdin with `--from -` or
# with no --from at all. In a worktree that file is inside the worktree, which
# is inside the sandbox, so the agent writes it with its ordinary tools and
# hands jig the path.
#
# No {{TASK_ID}} substitution happens here, unlike `task new --from`: that one
# seeds a template, this one stores a document its author already finished,
# where a `{{TASK_ID}}` is text and not a placeholder. The duplication between
# the two is one `mv`, and deliberate.
task_artifact() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage artifact)"
  local mode="$1"
  shift
  case "$mode" in
    write | append) ;;
    *) jig_die "$(_task_usage artifact)" ;;
  esac
  [ $# -ge 2 ] || jig_die "$(_task_usage artifact)"
  local id="$1" kind="$2" from="" seen=0
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ $# -ge 2 ] || jig_die "task artifact: --from requires a value"
        [ "$seen" -eq 0 ] || jig_die "task artifact: duplicate --from"
        seen=1
        from="$2"
        shift 2 ;;
      *) jig_die "task artifact: unknown argument: $1" ;;
    esac
  done
  _task_artifact_writable_kind "$kind" \
    || jig_die "task artifact: unknown kind: $kind (one of: task discovery spec alternatives design plan review verification handoff)"

  # Validated before the workspace is touched, so an unreadable source never
  # gets as far as the temporary file (task_new --from does the same).
  if [ -n "$from" ] && [ "$from" != "-" ]; then
    [ -e "$from" ] || jig_die "task artifact: --from: no such file: $from"
    [ -f "$from" ] || jig_die "task artifact: --from: not a regular file: $from"
    [ -r "$from" ] || jig_die "task artifact: --from: file not readable: $from"
  fi

  local root dest tmp
  root=$(_task_workspace_root "$id" "task artifact") || return 1
  dest="$root/$kind.md"
  tmp="$dest.tmp.$$"
  # A link is refused rather than resolved. `mv` would replace it and `append`
  # would read through it, out of the workspace and back in — and
  # `task artifacts` already treats an artifact that leaves the workspace as
  # unavailable. Whoever put the link there gets to say what happens to it.
  if [ -L "$dest" ]; then
    jig_die "task artifact: $kind.md is a link; remove it first if this document should live in the workspace"
  fi

  # The new content is captured first, whole, and only then is anything in the
  # workspace touched. An empty capture is refused rather than written: a
  # `write` fed the output of a command that failed would otherwise blank the
  # document, and blanking a plan is the one destructive act this verb can
  # perform. `task artifacts` would report the result as `unavailable
  # (empty)` — true, and too late.
  if [ -z "$from" ] || [ "$from" = "-" ]; then
    cat > "$tmp"
  else
    cat "$from" > "$tmp"
  fi
  if [ ! -s "$tmp" ]; then
    # The one path this command removes: the temporary file it created itself,
    # this run, inside the workspace directory _task_workspace_root validated
    # (RULES.md wants the path validated to be inside `.ai/` and shaped like a
    # workspace entry before a script deletes it; this one is both).
    rm -f "$tmp"
    jig_die "task artifact: refusing to write an empty $kind: nothing on the input"
  fi

  if [ "$mode" = "append" ] && [ -s "$dest" ]; then
    local joined="$dest.join.$$"
    # A document that does not end in a newline would otherwise run into the
    # one appended after it, silently joining a heading to the line above.
    {
      cat "$dest"
      if [ -n "$(tail -c 1 "$dest")" ]; then printf '\n'; fi
      cat "$tmp"
    } > "$joined"
    mv "$joined" "$tmp"
  fi

  mv "$tmp" "$dest"
  _task_touch_state "$root"
  # An absolute path when the workspace is borrowed: it is in another
  # worktree, and a relative one would be read against the wrong root
  # (ADR-0029: paths in reports are absolute).
  jig_relpath "$dest" "$JIG_PROJECT"
}

# --- ship (agent git rights: design.md, .ai/specs/autopilot/) ----------------
#
# The git steps themselves are shared with `jig spec ship` (jig_ship_*,
# common.sh); the task's own gates stay here.

# task_ship <id> --message-file <file> [--title <t>] [--body-file <file>] [--draft]
#
# Carries a task's own change as far as `agent.git` (config.sh) allows:
# commit, push, open a pull request, and at `merge` merge it once its checks
# passed (jig_ship_merge, common.sh;
# adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci). `--draft`
# opens the pull request as a draft, which is never merged: an unattended run
# whose repairs ran out ends in one. Every step it is not allowed to take, and
# a merge that did not happen, ends in a plain status line, not an error:
# "none" is the one outcome a caller must tell apart from every other exit,
# which is why it alone is exit 3.
# _task_ship_unverified_notice — say, at the moment the change leaves the
# machine, that nothing verifies this project.
#
# The person hears it here rather than only in a `jig verify` ten minutes
# earlier, because here is where it has consequences. It is deliberately not a
# refusal: when no profile covers the project there is nothing to install and
# nothing to wait for, so refusing would stop work over a state nobody can
# resolve. A stack profile whose tools are missing is the other case entirely
# — there `jig verify` refuses, because something could have been checked and
# was not (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).
#
# Nothing here may fail the ship: every path that cannot answer gives up.
_task_ship_unverified_notice() {
  local installed p pdir covered=0
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh" 2>/dev/null || return 0
  installed=$(profiles_installed_dir 2>/dev/null) || return 0
  [ -n "$installed" ] || return 0
  for p in $(profiles_active 2>/dev/null); do
    pdir=$(profiles_dir "$installed" "$p" 2>/dev/null) || continue
    [ -d "$pdir" ] || continue
    if ! profiles_is_fallback "$pdir"; then
      covered=1
      break
    fi
  done
  [ "$covered" = 0 ] || return 0
  printf 'task ship: no profile covers this project, so nothing verifies it; this ships unverified\n'
  return 0
}

task_ship() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage ship)"
  local id="$1"
  shift
  local message_file="" title="" body_file="" has_message=0 draft=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft)
        draft=1
        shift ;;
      --message-file)
        [ $# -ge 2 ] || jig_die "task ship: --message-file requires a value"
        has_message=1
        message_file="$2"
        shift 2 ;;
      --title)
        [ $# -ge 2 ] || jig_die "task ship: --title requires a value"
        title="$2"
        shift 2 ;;
      --body-file)
        [ $# -ge 2 ] || jig_die "task ship: --body-file requires a value"
        body_file="$2"
        shift 2 ;;
      *) jig_die "task ship: unknown argument: $1" ;;
    esac
  done
  [ "$has_message" -eq 1 ] || jig_die "task ship: --message-file is required"
  [ -f "$message_file" ] || jig_die "task ship: --message-file: no such file: $message_file"
  [ -z "$body_file" ] || [ -f "$body_file" ] || jig_die "task ship: --body-file: no such file: $body_file"

  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task ship: unknown task: $id"

  # Level first, before anything else changes: an invalid value must refuse
  # exactly like every other check here, not read as "none" by accident.
  local level
  level=$(jig_agent_git) || jig_die "task ship: invalid agent.git: $level (expected none|commit|push|pr|merge)"

  if [ "$level" = none ]; then
    # To stderr and exit 3, not `jig_die` (exit 1): a skill reads 3 as "hand
    # this over to the human", not as a command that failed.
    printf 'task ship: agent.git is none in this clone; the human commits\n' >&2
    exit 3
  fi

  # A draft completes nothing and is never merged (below, and jig_ship_merge
  # refuses one on its own): it is how an unattended run whose repairs ran out
  # shows where it stopped — usually with the blocking finding still open —
  # so the three completion gates are not asked for one. Everything else here
  # still is.
  local blocking="" receipt_msg=""
  if [ "$draft" -eq 0 ]; then
    [ "$(task_state_get "$id" knowledge_consolidated)" = "true" ] \
      || jig_die "task ship: requires knowledge_consolidated true; record the knowledge decision first: jig task set $id knowledge_consolidated true"

    # Checked again, independently of knowledge_consolidated above (design §4):
    # a fix landed after consolidation can plant a new finding, and ADR-0030's
    # order check alone would not see it.
    blocking=$(_task_blocking_findings "$id")
    [ -z "$blocking" ] || jig_die "task ship: $(_task_gate_blocking_message "$id" "$blocking")"

    # Same independent recheck as the findings ledger above, for the same
    # reason: a receipt gone stale after knowledge_consolidated was set true —
    # a later code edit, or a re-review nobody ran — must still refuse here.
    receipt_msg=$(_task_receipt_gate_message "$id")
    [ -z "$receipt_msg" ] || jig_die "task ship: $receipt_msg"
  fi

  local branch base cur
  branch=$(task_state_get "$id" branch)
  base=$(jig_task_base "$id")
  cur=$(_task_current_branch)
  [ -n "$branch" ] || jig_die "task ship: $id has not been started (no branch); run \`jig task start $id\` first"
  [ "$cur" = "$branch" ] || jig_die "task ship: current branch is $cur, but $id is on $branch; switch branches first"
  [ "$branch" != "$base" ] || jig_die "task ship: $id's branch is its own base ($base); nothing task-specific to ship"

  _task_ship_unverified_notice

  jig_ship_check_staged "task ship"
  jig_ship_commit "task ship" "$message_file"

  # Before the first step that leaves this machine (common.sh, "what a ship
  # may send out"). Asked here rather than just before the push: "this branch
  # carries no work" is the same answer at every level, and at `commit` the
  # human is the one who pushes next — telling them now is what stops the
  # empty branch one step later.
  jig_ship_require_commits "task ship" "$branch" "$base"

  if [ "$level" = commit ]; then
    printf "stopped at commit: push is the human's\n"
    return 0
  fi

  jig_ship_push "task ship" "$branch"

  if [ "$level" = push ]; then
    printf "stopped at push: the pull request is the human's\n"
    return 0
  fi

  jig_ship_pr "task ship" "$branch" "$base" "$message_file" "$title" "$body_file" "$draft"
  # The pull request's address, kept so the status page can link it the
  # moment it exists. A fact about what ship did, not a merge state: whether
  # it was merged is still derived by housekeeping every run (ADR-0005).
  case "$JIG_SHIP_URL" in
    https://*) _task_rewrite_state "$dir" pr_url "$JIG_SHIP_URL" ;;
  esac

  [ "$level" = merge ] || return 0
  if [ "$draft" -eq 1 ]; then
    printf 'not merged: a draft pull request is never merged\n'
    return 0
  fi
  # The task's own gates once more, right before the merge: the merge is the
  # last moment either can still stop the change.
  blocking=$(_task_blocking_findings "$id")
  if [ -n "$blocking" ]; then
    printf 'not merged: %s blocking finding(s) in the ledger\n' "$(_task_count_lines "$blocking")"
    return 0
  fi
  receipt_msg=$(_task_receipt_gate_message "$id")
  if [ -n "$receipt_msg" ]; then
    printf 'not merged: %s\n' "$receipt_msg"
    return 0
  fi
  jig_ship_merge "task ship" "$JIG_SHIP_URL" "$(git -C "$JIG_PROJECT" rev-parse HEAD)" any
}

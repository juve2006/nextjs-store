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
  _TASK_VERB="task $sub"
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
    route) task_route "$@" ;;
    *) jig_die "$(_task_usage)" ;;
  esac
  # One redraw of the status page for however many writes the command made
  # (jig_record_changed, common.sh). A command that stops early redraws on
  # its own way out: jig_die flushes, and so does the one `return 3` below.
  jig_status_page_flush
}

# _task_usage [sub] — the usage line of <sub>, or of `jig task` as a whole
# when <sub> is empty; non-zero, printing nothing, for an unknown <sub>. The
# one source for both `--help` and the usage errors the subcommands die with.
_task_usage() {
  case "${1:-}" in
    '') printf 'usage: jig task new|start|bootstrap|set|abandon|pause|resume|list|show|current|changes|artifacts|artifact|finding|findings|receipt|ship|autopilot|gate|route ...\n' ;;
    new) printf 'usage: jig task new <id> [--class T0..T4] [--domains a,b] [--from <file>] [--lean]\n' ;;
    start) printf 'usage: jig task start <id> [--worktree] [--no-bootstrap]\n' ;;
    bootstrap) printf 'usage: jig task bootstrap <id>\n' ;;
    set)
      printf 'usage: jig task set <id> <key> <value>\n'
      printf '       jig task set <id> class <Tn> --reason <text>   (a lower class than the current one)\n'
      ;;
    abandon) printf 'usage: jig task abandon <id>\n' ;;
    pause) printf 'usage: jig task pause <id> [--reason <text>] [--stash]\n' ;;
    resume) printf 'usage: jig task resume <id>\n' ;;
    list) printf 'usage: jig task list [--all] [--status <status>] [--goals] [--json]\n' ;;
    show) printf 'usage: jig task show <id>\n' ;;
    current) printf 'usage: jig task current\n' ;;
    changes) printf 'usage: jig task changes <id> --base <ref> [--files <list>|-] [--format report|paths]\n' ;;
    artifacts) printf 'usage: jig task artifacts <id> [--provided discovery,design,...]\n' ;;
    artifact)
      printf 'usage: jig task artifact write <id> <kind> [--from <file>|-]\n'
      printf '       jig task artifact append <id> <kind> [--from <file>|-]\n'
      printf '       <kind>: task discovery spec alternatives design plan review verification handoff knowledge-map commit-message pr-body\n'
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
      printf '       jig task autopilot <id> resume --answer <the human'"'"'s answer>\n'
      printf '       jig task autopilot <id> end [--reason <how it ended>]\n'
      printf '       jig task autopilot <id> report\n'
      ;;
    gate) printf 'usage: jig task gate <id> approved [--by human|agent]\n' ;;
    route) printf 'usage: jig task route <id>\n' ;;
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

# --- tracker issue (adr-20261010-a-task-carries-its-tracker-issue) -------------
#
# A project whose tasks live in a tracker names a task after its issue
# (`SRD-2455-fix-login`, `123-fix-login`). Jig reads the issue from the id, and
# only by the project's own `task.issue_pattern`: with no pattern nothing is
# read, so `release-0-25-1` can never turn into an issue `release-0`. There is
# no flag to give one by hand — the id is the one place it is written.

# _task_issue_pattern — task.issue_pattern with one pair of surrounding quotes
# removed, or nothing when the project sets none.
_task_issue_pattern() {
  local pattern
  pattern=$(cfg task.issue_pattern "")
  case "$pattern" in
    \'*\') pattern=${pattern#\'}; pattern=${pattern%\'} ;;
    \"*\") pattern=${pattern#\"}; pattern=${pattern%\"} ;;
  esac
  printf '%s\n' "$pattern"
}

# _task_issue_from_id <id> — the tracker issue at the start of <id>, or
# nothing. The pattern is anchored at the first character, takes awk's longest
# match, and counts only when that match ends at the end of the id or before a
# `-`, `_` or `.`: `SRD-2455x-y` names no issue, `SRD-2455-y` names SRD-2455.
# Exit 2, printing nothing, when awk cannot read the pattern.
_task_issue_from_id() {
  local pattern
  pattern=$(_task_issue_pattern)
  [ -n "$pattern" ] || return 0
  JIG_I_ID="$1" JIG_I_PAT="$pattern" awk 'BEGIN {
    id = ENVIRON["JIG_I_ID"]
    if (!match(id, "^(" ENVIRON["JIG_I_PAT"] ")") || RLENGTH < 1) exit 0
    after = substr(id, RLENGTH + 1, 1)
    if (after == "" || after == "-" || after == "_" || after == ".") print substr(id, 1, RLENGTH)
  }' 2>/dev/null || return 2
}

# _task_issue_ref <issue> — how a commit and a pull request title name the
# issue: as it is (`SRD-2455`), or `#123` for an issue of digits only, the form
# GitHub, GitLab and Redmine link.
_task_issue_ref() {
  case "$1" in
    *[!0-9]*) printf '%s\n' "$1" ;;
    *) printf '#%s\n' "$1" ;;
  esac
}

# _task_issue_in_line <line> <ref> — exit 0 when <ref> is a word of <line>:
# no letter, digit or `_` right before or after it. `SRD-24550` does not hold
# SRD-2455, and `#1234` does not hold #123.
_task_issue_in_line() {
  JIG_I_LINE="$1" JIG_I_REF="$2" awk 'BEGIN {
    line = ENVIRON["JIG_I_LINE"]; ref = ENVIRON["JIG_I_REF"]; n = length(ref)
    pos = 0; rest = line; found = 0
    while (!found && n > 0 && (i = index(rest, ref)) > 0) {
      p = pos + i
      before = (p > 1) ? substr(line, p - 1, 1) : ""
      after = substr(line, p + n, 1)
      if (before !~ /[A-Za-z0-9_]/ && after !~ /[A-Za-z0-9_]/) found = 1
      pos = p
      rest = substr(line, p + 1)
    }
    exit found ? 0 : 1
  }'
}

# _task_issue_subject <line> <issue> — <line> naming <issue>: unchanged when it
# already does, or is empty; otherwise `SRD-2455 <line>`, and `<line> (#123)`
# for an issue of digits — a first line that starts with `#` is a comment to
# git under `commit.cleanup=strip`, and the subject would be thrown away.
_task_issue_subject() {
  local line="$1" ref
  ref=$(_task_issue_ref "$2")
  line=${line%$'\r'}
  if [ -z "$line" ] || _task_issue_in_line "$line" "$ref"; then
    printf '%s\n' "$1"
    return 0
  fi
  case "$ref" in
    \#*) printf '%s (%s)\n' "$line" "$ref" ;;
    *) printf '%s %s\n' "$ref" "$line" ;;
  esac
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
  printf 'worktree=%s uncommitted=%s\n' "$1" "$(_task_worktree_uncommitted "$1")"
}

# _task_worktree_uncommitted <path> — how many files in the worktree at <path>
# differ from its HEAD, as `git status --porcelain` counts them: the number
# _task_worktree_note shows and `task list --json` reports.
_task_worktree_uncommitted() {
  _task_count_lines "$(git -C "$1" status --porcelain 2>/dev/null || true)"
}

# _task_worktree_holds <physical-path> <relative> — zero when <physical-path>
# is <W>/<relative> for this checkout or for any worktree git lists for this
# repository. It is what tells a directory link jig made from one planted by
# anybody else: a link jig makes leads into a checkout of this repository, and
# only git knows which checkouts those are. Paths compare physically, so a
# symlink and an NTFS junction (which bash reads as a link, and `cd -P`
# follows) are judged by where they lead, not by what they are.
_task_worktree_holds() {
  local want="$1" rel="$2" list p
  p=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || return 1
  [ "$want" != "$p/$rel" ] || return 0
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r p; do
    case "$p" in
      "worktree "*) p=${p#worktree } ;;
      *) continue ;;
    esac
    p=$(cd -P "$p" 2>/dev/null && pwd -P) || continue
    [ "$want" != "$p/$rel" ] || return 0
  done < <(printf '%s\n' "$list")
  return 1
}

# _task_borrowed_tasks_root — the physical path of `.ai/workspace/tasks` when
# this checkout borrows the whole directory from another worktree of this
# repository. Non-zero for a directory of its own, and for any other link,
# which could point anywhere.
_task_borrowed_tasks_root() {
  local link real
  link="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  [ -L "$link" ] || return 1
  real=$(cd -P "$link" 2>/dev/null && pwd -P) || return 1
  _task_worktree_holds "$real" "$JIG_AI_DIR/workspace/tasks" || return 1
  printf '%s\n' "$real"
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
  local id="$1" link real root
  # The whole directory borrowed: every task under it is the owner's, and this
  # task's workspace is simply the one named after it -- unless that name is a
  # link itself, which the borrowed directory vouches nothing for and the
  # check below judges like any other.
  if root=$(_task_borrowed_tasks_root) && [ ! -L "$root/$id" ]; then
    [ -d "$root/$id" ] || return 1
    printf '%s\n' "$root/$id"
    return 0
  fi
  link=$(task_dir "$id")
  [ -L "$link" ] || return 1
  real=$(cd -P "$link" 2>/dev/null && pwd -P) || return 1
  _task_worktree_holds "$real" "$JIG_AI_DIR/workspace/tasks/$id" || return 1
  printf '%s\n' "$real"
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
  jig_cleanup_add "$tmp"
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
  jig_record_changed
}

# --- state file rewriting -------------------------------------------------------

# Rewrite <dir>/state with <key> set to <value> (replacing an existing line,
# or inserting one before `created_at:` when the key is absent) and
# `updated_at` refreshed to today. Atomic write (ADR-0008): state.tmp.$$
# then mv. awk, not sed, does the substitution: <value> is printed literally
# rather than used as a sed replacement, so it needs no escaping.
#
# Values reach awk through the environment, not `-v`: awk expands escape
# sequences (`\n`, `\t`, ...) in a `-v` value, so a reason spelling a literal
# backslash-n (a Windows path such as `C:\temp`, or `--reason` text with one)
# would be written as an actual newline and split the state file into a
# second, bogus key (task_finding_set below uses the same ENVIRON pattern).
_task_rewrite_state() {
  local dir="$1" key="$2" value="$3" file tmp today
  _task_guard_dir "$dir"
  file="$dir/state"
  tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
  today=$(jig_today)
  JIG_S_KEY="$key" JIG_S_VALUE="$value" JIG_S_TODAY="$today" \
    awk '
    BEGIN { key = ENVIRON["JIG_S_KEY"]; value = ENVIRON["JIG_S_VALUE"]; today = ENVIRON["JIG_S_TODAY"] }
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
  jig_record_changed
}

# Rewrite <dir>/state with the <key> line removed (companion to
# _task_rewrite_state above, same atomic write and `updated_at` refresh).
# A no-op, beyond refreshing `updated_at`, when <key> is already absent.
_task_rewrite_state_remove() {
  local dir="$1" key="$2" file tmp today
  _task_guard_dir "$dir"
  file="$dir/state"
  tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
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
  jig_record_changed
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
  _task_guard_dir "$dir"
  file="$dir/state"
  [ -f "$file" ] || return 0
  tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
  today=$(jig_today)
  awk -v today="$today" '
    /^updated_at:/ { print "updated_at: " today; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
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

# _task_dirty_only_spec_raw <tracked-status-lines> — one candidate spec id
# per input line (empty for a line outside every spec), unsorted. A function
# of its own because bash 3.2 misparses a `case` written inside `$( )` (as
# `_jp_decide_raw`, profile.sh) — the loop has to live outside the
# substitution _task_dirty_only_spec reads it through.
#
# A rename line ("R  old -> new") is read from its new path; a quoted path
# (git quotes one holding a space or a non-ASCII byte) has its surrounding
# quotes stripped.
_task_dirty_only_spec_raw() {
  local lines="$1" prefix path rest line
  prefix="$JIG_AI_DIR/specs/"
  printf '%s\n' "$lines" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Columns 1-2 are the status codes, column 3 a space; the path starts
    # at column 4 (git status --porcelain's fixed format).
    path=${line#???}
    case "$path" in
      *' -> '*) path=${path#*' -> '} ;;
    esac
    case "$path" in
      \"*\") path=${path#\"}; path=${path%\"} ;;
    esac
    case "$path" in
      "$prefix"*)
        rest=${path#"$prefix"}
        printf '%s\n' "${rest%%/*}"
        ;;
      *)
        printf '\n'
        ;;
    esac
  done
}

# _task_dirty_only_spec <tracked-status-lines> — the one spec id every line
# names under `.ai/specs/<id>/`, or nothing when the lines are empty, name
# more than one id, or touch a path outside every spec. Told apart from "some
# other task's tracked work" so the refusal below can name the door that is
# actually open: `jig spec ship`, not `commit them`.
_task_dirty_only_spec() {
  local lines="$1" ids
  ids=$(_task_dirty_only_spec_raw "$lines" | sort -u)
  # More than one distinct value (several specs, or a spec mixed with
  # anything else), or the lone value being empty (nothing under a spec at
  # all): neither names one spec to point at.
  case "$ids" in
    *$'\n'*) return 1 ;;
    '') return 1 ;;
  esac
  jig_valid_id "$ids" || return 1
  [ -d "$JIG_PROJECT/$JIG_AI_DIR/specs/$ids" ] || return 1
  printf '%s\n' "$ids"
}

# _task_refuse_busy_checkout <id> — refuse to move this checkout's HEAD under
# another session (adr-20260924-a-checkout-records-what-is-happening-in-it).
#
# Who occupies this checkout is decided in one place, jig_checkout_occupants
# (checkout.sh), which `jig upgrade` reads too: a fresh record named by a task
# that has been started, is not consolidated or abandoned, and whose branch is
# the one checked out here. The task being started and this session's own id
# are left out. Nothing is deleted. Only the start that takes over this
# checkout asks: `--worktree` leaves it as it was, and a project on one branch
# moves no HEAD.
#
# The way out is named, as the dirty-tree refusal names its own. There is no
# override (ADR-0029 records that the dirty-tree one was overridden every
# time), and no advice to delete a record: what is left is a live session's
# task on HEAD, and the record lapses by itself after checkout.busy_ttl.
_task_refuse_busy_checkout() {
  local id="$1" name age cmd fname="" fage="" fcmd="" rest=0 more=""
  cfg_bool git.branch_per_task true || return 0
  while read -r name age cmd; do
    [ -n "$name" ] || continue
    if [ -z "$fname" ]; then
      fname="$name"
      fage="$age"
      fcmd="$cmd"
    else
      rest=$((rest + 1))
    fi
  done < <(jig_checkout_occupants "$id")
  [ -n "$fname" ] || return 0
  [ "$rest" -eq 0 ] || more=" (and $rest more)"
  jig_die "task start: this checkout is in use: task $fname ran \`jig $fcmd\` $(jig_checkout_ago "$fage") ago$more; start $id in its own worktree: \`jig task start $id --worktree\`, or wait until that work has finished"
}

# Refuse to start a task on a dirty working tree (design §6): untracked files
# never block (build output is not work in progress), only tracked changes do —
# a `git status --porcelain` line that is not `??` (jig_tracked_changes,
# common.sh). There is no override: the changes would ride into the new
# branch and become this task's first commit, which is how four tasks
# recorded someone else's work on 2026-09-11.
#
# The refusal is a fork, not a dead end, when branches are per task: the other
# road is a worktree of its own, which leaves this checkout — and the work in
# it — untouched (ADR-0029). When every tracked change lies under one spec's
# own directory, the door is `jig spec ship`, not a commit or a pause: the
# dirt is a spec `jig-idea` left mid-session, not another task's work
# (idea-leaves-a-tree-task-start-refuses).
_task_refuse_dirty_tree() {
  local branch="$1" id="${2:-}" tracked owner fork="" spec_id
  tracked=$(jig_tracked_changes)
  [ -n "$tracked" ] || return 0

  if [ -n "$id" ] && cfg_bool git.branch_per_task true; then
    fork=", or start it in its own worktree: \`jig task start $id --worktree\`"
  fi
  spec_id=$(_task_dirty_only_spec "$tracked") || spec_id=""
  if [ -n "$spec_id" ]; then
    jig_die "task start: uncommitted changes under $JIG_AI_DIR/specs/$spec_id/; ship it first: \`jig spec ship $spec_id\`$fork"
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
  local class="" domains="" from="" depth=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lean) depth=lean; shift ;;
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
  # The tasks directory may not exist yet (`mkdir -p` below makes it), and then
  # it is `.ai/workspace` that has to be this repository's: made through a link
  # there it would be made outside.
  local ws_path="$JIG_PROJECT/$JIG_AI_DIR/workspace" ws_real
  if [ -e "$ws_path/tasks" ] || [ -L "$ws_path/tasks" ]; then
    _task_tasks_root "task new" >/dev/null
  elif [ -e "$ws_path" ] || [ -L "$ws_path" ]; then
    ws_real=$(cd -P "$ws_path" 2>/dev/null && pwd -P) \
      || jig_die "task new: cannot inspect $JIG_AI_DIR/workspace"
    _task_worktree_holds "$ws_real" "$JIG_AI_DIR/workspace" \
      || jig_die "task new: $JIG_AI_DIR/workspace leads to $ws_real, which is no checkout of this repository"
  fi

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

  # The tracker issue, read from the id by the project's pattern before the
  # workspace exists. A pattern awk cannot read files the task without one: a
  # typo in the project's config is not a reason to refuse the work.
  local issue="" issue_rc=0
  issue=$(_task_issue_from_id "$id") || issue_rc=$?
  [ "$issue_rc" -eq 0 ] \
    || jig_warn "task new: task.issue_pattern is not a pattern awk can read; no issue recorded"

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
  jig_cleanup_add "$tmp"
  {
    printf 'task_id: %s\n' "$id"
    [ -z "$issue" ] || printf 'issue: %s\n' "$issue"
    [ -z "$class" ] || printf 'class: %s\n' "$class"
    printf 'status: active\n'
    printf 'knowledge_consolidated: false\n'
    # Filed under the route-evidence check (adr-20261004-a-route-stage-is-proven-by-its-record):
    # a task without this key was filed before it and is only warned.
    printf 'route_evidence: required\n'
    [ -z "$domains" ] || printf 'domains: %s\n' "$domains"
    [ -z "$depth" ] || printf 'route_depth: %s\n' "$depth"
    printf 'created_at: %s\n' "$(jig_today)"
    printf 'updated_at: %s\n' "$(jig_today)"
  } > "$tmp"
  mv "$tmp" "$dir/state"
  jig_record_changed

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
  _task_guard_write "$id" "task start"

  # A `branch` with no `base_commit` was recorded at filing, before starting
  # was a separate step: it is the branch the checkout happened to be on, not
  # one the task forked. Such a task was never started, and starting it is how
  # its record gets repaired — by the script that owns the key, not by hand
  # (ADR-0008). A task with a fork point is started, and stays refused.
  local existing refusal
  existing=$(task_state_get "$id" branch)
  refusal=$(_task_start_refusal "$id") || exit 1
  if [ -n "$refusal" ]; then
    if [ "$worktree" -eq 1 ]; then
      _task_move_to_worktree "$id" "$dir" "$existing" "$bootstrap"
      return 0
    fi
    jig_die "$refusal"
  fi
  if [ -n "$existing" ]; then
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
  _task_refuse_busy_checkout "$id"

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
  _task_executor_freeze "$id" "$dir"
  _task_base_hint "$id" "$base"
  _task_paused_hint "$id" ""
  printf '%s\n' "$branch"
}

# _task_start_refusal <id> — why `jig task start <id>` refuses this task by its
# state, or nothing when it would start it: a task with a fork point is
# started. The one guard the command and the actions table (_task_actions)
# both ask; what a start refuses by the checkout instead — a dirty tree, an
# occupied HEAD, a base that cannot be found — is the command's alone.
_task_start_refusal() {
  local id="$1" branch
  branch=$(task_state_get "$id" branch)
  [ -n "$branch" ] && [ -n "$(task_state_get "$id" base_commit)" ] || return 0
  # shellcheck disable=SC2016 # the backticks quote a command for the reader
  printf 'task start: already started on %s; to give it a worktree of its own: `jig task start %s --worktree`\n' "$branch" "$id"
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
  _task_executor_freeze "$id" "$dir"

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

# _task_move_to_worktree <id> <dir> <branch> <bootstrap> — give a task that is
# already started a worktree of its own: `jig task start <id> --worktree` on a
# started task. It is the way out of the refusal `task start` gives when this
# checkout is in use, and the move the moved-HEAD notice names.
#
# What it does is the four manual steps: free the branch here, add the worktree
# on it, link the workspace, carry the declared state. Nothing is recorded
# anew: the branch, the fork point and the base are the task's already, and the
# commits made so far ride along with the branch.
#
# Freeing the branch is the move `checkout-is-occupied` warns about, so it is
# made only when it takes nothing from anybody: the tree must have no tracked
# changes (a dirty one is a fork, as for `task start`: commit, or `jig task
# pause <id> --stash`), and HEAD goes to the task's base branch, which git
# refuses when that branch is checked out elsewhere or the switch would
# overwrite a file. Every refusal comes before anything is changed, and a
# failure after the switch puts HEAD back. The branch is never deleted, and
# the way back (a worktree into this checkout) is not offered: `git worktree
# remove` and `git switch` do it.
_task_move_to_worktree() {
  local id="$1" dir="$2" branch="$3" bootstrap="${4:-1}" path owner here other target="" moved=0
  cfg_bool git.branch_per_task true \
    || jig_die "task start: --worktree needs git.branch_per_task: true (one branch cannot be checked out in two worktrees)"
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
    || jig_die "task start: $id is started on $branch, which does not exist here; nothing to move"
  # `_task_worktrees` leaves this checkout out, so what it finds is elsewhere.
  other=$(_task_worktree_for "$branch" "$(_task_worktrees)")
  if [ -n "$other" ]; then
    jig_die "task start: $id is already on $branch in its own worktree: $other"
  fi
  here=$(_task_current_branch)
  path="$(_task_worktree_root)/$id"
  if [ -e "$path" ] || [ -L "$path" ]; then
    jig_die "task start: worktree path already exists: $path"
  fi
  owner=$(cd -P "$dir" && pwd -P) || jig_die "task start: cannot resolve the workspace of $id"
  jig_link_detect
  [ "$_JIG_LINK_KIND" != none ] \
    || jig_die "task start: --worktree needs a directory link, and neither a symlink nor a junction can be made here"

  if [ "$here" = "$branch" ]; then
    # This checkout holds the branch: it has to let go first.
    if [ -n "$(jig_tracked_changes)" ]; then
      jig_die "task start: $branch is checked out here with uncommitted changes, and a worktree cannot take them along; commit them, or run \`jig task pause $id --stash\`, then move the task"
    fi
    target=$(task_state_get "$id" base_branch)
    [ -n "$target" ] || target=$(cfg git.base_branch main)
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$target" >/dev/null 2>&1 \
      || jig_die "task start: cannot leave $branch here: base branch $target does not exist locally; switch this checkout to another branch, then run this again"
    git -C "$JIG_PROJECT" switch -q "$target" >/dev/null 2>&1 \
      || jig_die "task start: cannot leave $branch here: switching this checkout to $target failed (checked out in another worktree, or it would overwrite a file); switch it to another branch yourself, then run this again"
    moved=1
  fi

  if ! git -C "$JIG_PROJECT" worktree add -q "$path" "$branch" >/dev/null 2>&1; then
    _task_undo_move "$moved" "$branch" "$path"
    jig_die "task start: could not create worktree $path; $id stays on $branch"
  fi
  if ! _task_link_workspace "$owner" "$path" "$id"; then
    _task_undo_move "$moved" "$branch" "$path"
    jig_die "task start: could not link the workspace of $id into $path"
  fi
  path=$(cd -P "$path" && pwd -P) || jig_die "task start: cannot resolve worktree $path"

  if [ "$bootstrap" = 1 ]; then
    _task_carry_into "$JIG_PROJECT" "$path" "task start"
  fi

  _task_paused_hint "$id" " there"
  if [ "$moved" -eq 1 ]; then
    jig_info "task start: $id moved to its own worktree; this checkout is on $target now"
  fi
  jig_info "task start: $id is on $branch in its own worktree; open a new agent session in $path"
  printf '%s\n' "$path"
}

# _task_undo_move <moved> <branch> <path> — undo a half-made move: remove the
# worktree, and put this checkout back on the branch when it was taken off it.
# Never deletes the branch: it was the task's before the move began.
_task_undo_move() {
  git -C "$JIG_PROJECT" worktree remove "$3" >/dev/null 2>&1 || true
  git -C "$JIG_PROJECT" worktree prune >/dev/null 2>&1 || true
  [ "$1" -eq 1 ] || return 0
  git -C "$JIG_PROJECT" switch -q "$2" >/dev/null 2>&1 \
    || jig_info "task start: could not put this checkout back on $2 (a worktree is still at $3); remove it with \`git worktree remove\`, then \`git switch $2\`"
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
  _task_guard_write "$id" "task bootstrap"
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
  [ $# -eq 3 ] || [ $# -eq 5 ] || jig_die "$(_task_usage set)"
  jig_require_init
  local id="$1" key="$2" value="$3" dir reason="" has_reason=0
  if [ $# -eq 5 ]; then
    [ "$4" = --reason ] || jig_die "task set: unknown argument: $4"
    [ "$key" = class ] || jig_die "task set: --reason is only for lowering a class"
    reason="$5"
    has_reason=1
    [ -n "$reason" ] || jig_die "task set: --reason must not be empty"
    _task_finding_valid_field "$reason" || jig_die "task set: --reason must be a single line with no tab"
  fi
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task set"

  case "$key" in
    class) _task_valid_class "$value" || jig_die "task set: invalid class: $value" ;;
    status) _task_valid_status "$value" || jig_die "task set: invalid status: $value" ;;
    knowledge_consolidated) _task_valid_bool "$value" || jig_die "task set: invalid knowledge_consolidated: $value" ;;
    domains) _task_valid_domains "$value" || jig_die "task set: invalid domains: $value" ;;
    route_depth) _cfg_route_depth "$value" || jig_die "task set: invalid route_depth: $value (full or lean)" ;;
    executor_implement_runtime | executor_review_runtime | executor_implement_model | executor_review_model)
      [ -z "$(task_state_get "$id" branch)" ] \
        || jig_die "task set: executor choice is fixed when $id starts; stop this task and file a new one to change the stage executor"
      if [ "$value" != inherit ]; then
        local config_key problem
        config_key="executor.${key#executor_}"
        problem=$(jig_config_value_problem "$config_key" "$value") \
          || jig_die "task set: invalid $key: $problem"
      fi
      ;;
    task_id | issue | branch | base_commit | base_branch | created_at | updated_at | paused | paused_at | paused_reason | paused_stash \
      | autopilot | autopilot_repairs | autopilot_mode | autopilot_phase | gate | gate_design | gate_by | pr_url \
      | route_evidence | class_lowered_from | class_lowered_reason \
      | executor_implement_runtime_source | executor_review_runtime_source \
      | executor_implement_model_source | executor_review_model_source)
      jig_die "task set: key is not writable: $key" ;;
    *) jig_die "task set: unknown key: $key" ;;
  esac

  # ADR-0030: a task closes only after the knowledge decision is recorded.
  # Without this order check, `status consolidated` could be written by hand
  # ahead of `knowledge_consolidated`, which is exactly how a task ended up
  # closed with no recorded knowledge decision. Idempotent: re-setting
  # `status consolidated` on an already-consolidated task still succeeds,
  # since its flag is already true by then.
  #
  # And a merge alone never closes a task (AGENTS.md), nor does closing stand
  # in for one: _task_close_refusal asks the forge about the pull request now.
  if [ "$key" = status ] && [ "$value" = consolidated ]; then
    local refusal
    refusal=$(_task_close_refusal "$id" forge) || exit 1
    [ -z "$refusal" ] || jig_die "$refusal"
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
    # The stages the route requires, each by its record
    # (adr-20261004-a-route-stage-is-proven-by-its-record): `ready` is verify's
    # sign-off, so it asks for what comes before verify; the knowledge
    # decision is consolidation's, so it asks for verify too.
    if [ "$key" = status ]; then
      _task_route_evidence_gate "$id" ready "task set"
    else
      _task_route_evidence_gate "$id" consolidate "task set"
    fi
  fi

  if [ "$key" = class ]; then
    _task_set_class "$id" "$dir" "$value" "$has_reason" "$reason"
    return 0
  fi
  [ "$has_reason" -eq 0 ] || jig_die "task set: --reason is only for lowering a class"

  if [ "$value" = inherit ]; then
    _task_rewrite_state_remove "$dir" "$key"
  else
    _task_rewrite_state "$dir" "$key" "$value"
  fi
}

# _task_close_refusal <id> <pr-state> — why `jig task set <id> status
# consolidated` refuses this task, or nothing when it would close it.
# <pr-state> is `forge` for the command, which asks the forge now
# (jig_pr_state), or the state a reader already holds — the forge cache's, for
# the actions table (_task_actions), which never asks the forge. A cache's
# `merged` cannot be contradicted by the forge, since a merge is final; a cache
# behind the forge can only withhold a close the command would allow.
#
# A merge alone never closes a task (AGENTS.md), and neither does the
# reverse: closing a task never stands in for a merge that has not happened.
# Silent when no pull request was ever opened (pr_url unset — agent.git
# below pr, or the work never left this branch); once one was, `merged` is
# the only answer that lets `consolidated` through, asked of the forge now,
# never assumed from what wrote the request (autopilot-end-closes-unmerged-task).
#
# Forge-only, deliberately: housekeeping's own remote-state tier falls back
# from the forge to git ancestry/patch-id when the forge cannot answer
# (ADR-0005), because a background sweep can afford to keep looking. This
# gate cannot — it must answer now, synchronously, in the same call the
# human or the route is waiting on — so a forge that cannot be reached
# reads as `unknown` and refuses here, even on a run where housekeeping's
# ancestry check would have called the same pull request merged. That is
# the safe side to be wrong on: closing early cannot be taken back for
# free, and the refusal is retried by re-running this same command, not by
# `jig housekeeping`, which never feeds this gate.
_task_close_refusal() {
  local id="$1" pr_state="$2" pr
  if [ "$(task_state_get "$id" knowledge_consolidated)" != "true" ]; then
    printf 'task set: status consolidated requires knowledge_consolidated true; record the knowledge decision first: jig task set %s knowledge_consolidated true\n' "$id"
    return 0
  fi
  pr=$(task_state_get "$id" pr_url)
  [ -n "$pr" ] || return 0
  if [ "$pr_state" = forge ]; then
    pr_state=$(jig_pr_state "$pr") || return 1
  fi
  [ -n "$pr_state" ] || pr_state=unknown
  [ "$pr_state" = merged ] \
    || printf 'task set: status consolidated requires its pull request to be merged: %s is %s; merge it, then run this again\n' "$pr" "$pr_state"
  return 0
}

# _task_nobody_answers <id> — exit 0 when no human answers for <id>: this
# clone sets `autopilot.unattended`, or the task's run was started unattended
# and has not ended (`on` or `stopped`). Checked on the recorded mode too, so
# unsetting the key halfway through a run changes nothing about it.
_task_nobody_answers() {
  if jig_unattended; then return 0; fi
  case "$(task_state_get "$1" autopilot)" in
    on | stopped) [ "$(_task_autopilot_mode "$1")" = unattended ] ;;
    *) return 1 ;;
  esac
}

# _task_set_class <id> <dir> <class> <has-reason> <reason> — write the class.
# Re-classification is normal (ADR-0009), and lowering is the one direction
# that sheds stages, so it is the one that has to say why: refused without
# `--reason`, and recorded as `class_lowered_from` (the highest class the task
# was lowered from) and `class_lowered_reason`, which `jig task route`,
# `jig status` and the autopilot report show — a lowering is never quieter than
# the gate it may have skipped. Where nobody answers — `autopilot.unattended`
# set in this clone, or the task's unattended run on or stopped — a T3/T4 task
# is not lowered below T3: nobody there can read the reason before the gate is
# gone, and staying in the class is the cautious, reversible choice. Raising the class
# back to where it was lowered from clears the record
# (adr-20261004-a-route-stage-is-proven-by-its-record).
_task_set_class() {
  local id="$1" dir="$2" value="$3" has_reason="$4" reason="$5" old from
  old=$(task_state_get "$id" class)
  if _task_valid_class "$old" && [ "${value#T}" -lt "${old#T}" ]; then
    [ "$has_reason" -eq 1 ] \
      || jig_die "task set: lowering $id from $old to $value sheds stages of its route; say why: jig task set $id class $value --reason <text>"
    case "$old" in
      T3 | T4)
        if [ "${value#T}" -lt 3 ] && _task_nobody_answers "$id"; then
          jig_die "task set: an unattended run does not lower $id from $old below T3: nobody can read the reason before the gate is gone; stay in $old"
        fi ;;
    esac
    from=$(task_state_get "$id" class_lowered_from)
    if ! _task_valid_class "$from" || [ "${old#T}" -gt "${from#T}" ]; then
      from="$old"
    fi
    _task_rewrite_state "$dir" class "$value"
    _task_rewrite_state "$dir" class_lowered_from "$from"
    _task_rewrite_state "$dir" class_lowered_reason "$reason"
    if [ "$(task_state_get "$id" autopilot)" = on ]; then
      _task_autopilot_log "$id" lower "$old to $value: $reason"
    fi
    return 0
  fi
  [ "$has_reason" -eq 0 ] || jig_die "task set: --reason is only for lowering a class; $value is not lower than ${old:-unclassified}"
  _task_rewrite_state "$dir" class "$value"
  from=$(task_state_get "$id" class_lowered_from)
  if _task_valid_class "$from" && [ "${value#T}" -ge "${from#T}" ]; then
    _task_rewrite_state_remove "$dir" class_lowered_from
    _task_rewrite_state_remove "$dir" class_lowered_reason
  fi
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
  _task_guard_dir "$dir"
  file="$dir/autopilot"
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  if [ -f "$file" ]; then
    cp "$file" "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$(_task_autopilot_now)" "$event" "$text" >> "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
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
  _task_guard_write "$id" "task autopilot start"
  case "$(task_state_get "$id" autopilot)" in
    on) jig_die "task autopilot start: already running: $id" ;;
    stopped)
      if [ "$(_task_autopilot_mode "$id")" = unattended ]; then
        if [ "$(_task_autopilot_repairs "$id")" -ge 2 ]; then
          jig_die "task autopilot start: $id exhausted its unattended repair limit; ship a draft"
        fi
        jig_die "task autopilot start: $id is stopped; if a human answered, run: jig task autopilot $id resume --answer <text> --by human"
      fi
      jig_die "task autopilot start: $id is stopped; run: jig task autopilot $id resume" ;;
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
  _task_autopilot_depth_line "$id"
  _task_autopilot_git_line
}

# _task_autopilot_depth_line <id> — `depth: <depth> (<source>)`, the route
# depth (_task_route_depth) as `start` announces it and `report` repeats it.
_task_autopilot_depth_line() {
  local depth source
  IFS=$'\t' read -r depth source <<EOF
$(_task_route_depth "$1")
EOF
  printf 'depth: %s (%s)\n' "$depth" "$source"
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
  _task_guard_write "$id" "task autopilot stage"
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
  _task_guard_write "$id" "task autopilot repair"
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
  _task_autopilot_notify "$id" stop "repair limit reached (2): $reason"
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
  _task_guard_write "$id" "task autopilot stop"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot stop: no active autopilot run: $id; run: jig task autopilot $id start"

  _task_rewrite_state "$dir" autopilot stopped
  _task_autopilot_log "$id" stop "$reason"
  _task_autopilot_notify "$id" stop "$reason"
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
  _task_guard_write "$id" "task autopilot $event"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot $event: no active autopilot run: $id; run: jig task autopilot $id start"
  [ "$(_task_autopilot_mode "$id")" = unattended ] \
    || jig_die "task autopilot $event: $id's run is attended; stop and ask the human instead: jig task autopilot $id stop --reason <text>"

  _task_autopilot_log "$id" "$event" "$reason"
  _task_autopilot_notify "$id" "$event" "$reason"
  printf '%s: %s\n' "$event" "$reason"
}

# resume --answer <text> [--by human]: after the human answers a stop.
# An attended run resets its repair count. A stopped unattended run can resume
# only on an explicit human answer while it has fewer than two repairs; its
# count is preserved, so neither a manual stop nor the repair-limit stop can
# buy another repair attempt. The script cannot authenticate the answer. The
# journal quotes the claim where the person can check it.
_task_autopilot_resume() {
  local id="$1"
  shift
  local answer="" has_answer=0 by="" mode refusal
  while [ $# -gt 0 ]; do
    case "$1" in
      --answer)
        [ $# -ge 2 ] || jig_die "task autopilot resume: --answer requires a value"
        answer="$2"; has_answer=1; shift 2 ;;
      --by)
        [ $# -ge 2 ] || jig_die "task autopilot resume: --by requires human"
        [ "$2" = human ] || jig_die "task autopilot resume: --by accepts human only"
        by=human; shift 2 ;;
      *) jig_die "task autopilot resume: unknown argument: $1" ;;
    esac
  done
  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot resume"
  [ "$(task_state_get "$id" autopilot)" = "stopped" ] \
    || jig_die "task autopilot resume: not stopped: $id"
  [ "$has_answer" -eq 1 ] \
    || jig_die "task autopilot resume: --answer is required: the human's answer to the stop, in their words: jig task autopilot $id resume --answer <text>"
  [ -n "$answer" ] || jig_die "task autopilot resume: --answer must not be empty"
  _task_finding_valid_field "$answer" \
    || jig_die "task autopilot resume: --answer must be a single line with no tab"
  refusal=$(_task_autopilot_resume_refusal "$id" "$by") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"

  mode=$(_task_autopilot_mode "$id")
  if [ "$mode" = unattended ]; then
    _task_rewrite_state "$dir" autopilot on
    _task_autopilot_log "$id" resume "human: $answer"
  else
    _task_rewrite_state "$dir" autopilot on
    _task_rewrite_state "$dir" autopilot_repairs 0
    _task_autopilot_log "$id" resume "$answer"
  fi
  printf 'autopilot: on\n'
}

# _task_autopilot_resume_refusal <id> <by> — why `jig task autopilot <id>
# resume --answer <text>` (with `--by human` when <by> is `human`) refuses this
# task by its state, or nothing when it would resume the run. The command asks
# it after checking the answer itself; the actions table (_task_actions) asks
# it with the `--by` the run's mode needs.
_task_autopilot_resume_refusal() {
  local id="$1" by="$2"
  if [ "$(task_state_get "$id" autopilot)" != "stopped" ]; then
    printf 'task autopilot resume: not stopped: %s\n' "$id"
    return 0
  fi
  if [ "$(_task_autopilot_mode "$id")" = unattended ]; then
    if [ "$by" != human ]; then
      printf 'task autopilot resume: an unattended run needs an actual human answer and --by human; otherwise ship a draft\n'
    elif [ "$(_task_autopilot_repairs "$id")" -ge 2 ]; then
      printf 'task autopilot resume: %s exhausted its unattended repair limit; ship a draft\n' "$id"
    fi
  elif [ -n "$by" ]; then
    printf 'task autopilot resume: --by human is only for an unattended run\n'
  fi
  return 0
}

# end [--reason <text>]: the run reached the end of its route (design §1 step
# 5, after consolidation). Requires an active run. An unattended run ends only
# once the knowledge decision is recorded: `end` then `start` is a fresh run
# with a fresh repair count, and nobody there would have answered for it
# (adr-20261004-a-route-stage-is-proven-by-its-record).
#
# The reason says how the run ended — merged, not merged and why, ready for
# the person's commit — and is the text of the end's Telegram message
# (adr-20261009-autopilot-stops-reach-telegram). Optional: without it the
# journal line stays empty, as before, and the message says only that the run
# ended, never that anything merged.
_task_autopilot_end() {
  local id="$1"
  shift
  local reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot end: --reason requires a value"
        reason="$2"; shift 2 ;;
      *) jig_die "task autopilot end: unknown argument: $1" ;;
    esac
  done
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot end: --reason must be a single line with no tab"
  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot end"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot end: no active autopilot run: $id; run: jig task autopilot $id start"
  if [ "$(_task_autopilot_mode "$id")" = unattended ] && [ "$(task_state_get "$id" knowledge_consolidated)" != true ]; then
    jig_die "task autopilot end: $id's unattended run ends after consolidation (knowledge_consolidated true); a run whose repairs ran out stays stopped and ships a draft"
  fi

  _task_rewrite_state "$dir" autopilot "done"
  _task_autopilot_log "$id" end "$reason"
  _task_autopilot_notify "$id" end "$reason"
  printf 'autopilot: done\n'
}

# _task_autopilot_notify <id> <event> <text> — the event's Telegram message,
# detached; never fails and prints nothing (notify.sh). Called after the
# journal line, so a message never reports an event that was not recorded.
_task_autopilot_notify() {
  if ! command -v jig_notify_autopilot >/dev/null 2>&1; then
    # shellcheck source=lib/notify.sh
    . "$JIG_LIB/notify.sh" 2>/dev/null || return 0
  fi
  jig_notify_autopilot "$@" || true
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
  # A resume quotes the answer it was given and a lowering its reason, so the
  # person checks both where they read the run: in the pull request.
  block=$(awk -F '\t' '$2 == "resume" && $3 != "" { print "- " $3 }' "$file")
  [ -z "$block" ] || printf '\nResumed on an answer (check it was yours):\n%s\n' "$block"
  local from
  from=$(task_state_get "$id" class_lowered_from)
  if [ -n "$from" ]; then
    printf '\nClass lowered:\n- from %s to %s: %s\n' "$from" "$(task_state_get "$id" class)" "$(task_state_get "$id" class_lowered_reason)"
  fi
  # A linked source the task edited waits for a human's review (jig-accept),
  # and without this they would learn of it only after the merge, from
  # `jig status`. Informational: nothing here stops the run or the ship.
  # Read where the task's branch is checked out — this checkout, or the task's
  # own worktree — by a `knowledge changed` process run there: one command
  # library never sources another (ARCHITECTURE.md, Scripts layout).
  local base branch where="$JIG_PROJECT" sources
  base=$(task_state_get "$id" base_commit)
  branch=$(task_state_get "$id" branch)
  if [ -n "$base" ] && [ -n "$branch" ] && [ "$branch" != "$(_task_current_branch)" ]; then
    where=$(_task_worktree_for "$branch" "$(_task_worktrees)")
  fi
  if [ -n "$base" ] && [ -z "$where" ]; then
    # Said, not left out: an absent block would read as "nothing changed".
    printf '\nChanged linked sources: not checked, %s is not checked out in this clone\n' "$branch"
  elif [ -n "$base" ]; then
    sources=$(cd "$where" 2>/dev/null && "$JIG_SELF" knowledge changed --base "$base" --to-review 2>/dev/null) || sources=""
    [ -z "$sources" ] || printf '\n%s\n' "$sources"
  fi

  local facts state repairs mode=""
  facts=$(_task_autopilot_facts "$id")
  state=$(printf '%s\n' "$facts" | cut -f 1)
  repairs=$(printf '%s\n' "$facts" | cut -f 2)
  [ -n "$repairs" ] || repairs=0
  [ "$(_task_autopilot_mode "$id")" != unattended ] || mode=", unattended"
  _task_autopilot_depth_line "$id"
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
  _task_guard_write "$id" "task finding add"

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
  jig_cleanup_add "$tmp"
  if [ -f "$file" ]; then
    cp "$file" "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\topen\t%s\t%s\t%s\t\n' "$fid" "$severity" "$where" "$summary" "$(jig_today)" >> "$tmp"
  mv "$tmp" "$file"
  jig_record_changed

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
  _task_guard_write "$id" "task finding set"
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
  jig_cleanup_add "$tmp"
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
  jig_record_changed
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

# _task_review_tree <dir> [--all] — the git tree id of everything `git add -A`
# would stage right now in the checkout <dir>, minus `.ai/knowledge/` and
# `.ai/specs/` (with `--all`, minus nothing: the task's own knowledge edits are
# then visible to _task_receipt_context_hash). Computed through a temporary index so the real one is never
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
  local dir="$1" all="${2:-}" tmp tree
  tmp=$(mktemp "${TMPDIR:-/tmp}/jig-task-review-tree.XXXXXX") || return 1
  jig_cleanup_add "$tmp"
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
  if [ "$all" != --all ]; then
    GIT_INDEX_FILE="$tmp" git -C "$dir" rm -r -q --cached --ignore-unmatch \
      -- "$JIG_AI_DIR/knowledge" "$JIG_AI_DIR/specs" >/dev/null 2>&1 || true
  fi
  tree=$(GIT_INDEX_FILE="$tmp" git -C "$dir" write-tree 2>/dev/null) || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$tree"
}

# _task_review_merge_base <id> <dir> — the commit the task's own change is
# measured from: the merge base of the task's base branch (judged as
# jig_base_ref judges it, origin first) and the HEAD of the checkout <dir>.
# A merge of the base into the task's branch moves the merge base with it, so
# what the base brought in never counts as the task's change. Without a base
# ref the `base_commit` the task recorded at start answers; without that,
# nothing, and the callers fall back to pinning the whole tree.
_task_review_merge_base() {
  local id="$1" dir="$2" ref mb
  ref=$(jig_base_ref "$(jig_task_base "$id")")
  if [ -n "$ref" ] && mb=$(git -C "$dir" merge-base "$ref" HEAD 2>/dev/null); then
    printf '%s\n' "$mb"
    return 0
  fi
  mb=$(task_state_get "$id" base_commit)
  if [ -n "$mb" ] && git -C "$dir" rev-parse --verify --quiet "$mb^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "$mb"
    return 0
  fi
  return 1
}

# _task_review_changed_files <id> <dir> — the repo-relative paths the task's
# own change touches in the checkout <dir> (merge-base aware, untracked files
# included, `.ai/knowledge/` and `.ai/specs/` left out), one per line. Fails
# when there is no merge base to measure from.
_task_review_changed_files() {
  local id="$1" dir="$2" mb tree
  mb=$(_task_review_merge_base "$id" "$dir") || return 1
  tree=$(_task_review_tree "$dir") || return 1
  git -C "$dir" diff-tree -r --no-renames --name-only "$mb" "$tree" \
    -- . ":(exclude)$JIG_AI_DIR/knowledge" ":(exclude)$JIG_AI_DIR/specs" 2>/dev/null \
    | LC_ALL=C sort -u
}

# _task_receipt_diff_hash <id> <dir> — the receipt's `diff` field: the hash of
# the task's own change against its merge base, by content (the raw diff-tree
# listing carries both blob ids of every path). The same change gives the same
# value whatever the base has moved on to; a change to a file the task touches
# gives another. `tree:<id>` — the whole tree, the old pin — when there is no
# merge base: stricter, never softer.
_task_receipt_diff_hash() {
  local id="$1" dir="$2" mb tree
  tree=$(_task_review_tree "$dir") || return 1
  if ! mb=$(_task_review_merge_base "$id" "$dir"); then
    printf 'tree:%s\n' "$tree"
    return 0
  fi
  git -C "$dir" diff-tree -r --no-renames "$mb" "$tree" \
    -- . ":(exclude)$JIG_AI_DIR/knowledge" ":(exclude)$JIG_AI_DIR/specs" 2>/dev/null \
    | git hash-object --stdin
}

# _task_receipt_context_hash <id> <dir> — the receipt's `context` field: the
# knowledge the review was done against, by content. The documents are what
# `jig context` resolves for the files of the task's change, run in the
# checkout <dir> with the task's domains (the global documents included, the
# task's workspace left out), and the documents the task edited itself left out too: consolidation
# writes them after the review (ADR-0030), and they are part of the task's own
# change. The value hashes "<path> <content hash>" lines, so a document added,
# removed or edited by anyone else changes it. Fails when it cannot be
# computed; "-" when there is no merge base to find the task's files from.
_task_receipt_context_hash() {
  local id="$1" dir="$2" mb files full own domains matched path lines=""
  mb=$(_task_review_merge_base "$id" "$dir") || { printf -- '-\n'; return 0; }
  files=$(_task_review_changed_files "$id" "$dir") || return 1
  full=$(_task_review_tree "$dir" --all) || return 1
  own=$(git -C "$dir" diff-tree -r --no-renames --name-only "$mb" "$full" \
    -- "$JIG_AI_DIR/knowledge" 2>/dev/null) || own=""
  domains=$(task_state_get "$id" domains | tr ',' ' ')
  # A process, not a sourced library: one command library never sources
  # another (ARCHITECTURE.md, Scripts layout). `--no-task` keeps the task's
  # workspace out; its domains are passed explicitly. It is a re-entry, not a
  # session, so it carries JIG_INTERNAL_REDRAW and leaves no checkout record in
  # <dir> (checkout.sh, jig_checkout_record): a receipt check — from `task
  # list --json` too — reads about the work there, it does not do it.
  matched=$(printf '%s\n' "$files" | (cd "$dir" && JIG_INTERNAL_REDRAW=1 "$JIG_SELF" context --no-task --files - \
    ${domains:+--domains "$(printf '%s' "$domains" | tr ' ' ',')"} --format paths) 2>/dev/null) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    jig_has_line "$path" "$own" && continue
    if [ -f "$dir/$path" ]; then
      lines="$lines$path $(jig_hash "$dir/$path")
"
    else
      lines="$lines$path -
"
    fi
  done < <(printf '%s\n' "$matched")
  printf '%s' "$lines" | LC_ALL=C sort | git hash-object --stdin
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

# _task_receipt_changed <id> — "diff", "context", "design", "findings", any
# combination joined by ", ", or empty, for the parts of an existing receipt
# that no longer match the task's current state; empty (not an error) when the
# task has no receipt at all. `diff` is the task's own change against its base,
# `context` the knowledge the review relied on (ADR
# 20261003-receipt-pins-what-the-review-read); a receipt written before they
# existed has no such keys and is compared by `tree` until it is rewritten.
# One function decides staleness so `--check`, the three completion gates and
# `jig status` cannot disagree about what "stale" means (ARCHITECTURE.md,
# Scripts layout: a reporting command consumes a peer's answer, never
# recomputes it). With a second argument `cheap`, the `context` part is not
# computed — it costs a `jig context` process per task — so the answer says
# only what is certainly changed, never that the knowledge is unchanged.
_task_receipt_changed() {
  local id="$1" mode="${2:-}" file changed="" sep="" cur dir=""
  file="$(task_dir "$id")/receipt"
  [ -f "$file" ] || return 0

  # A checkout that cannot be read — the branch checked out nowhere — counts as
  # changed: the gate must not pass on a change it could not look at.
  dir=$(_task_review_dir "$id") || dir=""
  if [ -z "$(_task_receipt_get "$id" diff)" ]; then
    cur=""
    if [ -n "$dir" ]; then
      cur=$(_task_review_tree "$dir") || cur=""
    fi
    if [ "$cur" != "$(_task_receipt_get "$id" tree)" ]; then
      changed="$changed${sep}tree"
      sep=", "
    fi
  else
    cur=""
    if [ -n "$dir" ]; then
      cur=$(_task_receipt_diff_hash "$id" "$dir") || cur=""
    fi
    if [ "$cur" != "$(_task_receipt_get "$id" diff)" ]; then
      changed="$changed${sep}diff"
      sep=", "
    fi
    if [ "$mode" != cheap ]; then
      cur=""
      if [ -n "$dir" ]; then
        cur=$(_task_receipt_context_hash "$id" "$dir") || cur=""
      fi
      if [ "$cur" != "$(_task_receipt_get "$id" context)" ]; then
        changed="$changed${sep}context"
        sep=", "
      fi
    fi
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

# _task_receipt_gloss <changed> — one clause saying what each reason in the
# list _task_receipt_changed returned means, so a person can tell the task's
# own work moving from the knowledge under it moving.
_task_receipt_gloss() {
  local changed="$1" out="" sep="" reason
  for reason in tree diff context design findings; do
    case ", $changed, " in *", $reason, "*) ;; *) continue ;; esac
    case "$reason" in
      tree) out="$out${sep}tree: the working tree" ;;
      diff) out="$out${sep}diff: the task's own change" ;;
      context) out="$out${sep}context: the knowledge the review relied on, not the code" ;;
      design) out="$out${sep}design: the approved design" ;;
      findings) out="$out${sep}findings: the ledger" ;;
    esac
    sep="; "
  done
  printf '%s\n' "$out"
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
    printf 'review is stale: code changed since review on %s (%s; %s); re-review and run: jig task receipt %s --stage %s' \
      "$(_task_receipt_get "$id" reviewed_at)" "$changed" "$(_task_receipt_gloss "$changed")" "$id" "$(_task_receipt_get "$id" stage)"
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
  local id="$1" stage="$2" dir tree base_commit head diff context design findings file tmp
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task receipt"
  local review_dir
  review_dir=$(_task_review_dir "$id") \
    || jig_die "task receipt: $(task_state_get "$id" branch) is not checked out in any worktree; review the task where its branch is"
  tree=$(_task_review_tree "$review_dir") || jig_die "task receipt: could not read the working tree"
  diff=$(_task_receipt_diff_hash "$id" "$review_dir") || jig_die "task receipt: could not read the task's change"
  context=$(_task_receipt_context_hash "$id" "$review_dir") || jig_die "task receipt: could not resolve the knowledge for the task's change"
  base_commit=$(task_state_get "$id" base_commit)
  head=$(git -C "$review_dir" rev-parse --verify --quiet HEAD 2>/dev/null) || head=""
  design=$(_task_receipt_design_hash "$id")
  findings=$(_task_receipt_findings_hash "$id")
  # Every stage a receipt of this task was ever written for, so a re-review
  # under another stage does not erase that the first one happened (the route
  # evidence, adr-20261004-a-route-stage-is-proven-by-its-record). A receipt
  # from before the list counts its own `stage:`.
  local stages
  stages=$(_task_receipt_get "$id" stages)
  [ -n "$stages" ] || stages=$(_task_receipt_get "$id" stage)
  stages=$(printf '%s,%s\n' "$stages" "$stage" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)

  file="$dir/receipt"
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  {
    printf 'stage: %s\n' "$stage"
    printf 'stages: %s\n' "$stages"
    printf 'reviewed_at: %s\n' "$(jig_today)"
    printf 'tree: %s\n' "$tree"
    printf 'diff: %s\n' "$diff"
    printf 'context: %s\n' "$context"
    printf 'base_commit: %s\n' "$base_commit"
    printf 'head: %s\n' "$head"
    printf 'design: %s\n' "$design"
    printf 'findings: %s\n' "$findings"
  } > "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
  cat "$file"
}

# task_receipt_check <id> — `receipt: current|stale (...)|none`, exit 1 for
# stale and for a T4 task with none at all (design.md §3), exit 0 otherwise.
# With a second argument `cheap` (what `jig status` asks) the knowledge the
# review read is not resolved: a receipt whose diff, design and findings still
# match answers `not checked (knowledge not resolved)`, never `current`, and
# stale only when something cheap already moved. The gates ask without it.
task_receipt_check() {
  local id="$1" mode="${2:-}" file changed class
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

  changed=$(_task_receipt_changed "$id" "$mode")
  if [ -z "$changed" ]; then
    if [ "$mode" = cheap ] && [ -n "$(_task_receipt_get "$id" diff)" ]; then
      printf 'receipt: not checked (knowledge not resolved; jig task receipt %s --check)\n' "$id"
      return 0
    fi
    printf 'receipt: current\n'
    return 0
  fi
  printf 'receipt: stale (%s, reviewed %s)\n' "$changed" "$(_task_receipt_get "$id" reviewed_at)"
  return 1
}

# --- route depth (adr-20261002-route-depth-is-a-personal-choice) --------------
#
# How much of its class's route a task runs: `full`, or `lean`, which trims
# only what does not change the risk assessment. A task's own `route_depth`
# (`task new --lean`, `task set <id> route_depth`) wins; without one, the
# person's `route.depth` (local-only, config.sh) answers; without that, `full`.
# Nothing that gates — verify, the findings ledger, the receipt, the human
# gate, ship, consolidation, the route evidence (which reads the class's `full`
# route) — reads the depth, which is what keeps `lean` from ever getting under
# them. The answer is computed here and only here: `jig task
# route`, `jig status` and the autopilot report all ask _task_route_depth.

# _task_route_depth <id> [<setting>] — `<depth>\t<source>`, where <source> is
# `task` (the task's own key) or `route.depth` (the person's setting, or its
# default). <setting> is what _task_route_setting printed, so a caller asking
# for many tasks reads the file once.
_task_route_depth() {
  local id="$1" setting
  if [ $# -ge 2 ]; then
    setting="$2"
  else
    setting=$(_task_route_setting)
  fi
  _task_route_depth_of "$(task_state_get "$id" route_depth)" "$setting"
}

# _task_route_depth_of <own> <setting> — the rule itself, on values already
# read: the task's own `route_depth` wins, the setting answers otherwise. A
# caller holding the state row (`jig status`) asks this rather than repeating
# the rule. An invalid value anywhere reads as `full`: a mistake costs process,
# never a stage.
_task_route_depth_of() {
  if _cfg_route_depth "$1"; then
    printf '%s\ttask\n' "$1"
  elif _cfg_route_depth "$2"; then
    printf '%s\troute.depth\n' "$2"
  else
    printf 'full\troute.depth\n'
  fi
}

# _task_route_setting — route.depth (jig_route_depth), `full` when invalid.
_task_route_setting() {
  local value
  if value=$(jig_route_depth); then
    printf '%s\n' "$value"
  else
    printf 'full\n'
  fi
}

# _task_route_stages <class> <depth> — the route's stages, comma-separated.
# The one table of routes the scripts hold; the skills name what it prints.
_task_route_stages() {
  case "$1:$2" in
    T0:*) printf 'implement, verify, consolidate\n' ;;
    T1:*) printf 'analyze, implement, verify, consolidate\n' ;;
    T2:lean) printf 'analyze, implement, review, verify, consolidate\n' ;;
    T2:*) printf 'analyze, plan, implement, review, verify, consolidate\n' ;;
    T3:*) printf 'discover, design, human gate, implement, architecture review, verify, consolidate\n' ;;
    T4:*) printf 'discover, specify, alternatives, design, human gate, implement, independent review, verify, consolidate\n' ;;
  esac
}

# _task_route_lean_note <class> — what `lean` changes for <class>, in one line.
_task_route_lean_note() {
  case "$1" in
    T0) printf 'nothing to trim at T0\n' ;;
    T1) printf 'the analysis is a few lines in task.md, not a document of its own\n' ;;
    T2) printf 'the plan is part of the analysis; one review round: P2/P3 stay open and go to the pull request, and a re-review only closes a fixed P0/P1\n' ;;
    T3 | T4) printf 'the gate, the architecture review and verify are unchanged; one review round: P2/P3 stay open and go to the pull request, and a re-review only closes a fixed P0/P1\n' ;;
  esac
}

# _task_executor_freeze <id> <dir> — snapshot each effective executor field at
# task start, including an empty value. The source marker distinguishes an
# empty frozen choice from a pre-start task that still inherits local config.
# A changed clone-local setting cannot redirect a task already in flight.
_task_executor_freeze() {
  local id="$1" dir="$2" key value source
  for key in implement_runtime review_runtime implement_model review_model; do
    value=$(task_state_get "$id" "executor_$key")
    source=task
    if [ -z "$value" ]; then
      value=$(cfg "executor.$key" "")
      source='local config'
      [ -n "$value" ] || source=default
    fi
    _task_rewrite_state "$dir" "executor_$key" "$value"
    _task_rewrite_state "$dir" "executor_${key}_source" "$source"
  done
}

# _task_route_delegates <id> <class> — `executor:` lines for a chosen runtime and
# `delegate:` lines for a chosen in-runtime subagent model, only for stages
# in <class>'s route. Empty settings print nothing. The model is local-only,
# carried as it is written: Jig never interprets or validates it, and no gate
# reads it — delegation changes who does a stage, never the route or its
# records (adr-20261005-jig-names-the-roles-not-the-models). Review covers
# every review stage of a route — review, independent review, architecture
# review — so a class without one (T0, T1) gets no review line.
# The output carries no paths through Git Bash on Windows; the agent owns
# that boundary when it launches an external CLI.
_task_route_delegates() {
  local id="$1" class="$2" model runtime source
  runtime=$(task_state_get "$id" executor_implement_runtime)
  source=$(task_state_get "$id" executor_implement_runtime_source)
  if [ -z "$source" ]; then
    source=task
  fi
  if [ -z "$runtime" ] && [ "$source" = task ]; then
    runtime=$(cfg executor.implement_runtime "")
    source='local config'
  fi
  if [ -n "$runtime" ]; then
    printf 'executor: implement -> %s (executor.implement_runtime; %s)\n' "$runtime" "$source"
    model=$(task_state_get "$id" executor_implement_model)
    source=$(task_state_get "$id" executor_implement_model_source)
    if [ -z "$source" ]; then source=task; fi
    if [ -z "$model" ] && [ "$source" = task ]; then
      model=$(cfg executor.implement_model "")
      source='local config'
    fi
    if [ -n "$model" ]; then
      printf 'executor model: implement -> %s (executor.implement_model; %s)\n' "$model" "$source"
    fi
  fi
  model=$(cfg claude.implement_model "")
  if [ -n "$model" ]; then
    printf 'delegate: implement -> %s (claude.implement_model)\n' "$model"
  fi
  model=$(cfg codex.implement_model "")
  if [ -n "$model" ]; then
    printf 'delegate: implement -> %s (codex.implement_model)\n' "$model"
  fi
  case "$class" in
    T2 | T3 | T4) ;;
    *) return 0 ;;
  esac
  runtime=$(task_state_get "$id" executor_review_runtime)
  source=$(task_state_get "$id" executor_review_runtime_source)
  if [ -z "$source" ]; then source=task; fi
  if [ -z "$runtime" ] && [ "$source" = task ]; then
    runtime=$(cfg executor.review_runtime "")
    source='local config'
  fi
  if [ -n "$runtime" ]; then
    printf 'executor: review -> %s (executor.review_runtime; %s)\n' "$runtime" "$source"
    model=$(task_state_get "$id" executor_review_model)
    source=$(task_state_get "$id" executor_review_model_source)
    if [ -z "$source" ]; then source=task; fi
    if [ -z "$model" ] && [ "$source" = task ]; then
      model=$(cfg executor.review_model "")
      source='local config'
    fi
    if [ -n "$model" ]; then
      printf 'executor model: review -> %s (executor.review_model; %s)\n' "$model" "$source"
    fi
  fi
  model=$(cfg claude.review_model "")
  if [ -n "$model" ]; then
    printf 'delegate: review -> %s (claude.review_model)\n' "$model"
  fi
  model=$(cfg codex.review_model "")
  if [ -n "$model" ]; then
    printf 'delegate: review -> %s (codex.review_model)\n' "$model"
  fi
  return 0
}

# task_route <id> — the task's class, depth and route, for the skills to name.
task_route() {
  jig_require_init
  [ $# -eq 1 ] || jig_die "$(_task_usage route)"
  local id="$1" class depth source
  [ -f "$(task_dir "$id")/state" ] || jig_die "task route: unknown task: $id"
  class=$(task_state_get "$id" class)
  IFS=$'\t' read -r depth source <<EOF
$(_task_route_depth "$id")
EOF
  printf 'class: %s\n' "${class:--}"
  printf 'depth: %s (%s)\n' "$depth" "$source"
  if ! _task_valid_class "$class"; then
    printf 'route: none until the task is classified (jig task set %s class Tn)\n' "$id"
    return 0
  fi
  printf 'route: %s\n' "$(_task_route_stages "$class" "$depth")"
  if [ "$depth" = lean ]; then
    printf 'lean: %s\n' "$(_task_route_lean_note "$class")"
  fi
  printf 'never trimmed: tests on changed files, CI before a merge, consolidation\n'
  _task_autopilot_git_line
  _task_route_delegates "$id" "$class"
  local from
  from=$(task_state_get "$id" class_lowered_from)
  if [ -n "$from" ]; then
    printf 'lowered: from %s: %s\n' "$from" "$(task_state_get "$id" class_lowered_reason)"
  fi
}

# --- route evidence (adr-20261004-a-route-stage-is-proven-by-its-record) -------
#
# A class decides the process by mechanics, not by prose: the stages of the
# class's route (_task_route_stages, `full`) that leave a record
# must have left it before the completion gates pass. Only records that resist
# ritual count (convention-required-records): the human gate's approval pinned
# to the current design, a receipt the reviewer computed, verify's own
# `status ready`, and the design documents the gate pinned. A stage whose only
# trace is prose the actor writes for itself — discover, analyze, plan — or
# the diff — implement — is not asked for, and neither is the autopilot
# journal, which the actor writes about itself under names of its choosing.
#
# The depth is not read: the records asked for are the class's `full` route's,
# so a person's local `route.depth` can never loosen a gate. Lean trims only
# stages that leave no record (the plan), so a lean run is asked the same
# records; a depth that ever trimmed a recorded stage would be refused here,
# not let through.
#
# A task filed before this check — no `route_evidence: required` in its state,
# which `jig task new` writes — is judged as before: what is missing is
# printed as a warning and the gate passes, so no task in flight is stopped
# halfway through a route it began under other rules.

# _task_receipt_covers <id> <stage> — exit 0 when the task's receipt records a
# review of <stage>: its `stages:` list, or, for a receipt written before the
# list existed, its `stage:`.
_task_receipt_covers() {
  local id="$1" stage="$2" stages
  [ -f "$(task_dir "$id")/receipt" ] || return 1
  stages=$(_task_receipt_get "$id" stages)
  [ -n "$stages" ] || stages=$(_task_receipt_get "$id" stage)
  case ",$stages," in
    *",$stage,"*) return 0 ;;
  esac
  return 1
}

# _task_route_evidence_missing <id> <point> — one line per stage of the task's
# class's full route that leaves a record and has not, each naming the command that writes
# it; nothing when the route is complete. <point> is `ready` (every stage
# before verify) or `consolidate` (verify too: `status ready` is its record).
_task_route_evidence_missing() {
  local id="$1" point="$2" dir class stages stage
  dir=$(task_dir "$id")
  class=$(task_state_get "$id" class)
  if ! _task_valid_class "$class"; then
    printf 'class (not classified, so there is no route: jig task set %s class Tn)\n' "$id"
    return 0
  fi
  stages=$(_task_route_stages "$class" full)
  while IFS= read -r stage; do
    case "$stage" in
      specify)
        [ -s "$dir/spec.md" ] || printf 'specify (no spec.md: jig task artifact write %s spec)\n' "$id" ;;
      alternatives)
        [ -s "$dir/alternatives.md" ] || printf 'alternatives (no alternatives.md: jig task artifact write %s alternatives)\n' "$id" ;;
      design)
        [ -s "$dir/design.md" ] || printf 'design (no design.md: jig task artifact write %s design)\n' "$id" ;;
      'human gate')
        case "$(_task_gate_state "$id")" in
          approved) ;;
          changed) printf 'human gate (the design changed after its approval: take it back to the gate, then jig task gate %s approved)\n' "$id" ;;
          *) printf 'human gate (no approval recorded: jig task gate %s approved)\n' "$id" ;;
        esac ;;
      review | 'independent review')
        _task_receipt_covers "$id" review \
          || printf '%s (no review receipt: jig task receipt %s --stage review)\n' "$stage" "$id" ;;
      'architecture review')
        _task_receipt_covers "$id" architecture-review \
          || printf 'architecture review (no architecture-review receipt: jig task receipt %s --stage architecture-review)\n' "$id" ;;
      verify)
        [ "$point" = consolidate ] || continue
        case "$(task_state_get "$id" status)" in
          ready | consolidated) ;;
          *) printf 'verify (not signed off: jig verify, then jig task set %s status ready)\n' "$id" ;;
        esac ;;
    esac
  done < <(printf '%s\n' "$stages" | tr ',' '\n' | sed 's/^ *//')
}

# _task_route_evidence_list <id> <point> — what _task_route_evidence_missing
# printed, on one line joined by "; "; nothing when the route is complete.
_task_route_evidence_list() {
  _task_route_evidence_missing "$1" "$2" | awk 'NR > 1 { printf "; " } { printf "%s", $0 } END { if (NR) printf "\n" }'
}

# _task_route_evidence_refusal <id> <point> <command> — the refusal
# _task_route_evidence_gate dies with, or nothing: only a task filed under this
# check is refused, an older one is warned. Read by `task ship`'s guard, which
# the actions table shares (_task_ship_refusal).
_task_route_evidence_refusal() {
  local id="$1" point="$2" cmd="$3" missing
  [ "$(task_state_get "$id" route_evidence)" = required ] || return 0
  missing=$(_task_route_evidence_list "$id" "$point")
  [ -z "$missing" ] \
    || printf '%s: the route of %s (%s) is missing: %s\n' "$cmd" "$id" "$(task_state_get "$id" class)" "$missing"
  return 0
}

# _task_route_evidence_gate <id> <point> <command> — refuse, as <command>, a
# task filed under this check whose route is missing a record; warn, and pass,
# for a task filed before it.
_task_route_evidence_gate() {
  local id="$1" point="$2" cmd="$3" missing
  missing=$(_task_route_evidence_list "$id" "$point")
  [ -n "$missing" ] || return 0
  if [ "$(task_state_get "$id" route_evidence)" = required ]; then
    jig_die "$(_task_route_evidence_refusal "$id" "$point" "$cmd")"
  fi
  jig_warn "$cmd: $id was filed before route evidence was checked, so this passes without: $missing"
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
  local id="$1" decision="$2" by=human dir design refusal
  if [ $# -eq 4 ]; then
    [ "$3" = --by ] || jig_die "task gate: unknown argument: $3"
    case "$4" in
      human | agent) by="$4" ;;
      *) jig_die "task gate: invalid --by: $4 (expected human|agent)" ;;
    esac
  fi
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task gate"
  [ "$decision" = approved ] || jig_die "task gate: unknown decision: $decision (expected approved)"
  refusal=$(_task_gate_refusal "$id" "$by") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"
  design=$(_task_receipt_design_hash "$id")
  _task_rewrite_state "$dir" gate approved
  _task_rewrite_state "$dir" gate_design "$design"
  _task_rewrite_state "$dir" gate_by "$by"
  if [ "$by" = agent ]; then
    printf 'gate: approved by the agent\n'
  else
    printf 'gate: approved\n'
  fi
}

# _task_gate_refusal <id> <by> — why `jig task gate <id> approved --by <by>`
# refuses this task by its state, or nothing when it would record the
# approval. Shared with the actions table (_task_actions), which asks it for
# `--by human`: the approval a person gives.
_task_gate_refusal() {
  local id="$1" by="$2" class
  if [ "$by" = agent ]; then
    if [ "$(task_state_get "$id" autopilot)" != on ] || [ "$(_task_autopilot_mode "$id")" != unattended ]; then
      printf "task gate: --by agent is an unattended run's self-approval; %s has no unattended autopilot run on, so the gate is the human's\n" "$id"
      return 0
    fi
  elif _task_nobody_answers "$id"; then
    # Nobody answers where this clone is unattended or the task's unattended run
    # is on or stopped, so an approval recorded there is the agent's, and is
    # said to be (adr-20261004-a-route-stage-is-proven-by-its-record).
    if [ "$(task_state_get "$id" autopilot)" = on ]; then
      printf "task gate: %s's run is unattended, so this approval is the agent's: jig task gate %s approved --by agent\n" "$id" "$id"
      return 0
    fi
    if [ "$(task_state_get "$id" autopilot)" = stopped ]; then
      if [ "$(_task_autopilot_repairs "$id")" -ge 2 ]; then
        printf 'task gate: %s exhausted its unattended repair limit; ship a draft\n' "$id"
        return 0
      fi
      printf 'task gate: %s is stopped; if a human answered, run: jig task autopilot %s resume --answer <text> --by human; then approve with --by agent\n' "$id" "$id"
      return 0
    fi
    printf 'task gate: nobody answers for %s (unattended); start its run and approve with --by agent\n' "$id"
    return 0
  fi
  class=$(task_state_get "$id" class)
  case "$class" in
    T3 | T4) ;;
    *)
      printf 'task gate: %s is %s; only T3 and T4 tasks have a human gate\n' "$id" "${class:-unclassified}"
      return 0 ;;
  esac
  [ "$(_task_receipt_design_hash "$id")" != "-" ] || printf 'task gate: %s has no design.md to approve\n' "$id"
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

# _task_pause_refusal <id>, _task_resume_refusal <id> — why `jig task pause`
# or `jig task resume` refuses this task by its state, or nothing. Shared with
# the actions table (_task_actions). Resume's other refusal — the checkout is
# not on the task's branch — is the command's: it depends on where it runs.
_task_pause_refusal() {
  [ "$(task_state_get "$1" paused)" != "true" ] || printf 'task pause: already paused: %s\n' "$1"
}
_task_resume_refusal() {
  [ "$(task_state_get "$1" paused)" = "true" ] || printf 'task resume: not paused: %s\n' "$1"
}

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
  local reason="" stash=0 refusal
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) [ $# -ge 2 ] || jig_die "task pause: --reason requires a value"; reason="$2"; shift 2 ;;
      --stash) stash=1; shift ;;
      *) jig_die "task pause: unknown argument: $1" ;;
    esac
  done

  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task pause"
  refusal=$(_task_pause_refusal "$id") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"

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
  local id="$1" dir refusal
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task resume"
  refusal=$(_task_resume_refusal "$id") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"

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
  local arg
  # `--json` anywhere asks for the same listing as data, in the envelope
  # (lib/json.sh). It is looked for before anything else runs, so that a
  # refusal — an unknown argument, a project without jig — is an envelope too.
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_list "$@"
      return
    fi
  done
  _task_list "$@"
}

_task_list() {
  jig_require_init
  local show_all=0 want_status="" goals=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) show_all=1; shift ;;
      --goals) goals=1; shift ;;
      --json) json=1; shift ;;
      --status)
        [ $# -ge 2 ] || jig_fail usage "task list: --status requires a value"
        _task_valid_status "$2" || jig_fail usage "task list: invalid status: $2"
        want_status="$2"
        shift 2
        ;;
      *) jig_fail usage "task list: unknown argument: $1" ;;
    esac
  done

  _task_list_select "$show_all" "$want_status"
  if [ "$json" -eq 1 ]; then
    _task_list_json
    return 0
  fi

  local base="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  local dir id class status branch base_branch default_base paused issue line lines="" hidden worktrees wt
  hidden=$_TASK_LIST_HIDDEN
  worktrees=$(_task_worktrees)
  # The base is shown only where it is not the project's: a listing where
  # every line says base=main says nothing.
  default_base=$(cfg git.base_branch main)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    dir="$base/$id/"
    class=$(task_state_get "$id" class)
    status=$(task_state_get "$id" status)
    branch=$(task_state_get "$id" branch)
    paused=$(task_state_get "$id" paused)
    [ -n "$class" ] || class="-"
    line="$id class=$class status=$status"
    issue=$(task_state_get "$id" issue)
    [ -z "$issue" ] || line="$line issue=$issue"
    # A task with no branch has not been started. Saying so is the whole
    # point of representing "not started" as an absence: without a marker the
    # listing shows it as indistinguishable from work in progress.
    if [ -n "$branch" ]; then
      line="$line branch=$branch"
      wt=$(_task_worktree_for "$branch" "$worktrees")
      [ -z "$wt" ] || line="$line $(_task_worktree_note "$wt")"
    else
      line="$line not-started"
    fi
    base_branch=$(task_state_get "$id" base_branch)
    if [ -n "$base_branch" ] && [ "$base_branch" != "$default_base" ]; then
      line="$line base=$base_branch"
    fi
    [ "$paused" = "true" ] && line="$line paused"
    # The goal rides on the line through the sort, after a unit separator,
    # and is put on a line of its own below it once sorted.
    [ "$goals" -eq 0 ] || line="$line"$'\037'"goal: $(_task_goal "${dir}task.md")"
    lines="$lines
$line"
  done <<EOF
$_TASK_LIST_IDS
EOF
  lines=$(printf '%s\n' "$lines" | sed '/^$/d')
  if [ -z "$lines" ]; then
    if [ "$hidden" -gt 0 ]; then
      printf 'no live tasks (%d finished; jig task list --all)\n' "$hidden"
    else
      printf 'no tasks\n'
    fi
    return 0
  fi
  printf '%s\n' "$lines" | sort | awk -F '\037' '{ print $1; if (NF > 1) print "  " $2 }'
  [ "$hidden" -gt 0 ] && printf '(%d finished; jig task list --all)\n' "$hidden"
  return 0
}

# _task_list_select <show_all> <want_status> — which tasks `task list` shows,
# in the text and the JSON form alike: _TASK_LIST_IDS gets their ids, one per
# line, and _TASK_LIST_HIDDEN how many finished tasks were left out. Called as
# a plain command, never through $(...), so both globals reach the caller.
_TASK_LIST_IDS=""
_TASK_LIST_HIDDEN=0
_task_list_select() {
  local show_all="$1" want_status="$2" dir id status
  _TASK_LIST_IDS=""
  _TASK_LIST_HIDDEN=0
  for dir in "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"/*/; do
    [ -f "${dir}state" ] || continue
    id=$(basename "$dir")
    # Same rule as _task_candidates_for_branch: skip, never die on, a
    # directory whose name is not a task id.
    _task_valid_id "$id" || continue
    status=$(task_state_get "$id" status)
    if [ -n "$want_status" ]; then
      [ "$status" = "$want_status" ] || continue
    elif [ "$show_all" -eq 0 ] && ! _task_is_live "$status"; then
      _TASK_LIST_HIDDEN=$((_TASK_LIST_HIDDEN + 1))
      continue
    fi
    _TASK_LIST_IDS="$_TASK_LIST_IDS$id
"
  done
  return 0
}

# The housekeeping flags `task list --json` reports, in the words the log
# writes them (housekeeping_decide, _hk_report). Each is asked through
# hklog_flagged_ids, so a flag this disk already disproves is dropped exactly
# as the status page drops it.
_TASK_LIST_HK_FLAGS="needs-consolidation wrong-base abandoned? worktree-kept base-unreleased STALE_CANDIDATE"

# The forge cache's lines (forgecache_read), read once by _task_list_json for
# every task it lists.
_TASK_LIST_FORGE_CACHE=""

# _task_list_json — the `data` of `task list --json` for the tasks
# _task_list_select chose: one JSON object on stdout, in the shape
# schemas/json.md pins. Every value comes from the producer that already
# answers it for the text listing, the status page or the gates; nothing here
# decides what they do not. Local reads only: no fetch, no forge.
_task_list_json() {
  # shellcheck source=lib/hklog.sh
  . "$JIG_LIB/hklog.sh"
  # shellcheck source=lib/forgecache.sh
  . "$JIG_LIB/forgecache.sh"
  local worktrees flag ids fid flagged="" run ran_at forge t id rows=""
  t=$(printf '\t')
  worktrees=$(_task_worktrees)
  # What housekeeping last heard from the forge, read once per listing.
  _TASK_LIST_FORGE_CACHE=$(forgecache_read)
  # "<id><TAB><flag>" for every flag that still stands, asked once per flag
  # rather than once per task. Pathname expansion is off for the split:
  # `abandoned?` is a glob.
  set -f
  for flag in $_TASK_LIST_HK_FLAGS; do
    ids=$(hklog_flagged_ids "$flag")
    while IFS= read -r fid; do
      [ -n "$fid" ] || continue
      flagged="$flagged$fid$t$flag
"
    done <<EOF
$ids
EOF
  done
  set +f
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    rows="$rows$id$t$(_task_list_json_task "$id" "$worktrees" "$flagged")
"
  done <<EOF
$_TASK_LIST_IDS
EOF
  printf '{"tasks":['
  # Sorted by id, as the text listing is. A record holds no raw tab or
  # newline (json_quote escapes both), so the id column is the whole key.
  printf '%s' "$rows" | sed '/^$/d' | LC_ALL=C sort -t "$t" -k1,1 | cut -f2- \
    | awk 'NR > 1 { printf "," } { printf "%s", $0 }'
  printf '],"hidden":%s,"housekeeping":' "$_TASK_LIST_HIDDEN"
  run=$(hklog_last_run)
  if [ -z "$run" ]; then
    printf 'null'
  else
    ran_at=${run%%"$t"*}
    forge=${run#*"$t"}
    [ "$forge" != "-" ] || forge=""
    json_quote "$ran_at"
    printf '{"ran_at":%s,' "$_JSON"
    json_str_or_null "$forge"
    printf '"forge":%s}' "$_JSON"
  fi
  printf '}\n'
}

# _task_list_json_task <id> <worktrees> <flagged> — one task as a JSON object
# on one line. <worktrees> is a _task_worktrees listing and <flagged> the
# "<id><TAB><flag>" lines _task_list_json collected; both are read once per
# listing, not once per task.
_task_list_json_task() {
  local id="$1" worktrees="$2" flagged="$3" line o t
  local class status issue consolidated paused created updated branch base pr_url gate_by
  local wt gate facts state repairs stage stage_at stop stop_at phase goal flag flags=""
  t=$(printf '\t')
  # Through task_state_get, the one reader of the state format.
  class=$(task_state_get "$id" class)
  status=$(task_state_get "$id" status)
  issue=$(task_state_get "$id" issue)
  consolidated=$(task_state_get "$id" knowledge_consolidated)
  paused=$(task_state_get "$id" paused)
  created=$(task_state_get "$id" created_at)
  updated=$(task_state_get "$id" updated_at)
  branch=$(task_state_get "$id" branch)
  pr_url=$(task_state_get "$id" pr_url)
  gate_by=$(task_state_get "$id" gate_by)

  json_quote "$id"; o="{\"id\":$_JSON"
  json_str_or_null "$class"; o="$o,\"class\":$_JSON"
  json_str_or_null "$status"; o="$o,\"status\":$_JSON"
  json_str_or_null "$issue"; o="$o,\"issue\":$_JSON"
  goal=$(_task_goal "$(task_dir "$id")/task.md")
  [ "$goal" != "(none)" ] || goal=""
  json_str_or_null "$goal"; o="$o,\"goal\":$_JSON"
  json_bool "$consolidated"; o="$o,\"knowledge_consolidated\":$_JSON"
  json_bool "$paused"; o="$o,\"paused\":$_JSON"
  json_str_or_null "$created"; o="$o,\"created_at\":$_JSON"
  json_str_or_null "$updated"; o="$o,\"updated_at\":$_JSON"
  json_str_or_null "$branch"; o="$o,\"branch\":$_JSON"
  base=$(jig_task_base "$id")
  json_quote "$base"; o="$o,\"base_branch\":$_JSON"

  wt=""
  [ -z "$branch" ] || wt=$(_task_worktree_for "$branch" "$worktrees")
  if [ -n "$wt" ]; then
    json_quote "$wt"
    o="$o,\"worktree\":{\"path\":$_JSON,\"uncommitted\":$(_task_worktree_uncommitted "$wt")}"
  else
    o="$o,\"worktree\":null"
  fi

  gate=$(_task_gate_state "$id")
  if [ -n "$gate" ]; then
    json_quote "$gate"; o="$o,\"gate\":{\"state\":$_JSON"
    # Who approved: nobody while it waits; an approval recorded before
    # `gate_by` existed is read as `human` (schemas/state.md).
    if [ "$gate" = waiting ]; then
      _JSON=null
    else
      json_quote "${gate_by:-human}"
    fi
    o="$o,\"by\":$_JSON}"
  else
    o="$o,\"gate\":null"
  fi

  facts=$(_task_autopilot_facts "$id")
  if [ -n "$facts" ]; then
    IFS="$t" read -r state repairs stage stage_at stop stop_at phase <<EOF
$facts
EOF
    [ "$stage" != "-" ] || stage=""
    [ "$stage_at" != "-" ] || stage_at=""
    [ "$stop" != "-" ] || stop=""
    [ "$stop_at" != "-" ] || stop_at=""
    [ "$phase" != "-" ] || phase=""
    json_quote "$state"; o="$o,\"autopilot\":{\"state\":$_JSON"
    # The mode the gates read: anything but `unattended` is attended.
    json_quote "$(_task_autopilot_mode "$id")"; o="$o,\"mode\":$_JSON"
    json_int_or_null "$repairs"; o="$o,\"repairs\":$_JSON"
    json_str_or_null "$stage"; o="$o,\"stage\":$_JSON"
    json_str_or_null "$stage_at"; o="$o,\"stage_at\":$_JSON"
    json_str_or_null "$stop"; o="$o,\"stop_reason\":$_JSON"
    json_str_or_null "$stop_at"; o="$o,\"stop_at\":$_JSON"
    json_str_or_null "$phase"; o="$o,\"phase\":$_JSON}"
  else
    o="$o,\"autopilot\":null"
  fi

  # What `task ship` opened, with its state and checks as housekeeping last
  # heard them from the forge (lib/forgecache.sh), joined by the task's branch
  # and base as housekeeping's own remote state joins them. Reading never asks
  # the forge: an old entry says how old it is, a missing one is null.
  if [ -n "$pr_url" ]; then
    json_quote "$pr_url"; o="$o,\"pull_request\":{\"url\":$_JSON"
    forgecache_entry "$_TASK_LIST_FORGE_CACHE" "$branch" "$base"
    json_str_or_null "$_FORGECACHE_STATE"; o="$o,\"state\":$_JSON"
    json_str_or_null "$_FORGECACHE_CI"; o="$o,\"ci\":$_JSON"
    json_str_or_null "$_FORGECACHE_AT"; o="$o,\"fetched_at\":$_JSON}"
  else
    o="$o,\"pull_request\":null"
  fi

  while IFS="$t" read -r line flag; do
    [ "$line" = "$id" ] || continue
    json_quote "$flag"
    flags="${flags:+$flags,}$_JSON"
  done <<EOF
$flagged
EOF
  o="$o,\"housekeeping_flags\":[$flags]"

  # What a person may do next (_task_actions): every row of the table, with
  # the pull request's state as the forge cache holds it, never the forge's.
  local action offered command reason actions="" pr_state=""
  [ -z "$pr_url" ] || pr_state=$_FORGECACHE_STATE
  while IFS="$t" read -r action offered command reason; do
    [ -n "$action" ] || continue
    json_quote "$action"; line="{\"id\":$_JSON"
    json_quote "$command"; line="$line,\"command\":$_JSON,\"offered\":$offered"
    json_str_or_null "$reason"; line="$line,\"reason\":$_JSON}"
    actions="${actions:+$actions,}$line"
  done <<EOF
$(_task_actions "$id" "$pr_state")
EOF
  printf '%s,"actions":[%s]}\n' "$o" "$actions"
}

# --- what a person may do next (adr-20261015-one-table-of-what-a-person-may-do)
#
# One table of the moves a person makes on a task, each a Jig command, and
# whether this task's state lets it through. No consumer keeps a copy: `task
# list --json` reports it per task (schemas/json.md). The rule is one-way —
# an action offered is one its command accepts on this task's state — and it
# holds because each row asks the command's own guard (_task_*_refusal), whose
# text is the reason a row is withheld. The table may withhold more than the
# command refuses: a finished task offers nothing but `reopen`, a design
# already approved offers no approval, a merged pull request no ship. What a
# command refuses by the checkout it runs in, by the network or by the value a
# person types is the command's when it runs, never the table's.
#
# The rows, in their order; the ids are a contract. Pause and resume requests
# (spec contract-queue) join as rows of their own, with a guard that reads the
# queue.
_TASK_ACTIONS="start pause resume approve-gate answer-stop set-class ship close abandon reopen"

# _task_actions <id> <pr-state> — one line per row of the table:
# `<action><TAB><true|false><TAB><command><TAB><reason>`, the reason empty
# when the action is offered. <pr-state> is what the reader knows of the
# task's pull request without asking the forge (the forge cache's state, or
# empty); `close` and `ship` read it. Local reads only.
_task_actions() {
  local id="$1" pr_state="$2" status action command reason by=""
  status=$(task_state_get "$id" status)
  for action in $_TASK_ACTIONS; do
    reason=""
    case "$action" in
      start) command="jig task start $id" ;;
      pause) command="jig task pause $id" ;;
      resume) command="jig task resume $id" ;;
      approve-gate) command="jig task gate $id approved" ;;
      answer-stop)
        # The `--by human` an unattended run's resume needs, in the command
        # and in the guard alike.
        command="jig task autopilot $id resume --answer <text>"
        if [ "$(_task_autopilot_mode "$id")" = unattended ]; then
          by=human
          command="$command --by human"
        fi ;;
      set-class) command="jig task set $id class <Tn>" ;;
      ship) command="jig task ship $id --message-file <file>" ;;
      close) command="jig task set $id status consolidated" ;;
      abandon) command="jig task abandon $id" ;;
      reopen) command="jig task set $id status active" ;;
    esac
    case "$status:$action" in
      abandoned:reopen) ;;
      consolidated:* | abandoned:*) reason="task $id is $status" ;;
      *:reopen) reason="task $id is $status, not abandoned" ;;
      *:start) reason=$(_task_actions_guard "$id" "$action" _task_start_refusal "$id") ;;
      *:pause) reason=$(_task_actions_guard "$id" "$action" _task_pause_refusal "$id") ;;
      *:resume) reason=$(_task_actions_guard "$id" "$action" _task_resume_refusal "$id") ;;
      *:approve-gate)
        reason=$(_task_actions_guard "$id" "$action" _task_gate_refusal "$id" human)
        if [ -z "$reason" ] && [ "$(_task_gate_state "$id")" = approved ]; then
          reason="task gate: $id's design is approved; nothing waits at its gate"
        fi ;;
      *:answer-stop) reason=$(_task_actions_guard "$id" "$action" _task_autopilot_resume_refusal "$id" "$by") ;;
      *:ship)
        if [ "$pr_state" = merged ]; then
          reason="task ship: $id's pull request is merged"
        else
          # In the command's order: the level, the gates, the branch.
          reason=$(_task_actions_guard "$id" "$action" _task_ship_level_refusal "$id")
          [ -n "$reason" ] || reason=$(_task_actions_guard "$id" "$action" _task_ship_refusal "$id" 0)
          [ -n "$reason" ] || reason=$(_task_actions_guard "$id" "$action" _task_ship_branch_refusal "$id")
        fi ;;
      *:close) reason=$(_task_actions_guard "$id" "$action" _task_close_refusal "$id" "${pr_state:-unknown}") ;;
    esac
    if [ -n "$reason" ]; then
      printf '%s\tfalse\t%s\t%s\n' "$action" "$command" "$reason"
    else
      printf '%s\ttrue\t%s\t\n' "$action" "$command"
    fi
  done
}

# _task_actions_guard <id> <action> <guard> [args] — what <guard> prints, or,
# when it could not decide, a reason that withholds <action>: a guard that
# fails never reads as "nothing refuses".
_task_actions_guard() {
  local id="$1" action="$2" out
  shift 2
  if out=$("$@"); then
    printf '%s\n' "$out"
  else
    printf 'jig could not check whether %s may %s now\n' "$id" "$action"
  fi
}

# _task_goal <task.md> — the first paragraph under the `## Goal` heading of a
# task's brief, joined into one line, or `(none)` when the brief has no such
# heading or nothing under it. What `jig task list --goals` shows a person
# choosing which tasks go into a release; a missing goal is a gap in the
# brief, said as one, not a field to add.
_task_goal() {
  local goal=""
  [ -f "$1" ] && goal=$(awk '
    /^##[[:space:]]+Goal[[:space:]]*$/ { in_goal = 1; next }
    in_goal && /^#/ { exit }
    in_goal && /^[[:space:]]*$/ { if (text != "") exit; next }
    in_goal {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      text = (text == "" ? line : text " " line)
    }
    END { print text }
  ' "$1")
  [ -n "$goal" ] || goal="(none)"
  printf '%s\n' "$goal"
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
# A link anywhere on the way is judged by where it leads, never by its shape.
# `-L` asks about the last component only, and comparing the task's directory
# with the tasks directory proves nothing when both resolve through the same
# link above them: a planted `.ai/workspace/tasks` (or `.ai/workspace`) passed
# that comparison wherever it pointed, outside the repository included. So
# the tasks directory itself must physically be the one of a checkout of this
# repository -- this one, or the owner a `task start --worktree` link (a
# symlink, or a junction on Windows) leads to, or the owner a coordinator's
# workspace link leads to (ADR-0029 as amended). Inside it, a task directory
# that is a link must lead to this task's workspace in some worktree of this
# repository (the single-task link `task start` still makes where the whole
# directory cannot be linked); any other must be exactly the entry named after
# the task. <command> names the caller in the refusals, so the message still
# says which verb refused.
_task_workspace_root() {
  local id="$1" cmd="$2" root tasks_root real
  root=$(task_dir "$id") || return 1
  [ -f "$root/state" ] || jig_die "$cmd: unknown task: $id"
  tasks_root=$(_task_tasks_root "$cmd")
  if [ -L "$root" ]; then
    real=$(cd -P "$root" 2>/dev/null && pwd -P) || real=""
    if [ -z "$real" ] || ! _task_worktree_holds "$real" "$JIG_AI_DIR/workspace/tasks/$id"; then
      jig_die "$cmd: linked task workspace is unsupported unless it is this task's workspace in another worktree"
    fi
    printf '%s\n' "$real"
    return 0
  fi
  real=$(cd -P "$root" && pwd -P) || jig_die "$cmd: cannot inspect workspace"
  [ "$real" = "$tasks_root/$id" ] || jig_die "$cmd: workspace outside task root"
  printf '%s\n' "$real"
}

# _task_tasks_root <command> — the physical path of `.ai/workspace/tasks`, once
# it is known to be the tasks directory of a checkout of this repository
# (see above); dies naming <command> otherwise. The half of the check that
# does not need a task, so `task new` can make it before a task exists.
_task_tasks_root() {
  local cmd="$1" tasks_root
  tasks_root=$(cd -P "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks" 2>/dev/null && pwd -P) \
    || jig_die "$cmd: cannot inspect $JIG_AI_DIR/workspace/tasks"
  _task_worktree_holds "$tasks_root" "$JIG_AI_DIR/workspace/tasks" \
    || jig_die "$cmd: $JIG_AI_DIR/workspace/tasks leads to $tasks_root, which is no checkout of this repository"
  printf '%s\n' "$tasks_root"
}

# _task_guard_write <id> <command> — the check every writer of a task's
# workspace (`state`, the journal, findings, the receipt, artifacts) passes
# before it writes anything, including a side effect that comes first (a stash,
# a commit). Dies, naming <command>, unless the workspace is this checkout's
# own, a worktree's, or the owner's a start linked; unknown task included.
# Called as a plain command, never inside $(...), so the refusal ends the
# process rather than a subshell.
_task_guard_write() {
  _task_workspace_root "$1" "$2" >/dev/null
}

# _task_guard_dir <dir> — the same check for a low-level writer that is handed
# a workspace directory (task_dir's answer, or the physical root of one). The
# verb is the running `jig task` subcommand, set by cmd_task.
_task_guard_dir() {
  _task_workspace_root "${1##*/}" "${_TASK_VERB:-task}" >/dev/null
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

# stage|documentary inputs|unassessed semantic prerequisites, for <class> at
# <depth> (_task_route_depth; `full` when absent). This is not a router: the
# stages are _task_route_stages', and lean changes only what T1 and T2 read —
# the analysis lives in task.md at T1, and the plan inside the analysis at T2
# (adr-20261002-route-depth-is-a-personal-choice).
_task_artifact_route() {
  case "$1:${2:-full}" in
    T1:lean) printf '%s\n' 'analyze|task|task intent' 'implement|task|analysis sufficiency' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T2:lean) printf '%s\n' 'analyze|task|task intent' 'implement|task discovery|analysis and plan sufficiency' 'review|task discovery|implementation' 'verify|task discovery|implementation and review outcome' 'consolidate|task discovery|implementation, review and verification outcomes' ;;
    T0:*) printf '%s\n' 'implement|task|task intent' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T1:*) printf '%s\n' 'analyze|task|task intent' 'implement|task discovery|analysis sufficiency' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T2:*) printf '%s\n' 'analyze|task|task intent' 'plan|task discovery|analysis sufficiency' 'implement|task plan|plan sufficiency' 'review|task plan|implementation' 'verify|task plan|implementation and review outcome' 'consolidate|task plan|implementation, review and verification outcomes' ;;
    T3:*) printf '%s\n' 'discover|task|task intent' 'design|task discovery|discovery sufficiency' 'human-gate|task design|human design decision' 'implement|task design|human design approval' 'architecture-review|task design|implementation' 'verify|task design|implementation and architecture review outcome' 'consolidate|task verification|implementation, review and verification outcomes' ;;
    T4:*) printf '%s\n' 'discover|task|task intent' 'specify|task discovery|discovery sufficiency' 'alternatives|task spec|specification sufficiency' 'design|task spec alternatives|alternatives evaluated' 'human-gate|task spec design|human design decision' 'implement|task spec design|human design approval' 'review|task spec design|implementation and independent reviewer' 'verify|task spec design|implementation and independent review outcome' 'consolidate|task verification|implementation, review and verification outcomes' ;;
  esac
}

task_artifacts() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage artifacts)"
  local id="$1" root class provided="" seen=0 kinds kind fact stage inputs semantic availability facts="" t depth
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
  depth=$(_task_route_depth "$id" | cut -f 1)
  printf 'task: %s; class: %s; depth: %s\nartifacts (optional unless consumed by a route stage):\n' "$id" "$class" "$depth"
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
  done < <(_task_artifact_route "$class" "$depth")
  printf 'Presence and provided claims do not prove approval, quality or completion; state unchanged.\n'
}

# --- artifact writes (ADR-0029: a worktree never writes through the link) ----

# The kinds `task artifact` will write. Wider than _task_artifact_kind above,
# which serves `--provided` and has no use for the rest:
#   - `task`: where jig-analyze puts its analysis and where an unattended run
#     records the gate it approved, so it is the most edited document of all;
#   - `knowledge-map`, `commit-message`, `pr-body`: documents the skills have
#     always written into the workspace (jig-map, jig-consolidate and a phase
#     run's task agents). Without a kind they could only be written around
#     jig, which is the one thing the skills forbid; a rule that cannot be
#     kept is broken. They are inputs to nothing `task artifacts` reports.
# The two predicates stay separate on purpose — widening the `--provided`
# vocabulary would let a caller claim an input that is never an input.
_task_artifact_writable_kind() {
  case "$1" in task | discovery | spec | alternatives | design | plan | review | verification | handoff | knowledge-map | commit-message | pr-body) return 0 ;; *) return 1 ;; esac
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
    || jig_die "task artifact: unknown kind: $kind (one of: task discovery spec alternatives design plan review verification handoff knowledge-map commit-message pr-body)"

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
  jig_cleanup_add "$tmp"
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

# _task_ship_git <id> — `<level><TAB><key>`: the git level `task ship` uses
# for <id>, and the key it came from. A task whose autopilot run is `on`, or
# `stopped` in an unattended run (whose repairs ran out: it ships its draft
# from there), ships at the run's level, jig_autopilot_git; every other ship
# at `agent.git`. An attended run that stopped is waiting for its person, who
# may well finish the task by hand: that ship is theirs, at their level. Read when it ships, not recorded at `start`: a person
# who lowers either key halfway through a run is obeyed at once. Exit 1 when
# the level is invalid, like jig_agent_git.
_task_ship_git() {
  local value
  case "$(task_state_get "$1" autopilot)" in
    on)
      jig_autopilot_git
      return
      ;;
    stopped)
      if [ "$(_task_autopilot_mode "$1")" = unattended ]; then
        jig_autopilot_git
        return
      fi
      ;;
  esac
  if value=$(jig_agent_git); then
    printf '%s\tagent.git\n' "$value"
  else
    printf '%s\tagent.git\n' "$value"
    return 1
  fi
}

# _task_ship_level_refusal <id> — why `jig task ship <id>` refuses at the git
# level it would ship at (_task_ship_git), or nothing: an invalid level, or
# `none`, where the human commits. Shared with the actions table
# (_task_actions); the command exits 3 for `none` and 1 for an invalid level.
_task_ship_level_refusal() {
  local line level key rc=0
  line=$(_task_ship_git "$1") || rc=$?
  IFS=$'\t' read -r level key <<EOF
$line
EOF
  if [ "$rc" -ne 0 ]; then
    printf 'task ship: invalid %s: %s (expected none|commit|push|pr|merge)\n' "$key" "$level"
  elif [ "$level" = none ]; then
    printf 'task ship: %s is none in this clone; the human commits\n' "$key"
  fi
  return 0
}

# _task_autopilot_git_line — `autopilot git: <level> (<key>)`, the level an
# autopilot run ships at and where it comes from, as `task autopilot start`
# and `task route` print it. An invalid value is named, never guessed.
_task_autopilot_git_line() {
  local line level key rc=0
  line=$(jig_autopilot_git) || rc=$?
  IFS=$'\t' read -r level key <<EOF
$line
EOF
  if [ "$rc" -eq 0 ]; then
    printf 'autopilot git: %s (%s)\n' "$level" "$key"
  else
    printf 'autopilot git: invalid %s %s (expected none|commit|push|pr|merge)\n' "$key" "$level"
  fi
}

# _task_ship_refusal <id> <draft> — why `jig task ship <id>` (with `--draft`
# when <draft> is 1) refuses this task by its state, or nothing when its gates
# pass. Shared with the actions table (_task_actions). The git level
# (_task_ship_level_refusal) is asked before it and the branch
# (_task_ship_branch_refusal) after it, by both; what a ship refuses by the
# checkout — another branch checked out, nothing staged — is the command's.
# Non-zero when a check could not be made: a guard that fails refuses.
#
# A draft completes nothing and is never merged (task_ship, and jig_ship_merge
# refuses one on its own): it is how an unattended run whose repairs ran out
# shows where it stopped — usually with the blocking finding still open — so
# the three completion gates are not asked for one.
_task_ship_refusal() {
  local id="$1" draft="$2" blocking msg
  if [ "$draft" -eq 0 ]; then
    if [ "$(task_state_get "$id" knowledge_consolidated)" != "true" ]; then
      printf 'task ship: requires knowledge_consolidated true; record the knowledge decision first: jig task set %s knowledge_consolidated true\n' "$id"
      return 0
    fi
    # Checked again, independently of knowledge_consolidated above (design §4):
    # a fix landed after consolidation can plant a new finding, and ADR-0030's
    # order check alone would not see it.
    blocking=$(_task_blocking_findings "$id") || return 1
    if [ -n "$blocking" ]; then
      printf 'task ship: %s\n' "$(_task_gate_blocking_message "$id" "$blocking")"
      return 0
    fi
    # Same independent recheck as the findings ledger above, for the same
    # reason: a receipt gone stale after knowledge_consolidated was set true —
    # a later code edit, or a re-review nobody ran — must still refuse here.
    msg=$(_task_receipt_gate_message "$id") || return 1
    if [ -n "$msg" ]; then
      printf 'task ship: %s\n' "$msg"
      return 0
    fi
    # And the route, for the same reason: the gate's approval goes stale the
    # moment the design changes after it, whenever that happens.
    msg=$(_task_route_evidence_refusal "$id" consolidate "task ship") || return 1
    [ -z "$msg" ] || printf '%s\n' "$msg"
  fi
  return 0
}

# _task_ship_branch_refusal <id> — why `jig task ship <id>` refuses this task
# for its branch, or nothing: a task not started, or one whose branch is its
# own base, has nothing of its own to ship. Asked after _task_ship_refusal, by
# the command and the actions table alike.
_task_ship_branch_refusal() {
  local id="$1" branch base
  branch=$(task_state_get "$id" branch)
  if [ -z "$branch" ]; then
    # shellcheck disable=SC2016 # the backticks quote a command for the reader
    printf 'task ship: %s has not been started (no branch); run `jig task start %s` first\n' "$id" "$id"
    return 0
  fi
  base=$(jig_task_base "$id")
  [ "$branch" != "$base" ] \
    || printf "task ship: %s's branch is its own base (%s); nothing task-specific to ship\n" "$id" "$base"
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
  _task_guard_write "$id" "task ship"

  # Level first, before anything else changes: an invalid value must refuse
  # exactly like every other check here, not read as "none" by accident.
  local level key line rc=0 refusal
  line=$(_task_ship_git "$id") || rc=$?
  IFS=$'\t' read -r level key <<EOF
$line
EOF
  refusal=$(_task_ship_level_refusal "$id") || exit 1
  [ "$rc" -eq 0 ] || jig_die "$refusal"

  if [ "$level" = none ]; then
    # To stderr and exit 3, not `jig_die` (exit 1): a skill reads 3 as "hand
    # this over to the human", not as a command that failed.
    printf '%s\n' "$refusal" >&2
    exit 3
  fi

  # The completion gates and the branch, as the actions table asks them; a
  # draft skips the gates (_task_ship_refusal).
  local blocking="" receipt_msg="" refusal
  refusal=$(_task_ship_refusal "$id" "$draft") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"
  # A task filed before route evidence was checked passes with a warning.
  [ "$draft" -eq 1 ] || _task_route_evidence_gate "$id" consolidate "task ship"

  local branch base cur
  refusal=$(_task_ship_branch_refusal "$id") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"
  branch=$(task_state_get "$id" branch)
  base=$(jig_task_base "$id")
  cur=$(_task_current_branch)
  [ "$cur" = "$branch" ] || jig_die "task ship: current branch is $cur, but $id is on $branch; switch branches first"

  # The tracker issue into the commit's first line and the pull request's
  # title, where trackers' VCS integrations look for it — written to a copy,
  # so the task's own commit-message artifact stays as its author wrote it.
  local issue subject named msg_tmp
  issue=$(task_state_get "$id" issue)
  if [ -n "$issue" ]; then
    subject=$(head -n 1 "$message_file")
    named=$(_task_issue_subject "$subject" "$issue")
    if [ "$named" != "$subject" ]; then
      msg_tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-msg.XXXXXX")
      jig_cleanup_add "$msg_tmp"
      { printf '%s\n' "$named"; tail -n +2 "$message_file"; } > "$msg_tmp"
      message_file="$msg_tmp"
      printf "task ship: issue %s added to the message's first line\n" "$issue"
    fi
    [ -z "$title" ] || title=$(_task_issue_subject "$title" "$issue")
  fi

  _task_ship_unverified_notice
  # Which key decided how far this goes: with autopilot.git and agent.git
  # apart, "stopped at push" alone would not say whose setting stopped it.
  printf 'task ship: git level %s (%s)\n' "$level" "$key"

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
  local missing
  if [ "$(task_state_get "$id" route_evidence)" = required ]; then
    missing=$(_task_route_evidence_list "$id" consolidate)
    if [ -n "$missing" ]; then
      printf 'not merged: the route of %s is missing: %s\n' "$id" "$missing"
      return 0
    fi
  fi
  local sha
  sha=$(git -C "$JIG_PROJECT" rev-parse HEAD)
  jig_ship_merge "task ship" "$JIG_SHIP_URL" "$sha" any
  # Merged here, so this checkout goes back to the base and the branch goes;
  # from the task's own worktree it stays for housekeeping
  # (adr-20261007-a-merged-branch-leaves-with-its-work).
  jig_ship_leave "task ship" "$branch" "$base" "$sha"
}

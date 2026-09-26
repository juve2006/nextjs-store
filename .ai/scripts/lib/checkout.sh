# shellcheck shell=bash
# checkout.sh — what is happening in this checkout
# (adr-20260924-a-checkout-records-what-is-happening-in-it).
#
# git has a primitive for "someone is using this tree" — `git worktree lock`,
# which housekeeping already reads as "a session may still be using it". It
# refuses the one tree that needs it most:
#
#   $ git worktree lock .
#   fatal: The main working tree cannot be locked or unlocked
#
# So jig writes down for itself what git will not hold: that a live agent
# session is working here. Two records, both under the checkout's own
# gitignored `.ai/runtime/`, both rewritten by every jig command:
#
#   runtime/working/<name>  one file per piece of work in progress here
#   runtime/checkout        what this checkout last told a reader
#
# **Only the incomputable is stored.** Which worktree the work is in, which
# branch it sits on and when it was last touched are all facts git or the
# filesystem answers better — `jig status` already prints `worktree=<path>`
# from `git worktree list` (ADR-0029), and the record's own mtime is when.
# What nothing can answer afterwards is which command ran, so that is the
# whole content. A stored copy of a computed fact is what
# conventions/required-records.md says to prefer the other way round.
#
# Nothing here may fail a command or print to stdout: a checkout note that can
# break `jig verify`, or prepend a line to output another script reads, is
# worse than the silence it replaces. Every path gives up with `return 0`, and
# the one message goes to stderr.

# _jig_checkout_ready — resolve the checkout this command is running in and
# succeed only in a jig project. Quiet where jig_require_init would die: the
# recorder runs before the command that is entitled to complain.
#
# **The root is always computed, never taken from the environment**, exactly as
# jig_require_repo computes it (conventions/shell.md: `pwd -P`, because git
# resolves symlinks and Windows spells paths differently). An inherited
# JIG_PROJECT is somebody else's answer, and trusting it made a record land in
# the wrong checkout: a jig command run under another jig inherits it, so the
# test suite run by `jig verify` wrote every one of its records into the
# repository being verified instead of each test's own tree. It was found in
# this repository's `.ai/runtime/told/`, holding session ids that only ever
# existed inside tests. A record about "what is happening here" may not take
# "here" on hearsay.
#
# Memoised privately, so the two calls the dispatcher makes cost one `git`
# between them. The memo is this file's own, never the environment's.
_JIG_CHECKOUT_PROJECT=""
_jig_checkout_ready() {
  local top
  if [ -z "$_JIG_CHECKOUT_PROJECT" ]; then
    top=$(jig_repo_root 2>/dev/null) || return 1
    [ -n "$top" ] || return 1
    _JIG_CHECKOUT_PROJECT=$(cd -P "$top" 2>/dev/null && pwd -P) || return 1
  fi
  JIG_PROJECT="$_JIG_CHECKOUT_PROJECT"
  [ -f "$JIG_PROJECT/$JIG_AI_DIR/config.yaml" ] || return 1
  return 0
}

_jig_checkout_runtime() { printf '%s/%s/runtime\n' "$JIG_PROJECT" "$JIG_AI_DIR"; }

# _jig_checkout_value <file> <key> — the first `<key>: <value>` line of a flat
# jig record, read by the shell alone.
#
# The rest of the codebase reads this format with `sed -n 's/^key: //p'`, and
# this reader exists only because of where it runs: before *every* jig
# command. A sed per key put four process starts on every command that does
# any work, and process starts are what took `jig status` from 4 s to 0.6 s
# when they were batched away (conventions/shell.md). A record is a handful of
# short lines, so the shell reads it for nothing.
#
# `|| [ -n "$line" ]` picks up a last line with no newline. The CR is stripped
# explicitly because `read` keeps it where sed would not, and this reader must
# answer the same as the rest of the codebase on a record written under
# Windows.
_jig_checkout_value() {
  local file="$1" key="$2"
  _jig_checkout_read "$file" "$key" || return 0
  printf '%s\n' "$_JIG_CHECKOUT_READ"
  return 0
}

# _jig_checkout_read <file> <key> — the same answer in _JIG_CHECKOUT_READ and
# without a subshell, for the one caller that asks once per record.
#
# `cmd=$(_jig_checkout_value …)` is a fork, and a fork per record is the same
# process-per-item shape as the `stat` above: batching `stat` alone left 500
# forks behind and most of the cost with them. A function that sets a variable
# is how shell avoids that (status.sh's `_ST_*` readers do it for the same
# reason), so the loop over a record directory now forks not at all.
_JIG_CHECKOUT_READ=""
_jig_checkout_read() {
  local file="$1" key="$2" line
  _JIG_CHECKOUT_READ=""
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "$key: "*)
        _JIG_CHECKOUT_READ=${line#"$key": }
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# The branch checked out here, empty when HEAD is detached. Read before the
# command runs, so `task start` cannot answer for the tree it is about to move.
#
# This one git call is the whole external cost of recording: everything else
# the recorder does is shell. Reading `.git/HEAD` directly would save it, the
# way jig_config_clone_root reads git's own files, but that puts a second
# implementation of ref resolution in the tree to save a few milliseconds off
# a command that is about to run git anyway.
_jig_checkout_head() {
  git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || printf ''
}

# --- naming the work ------------------------------------------------------------
#
# A record's file name is derived, never composed, in this order:
#
#   1. a task named by the command's arguments — `jig task show Y`;
#   2. otherwise the task whose branch is checked out here;
#   3. otherwise the runtime's own session id, when it gives one;
#   4. otherwise nothing, and no record is written.
#
# The name becomes a path, so it passes jig_valid_id first — the same check
# task_dir makes, for the same RULES.md invariant. Rule 1 additionally
# requires the workspace to exist, so a subcommand word can never be mistaken
# for an id, and no name can be invented by an argument.

# _jig_checkout_worktree_list — git's own answer to "where is each branch
# checked out", or nothing. Read from git, never from another checkout's
# `.ai/` (ADR-0029). One call serves a whole walk, so it is fetched by the
# caller rather than per record.
_jig_checkout_worktree_list() {
  git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null || printf ''
}

# _jig_checkout_branch_elsewhere <branch> <head> <list> — exit 0 when <branch>
# is checked out in some worktree that is not this one. A string test, no
# process of its own.
#
# Comparing the branch with this checkout's HEAD rather than comparing paths
# is deliberate: path spellings differ between git and the shell on Windows
# (conventions/shell.md), and the question needs no path at all — if the
# branch is not the one checked out here and git lists it anyway, it is
# checked out somewhere else.
_jig_checkout_branch_elsewhere() {
  local branch="$1" head="$2" list="$3"
  [ -n "$branch" ] || return 1
  [ -n "$list" ] || return 1
  [ "$branch" != "$head" ] || return 1
  jig_has_line "branch refs/heads/$branch" "$list"
}

# _jig_checkout_task_elsewhere <id> <head> <list> — exit 0 when <id> is a task
# of this checkout whose branch lives in another worktree.
_jig_checkout_task_elsewhere() {
  local id="$1" head="$2" list="$3" state
  state="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$id/state"
  [ -f "$state" ] || return 1
  _jig_checkout_read "$state" branch || return 1
  _jig_checkout_branch_elsewhere "$_JIG_CHECKOUT_READ" "$head" "$list"
}

# Rule 1, with the one exclusion the reviewer's measurement earned: **a task
# whose branch is checked out in another worktree is not work happening
# here.** Naming `jig task show T-2` from the main checkout as work here made
# one page of `jig status` say both `task T-2 … worktree=<path>` — read from
# git, ADR-0029 — and `working here: task T-2`. Reading about work elsewhere
# is not doing it.
_jig_checkout_name_from_args() {
  local head="$1" a list=""
  shift
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    jig_valid_id "$a" || continue
    [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$a/state" ] || continue
    # Asked of git only once a candidate exists, so an ordinary command pays
    # nothing for it.
    [ -n "$list" ] || list=$(_jig_checkout_worktree_list)
    if _jig_checkout_task_elsewhere "$a" "$head" "$list"; then continue; fi
    printf '%s\n' "$a"
    return 0
  done
  return 1
}

# The task whose branch is this checkout's HEAD. Deliberately not
# _task_candidates_for_branch: this runs on every jig command, and sourcing
# task.sh (109 KB) to answer it would put that cost on `jig version`. The
# narrower question here — is some live task sitting on this branch — needs
# neither the pause rules nor the ambiguity reporting that function owes its
# callers. `active | ready` is live, the same pair task.sh uses.
_jig_checkout_name_from_head() {
  local head="$1" d id branch status
  [ -n "$head" ] || return 1
  for d in "$JIG_PROJECT/$JIG_AI_DIR"/workspace/tasks/*/; do
    [ -f "$d/state" ] || continue
    id=${d%/}
    id=${id##*/}
    jig_valid_id "$id" || continue
    branch=$(_jig_checkout_value "$d/state" branch)
    [ "$branch" = "$head" ] || continue
    status=$(_jig_checkout_value "$d/state" status)
    case "$status" in
      active | ready)
        printf '%s\n' "$id"
        return 0
        ;;
    esac
  done
  return 1
}

# jig_checkout_session — the runtime's id for the session running this command,
# empty when it has none.
#
# Runtime-specific knowledge lives in adapters (ADR-0024), and exit 2 means
# "not applicable to this runtime", as it does for the session hook. Adapters
# live in the framework source, where init and upgrade read them from; an
# install whose source is not on this machine simply has no answer here.
#
# The libraries the lookup needs are sourced inside this command
# substitution's subshell, so nothing leaks into the process that asked — a
# recorder running on every command must not change what a command sees. The
# id is compared only with names of files jig wrote itself: it is never
# shown, never sent anywhere and never stored beyond its own file name.
# _jig_checkout_adapters_dir — the adapters directory this run can reach, or
# nothing.
#
# Adapters are not copied into `.ai/` (ADR-0003 installs what a project runs,
# and the adapters are the installer's own material), so they are found where
# init and upgrade find them: the framework source the manifest records. In a
# project installed from a checkout that is not on this machine there is
# nothing there — and then the jig that is running may itself be a framework
# checkout, which is the common case for a global install, so that is tried
# second. Whoever installed is no longer the only one the session id reaches.
#
# What is still not covered is a copy install driven through `.ai/scripts/jig`
# with the source gone. Reaching adapters there means installing them into the
# project, which is an install-surface decision of its own
# (adr-20260924-a-checkout-records-what-is-happening-in-it); until it is taken,
# `jig status` says the observation is unavailable rather than staying silent.
_jig_checkout_adapters_dir() {
  local src
  src=$(
    # shellcheck source=lib/manifest.sh
    . "$JIG_LIB/manifest.sh" 2>/dev/null || exit 0
    manifest_source 2>/dev/null || exit 0
  ) || src=""
  if [ -n "$src" ] && [ -d "$src/adapters" ]; then
    printf '%s/adapters\n' "$src"
    return 0
  fi
  src=$(jig_source_root 2>/dev/null) || src=""
  if [ -n "$src" ] && [ -d "$src/adapters" ]; then
    printf '%s/adapters\n' "$src"
    return 0
  fi
  return 1
}

jig_checkout_session() {
  (
    root=$(_jig_checkout_adapters_dir) || exit 0
    # shellcheck source=lib/profiles.sh
    . "$JIG_LIB/profiles.sh" 2>/dev/null || exit 0
    for a in $(cfg_list adapters "claude codex"); do
      adir=$(adapters_dir "$root" "$a") || continue
      [ -f "$adir/adapter.sh" ] || continue
      # shellcheck disable=SC1090
      . "$adir/adapter.sh" 2>/dev/null || continue
      command -v "adapter_${a}_session_id" >/dev/null 2>&1 || continue
      id=$("adapter_${a}_session_id" 2>/dev/null) || continue
      [ -n "$id" ] || continue
      jig_valid_id "$id" || continue
      printf '%s\n' "$id"
      exit 0
    done
    exit 0
  ) 2>/dev/null
}

# jig_checkout_session_problem — why this checkout cannot tell one session from
# another, or nothing when it can.
#
# A reader who is told nothing cannot tell "nobody else is here" from "there is
# no way to see anybody". The framework already refuses that ambiguity for the
# session hook, whose adapter capability uses the same exit 2 and which
# `jig status` reports either way (ADR-0024), so this one says it too. The two
# answers are kept apart because they are different problems: one is a runtime
# that does not name its sessions, which is a named boundary; the other is an
# install that cannot reach the adapters, which is a gap.
jig_checkout_session_problem() {
  local root
  if ! root=$(_jig_checkout_adapters_dir); then
    printf 'the framework source that holds the adapters is not on this machine\n'
    return 0
  fi
  [ -z "$(jig_checkout_session)" ] || return 0
  printf 'no active runtime names its sessions here\n'
  return 0
}

# --- freshness ------------------------------------------------------------------

# How long a record still counts as a live session. Long on purpose: a stale
# record costs one worktree nobody needed, a missed one costs another session's
# HEAD (design §8). A live session refreshes its own record with every jig
# command it runs, so a generous window does not keep a finished session alive.
#
# One duration grammar for the whole framework: jig_duration_seconds, which
# dies on anything else — here the death is caught and the default stands,
# because a mistyped setting must not take a command down with it.
_jig_checkout_ttl() {
  local raw seconds
  raw=$(cfg checkout.busy_ttl "12h")
  seconds=$(jig_duration_seconds "$raw" 2>/dev/null) || seconds=""
  case "$seconds" in
    '' | *[!0-9]*) seconds=43200 ;;
  esac
  printf '%s\n' "$seconds"
}

# _jig_checkout_mtimes <file>... — "<mtime> <path>" per file, in **one**
# process for the whole set. The same stat pair the session hook uses, BSD
# first and GNU second, neither mandatory beyond what ADR-0002 allows.
#
# One call, not one per file: a `stat` and a `date` inside the loop is the
# process-per-item shape conventions/shell.md forbids, and the cost is not
# hypothetical, because nothing here deletes an expired record. Measured on
# `jig status`: 1.77 s of CPU with one record against 8.46 s with 500. The
# whole directory now costs two processes, whatever it holds.
_jig_checkout_mtimes() {
  stat -f '%m %N' "$@" 2>/dev/null && return 0
  stat -c '%Y %n' "$@" 2>/dev/null && return 0
  return 0
}

# A short "40s"/"12m"/"3h" for a message. Whole units only: the reader is
# deciding whether someone is around, not measuring.
jig_checkout_ago() {
  local s="$1"
  if [ "$s" -lt 60 ]; then
    printf '%ds\n' "$s"
    return 0
  fi
  if [ "$s" -lt 3600 ]; then
    printf '%dm\n' $((s / 60))
    return 0
  fi
  printf '%dh\n' $((s / 3600))
}

# --- writing --------------------------------------------------------------------

# tmp then mv, as _task_rewrite_state writes state (conventions/shell.md): a
# reader sees the old record or the new one, never a torn one.
#
# The temporary is named `.tmp.<file>.<pid>`, with the leading dot, where
# state.sh writes `state.tmp.$$`. The dot is not decoration: a process killed
# between the write and the rename leaves the temporary behind, and
# `working/` is read as a plain glob of record names. `<id>.tmp.1234` passes
# jig_valid_id — dots are legal in an id — so it would be listed as a
# neighbour that never existed, and later refused for. A dotfile is outside
# the glob, so a leftover is invisible to every reader.
_jig_checkout_write() {
  local file="$1" body="$2" dir base tmp
  dir=${file%/*}
  base=${file##*/}
  tmp="$dir/.tmp.$base.$$"
  printf '%s' "$body" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  mv "$tmp" "$file" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

# jig_checkout_record <command-words...> — called by the dispatcher before the
# command runs. Writes at most two records and prints nothing.
jig_checkout_record() {
  _jig_checkout_record_inner "$@" || true
  return 0
}

_jig_checkout_record_inner() {
  local runtime head name told body
  _jig_checkout_ready || return 0
  runtime=$(_jig_checkout_runtime)
  [ -d "$runtime" ] || mkdir -p "$runtime" 2>/dev/null || return 0
  head=$(_jig_checkout_head)

  # The checkout's own record. `branch_reported` is carried over untouched:
  # it is the one fact here that is about a reader's knowledge rather than the
  # tree's state, and only the commands that print the notice may move it.
  told=$(_jig_checkout_value "$runtime/checkout" branch_reported)
  body="command: $*
"
  if [ -n "$told" ]; then
    body="$body""branch_reported: $told
"
  fi
  _jig_checkout_write "$runtime/checkout" "$body" || true

  name=""
  if ! name=$(_jig_checkout_name_from_args "$head" "$@"); then
    if ! name=$(_jig_checkout_name_from_head "$head"); then
      name=$(jig_checkout_session)
    fi
  fi
  [ -n "$name" ] || return 0
  jig_valid_id "$name" || return 0
  [ -d "$runtime/working" ] || mkdir -p "$runtime/working" 2>/dev/null || return 0
  _jig_checkout_write "$runtime/working/$name" "command: $*
" || true
  return 0
}

# --- reading --------------------------------------------------------------------

# _jig_checkout_orienting <command-words...> — exit 0 for the commands a
# session reads to find out where it is. They are the ones that owe a reader
# the notice below, and they are named here rather than in the dispatcher:
# which commands orient a reader is a fact about this record, not about
# dispatching.
#
# `task start` is deliberately absent. It is the command that moves HEAD, and
# printing the notice there would swallow the message meant for its neighbour.
_jig_checkout_orienting() {
  case "${1:-}" in
    status) return 0 ;;
    task)
      case "${2:-}" in
        current | list) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# _jig_checkout_told_file — where the reader running this command keeps the
# branch it was last told about.
#
# **Per session when the runtime names one**, and only shared when it does
# not. What a reader knows is a fact about that reader, so one shared key is
# answered by whoever looks first — including the session that moved HEAD in
# the first place, which then consumes the only message its neighbour would
# ever get. Measured: `task start T-1` followed by `task current` in the same
# session took the message for itself and left the neighbour's `jig status`
# silent. A session that switched the branch itself still gets one true line;
# what it can no longer do is eat somebody else's.
#
# One file per session, so two sessions never rewrite each other's answer —
# the same reason the work records are one file per piece of work.
_jig_checkout_told_file() {
  local runtime="$1" session="$2"
  if [ -n "$session" ]; then
    printf '%s/told/%s\n' "$runtime" "$session"
  else
    printf '%s/checkout\n' "$runtime"
  fi
}

# jig_checkout_notice <command-words...> — print the one line a session is
# owed when HEAD moved under it, and record that it has now been told.
#
# The second line matters as much as the first. Switching the branch back
# pulls the tree out from under the session that just started work on it; the
# way out is to give that task a worktree of its own.
#
# stderr, not stdout: `jig task current` prints an id that callers read as one
# (ADR-0012), and an advisory must not become part of it.
jig_checkout_notice() {
  _jig_checkout_orienting "$@" || return 0
  _jig_checkout_notice_inner || true
  return 0
}

_jig_checkout_notice_inner() {
  local runtime file head told body cmd session
  _jig_checkout_ready || return 0
  runtime=$(_jig_checkout_runtime)
  head=$(_jig_checkout_head)
  [ -n "$head" ] || return 0
  session=$(jig_checkout_session)
  file=$(_jig_checkout_told_file "$runtime" "$session")

  told=$(_jig_checkout_value "$file" branch_reported)
  if [ "$told" = "$head" ]; then
    return 0
  fi
  if [ -n "$told" ]; then
    printf 'checkout: HEAD here moved %s -> %s since you were told\n' "$told" "$head" >&2
    printf '  another session may be working on this checkout; to give the branch\n' >&2
    printf '  back, move that task to a worktree of its own — do not just switch\n' >&2
    printf '  this checkout back under it\n' >&2
  fi

  # A session's own file holds this one key and nothing else. The shared file
  # is the checkout's record, so its `command:` is rewritten with it —
  # from its parts rather than edited, which keeps one writer for one format.
  if [ -n "$session" ]; then
    [ -d "$runtime/told" ] || mkdir -p "$runtime/told" 2>/dev/null || return 0
    _jig_checkout_write "$file" "branch_reported: $head
" || true
    return 0
  fi
  body=""
  cmd=$(_jig_checkout_value "$file" command)
  if [ -n "$cmd" ]; then
    body="command: $cmd
"
  fi
  [ -d "$runtime" ] || mkdir -p "$runtime" 2>/dev/null || return 0
  _jig_checkout_write "$file" "$body""branch_reported: $head
" || true
  return 0
}

# jig_checkout_busy [<id to ignore>] — "<name> <seconds> <command>" for every
# live record of work in this checkout, excluding the caller's own two names:
# the task it is about to start, and this session's own id.
#
# A record older than the window is ignored rather than deleted. RULES.md lets
# a script delete only a path it has checked to be a workspace or a trash
# entry, and a file under runtime/working/ is neither; cleaning up after it is
# a decision of its own, with its own line in that document.
jig_checkout_busy() {
  local ignore="${1:-}" runtime ttl self now head list mtime f name age cmd
  _jig_checkout_ready || return 0
  runtime=$(_jig_checkout_runtime)
  [ -d "$runtime/working" ] || return 0
  ttl=$(_jig_checkout_ttl)
  self=$(jig_checkout_session)
  now=$(date +%s)
  head=$(_jig_checkout_head)
  list=$(_jig_checkout_worktree_list)

  while read -r mtime f; do
    case "$mtime" in '' | *[!0-9]*) continue ;; esac
    [ -f "$f" ] || continue
    name=${f##*/}
    # A walk over what is on disk checks every name with the validator that
    # put it there and skips what fails, never trusting the directory
    # (conventions/shell.md). Here it also keeps the output parsable: a caller
    # reads these lines with `read -r name age cmd`, and a file name holding a
    # space or a newline would silently become a different record.
    jig_valid_id "$name" || continue
    [ "$name" != "$ignore" ] || continue
    if [ -n "$self" ] && [ "$name" = "$self" ]; then continue; fi
    # A record is filtered here as well as at the point it is written,
    # because it can become wrong afterwards — and does, in the one case that
    # matters most: `jig task start <id> --worktree` runs *here*, records the
    # work before the tree exists, and leaves the branch somewhere else a
    # moment later. The reader is where the contradiction would be visible,
    # so it is also where it is settled.
    if _jig_checkout_task_elsewhere "$name" "$head" "$list"; then continue; fi
    if [ "$now" -lt "$mtime" ]; then age=0; else age=$((now - mtime)); fi
    [ "$age" -le "$ttl" ] || continue
    cmd=""
    if _jig_checkout_read "$f" command; then cmd="$_JIG_CHECKOUT_READ"; fi
    [ -n "$cmd" ] || cmd="jig"
    printf '%s %s %s\n' "$name" "$age" "$cmd"
  done < <(_jig_checkout_mtimes "$runtime"/working/*)
  return 0
}

# jig_checkout_here_task — the task whose branch is checked out here, empty
# when none is. `jig status` excludes it from the list of work going on here:
# the reader is sitting on it and does not need to be told.
#
# The refusal in `task start` deliberately does *not* exclude it. Two sessions
# in one checkout, one of them on another task's branch, is the case that has
# to be caught, and hiding that task's record would hide exactly it.
jig_checkout_here_task() {
  _jig_checkout_ready || return 0
  _jig_checkout_name_from_head "$(_jig_checkout_head)" || printf ''
}

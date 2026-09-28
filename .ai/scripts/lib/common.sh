# Shared helpers for every jig command. Sourced by scripts/jig.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

JIG_AI_DIR=".ai"
export JIG_AI_DIR

# --- output --------------------------------------------------------------

jig_log()  { [ -n "${JIG_QUIET:-}" ] || printf '%s\n' "$*"; }
jig_info() { [ -n "${JIG_QUIET:-}" ] || printf 'jig: %s\n' "$*" >&2; }
jig_warn() { printf 'jig: warning: %s\n' "$*" >&2; }
jig_die()  {
  printf 'jig: error: %s\n' "$*" >&2
  # A command that changed a task and then failed still redraws the status
  # page, so the page never shows less than the files do.
  jig_status_page_flush
  exit 1
}

# --- repository ------------------------------------------------------------

# Remove the environment variables that tell git which repository to work on,
# so every git jig runs acts on the checkout jig is standing in.
#
# `git rev-parse --show-toplevel` asks the environment first, and `git -C
# <dir>` does not override it: with GIT_DIR and GIT_WORK_TREE pointing at
# another repository and the working directory untouched, every record jig
# wrote landed in that other repository and none in this one — measured. The
# layer above this one had the same bug with an inherited JIG_PROJECT
# (adr-20260924-a-checkout-records-what-is-happening-in-it), and a component
# that describes its own surroundings may not learn them from somebody else,
# at either layer.
#
# The list is git(1) "The Git Repository", read rather than recalled, kept to
# the variables that choose *what* git acts on:
#   GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR  the repository and its tree
#   GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES  where objects go
#   GIT_INDEX_FILE                          the index add and commit see
#   GIT_NAMESPACE                           which refs exist
#   GIT_CEILING_DIRECTORIES                 how far discovery walks up
#   GIT_DISCOVERY_ACROSS_FILESYSTEM         whether it crosses a mount point
# All of them or none: clearing GIT_DIR while GIT_OBJECT_DIRECTORY stands
# commits into this repository and writes the objects into another one, which
# is worse than either end of the choice.
#
# The line is location, not configuration. GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM,
# GIT_CONFIG_NOSYSTEM and GIT_CONFIG_COUNT/KEY/VALUE can redirect a work tree
# too, through core.worktree, but they are how a person configures git on
# purpose — tests/run.sh isolates a run with GIT_CONFIG_NOSYSTEM — and jig
# reads the configuration of the repository it found. It decides which
# repository it is in; it does not decide how that repository is set up.
#
# Variables that only change a format or a default (GIT_INDEX_VERSION,
# GIT_DEFAULT_HASH, GIT_DEFAULT_REF_FORMAT) and those that change behaviour
# without changing the address are left alone.
jig_clear_git_location_env() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_INDEX_FILE GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
}

# Print the git repository root of the current directory or fail.
#
# The clearing belongs to the callers below, not here: this runs inside
# `$(jig_repo_root)`, a subshell, where an unset would not outlive the one
# command it guards.
jig_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# Set JIG_PROJECT to the repository root; die when not inside a repository.
#
# The root is made physical in bash's own spelling. Git for Windows prints
# C:/Users/..., while every path bash builds is /c/Users/...; a symlink target
# computed between the two, or a prefix comparison, finds no common part —
# `init --link` produced ../../../../d/a/jig/jig/scripts, dangling, on the
# same drive. git already resolves symlinks on macOS and Linux, so this
# changes nothing there.
#
# Clears the git location variables first, for the callers that reach the
# library without the dispatcher — the test suite sources common.sh and calls
# this directly. The dispatcher has already cleared them by the time a command
# runs, and `unset` twice costs nothing.
jig_require_repo() {
  local top
  jig_clear_git_location_env
  top=$(jig_repo_root) || jig_die "not inside a git repository"
  JIG_PROJECT=$(cd -P "$top" 2>/dev/null && pwd -P) \
    || jig_die "cannot resolve the repository root: $top"
  export JIG_PROJECT
}

# jig_valid_id <id> — the grammar of a name that becomes a directory under
# .ai/: a task id and a spec id. Both must agree, because a spec's roadmap
# names task ids and a spec id follows task id rules; two copies of the case
# below would be free to drift.
# No leading dot: rules out `.`, `..` and hidden directories, which the `*/`
# walks over workspaces and specs would not see.
# No leading dash: every subcommand reads its id from the first argument, so
# `-x` is a flag in the wrong place, never a name. `jig task new --help` used
# to file a workspace named `--help`.
jig_valid_id() {
  case "$1" in
    '' | .* | -* | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Die unless the project has been initialised with jig init.
# jig_has_line <line> <text> — exit 0 when <line> is a whole line of <text>,
# compared as a string. A `case`, never `printf | grep -qxF`: bash writes a
# pipe line by line, and under pipefail the SIGPIPE a reader that quit early
# leaves printf with turns a match into a failure (conventions/shell.md).
jig_has_line() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

jig_require_init() {
  jig_require_repo
  [ -f "$JIG_PROJECT/$JIG_AI_DIR/config.yaml" ] \
    || jig_die "project is not initialised; run: jig init"
}

# True when <dir> is a framework source checkout (has skills/ and templates/).
jig_is_source_root() {
  [ -d "$1/skills" ] && [ -d "$1/templates" ] && [ -f "$1/scripts/jig" ]
}

# Best-effort framework source root: the checkout this script runs from, or
# JIG_SOURCE, or empty when running from an installed copy.
jig_source_root() {
  local candidate
  candidate=$(cd "$JIG_LIB/../.." && pwd)
  if jig_is_source_root "$candidate"; then
    printf '%s\n' "$candidate"
  elif [ -n "${JIG_SOURCE:-}" ] && jig_is_source_root "$JIG_SOURCE"; then
    printf '%s\n' "$JIG_SOURCE"
  fi
}

# --- framework versions and the global executable -------------------------
#
# Release tags are the update channel: a release is `v<major>.<minor>.<patch>`,
# digits only, and the newest one is what `install.sh` installs and what
# `jig self-update` moves to. Versions are ordered in shell arithmetic because
# `sort -V` is not available everywhere jig runs (conventions/shell.md).

# jig_release_version <tag> — the `X.Y.Z` of release tag `vX.Y.Z`. Prints
# nothing and fails for anything else: a pre-release suffix, a stray tag, a
# version with more or fewer than three fields.
jig_release_version() {
  local v a b c rest
  case "$1" in
    v*) v="${1#v}" ;;
    *) return 1 ;;
  esac
  case "$v" in
    '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  IFS=. read -r a b c rest <<EOF
$v
EOF
  if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -n "$rest" ]; then
    return 1
  fi
  printf '%s\n' "$v"
}

# jig_version_newer <a> <b> — true when release version <a> (`X.Y.Z`) is
# strictly newer than <b>, comparing each field as a number: 0.10.0 is newer
# than 0.9.0. False for equal versions and for anything that is not three
# numeric fields, so an unparsable version never reads as an upgrade.
jig_version_newer() {
  local a1 a2 a3 b1 b2 b3
  jig_release_version "v$1" >/dev/null || return 1
  jig_release_version "v$2" >/dev/null || return 1
  IFS=. read -r a1 a2 a3 <<EOF
$1
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$2
EOF
  # 10#: a field with a leading zero is still decimal, not octal.
  a1=$((10#$a1)); a2=$((10#$a2)); a3=$((10#$a3))
  b1=$((10#$b1)); b2=$((10#$b2)); b3=$((10#$b3))
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

# jig_newest_release — read tag names on stdin, one per line, and print the
# newest release tag (`vX.Y.Z`). Accepts `git tag` names and `git ls-remote
# --tags` lines alike: a `refs/tags/` prefix and the `^{}` of a peeled
# annotated tag are stripped. Fails, printing nothing, when no line is a
# release tag.
jig_newest_release() {
  local line tag v best="" best_v=""
  while IFS= read -r line; do
    tag=${line##*refs/tags/}
    tag=${tag%'^{}'}
    v=$(jig_release_version "$tag") || continue
    if [ -z "$best_v" ] || jig_version_newer "$v" "$best_v"; then
      best="$tag"
      best_v="$v"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# jig_version_of <executable> — the version a jig executable reports, taken
# only from a single line shaped exactly `jig <version>`. Fails otherwise, so
# a wrapper or an unrelated `jig` on PATH is never mistaken for a version.
jig_version_of() {
  local out
  out=$("$1" version 2>/dev/null) || return 1
  case "$out" in
    *'
'*) return 1 ;;
    'jig '?*) printf '%s\n' "${out#jig }" ;;
    *) return 1 ;;
  esac
}

# jig_declared_version <source> — the version a framework checkout declares in
# scripts/lib/version.sh, read without running anything. Fails unless exactly
# one line is shaped `JIG_VERSION="<version>"` with a value free of quotes and
# spaces. `jig status` uses this rather than jig_version_of: a read-only
# command must not execute whatever PATH selects, and a broken global checkout
# would otherwise hang it, with no portable timeout to bound the wait.
jig_declared_version() {
  local file="$1/scripts/lib/version.sh" found
  [ -f "$file" ] || return 1
  found=$(sed -n 's/^JIG_VERSION="\([^" ]\{1,\}\)"[[:space:]]*$/\1/p' "$file" 2>/dev/null) \
    || return 1
  case "$found" in
    '' | *'
'*) return 1 ;;
  esac
  printf '%s\n' "$found"
}

# jig_global_executable — the physical path of the `jig` the current PATH
# selects, when it is the dispatcher of a framework source checkout. Fails,
# printing nothing, when PATH has no `jig` or it resolves anywhere else.
#
# Symlinks are resolved with the dispatcher's own jig_resolve_path, defined in
# scripts/jig before any library is sourced; it is reused rather than copied
# here, because two resolvers would drift. Directories are then made physical
# (conventions/shell.md), so the path compares equal to JIG_SELF resolved the
# same way — equal means the same checkout, as in link mode.
jig_global_executable() {
  local found path dir
  found=$(command -v jig 2>/dev/null) || return 1
  case "$found" in
    /*) ;;
    *) return 1 ;;
  esac
  path=$(jig_resolve_path "$found") || return 1
  dir=$(cd -P "${path%/*}" 2>/dev/null && pwd -P) || return 1
  path="$dir/${path##*/}"
  case "$path" in
    */scripts/jig) ;;
    *) return 1 ;;
  esac
  jig_is_source_root "${path%/scripts/jig}" || return 1
  printf '%s\n' "$path"
}

# --- directory links ----------------------------------------------------------

# How this machine links one directory to another: symlink, junction or none.
# Set by jig_link_detect, once per process. Cleared here so that a value in the
# caller's environment is never taken for a measurement.
_JIG_LINK_KIND=""

# jig_link_detect — measure which kind of directory link works here and keep it
# in _JIG_LINK_KIND. Not a `$(...)` helper: the answer must outlive the call.
#
# `ln -s` is never trusted to have made a link. Git Bash on Windows copies by
# default, and a copied task workspace diverges from its first write — two
# `state` files, and housekeeping keeping the worktree forever, because a copy
# is "a workspace of its own" (ADR-0029). Where symlinks are unavailable an
# NTFS junction needs no privilege; bash reads it as a link (`-L`,
# `find -type l`), and `git worktree remove` and `rm -rf` remove the junction
# without touching its target (measured on windows-latest, 2026-09-14).
jig_link_detect() {
  [ -z "$_JIG_LINK_KIND" ] || return 0
  local dir
  _JIG_LINK_KIND=none
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jig-link-probe.XXXXXX") || return 0
  mkdir "$dir/target" || { rm -rf "$dir"; return 0; }
  if ln -s "$dir/target" "$dir/symlink" 2>/dev/null && [ -L "$dir/symlink" ]; then
    _JIG_LINK_KIND=symlink
  elif _jig_junction "$dir/target" "$dir/junction" && [ -L "$dir/junction" ]; then
    _JIG_LINK_KIND=junction
  fi
  rm -rf "$dir"
  return 0
}

# _jig_junction <target-abs> <link-abs> — an NTFS junction made by cmd.exe.
# MSYS rewrites mklink's `/J` into a path unless argument conversion is off,
# and cmd.exe needs both paths in Windows form.
_jig_junction() {
  local target link
  command -v cmd >/dev/null 2>&1 || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  target=$(cygpath -w "$1") || return 1
  link=$(cygpath -w "$2") || return 1
  MSYS2_ARG_CONV_EXCL='*' cmd /c mklink /J "$link" "$target" >/dev/null 2>&1
}

# jig_link_dir <target-abs> <link-abs> — link <link-abs> to the existing
# directory <target-abs> with the kind jig_link_detect found. Non-zero when no
# kind works, or when what was made does not read as a link.
jig_link_dir() {
  jig_link_detect
  case "$_JIG_LINK_KIND" in
    symlink) ln -s "$1" "$2" 2>/dev/null || return 1 ;;
    junction) _jig_junction "$1" "$2" || return 1 ;;
    *) return 1 ;;
  esac
  [ -L "$2" ]
}

# How this machine copies a directory fastest: the `cp` flags in
# _JIG_COPY_FLAGS, with a one-word name for reports in _JIG_COPY_KIND. Set by
# jig_copy_detect, once per process. Cleared here so that a value in the
# caller's environment is never taken for a measurement.
_JIG_COPY_FLAGS=""
_JIG_COPY_KIND=""

# jig_copy_detect — measure which copy flags this `cp` understands and keep
# them in _JIG_COPY_FLAGS. Not a `$(...)` helper: the answer must outlive the
# call (mirrors jig_link_detect).
#
# A capability, never a platform (ADR-0037). Two flags ask the filesystem for
# a copy-on-write clone instead of duplicating the bytes: `-c` (clonefile) on
# macOS and the BSDs, `--reflink=auto` on GNU coreutils. Neither can be probed
# by its result — both fall back to a full copy in silence when the filesystem
# cannot clone, which is exactly what makes them safe to pass blindly, and
# what makes "did it clone?" unanswerable. So the probe asks the only question
# that has an answer: does this `cp` accept the flag at all. Git Bash on
# Windows accepts neither and copies honestly.
#
# Measured 2026-09-24 on APFS, a 26,861-file vendor tree: 5.35s and 11MB of
# disk with `-c`, against 12.27s and 210MB without it.
jig_copy_detect() {
  [ -z "$_JIG_COPY_KIND" ] || return 0
  local dir
  _JIG_COPY_FLAGS="-a"
  _JIG_COPY_KIND="copy"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jig-copy-probe.XXXXXX") || return 0
  if printf 'x\n' > "$dir/probe" 2>/dev/null; then
    if cp -c "$dir/probe" "$dir/clone" >/dev/null 2>&1; then
      _JIG_COPY_FLAGS="-a -c"
      _JIG_COPY_KIND="clone"
    elif cp --reflink=auto "$dir/probe" "$dir/reflink" >/dev/null 2>&1; then
      _JIG_COPY_FLAGS="-a --reflink=auto"
      _JIG_COPY_KIND="clone"
    fi
  fi
  rm -rf "$dir"
  return 0
}

# jig_copy_dir <src-abs> <dst-abs> — copy a file or directory tree with the
# flags jig_copy_detect found, preserving symlinks as symlinks rather than
# following them. Non-zero when the copy failed.
#
# Hard links (`cp -R -l`) were measured and rejected: 11.64s against 12.27s
# for a full copy, and no more disk saved than a clone. A tenth of the time is
# not what a framework takes the risk of an in-place edit reaching the
# neighbouring tree for.
jig_copy_dir() {
  jig_copy_detect
  # Word splitting is the point: the flags are the framework's own, never a
  # caller's data.
  # shellcheck disable=SC2086
  cp $_JIG_COPY_FLAGS "$1" "$2" 2>/dev/null
}

# jig_physical_path <file> — <file> with its directory made physical.
jig_physical_path() {
  local dir
  dir=$(cd -P "${1%/*}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "${1##*/}"
}

# jig_task_base <task-id> — the branch a task was cut from and has to land on:
# `base_branch` from its state file, or `git.base_branch` when the task never
# recorded one (not started, or started before the field existed). One answer
# for `task`, `housekeeping`, `context` and `knowledge`, which must never
# disagree about what a task is judged against (ADR-0039). The state file is
# the task domain's; reading it here is allowed, writing it is not. An id that
# is not a task id gets the configured base, never a path built from it.
jig_task_base() {
  local id="${1:-}" file value=""
  if jig_valid_id "$id"; then
    file="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$id/state"
    if [ -f "$file" ]; then
      value=$(sed -n 's/^base_branch:[[:space:]]*//p' "$file" | head -n 1)
    fi
  fi
  [ -n "$value" ] || value=$(cfg git.base_branch main)
  printf '%s\n' "$value"
}

# jig_base_ref <name> — the ref a base branch is judged by:
# refs/remotes/origin/<name> when it exists, else refs/heads/<name>, else
# nothing. Origin first because landed means landed on the remote: a local
# base can be behind it (a teammate who never fetched the branch) or ahead of
# it (commits nobody pushed), and a bare name lets git pick the local one.
jig_base_ref() {
  local name="${1:-}"
  [ -n "$name" ] || return 0
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$name^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "refs/remotes/origin/$name"
  elif git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$name^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "refs/heads/$name"
  fi
  return 0
}

# jig_git_show_path <ref> <path> — the content of <path> as committed at <ref>,
# on stdout; non-zero when <ref> names no commit or <path> is not in it.
# The ref is resolved to a commit SHA first and git is handed `<sha>:<path>`,
# never `<ref>:<path>`: under Git Bash (MSYS) an argument holding both `/`
# and `:` — `epic/idea-x:.ai/specs/...` — is rewritten as a path list before
# git sees it, so a ref with `/` in its name read nothing on Windows.
jig_git_show_path() {
  local sha
  sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
  [ -n "$sha" ] || return 1
  git -C "$JIG_PROJECT" show "$sha:$2"
}

# jig_fresh_base_ref <name> <who> — the ref to cut from <name>: the fresher of
# refs/heads/<name> and refs/remotes/origin/<name>, or HEAD when neither exists.
#
# Freshest, not nearest: resolving refs/heads/<base> first meant a local base
# that had fallen behind produced a stale branch *and* a stale base_commit,
# silently. That happened on 2026-09-11 — a branch was cut from the previous
# merge and the work done on it was missing a command merged an hour earlier.
# Diverged refs are refused rather than guessed: picking either surprises
# somebody, and the surprise surfaces far from its cause. <who> prefixes the
# messages (`task start`, `spec epic`). Shared because a task and an epic are
# both cut this way, and must never disagree about which commit is fresh.
jig_fresh_base_ref() {
  local base="$1" who="$2" local_ref remote_ref has_local=0 has_remote=0
  local_ref="refs/heads/$base"
  remote_ref="refs/remotes/origin/$base"
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$local_ref" >/dev/null 2>&1 && has_local=1
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$remote_ref" >/dev/null 2>&1 && has_remote=1

  if [ "$has_local" = 1 ] && [ "$has_remote" = 1 ]; then
    if git -C "$JIG_PROJECT" merge-base --is-ancestor "$local_ref" "$remote_ref" 2>/dev/null; then
      if ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$remote_ref" "$local_ref" 2>/dev/null; then
        jig_info "$who: local $base is behind origin/$base; branching from origin/$base"
        printf '%s\n' "$remote_ref"
      else
        printf '%s\n' "$local_ref"
      fi
    elif git -C "$JIG_PROJECT" merge-base --is-ancestor "$remote_ref" "$local_ref" 2>/dev/null; then
      printf '%s\n' "$local_ref"
    else
      jig_die "$who: $base and origin/$base have diverged; reconcile them first"
    fi
  elif [ "$has_local" = 1 ]; then
    printf '%s\n' "$local_ref"
  elif [ "$has_remote" = 1 ]; then
    printf '%s\n' "$remote_ref"
  else
    printf 'HEAD\n'
  fi
}

# jig_fetch_branches <who> <name>... — refresh origin/<name> for each branch
# from origin, one at a time, so that a branch origin does not have fails
# alone. Does nothing without an origin. A failure is a warning, never fatal:
# the caller goes on with the refs it has, and says what it decided from them.
# GIT_TERMINAL_PROMPT=0: a command that only wanted fresh refs must not stop
# and wait for a password.
jig_fetch_branches() {
  local who="$1" name
  shift
  git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1 || return 0
  for name in "$@"; do
    [ -n "$name" ] || continue
    if ! GIT_TERMINAL_PROMPT=0 git -C "$JIG_PROJECT" fetch --quiet origin \
         "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1; then
      jig_warn "$who: could not fetch $name from origin; using the refs this checkout has"
    fi
  done
  return 0
}

# --- forge -------------------------------------------------------------------

# jig_forge_kind — which forge CLI this checkout should use: cfg `forge`
# (auto|github|gitlab|none, default auto) resolved against the origin URL
# when auto, then confirmed actually usable here — the CLI on PATH and
# authenticated. Prints github|gitlab|none; dies only on an unrecognised
# `forge` value, the one case a caller cannot paper over with "none".
#
# Shared rather than kept in housekeeping.sh: `housekeeping`'s remote-state
# tier and the pull-request step of `task ship` and `spec ship` (jig_ship_pr)
# all have to agree on which forge this checkout uses, and one command library
# never sources another (ARCHITECTURE.md, Scripts layout) — so the decision
# common to them lives here.
jig_forge_kind() {
  local want origin
  want=$(cfg forge auto)
  case "$want" in
    none) printf 'none\n'; return 0 ;;
    auto|github|gitlab) ;;
    *) jig_die "invalid forge: $want (expected auto|github|gitlab|none)" ;;
  esac

  origin=$(git -C "$JIG_PROJECT" remote get-url origin 2>/dev/null || printf '')
  if [ -z "$origin" ]; then
    printf 'none\n'
    return 0
  fi

  if [ "$want" = "auto" ]; then
    case "$origin" in
      *github.com*) want="github" ;;
      *gitlab.com*|*gitlab.*) want="gitlab" ;;
      *) printf 'none\n'; return 0 ;;
    esac
  fi

  case "$want" in
    github)
      if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        printf 'github\n'
      else
        printf 'none\n'
      fi
      ;;
    gitlab)
      if command -v glab >/dev/null 2>&1 && glab auth status >/dev/null 2>&1; then
        printf 'gitlab\n'
      else
        printf 'none\n'
      fi
      ;;
  esac
}

# jig_glab_fields <key>... — read `glab ... --output json` on stdin and print
# one tab-separated row of the given string fields per object, skipping an
# object whose first field is empty. `glab` returns a compact single-line
# array, so it is split into one object per line first: a greedy `.*` across
# the whole line would keep only the last merge request. Each field is taken
# at its first occurrence, whatever the key order: nested objects (author,
# assignees) carry a `state` of their own, later on. Housekeeping and
# jig_ship_pr both read `glab` through this, so they cannot disagree on it.
jig_glab_fields() {
  sed 's/},[[:space:]]*{/}\
{/g' | awk -v keys="$*" '
    function field(key,   k) {
      k = "\"" key "\":\""
      if (!match($0, k "[^\"]*\"")) return ""
      return substr($0, RSTART + length(k), RLENGTH - length(k) - 1)
    }
    BEGIN { n = split(keys, want, " ") }
    {
      row = field(want[1])
      if (row == "") next
      for (i = 2; i <= n; i++) row = row "\t" field(want[i])
      print row
    }'
}

# --- shipping a change ---------------------------------------------------------
#
# The git steps `jig task ship` and `jig spec ship` both take, as far as
# `agent.git` allows (jig_agent_git, config.sh): commit what the agent staged,
# push a branch, open a pull request. Shared here because the two commands must
# never disagree about what may be committed, how a push is made or when a pull
# request is a duplicate, and one command library never sources another
# (ARCHITECTURE.md, Scripts layout). Each caller keeps its own gates — a task's
# knowledge decision and review, a spec's mode — and decides which of these
# steps to take; <who> prefixes every message with the command that was run.
# Nothing here stages, forces a push or skips hooks
# (adr-20260921-agent-git-rights-are-a-local-setting). The one merge, at
# `agent.git: merge`, is jig_ship_merge below, and it merges only a pull
# request whose checks all passed, at the commit that was shipped, through the
# forge's own rules — never --admin, never --auto
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci).

# Referenced from the EXIT trap jig_ship_pr sets for the pull request body it
# cuts from a commit message, so it is script-global rather than `local`
# (conventions/shell.md: a trap runs after its function returned). One ship
# runs per dispatch, so this is the only EXIT trap in that process.
_JIG_SHIP_BODY_TMP=""
# The pull request's URL as jig_ship_pr found or opened it; empty when none.
JIG_SHIP_URL=""

# jig_ship_staged — the paths staged in the index, one per line.
jig_ship_staged() {
  git -C "$JIG_PROJECT" diff --cached --name-only 2>/dev/null | sed '/^$/d'
}

# jig_ship_check_staged <who> — refuse, changing nothing, when anything under
# .ai/workspace/ or .ai/runtime/ is staged: those are never committed
# (RULES.md).
jig_ship_check_staged() {
  local who="$1" bad="" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$JIG_AI_DIR/workspace/"* | "$JIG_AI_DIR/runtime/"*) bad="$bad
$p" ;;
    esac
  done <<EOF
$(jig_ship_staged)
EOF
  bad=$(printf '%s\n' "$bad" | sed '/^$/d')
  if [ -n "$bad" ]; then
    jig_die "$who: staged changes under $JIG_AI_DIR/workspace/ or $JIG_AI_DIR/runtime/ are not shippable:
$bad"
  fi
}

# jig_ship_commit <who> <message-file> — commit the index as it is: only what
# is staged, never `-a`; hooks run, never --no-verify.
#
# An empty index used to be an outcome rather than a question: the step
# printed `nothing staged; no commit` and the ship carried on. That is right
# only when there is nothing left to commit — the change was committed by an
# earlier run, and this run pushes it or opens its pull request. When the
# working tree still holds changes to tracked files, the same empty index
# means the opposite: the work is being left behind, and what would be
# shipped is whatever the branch happens to carry already. Nothing about that
# reads as a failure afterwards — at `agent.git: merge` a pull request without
# the change has nothing to make CI red, so it goes green and merges itself.
# So it is a refusal here, before the commit step returns, and not a line in
# the log. Untracked files are warned about, not refused: a scratch file, the
# commit message itself or a build artefact is nobody's shipped change, and a
# refusal on those is one every caller would learn to work around.
jig_ship_commit() {
  local who="$1" message_file="$2" unstaged untracked
  if [ -n "$(jig_ship_staged)" ]; then
    git -C "$JIG_PROJECT" commit -F "$message_file" >/dev/null \
      || jig_die "$who: git commit failed"
    printf 'committed %s\n' "$(git -C "$JIG_PROJECT" rev-parse --short HEAD)"
    return 0
  fi
  unstaged=$(git -C "$JIG_PROJECT" diff --name-only 2>/dev/null | sed '/^$/d')
  if [ -n "$unstaged" ]; then
    jig_die "$who: nothing is staged, and these tracked files have changes that are not:
$unstaged
Shipping now would carry whatever the branch already holds and leave the change behind. Stage it and run again."
  fi
  untracked=$(git -C "$JIG_PROJECT" ls-files --others --exclude-standard 2>/dev/null | sed '/^$/d')
  [ -z "$untracked" ] || jig_warn "$who: nothing is staged, and these files are not tracked by git:
$untracked"
  printf 'nothing staged; no commit\n'
}

# --- what a ship may send out ------------------------------------------------
#
# Push, the pull request and the merge are the steps that leave this machine,
# and none of them is taken back by noticing afterwards: an empty pull request
# stays in the forge, people and bots see it, somebody closes it by hand, and
# on a public repository it has already happened while the agent is still
# working out what went wrong. An unhelpful message costs a reader a minute;
# an outward step taken too early costs everyone who sees the result.
#
# So the order is an invariant here, not a habit: a ship says what it is
# sending before its first outward step, and every outward step refuses to run
# until it has. Two calls say it, and one of them must:
#
#   jig_ship_require_commits <who> <head> <base> — <head> carries at least one
#       commit <base> does not; otherwise the ship refuses right there, with
#       nothing sent. This is the ordinary case: it is what `task ship` and a
#       spec's declaration and final pull request all send.
#   jig_ship_sends_no_commit <why> — this ship carries no commit on purpose.
#       `spec ship` in `epic` mode pushes an epic branch so that it exists on
#       the forge for its tasks to target, and an epic just cut from the
#       default branch has no commit of its own.
#
# A new outward step inherits the rule by opening with _jig_ship_outward; a
# new call site inherits it by having to say which of the two above it is.
# Observed on 2026-09-24 and again on 2026-09-25: `task ship` printed
# `nothing staged; no commit`, pushed the empty branch anyway and only then
# asked GitHub for a pull request, which is where the run finally stopped —
# by then the forge had already been asked.

# What this ship sends, as a sentence; empty until the ship has said.
_JIG_SHIP_SENDS=""

# _jig_ship_outward <who> — the guard every step that leaves this machine
# opens with. Reaching one without an answer is a mistake in the caller, not
# something a user can cause, so it dies rather than guessing.
_jig_ship_outward() {
  [ -n "$_JIG_SHIP_SENDS" ] \
    || jig_die "$1: internal: a step that leaves this machine was reached before the ship checked what it has to send"
}

# jig_ship_require_commits <who> <head> <base> — refuse, with nothing sent,
# unless <head> has a commit the base does not. The base is read through
# jig_base_ref, so the comparison is the one the forge will make: origin's
# base when it is known here, the local branch otherwise.
jig_ship_require_commits() {
  local who="$1" head="$2" base="$3" base_ref count
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1 \
    || jig_die "$who: $head names no commit in this checkout"
  base_ref=$(jig_base_ref "$base")
  [ -n "$base_ref" ] \
    || jig_die "$who: no branch $base here or on origin, so what $head would add cannot be told; fetch it and run again"
  count=$(git -C "$JIG_PROJECT" rev-list --count "$base_ref..$head" 2>/dev/null) || count=""
  [ -n "$count" ] || jig_die "$who: cannot tell what $head adds to $base_ref"
  if [ "$count" -eq 0 ]; then
    jig_die "$who: nothing to ship: $head has no commit $base_ref does not have.
The index was empty and no earlier run committed, so the branch carries no work.
Nothing has been pushed and no pull request opened: stage the change and run again."
  fi
  _JIG_SHIP_SENDS="$count commit(s) on $head"
}

# jig_ship_sends_no_commit <why> — this ship sends no commit and means to;
# <why> is for the reader of this code, not for the user.
jig_ship_sends_no_commit() {
  _JIG_SHIP_SENDS="no commit: $1"
}

# jig_ship_push <who> <branch> — push <branch> to origin and track it. Never
# --force: a branch origin has moved past is refused by git, and the refusal
# is the answer.
jig_ship_push() {
  local who="$1" branch="$2" out
  _jig_ship_outward "$who"
  if ! out=$(git -C "$JIG_PROJECT" push -u origin "$branch" 2>&1); then
    jig_die "$who: git push failed:
$out"
  fi
  printf 'pushed %s\n' "$branch"
}

# jig_ship_pr <who> <head> <base> <message-file> [<title>] [<body-file>] [<draft>]
# — open a pull request from <head> into <base> through whichever forge this
# checkout uses (jig_forge_kind), or report the one already open from <head>
# rather than opening a second. The title defaults to the message's first
# line, the body to the rest of it; <draft> 1 opens it as a draft. With no
# usable forge it says the pull request is the human's and returns 0. Leaves
# the URL in JIG_SHIP_URL, so it is called directly, never in `$()`.
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
jig_ship_pr() {
  local who="$1" head="$2" base="$3" message_file="$4" title="${5:-}" body_file="${6:-}" draft="${7:-0}" kind
  _jig_ship_outward "$who"
  JIG_SHIP_URL=""
  kind=$(jig_forge_kind) || exit 1
  if [ "$kind" = none ]; then
    printf "no forge available; the pull request is the human's\n"
    return 0
  fi
  [ -n "$title" ] || title=$(head -n 1 "$message_file")
  if [ -z "$body_file" ]; then
    _JIG_SHIP_BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-ship-body.XXXXXX")
    trap '[ -z "${_JIG_SHIP_BODY_TMP:-}" ] || rm -f "$_JIG_SHIP_BODY_TMP"' EXIT
    tail -n +2 "$message_file" > "$_JIG_SHIP_BODY_TMP"
    body_file="$_JIG_SHIP_BODY_TMP"
  fi
  case "$kind" in
    github) _jig_ship_pr_github "$who" "$head" "$base" "$title" "$body_file" "$draft" ;;
    gitlab) _jig_ship_pr_gitlab "$who" "$head" "$base" "$title" "$body_file" "$draft" ;;
  esac
}

# _jig_ship_pr_github <who> <head> <base> <title> <body-file> <draft>
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
_jig_ship_pr_github() {
  local who="$1" head="$2" base="$3" title="$4" body_file="$5" draft="$6" url out
  local extra=""
  [ "$draft" != 1 ] || extra="--draft"
  url=$(gh pr list --head "$head" --state open --json url --jq '.[0].url' 2>/dev/null || printf '')
  case "$url" in '' | null) url="" ;; esac
  if [ -n "$url" ]; then
    JIG_SHIP_URL="$url"
    printf 'pr %s (already open)\n' "$url"
    return 0
  fi
  # shellcheck disable=SC2086 # $extra is one flag or nothing
  out=$(gh pr create --base "$base" --head "$head" --title "$title" --body-file "$body_file" $extra 2>&1) \
    || jig_die "$who: gh pr create failed:
$out"
  url=$(printf '%s\n' "$out" | tail -n 1)
  JIG_SHIP_URL="$url"
  printf 'pr %s\n' "$url"
}

# _jig_ship_pr_gitlab <who> <head> <base> <title> <body-file> <draft> — the
# same through `glab`, whose JSON is read by jig_glab_fields, the reader
# housekeeping uses.
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
_jig_ship_pr_gitlab() {
  local who="$1" head="$2" base="$3" title="$4" body_file="$5" draft="$6" out url desc
  local extra=""
  [ "$draft" != 1 ] || extra="--draft"
  out=$(glab mr list --source-branch "$head" --output json 2>/dev/null || printf '')
  url=$(printf '%s' "$out" | jig_glab_fields web_url | head -n 1)
  if [ -n "$url" ]; then
    JIG_SHIP_URL="$url"
    printf 'pr %s (already open)\n' "$url"
    return 0
  fi
  desc=$(cat "$body_file")
  # shellcheck disable=SC2086 # $extra is one flag or nothing
  out=$(glab mr create --target-branch "$base" --source-branch "$head" --title "$title" --description "$desc" $extra 2>&1) \
    || jig_die "$who: glab mr create failed:
$out"
  url=$(printf '%s\n' "$out" | grep -oE 'https://[^[:space:]]+' | tail -n 1)
  JIG_SHIP_URL="$url"
  printf 'pr %s\n' "${url:-$out}"
}

# --- merging a shipped pull request ----------------------------------------------
#
# adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci. At
# `agent.git: merge` a ship ends by merging the pull request it opened — only
# when every condition below holds, and otherwise leaving it open with the
# reason. Not merging is an ordinary end, not an error: the forge's branch
# protection and a human review a repository requires are the ceiling a team
# keeps over one contributor's local key, and a red or silent CI is an answer.
# Each caller checks its own gates — a task's findings and receipt, an epic's
# leftovers — right before calling it.

# Set by jig_ship_merge: 1 when it merged, 0 otherwise.
JIG_SHIP_MERGED=0

# The seconds between two looks at a pull request's checks, and how long no
# check at all may mean "not registered yet" rather than "CI checks nothing".
_JIG_CI_POLL=15
_JIG_CI_GRACE=120

# jig_ship_merge <who> <url> <sha> <any|merge-commit> — merge the pull request
# at <url>, only as the commit <sha> that was shipped. Prints `merged <url>` or
# `not merged: <reason>` and returns 0 either way; dies (exit 1) only on an
# invalid agent.ci_timeout. The conditions, in order:
#   1. a forge this checkout can use, and a pull request to merge;
#   2. not a draft, and its head is <sha>;
#   3. a merge method the repository allows: `any` takes a merge commit, else
#      squash, else rebase; `merge-commit` takes a merge commit or nothing (an
#      epic: squash and rebase break the ancestry its tasks are judged by,
#      ADR-0040);
#   4. at least one check, and every check passed, within agent.ci_timeout
#      minutes — none, a red one or the timeout leaves it open;
#   5. the forge merges it at <sha> (GitHub `--match-head-commit`, GitLab
#      `--sha`) and agrees to: a refusal — branch protection, a required
#      review — leaves it open.
# Never `--admin`, never `--auto`: nothing here overrides the forge or asks it
# to merge later, when nobody is watching the conditions. Leaves the answer in
# JIG_SHIP_MERGED, so it is called directly, never in `$()`.
jig_ship_merge() {
  local who="$1" url="$2" sha="$3" policy="$4" kind timeout
  _jig_ship_outward "$who"
  JIG_SHIP_MERGED=0
  timeout=$(jig_ci_timeout) || jig_die "$who: invalid agent.ci_timeout: $timeout (expected whole minutes)"
  kind=$(jig_forge_kind) || exit 1
  if [ "$kind" = none ]; then
    printf "not merged: no forge available; the merge is the human's\n"
    return 0
  fi
  if [ -z "$url" ]; then
    printf 'not merged: no pull request to merge\n'
    return 0
  fi
  case "$kind" in
    github) _jig_ship_merge_github "$url" "$sha" "$policy" "$timeout" ;;
    gitlab) _jig_ship_merge_gitlab "$url" "$sha" "$policy" "$timeout" ;;
  esac
}

# _jig_ship_ci_wait <timeout-minutes> <reader> <args>... — call <reader>
# <args>... until the checks settle or the timeout passes; the reader prints
# one line, `<passed> <failed> <pending>` (counts). Prints green, red, none
# (nothing was checked) or timeout. No check at all is waited on only for
# _JIG_CI_GRACE seconds — a check registers a little after the push — and a
# timeout of 0 looks once.
_jig_ship_ci_wait() {
  local timeout="$1" reader="$2" start deadline counts passed failed pending now left
  shift 2
  start=$SECONDS
  deadline=$((start + timeout * 60))
  while :; do
    counts=$("$reader" "$@") || counts="0 0 0"
    read -r passed failed pending <<EOF
$counts
EOF
    passed=${passed:-0}
    failed=${failed:-0}
    pending=${pending:-0}
    if [ "$failed" -gt 0 ]; then
      printf 'red\n'
      return 0
    fi
    if [ "$pending" -eq 0 ] && [ "$passed" -gt 0 ]; then
      printf 'green\n'
      return 0
    fi
    now=$SECONDS
    if [ "$pending" -eq 0 ] && [ $((now - start)) -ge "$_JIG_CI_GRACE" ]; then
      printf 'none\n'
      return 0
    fi
    if [ "$now" -ge "$deadline" ]; then
      if [ "$pending" -eq 0 ]; then printf 'none\n'; else printf 'timeout\n'; fi
      return 0
    fi
    left=$((deadline - now))
    [ "$left" -le "$_JIG_CI_POLL" ] || left=$_JIG_CI_POLL
    sleep "$left"
  done
}

# _jig_ship_ci_reason <state> <timeout> — the `not merged:` text for a CI
# state other than green.
_jig_ship_ci_reason() {
  case "$1" in
    red) printf 'a check failed\n' ;;
    none) printf 'CI checked nothing: no check ran on the pull request\n' ;;
    *) printf 'the checks did not finish within %s minutes (agent.ci_timeout)\n' "$2" ;;
  esac
}

# _jig_ship_first_line <text> — the first non-empty line, for a refusal.
_jig_ship_first_line() {
  printf '%s\n' "$1" | awk '!f && /[^[:space:]]/ { print; f = 1 }'
}

# _jig_ship_checks_github <url> — `<passed> <failed> <pending>` for the pull
# request's checks. A skipped check counts as neither; a cancelled one as
# failed. An error reading them reads as no checks, never as passed.
_jig_ship_checks_github() {
  local out
  out=$(gh pr checks "$1" --json bucket --jq '.[].bucket' 2>/dev/null) || true
  printf '%s\n' "$out" | awk '
    $1 == "pass" { p++ }
    $1 == "fail" || $1 == "cancel" { f++ }
    $1 == "pending" { w++ }
    END { printf "%d %d %d\n", p, f, w }'
}

# _jig_ship_merge_github <url> <sha> <policy> <timeout>
# shellcheck disable=SC2034 # JIG_SHIP_MERGED is read by the caller
_jig_ship_merge_github() {
  local url="$1" sha="$2" policy="$3" timeout="$4" view draft="" head="" allowed m="" s="" r="" method state out
  if ! view=$(gh pr view "$url" --json isDraft,headRefOid --jq '"\(.isDraft) \(.headRefOid)"' 2>/dev/null); then
    printf 'not merged: could not read the pull request\n'
    return 0
  fi
  read -r draft head <<EOF
$view
EOF
  if [ "$draft" != false ]; then
    printf 'not merged: the pull request is a draft\n'
    return 0
  fi
  if [ "$head" != "$sha" ]; then
    printf 'not merged: the pull request is at %s, not at the shipped %s\n' "${head:-an unknown commit}" "$sha"
    return 0
  fi
  allowed=$(gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed \
    --jq '"\(.mergeCommitAllowed) \(.squashMergeAllowed) \(.rebaseMergeAllowed)"' 2>/dev/null) || allowed=""
  read -r m s r <<EOF
$allowed
EOF
  method=""
  if [ "$m" = true ]; then
    method=merge
  elif [ "$policy" = any ] && [ "$s" = true ]; then
    method=squash
  elif [ "$policy" = any ] && [ "$r" = true ]; then
    method=rebase
  fi
  if [ -z "$method" ]; then
    if [ "$policy" = merge-commit ] && [ -n "$allowed" ]; then
      printf 'not merged: the repository does not allow merge commits, and an epic merges only with one\n'
    else
      printf 'not merged: could not tell which merge method the repository allows\n'
    fi
    return 0
  fi
  state=$(_jig_ship_ci_wait "$timeout" _jig_ship_checks_github "$url")
  if [ "$state" != green ]; then
    printf 'not merged: %s\n' "$(_jig_ship_ci_reason "$state" "$timeout")"
    return 0
  fi
  if ! out=$(gh pr merge "$url" --match-head-commit "$sha" "--$method" 2>&1); then
    printf 'not merged: the forge refused: %s\n' "$(_jig_ship_first_line "$out")"
    return 0
  fi
  JIG_SHIP_MERGED=1
  printf 'merged %s\n' "$url"
}

# _jig_ship_glab_mr <url> — the merge request's iid from its web URL, or
# nothing when the URL is not one.
_jig_ship_glab_mr() {
  local iid="${1##*/merge_requests/}"
  iid=${iid%%[/?#]*}
  case "$iid" in '' | *[!0-9]*) return 0 ;; esac
  printf '%s\n' "$iid"
}

# _jig_ship_glab_pipeline <json> — `<status> <sha>` of the merge request's
# head pipeline, or nothing when it has none (`"head_pipeline":null`). Its
# fields are read up to its first nested object; status and sha come first.
_jig_ship_glab_pipeline() {
  local obj status psha
  obj=$(printf '%s' "$1" | tr '\n' ' ' | sed -n 's/.*"head_pipeline":[[:space:]]*{\([^}]*\).*/\1/p')
  [ -n "$obj" ] || return 0
  status=$(printf '%s' "$obj" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p')
  psha=$(printf '%s' "$obj" | sed -n 's/.*"sha":[[:space:]]*"\([^"]*\)".*/\1/p')
  printf '%s %s\n' "${status:-unknown}" "${psha:--}"
}

# _jig_ship_checks_gitlab <iid> <sha> — `<passed> <failed> <pending>` for the
# merge request's head pipeline, the one check GitLab reports on it: a
# pipeline for another commit is still pending for <sha>; a skipped one
# checked nothing.
_jig_ship_checks_gitlab() {
  local json pipe status="" psha=""
  json=$(glab mr view "$1" --output json 2>/dev/null) || json=""
  pipe=$(_jig_ship_glab_pipeline "$json")
  if [ -z "$pipe" ]; then
    printf '0 0 0\n'
    return 0
  fi
  read -r status psha <<EOF
$pipe
EOF
  if [ "$psha" != "$2" ]; then
    printf '0 0 1\n'
    return 0
  fi
  case "$status" in
    success) printf '1 0 0\n' ;;
    failed | canceled | canceling) printf '0 1 0\n' ;;
    skipped) printf '0 0 0\n' ;;
    *) printf '0 0 1\n' ;;
  esac
}

# _jig_ship_merge_gitlab <url> <sha> <policy> <timeout> — the same through
# `glab`. GitLab sets the method per project (merge_method, squash_option):
# `merge-commit` needs a merge commit and a squash that is off by default.
# shellcheck disable=SC2034 # JIG_SHIP_MERGED is read by the caller
_jig_ship_merge_gitlab() {
  local url="$1" sha="$2" policy="$3" timeout="$4" iid json project mm so squash="" state out
  iid=$(_jig_ship_glab_mr "$url")
  if [ -z "$iid" ]; then
    printf 'not merged: could not read the merge request from %s\n' "$url"
    return 0
  fi
  if ! json=$(glab mr view "$iid" --output json 2>/dev/null); then
    printf 'not merged: could not read the merge request\n'
    return 0
  fi
  case "$(printf '%s' "$json" | tr -d ' \n')" in
    *'"draft":true'* | *'"work_in_progress":true'*)
      printf 'not merged: the merge request is a draft\n'
      return 0 ;;
  esac
  project=$(glab api "projects/:id" 2>/dev/null | tr '\n' ' ') || project=""
  mm=$(printf '%s' "$project" | sed -n 's/.*"merge_method":[[:space:]]*"\([^"]*\)".*/\1/p')
  so=$(printf '%s' "$project" | sed -n 's/.*"squash_option":[[:space:]]*"\([^"]*\)".*/\1/p')
  case "$policy:$mm:$so" in
    merge-commit:merge:never | merge-commit:merge:default_off \
      | merge-commit:rebase_merge:never | merge-commit:rebase_merge:default_off) ;;
    merge-commit:?*:?*)
      printf 'not merged: the project does not merge with a merge commit, and an epic merges only with one\n'
      return 0 ;;
    any:?*:always | any:?*:default_on) squash="--squash" ;;
    any:?*:?*) ;;
    *)
      printf 'not merged: could not tell which merge method the project allows\n'
      return 0 ;;
  esac
  state=$(_jig_ship_ci_wait "$timeout" _jig_ship_checks_gitlab "$iid" "$sha")
  if [ "$state" != green ]; then
    printf 'not merged: %s\n' "$(_jig_ship_ci_reason "$state" "$timeout")"
    return 0
  fi
  # --auto-merge=false: merge now or not at all, never "once the pipeline
  # succeeds", later, when nobody checks the conditions again.
  # shellcheck disable=SC2086 # $squash is one flag or nothing
  if ! out=$(glab mr merge "$iid" --sha "$sha" --yes --auto-merge=false $squash 2>&1); then
    printf 'not merged: the forge refused: %s\n' "$(_jig_ship_first_line "$out")"
    return 0
  fi
  JIG_SHIP_MERGED=1
  printf 'merged %s\n' "$url"
}

# --- specification links ------------------------------------------------------

# jig_spec_link <task.md> — the spec id a task links to, or nothing.
#
# A link is a whole line `Spec: .ai/specs/<id>/`, optionally followed by a
# dash and `Phase <n>`. A line whose id breaks the id grammar links to
# nothing. Exits 2 when the file links to two different specs: which roadmap
# to read would be a guess. Here rather than in spec.sh because `task start`
# needs it too, and one command library never sources another.
jig_spec_link() {
  awk '
    /^Spec: \.ai\/specs\/[A-Za-z0-9._-]+\/([[:space:]]+(—|-|--)[[:space:]]+Phase[[:space:]]+[0-9]+)?[[:space:]]*$/ {
      id = $0
      sub(/^Spec: \.ai\/specs\//, "", id)
      sub(/\/.*$/, "", id)
      if (id ~ /^[.-]/) next
      if (found == "") found = id
      else if (found != id) conflict = 1
    }
    END {
      if (conflict) exit 2
      if (found != "") print found
    }
  ' "$1"
}

# jig_spec_epic <roadmap.md|-> — "<branch> open" or "<branch> finished" when
# the roadmap declares an epic branch, nothing when it does not (ADR-0040).
#
# The declaration is a whole line `Epic: <branch>`, closed before the epic's
# final pull request as `Epic: <branch> — finished`. Exits 2 when two lines
# disagree, on the branch or on its state: which base a task is cut from
# would be a guess. The branch name is not validated here; a caller that
# builds a ref from it runs `git check-ref-format --branch` first.
jig_spec_epic() {
  awk '
    /^Epic:[[:space:]]+[^[:space:]]+([[:space:]]+(—|-|--)[[:space:]]+finished)?[[:space:]]*$/ {
      line = $0
      sub(/^Epic:[[:space:]]+/, "", line)
      b = line
      sub(/[[:space:]].*$/, "", b)
      st = (line ~ /finished[[:space:]]*$/) ? "finished" : "open"
      v = b " " st
      if (found == "") found = v
      else if (found != v) conflict = 1
    }
    END {
      if (conflict) exit 2
      if (found != "") print found
    }
  ' "$1"
}

# Files this checkout has touched: the union of the diff against the merge-base
# with the configured base branch, the staged and unstaged diffs, and untracked
# files — all repo-relative (ARCHITECTURE.md, Scripts layout). `-C "$JIG_PROJECT"` matters: `git diff`
# reports paths relative to the repository root regardless of cwd, but
# `git ls-files` reports them relative to cwd unless it is the root, so without
# -C the two halves of the union could disagree on the path of the same file.
# When the base branch does not exist, merge-base fails and only the working
# tree diffs (staged, unstaged, untracked) are used.
#
# `--base-branch <name>` names the base a task was cut from (jig_task_base);
# without it the configured `git.base_branch` is used. Either way the base is
# resolved as jig_base_ref resolves it, origin first.
#
# Lives here rather than in one command's library because `context` and
# `knowledge paths` both need the same answer to "what did this task touch",
# and they must never disagree about it (ARCHITECTURE.md, scripts layout).
jig_git_touched_files() {
  local base=""
  if [ "${1:-}" = "--base-branch" ]; then
    [ "$#" -ge 2 ] || { jig_warn "jig_git_touched_files: --base-branch requires a value"; return 1; }
    base="$2"
    shift 2
  fi
  if [ "$#" -gt 0 ]; then
    local explicit_base explicit_head explicit_rows
    explicit_base=$(jig_review_commit "$1") || return 1
    explicit_head=$(jig_review_commit "${2:-HEAD}") || return 1
    explicit_rows=$(jig_git_change_rows "$explicit_base" "$explicit_head") || return 1
    printf '%s\n' "$explicit_rows" | sed '/^$/d' | cut -f1 | LC_ALL=C sort -u
    return 0
  fi
  local ref mb out=""
  [ -n "$base" ] || base=$(cfg git.base_branch main)
  ref=$(jig_base_ref "$base")
  if [ -n "$ref" ] && mb=$(git -C "$JIG_PROJECT" merge-base "$ref" HEAD 2>/dev/null); then
    out="$out
$(git -C "$JIG_PROJECT" diff --name-only "$mb" 2>/dev/null)"
  fi
  # Staged changes are listed independently: without a merge base they would
  # otherwise vanish from both the unstaged diff and the untracked list.
  out="$out
$(git -C "$JIG_PROJECT" diff --cached --name-only 2>/dev/null)"
  out="$out
$(git -C "$JIG_PROJECT" diff --name-only 2>/dev/null)"
  out="$out
$(git -C "$JIG_PROJECT" ls-files --others --exclude-standard 2>/dev/null)"
  printf '%s\n' "$out" | sed '/^$/d' | sort -u
}

# --- knowledge documents ---------------------------------------------------

# Document types that carry frontmatter and ship a template under
# templates/knowledge/ (schemas/frontmatter.md, ADR-0004). `domain`,
# `glossary` and `rule` are the three files of a domain pack.
JIG_DOC_TYPES="feature adr convention domain glossary rule"
export JIG_DOC_TYPES

# The three documents directly under .ai/knowledge/ that carry no frontmatter
# by design. Takes an absolute path and matches on the repository-relative
# path, never on the basename: a domain pack is `domains/<d>/RULES.md`, and a
# basename test would exempt that file from validation and hide it from every
# consumer of jig_knowledge_docs — silently, which is the worst way to lose a
# document (design.md, "Global documents are recognised by path").
jig_knowledge_is_global() {
  local rel
  rel=$(jig_relpath "$1" "$JIG_PROJECT")
  case "$rel" in
    "$JIG_AI_DIR/knowledge/GLOSSARY.md" | \
      "$JIG_AI_DIR/knowledge/ARCHITECTURE.md" | \
      "$JIG_AI_DIR/knowledge/RULES.md") return 0 ;;
    *) return 1 ;;
  esac
}

# Every knowledge document that can carry frontmatter, absolute paths, sorted.
# Walks .ai/knowledge recursively: applicability lives in frontmatter, not in
# the directory (ADR-0004), so a document counts wherever it sits — including
# under domains/<d>/.
#
# Lives here, with the other shared knowledge helpers, because `context` and
# `knowledge` must never disagree about which files exist: one walking
# recursively while the other read three fixed directories is how a domain
# document ended up validated but never resolved.
jig_knowledge_docs() {
  local dir="$JIG_PROJECT/$JIG_AI_DIR/knowledge" f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    jig_knowledge_is_global "$f" && continue
    printf '%s\n' "$f"
  done < <(find "$dir" -type f -name '*.md' | sort)
}

# jig_knowledge_status_resolvable <status> — true when a document may be loaded into
# an agent's context, listed in the catalog, or pulled in as a `requires` target.
#
# An allowlist, deliberately: a denylist of retired values resolves anything it has not
# heard of — a typo'd status, or a lifecycle value added later — as if it were active.
# `proposed` is exactly such a later value, and the guarantee that a proposed document
# cannot reach an agent rests on this being an allowlist. `accepted` is the ADR spelling
# of `active`.
jig_knowledge_status_resolvable() {
  case "$1" in
    active | accepted) return 0 ;;
    *) return 1 ;;
  esac
}

# jig_knowledge_source <doc> — the `source:` a document links, or nothing.
# A document with one is a stub for an existing file (ADR-0036). `knowledge`
# validates stubs and `context` resolves them to their sources, and the two
# must agree on what a stub is — so the question is asked here, once.
# Callers have sourced frontmatter.sh, as both commands do.
jig_knowledge_source() {
  fm_get "$1" source
}

# jig_knowledge_read_path <doc> — the repository-relative path an agent reads
# for <doc>: the source of a stub, the document itself otherwise. Exit 3, with
# the source path still printed, when a stub's source is not a regular file
# inside the repository — a path that could leave it, a symlink, or a file
# reached through a symlinked directory. Checked on every resolution, not only
# at acceptance: a hand-edited stub is not validated before it is resolved, and
# a source can be swapped for a link to `/etc/passwd` after it was accepted
# without touching the stub. Whether git tracks the file with this exact case
# is `knowledge check`'s question, not this one's.
jig_knowledge_read_path() {
  local src
  src=$(jig_knowledge_source "$1")
  if [ -z "$src" ]; then
    jig_relpath "$1" "$JIG_PROJECT"
    return 0
  fi
  printf '%s\n' "$src"
  case "$src" in
    /* | ../* | */../* | *.. ) return 3 ;;
  esac
  if [ ! -f "$JIG_PROJECT/$src" ] || [ -L "$JIG_PROJECT/$src" ]; then
    return 3
  fi
  local root dir
  root=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || return 3
  dir=$(cd -P "$(dirname "$JIG_PROJECT/$src")" 2>/dev/null && pwd -P) || return 3
  case "$dir/" in
    "$root/"*) return 0 ;;
    *) return 3 ;;
  esac
}

# Translate a frontmatter `paths` glob into a pattern usable both with
# `find -path` and with a bash `case`: `**` (any depth, including zero
# directories) collapses to a single `*`. BSD and GNU `find -path` match `*`
# across `/` (no FNM_PATHNAME) and a `case` pattern does the same, so this one
# substitution covers any-depth and single-segment globs in both consumers
# (convention-shell). Used by context.sh, knowledge.sh.
jig_glob_pattern() {
  printf '%s' "$1" | sed 's#[*][*]/#*#g; s#[*][*]#*#g'
}

# --- misc ------------------------------------------------------------------

jig_today() { date +%Y-%m-%d; }

# jig_trash_dest <name> — where <name> goes in trash today:
# .ai/runtime/trash/<date>/<name>, or <name>-2, -3, … when that is taken. Never
# overwrites and never merges into an existing entry (ADR-0006). Shared by
# housekeeping (a workspace, named by its task id) and `jig spec remove`
# (`spec-<id>`), so two commands putting things in the same trash cannot
# disagree about collisions. Prints the path; creates nothing.
jig_trash_dest() {
  local base dest n
  base="$JIG_PROJECT/$JIG_AI_DIR/runtime/trash/$(jig_today)/$1"
  dest="$base"
  n=2
  while [ -e "$dest" ]; do
    dest="$base-$n"
    n=$((n + 1))
  done
  printf '%s\n' "$dest"
}

# --- the live status page (adr-20260924-the-status-page-keeps-the-readers-place)
#
# The page, .ai/runtime/status.html, is redrawn by the commands that change
# what it shows, synchronously and from the counts the last full `jig status`
# cached, so a redraw costs a fraction of a second. Shared here because task,
# spec and housekeeping all trigger it and none of them may source status.sh:
# the redraw is a process, `jig status --refresh`, the way one domain runs
# another's command (ARCHITECTURE.md, Scripts layout).

_JIG_PAGE_DIRTY=""

# jig_status_page_touch [--full | --refresh] — redraw the clone's status page
# if it exists.
# One page per clone: a command run in a task worktree redraws the page of the
# main checkout, with that checkout's own jig. A page nobody has opened yet
# (`jig status --html` or `--open` writes the first one) is never created
# here. --full recounts everything and refreshes the cached counts
# (`status --html`); --refresh, the default, reads them (`status --refresh`).
# Callers in this file pass the mode explicitly: shellcheck 0.9.0 reports
# SC2120 on a function that reads $1 when every call it can see passes none.
# Always returns 0 and prints nothing: a failed redraw never changes the
# output or the exit code of the command that triggered it.
jig_status_page_touch() {
  local mode="--refresh" root jig
  [ "${1:-}" != --full ] || mode="--html"
  root=$(jig_config_clone_root 2>/dev/null) || return 0
  [ -f "$root/$JIG_AI_DIR/runtime/status.html" ] || return 0
  jig="$root/$JIG_AI_DIR/scripts/jig"
  [ -f "$jig" ] || return 0
  (cd "$root" && bash "$jig" status "$mode") </dev/null >/dev/null 2>&1 || true
  return 0
}

# jig_status_page_dirty — note that this command changed something the page
# shows. The writers call it themselves, so a new command that writes through
# them is covered without anyone remembering to; jig_status_page_flush then
# redraws once, however many writes came before.
jig_status_page_dirty() { _JIG_PAGE_DIRTY=1; }

# jig_status_page_flush — redraw the page when this command changed something.
jig_status_page_flush() {
  [ -n "${_JIG_PAGE_DIRTY:-}" ] || return 0
  _JIG_PAGE_DIRTY=""
  jig_status_page_touch --refresh
}

# jig_hash_git_dir — the git directory every hash in this project is computed
# against, empty when the project is not in a repository at all. Asked of git
# once per shell that asks, because it costs a git startup and `jig status`
# hashes on every invocation; a caller inside `$(...)` is a subshell and pays
# again, which is why the batching rule below matters more than this cache.
#
# `git hash-object` reads two things from wherever it happens to run, and both
# of them decide whether two hashes of identical bytes come out equal:
#
#   - the object format. In a repository created with --object-format=sha256 a
#     file hashes to 64 hex digits; outside any repository, to 40. `jig
#     upgrade` hashes the project inside it and its staging tree in $TMPDIR
#     outside it, so in a SHA-256 project every framework file compared
#     unequal: the first run replaced all 97 of them and wrote SHA-1 hashes
#     into a SHA-256 manifest, and from the second run on every file read as
#     `keep-modified` and `jig status` reported drift that was never there.
#   - the clean filters. A `filter=` driver or a `text` attribute makes the
#     hash of a path in a repository the hash of its *cleaned* content, which
#     the same bytes outside a repository do not have.
#
# --no-filters answers the second and not the first, so both are needed: one
# hash space for the project, and the bytes on disk as they are.
#
# Sets _JIG_HASH_GIT_DIR rather than printing it (jig_link_detect's pattern):
# a `$(...)` result would be computed in a subshell, where the answer could not
# be kept. An empty GIT_DIR is not "unset" to git but a fatal "the empty string
# is not a valid path", so every caller branches on it instead of exporting it.
jig_hash_git_dir() {
  [ -z "${_JIG_HASH_GIT_DIR_SET:-}" ] || return 0
  _JIG_HASH_GIT_DIR=$(git -C "${JIG_PROJECT:-.}" rev-parse --absolute-git-dir 2>/dev/null) \
    || _JIG_HASH_GIT_DIR=""
  _JIG_HASH_GIT_DIR_SET=1
}

# Content hash used by the manifest (ADR-0003, domains/install). git is mandatory,
# shasum/sha256sum are not portable. Hashed in the project's own hash space and
# without filters, the same way jig_hash_list does it: the two must never
# disagree about the hash of one file, or one writer of the manifest would
# record what the other reads as a modification.
jig_hash() {
  jig_hash_git_dir
  if [ -n "$_JIG_HASH_GIT_DIR" ]; then
    GIT_DIR="$_JIG_HASH_GIT_DIR" git hash-object --no-filters "$1"
  else
    git hash-object --no-filters "$1"
  fi
}

# jig_copy_tree <src-dir> <dst-dir> — copy every regular file under <src-dir>
# (`find -type f`: symlinks and empty directories are not copied) to the same
# relative path under <dst-dir>, with `cp -p`. Plain overwrite, no conflict
# handling: for scratch trees such as upgrade's stage, not for a project.
#
# One `mkdir -p` and one `cp` per directory rather than per file. The file list
# is sorted so each directory's files arrive together; a directory split
# around a subdirectory only costs an extra `cp`, never a wrong copy. The
# per-file loop — `dirname`, `mkdir` and `cp` for each of 43 framework files —
# was the largest part of what `jig status` still spent once hashing was
# batched.
jig_copy_tree() {
  local src="$1" dst="$2" f dir last="" n=0
  local -a batch
  mkdir -p "$dst"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f=${f#./}
    case "$f" in
      */*) dir=${f%/*} ;;
      *) dir=. ;;
    esac
    if [ "$dir" != "$last" ] && [ "$n" -gt 0 ]; then
      mkdir -p "$dst/$last"
      cp -p "${batch[@]}" "$dst/$last/"
      n=0
      batch=()
    fi
    last=$dir
    batch[n]="$src/$f"
    n=$((n + 1))
  done < <(cd "$src" && find . -type f | LC_ALL=C sort)
  if [ "$n" -gt 0 ]; then
    mkdir -p "$dst/$last"
    cp -p "${batch[@]}" "$dst/$last/"
  fi
  return 0
}

# jig_hash_list <base> <file> — the blob hash of every path listed in <file>,
# one per line and in the same order, from a single `git hash-object` process
# run in <base>. Nothing for an empty list. Every listed path must exist under
# <base>: git fails the whole batch otherwise, which the caller turns into an
# error rather than a missing hash.
#
# The paths are relative to <base>, never absolute. MSYS converts a path only
# when it is an argument; on stdin Git for Windows gets /tmp/... verbatim and
# cannot open it — `jig upgrade` died on every Windows run with "could not open
# '/tmp/jig-upgrade-stage…'". A relative path is spelled the same everywhere.
#
# Use this, not a loop over jig_hash, whenever there is more than one file.
# Each call is a git startup, and on 65 manifest files the loop took 0.879 s
# where one call took 0.013 s — it was most of what `jig status` cost.
# Pair the output back with its paths by position (`paste`); a path containing
# a newline would desync that, and none of jig's line-based lists can hold one.
#
# <base> is often outside the project — `jig upgrade` hashes its staging tree in
# $TMPDIR — and the hash must come out the same as for the same bytes inside it,
# so the project's git directory travels with the call (jig_hash_git_dir).
jig_hash_list() {
  [ -s "$2" ] || return 0
  jig_hash_git_dir
  if [ -n "$_JIG_HASH_GIT_DIR" ]; then
    (cd "$1" && GIT_DIR="$_JIG_HASH_GIT_DIR" git hash-object --no-filters --stdin-paths) < "$2"
  else
    (cd "$1" && git hash-object --no-filters --stdin-paths) < "$2"
  fi
}

# Path of <file> relative to <base>, both absolute. Pure string operation.
jig_relpath() {
  local base="${2%/}/" file="$1"
  case "$file" in
    "$base"*) printf '%s\n' "${file#"$base"}" ;;
    *) printf '%s\n' "$file" ;;
  esac
}

# Age of a file in whole days (0 when it does not exist). Uses mtime.
jig_file_age_days() {
  local f="$1" mtime now
  [ -f "$f" ] || { printf '0\n'; return; }
  if mtime=$(stat -f %m "$f" 2>/dev/null); then :; else mtime=$(stat -c %Y "$f"); fi
  now=$(date +%s)
  printf '%d\n' $(( (now - mtime) / 86400 ))
}

# Convert a duration like 7d / 12h / 30m to seconds.
jig_duration_seconds() {
  local d="$1" n unit
  n=${d%[dhms]}; unit=${d#"$n"}
  case "$n" in ''|*[!0-9]*) jig_die "invalid duration: $d" ;; esac
  case "$unit" in
    d|'') printf '%d\n' $((n * 86400)) ;;
    h) printf '%d\n' $((n * 3600)) ;;
    m) printf '%d\n' $((n * 60)) ;;
    s) printf '%d\n' "$n" ;;
  esac
}

# Fixed route vocabulary shared by context and knowledge metadata validation.
jig_valid_stage() {
  case "$1" in
    analyze | discover | specify | alternatives | design | plan | implement | review | architecture-review | verify | consolidate) return 0 ;;
    *) return 1 ;;
  esac
}

# Literal repository-relative paths for a review inventory (not shell/Git patterns).
jig_check_review_path() {
  case "$1" in
    '' | /* | *"$(printf '\t')"* | *'
'*) jig_die "task changes: unsupported path (absolute, empty, tab or newline): $1" ;;
  esac
  case "/$1/" in
    */../* | */./* | *//*) jig_die "task changes: path must be repository-relative without dot segments: $1" ;;
  esac
}

# jig_review_commit <ref> [message-prefix]
#
# The prefix names the *calling* command in the error. Without it the message
# was hardcoded to "task changes", so a second caller told the user about a
# command they had not run.
jig_review_commit() {
  local who="${2:-task changes}"
  case "$1" in '' | -*) jig_die "$who: invalid base: $1" ;; esac
  git -C "$JIG_PROJECT" rev-parse --verify "$1^{commit}" 2>/dev/null \
    || jig_die "$who: cannot resolve commit: $1"
}

# Strict inventory, path<TAB>layer. NUL Git output is decoded only after checking
# producer exit status; process substitution would hide a failing Git command.
# Buffer all rows so failures cannot be mistaken for a complete partial inventory.
jig_git_change_rows() (
  local base="$1" head="$2" layer path
  JIG_CHANGE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jig-changes.XXXXXX") || exit 1
  trap 'rm -rf "$JIG_CHANGE_TMP"' EXIT
  : > "$JIG_CHANGE_TMP/rows"
  for layer in committed staged unstaged untracked; do
    case "$layer" in
      committed) git -C "$JIG_PROJECT" diff --no-ext-diff --no-textconv --ignore-submodules=none --no-renames --name-only -z "$base" "$head" -- > "$JIG_CHANGE_TMP/paths" ;;
      staged) git -C "$JIG_PROJECT" diff --no-ext-diff --no-textconv --ignore-submodules=none --no-renames --cached --name-only -z "$head" -- > "$JIG_CHANGE_TMP/paths" ;;
      unstaged) git -C "$JIG_PROJECT" diff --no-ext-diff --no-textconv --ignore-submodules=none --no-renames --name-only -z -- > "$JIG_CHANGE_TMP/paths" ;;
      untracked) git -C "$JIG_PROJECT" ls-files --others --exclude-standard -z > "$JIG_CHANGE_TMP/paths" ;;
    esac || jig_die "task changes: Git inventory failed for $layer"
    while IFS= read -r -d '' path; do
      jig_check_review_path "$path"
      printf '%s\t%s\n' "$path" "$layer" >> "$JIG_CHANGE_TMP/rows"
    done < "$JIG_CHANGE_TMP/paths"
  done
  LC_ALL=C sort -u "$JIG_CHANGE_TMP/rows"
)

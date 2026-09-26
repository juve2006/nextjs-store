# Carrying into a task worktree the state git does not track (adr-20260924-a-worktree-carries-what-git-does-not).
#
# A task worktree is a git checkout, so it holds exactly what git tracks.
# Every project with an install step keeps the rest outside git — vendor/,
# node_modules/, .env — and a worktree without them is a tree whose checks
# cannot run. What is carried is declared, never guessed: a profile declares
# its stack's derived state (`carry` in profile.yaml), a project declares its
# own layout (`worktree.carry` in .ai/config.yaml).
#
# One action, and one nature of state: **derived state, each tree's own** —
# vendor, node_modules, .env — copied from the checkout that owns the worktree.
# State that must stay single because it is a source of truth under edit, such
# as a directory of separate repositories wired in as path repositories, is not
# served by copying and is not carried here at all: see the `worktree-share`
# task, which holds that analysis whole.
#
# Sourced by scripts/lib/task.sh, which sources scripts/lib/profiles.sh first.
# Depends on common.sh (jig_info, jig_warn, jig_copy_dir) and config.sh
# (cfg_list_lines), both already sourced by the dispatcher.
# bash 3.2 compatible.
# shellcheck shell=bash

# The staging directory the running carry is using, for _bootstrap_sweep to
# clear on the way out. Cleared here so a value inherited from the environment
# is never mistaken for one this process set.
_JIG_BOOTSTRAP_STAGING=""

# Exactly what the current placement created in the worktree, one path per
# line, so that a placement git turns out to see can be taken back precisely.
_BOOTSTRAP_MADE=""

# _bootstrap_first_segment <path> — the first component of a relative path.
_bootstrap_first_segment() {
  case "$1" in
    */*) printf '%s\n' "${1%%/*}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# _bootstrap_trim_slash <path> — <path> without trailing slashes. A person
# writing `packages/` is copying .gitignore's own convention for a directory —
# the very convention this design depends on — so the slash is normalised
# away rather than refused.
_bootstrap_trim_slash() {
  local p="$1"
  while :; do
    case "$p" in
      ?*/) p=${p%/} ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$p"
}

# _bootstrap_path_problem <path> — print why <path> may not be carried and
# exit 0; print nothing and exit 1 when it is acceptable. A declaration is
# read from .ai/config.yaml or a profile.yaml, both of which a person edits,
# so every path is checked before anything is created (RULES.md: no
# filesystem path is built from a name that has not been validated first).
# Expects a path already run through _bootstrap_trim_slash.
_bootstrap_path_problem() {
  local p="$1" lower ai
  case "$p" in
    '') printf 'it is empty\n'; return 0 ;;
    /*) printf 'it is absolute\n'; return 0 ;;
  esac
  case "$p" in
    *"$(printf '\t')"* | *' '* | *'
'*) printf 'it holds a space, a tab or a newline\n'; return 0 ;;
  esac
  # The /…/ wrapping makes one pattern catch a leading `../`, a trailing
  # `/..` and a bare `..` alike (jig_check_review_path's idiom).
  case "/$p/" in
    */../* | */./* | *//*) printf 'it is not a plain repository-relative path\n'; return 0 ;;
  esac
  # Compared lowercased, and on every segment rather than only the first: a
  # case-insensitive filesystem — macOS by default, and NTFS — opens
  # `.AI/state` as `.ai/state`, so a case-sensitive test refuses nothing
  # there. km_source_problem lowercases `.git` for the same reason. This is a
  # lexical guard; _bootstrap_dest_ok makes the physical one, because a path
  # can also reach .ai/ through a link rather than through its spelling.
  lower=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  ai=$(printf '%s' "$JIG_AI_DIR" | tr '[:upper:]' '[:lower:]')
  case "/$lower/" in
    */"$ai"/*)
      printf 'it is inside %s/, which a worktree borrows by link and must never copy\n' "$JIG_AI_DIR"
      return 0
      ;;
    */.git/*) printf 'it is inside .git/\n'; return 0 ;;
  esac
  return 1
}

# _bootstrap_under <root> <path> — exit 0 when <path>'s deepest existing
# component resolves physically inside <root>. The plain containment test;
# _bootstrap_dest_ok adds what a carry destination needs on top of it.
_bootstrap_under() {
  local root="$1" probe="$2" dir
  while [ ! -e "$probe" ] && [ ! -L "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "$root" ]; do
    probe=$(dirname "$probe")
  done
  [ -e "$probe" ] || [ -L "$probe" ] || return 1
  # A symlink is judged by where it lies, never by where it points: `cd -P`
  # through one answers about the target, and a link into the owning checkout
  # would then look as if it were outside the worktree — which is exactly
  # backwards, since moving or removing a link never touches its target. Every
  # entry a mirror makes is such a link.
  if [ -L "$probe" ] || [ ! -d "$probe" ]; then
    probe=$(dirname "$probe")
  fi
  dir=$(cd -P "$probe" 2>/dev/null && pwd -P) || return 1
  case "$dir/" in
    "$root"/* | "$root"/) return 0 ;;
  esac
  return 1
}

# _bootstrap_dest_ok <tree-root> <dst> — exit 0 when <dst> is a safe place to
# put a carried path: inside the worktree, and not inside the worktree's .ai/.
#
# Checked *before* anything is made, because `mkdir -p` and `cp` follow a
# symlink that is already there: a link at an intermediate component of a
# declared path would otherwise let the carry write outside the worktree
# entirely. The owning checkout's side is checked by _bootstrap_inside; this
# is the same guarantee for the destination.
_bootstrap_dest_ok() {
  local root="$1" dst="$2" ai
  _bootstrap_under "$root" "$dst" || return 1
  ai=$(cd -P "$root/$JIG_AI_DIR" 2>/dev/null && pwd -P) || return 0
  _bootstrap_under "$ai" "$dst" && return 1
  return 0
}

# _bootstrap_staging_root <tree-root> — where a carry builds a path before
# renaming it into place.
#
# Inside the worktree, so the rename is within one filesystem and therefore
# atomic, and under `.ai/runtime/`, because git is told to ignore that (the
# gitignore jig installs lists it without a trailing slash, so a directory and
# a link both match). That matters more than tidiness: anything a carry leaves
# in the worktree that git does *not* ignore reads as untracked, and
# `git worktree remove` without --force — the only removal jig ever performs —
# refuses such a worktree for the rest of its life. Staging beside the
# destination was tried first and did exactly that: a project ignores
# `vendor/`, and `vendor.jig-partial.60347` is not `vendor/`.
_bootstrap_staging_root() {
  printf '%s/%s/runtime/bootstrap\n' "$1" "$JIG_AI_DIR"
}

# _bootstrap_sweep — remove the staging directory this run is using. Called on
# the way out, however the run ends (see the trap in jig_bootstrap_worktree),
# so an interrupted carry leaves nothing behind; a kill -9 defeats the trap,
# and the location is what covers that case.
#
# The path is shape-checked before it is deleted, never taken on trust from
# the variable (RULES.md; conventions/shell.md).
_bootstrap_sweep() {
  [ -n "${_JIG_BOOTSTRAP_STAGING:-}" ] || return 0
  case "$_JIG_BOOTSTRAP_STAGING" in
    */"$JIG_AI_DIR"/runtime/bootstrap)
      rm -rf "$_JIG_BOOTSTRAP_STAGING" 2>/dev/null || true
      ;;
  esac
  return 0
}

# _bootstrap_discard <allowed-root> <path> — remove <path>, which must lie
# physically inside <allowed-root> and must not be <allowed-root> itself.
#
# Only ever called on something this run built inside the staging directory,
# so what it deletes is under `.ai/runtime/` — inside `.ai/` and shaped like
# the staging area, which is what RULES.md's deletion invariant asks for. A
# carried path at its final destination is never deleted: it only ever appears
# there complete, by rename.
_bootstrap_discard() {
  local root="$1" path="$2"
  [ -n "$path" ] || return 0
  [ "$path" != "$root" ] || return 1
  _bootstrap_under "$root" "$path" || return 1
  rm -rf "$path" 2>/dev/null || true
  # `rm -rf` reports nothing useful here and cannot be trusted to have worked:
  # a copy keeps the source's modes, so one mode-500 directory inside a
  # carried tree makes the whole delete a no-op that still exits 0. The answer
  # is the only one that means anything — is the path gone.
  if [ -e "$path" ] || [ -L "$path" ]; then
    return 1
  fi
  return 0
}

# _bootstrap_dirt <tree-root> — what git reports in the worktree, sorted, one
# entry per line. Ignored files are not listed, which is the whole point.
#
# This is the question that matters, asked of the only thing that can answer
# it. Everything a carry puts in a worktree must be invisible to git, because
# `git worktree remove` without `--force` — the only removal jig performs —
# refuses a worktree with anything untracked in it, and then housekeeping can
# never clean that tree up (ADR-0029).
#
# Four separate findings were the same failure reached by different routes: a
# path spelled in another case, a staging name the project's ignore rule did
# not cover, a shared directory nobody had ignored. Each was found by asking
# whether git *would* see something — from the path's spelling, from an ignore
# pattern, from `git ls-files`. Every such question is a proxy, and every proxy
# has another door: case folding, unicode normalisation in HFS+,
# `core.ignorecase`, a symlinked component. So the question is no longer asked
# by proxy. The carry acts, then looks at what git now reports, and takes back
# anything it made appear.
_bootstrap_dirt() {
  git -C "$1" status --porcelain 2>/dev/null | LC_ALL=C sort
}

# _bootstrap_new_dirt <tree-root> <baseline> — the lines git reports now that
# it did not report in <baseline>. Empty when the carry changed nothing git
# can see, which is the condition for keeping what was just placed.
_bootstrap_new_dirt() {
  local baseline="$2" line out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $'\n'"$baseline"$'\n' in
      *$'\n'"$line"$'\n'*) continue ;;
    esac
    out="$out$line
"
  done <<EOF
$(_bootstrap_dirt "$1")
EOF
  printf '%s' "$out"
}

# _bootstrap_take_back <tree-root> <staging> <made> <baseline> — undo a
# placement that made the worktree visible to git, and exit 0 only when git
# agrees the worktree is back at <baseline>. <made> lists, one per line,
# exactly what this run created; nothing else is ever touched.
#
# Each is moved into the staging directory and deleted there, so the deletion
# still happens inside `.ai/runtime/` and the invariant in RULES.md holds.
#
# **The list is what the undo acts on; git is what says whether it worked.**
# This is the same principle the placement was rebuilt on, and it was missing
# here — the one place where an answer was still being predicted. The list is
# newline-separated, so an entry whose own name holds a newline reaches this
# loop as two lines that name nothing; both are skipped, nothing is removed,
# and reporting a clean refusal would leave a worktree `git worktree remove`
# refuses for the rest of its life. A newline is only the reproducer: any gap
# in the accounting, present or future, is a silent stranding as long as the
# accounting is also the proof. So the proof is git's, and a skip needs no
# bookkeeping of its own — if it left something behind, git reports it.
#
# An entry not shaped like an absolute path inside the worktree is skipped
# before `_bootstrap_under` is asked, because that test resolves a relative
# path against the current directory: a mangled line such as a bare `b` could
# otherwise name something in the caller's own directory.
_bootstrap_take_back() {
  local tree_root="$1" staging="$2" made="$3" baseline="$4" p n=0 tmp
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in "$tree_root"/?*) ;; *) continue ;; esac
    _bootstrap_under "$tree_root" "$p" || continue
    [ -e "$p" ] || [ -L "$p" ] || continue
    n=$((n + 1))
    tmp="$staging/undo.$n.$$"
    if mv "$p" "$tmp" 2>/dev/null; then
      _bootstrap_discard "$staging" "$tmp" >/dev/null 2>&1 || true
    fi
  done <<EOF
$made
EOF
  [ -z "$(_bootstrap_new_dirt "$tree_root" "$baseline")" ]
}

# _bootstrap_inode <path> — <path>'s inode number, or nothing when it cannot
# be read. What tells one object from another, where a name cannot: after a
# rename that landed, the destination *is* the thing that was staged.
#
# `ls -di` because there is no portable `stat`: BSD and GNU disagree on every
# flag, and Git Bash ships the GNU one on a platform that is neither. `-d`
# answers about a symlink itself rather than its target, and about a directory
# rather than its contents.
#
# **What this promises is narrow: a number, when one can be read.** It does not
# promise that the number identifies the object. That can fail in more than one
# way — every path answering alike, or an answer that does not survive a rename
# — and the sole caller is built for that: it asks two comparisons that cannot
# both hold unless the read really discriminates, so it stands down rather than
# guessing. There is no fallback test to fall back to; what holds the line then
# is the destination re-test before the rename, not anything here.
_bootstrap_inode() {
  # SC2012 warns about parsing `ls` for filenames; no filename is read here —
  # one quoted path goes in and the first field of the first line, a number,
  # comes out. `find -printf '%i'` is GNU-only and so is not the alternative.
  # shellcheck disable=SC2012
  ls -di "$1" 2>/dev/null | awk 'NR==1 {print $1; exit}'
}

# _bootstrap_join <words> — space-separated words, comma separated for a
# report line. Paths never hold a space (_bootstrap_path_problem refuses one),
# so splitting on whitespace is safe here.
_bootstrap_join() {
  local w out=""
  for w in $1; do
    if [ -z "$out" ]; then out="$w"; else out="$out, $w"; fi
  done
  printf '%s\n' "$out"
}

# _bootstrap_inside <root-physical> <path> — exit 0 when <path>'s own physical
# location lies inside <root-physical>. A lexical check is not enough: a
# symlinked parent directory leads out of the checkout without a single `..`
# in the path (jig_knowledge_read_path's reasoning).
_bootstrap_inside() {
  local root="$1" dir
  dir=$(cd -P "$(dirname "$2")" 2>/dev/null && pwd -P) || return 1
  case "$dir/" in
    "$root"/*) return 0 ;;
    "$root"/) return 0 ;;
  esac
  return 1
}

# _bootstrap_declared — `<source><TAB><path>` for everything this project
# declares, profiles first, then the project's own list. <source> is a profile
# name or `project`, and is what an install hint is looked up from.
_bootstrap_declared() {
  local name item
  while IFS="$(printf '\t')" read -r name item; do
    [ -n "$item" ] || continue
    printf '%s\t%s\n' "$name" "$item"
  done < <(profiles_carry)
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf 'project\t%s\n' "$item"
  done < <(cfg_list_lines worktree.carry)
  return 0
}

# _bootstrap_stale <owner> <tree> <verb> — warn for each declared lock file
# that differs between the owning checkout and the worktree. The carried tree
# matches the owner's lock; the worktree's lock came from the task's base. A
# difference means the carried state is of the wrong vintage, not that it is
# broken, so this is a warning and never a refusal.
_bootstrap_stale() {
  local owner="$1" tree="$2" verb="$3" name item
  while IFS="$(printf '\t')" read -r name item; do
    [ -n "$item" ] || continue
    item=$(_bootstrap_trim_slash "$item")
    _bootstrap_path_problem "$item" >/dev/null && continue
    [ -f "$owner/$item" ] || continue
    [ -f "$tree/$item" ] || continue
    cmp -s "$owner/$item" "$tree/$item" && continue
    jig_warn "$verb: $item differs from this checkout's; what was carried may be stale"
  done < <(profiles_lock)
  return 0
}

# jig_bootstrap_worktree <owner-abs> <tree-abs> <verb> — carry the declared
# state from the owning checkout into the worktree.
#
# Never fatal, and never a rollback. By the time it runs the task is started,
# its branch exists and its workspace is linked; a tree that is missing a
# dependency is not a broken task, and the tree and the branch are exactly
# what is needed to try the carry again (`jig task bootstrap`). Every refusal
# and every skip is reported. Always returns 0.
jig_bootstrap_worktree() {
  local owner="$1" tree="$2" verb="$3"
  local src dst staged ok source path problem started elapsed baseline
  local staged_inode nested
  local carried="" missing="" seen=""
  local owner_root tree_root

  owner_root=$(cd -P "$owner" 2>/dev/null && pwd -P) || return 0
  tree_root=$(cd -P "$tree" 2>/dev/null && pwd -P) || return 0
  [ "$owner_root" != "$tree_root" ] || return 0

  # One staging directory for the whole run, cleared on the way in and swept on
  # the way out however the run ends. Clearing it first is what stops an
  # interrupted carry's remains accumulating: the directory is jig's own, so
  # nothing in it is anyone else's to keep.
  _JIG_BOOTSTRAP_STAGING=$(_bootstrap_staging_root "$tree_root")
  trap '_bootstrap_sweep' EXIT INT TERM
  _bootstrap_sweep
  mkdir -p "$_JIG_BOOTSTRAP_STAGING" 2>/dev/null || true

  # What git already reports in this worktree, before the carry touches it. A
  # fresh worktree reports nothing; one `jig task bootstrap` runs in may hold a
  # person's own work, and that is theirs, not this run's doing.
  baseline=$(_bootstrap_dirt "$tree_root")

  started=$(date +%s 2>/dev/null || printf '0')

  while IFS="$(printf '\t')" read -r source path; do
    [ -n "$path" ] || continue
    path=$(_bootstrap_trim_slash "$path")

    problem=$(_bootstrap_path_problem "$path") && {
      jig_warn "$verb: refusing to carry $path: $problem"
      continue
    }

    # A path declared twice, or declared both ways, is a configuration
    # mistake worth naming rather than resolving silently.
    case "$seen" in
      *"<$path>"*)
        jig_warn "$verb: $path is declared more than once; carried once"
        continue
        ;;
    esac
    seen="$seen<$path>"

    src="$owner_root/$path"
    dst="$tree_root/$path"

    # Something is already at the destination: git brought it, so it is the
    # worktree's own and is never touched. The carry only ever fills a gap.
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      continue
    fi
    if [ ! -e "$src" ] && [ ! -L "$src" ]; then
      missing="$missing $source:$path"
      continue
    fi
    if [ -L "$src" ]; then
      jig_warn "$verb: refusing to carry $path: it is a link in this checkout"
      continue
    fi
    if ! _bootstrap_inside "$owner_root" "$src"; then
      jig_warn "$verb: refusing to carry $path: it resolves outside this checkout"
      continue
    fi
    if ! _bootstrap_dest_ok "$tree_root" "$dst"; then
      jig_warn "$verb: refusing to carry $path: in the worktree it resolves outside the tree, or into $JIG_AI_DIR/"
      continue
    fi
    if ! mkdir -p "$(dirname "$dst")" 2>/dev/null; then
      jig_warn "$verb: could not make room for $path in the worktree"
      continue
    fi

    # Built beside its destination and renamed into place, so that <dst>
    # exists only when a carry finished. The loop above reads an existing
    # <dst> as already carried, and cleaning up after the fact cannot be
    # relied on to restore that: a copy keeps the source's modes, so a
    # read-only directory inside a carried tree defeats `rm -rf` while
    # leaving the remains exactly where the next run — `jig task bootstrap`
    # included — would mistake them for finished work. The rename is atomic
    # and within one directory, so no window exists where <dst> is partial.
    # This is conventions/shell.md's rule for the manifest, applied to a tree.
    staged="$_JIG_BOOTSTRAP_STAGING/$(printf '%s' "$path" | tr '/' '_')"
    _bootstrap_discard "$_JIG_BOOTSTRAP_STAGING" "$staged" >/dev/null 2>&1 || true
    ok=0
    jig_copy_dir "$src" "$staged" || ok=1
    # The destination is tested again here, not only before the copy: a copy
    # of a large tree takes seconds, and anything that appeared at <dst> in the
    # meantime would swallow the rename — `mv` moves *into* an existing
    # directory, which would bury the carried tree one level down and leave the
    # destination looking empty while the report said it was carried.
    if [ "$ok" = 0 ] && { [ -e "$dst" ] || [ -L "$dst" ]; }; then
      jig_warn "$verb: $path appeared in the worktree while it was being carried; left alone"
      ok=1
    fi
    staged_inode=$(_bootstrap_inode "$staged")
    if [ "$ok" = 0 ] && mv "$staged" "$dst" 2>/dev/null; then
      # **Second echelon, and only that.** What closes the race is the re-test
      # immediately before the `mv` above — measured against a real copy with a
      # directory planted partway through it. This catches only the sliver
      # between that test and the rename. Read it as a belt, not the trousers.
      #
      # That sliver is reachable by a test because `_bootstrap_inode` is the one
      # call that happens inside it: a stub that creates <dst> on its way past
      # makes the rename nest for real, which is what proves this block fires at
      # all (tests/bootstrap.t.sh).
      #
      # **Two bits of evidence, because one is not enough.** A rename nested
      # only if the object now at <dst>/<staged basename> *is* the staged one
      # **and** <dst> itself is *not*. Each half alone was tried and each was
      # wrong in its own direction, both times by truncating a carried tree that
      # legitimately holds a top-level entry of its own name (`carry: [data]`
      # over a `data/data/`) while reporting that nothing had been touched — the
      # exact harm this block exists to prevent.
      #
      # The precondition both halves rest on is not a list of platforms but a
      # property: **reading an inode tells one object from another.** Where that
      # holds, the conjunction is exact. Where it does not — whatever the reason,
      # and the reasons outran every list we wrote twice — the two halves cannot
      # both be satisfied, so the block stands down and the re-test holds the
      # line. Failing closed is the whole design of it.
      nested=0
      if [ -n "$staged_inode" ] && [ -e "$dst/${staged##*/}" ] \
         && [ "$(_bootstrap_inode "$dst/${staged##*/}")" = "$staged_inode" ] \
         && [ "$(_bootstrap_inode "$dst")" != "$staged_inode" ]; then
        nested=1
      fi
      if [ "$nested" = 1 ]; then
        mv "$dst/${staged##*/}" "$staged" 2>/dev/null || true
        jig_warn "$verb: could not put $path in the worktree without nesting it; left alone"
      else
        _BOOTSTRAP_MADE="$dst
"
        if [ -n "$(_bootstrap_new_dirt "$tree_root" "$baseline")" ]; then
          jig_warn "$verb: not carrying $path: git does not ignore it, and anything git can see in a worktree stops that worktree from ever being removed; add it to .gitignore, then carry it again"
          if ! _bootstrap_take_back "$tree_root" "$_JIG_BOOTSTRAP_STAGING" \
               "$_BOOTSTRAP_MADE" "$baseline"; then
            jig_warn "$verb: and could not take $path back out; the worktree needs you"
            baseline=$(_bootstrap_dirt "$tree_root")
          fi
        else
          carried="$carried $path"
        fi
        continue
      fi
    else
      if [ "$ok" = 0 ]; then
        jig_warn "$verb: could not carry $path into the worktree"
      fi
    fi
    _bootstrap_discard "$_JIG_BOOTSTRAP_STAGING" "$staged" >/dev/null 2>&1 || true
  done < <(_bootstrap_declared)

  elapsed=$(( $(date +%s 2>/dev/null || printf '0') - started ))
  [ "$elapsed" -ge 0 ] 2>/dev/null || elapsed=0

  if [ -n "$carried" ]; then
    jig_info "$verb: carried $(_bootstrap_join "$carried") ($_JIG_COPY_KIND, ${elapsed}s)"
  fi
  _bootstrap_missing_report "$missing" "$verb"
  _bootstrap_stale "$owner_root" "$tree_root" "$verb"
  return 0
}

# _bootstrap_missing_report <list> <verb> — one line per declared path that
# the owning checkout does not have either, naming the profile's install
# command where there is one. Nothing is run: if there is nothing to carry,
# the owning checkout is not installed either, and installing inside the
# worktree is a thing only a human with a toolchain can decide to do.
_bootstrap_missing_report() {
  local entry source path install
  for entry in $1; do
    source="${entry%%:*}"
    path="${entry#*:}"
    install=""
    [ "$source" = project ] || install=$(profiles_install "$source" 2>/dev/null || printf '')
    if [ -n "$install" ]; then
      jig_info "$2: $path is absent in this checkout too, so nothing was carried; run \`$install\` in the worktree"
    elif [ "$source" = project ]; then
      jig_info "$2: $path is absent in this checkout too, so nothing was carried"
    else
      jig_info "$2: $path is absent in this checkout too, so nothing was carried; install this stack's dependencies in the worktree"
    fi
  done
  return 0
}

# cmd_self_update — move the global framework checkout to the newest release
# (design.md task framework-self-update, section 2). Sourced by scripts/jig;
# defines cmd_self_update. Never touches the current project: it mutates only
# the framework source checkout `jig_global_executable` resolves to.
# shellcheck shell=bash

# _self_update_validate_source <source> — refuse (via jig_die, nothing
# changed) unless <source> is the root of a Git worktree (not a directory
# merely nested inside another worktree) and has no tracked, staged or
# untracked changes. jig_is_source_root is not re-checked here: the caller
# only ever passes a path jig_global_executable already validated as one.
_self_update_validate_source() {
  local source="$1" toplevel toplevel_phys source_phys status
  toplevel=$(git -C "$source" rev-parse --show-toplevel 2>/dev/null) \
    || jig_die "self-update: not a git checkout: $source"
  # pwd -P, not raw string comparison: git resolves symlinks and macOS maps
  # /var to /private/var (conventions/shell.md).
  toplevel_phys=$(cd -P "$toplevel" 2>/dev/null && pwd -P) \
    || jig_die "self-update: cannot resolve: $toplevel"
  source_phys=$(cd -P "$source" 2>/dev/null && pwd -P) \
    || jig_die "self-update: cannot resolve: $source"
  [ "$toplevel_phys" = "$source_phys" ] \
    || jig_die "self-update: $source is nested inside another git worktree ($toplevel_phys); refusing"

  # --untracked-files=all pins what counts as a change: with
  # status.showUntrackedFiles=no in someone's git config, plain --porcelain
  # hides untracked files and a dirty checkout would read as clean.
  status=$(git -C "$source" status --porcelain --untracked-files=all 2>/dev/null) \
    || jig_die "self-update: cannot read git status: $source"
  [ -z "$status" ] \
    || jig_die "self-update: framework checkout has uncommitted changes; commit or stash before self-update: $source"
}

# _self_update_branch <source> <global> — the checkout is on a branch.
# Requires an upstream, then runs exactly `git pull --ff-only`: never a
# merge, reset or stash (AC-04). A pull failure (divergence, unreachable
# remote) exits with git's own non-zero status, not always 1.
_self_update_branch() {
  local source="$1" global="$2" old_short old_version new_short new_version rc

  git -C "$source" rev-parse --verify -q '@{u}' >/dev/null 2>&1 \
    || jig_die "self-update: branch has no upstream; nothing to update from: $source"

  old_short=$(git -C "$source" rev-parse --short HEAD) \
    || jig_die "self-update: cannot read HEAD: $source"
  old_version=$(jig_version_of "$global") \
    || jig_die "self-update: cannot read the current version: $global"

  # Not `if ! git ...; then rc=$?`: `!` itself sets $? to 0/1 (negated), so
  # that idiom always captures 0 here, discarding git's real status. `cmd ||
  # rc=$?` captures it before the negation, and the assignment's own success
  # keeps `set -e` from firing on git's failure.
  rc=0
  git -C "$source" pull --ff-only || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'jig: error: self-update: git pull --ff-only failed\n' >&2
    exit "$rc"
  fi

  new_short=$(git -C "$source" rev-parse --short HEAD) \
    || jig_die "self-update: cannot read HEAD: $source"
  new_version=$(jig_version_of "$global") \
    || jig_die "self-update: cannot read the updated version: $global"

  if [ "$new_short" = "$old_short" ]; then
    printf 'self-update: already current at %s (%s)\n' "$old_version" "$old_short"
  elif [ "$new_version" = "$old_version" ]; then
    printf 'self-update: source updated, version unchanged at %s (%s -> %s)\n' \
      "$old_version" "$old_short" "$new_short"
  else
    printf 'self-update: updated %s -> %s (%s)\n' "$old_version" "$new_version" "$new_short"
  fi
}

# _self_update_detached <source> <global> — the checkout is detached. The
# current release is the newest release tag pointing at HEAD; anything else
# (a plain commit, a non-release tag) is refused. Fetches tags, and moves to
# the newest release tag only when it is strictly newer (jig_version_newer),
# never backwards. After moving, the executable's reported version must equal
# the tag's version or the discrepancy is reported and the command fails
# (design AC-01).
_self_update_detached() {
  local source="$1" global="$2"
  local old_short old_commit old_version current_tag current_version rc
  local newest_tag="" newest_version="" new_short new_version

  old_short=$(git -C "$source" rev-parse --short HEAD) \
    || jig_die "self-update: cannot read HEAD: $source"
  old_commit=$(git -C "$source" rev-parse HEAD) \
    || jig_die "self-update: cannot read HEAD: $source"
  old_version=$(jig_version_of "$global") \
    || jig_die "self-update: cannot read the current version: $global"

  current_tag=$(git -C "$source" tag --points-at HEAD 2>/dev/null | jig_newest_release) \
    || jig_die "self-update: detached at a commit that is not a release tag: $source"
  current_version=$(jig_release_version "$current_tag")

  # See _self_update_branch: `cmd || rc=$?`, never `if ! cmd; then rc=$?`.
  rc=0
  git -C "$source" fetch --tags origin || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'jig: error: self-update: git fetch --tags origin failed\n' >&2
    exit "$rc"
  fi

  if newest_tag=$(git -C "$source" tag -l | jig_newest_release); then
    newest_version=$(jig_release_version "$newest_tag")
  fi

  if [ -n "$newest_tag" ] && jig_version_newer "$newest_version" "$current_version"; then
    git -C "$source" checkout -q --detach "$newest_tag" \
      || jig_die "self-update: checkout of $newest_tag failed: $source"
    new_short=$(git -C "$source" rev-parse --short HEAD) \
      || jig_die "self-update: cannot read HEAD: $source"
    new_version=$(jig_version_of "$global") || new_version=""
    if [ "$new_version" != "$newest_version" ]; then
      # Go back before failing. Left on the bad tag, every later command would
      # run a release that disagrees with its own name, and the next
      # self-update would read that tag as current and report nothing wrong.
      printf 'jig: error: self-update: %s reports version %s (expected %s); staying at %s\n' \
        "$newest_tag" "${new_version:-unknown}" "$newest_version" "$old_version" >&2
      git -C "$source" checkout -q --detach "$old_commit" \
        || jig_die "self-update: could not return to $old_short after the failed update: $source"
      exit 1
    fi
    printf 'self-update: updated %s -> %s (%s)\n' "$old_version" "$new_version" "$new_short"
  else
    printf 'self-update: already current at %s (%s)\n' "$old_version" "$old_short"
  fi
}

cmd_self_update() {
  local global self_phys source

  global=$(jig_global_executable) \
    || jig_die "self-update: no global jig on PATH; install it with: curl -fsSL https://raw.githubusercontent.com/fapost-lab/jig/main/install.sh | bash"

  # JIG_SELF is already symlink-resolved (dispatcher); made physical the same
  # way jig_global_executable makes its own answer physical, so the two
  # compare equal in link mode (AC-11) instead of differing only by a
  # non-canonical directory component.
  self_phys=$(jig_physical_path "$JIG_SELF") \
    || jig_die "self-update: cannot resolve the running executable: $JIG_SELF"

  if [ "$self_phys" != "$global" ]; then
    if [ -n "${JIG_SELF_UPDATE_DELEGATED:-}" ]; then
      jig_die "self-update: delegation loop: $global still differs from $self_phys"
    fi
    JIG_SELF_UPDATE_DELEGATED=1 exec "$global" self-update "$@" \
      || jig_die "self-update: could not delegate to $global"
  fi

  [ $# -eq 0 ] || jig_die "self-update: unknown argument: $1"

  source="${global%/scripts/jig}"
  _self_update_validate_source "$source"

  if git -C "$source" symbolic-ref -q HEAD >/dev/null 2>&1; then
    _self_update_branch "$source" "$global"
  else
    _self_update_detached "$source" "$global"
  fi
}

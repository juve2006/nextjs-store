# The forge cache: what housekeeping last heard from the forge about pull
# requests, kept so that a read never asks the forge itself
# (adr-20261015-a-read-is-one-json-envelope; schemas/json.md). Written by
# `jig housekeeping` from the list it already fetches, read by
# `jig task list --json`.
#
#   .ai/runtime/forge-cache, one line per pull request, newest first as the
#   forge listed them:
#     <head><TAB><base><TAB><state><TAB><ci><TAB><fetched_at>
#   <state> open|merged|closed; <ci> green|red|pending|none, `-` when it was
#   not asked (a pull request that is not open, a forge that does not list it);
#   <fetched_at> UTC, when the forge said so. Lines starting with `#` are
#   comments.
#
# The file lives in the runtime directory of the checkout that owns the task
# workspaces: a worktree that borrows the owner's `tasks/` (ADR-0029) reads the
# owner's file and never writes it, so one clone has one cache.
#
# Depends on `_task_borrowed_tasks_root` (lib/task.sh): a caller sources task.sh
# first, as for lib/hklog.sh.
# shellcheck shell=bash

# forgecache_file — the cache's path, in the owner's runtime directory when this
# checkout borrows its task workspaces.
forgecache_file() {
  local borrowed
  if borrowed=$(_task_borrowed_tasks_root); then
    printf '%s/runtime/forge-cache\n' "${borrowed%/workspace/tasks}"
    return 0
  fi
  printf '%s/%s/runtime/forge-cache\n' "$JIG_PROJECT" "$JIG_AI_DIR"
}

# forgecache_owned — exit 0 when this checkout keeps the cache it reads: not
# when it borrows the owner's task workspaces, whose housekeeping keeps the
# owner's cache. A writer asks before it asks the forge for anything.
forgecache_owned() {
  ! _task_borrowed_tasks_root >/dev/null
}

# forgecache_write <rows> — replace the cache with <rows>, atomically. Does
# nothing in a checkout that does not own its cache (forgecache_owned). Never
# fails the caller: a cache that could not be written is the old one, whose
# entries still say how old they are.
forgecache_write() {
  local rows="$1" file tmp
  forgecache_owned || return 0
  file=$(forgecache_file)
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  {
    printf '# jig forge cache: <head> <base> <state> <ci> <fetched_at>, written by jig housekeeping\n'
    [ -z "$rows" ] || printf '%s\n' "$rows"
  } > "$tmp" 2>/dev/null || return 0
  mv "$tmp" "$file" 2>/dev/null || return 0
  # `task list --json` reports what the cache holds, so a written cache raises
  # the clone's revision (adr-20261016-the-clone-revision-is-a-claimed-name).
  # housekeeping, today's one writer, raises it again when its run ends; this
  # one keeps any other writer from forgetting.
  jig_record_changed
  return 0
}

# forgecache_read — the cache's lines, comments left out; nothing when there is
# no cache.
forgecache_read() {
  local file
  file=$(forgecache_file)
  [ -f "$file" ] || return 0
  sed '/^#/d;/^$/d' "$file" 2>/dev/null || true
}

# forgecache_entry <cache> <head> <base> — sets _FORGECACHE_STATE, _FORGECACHE_CI
# and _FORGECACHE_AT from the first line of <cache> (forgecache_read's output)
# for a pull request from <head> into <base>: the newest, as the forge lists
# them and as housekeeping's own remote state takes it. Each is empty when the
# cache does not say. In the caller's shell, without a process per lookup.
_FORGECACHE_STATE=""
_FORGECACHE_CI=""
_FORGECACHE_AT=""
forgecache_entry() {
  local cache="$1" head="$2" base="$3" t nl rest line
  _FORGECACHE_STATE=""
  _FORGECACHE_CI=""
  _FORGECACHE_AT=""
  [ -n "$cache" ] && [ -n "$head" ] && [ -n "$base" ] || return 0
  t=$(printf '\t')
  nl=$'\n'
  rest=${nl}${cache}
  case "$rest" in
    *"$nl$head$t$base$t"*) ;;
    *) return 0 ;;
  esac
  rest=${rest#*"$nl$head$t$base$t"}
  line=${rest%%"$nl"*}
  IFS="$t" read -r _FORGECACHE_STATE _FORGECACHE_CI _FORGECACHE_AT <<EOF
$line
EOF
  [ "$_FORGECACHE_CI" != "-" ] || _FORGECACHE_CI=""
  return 0
}

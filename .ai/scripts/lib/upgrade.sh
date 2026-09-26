# cmd_upgrade — update framework-owned files from a source checkout without
# touching files the user changed (domains/install decision table, ADR-0003).
# Sourced by scripts/jig; defines cmd_upgrade.
# shellcheck shell=bash

# Unconditional report output (one line per non-trivial action, copy or link
# mode alike), suppressed only by this command's own --quiet flag.
# Deliberately NOT jig_log/JIG_QUIET, see scripts/lib/init.sh's _init_out for
# why. Relies on bash's dynamic scope: `quiet` is cmd_upgrade's local
# variable, seen by every helper it calls (directly or transitively).
_upgrade_out() { [ "${quiet:-0}" = 1 ] || printf '%s\n' "$*"; }

# --- staging: build the tree the source would install right now -----------

# _upgrade_build_staged <source> <stage> <profiles> <adapters>
# Populates <stage> with exactly the framework-owned files the given source
# checkout would install for the given active profiles/adapters, mirroring
# the manifest path layout (.ai/scripts/**, .ai/profiles/<p>/**,
# <skills_dir>/<skill>/**). Not conflict-aware: plain overwrite into a
# scratch directory, so it is safe to always rebuild from scratch.
_upgrade_build_staged() {
  local source="$1" stage="$2" profiles="$3" adapters="$4" p a skill_dir
  local src_pdir stage_pdir adir
  mkdir -p "$stage/.ai/scripts" "$stage/.ai/profiles" \
    "$stage/.ai/templates/knowledge" "$stage/.ai/templates/scheduler" \
    "$stage/.ai/templates/spec"

  jig_copy_tree "$source/scripts" "$stage/.ai/scripts"
  jig_copy_tree "$source/templates/knowledge" "$stage/.ai/templates/knowledge"
  jig_copy_tree "$source/templates/scheduler" "$stage/.ai/templates/scheduler"
  jig_copy_tree "$source/templates/spec" "$stage/.ai/templates/spec"
  # The instructions template is framework-owned (ADR-0011): the `jig-init`
  # skill reads the marked Jig section from it in a project that has no
  # framework checkout to read it from. The project's own AGENTS.md is not
  # staged and never will be — it stays project-owned, and only the region
  # between its markers is jig's to replace (see _upgrade_section).
  cp -p "$source/templates/AGENTS.md" "$stage/.ai/templates/AGENTS.md"

  for p in $profiles; do
    src_pdir=$(profiles_dir "$source/profiles" "$p")
    [ -d "$src_pdir" ] || continue
    stage_pdir=$(profiles_dir "$stage/.ai/profiles" "$p")
    jig_copy_tree "$src_pdir" "$stage_pdir"
  done

  for a in $adapters; do
    adir=$(adapters_dir "$source/adapters" "$a")
    [ -f "$adir/adapter.sh" ] || continue
    for skill_dir in "$source"/skills/*/; do
      [ -d "$skill_dir" ] || continue
      skill_dir="${skill_dir%/}"
      "adapter_${a}_install_skill" "$skill_dir" "$stage" > /dev/null
    done
  done
}

# --- shared helpers (both modes) --------------------------------------------

# _upgrade_source_version <source> — the framework version a source checkout
# declares in scripts/lib/version.sh, falling back to the running
# dispatcher's own $JIG_VERSION when it cannot be read. Mirrors init.sh's
# _init_source_version.
_upgrade_source_version() {
  local version
  version=$(sed -n 's/^JIG_VERSION="\(.*\)"/\1/p' "$1/scripts/lib/version.sh" | head -n 1)
  [ -n "$version" ] || version="$JIG_VERSION"
  printf '%s\n' "$version"
}

# _upgrade_csv <words> — space-separated words joined as "a, b, c" for the
# manifest's `adapters: [...]` header line.
_upgrade_csv() {
  local w out=""
  for w in $1; do
    if [ -z "$out" ]; then out="$w"; else out="$out, $w"; fi
  done
  printf '%s\n' "$out"
}

# _upgrade_same_dir <a> <b> — whether two paths name the same directory.
# Compared as physical paths (`pwd -P`), the way manifest_write_entries
# compares the source with the project: the same checkout can be reached
# through a symlinked parent (a TMPDIR under /var on macOS) and spelled two
# ways. A path that cannot be entered — a source checkout since deleted —
# falls back to its own text, so it still equals itself; an empty path is
# never equal to anything, because `cd ""` succeeds and would otherwise
# answer with the current directory.
_upgrade_same_dir() {
  local a b
  [ -n "$1" ] || return 1
  [ -n "$2" ] || return 1
  a=$(cd "$1" 2>/dev/null && pwd -P) || a="$1"
  b=$(cd "$2" 2>/dev/null && pwd -P) || b="$2"
  [ "$a" = "$b" ]
}

# _upgrade_records_source <source> <applied-count> — whether this run may
# rewrite `.ai/manifest` with <source> in its header
# (adr-20260922-upgrade-records-the-source-it-installed-from).
#
# An upgrade that applied nothing has not made the project an install of
# <source>: every framework-owned path still comes from wherever it came from
# before. Writing the header anyway would record a checkout no file of this
# project came from, and the next plain `jig upgrade` would read from there
# without anyone asking for it.
#
# The recorded source is writable whether or not anything was applied: there
# the header only restates where the project already comes from, and
# `jig.version` must keep following that checkout — in link mode the project
# runs the source's scripts directly, so its version moves with the source
# even when no link is created.
_upgrade_records_source() {
  local recorded
  [ "$2" = 0 ] || return 0
  recorded=$(manifest_source)
  _upgrade_same_dir "$1" "$recorded"
}

# _upgrade_summary <placed> <kept> <removed> <conflicts> <manifest-state>
# The one line every run ends with, in both modes, so that "nothing happened"
# is reported rather than left to silence. `manifest <state>` is the part the
# reader needs most: an upgrade can end with no file placed and no manifest
# written at all, and until it said so that was invisible.
_upgrade_summary() {
  local line="jig upgrade: $1 placed, $2 kept"
  if [ "$3" != 0 ]; then line="$line, $3 removed"; fi
  _upgrade_out "$line, $4 conflict(s); manifest $5"
}

# _upgrade_kept_source_note <source> <mode> — why the manifest still names
# another checkout, and the command that does change it. `init` is that
# command: choosing where a project's framework comes from is an install
# decision, and `upgrade` only carries an existing install forward.
_upgrade_kept_source_note() {
  local source="$1" link_flag=""
  if [ "$2" = link ]; then link_flag=" --link"; fi
  _upgrade_out "nothing was placed from $source, so this project stays installed from $(manifest_source)"
  _upgrade_out "hint: to install it from that checkout instead, run \`jig init$link_flag --from $source\`"
}

# _upgrade_config_note <dry-run> — after a real run, one line when the
# project's .ai/config.yaml says nothing about keys this version reads.
#
# Nothing here writes that file, and nothing ever will (ADR-0024): an upgrade
# brings new scripts, and the file that says what they may be told stays the
# team's, exactly as it was. But an upgrade is the moment the two part
# company, and saying so once, here, is the whole difference between a
# capability somebody was offered and one they merely have. `jig doctor`
# repeats it on demand; `jig status` does not, because an unmentioned key is
# something to look at, not anything a task is waiting on.
#
# Silent on a dry run, and silent when there is nothing to say.
_upgrade_config_note() {
  if [ "$1" = 1 ]; then return 0; fi
  local keys n
  keys=$(jig_config_unmentioned | tr '\n' ' ' | sed 's/ $//')
  [ -n "$keys" ] || return 0
  n=$(printf '%s\n' "$keys" | wc -w | tr -d ' ')
  _upgrade_out "$JIG_AI_DIR/config.yaml does not mention $n key(s) this version reads, each on its default: $(printf '%s\n' "$keys" | sed 's/ /, /g')"
  # shellcheck disable=SC2016
  _upgrade_out 'hint: `jig config keys` lists them; that file is yours to change or leave as it is'
}

# --- decision table (domains/install) ---------------------------------------------

# _upgrade_place <staged-abs> <local-abs> — copy one staged file into the
# project through a temporary name beside it, then rename over the
# destination.
#
# Never `cp` straight onto the destination: `cp` truncates and rewrites the
# file in place, keeping its inode, and one of the files an upgrade replaces
# is `.ai/scripts/jig` — the script bash is executing at that moment. Bash
# reads a script incrementally from an open descriptor, so once the running
# copy grew, it read on past the end of the version it had started and
# executed whatever the new bytes happened to say at that offset. `rename`
# gives the destination a new inode and leaves the one the running shell holds
# open untouched, so it reaches its own end of file and exits. The temporary
# lives in the destination's directory so the rename stays on one filesystem.
_upgrade_place() {
  local staged_abs="$1" local_abs="$2" tmp="$2.tmp.$$"
  mkdir -p "$(dirname "$local_abs")"
  cp -p "$staged_abs" "$tmp" || jig_die "upgrade: could not write $local_abs"
  mv -f "$tmp" "$local_abs" || jig_die "upgrade: could not write $local_abs"
}

# _upgrade_process_path <rel> <stage-dir> <dry-run> <manifest-hash>
#                       <local-hash> <staged-hash>
# Applies one row of the upgrade decision table to a single framework-owned
# path and appends the resulting manifest line ("<hash> <path>") to the
# caller's `new_entries` variable (dynamic scope; cmd_upgrade declares it
# local, along with the placed_count/kept_count/removed_count/conflict_count
# tally this function keeps for the run summary). Prints one report line per
# non-trivial action.
#
# The three hashes come precomputed from _upgrade_hash_table, empty when the
# path is absent from the manifest, the project or the stage respectively, so
# this function starts no process of its own for a path it leaves alone.
_upgrade_process_path() {
  local rel="$1" stage="$2" dry_run="$3" manifest_hash="$4" local_hash="$5" staged_hash="$6"
  local staged_abs="$stage/$rel" staged_exists local_abs local_exists
  local in_manifest action

  if [ -n "$staged_hash" ]; then staged_exists=1; else staged_exists=0; fi
  if [ -n "$manifest_hash" ]; then in_manifest=1; else in_manifest=0; fi
  local_abs="$JIG_PROJECT/$rel"
  if [ -n "$local_hash" ]; then local_exists=1; else local_exists=0; fi

  if [ "$staged_exists" = 1 ] && [ "$in_manifest" = 1 ]; then
    if [ "$local_exists" = 0 ]; then
      action=install # tracked but missing locally: reinstall
    elif [ "$local_hash" = "$manifest_hash" ]; then
      action=replace
    else
      action=keep-modified
    fi
  elif [ "$staged_exists" = 1 ] && [ "$in_manifest" = 0 ]; then
    if [ "$local_exists" = 0 ]; then
      action=install
    else
      action=keep-conflict
    fi
  elif [ "$staged_exists" = 0 ] && [ "$in_manifest" = 1 ]; then
    if [ "$local_exists" = 0 ] || [ "$local_hash" = "$manifest_hash" ]; then
      action=delete
    else
      action=keep-orphaned-modified
    fi
  else
    return 0 # not in new version and not tracked: not in the union, unreachable
  fi

  case "$action" in
    replace)
      if [ "$staged_hash" != "$local_hash" ]; then
        if [ "$dry_run" != 1 ]; then
          _upgrade_place "$staged_abs" "$local_abs"
        fi
        _upgrade_out "replace $rel"
        placed_count=$((placed_count + 1))
      else
        kept_count=$((kept_count + 1))
      fi
      new_entries="$new_entries
$staged_hash $rel"
      ;;
    install)
      if [ "$dry_run" != 1 ]; then
        _upgrade_place "$staged_abs" "$local_abs"
      fi
      _upgrade_out "install $rel"
      placed_count=$((placed_count + 1))
      new_entries="$new_entries
$staged_hash $rel"
      ;;
    keep-modified)
      _upgrade_out "keep-modified $rel"
      kept_count=$((kept_count + 1))
      new_entries="$new_entries
$manifest_hash $rel"
      ;;
    keep-conflict)
      _upgrade_out "keep-conflict $rel"
      conflict_count=$((conflict_count + 1))
      ;;
    keep-orphaned-modified)
      _upgrade_out "keep-orphaned-modified $rel"
      kept_count=$((kept_count + 1))
      new_entries="$new_entries
$manifest_hash $rel"
      ;;
    delete)
      # The one deletion outside `.ai/` (RULES.md): a file this framework
      # installed, recorded in the manifest with the hash it installed and
      # unchanged since, which the new version no longer ships. Only under
      # `.ai/` or an adapter's skills directory, and never through `..`: the
      # manifest is a file in the project, and a path in it is not proof.
      if ! _upgrade_deletable "$rel"; then
        _upgrade_out "keep-outside $rel"
        kept_count=$((kept_count + 1))
        new_entries="$new_entries
$manifest_hash $rel"
        return 0
      fi
      if [ "$dry_run" != 1 ]; then
        rm -f "$local_abs"
      fi
      _upgrade_out "delete $rel"
      removed_count=$((removed_count + 1))
      ;;
  esac
}

# --- the marked instructions section ----------------------------------------

# Outputs of _upgrade_section for its caller, because the two modes keep
# different tallies (copy counts `placed`, link counts `created`) and bash 3.2
# has no namerefs. The caller reads the action to bump its own counters and
# the record to hand to the manifest writer.
_UPGRADE_SECTION_ACTION=""
_UPGRADE_SECTION_RECORD=""
_UPGRADE_SECTION_TMP=""

# _upgrade_section <source> <dry-run>
# The same decision table as _upgrade_process_path, applied to the region
# between the markers in the project's own AGENTS.md instead of to a whole
# file (adr-20260924-jig-owns-a-marked-section-of-the-instructions). Prints
# one report line per non-trivial outcome and sets the two variables above.
#
# The record in the manifest header is what separates "jig wrote this and may
# keep it current" from "somebody else's text that happens to sit between
# markers". Without it, every outcome here is a `keep-`: upgrade never adopts
# a section, because the first time jig claims a region of a file the project
# already had is a moment that belongs to a human. `jig init` is where that
# claim is made, on markers a human consented to (the `jig-init` skill).
#
# | record | markers   | text                | outcome        |
# |--------|-----------|---------------------|----------------|
# | no     | none      |                     | keep-unmarked  |
# | no     | ok        |                     | keep-conflict  |
# | no     | malformed |                     | keep-malformed |
# | yes    | ok        | = record, = source  | (silent)       |
# | yes    | ok        | = record, ≠ source  | replace        |
# | yes    | ok        | ≠ record            | keep-modified  |
# | yes    | none      | the section removed | keep-modified  |
# | yes    | malformed |                     | keep-malformed |
_upgrade_section() {
  local source="$1" dry_run="$2"
  local file="$JIG_PROJECT/AGENTS.md" template="$source/templates/AGENTS.md"
  local recorded rec_hash state cur_hash new_hash

  _UPGRADE_SECTION_ACTION=""
  recorded=$(manifest_instructions_section)
  _UPGRADE_SECTION_RECORD="$recorded"
  rec_hash="${recorded%% *}"

  # A project-owned file jig never restores once it is gone (ADR-0003), and a
  # source with no template to read a new section from: nothing to say.
  if [ ! -f "$file" ] || [ ! -f "$template" ]; then
    return 0
  fi

  state=$(jig_section_state "$file")

  if [ -z "$recorded" ]; then
    case "$state" in
      absent)
        _UPGRADE_SECTION_ACTION=keep-unmarked
        _upgrade_out "keep-unmarked AGENTS.md"
        _upgrade_out "  its Jig section is not marked, so upgrades cannot reach it; the jig-init skill adds the markers"
        ;;
      malformed)
        _UPGRADE_SECTION_ACTION=keep-malformed
        _upgrade_out "keep-malformed AGENTS.md (Jig section)"
        _upgrade_out "  expected one $JIG_SECTION_BEGIN and one $JIG_SECTION_END, in that order"
        ;;
      *)
        _UPGRADE_SECTION_ACTION=keep-conflict
        _upgrade_out "keep-conflict AGENTS.md (Jig section)"
        _upgrade_out "  jig did not write this section, so it does not update it; run \`jig init\` to adopt it"
        ;;
    esac
    return 0
  fi

  if [ "$state" = malformed ]; then
    _UPGRADE_SECTION_ACTION=keep-malformed
    _upgrade_out "keep-malformed AGENTS.md (Jig section)"
    _upgrade_out "  expected one $JIG_SECTION_BEGIN and one $JIG_SECTION_END, in that order"
    return 0
  fi

  # The markers are gone: somebody removed the section on purpose, and an
  # upgrade never restores what a human removed (the same conclusion ADR-0024
  # reached about a deleted session-hook line).
  if [ "$state" = absent ]; then
    _UPGRADE_SECTION_ACTION=keep-modified
    _upgrade_out "keep-modified AGENTS.md (Jig section)"
    return 0
  fi

  cur_hash=$(jig_section_hash "$file")
  if [ "$cur_hash" != "$rec_hash" ]; then
    _UPGRADE_SECTION_ACTION=keep-modified
    _upgrade_out "keep-modified AGENTS.md (Jig section)"
    return 0
  fi

  new_hash=$(jig_section_hash "$template")
  if [ "$new_hash" = "$cur_hash" ]; then
    return 0 # already current, and silent like every other unchanged path
  fi

  if [ "$dry_run" != 1 ]; then
    _UPGRADE_SECTION_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-upgrade-section.XXXXXX")
    jig_section_read "$template" > "$_UPGRADE_SECTION_TMP"
    jig_section_write "$file" "$_UPGRADE_SECTION_TMP" \
      || jig_die "upgrade: could not replace the Jig section of AGENTS.md"
    rm -f "$_UPGRADE_SECTION_TMP"
    _UPGRADE_SECTION_TMP=""
  fi
  _UPGRADE_SECTION_ACTION=replace
  _UPGRADE_SECTION_RECORD="$new_hash AGENTS.md"
  _upgrade_out "replace AGENTS.md (Jig section)"
}

# _upgrade_deletable <rel> — true when <rel> is a relative path with no `..`
# component under one of _UPGRADE_DELETE_ROOTS.
_upgrade_deletable() {
  local rel="$1" root
  case "$rel" in
    '' | /* | .. | ../* | */.. | */../*) return 1 ;;
  esac
  for root in $_UPGRADE_DELETE_ROOTS; do
    case "$rel" in
      "$root"/*) return 0 ;;
    esac
  done
  return 1
}

# _upgrade_hash_table <union-file> <stage-dir> <work-dir>
# Prints one line per path in <union-file>: "<path>\t<manifest>\t<local>\t<staged>",
# each hash `-` when the path is absent from that side.
#
# Built once for the whole union — one pass over the manifest, one
# `git hash-object` for the project's files and one for the stage's — instead
# of a manifest reread and up to three git startups per path. On a 72-file
# install that per-path loop was most of the 3.5 s `jig status` spent asking
# whether anything was pending. `-`, not an empty field: `read` treats tab as
# whitespace and would collapse two adjacent separators into one.
_upgrade_hash_table() {
  local union="$1" stage="$2" work="$3" rel
  : > "$work/local.paths"
  : > "$work/staged.paths"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -f "$JIG_PROJECT/$rel" ]; then
      printf '%s\n' "$rel" >> "$work/local.paths"
    fi
    if [ -f "$stage/$rel" ]; then
      printf '%s\n' "$rel" >> "$work/staged.paths"
    fi
  done < "$union"
  jig_hash_list "$JIG_PROJECT" "$work/local.paths" > "$work/local.hashes" \
    || jig_die "upgrade: could not hash the installed files"
  jig_hash_list "$stage" "$work/staged.paths" > "$work/staged.hashes" \
    || jig_die "upgrade: could not hash the staged files"

  # Tagged streams in one awk: a per-file `NR == FNR` join goes wrong as soon
  # as one of the inputs is empty (conventions/shell.md).
  {
    manifest_entries | sed 's/^/M /'
    paste -d' ' "$work/local.hashes" "$work/local.paths" | sed 's/^/L /'
    paste -d' ' "$work/staged.hashes" "$work/staged.paths" | sed 's/^/S /'
    sed 's/^/U /' "$union"
  } | awk '
    function rest(n,   i, s) { s = $0; for (i = 0; i < n; i++) s = substr(s, index(s, " ") + 1); return s }
    function or_dash(v) { return v == "" ? "-" : v }
    $1 == "M" { m[rest(2)] = $2; next }
    $1 == "L" { l[rest(2)] = $2; next }
    $1 == "S" { st[rest(2)] = $2; next }
    $1 == "U" { p = rest(1); if (p != "") print p "\t" or_dash(m[p]) "\t" or_dash(l[p]) "\t" or_dash(st[p]) }
  '
}

# --- link mode ---------------------------------------------------------------

# _upgrade_link_one <target-abs> <link-abs> <dry-run>
# Places one relative symlink through init.sh's _init_place_symlink
# (dynamic scope: kept_count/created_count/conflict_count/conflict_paths are
# _upgrade_link's locals — same pattern _upgrade_process_path uses for
# new_entries) and reports the outcome, one line per non-trivial action,
# the same way the copy-mode decision table does.
_upgrade_link_one() {
  local target_abs="$1" link_abs="$2" dry_run="$3" rel before_created before_conflict
  rel=$(jig_relpath "$link_abs" "$JIG_PROJECT")
  before_created=$created_count
  before_conflict=$conflict_count
  _init_place_symlink "$target_abs" "$link_abs" "$dry_run"
  if [ "$created_count" != "$before_created" ]; then
    _upgrade_out "link $rel"
  elif [ "$conflict_count" != "$before_conflict" ]; then
    _upgrade_out "keep-conflict $rel"
  fi
}

# _upgrade_link <source> <active-profiles> <active-adapters> <dry-run>
# Link mode's "upgrade": rather than the no-op it used to be, ensure every
# framework-owned item for the *current* config is linked — .ai/scripts,
# each active profile, each active adapter's skills — exactly the way
# `jig init --link` places them (domains/install). Sources init.sh for
# _init_place_symlink/_init_relpath so the two relative-symlink code paths
# never diverge; sourcing a command library only defines its functions, it
# does not run cmd_init.
_upgrade_link() {
  local source="$1" active_profiles="$2" active_adapters="$3" dry_run="$4"
  # shellcheck source=lib/init.sh
  . "$JIG_LIB/init.sh"

  # conflict_paths is required by _init_place_symlink's dynamic-scope
  # contract (it appends to it unconditionally) even though this caller
  # never reads the list back — _upgrade_link_one already reports each
  # conflict immediately, one line per path, as it happens.
  # shellcheck disable=SC2034
  local created_count=0 kept_count=0 conflict_count=0 conflict_paths=""
  local p a skill_dir sname sdir pdir adir dest_pdir

  _upgrade_link_one "$(cd "$source/scripts" && pwd)" "$JIG_PROJECT/.ai/scripts" "$dry_run"
  _upgrade_link_one "$(cd "$source/templates/knowledge" && pwd)" \
    "$JIG_PROJECT/.ai/templates/knowledge" "$dry_run"
  _upgrade_link_one "$(cd "$source/templates/scheduler" && pwd)" \
    "$JIG_PROJECT/.ai/templates/scheduler" "$dry_run"
  _upgrade_link_one "$(cd "$source/templates/spec" && pwd)" \
    "$JIG_PROJECT/.ai/templates/spec" "$dry_run"
  # A file link, not a directory one: the instructions template is a single
  # framework-owned file (ADR-0011, and see _upgrade_build_staged).
  _upgrade_link_one "$source/templates/AGENTS.md" \
    "$JIG_PROJECT/.ai/templates/AGENTS.md" "$dry_run"

  for p in $active_profiles; do
    pdir=$(profiles_dir "$source/profiles" "$p")
    [ -d "$pdir" ] || continue
    dest_pdir=$(profiles_dir "$JIG_PROJECT/.ai/profiles" "$p")
    _upgrade_link_one "$(cd "$pdir" && pwd)" "$dest_pdir" "$dry_run"
  done

  for a in $active_adapters; do
    adir=$(adapters_dir "$source/adapters" "$a")
    [ -f "$adir/adapter.sh" ] || continue
    sdir=$("adapter_${a}_skills_dir")
    for skill_dir in "$source"/skills/*/; do
      [ -d "$skill_dir" ] || continue
      skill_dir="${skill_dir%/}"
      sname=$(basename "$skill_dir")
      _upgrade_link_one "$skill_dir" "$JIG_PROJECT/$sdir/$sname" "$dry_run"
    done
  done

  # The marked instructions section is decided the same way in both modes:
  # the record it rests on lives in the manifest header, and link mode writes
  # a header too (it is only the body it has no use for).
  _upgrade_section "$source" "$dry_run"
  case "$_UPGRADE_SECTION_ACTION" in
    replace) created_count=$((created_count + 1)) ;;
    keep-modified | keep-malformed | keep-unmarked) kept_count=$((kept_count + 1)) ;;
    keep-conflict) conflict_count=$((conflict_count + 1)) ;;
  esac

  if [ "$dry_run" = 1 ]; then
    _upgrade_summary "$created_count" "$kept_count" 0 "$conflict_count" "unchanged (dry run)"
    return 0
  fi

  # A link-mode run places or it does not: there is nothing in between, and
  # no manifest body to keep either. So an upgrade whose every path was a
  # conflict leaves the file exactly as it was, source and version included
  # (adr-20260922-upgrade-records-the-source-it-installed-from).
  if _upgrade_records_source "$source" "$created_count"; then
    local version adapters_manifest
    version=$(_upgrade_source_version "$source")
    adapters_manifest=$(_upgrade_csv "$active_adapters")
    manifest_write_entries "$version" "$source" "$adapters_manifest" "link" \
      "$_UPGRADE_SECTION_RECORD" < /dev/null
    _upgrade_summary "$created_count" "$kept_count" 0 "$conflict_count" "updated"
  else
    _upgrade_summary "$created_count" "$kept_count" 0 "$conflict_count" "unchanged"
    _upgrade_kept_source_note "$source" "link"
  fi
}

# --- cmd_upgrade -------------------------------------------------------------

# Staging directory / union-of-paths temp file / hash-table work directory for
# the current cmd_upgrade run. Script-global (not `local`) so the EXIT/INT/TERM cleanup trap below
# still sees them if the process dies mid-run — same pattern as
# scripts/lib/knowledge.sh's KM_*_FILE variables.
_UPGRADE_STAGE=""
_UPGRADE_UNION_FILE=""
_UPGRADE_WORK=""
# Where an orphan may be deleted: `.ai/` and every adapter's skills directory,
# filled in once the adapters are sourced (see _upgrade_deletable).
_UPGRADE_DELETE_ROOTS=""

cmd_upgrade() {
  local from="" dry_run=0 quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || jig_die "upgrade: --from requires a value"; from="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --quiet) quiet=1; shift ;;
      *) jig_die "upgrade: unknown argument: $1" ;;
    esac
  done
  jig_require_init
  # shellcheck source=lib/manifest.sh
  . "$JIG_LIB/manifest.sh"
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"
  # shellcheck source=lib/section.sh
  . "$JIG_LIB/section.sh"

  trap '[ -n "$_UPGRADE_STAGE" ] && rm -rf "$_UPGRADE_STAGE"
        [ -n "$_UPGRADE_UNION_FILE" ] && rm -f "$_UPGRADE_UNION_FILE"
        [ -n "$_UPGRADE_SECTION_TMP" ] && rm -f "$_UPGRADE_SECTION_TMP"
        [ -n "$_UPGRADE_WORK" ] && rm -rf "$_UPGRADE_WORK"' EXIT INT TERM

  local source
  if [ -n "$from" ]; then
    [ -d "$from" ] || jig_die "upgrade: --from directory does not exist: $from"
    source=$(cd "$from" && pwd)
  else
    source=$(jig_source_root)
    [ -n "$source" ] || source=$(manifest_source)
  fi
  if [ -z "$source" ] || [ ! -d "$source" ]; then
    jig_die "upgrade: cannot determine the framework source root; pass --from <dir>"
  fi
  jig_is_source_root "$source" \
    || jig_die "upgrade: not a framework source root (missing skills/, templates/ or scripts/jig): $source"

  # Source every adapter known to the source checkout (not just the ones
  # active in config) so manifest paths owned by a since-deactivated adapter
  # are still recognised as framework-owned and can be deleted.
  local adapter_dir a
  for adapter_dir in "$source"/adapters/*/; do
    [ -d "$adapter_dir" ] || continue
    [ -f "$adapter_dir/adapter.sh" ] || continue
    # shellcheck disable=SC1090,SC1091
    . "$adapter_dir/adapter.sh"
    a=$(basename "$adapter_dir")
    if command -v "adapter_${a}_skills_dir" >/dev/null 2>&1; then
      _UPGRADE_DELETE_ROOTS="$_UPGRADE_DELETE_ROOTS $("adapter_${a}_skills_dir")"
    fi
  done
  _UPGRADE_DELETE_ROOTS=".ai$_UPGRADE_DELETE_ROOTS"

  local active_profiles active_adapters
  active_profiles=$(cfg_list profiles generic)
  active_adapters=$(cfg_list adapters "claude codex")

  local mode
  mode=$(manifest_header_get jig.mode)
  if [ "$mode" = "link" ]; then
    # The same refusal as `init --link`, for the same reason: where `ln -s`
    # copies, every "missing link" would be placed as a copy of the source.
    jig_link_detect
    [ "$_JIG_LINK_KIND" = symlink ] \
      || jig_die "upgrade: this project is installed in link mode, which needs symbolic links, and they cannot be made here"
    _upgrade_link "$source" "$active_profiles" "$active_adapters" "$dry_run"
    _upgrade_config_note "$dry_run"
    return 0
  fi

  _UPGRADE_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/jig-upgrade-stage.XXXXXX")
  _upgrade_build_staged "$source" "$_UPGRADE_STAGE" "$active_profiles" "$active_adapters"

  _UPGRADE_UNION_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-upgrade-union.XXXXXX")
  { (cd "$_UPGRADE_STAGE" && find . -type f | sed 's|^\./||'); manifest_paths; } | sort -u > "$_UPGRADE_UNION_FILE"

  _UPGRADE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/jig-upgrade-work.XXXXXX")
  _upgrade_hash_table "$_UPGRADE_UNION_FILE" "$_UPGRADE_STAGE" "$_UPGRADE_WORK" \
    > "$_UPGRADE_WORK/table"

  local new_entries="" rel mhash lhash shash t
  local placed_count=0 kept_count=0 removed_count=0 conflict_count=0
  t=$(printf '\t')
  while IFS="$t" read -r rel mhash lhash shash; do
    [ -n "$rel" ] || continue
    [ "$mhash" != "-" ] || mhash=""
    [ "$lhash" != "-" ] || lhash=""
    [ "$shash" != "-" ] || shash=""
    _upgrade_process_path "$rel" "$_UPGRADE_STAGE" "$dry_run" "$mhash" "$lhash" "$shash"
  done < "$_UPGRADE_WORK/table"
  rm -rf "$_UPGRADE_WORK"
  _UPGRADE_WORK=""
  rm -f "$_UPGRADE_UNION_FILE"
  _UPGRADE_UNION_FILE=""
  rm -rf "$_UPGRADE_STAGE"
  _UPGRADE_STAGE=""

  _upgrade_section "$source" "$dry_run"
  case "$_UPGRADE_SECTION_ACTION" in
    replace) placed_count=$((placed_count + 1)) ;;
    keep-modified | keep-malformed | keep-unmarked) kept_count=$((kept_count + 1)) ;;
    keep-conflict) conflict_count=$((conflict_count + 1)) ;;
  esac

  if [ "$dry_run" = 1 ]; then
    _upgrade_summary "$placed_count" "$kept_count" "$removed_count" "$conflict_count" \
      "unchanged (dry run)"
    return 0
  fi

  # Same rule as link mode, and for the same reason: a run that copied and
  # removed nothing has not installed this project from <source>, so the
  # header must not name it. The body is unaffected either way — with no
  # install, replace or delete, every entry it would write is the one the
  # manifest already holds (keep-modified and keep-outside carry the recorded
  # hash forward verbatim).
  if _upgrade_records_source "$source" "$((placed_count + removed_count))"; then
    local version adapters_manifest
    version=$(_upgrade_source_version "$source")
    adapters_manifest=$(_upgrade_csv "$active_adapters")
    printf '%s\n' "$new_entries" | sed '/^$/d' \
      | manifest_write_entries "$version" "$source" "$adapters_manifest" "copy" \
          "$_UPGRADE_SECTION_RECORD"
    _upgrade_summary "$placed_count" "$kept_count" "$removed_count" "$conflict_count" "updated"
  else
    _upgrade_summary "$placed_count" "$kept_count" "$removed_count" "$conflict_count" "unchanged"
    _upgrade_kept_source_note "$source" "copy"
  fi
  _upgrade_config_note "$dry_run"
}

# --- upgrade_pending ---------------------------------------------------------

# upgrade_pending — the pending action lines ("install <rel>", "link <rel>"
# or "replace <rel>") that `jig upgrade` would apply right now, for whichever
# project/config the caller is already running against. Read-only: never
# mutates the project. Built on top of --dry-run rather than duplicating the
# staging/decision-table logic — `cmd_upgrade --dry-run` already computes
# exactly this, and command substitution already runs it in a subshell, so
# its own EXIT/INT/TERM trap and locals never touch the caller's.
#
# Callers: `jig status` (drift's pending count) and `jig verify` (refuse to
# run on a stale install). Precondition: the project is initialised
# (jig_require_init already satisfied by the caller — cmd_upgrade re-checks
# it regardless).
#
# Output/exit contract:
#   0  success; zero or more pending lines printed on stdout, one per line,
#      each exactly one of cmd_upgrade's own "install "/"link "/"replace "
#      report lines. The run summary and the kept-source note are not matched
#      by the filter below — they are informational, not pending per-path
#      actions.
#   3  pending state is unknown right now and nothing is printed. This is
#      the expected outcome whenever the underlying dry run cannot complete
#      at all — most notably when the framework source root cannot be
#      determined (e.g. a copy-mode install whose source checkout was since
#      deleted, domains/install). Any other cmd_upgrade failure (a corrupt
#      .ai/config.yaml, say) also lands here rather than aborting the
#      caller: a best-effort staleness check must never itself turn into a
#      hard failure for status/verify — the caller's own subsequent logic
#      (e.g. verify's profile-name validation) surfaces the real error.
upgrade_pending() {
  local out rc=0
  out=$(cmd_upgrade --dry-run 2>&1) || rc=$?
  [ "$rc" = 0 ] || return 3

  printf '%s\n' "$out" | grep -E '^(install|link|replace) ' || true
  return 0
}

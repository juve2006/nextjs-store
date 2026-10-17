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

# --- the report's two forms ----------------------------------------------------
#
# The report goes through the shared output layer (output.sh,
# adr-20261005-output-is-decorated-only-on-a-terminal). In a pipe every line is
# the bytes upgrade printed before the layer existed, printed as it happens:
# agents, CI and upgrade_pending's filter read them. At a terminal the run says
# what changed rather than every file it touched: the replacements (and the
# reconciliations of an interrupted run) are kept here and said once, grouped
# by where they live, just before the summary; what a person may have to act
# on — an install, a deletion, a file kept because it was changed or is in the
# way, a hint — stays one line each, with its level word.

# "<verb> <rel>" lines kept for the grouped line, one per line.
_UPGRADE_GROUPED=""

# _upgrade_line <level> <verb> <rel> — one per-path report line. Plain:
# "<verb> <rel>". Terminal: replace and already-placed are kept for
# _upgrade_flush; any other verb is a status line of <level>.
_upgrade_line() {
  if [ "${quiet:-0}" = 1 ]; then return 0; fi
  if ! out_terminal; then
    printf '%s %s\n' "$2" "$3"
    return 0
  fi
  case "$2" in
    replace | already-placed)
      _UPGRADE_GROUPED="$_UPGRADE_GROUPED$2 $3
"
      ;;
    *) out_status "$1" "$2 $3" ;;
  esac
}

# _upgrade_line_note <text> — the explanation under the per-path line above
# it. Plain: indented by two spaces. Terminal: a `note:` detail.
_upgrade_line_note() {
  if [ "${quiet:-0}" = 1 ]; then return 0; fi
  if out_terminal; then
    out_detail note "$1"
  else
    printf '  %s\n' "$1"
  fi
}

# _upgrade_note <level> <text> [<hint>] — a remark about the whole run, and
# the hint that goes with it. Plain: the text, then "hint: <hint>". Terminal:
# a status line of <level>, the hint a detail under it.
_upgrade_note() {
  if [ "${quiet:-0}" = 1 ]; then return 0; fi
  if out_terminal; then
    out_status "$1" "$2"
    [ -z "${3:-}" ] || out_detail hint "$3"
  else
    printf '%s\n' "$2"
    [ -z "${3:-}" ] || printf 'hint: %s\n' "$3"
  fi
}

# _upgrade_flush — at a terminal, the kept replacements and reconciliations,
# one line per verb: "ok    replace 50 file(s): .ai/scripts (12), ...". A
# path is counted under its first two directories (`.ai/scripts`,
# `.claude/skills`), or its one directory (`.ai/manifest` under `.ai`), a path
# with none under itself; the count is left out where it is one. Areas keep
# the order the paths came in, which is sorted.
#
# Said only when the summary is: a run that dies midway names, at a terminal,
# none of the files it had already replaced. Repeating the command is what
# finishes such a run (adr-20260926-an-interrupted-upgrade-is-repeated-not-
# rolled-back), and the repeat reports them as `already-placed`.
_upgrade_flush() {
  [ -n "$_UPGRADE_GROUPED" ] || return 0
  local verb total area areas=()
  for verb in replace already-placed; do
    total=0
    areas=()
    while IFS= read -r area; do
      if [ "$total" = 0 ]; then total=$area; else areas+=("$area"); fi
    done < <(printf '%s' "$_UPGRADE_GROUPED" | awk -v verb="$verb" '
      {
        sp = index($0, " ")
        if (substr($0, 1, sp - 1) != verb) next
        rel = substr($0, sp + 1)
        n = split(rel, part, "/")
        if (n > 2) a = part[1] "/" part[2]; else if (n == 2) a = part[1]; else a = rel
        if (!(a in count)) order[++k] = a
        count[a]++
        total++
      }
      END {
        if (total == 0) exit
        print total
        for (i = 1; i <= k; i++) print (count[order[i]] > 1 ? order[i] " (" count[order[i]] ")" : order[i])
      }')
    [ "$total" != 0 ] || continue
    out_group ok "$verb $total file(s)" "${areas[@]}"
  done
  _UPGRADE_GROUPED=""
}

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
#
# _upgrade_summary_text prints the line, in the same words in both forms, for
# the commit message as well; _upgrade_summary reports it, and at a terminal
# says the grouped replacements first.
_upgrade_summary_text() {
  local line="jig upgrade: $1 placed, $2 kept"
  if [ "$3" != 0 ]; then line="$line, $3 removed"; fi
  printf '%s\n' "$line, $4 conflict(s); manifest $5"
}

_upgrade_summary() {
  if [ "${quiet:-0}" = 1 ]; then return 0; fi
  if out_terminal; then
    _upgrade_flush
    out_summary "$(_upgrade_summary_text "$@")"
  else
    _upgrade_summary_text "$@"
  fi
}

# _upgrade_kept_source_note <source> <mode> — why the manifest still names
# another checkout, and the command that does change it. `init` is that
# command: choosing where a project's framework comes from is an install
# decision, and `upgrade` only carries an existing install forward.
_upgrade_kept_source_note() {
  local source="$1" link_flag=""
  if [ "$2" = link ]; then link_flag=" --link"; fi
  _upgrade_note warn "nothing was placed from $source, so this project stays installed from $(manifest_source)" \
    "to install it from that checkout instead, run \`jig init$link_flag --from $source\`"
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
  # shellcheck disable=SC2016
  _upgrade_note warn "$JIG_AI_DIR/config.yaml does not mention $n key(s) this version reads, each on its default: $(printf '%s\n' "$keys" | sed 's/ /, /g')" \
    '`jig config keys` lists them; that file is yours to change or leave as it is'
}

# _upgrade_self_check <dry-run> — after a real run, ask the install that now
# exists whether anything is still not installed, and name it.
#
# The predicate is not a new one: it is `upgrade_pending`, the same question
# `jig doctor` and `jig status` ask. What this adds is the moment. Until now an
# unfinished run said nothing, and the leftover surfaced whenever somebody
# happened to run another command — the reported case was a run that printed
# "55 placed, 49 kept, 2 removed; manifest updated" and left
# `.ai/templates/AGENTS.md` unplaced, found a day later in `jig doctor` as
# "1 pending item(s) although the version is the same".
#
# It runs the project's own dispatcher as a subprocess, and that is the point,
# not an implementation detail: an upgrade is carried out by the code of the
# version being replaced. The run that left that template behind was 0.15.1
# doing the work, and 0.15.1 does not stage `.ai/templates/AGENTS.md` at all —
# the line that copies it arrived in 0.16.0. Worse, the template was in the
# manifest and not in its stage, so the old code deleted it. Asking
# `upgrade_pending` in this process would ask the old decision table, which is
# satisfied by construction: it would stay silent in exactly the case this
# check exists for. Only the newly installed code knows what it wants.
#
# Never on a dry run — `status`, `verify` and `doctor` each run one on every
# invocation (ADR-0017), and a self-check there would double their cost and
# recurse. A real upgrade pays one extra dry run (0.78 s against 0.88 s for the
# run itself, on 97 files), for a command that runs once per release.
#
# It never fails the upgrade it follows: that upgrade already happened, and a
# check that cannot answer says so instead of turning a success into an error
# (ADR-0017's "unknown is not zero"). `bash "$jig"`, not `"$jig"`, for the
# reason jig_status_page_touch uses it: Windows has no execute bit.
#
# Its status is what a copy-mode run commits on (_upgrade_finish): 0 the
# install is complete, 1 something is still not installed, 2 the check could
# not answer. A caller that only reports ignores it.
_upgrade_self_check() {
  [ "$1" != 1 ] || return 0
  local jig="$JIG_PROJECT/$JIG_AI_DIR/scripts/jig" out rc=0 n
  [ -f "$jig" ] || return 0
  # JIG_TERMINAL=0: the lines are read by the filter below, so the child
  # reports in the plain form even when this run's reader asked for the
  # terminal one (output.sh).
  out=$( (cd "$JIG_PROJECT" && JIG_TERMINAL=0 bash "$jig" upgrade --dry-run) </dev/null 2>&1 ) || rc=$?
  if [ "$rc" != 0 ]; then
    _upgrade_note warn "could not confirm this install is complete; run \`jig doctor\`"
    return 2
  fi
  out=$(printf '%s\n' "$out" | grep -E '^(install|link|replace) ' || true)
  [ -n "$out" ] || return 0
  n=$(printf '%s\n' "$out" | grep -c . || true)
  _upgrade_note fail "$n item(s) still not installed; run \`jig upgrade\` again"
  # Indented, the way every other note under a report line is: these are
  # another run's words quoted back, and unindented they would be
  # indistinguishable from this run's own `install`/`replace` lines — to a
  # reader, and to anything that reads the report by its line starts.
  # At a terminal, under the `fail` line's text, where its details stand.
  local indent='  '
  if out_terminal; then indent=$_OUT_PAD; fi
  _upgrade_out "$(printf '%s\n' "$out" | sed "s/^/$indent/")"
  return 1
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
  jig_cleanup_add "$tmp"
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
# tally this function keeps for the run summary, and reconciled_count, which
# decides whether the manifest is rewritten at all). Prints one report line per
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

  # The third comparison, and the first question asked: is the file already
  # exactly what this run would install? Then it is placed, whoever placed it,
  # and the only thing left to do is to say so in the manifest.
  #
  # Without it an interrupted run can never be repeated. Files are placed one
  # at a time and the manifest is written once at the end, so an interruption
  # leaves new bytes on disk against an old recorded hash — which the branches
  # below read as "the user edited this file" (`keep-modified`, or
  # `keep-conflict` for a path the manifest does not know yet) and never
  # reconsider. The content is the one predicate that cannot be lost, go stale
  # or arrive from somebody else's clone, so the repeat needs no journal
  # (adr-20260926-an-interrupted-upgrade-is-repeated-not-rolled-back).
  if [ "$staged_exists" = 1 ] && [ "$local_exists" = 1 ] \
     && [ "$local_hash" = "$staged_hash" ]; then
    action=already-placed
  elif [ "$staged_exists" = 1 ] && [ "$in_manifest" = 1 ]; then
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
    already-placed)
      # Reported only when the manifest did not already say so, which is
      # exactly when this run reconciled something: the ordinary case where
      # manifest, disk and stage all agree is the quiet majority of every run
      # and stays silent. Counted in `kept`, like every other outcome that
      # writes no file, and deliberately not one of upgrade_pending's verbs —
      # the file is current. `reconciled_count` is counted separately because
      # it decides whether the manifest is rewritten at all, below.
      if [ "$manifest_hash" != "$staged_hash" ]; then
        _upgrade_line ok already-placed "$rel"
        reconciled_count=$((reconciled_count + 1))
      fi
      kept_count=$((kept_count + 1))
      new_entries="$new_entries
$staged_hash $rel"
      ;;
    replace)
      # A file that already carries the staged bytes is `already-placed` above,
      # so reaching here means the two differ and the file is written.
      if [ "$dry_run" != 1 ]; then
        _upgrade_place "$staged_abs" "$local_abs"
      fi
      _upgrade_line ok replace "$rel"
      placed_count=$((placed_count + 1))
      new_entries="$new_entries
$staged_hash $rel"
      ;;
    install)
      if [ "$dry_run" != 1 ]; then
        _upgrade_place "$staged_abs" "$local_abs"
      fi
      _upgrade_line ok install "$rel"
      placed_count=$((placed_count + 1))
      new_entries="$new_entries
$staged_hash $rel"
      ;;
    keep-modified)
      _upgrade_line warn keep-modified "$rel"
      kept_count=$((kept_count + 1))
      new_entries="$new_entries
$manifest_hash $rel"
      ;;
    keep-conflict)
      _upgrade_line warn keep-conflict "$rel"
      conflict_count=$((conflict_count + 1))
      ;;
    keep-orphaned-modified)
      _upgrade_line warn keep-orphaned-modified "$rel"
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
        _upgrade_line warn keep-outside "$rel"
        kept_count=$((kept_count + 1))
        new_entries="$new_entries
$manifest_hash $rel"
        return 0
      fi
      if [ "$dry_run" != 1 ]; then
        rm -f "$local_abs"
      fi
      _upgrade_line ok delete "$rel"
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
# | yes    | ok        | ≠ record, = source  | already-placed |
# | yes    | ok        | ≠ record, ≠ source  | keep-modified  |
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
        _upgrade_line warn keep-unmarked AGENTS.md
        _upgrade_line_note "its Jig section is not marked, so upgrades cannot reach it; the jig-init skill adds the markers"
        ;;
      malformed)
        _UPGRADE_SECTION_ACTION=keep-malformed
        _upgrade_line warn keep-malformed "AGENTS.md (Jig section)"
        _upgrade_line_note "expected one $JIG_SECTION_BEGIN and one $JIG_SECTION_END, in that order"
        ;;
      *)
        _UPGRADE_SECTION_ACTION=keep-conflict
        _upgrade_line warn keep-conflict "AGENTS.md (Jig section)"
        _upgrade_line_note "jig did not write this section, so it does not update it; run \`jig init\` to adopt it"
        ;;
    esac
    return 0
  fi

  if [ "$state" = malformed ]; then
    _UPGRADE_SECTION_ACTION=keep-malformed
    _upgrade_line warn keep-malformed "AGENTS.md (Jig section)"
    _upgrade_line_note "expected one $JIG_SECTION_BEGIN and one $JIG_SECTION_END, in that order"
    return 0
  fi

  # The markers are gone: somebody removed the section on purpose, and an
  # upgrade never restores what a human removed (the same conclusion ADR-0024
  # reached about a deleted session-hook line).
  if [ "$state" = absent ]; then
    _UPGRADE_SECTION_ACTION=keep-modified
    _upgrade_line warn keep-modified "AGENTS.md (Jig section)"
    return 0
  fi

  cur_hash=$(jig_section_hash "$file")
  new_hash=$(jig_section_hash "$template")

  # The file table's third comparison, applied to the region: the section has
  # the same hole, because its record lives in the manifest header and the
  # header is written at the end of the run. Replace the section, die before
  # the manifest, and the region is the source's text against an older
  # recorded hash — read below as an edit, and so never replaced again.
  #
  # ADR-20260924's invariants are untouched. Reaching here means a record
  # exists, so a human already consented to jig owning this region; the text
  # is not changed by a byte, only the hash the manifest remembers of it.
  if [ "$cur_hash" = "$new_hash" ]; then
    if [ "$cur_hash" != "$rec_hash" ]; then
      _UPGRADE_SECTION_ACTION=already-placed
      _UPGRADE_SECTION_RECORD="$new_hash AGENTS.md"
      _upgrade_line ok already-placed "AGENTS.md (Jig section)"
    fi
    return 0 # already current, and silent like every other unchanged path
  fi

  if [ "$cur_hash" != "$rec_hash" ]; then
    _UPGRADE_SECTION_ACTION=keep-modified
    _upgrade_line warn keep-modified "AGENTS.md (Jig section)"
    return 0
  fi

  if [ "$dry_run" != 1 ]; then
    _UPGRADE_SECTION_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-upgrade-section.XXXXXX")
    jig_cleanup_add "$_UPGRADE_SECTION_TMP"
    jig_section_read "$template" > "$_UPGRADE_SECTION_TMP"
    jig_section_write "$file" "$_UPGRADE_SECTION_TMP" \
      || jig_die "upgrade: could not replace the Jig section of AGENTS.md"
    rm -f "$_UPGRADE_SECTION_TMP"
    _UPGRADE_SECTION_TMP=""
  fi
  _UPGRADE_SECTION_ACTION=replace
  _UPGRADE_SECTION_RECORD="$new_hash AGENTS.md"
  _upgrade_line ok replace "AGENTS.md (Jig section)"
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
    _upgrade_line ok link "$rel"
  elif [ "$conflict_count" != "$before_conflict" ]; then
    _upgrade_line warn keep-conflict "$rel"
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
  local created_count=0 kept_count=0 conflict_count=0 conflict_paths="" reconciled_count=0
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
    already-placed) kept_count=$((kept_count + 1)); reconciled_count=$((reconciled_count + 1)) ;;
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
  #
  # The one thing in between after all: the marked section's record lives in
  # the header, which link mode does write, so a run whose only work was
  # reconciling that record has something to save. Dropped, the section stays
  # unreplaceable for ever — the state this change ends
  # (adr-20260926-an-interrupted-upgrade-is-repeated-not-rolled-back).
  #
  # But it does not earn <source> the header. Where copy mode may name the
  # checkout it reconciled from — every reconciled path holds that checkout's
  # bytes — a link-mode run that created no link leaves the project running the
  # scripts it ran before, and naming another checkout would send the next plain
  # `jig upgrade` to read from it (adr-20260922). So the record is kept and the
  # source is not moved: the two decisions are separate here.
  local record_source=""
  if _upgrade_records_source "$source" "$created_count"; then
    record_source="$source"
  elif [ "$reconciled_count" != 0 ]; then
    record_source=$(manifest_source)
  fi

  if [ -n "$record_source" ]; then
    local version adapters_manifest
    version=$(_upgrade_source_version "$record_source")
    adapters_manifest=$(_upgrade_csv "$active_adapters")
    manifest_write_entries "$version" "$record_source" "$adapters_manifest" "link" \
      "$_UPGRADE_SECTION_RECORD" < /dev/null
    _upgrade_summary "$created_count" "$kept_count" 0 "$conflict_count" "updated"
    if [ "$record_source" != "$source" ]; then
      _upgrade_kept_source_note "$source" "link"
    fi
  else
    _upgrade_summary "$created_count" "$kept_count" 0 "$conflict_count" "unchanged"
    _upgrade_kept_source_note "$source" "link"
  fi
}

# --- the upgrade as a unit of work -------------------------------------------
#
# A real copy-mode run checks that it may start, is carried out by the newest
# code it can reach, works on a branch of its own cut from the base branch,
# confirms the install is complete, and only then commits — one commit, shipped
# as far as `agent.git` allows, by the same steps `jig task ship` takes
# (adr-20260930-an-upgrade-is-a-unit-of-work). Link mode is left out: there the
# scripts are the source itself, and an upgrade is a development step taken on
# a tree that is dirty by design.

# The branches this command cuts, and recognises as its own on a repeat.
_UPGRADE_BRANCH_PREFIX="jig/upgrade-"
# Set by _upgrade_open_branch: the branch the run works on (empty when it
# works on no branch of its own), the branch it was started from, and whether
# this run created the branch.
_UPGRADE_BRANCH=""
_UPGRADE_PREV=""
_UPGRADE_CREATED=0

# _upgrade_current_branch — the checked-out branch, empty when detached.
_upgrade_current_branch() {
  git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# _upgrade_handoff <source> — when the code running this command is older than
# the source it upgrades from, give the whole run to the source's own
# dispatcher, and never return.
#
# Every upgrade incident of 2026-09-26..29 was the version being replaced
# doing the replacing: an old decision table deleting a template the new
# version ships, an old copy replacing its entry point but not its libraries.
# Only the new code knows what the new install is. The limit is honest: this
# protects only from the first version that has it.
#
# The marker stops a loop: a handed-off run that is somehow still older than
# its source has nowhere better to go, and the way out is the global tool.
_upgrade_handoff() {
  local source="$1" to q=""
  to=$(_upgrade_source_version "$source")
  jig_version_newer "$to" "$JIG_VERSION" || return 0
  if [ -n "${JIG_UPGRADE_HANDED_OFF:-}" ]; then
    jig_die "upgrade: this jig is $JIG_VERSION and $source holds $to; nothing was changed. Run \`jig self-update\`, then \`jig upgrade\`"
  fi
  if [ "${quiet:-0}" = 1 ]; then q="--quiet"; fi
  _upgrade_out "upgrade: this jig is $JIG_VERSION; handing the upgrade to $to from $source"
  cd "$JIG_PROJECT" || jig_die "upgrade: cannot enter $JIG_PROJECT"
  # bash, not the file itself: Windows has no execute bit.
  JIG_UPGRADE_HANDED_OFF="$JIG_VERSION" exec bash "$source/scripts/jig" upgrade --from "$source" $q
}

# _upgrade_stop_reasons <source> — why a real run must not start here, one
# reason per line; nothing when it may. Asked before anything is touched.
_upgrade_stop_reasons() {
  local source="$1" cur tracked eol lines name exit_hint ttl dir holder checkout

  # 1. Uncommitted work: the rule of `task start` — tracked changes block,
  #    untracked files do not. A repeat on the upgrade's own branch is the
  #    exception: its changes are the interrupted run's, and repeating it is
  #    how that run is finished (adr-20260926-an-interrupted-upgrade-is-
  #    repeated-not-rolled-back).
  cur=$(_upgrade_current_branch)
  case "$cur" in
    "$_UPGRADE_BRANCH_PREFIX"*) ;;
    *)
      tracked=$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null | grep -v '^??' || true)
      if [ -n "$tracked" ]; then
        printf '%s\n' "the working tree has uncommitted changes; commit them, stash them (\`git stash\`), or finish the task they belong to, then run \`jig upgrade\` again"
      fi
      ;;
  esac

  # 2. Line endings: with core.autocrlf=true and nothing pinning Jig's files to
  #    LF, a clone checks them out with CRLF, and every hash in the manifest
  #    stops meaning anything — invisibly, `jig status` still says drift 0.
  #    The manifest itself is the path that matters: a CRLF `.ai/manifest`
  #    parses as empty (manifest.sh's `---` separator never matches with a
  #    trailing \r), which is the failure this stop exists to prevent. Older
  #    templates pinned `.ai/scripts/**` alone, so checking a script's eol
  #    here would already read `lf` on every one of those installs and never
  #    fire for the bug it is meant to catch.
  if [ "$(git -C "$JIG_PROJECT" config --bool --get core.autocrlf 2>/dev/null || true)" = true ]; then
    eol=$(git -C "$JIG_PROJECT" check-attr eol -- "$JIG_AI_DIR/manifest" 2>/dev/null | sed 's/.*: eol: //')
    if [ "$eol" != lf ]; then
      lines=$(sed '/^#/d; /^$/d' "$source/templates/gitattributes" 2>/dev/null | tr '\n' ';' | sed 's/;$//; s/;/; /g')
      printf '%s\n' "core.autocrlf is true here and Jig's files are not pinned to LF, so they would be checked out with CRLF; add these lines to .gitattributes, commit, and run again: $lines"
    fi
  fi

  # 3. A started task on this checkout's HEAD: the upgrade cuts its branch from
  #    the base and switches to it, so it takes HEAD from whoever is working on
  #    that task here. Who occupies the checkout is the one rule `task start`
  #    reads, jig_checkout_occupants (adr-20260930-an-upgrade-is-a-unit-of-
  #    work, amended 2026-10-05), with no exception for the task on HEAD: that
  #    task is the one whose HEAD moves. The dispatcher has just recorded this
  #    very run under that task's name, so the record is always fresh here and
  #    its age and command would only describe this upgrade; the message names
  #    the record and leaves them out. A record named by a session id stops
  #    nothing: it says a command ran, not that one is running, and the one
  #    long command that broke under a script swap has its own stop (4).
  #    Asked only where a HEAD moves — not with `git.branch_per_task: false`,
  #    and not on a repeat on the upgrade's own branch, which no task holds.
  #    Where this checkout is is answered as the rest of Jig answers it,
  #    jig_config_clone_root: a worktree of a clone has a main checkout that
  #    differs from it; a bare repository's worktree has none, so it is asked
  #    as a main checkout. The way out depends on that: in the main checkout,
  #    `task start <id> --worktree` moves the task out and puts this checkout
  #    back on the base; in a worktree of its own the task already has one,
  #    that command cannot hand this tree the base (git keeps a branch in one
  #    worktree at a time), and the upgrade belongs in the main checkout.
  if cfg_bool git.branch_per_task true; then
    while read -r name _; do
      [ -n "$name" ] || continue
      if [ "$(jig_config_clone_root)" != "$JIG_PROJECT" ]; then
        exit_hint="this is a worktree of its own, so run \`jig upgrade\` in the main checkout instead"
      else
        exit_hint="if that work is yours or its session has ended, give it a worktree of its own with \`jig task start $name --worktree\` (this checkout goes back to its base branch), then run \`jig upgrade\` again; if another session is still working on it, run the upgrade when it has finished"
      fi
      printf '%s\n' "task $name is started and its branch $cur is checked out here (record $JIG_AI_DIR/runtime/working/$name); the upgrade would take this checkout off it; $exit_hint"
    done < <(jig_checkout_occupants)
  fi

  # 4. A `jig verify` running in this checkout: replacing the scripts it is
  #    executing turned one run into 34 false failures on 2026-09-26. A run
  #    in another worktree of the clone executes its own files, not these.
  ttl=$(jig_verify_busy_ttl)
  if [ "$ttl" -gt 0 ] && dir=$(jig_verify_busy_dir) && [ -n "$dir" ]; then
    holder=$(jig_verify_busy_holder "$dir" "$ttl") || holder=""
    if [ -n "$holder" ]; then
      checkout=${holder#* }
      if _upgrade_same_dir "$checkout" "$JIG_PROJECT"; then
        printf '%s\n' "\`jig verify\` is running in this checkout (for $(jig_checkout_ago "${holder%% *}")); run the upgrade when it has finished"
      fi
    fi
  fi
  return 0
}

# _upgrade_preflight <source> <dry-run> — refuse a real run, changing nothing,
# for every reason above at once; on a dry run only say what a real one would
# do. A dry run is read-only and `status`, `verify` and `doctor` rely on it
# (ADR-0017), so it never refuses.
_upgrade_preflight() {
  local reasons r
  reasons=$(_upgrade_stop_reasons "$1")
  [ -n "$reasons" ] || return 0
  if [ "$2" = 1 ]; then
    while IFS= read -r r; do
      _upgrade_out "note: a real upgrade would stop: $r"
    done <<EOF
$reasons
EOF
    return 0
  fi
  jig_die "upgrade: nothing was changed:
$(printf '%s\n' "$reasons" | sed 's/^/  - /')"
}

# _upgrade_open_branch <to-version> — put the run on a branch of its own.
#
# Cut from the base branch, never from the current one: standing on a task's
# branch, an upgrade cut from it would ride into that task's pull request. The
# base is freshened and chosen the way `task start` chooses it. Already on an
# upgrade branch, the run stays there. No branch at all when the project works
# on one branch by choice (`git.branch_per_task: false`) or has no commit yet.
_upgrade_open_branch() {
  local to="$1" base start name based n=2
  _UPGRADE_PREV=$(_upgrade_current_branch)
  [ -n "$_UPGRADE_PREV" ] || _UPGRADE_PREV=$(git -C "$JIG_PROJECT" rev-parse --short HEAD 2>/dev/null || true)
  case "$_UPGRADE_PREV" in
    "$_UPGRADE_BRANCH_PREFIX"*) _UPGRADE_BRANCH="$_UPGRADE_PREV"; return 0 ;;
  esac
  cfg_bool git.branch_per_task true || return 0
  git -C "$JIG_PROJECT" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 0
  base=$(cfg git.base_branch main)
  jig_fetch_branches "upgrade" "$base"
  start=$(jig_fresh_base_ref "$base" "upgrade") || exit 1
  # jig_fresh_base_ref falls back to HEAD when the base exists nowhere, and
  # HEAD is the one place an upgrade must not be cut from.
  if [ "$start" = HEAD ]; then
    jig_die "upgrade: no branch $base here or on origin to cut the upgrade from; set git.base_branch to your main branch. Nothing was changed"
  fi
  # An upgrade to this version already on a branch that has not landed is the
  # same upgrade: a second branch could only become a second pull request for
  # it, or an empty one. A landed one is history, and a new name is fine.
  # Landed is read two ways, because ancestry alone misses the common case: a
  # pull request squashed or rebased by the forge leaves the local branch
  # behind as no ancestor of the base. A base whose manifest already records
  # <to> carries that upgrade whichever way it arrived.
  based=$(jig_git_show_path "$start" "$JIG_AI_DIR/manifest" 2>/dev/null \
    | sed -n 's/^jig\.version:[[:space:]]*//p' | head -n 1) || based=""
  name="$_UPGRADE_BRANCH_PREFIX$to"
  while git -C "$JIG_PROJECT" show-ref --verify --quiet "refs/heads/$name"; do
    if [ "$based" != "$to" ] \
      && ! git -C "$JIG_PROJECT" merge-base --is-ancestor "refs/heads/$name" "$start" 2>/dev/null; then
      jig_die "upgrade: the upgrade to $to is already on branch $name, which has not been merged into $base yet. Merge it, or \`git checkout $name\` and run \`jig upgrade\` there to carry it on. Nothing was changed"
    fi
    name="$_UPGRADE_BRANCH_PREFIX$to-$n"
    n=$((n + 1))
  done
  git -C "$JIG_PROJECT" checkout -q -b "$name" "$start" \
    || jig_die "upgrade: could not create branch $name from $base; nothing was changed"
  _UPGRADE_BRANCH="$name"
  _UPGRADE_CREATED=1
  _upgrade_out "upgrade: working on branch $name, cut from $base"
}

# _upgrade_stage_change — stage what this run changed and nothing else. The
# tree held no tracked change when the run started, so every tracked change is
# the run's own; of the untracked files, only the ones the install owns.
_upgrade_stage_change() {
  local ours untracked p
  git -C "$JIG_PROJECT" add -u || jig_die "upgrade: git add failed"
  ours=$( { manifest_paths; printf '%s\n' "$JIG_AI_DIR/manifest" AGENTS.md; } | sed '/^$/d' | sort -u)
  untracked=$(git -C "$JIG_PROJECT" ls-files --others --exclude-standard 2>/dev/null \
    | grep -Fx -f <(printf '%s\n' "$ours") || true)
  [ -n "$untracked" ] || return 0
  while IFS= read -r p; do
    git -C "$JIG_PROJECT" add -- "$p" || jig_die "upgrade: git add failed: $p"
  done <<EOF
$untracked
EOF
}

# _upgrade_custom_profiles — active profile names (profiles_active) that are
# not part of the project's recorded source (manifest_source): a profile
# somebody wrote themselves rather than one the framework ships. `generic` is
# never included: it is the framework's own fallback and already declares
# `verifies: nothing`. Silent (prints nothing) when the source cannot be
# read, rather than guessing.
_upgrade_custom_profiles() {
  local source p
  source=$(manifest_source 2>/dev/null) || source=""
  [ -n "$source" ] || return 0
  for p in $(profiles_active); do
    [ "$p" != generic ] || continue
    [ -f "$source/profiles/$p/profile.yaml" ] && continue
    printf '%s\n' "$p"
  done
}

# _upgrade_manual_steps <from> <to> — the steps a person still has to take by
# hand, as the commit and the pull request carry them (the one place both
# read from). All three below arrived in 0.16.0 (docs/changelog.mdx,
# docs/upgrading.mdx#from-015-to-016); nothing is printed once <from> is
# 0.16.0 or newer.
#
# The first has a real predicate — jig_section_report_state, the same one
# `jig doctor`'s instructions check reads, so the two can never disagree
# about it (doctor.sh's own comment says so) — and is skipped once satisfied.
# `jig doctor` is where it can be checked again later; nothing new needed
# there.
#
# The other two are advisory text, not a tracked done/not-done step:
#
#   - Whether the project's verification tools are installed cannot be
#     answered here without running them, which is exactly what `jig verify`
#     exists to do, on its own busy-record and narrowing
#     (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass). Its
#     own exit code (0 or 3) is the predicate; running it as a side effect of
#     every upgrade would mean paying for a full run here or contending with
#     one already in flight. Always shown, unconditionally, once <from>
#     predates 0.16.0.
#   - Whether a self-written profile needs `verifies: nothing` has no correct
#     yes/no answer from the filesystem alone: a custom profile with real
#     checks correctly has no `verifies` key, and nothing distinguishes that
#     from one with none short of running its checks and reading why they
#     skipped. Per this task's own rule, a step with no predicate is not
#     filed as one; this stays a named pointer at whichever custom profiles
#     the project actually has, so a project with none sees nothing.
_upgrade_manual_steps() {
  local from="$1" state custom
  jig_version_lt "$from" 0.16.0 || return 0

  state=$(jig_section_report_state "$JIG_PROJECT/AGENTS.md" "$(manifest_instructions_section 2>/dev/null)")
  if [ "$state" = unmarked ]; then
    # shellcheck disable=SC2016
    printf -- '- Run the jig-init skill, so upgrades can reach your AGENTS.md. It adds the markers and records Jig'\''s claim to that section, with your consent; without that claim `jig upgrade` reports `keep-unmarked AGENTS.md` and never touches it, however well-formed the markers are.\n'
  fi

  # shellcheck disable=SC2016
  printf -- '- Install the tools your project'\''s checks need. `jig verify` now refuses (exit 3, nothing was checked) when a profile for your stack is active and its tools are missing; `jig verify --list` shows which profiles are installed.\n'

  custom=$(_upgrade_custom_profiles | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$custom" ]; then
    # shellcheck disable=SC2016
    printf -- '- If %s checks nothing by design, add `verifies: nothing` to its profile.yaml. Absence means the profile claims it verifies something, and it will refuse once its checks all skip.\n' "$custom"
  fi
}

# _upgrade_message <file> <from> <to> <summary> — the one commit's message.
_upgrade_message() {
  local file="$1" from="$2" to="$3" summary="$4"
  [ -n "$from" ] || from="unknown"
  {
    printf 'Upgrade Jig %s -> %s\n\n' "$from" "$to"
    printf '%s\n\n' "$summary"
    printf 'Manual steps:\n'
    _upgrade_manual_steps "$from" "$to"
    printf '\nUpgrading: https://jig.fapost.in/upgrading\n'
  } > "$file"
}

# _upgrade_finish <from> <to> <summary> — the end of a real copy-mode run: the
# self-check, then one commit and whatever `agent.git` allows beyond it. Never
# commits an install the self-check did not confirm.
_upgrade_finish() {
  local from="$1" to="$2" summary="$3" level rc=0 base msg rel sha
  level=$(jig_agent_git) || level=none
  _upgrade_self_check 0 || rc=$?
  _upgrade_config_note 0
  if [ "$rc" != 0 ]; then
    _upgrade_out "upgrade: not committed, because the install is not complete; run \`jig upgrade\` again${_UPGRADE_BRANCH:+ on $_UPGRADE_BRANCH}"
    return 0
  fi
  git -C "$JIG_PROJECT" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || {
    _upgrade_out "upgrade: this repository has no commit yet; the change is left for you to commit"
    return 0
  }

  _upgrade_stage_change
  if [ -z "$(jig_ship_staged)" ]; then
    if [ "$_UPGRADE_CREATED" = 1 ]; then
      # The branch was cut by this run and holds no commit of its own, so
      # `branch -d` loses nothing; it refuses anything else by itself.
      if git -C "$JIG_PROJECT" checkout -q "$_UPGRADE_PREV" 2>/dev/null; then
        git -C "$JIG_PROJECT" branch -q -d "$_UPGRADE_BRANCH" 2>/dev/null || true
        _upgrade_out "upgrade: nothing changed; back on $_UPGRADE_PREV"
        # The base is already current, so a branch still asking for an
        # upgrade (`jig verify` refuses there) gets it from the base, not from
        # another run of this command.
        base=$(cfg git.base_branch main)
        if [ "$_UPGRADE_PREV" != "$base" ]; then
          _upgrade_out "next: $base already has this version; if $_UPGRADE_PREV still asks for an upgrade, bring it in with \`git merge $base\`"
        fi
      else
        _upgrade_out "upgrade: nothing changed; you are on $_UPGRADE_BRANCH"
      fi
    else
      _upgrade_out "upgrade: nothing changed"
    fi
    return 0
  fi

  rel="$JIG_AI_DIR/runtime/upgrade/message"
  msg="$JIG_PROJECT/$rel"
  mkdir -p "$(dirname "$msg")" || jig_die "upgrade: cannot create $(dirname "$msg")"
  _upgrade_message "$msg" "$from" "$to" "$summary"

  if [ "$level" = none ]; then
    _upgrade_out "upgrade: the change is staged; commit it with \`git commit -F $rel\`"
    _upgrade_next
    return 0
  fi
  jig_ship_check_staged "upgrade"
  jig_ship_commit "upgrade" "$msg"
  if [ -z "$_UPGRADE_BRANCH" ] || [ "$level" = commit ]; then
    _upgrade_next
    return 0
  fi

  if ! git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    _upgrade_out "upgrade: no remote named origin, so nothing is pushed"
    _upgrade_next
    return 0
  fi
  base=$(cfg git.base_branch main)
  jig_ship_require_commits "upgrade" "$_UPGRADE_BRANCH" "$base"
  jig_ship_push "upgrade" "$_UPGRADE_BRANCH"
  if [ "$level" = push ]; then
    _upgrade_step_back "$base"
    _upgrade_next
    return 0
  fi
  # jig_ship_pr registers the body it cuts with the same exit cleanup.
  jig_ship_pr "upgrade" "$_UPGRADE_BRANCH" "$base" "$msg"
  if [ "$level" = merge ] && [ -n "$JIG_SHIP_URL" ]; then
    sha=$(git -C "$JIG_PROJECT" rev-parse HEAD)
    jig_ship_merge "upgrade" "$JIG_SHIP_URL" "$sha" any
    # A merged upgrade leaves no branch behind: back on the base, the branch
    # deleted here and on origin (adr-20261007-a-merged-branch-leaves-with-its-work).
    jig_ship_leave "upgrade" "$_UPGRADE_BRANCH" "$base" "$sha"
  fi
  [ "$JIG_SHIP_MERGED" = 1 ] || _upgrade_step_back "$base"
  _upgrade_next
}

# Set by _upgrade_step_back: the branch (or commit) this checkout went back
# to after the push, or empty when it stayed on the upgrade's branch.
_UPGRADE_BACK_ON=""

# _upgrade_step_back <base> — once the upgrade's branch is on origin and Jig
# did not merge it, put this checkout back where the run started (the base,
# when the run started on the upgrade's own branch). Nothing is lost: the
# commit is pushed. Left checked out, the branch could never be deleted after
# the person merges its pull request — housekeeping never deletes a branch
# checked out anywhere (adr-20261007-a-merged-branch-leaves-with-its-work). A
# linked worktree is never moved, as in jig_ship_leave.
_upgrade_step_back() {
  local base="$1" to
  [ -n "$_UPGRADE_BRANCH" ] || return 0
  [ "$(_upgrade_current_branch)" = "$_UPGRADE_BRANCH" ] || return 0
  [ "$(jig_config_clone_root)" = "$JIG_PROJECT" ] || return 0
  to="$_UPGRADE_PREV"
  if [ -z "$to" ] || [ "$to" = "$_UPGRADE_BRANCH" ]; then to="$base"; fi
  if git -C "$JIG_PROJECT" checkout -q "$to" >/dev/null 2>&1; then
    _UPGRADE_BACK_ON="$to"
    _upgrade_out "upgrade: back on $to; the upgrade waits on branch $_UPGRADE_BRANCH"
  else
    _upgrade_out "upgrade: could not switch back to $to; you are on $_UPGRADE_BRANCH"
  fi
}

# _upgrade_next — where the person stands now, and the way back, in words: a
# branch and a pull request must not become a new dead end for somebody who
# has never used git beyond what jig does for them.
_upgrade_next() {
  local base
  [ -n "$_UPGRADE_BRANCH" ] || return 0
  base=$(cfg git.base_branch main)
  if [ "$JIG_SHIP_MERGED" = 1 ]; then
    if [ -n "$JIG_SHIP_BACK_ON" ]; then
      # Back on the base already: the one way left to go is back to a branch
      # the person was on before, which does not have the upgrade yet.
      if [ -n "$_UPGRADE_PREV" ] && [ "$_UPGRADE_PREV" != "$JIG_SHIP_BACK_ON" ] \
         && [ "$_UPGRADE_PREV" != "$_UPGRADE_BRANCH" ]; then
        _upgrade_out "next: to go back to what you were doing: \`git checkout $_UPGRADE_PREV\`, then \`git merge $base\` to bring the upgrade into it"
      fi
      return 0
    fi
    _upgrade_out "next: this upgrade is merged into $base; merge that into the branches still in progress"
  else
    _upgrade_out "next: this upgrade is on branch $_UPGRADE_BRANCH; once it is merged into $base, merge that into the branches still in progress"
    if [ -n "$_UPGRADE_BACK_ON" ]; then
      _upgrade_out "next: to change the upgrade before it is merged: \`git checkout $_UPGRADE_BRANCH\`"
      return 0
    fi
  fi
  if [ -n "$_UPGRADE_PREV" ] && [ "$_UPGRADE_PREV" != "$_UPGRADE_BRANCH" ]; then
    _upgrade_out "next: to go back to what you were doing: \`git checkout $_UPGRADE_PREV\`"
  fi
}

# --- cmd_upgrade -------------------------------------------------------------

# Staging directory / union-of-paths temp file / hash-table work directory for
# the current cmd_upgrade run. Script-global (not `local`), registered with jig_cleanup_add
# (common.sh) so an interrupted run still removes them.
_UPGRADE_STAGE=""
_UPGRADE_UNION_FILE=""
_UPGRADE_WORK=""
# Where an orphan may be deleted: `.ai/` and every adapter's skills directory,
# filled in once the adapters are sourced (see _upgrade_deletable).
_UPGRADE_DELETE_ROOTS=""

cmd_upgrade() {
  local from="" dry_run=0 quiet=0 level=none
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || jig_die "upgrade: --from requires a value"; from="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --quiet) quiet=1; shift ;;
      *) jig_die "upgrade: unknown argument: $1" ;;
    esac
  done
  jig_require_init
  # shellcheck source=lib/output.sh
  . "$JIG_LIB/output.sh"
  out_init
  _UPGRADE_GROUPED=""
  # shellcheck source=lib/manifest.sh
  . "$JIG_LIB/manifest.sh"
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"
  # shellcheck source=lib/section.sh
  . "$JIG_LIB/section.sh"

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
    _upgrade_self_check "$dry_run" || true
    _upgrade_config_note "$dry_run"
    return 0
  fi

  # Copy mode is a unit of work (adr-20260930-an-upgrade-is-a-unit-of-work):
  # the newest code, the checks, then a branch of its own — all before the
  # first file is touched. upgrade_pending skips the checks: it runs on every
  # `status` and `verify`, and reads only the per-path lines.
  local from_version to_version
  if [ "$dry_run" != 1 ]; then
    _upgrade_handoff "$source"
    level=$(jig_agent_git) \
      || jig_die "upgrade: invalid agent.git: $level (expected none|commit|push|pr|merge); nothing was changed"
  fi
  [ "${_upgrade_skip_preflight:-0}" = 1 ] || _upgrade_preflight "$source" "$dry_run"
  to_version=$(_upgrade_source_version "$source")
  if [ "$dry_run" != 1 ]; then
    _upgrade_open_branch "$to_version"
    # The branch may hold another config; read what this run installs there.
    active_profiles=$(cfg_list profiles generic)
    active_adapters=$(cfg_list adapters "claude codex")
  fi
  from_version=$(manifest_header_get jig.version)

  _UPGRADE_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/jig-upgrade-stage.XXXXXX")
  jig_cleanup_add -d "$_UPGRADE_STAGE"
  _upgrade_build_staged "$source" "$_UPGRADE_STAGE" "$active_profiles" "$active_adapters"

  _UPGRADE_UNION_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-upgrade-union.XXXXXX")
  jig_cleanup_add "$_UPGRADE_UNION_FILE"
  { (cd "$_UPGRADE_STAGE" && find . -type f | sed 's|^\./||'); manifest_paths; } | sort -u > "$_UPGRADE_UNION_FILE"

  _UPGRADE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/jig-upgrade-work.XXXXXX")
  jig_cleanup_add -d "$_UPGRADE_WORK"
  _upgrade_hash_table "$_UPGRADE_UNION_FILE" "$_UPGRADE_STAGE" "$_UPGRADE_WORK" \
    > "$_UPGRADE_WORK/table"

  local new_entries="" rel mhash lhash shash t
  local placed_count=0 kept_count=0 removed_count=0 conflict_count=0 reconciled_count=0
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
    already-placed) kept_count=$((kept_count + 1)); reconciled_count=$((reconciled_count + 1)) ;;
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
  #
  # A reconciliation counts as applied, and it has to. It is the one outcome
  # that changes the body while writing no file: the entry it carries forward
  # is the staged hash, not the recorded one. Left out of this count, a repeat
  # of a run interrupted after its last placement would find every path already
  # placed, write nothing, and report "manifest unchanged" — the state this
  # whole change exists to end, reached by the fix itself. Naming <source> in
  # the header is right in that case too: every reconciled path holds that
  # checkout's bytes, so the project is an install of it, and the interrupted
  # run only failed to say so.
  local manifest_state=unchanged
  if _upgrade_records_source "$source" \
       "$((placed_count + removed_count + reconciled_count))"; then
    local version adapters_manifest
    version=$(_upgrade_source_version "$source")
    adapters_manifest=$(_upgrade_csv "$active_adapters")
    printf '%s\n' "$new_entries" | sed '/^$/d' \
      | manifest_write_entries "$version" "$source" "$adapters_manifest" "copy" \
          "$_UPGRADE_SECTION_RECORD"
    manifest_state=updated
  fi
  _upgrade_summary "$placed_count" "$kept_count" "$removed_count" "$conflict_count" "$manifest_state"
  [ "$manifest_state" = updated ] || _upgrade_kept_source_note "$source" "copy"
  _upgrade_finish "$from_version" "$to_version" \
    "$(_upgrade_summary_text "$placed_count" "$kept_count" "$removed_count" "$conflict_count" "$manifest_state")"
}

# --- upgrade_pending ---------------------------------------------------------

# upgrade_pending — the pending action lines ("install <rel>", "link <rel>"
# or "replace <rel>") that `jig upgrade` would apply right now, for whichever
# project/config the caller is already running against. Read-only: never
# mutates the project. Built on top of --dry-run rather than duplicating the
# staging/decision-table logic — `cmd_upgrade --dry-run` already computes
# exactly this, and command substitution already runs it in a subshell, so
# its own exit cleanup (common.sh) and locals never touch the caller's.
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
  # JIG_TERMINAL=0: the dry run's lines are read by the filter below, so it
  # reports in the plain form whatever the caller's reader is (output.sh).
  # Read by out_init inside cmd_upgrade, which shellcheck cannot see.
  # shellcheck disable=SC2034
  local out rc=0 _upgrade_skip_preflight=1 JIG_TERMINAL=0
  out=$(cmd_upgrade --dry-run 2>&1) || rc=$?
  [ "$rc" = 0 ] || return 3

  printf '%s\n' "$out" | grep -E '^(install|link|replace) ' || true
  return 0
}

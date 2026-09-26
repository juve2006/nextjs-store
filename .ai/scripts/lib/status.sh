# cmd_status — version, init/manifest state, drift, pending knowledge
# proposals, active tasks, housekeeping age (ARCHITECTURE.md, Scripts layout). Sourced by
# scripts/jig; defines cmd_status.
# Read-only, with two exceptions, both in .ai/runtime/ and both about the
# status page (adr-20260924-the-status-page-keeps-the-readers-place):
# the page itself, .ai/runtime/status.html (`--html`, `--open`, `--refresh`),
# and the counts it reuses between full runs, .ai/runtime/status-counts
# (_status_counts_save).
# shellcheck shell=bash

cmd_status() {
  local mode=text
  while [ $# -gt 0 ]; do
    case "$1" in
      --html) [ "$mode" = open ] || mode=html; shift ;;
      --open) mode=open; shift ;;
      --refresh) mode=refresh; shift ;;
      *) jig_die "status: unknown argument: $1 (usage: jig status [--html | --open])" ;;
    esac
  done
  jig_require_repo
  if [ "$mode" != text ]; then
    _status_page "$mode"
    return 0
  fi
  _status_load
  _status_report
  # A full report is also when the page's cached counts are refreshed — only
  # where the page lives and only once it exists: `jig status` writes nothing
  # in a project that never asked for the page.
  if [ -f "$JIG_PROJECT/$JIG_AI_DIR/runtime/status.html" ] && [ -n "$_SC_AT" ] \
     && [ "$(jig_config_clone_root)" = "$JIG_PROJECT" ]; then
    _status_counts_save || true
  fi
}

# --- the counts that cost seconds ------------------------------------------------
#
# Three answers take most of `jig status`'s time: knowledge awaiting a decision
# (km_proposed_count), linked sources changed since acceptance
# (km_changed_sources_count) and what `jig upgrade` would install
# (upgrade_pending) — about three seconds together. A full report computes
# them; the page's redraw after every task command reuses the last full run's
# answers from .ai/runtime/status-counts and says how old they are, so the
# redraw stays well under a second.

_SC_READY=""      # set once the counts below are known for this process
_SC_PROPOSALS=""  # knowledge documents awaiting a decision; empty: unknown
_SC_SOURCES=""    # linked sources changed since acceptance; empty: unknown
_SC_PENDING=""    # items `jig upgrade` would install; empty: cannot tell
_SC_AT=""         # UTC time the counts were taken

# _status_counts — compute the three counts now.
_status_counts() {
  local pending rc=0
  _SC_PROPOSALS=$(km_proposed_count)
  _SC_SOURCES=$(km_changed_sources_count)
  # Omitted rather than 0 when it cannot be determined, most commonly because
  # this install's source checkout no longer exists (see the drift line).
  pending=$(upgrade_pending) || rc=$?
  if [ "$rc" = 0 ]; then
    _SC_PENDING=$(printf '%s\n' "$pending" | grep -c . || true)
  else
    _SC_PENDING=""
  fi
  _SC_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _SC_READY=1
}

# _status_counts_cached — the counts the last full run saved; computed (and
# saved) now when there are none yet, so a page first written by an older jig
# pays the full cost once rather than showing nothing.
_status_counts_cached() {
  local file="$JIG_PROJECT/$JIG_AI_DIR/runtime/status-counts" key value
  if [ ! -f "$file" ]; then
    _status_counts
    _status_counts_save || true
    return 0
  fi
  _SC_PROPOSALS="" _SC_SOURCES="" _SC_PENDING="" _SC_AT=""
  while IFS= read -r key || [ -n "$key" ]; do
    value=${key#*: }
    case "$key" in
      "at: "*) _SC_AT=$value ;;
      "proposals: "*) _SC_PROPOSALS=$value ;;
      "sources_changed: "*) _SC_SOURCES=$value ;;
      "pending: "*) _SC_PENDING=$value ;;
    esac
  done < "$file"
  # Anything but a number is unknown: the file is ours, but it is a file.
  case "$_SC_PROPOSALS" in '' | *[!0-9]*) _SC_PROPOSALS="" ;; esac
  case "$_SC_SOURCES" in '' | *[!0-9]*) _SC_SOURCES="" ;; esac
  case "$_SC_PENDING" in '' | *[!0-9]*) _SC_PENDING="" ;; esac
  _SC_READY=1
}

# _status_counts_save — write the counts for the next redraw, atomically.
_status_counts_save() {
  local dir="$JIG_PROJECT/$JIG_AI_DIR/runtime" file tmp
  file="$dir/status-counts"
  tmp="$file.tmp.$$"
  mkdir -p "$dir" || return 1
  {
    printf 'at: %s\n' "$_SC_AT"
    printf 'proposals: %s\n' "${_SC_PROPOSALS:-unknown}"
    printf 'sources_changed: %s\n' "${_SC_SOURCES:-unknown}"
    printf 'pending: %s\n' "${_SC_PENDING:-unknown}"
  } > "$tmp" && mv "$tmp" "$file"
}

# _status_load — source the peers whose answers this report consumes
# (ARCHITECTURE.md, Scripts layout: reporting commands are the exception).
_status_load() {
  # shellcheck source=lib/manifest.sh
  . "$JIG_LIB/manifest.sh"
  # shellcheck source=lib/upgrade.sh
  . "$JIG_LIB/upgrade.sh"
  # shellcheck source=lib/frontmatter.sh
  . "$JIG_LIB/frontmatter.sh"
  # shellcheck source=lib/knowledge.sh
  . "$JIG_LIB/knowledge.sh"
  # shellcheck source=lib/spec.sh
  . "$JIG_LIB/spec.sh"
  # shellcheck source=lib/task.sh
  . "$JIG_LIB/task.sh"
}

# _status_report — the plain-text report `jig status` prints.
_status_report() {
  printf '%s\n' "jig $JIG_VERSION"

  if [ ! -f "$JIG_PROJECT/$JIG_AI_DIR/config.yaml" ]; then
    printf '%s\n' "initialised: no"
    printf '%s\n' "hint: run \`jig init\` to bootstrap this project"
    return 0
  fi
  printf '%s\n' "initialised: yes"
  [ -n "$_SC_READY" ] || _status_counts
  _status_config_local
  _status_agent_git

  if manifest_exists; then
    local proj_version
    proj_version=$(manifest_header_get jig.version)
    printf '%s\n' "manifest: version=$proj_version mode=$(manifest_header_get jig.mode) source=$(manifest_source)"
    _status_framework_versions "$proj_version"
  else
    printf '%s\n' "manifest: missing"
  fi

  # Drift: one pass over the manifest, then one git process for every file
  # still on disk (jig_hash_list). A manifest_hash_of and a jig_hash per path
  # cost 1.5 s on a 72-file install — the manifest reread for every path, and
  # a git startup for every hash. Both lists stay in manifest order.
  local modified="" missing="" mcount=0 xcount=0 line rel mhash lhash drift_tmp
  drift_tmp=$(mktemp -d "${TMPDIR:-/tmp}/jig-status-drift.XXXXXX")
  : > "$drift_tmp/present"
  : > "$drift_tmp/rel"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mhash=${line%% *}
    rel=${line#* }
    if [ -f "$JIG_PROJECT/$rel" ]; then
      printf '%s %s\n' "$mhash" "$rel" >> "$drift_tmp/present"
      printf '%s\n' "$rel" >> "$drift_tmp/rel"
    else
      missing="$missing
$rel"
      xcount=$((xcount + 1))
    fi
  done < <(manifest_entries)
  jig_hash_list "$JIG_PROJECT" "$drift_tmp/rel" > "$drift_tmp/hashes" \
    || jig_die "status: could not hash the installed files"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lhash=${line%% *}
    line=${line#* }
    mhash=${line%% *}
    rel=${line#* }
    if [ "$lhash" != "$mhash" ]; then
      modified="$modified
$rel"
      mcount=$((mcount + 1))
    fi
  done < <(paste -d' ' "$drift_tmp/hashes" "$drift_tmp/present")
  rm -rf "$drift_tmp"

  # Pending: framework-owned items `jig upgrade` would install/link right
  # now (e.g. a skill added to the source since the last upgrade) — distinct
  # from drift above, which only covers paths already recorded in the
  # manifest. Omitted from the line entirely (rather than printed as "0
  # pending") when it cannot be determined, most commonly because this
  # install's source checkout no longer exists on this machine (domains/install):
  # that is a different, unknown state from "checked and found nothing
  # pending", and collapsing the two would misreport it as clean.
  if [ -n "$_SC_PENDING" ]; then
    printf '%s\n' "drift: $mcount modified, $xcount missing, $_SC_PENDING pending"
  else
    printf '%s\n' "drift: $mcount modified, $xcount missing"
  fi
  if [ "$mcount" -gt 0 ]; then
    printf '%s\n' "modified:"
    printf '%s\n' "$modified" | sed '/^$/d; s/^/  /'
  fi
  if [ "$xcount" -gt 0 ]; then
    printf '%s\n' "missing:"
    printf '%s\n' "$missing" | sed '/^$/d; s/^/  /'
  fi

  # Knowledge awaiting a decision. A proposed document is deliberately
  # invisible to every agent until a human accepts it (ADR-0016), and the
  # decision is deliberately allowed to outlive the session that proposed
  # (ADR-0018) — so the only thing that makes it discoverable later is this
  # line. Counted, not listed: `jig knowledge proposed` does the listing.
  if [ -z "$_SC_PROPOSALS" ]; then
    printf 'proposals: unknown (run jig status)\n'
  elif [ "$_SC_PROPOSALS" -gt 0 ]; then
    printf 'proposals: %s awaiting decision (jig knowledge proposed)\n' "$_SC_PROPOSALS"
  else
    printf 'proposals: none\n'
  fi

  # An accepted stub hands agents whatever its source says now. A source edited
  # after acceptance is still read — a merged edit went through the team's own
  # review — but a human has not approved it for agents, and without this line
  # `proposals: none` would be the only thing anyone saw (ADR-0036 as amended).
  if [ -n "$_SC_SOURCES" ] && [ "$_SC_SOURCES" -gt 0 ]; then
    printf 'sources changed: %s (jig knowledge sources)\n' "$_SC_SOURCES"
  fi

  # Specifications (jig-idea). A spec is a plan outside .ai/knowledge/, so no
  # `jig context` call ever surfaces it; this line is how an agent starting a
  # session learns that one exists. Counted, not listed: `jig spec list` lists.
  local specs
  specs=$(spec_count)
  if [ "$specs" -gt 0 ]; then
    printf 'specs: %s (jig spec list)\n' "$specs"
    spec_epic_status
  else
    printf 'specs: none\n'
  fi

  local found=0 rec line default_base blocking bcount autopilot_note
  [ -n "$_STATUS_LIVE_READY" ] || _status_live_collect
  default_base=$_STATUS_DEFAULT_BASE
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _status_rec "$rec"
    found=1
    line="task $_ST_ID class=$_ST_CLASS status=$_ST_STATUS"
    [ -z "$_ST_WT" ] || line="$line $_ST_WT_NOTE"
    # Same rule as `jig task list`: the base only where it is not the project's.
    if [ -n "$_ST_BASE" ] && [ "$_ST_BASE" != "$default_base" ]; then
      line="$line base=$_ST_BASE"
    fi
    if [ "$_ST_PAUSED" = "true" ]; then
      if [ -n "$_ST_REASON" ]; then
        line="$line paused ($_ST_REASON)"
      else
        line="$line paused"
      fi
    fi
    # Same predicate every gate uses (_task_blocking_findings, task.sh):
    # reporting never recomputes a peer's answer (ARCHITECTURE.md, Scripts
    # layout).
    blocking=$(_task_blocking_findings "$_ST_ID")
    if [ -n "$blocking" ]; then
      bcount=$(_task_count_lines "$blocking")
      [ "$bcount" -eq 0 ] || line="$line blocking=$bcount"
    fi
    # The answer `jig task receipt --check` gives (task_receipt_check,
    # task.sh), read once per task in _status_live_collect: a receipt that
    # exists but no longer matches the reviewed state. A task with no receipt
    # at all is not flagged here — that is "not reviewed yet", not "stale".
    case "$_ST_RECEIPT" in
      "receipt: stale"*) line="$line review=stale" ;;
    esac
    # Same predicate `jig task autopilot report` prints (_task_autopilot_note,
    # task.sh): a run mid-flight (`on`) or waiting on a human (`stopped`).
    # `done`, and a task that never ran one, add nothing (design.md, autopilot).
    # Asked only of a task whose state has a run at all; for any other the
    # answer is empty.
    if [ -n "$_ST_AUTOPILOT" ]; then
      autopilot_note=$(_task_autopilot_note "$_ST_ID")
      [ -z "$autopilot_note" ] || line="$line $autopilot_note"
    fi
    printf '%s\n' "$line"
  done <<EOF
$_STATUS_LIVE
EOF
  [ "$found" = 1 ] || printf '%s\n' "no active tasks"
  [ "$_STATUS_FINISHED" -gt 0 ] && printf '(%d finished; jig task list --all)\n' "$_STATUS_FINISHED"

  printf 'current task: %s\n' "${_STATUS_CURRENT:-$(_status_current_task)}"
  _status_checkout
  printf 'housekeeping: %s\n' "$(_status_housekeeping_age)"

  # Tasks a housekeeping flag still stands for (_status_hk_count): flagged by
  # the last run, and not disproved since by this disk.
  local nc kept wrong
  nc=$(_status_hk_count needs-consolidation)
  if [ "$nc" != "0" ]; then
    printf '%s\n' "needs consolidation: $nc task(s) (see .ai/runtime/housekeeping.log)"
  fi
  # A finished task whose worktree could not be removed is hidden from the
  # task listing above, so this line is the only place it surfaces. The
  # worktree usually holds work nobody committed (ADR-0029).
  kept=$(_status_hk_count worktree-kept)
  if [ "$kept" != "0" ]; then
    printf '%s\n' "worktrees kept: $kept task(s) (see .ai/runtime/housekeeping.log)"
  fi
  # Work that landed somewhere other than the task's base: kept, and only a
  # person can say where it should have gone (ADR-0039).
  wrong=$(_status_hk_count wrong-base)
  if [ "$wrong" != "0" ]; then
    printf '%s\n' "wrong base: $wrong task(s) (see .ai/runtime/housekeeping.log)"
  fi

  _status_session_hook
  _status_instructions
}

# The live tasks, read once per report and shared by the text report and the
# page: _STATUS_LIVE holds one record per task still in flight, fields joined
# by the unit separator (\037) so that an empty one survives a `read`.
# Finished tasks are counted in _STATUS_FINISHED, not listed: on a
# long-lived branch they would crowd out the tasks actually in flight (same
# rule as `jig task list`, see _task_is_live).
_STATUS_LIVE=""
_STATUS_LIVE_READY=""
_STATUS_FINISHED=0
_STATUS_WORKTREES=""
_STATUS_DEFAULT_BASE=""
_STATUS_US=$(printf '\037')

# _status_task_rows — every workspace's `state`, in one awk pass rather than a
# sed per key per task: the page is redrawn after every task command, and a
# process per value made ten tasks cost seconds. One line per state file,
# <task_id> <class> <status> <paused> <paused_reason> <branch> <base_branch>
# <autopilot> <pr_url> <knowledge_consolidated>, joined by \037; each value is
# what `sed -n 's/^<key>:[[:space:]]*//p' | head -n 1` gave, the first match.
_status_task_rows() {
  local f
  set --
  for f in "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"/*/state; do
    if [ -f "$f" ]; then set -- "$@" "$f"; fi
  done
  [ $# -gt 0 ] || return 0
  awk '
    function out() {
      if (have)
        printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n",
          v["task_id"], v["class"], v["status"], v["paused"], v["paused_reason"],
          v["branch"], v["base_branch"], v["autopilot"], v["pr_url"], v["knowledge_consolidated"]
    }
    FNR == 1 { out(); split("", v); split("", seen); have = 1 }
    /^[^:]+:/ {
      k = $0
      sub(/:.*/, "", k)
      if (!(k in seen)) { seen[k] = 1; x = $0; sub(/^[^:]*:[[:space:]]*/, "", x); v[k] = x }
    }
    END { out() }
  ' "$@"
}

# _status_live_collect [page] — fill _STATUS_LIVE, _STATUS_FINISHED and
# _STATUS_WORKTREES. Per live task it asks the peers once: where its branch is
# checked out (git's own list, ADR-0029) and how many files wait there, and
# the receipt line `jig task receipt --check` prints (task_receipt_check). With
# `page`, also the answers only the page shows: the gate of a T3/T4 design
# (_task_gate_state) and the autopilot run (_task_autopilot_facts).
_status_live_collect() {
  local page="${1:-}" row id class status paused reason branch base autopilot pr_url kc
  local wt wt_note receipt gate facts us="$_STATUS_US"
  _STATUS_FINISHED=0
  _STATUS_LIVE=""
  _STATUS_WORKTREES=$(_task_worktrees)
  _STATUS_DEFAULT_BASE=$(cfg git.base_branch main)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS="$us" read -r id class status paused reason branch base autopilot pr_url kc <<EOF
$row
EOF
    case "$status" in
      active | ready) ;;
      *) _STATUS_FINISHED=$((_STATUS_FINISHED + 1)); continue ;;
    esac
    [ "$paused" = true ] || reason=""
    wt="" wt_note=""
    if [ -n "$branch" ]; then
      wt=$(_task_worktree_for "$branch" "$_STATUS_WORKTREES")
      [ -z "$wt" ] || wt_note=$(_task_worktree_note "$wt")
    fi
    # task_receipt_check exits 1 for stale and for a T4 with none; its line
    # is the answer either way.
    receipt=$(task_receipt_check "$id" || true)
    gate="" facts=""
    if [ "$page" = page ]; then
      case "$class" in
        T3 | T4) gate=$(_task_gate_state "$id") ;;
      esac
      [ -z "$autopilot" ] || facts=$(_task_autopilot_facts "$id")
    fi
    _STATUS_LIVE="$_STATUS_LIVE$id$us$class$us$status$us$paused$us$reason$us$branch$us$base$us$autopilot$us$pr_url$us$kc$us$wt$us$wt_note$us$receipt$us$gate$us$facts
"
  done <<EOF
$(_status_task_rows)
EOF
  _STATUS_LIVE_READY=1
}

# _status_rec <record> — one _STATUS_LIVE record into the _ST_* globals.
# _ST_APFACTS is _task_autopilot_facts' line, tab-separated, or empty.
_status_rec() {
  IFS="$_STATUS_US" read -r _ST_ID _ST_CLASS _ST_STATUS _ST_PAUSED _ST_REASON _ST_BRANCH _ST_BASE \
    _ST_AUTOPILOT _ST_PR_URL _ST_KC _ST_WT _ST_WT_NOTE _ST_RECEIPT _ST_GATE _ST_APFACTS <<EOF
$1
EOF
}

# _status_current_task — the workspace whose branch matches the checkout
# (ADR-0008). Three outcomes (design.md §2): exactly one candidate prints its
# id, none prints "none", several print "ambiguous (a, b)" built from
# task_current's own stderr (one line per candidate, id is the first field)
# rather than re-deriving the candidate list here.
_status_current_task() {
  local current cur_rc=0 cur_err_file ids
  cur_err_file=$(mktemp "${TMPDIR:-/tmp}/jig-status-current.XXXXXX")
  current=$(task_current 2>"$cur_err_file") || cur_rc=$?
  case "$cur_rc" in
    0)
      printf '%s\n' "$current"
      ;;
    2)
      ids=$(awk '{ if (NR > 1) printf ", "; printf "%s", $1 }' "$cur_err_file")
      printf 'ambiguous (%s)\n' "$ids"
      ;;
    *)
      printf 'none\n'
      ;;
  esac
  rm -f "$cur_err_file"
}

# _status_checkout — other work going on in this checkout, one line each
# (checkout.sh). Silent when there is none, like the housekeeping flags below:
# a checkout with one session in it has nothing to report.
#
# The task whose branch is checked out here is left out — the reader is
# sitting on it. A record named by a session id rather than a task is shown as
# "another session": the id names a runtime's session, which means nothing to
# a person, and the fact they need is that somebody else is here.
_status_checkout() {
  local here name age cmd label
  here=$(jig_checkout_here_task)
  while read -r name age cmd; do
    [ -n "$name" ] || continue
    if [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$name/state" ]; then
      label="task $name"
    else
      label="another session"
    fi
    printf 'working here: %s (jig %s, %s ago)\n' "$label" "$cmd" "$(jig_checkout_ago "$age")"
  done < <(jig_checkout_busy "$here")

  # A reader told nothing cannot tell "nobody else is here" from "there is no
  # way to see anybody", so the second case says so — as the session hook's
  # line already does for the same exit 2 (ADR-0024).
  local problem
  problem=$(jig_checkout_session_problem)
  [ -z "$problem" ] || printf 'sessions: not observable (%s)\n' "$problem"
}

# _status_housekeeping_age — "<n> days ago" since the last housekeeping run,
# or "never".
_status_housekeeping_age() {
  local hk_file="$JIG_PROJECT/$JIG_AI_DIR/runtime/last-housekeeping"
  if [ -f "$hk_file" ]; then
    printf '%s\n' "$(jig_file_age_days "$hk_file") days ago"
  else
    printf '%s\n' "never"
  fi
}

# _status_hk_count <flag> — how many tasks <flag> still stands for, 0 when
# housekeeping has never logged. Housekeeping exits 3 for these, but nothing
# keeps that exit code around, and a flag nobody sees is the manual discipline
# the framework exists to remove (RULES.md, Scope invariants).
#
# Counted from _status_flagged_ids, so this line and the page's cards name the
# same tasks: a count that said two while the cards showed one would send the
# reader looking for a task that is not there.
_status_hk_count() {
  _status_flagged_ids "$1" | grep -c . || true
}

# --- the status page (`jig status --html | --open`) ------------------------------
#
# One self-contained HTML file for a person who does not live in a terminal
# (.ai/specs/autopilot/, Phase 5; adr-20260924-the-status-page-keeps-the-readers-place):
# inline CSS and one static inline script, no external asset, so it opens
# from disk with the network off, and it follows the reader's light or dark
# preference. It
# answers, in this order, what needs the reader, what is running, how far the
# specifications are, and then everything `jig status` prints.
#
# It stays current without a server: the commands that change a task, a spec
# or a housekeeping result redraw it (jig_status_page_touch, common.sh), and
# the open page reloads itself every 10 seconds. The script does the reloading
# (adr-20260924-the-status-page-keeps-the-readers-place): it waits while the
# reader is busy, keeps their scroll position and open <details> across the
# reload in sessionStorage, and offers a pause. Without JavaScript the
# `<meta http-equiv="refresh">` in <noscript> reloads it as before. One page
# per clone, in the main checkout: the page belongs to the checkout that owns
# the workspaces, and a worktree hands every mode to the main checkout's own
# jig (`_status_page`, below).
#
# Everything on it is an answer this report already consumes — the same
# helpers the text report and the completion gates call — and every value is
# escaped with _status_h, because task ids, reasons, finding locations, spec
# titles and paths are text people wrote.

# Script-global: the EXIT trap runs after _status_html has returned.
_STATUS_HTML_TMP=""
_STATUS_CURRENT=""  # the current task, asked once per page

# How often the open page reloads itself, in seconds (task.md, human gate).
_STATUS_REFRESH=10

# _status_page html|open|refresh — write the page (and open it). `refresh` is
# the redraw the writers run: silent, nothing at all when there is no page
# yet, and from the cached counts. Run in a worktree, every mode is handed to
# the main checkout's own jig, which owns the page.
_status_page() {
  local mode="$1" root jig path
  root=$(jig_config_clone_root)
  if [ "$root" != "$JIG_PROJECT" ]; then
    jig="$root/$JIG_AI_DIR/scripts/jig"
    if [ "$mode" = refresh ]; then
      [ -f "$jig" ] || return 0
      (cd "$root" && bash "$jig" status --refresh)
      return 0
    fi
    [ -f "$jig" ] || jig_die "status --$mode: the main checkout has no jig to write its page: $root"
    path=$(cd "$root" && bash "$jig" status --html) || exit 1
    printf '%s\n' "$path"
    [ "$mode" != open ] || _status_open "$path"
    return 0
  fi

  if [ ! -f "$JIG_PROJECT/$JIG_AI_DIR/config.yaml" ]; then
    [ "$mode" != refresh ] || return 0
    jig_die "status --$mode: project is not initialised; run: jig init"
  fi
  if [ "$mode" = refresh ]; then
    [ -f "$JIG_PROJECT/$JIG_AI_DIR/runtime/status.html" ] || return 0
    _status_load
    _status_counts_cached
    _status_html >/dev/null
    return 0
  fi
  _status_load
  _status_counts
  _status_counts_save || true
  path=$(_status_html)
  printf '%s\n' "$path"
  [ "$mode" != open ] || _status_open "$path"
  return 0
}

# _status_html — write .ai/runtime/status.html and print its path.
_status_html() {
  local dir="$JIG_PROJECT/$JIG_AI_DIR/runtime" out
  out="$dir/status.html"
  mkdir -p "$dir" || jig_die "status --html: cannot create $dir"
  _STATUS_HTML_TMP="$out.tmp.$$"
  trap 'if [ -n "${_STATUS_HTML_TMP:-}" ]; then rm -f "$_STATUS_HTML_TMP"; fi' EXIT INT TERM
  _status_html_page > "$_STATUS_HTML_TMP"
  mv "$_STATUS_HTML_TMP" "$out" || jig_die "status --html: cannot write $out"
  _STATUS_HTML_TMP=""
  printf '%s\n' "$out"
}

# _status_open <path> — open the page in the default browser, with what the
# system already has (ADR-0002): `open` on macOS, `cmd /c start` from Git Bash
# (ADR-0037), `explorer.exe` inside WSL, `xdg-open` elsewhere. With none, or
# when it fails — a server over SSH has no browser — the page is written all
# the same and the reader is told where it is; never an error.
_status_open() {
  local path="$1" win
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if command -v open >/dev/null 2>&1 && open "$path" >/dev/null 2>&1; then return 0; fi
      ;;
    MINGW* | MSYS* | CYGWIN*)
      # MSYS rewrites arguments that look like paths unless conversion is off,
      # and cmd.exe needs the path in Windows form (as _jig_junction does).
      if command -v cmd >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1 \
         && win=$(cygpath -w "$path") \
         && MSYS2_ARG_CONV_EXCL='*' cmd /c start "" "$win" >/dev/null 2>&1; then
        return 0
      fi
      ;;
    *)
      if command -v wslpath >/dev/null 2>&1 && command -v explorer.exe >/dev/null 2>&1 \
         && win=$(wslpath -w "$path" 2>/dev/null); then
        # explorer.exe exits 1 even when it opened the file.
        explorer.exe "$win" >/dev/null 2>&1 || true
        return 0
      fi
      if command -v xdg-open >/dev/null 2>&1 && xdg-open "$path" >/dev/null 2>&1; then return 0; fi
      ;;
  esac
  printf 'status --open: could not open a browser here; open this file in your browser: %s\n' "$path" >&2
  return 0
}

# _status_h <text> — <text> escaped for HTML text and attribute values.
# sed, not ${var//&/...}: from bash 5.2 an `&` in that replacement means the
# matched text (patsub_replacement), so the same line escapes differently on
# macOS's bash 3.2 and a Linux bash.
# Text with nothing to escape is printed as it is, without a sed process: the
# page escapes a few hundred values, and the redraw runs after every task
# command.
_status_h() {
  case "$1" in
    *[\&\<\>\"\']*) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# _status_html_item <label> <value> <attention: 0|1> — one summary entry.
_status_html_item() {
  local cls="item"
  [ "$3" = 0 ] || cls="item attention"
  printf '<div class="%s"><dt>%s</dt><dd>%s</dd></div>\n' "$cls" "$(_status_h "$1")" "$(_status_h "$2")"
}

# _status_html_count <label> <n> — a summary entry that needs attention
# when <n> is not 0; "unknown" when <n> is empty.
_status_html_count() {
  if [ -z "$2" ]; then
    _status_html_item "$1" "unknown" 0
  elif [ "$2" = 0 ]; then
    _status_html_item "$1" "none" 0
  else
    _status_html_item "$1" "$2" 1
  fi
}

# _status_epoch <UTC ISO time> — seconds since the epoch, or nothing. BSD date
# first (macOS), GNU date otherwise (Linux, Git Bash).
_status_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || true
}

# _status_zone — reads "<date> <time> <offset> <zone>" (date's `%z %Z`) on
# stdin and prints "<date> <time> <zone>", naming a +0000 offset `UTC`
# whatever the zone abbreviation says: Git Bash's `date` calls TZ=UTC `GMT`,
# and the reader should see one name for the same zone on every platform.
_status_zone() {
  awk '{ z = ($4 != "") ? $4 : $3; if ($3 == "+0000" || $3 == "-0000") z = "UTC"; print $1, $2, z }'
}

# _status_when <UTC ISO time> — the same moment in the reader's local time,
# "YYYY-MM-DD HH:MM <zone>", like the page's own "updated" line; the input
# unchanged when it cannot be read. BSD `date -r <seconds>`, else GNU `-d @`.
_status_when() {
  local e out=""
  e=$(_status_epoch "$1")
  if [ -n "$e" ]; then
    out=$(date -r "$e" '+%Y-%m-%d %H:%M %z %Z' 2>/dev/null \
      || date -d "@$e" '+%Y-%m-%d %H:%M %z %Z' 2>/dev/null) || out=""
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | _status_zone
  else
    printf '%s\n' "$1"
  fi
}

# _status_ago <UTC ISO time> — how long ago, in words a person reads at a
# glance: "just now", "12 min", "3 h", "2 days"; empty when unparsable.
_status_ago() {
  local past now d
  past=$(_status_epoch "$1")
  [ -n "$past" ] || return 0
  now=$(date -u +%s)
  d=$((now - past))
  if [ "$d" -lt 60 ]; then printf 'just now\n'
  elif [ "$d" -lt 3600 ]; then printf '%d min\n' $((d / 60))
  elif [ "$d" -lt 172800 ]; then printf '%d h\n' $((d / 3600))
  else printf '%d days\n' $((d / 86400))
  fi
}

# _status_hk_ids <regex> — the tasks whose line in the last housekeeping run
# matches <regex>, distinct and in log order; nothing when housekeeping has
# never logged. The one reader of the log's task lines here; what the log said
# is where a flag starts, not where it ends -- _status_flagged_ids asks this
# disk whether the flag still stands.
_status_hk_ids() {
  local hk_log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  [ -f "$hk_log" ] || return 0
  _status_hk_ids_in "$hk_log" "$1"
}

_status_hk_ids_in() {
  JIG_HK_RE="$2" awk '
    # split("", seen) clears the array portably; `delete seen` is an
    # extension not every awk on a supported machine has.
    /^--- run / { split("", seen); n = 0; next }
    $0 ~ ENVIRON["JIG_HK_RE"] {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^task=/) {
          id = substr($i, 6)
          if (!(id in seen)) { seen[id] = 1; ids[++n] = id }
        }
      }
    }
    END { for (i = 1; i <= n; i++) print ids[i] }
  ' "$1"
}

# _status_hk_run — "<UTC time>\t<forge>" of the last housekeeping run, from its
# `--- run` marker; <forge> is github|gitlab|none|failed, `-` when the marker
# predates the field. Nothing when housekeeping has never logged a run.
_status_hk_run() {
  local hk_log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  [ -f "$hk_log" ] || return 0
  awk '
    /^--- run / {
      at = $3; forge = "-"
      for (i = 4; i <= NF; i++) if ($i ~ /^forge=/) forge = substr($i, 7)
    }
    END { if (at != "") printf "%s\t%s\n", at, forge }
  ' "$hk_log"
}

# _status_hk_stale <UTC time> <forge> — exit 0 when the pull request states of
# that run cannot be trusted as current: the forge did not answer, or the run
# is older than `housekeeping.cadence`, after which the session hook would
# have run a new one.
_status_hk_stale() {
  local at="$1" forge="$2" cadence days past now
  [ "$forge" != failed ] || return 0
  cadence=$(cfg housekeeping.cadence 1d)
  days=${cadence%d}
  case "$days" in '' | *[!0-9]*) days=1 ;; esac
  past=$(_status_epoch "$at")
  [ -n "$past" ] || return 0
  now=$(date -u +%s)
  [ $((now - past)) -gt $((days * 86400)) ]
}

# _status_in <id> <list> — exit 0 when <id> is a line of <list>.
_status_in() {
  jig_has_line "$1" "$2"
}

_status_html_page() {
  local project generated report
  project=$(basename "$JIG_PROJECT")
  generated=$(date '+%Y-%m-%d %H:%M:%S %z %Z' | _status_zone)
  # Asked once: the report and the summary both show it.
  _STATUS_CURRENT=$(_status_current_task)
  # The whole text report, as `jig status` prints it, so the page never shows
  # less than the terminal does. errexit is set again inside the
  # substitution, which does not inherit it.
  # The tasks, read once for the report and the sections below.
  _status_live_collect page
  report=$(set -e; _status_report)

  _STATUS_HK_RUN=$(_status_hk_run)
  _STATUS_HK_AT=$(printf '%s\n' "$_STATUS_HK_RUN" | cut -f 1)
  _STATUS_HK_FORGE=$(printf '%s\n' "$_STATUS_HK_RUN" | cut -f 2)
  _STATUS_HK_WHEN=""
  [ -z "$_STATUS_HK_AT" ] || _STATUS_HK_WHEN=$(_status_when "$_STATUS_HK_AT")

  cat <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
HTML
  printf '<noscript><meta http-equiv="refresh" content="%s"></noscript>\n' "$_STATUS_REFRESH"
  printf '<title>Jig status: %s</title>\n' "$(_status_h "$project")"
  cat <<'HTML'
<style>
:root {
  --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0; --panel: #f6f8fa;
  --ok-bg: #dafbe1; --ok-fg: #116329; --bad-bg: #ffebe9; --bad-fg: #a40e26;
  --warn-bg: #fff8c5; --warn-fg: #7d4e00; --accent: #0969da;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --line: #3d444d; --panel: #151b23;
    --ok-bg: #12361f; --ok-fg: #7ee2a8; --bad-bg: #3c1618; --bad-fg: #ffa198;
    --warn-bg: #3a2c05; --warn-fg: #e3b341; --accent: #4493f8;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 80px; }
h1 { font-size: 1.6rem; margin: 0 0 4px; }
h2 { font-size: 1.15rem; margin: 32px 0 12px; padding-bottom: 6px; border-bottom: 1px solid var(--line); }
h3 { font-size: 1rem; margin: 20px 0 8px; }
p { margin: 0 0 8px; }
a { color: var(--accent); overflow-wrap: anywhere; }
.muted { color: var(--muted); }
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.9em; }
.cards { display: grid; gap: 10px; }
.card { background: var(--warn-bg); border: 1px solid var(--warn-fg); border-radius: 8px; padding: 12px 14px; }
.card h3 { margin: 0 0 4px; color: var(--warn-fg); }
.card p { margin: 4px 0 0; overflow-wrap: anywhere; }
.card .todo { font-weight: 600; }
.nothing { padding: 14px; background: var(--ok-bg); color: var(--ok-fg); border-radius: 8px; font-weight: 600; }
dl.summary { display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 10px; margin: 0; }
.item { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; }
.item dt { color: var(--muted); font-size: 0.85rem; }
.item dd { margin: 2px 0 0; font-weight: 600; overflow-wrap: anywhere; }
.item.attention { background: var(--warn-bg); border-color: var(--warn-fg); }
.item.attention dd { color: var(--warn-fg); }
.scroll { overflow-x: auto; border: 1px solid var(--line); border-radius: 8px; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; vertical-align: top; padding: 8px 10px; border-bottom: 1px solid var(--line); }
th { background: var(--panel); font-size: 0.85rem; color: var(--muted); font-weight: 600; white-space: nowrap; }
tr:last-child td { border-bottom: 0; }
td.path { overflow-wrap: anywhere; min-width: 12rem; }
td.id code { white-space: nowrap; }
.badge { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 0.85rem;
  background: var(--panel); border: 1px solid var(--line); white-space: nowrap; }
.badge.ok { background: var(--ok-bg); color: var(--ok-fg); border-color: transparent; }
.badge.bad { background: var(--bad-bg); color: var(--bad-fg); border-color: transparent; }
.badge.warn { background: var(--warn-bg); color: var(--warn-fg); border-color: transparent; }
.bar { display: inline-block; width: 120px; height: 8px; background: var(--panel); border: 1px solid var(--line);
  border-radius: 999px; overflow: hidden; vertical-align: middle; margin-right: 8px; }
.bar span { display: block; height: 100%; background: var(--ok-fg); }
ul.findings { margin: 0; padding-left: 18px; }
ul.findings li { color: var(--bad-fg); }
.empty { padding: 14px; background: var(--panel); border: 1px dashed var(--line); border-radius: 8px; color: var(--muted); }
details { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; margin-top: 10px; }
summary { cursor: pointer; }
pre { margin: 10px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.autorefresh { position: fixed; right: 16px; bottom: 16px; display: flex; gap: 8px; align-items: center;
  background: var(--panel); border: 1px solid var(--line); border-radius: 999px; padding: 4px 6px 4px 14px;
  font-size: 0.85rem; color: var(--muted); box-shadow: 0 1px 4px rgba(0, 0, 0, 0.15); }
.autorefresh[hidden] { display: none; }
.autorefresh.paused { background: var(--warn-bg); border-color: var(--warn-fg); color: var(--warn-fg); }
.autorefresh button { font: inherit; font-weight: 600; color: var(--accent); background: transparent;
  border: 1px solid var(--line); border-radius: 999px; padding: 2px 10px; cursor: pointer; }
.autorefresh.paused button { color: var(--warn-fg); border-color: var(--warn-fg); }
</style>
</head>
<body>
<main>
HTML
  printf '<h1>Jig status</h1>\n'
  printf '<p class="muted">Project <strong>%s</strong> · updated %s · jig %s</p>\n' \
    "$(_status_h "$project")" "$(_status_h "$generated")" "$(_status_h "$JIG_VERSION")"
  printf '<p class="muted">This page refreshes itself every %s seconds while it is open, and jig redraws it whenever a task changes.</p>\n' \
    "$_STATUS_REFRESH"
  _status_html_freshness

  _status_html_needs
  _status_html_phase_run
  _status_html_tasks
  _status_html_specs
  _status_html_summary

  printf '<section id="report">\n<h2>Full report</h2>\n'
  printf '<details id="full-report"><summary>What <code>jig status</code> prints</summary>\n<pre>%s</pre>\n</details>\n</section>\n' \
    "$(_status_h "$report")"
  printf '</main>\n'
  _status_html_autorefresh
  printf '</body>\n</html>\n'
}

# _status_html_autorefresh — the pause control and the one inline script
# (adr-20260924-the-status-page-keeps-the-readers-place). The control stays
# hidden unless the script runs. The script is static: the reload interval is
# the only value in it, and it writes to the page through textContent only.
# It reloads once _STATUS_REFRESH seconds have passed, but not while the tab
# is hidden, text is selected, the reader acted in the last 3 seconds or the
# reader paused it; the open <details> (by id), the scroll position (as an
# offset into the nearest <section>) and the pause survive the reload in
# sessionStorage. Every storage access may throw, and then the page only
# forgets them.
_status_html_autorefresh() {
  printf '<div id="autorefresh" class="autorefresh" hidden><span id="autorefresh-text"></span>'
  printf '<button type="button" id="autorefresh-toggle"></button></div>\n'
  printf '<script>\n(function () {\n'
  printf "try { history.scrollRestoration = 'manual'; } catch (e) {}\\n"
  printf 'var every = %s * 1000, quiet = 3000;\n' "$_STATUS_REFRESH"
  cat <<'HTML'
var key = 'jig-status:' + location.pathname, loaded = Date.now(), acted = 0, state = {};
var bar = document.getElementById('autorefresh');
var text = document.getElementById('autorefresh-text');
var toggle = document.getElementById('autorefresh-toggle');
try { state = JSON.parse(sessionStorage.getItem(key)) || {}; } catch (e) { state = {}; }
function save() {
  var open = [], at = null, off = 0, i, all, top;
  all = document.querySelectorAll('details[id]');
  for (i = 0; i < all.length; i++) { if (all[i].open) open.push(all[i].id); }
  all = document.querySelectorAll('section[id]');
  for (i = 0; i < all.length; i++) {
    top = all[i].getBoundingClientRect().top;
    if (top <= 1) { at = all[i].id; off = -top; }
  }
  try {
    sessionStorage.setItem(key, JSON.stringify({ paused: !!state.paused, open: open,
      at: at, off: off, y: window.scrollY }));
  } catch (e) {}
}
function restore() {
  var i, el, y;
  if (state.open) {
    for (i = 0; i < state.open.length; i++) {
      el = document.getElementById(state.open[i]);
      if (el && el.tagName === 'DETAILS') el.open = true;
    }
  }
  el = state.at ? document.getElementById(state.at) : null;
  y = el ? el.getBoundingClientRect().top + window.scrollY + (state.off || 0) : state.y;
  if (y > 0) window.scrollTo(0, y);
}
function show() {
  bar.className = state.paused ? 'autorefresh paused' : 'autorefresh';
  text.textContent = state.paused ? 'Auto-refresh paused'
    : 'Auto-refresh every ' + every / 1000 + ' s · keeps your place';
  toggle.textContent = state.paused ? 'Resume' : 'Pause';
  bar.hidden = false;
}
function busy() {
  var sel = window.getSelection ? window.getSelection() : null;
  return document.hidden || Date.now() - acted < quiet || (sel && !sel.isCollapsed && String(sel) !== '');
}
function tick() {
  if (state.paused || Date.now() - loaded < every || busy()) return;
  save();
  location.reload();
}
toggle.addEventListener('click', function () {
  state.paused = !state.paused;
  save();
  if (state.paused) show(); else location.reload();
});
['scroll', 'wheel', 'keydown', 'pointerdown', 'touchstart'].forEach(function (name) {
  window.addEventListener(name, function () { acted = Date.now(); }, { passive: true });
});
document.addEventListener('visibilitychange', tick);
window.addEventListener('pagehide', save);
restore();
show();
setInterval(tick, 1000);
})();
</script>
HTML
}

# _status_html_freshness — how old the two borrowed kinds of data are: pull
# request states from the last housekeeping run, and the counts from the last
# full `jig status`.
_status_html_freshness() {
  if [ -z "$_STATUS_HK_AT" ]; then
    printf '<p class="muted">Housekeeping has not run yet: a pull request shows here only when jig opened it, until <code>jig housekeeping</code> runs.</p>\n'
  elif [ "$_STATUS_HK_FORGE" = none ]; then
    printf '<p class="muted">Housekeeping last ran at %s, with no GitHub or GitLab to ask: open pull requests are shown only for tasks jig opened them for.</p>\n' \
      "$(_status_h "$_STATUS_HK_WHEN")"
  elif _status_hk_stale "$_STATUS_HK_AT" "$_STATUS_HK_FORGE"; then
    printf '<p class="muted">Pull request data from housekeeping at %s <span class="badge warn">stale</span> — run <code>jig housekeeping</code> to update it.</p>\n' \
      "$(_status_h "$_STATUS_HK_WHEN")"
  else
    printf '<p class="muted">Pull request data from housekeeping at %s.</p>\n' "$(_status_h "$_STATUS_HK_WHEN")"
  fi
  if [ -n "$_SC_AT" ]; then
    printf '<p class="muted">Knowledge and upgrade counts from the last full <code>jig status</code> at %s.</p>\n' \
      "$(_status_h "$(_status_when "$_SC_AT")")"
  fi
}

# _status_card <title> <id> <detail> <todo> [url] [badge-html] — one "needs
# you" card. <id> and <detail> may be empty; <url> becomes a link only when it
# is https. <badge-html> is markup this file wrote, never a value.
_status_card() {
  printf '<div class="card"><h3>%s%s</h3>' "$(_status_h "$1")" "${6:+ $6}"
  if [ -n "$2" ] || [ -n "$3" ]; then
    printf '<p>'
    [ -z "$2" ] || printf '<code>%s</code>' "$(_status_h "$2")"
    [ -z "$2" ] || [ -z "$3" ] || printf ' · '
    [ -z "$3" ] || printf '%s' "$(_status_h "$3")"
    printf '</p>'
  fi
  case "${5:-}" in
    https://*) printf '<p><a href="%s">%s</a></p>' "$(_status_h "$5")" "$(_status_h "$5")" ;;
    ?*) printf '<p><code>%s</code></p>' "$(_status_h "$5")" ;;
  esac
  printf '<p class="todo">%s</p></div>\n' "$(_status_h "$4")"
}

# _status_html_needs — what only the reader can do, most urgent first: a
# stopped autopilot run, a design at its gate, a finished task waiting for its
# git step, a pull request to review or merge, a merged task to close, work
# that landed wrong or was left in a worktree, knowledge to decide. Each card
# says in plain words what to do. Nothing to do is said out loud too.
_status_html_needs() {
  local cards="" stopped="" gates="" git_steps="" rec id stop_reason stop_at ago level queue url live hk_note pr_ids=""
  local nc wrong kept closed open settled phase phase_stops=""
  hk_note=""
  [ -z "$_STATUS_HK_AT" ] || hk_note="housekeeping at $_STATUS_HK_WHEN"
  level=$(jig_agent_git 2>/dev/null) || level=none
  settled=$(_status_hk_ids ' remote=(merged|closed) ')

  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _status_rec "$rec"
    # A pull request jig opened, unless housekeeping already saw it settled.
    # Collected before anything below, because the branches that follow end
    # the iteration: a task whose autopilot stopped is exactly the one that
    # has just been shipped, and its pull request was the card most likely to
    # be missing.
    if [ -n "$_ST_PR_URL" ] && ! _status_in "$_ST_ID" "$settled"; then
      pr_ids="$pr_ids$_ST_ID
"
    fi
    # 1. A stopped autopilot run waits on an answer (its journal's last stop).
    if [ "$_ST_AUTOPILOT" = stopped ]; then
      stop_reason=$(printf '%s\n' "$_ST_APFACTS" | cut -f 5)
      stop_at=$(printf '%s\n' "$_ST_APFACTS" | cut -f 6)
      if [ -z "$stop_reason" ] || [ "$stop_reason" = "-" ]; then
        stop_reason="no reason recorded"
      fi
      # The reason was written once, when the run stopped, and nothing
      # rechecks it: it is prose, and the task moves on without it. So the
      # card quotes it as what was said then -- the age leads, and the reason
      # follows a colon -- instead of appending the age to a sentence that
      # then reads as true now. What is true now the page derives itself, in
      # the cards around this one.
      ago=""
      [ -z "$stop_at" ] || [ "$stop_at" = "-" ] || ago=$(_status_ago "$stop_at")
      case "$ago" in
        '') stop_reason="stopped: $stop_reason" ;;
        "just now") stop_reason="stopped just now: $stop_reason" ;;
        *) stop_reason="stopped $ago ago: $stop_reason" ;;
      esac
      # A task of a phase run has no session of its own to answer in: its
      # agent was started by a coordinator, which is where the question
      # surfaced and where the answer goes back
      # (adr-20260922-a-phase-run-is-coordinated). Every stop of one phase is
      # held back here and becomes a single card below — the page says what
      # the coordinator says in chat, one message for the whole wave.
      phase=$(printf '%s\n' "$_ST_APFACTS" | cut -f 7)
      if [ -n "$phase" ] && [ "$phase" != "-" ]; then
        phase_stops="$phase_stops$phase	$_ST_ID	$stop_reason
"
        continue
      fi
      stopped="$stopped$(_status_card "Autopilot stopped and is waiting for you" "$_ST_ID" "$stop_reason" \
        "Answer the agent in this task's session; it resumes the run." "" '<span class="badge warn">autopilot stopped</span>')
"
      continue
    fi
    # 2. A design waits at its human gate, or changed after it was approved.
    case "$_ST_GATE" in
      waiting)
        gates="$gates$(_status_card "A design is waiting for your decision" "$_ST_ID" "design.md in the task's workspace" \
          "Read the design the agent showed you and approve it, or say what to change.")
" ;;
      changed)
        gates="$gates$(_status_card "A design changed after you approved it" "$_ST_ID" "design.md in the task's workspace" \
          "Read what changed and approve it again before the work goes on.")
" ;;
    esac
    # 3. Finished, and the next git step is the reader's (agent.git). Only
    # once the knowledge decision is recorded: that is the last step before
    # `jig task ship`, so an earlier `ready` is still the agent's.
    if [ "$_ST_STATUS" = ready ] && [ "$_ST_KC" = true ] && [ -z "$_ST_PR_URL" ]; then
      queue=""
      case "$level" in
        none) queue="Review the changes and commit them: the agent may not commit in this clone." ;;
        commit) queue="Push the task's branch: the agent may commit but not push in this clone." ;;
        push) queue="Open a pull request for the task's branch: the agent may push but not open one here." ;;
      esac
      [ -z "$queue" ] || git_steps="$git_steps$(_status_card "Ready for your step in git" "$_ST_ID" "agent.git: $level" "$queue")
"
    fi
  done <<EOF
$_STATUS_LIVE
EOF
  # Most urgent first, whatever order the workspaces came in; a phase run's
  # stops come first of all, as one card per phase.
  cards="$(_status_phase_stop_cards "$phase_stops")$stopped$gates$git_steps"

  # 4. A pull request waits for review or merge: one jig opened (pr_url), or
  # one the last housekeeping run saw open (a closed task's too).
  #
  # Deliberately outside _status_flagged_ids, and "a closed task's too" is the
  # reason: closing a task does not merge its pull request, so a consolidated
  # task with `remote=open` contradicts nothing and this card still asks for
  # something real. Only the forge can answer whether it is open, which is why
  # it is worded in the past tense and asks for a refresh first.
  #
  # One live answer does reach it, in the loop below: a task the person
  # abandoned. That disproves no flag either -- it makes the card's ask wrong,
  # so the card changes what it asks instead of disappearing.
  open=$(_status_hk_ids ' remote=open ')
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _status_in "$id" "$pr_ids" || pr_ids="$pr_ids$id
"
  done <<EOF
$open
EOF
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # Guarded for the same reason as in _status_hk_recheck: these ids include
    # the log's, and a malformed one would take task_dir into jig_die, which
    # redraws the page being drawn.
    url="" live=""
    if jig_valid_id "$id"; then
      url=$(task_state_get "$id" pr_url)
      live=$(task_state_get "$id" status)
    fi
    if [ "$live" = abandoned ]; then
      # `task abandon` never touches the forge, so a task the person gave up
      # on keeps its pull request. The flag stands -- only the forge knows
      # whether it is still open -- but the ask does not: work nobody wants is
      # not work to merge. So this card keeps the borrowed fact and changes
      # what it asks for, which is the one thing the local answer is good for
      # here. `consolidated` is deliberately not treated this way: a closed
      # task with an open pull request is worth looking at, and merging it is
      # still the right move.
      #
      # Borrowed exactly as much as the card below it, and worded the same
      # way: past tense, and a refresh asked for first. Only what the task's
      # own state says -- that it was abandoned -- is present tense here. A
      # change about cards claiming more than they know may not add one.
      cards="$cards$(_status_card "A pull request was open for a task you abandoned" "$id" \
        "${hk_note:+open as of $hk_note}" \
        "It may have been closed or merged since: jig last asked the forge then. Run jig housekeeping to refresh, then close on the forge what is still open, or reopen the task. Nothing here will merge it." "$url")
"
    elif _status_in "$id" "$open"; then
      # Borrowed knowledge: housekeeping asks the forge once a cadence, so this
      # one may have been merged since. Past tense, and the first thing asked
      # for is a refresh -- the imperative below it is the one the reader acts
      # on, so it must not tell them to merge what may already be merged.
      cards="$cards$(_status_card "A pull request was open at the last housekeeping run" "$id" "open as of $hk_note" \
        "It may have been merged since: jig last asked the forge then. Run jig housekeeping to refresh, then review and merge what is still open." "$url")
"
    else
      cards="$cards$(_status_card "A pull request is waiting for review or merge" "$id" "opened by jig task ship" \
        "Review it and merge it; jig merges one itself only at agent.git: merge, on green CI." "$url")
"
    fi
  done <<EOF
$pr_ids
EOF

  # 5. Merged and ready to close (needs-consolidation, ADR-0030). 6. Work that
  # landed elsewhere, a pull request closed unmerged, a worktree left behind:
  # kept, and only a person can say what happens next.
  #
  # Through _status_flagged_ids, so a flag this disk already disproves -- a
  # task closed since the run, a worktree removed since it -- builds no card,
  # and the same four answers reach the counts.
  nc=$(_status_flagged_ids needs-consolidation)
  wrong=$(_status_flagged_ids wrong-base)
  closed=$(_status_flagged_ids 'abandoned?')
  kept=$(_status_flagged_ids worktree-kept)
  cards="$cards$(_status_cards "$nc" "Merged: the task can be closed" "$hk_note" \
    "Tell the agent to close this task (jig-consolidate).")"
  cards="$cards$(_status_cards "$wrong" "The work landed on a different branch than planned" "$hk_note" \
    "Check where its pull request was merged; the details are in .ai/runtime/housekeeping.log.")"
  cards="$cards$(_status_cards "$closed" "The pull request was closed without merging" "$hk_note" \
    "Reopen it, or tell the agent to abandon the task.")"
  cards="$cards$(_status_cards "$kept" "A worktree was kept because it still holds work" "$hk_note" \
    "Commit or discard what is left in the task's worktree; the next housekeeping removes it.")"

  # 7. Knowledge nobody has agreed to yet reaches no agent (ADR-0016).
  if [ -n "$_SC_PROPOSALS" ] && [ "$_SC_PROPOSALS" -gt 0 ]; then
    cards="$cards$(_status_card "Knowledge is waiting for your decision" "" "$_SC_PROPOSALS document(s) proposed" \
      "Ask the agent: what's proposed? (jig-accept)")
"
  fi
  if [ -n "$_SC_SOURCES" ] && [ "$_SC_SOURCES" -gt 0 ]; then
    cards="$cards$(_status_card "Adopted rule files changed since you approved them" "" "$_SC_SOURCES file(s)" \
      "Ask the agent to go through the changed sources with you (jig-accept).")
"
  fi

  printf '<section id="needs">\n<h2>Needs you</h2>\n'
  if [ -n "$cards" ]; then
    printf '<div class="cards">\n%s</div>\n' "$cards"
  else
    printf '<p class="nothing">Nothing needs you right now.</p>\n'
    if [ -n "$_STATUS_HK_AT" ] && _status_hk_stale "$_STATUS_HK_AT" "$_STATUS_HK_FORGE"; then
      printf '<p class="muted">Pull request data is stale, so a pull request waiting for you may be missing here.</p>\n'
    fi
  fi
  printf '</section>\n'
}

# _status_cards <ids> <title> <detail> <todo> — one card per id, each ending
# in a newline.
_status_cards() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _status_card "$2" "$id" "$3" "$4"
    printf '\n'
  done <<EOF
$1
EOF
}

# _status_phase_stop_cards <lines> — one "needs you" card per phase, from
# `<phase>\t<task-id>\t<stop reason>` lines. Several stopped tasks of one
# phase make one card with all of them listed: in a phase run the person is
# asked once, in the coordinator's session, about the whole wave — the page
# says the same thing rather than handing them a card each
# (adr-20260922-a-phase-run-is-coordinated).
_status_phase_stop_cards() {
  local lines="$1" phases="" phase id reason detail n
  [ -n "$lines" ] || return 0
  phases=$(printf '%s\n' "$lines" | cut -f 1 | grep -v '^$' | sort -u)
  while IFS= read -r phase; do
    [ -n "$phase" ] || continue
    detail="" n=0
    while IFS="$(printf '\t')" read -r _ id reason; do
      [ -n "$id" ] || continue
      n=$((n + 1))
      detail="$detail${detail:+; }$id — $reason"
    done < <(printf '%s\n' "$lines" | awk -F '\t' -v p="$phase" '$1 == p')
    if [ "$n" -gt 1 ]; then
      _status_card "A phase run is waiting for you" "phase $phase" "$detail" \
        "Answer in the coordinator's session; it resumes the tasks." "" \
        '<span class="badge warn">autopilot stopped</span>'
    else
      _status_card "A phase run is waiting for you" "phase $phase" "$detail" \
        "Answer in the coordinator's session; it resumes the task." "" \
        '<span class="badge warn">autopilot stopped</span>'
    fi
    printf '\n'
  done < <(printf '%s\n' "$phases")
}

# _status_html_phase_run — "Phase run": the roadmap phases a coordinator is
# running here, one block each. A phase is running when some live task's
# `autopilot_phase` names it and its run has not ended, so a phase whose
# tasks all merged and closed leaves the page on its own.
#
# Everything about the phase itself is `jig spec plan`'s answer, never
# recomputed here (ARCHITECTURE.md, Scripts layout: a reporting command
# consumes a peer's answer). `spec plan` refuses outright when the spec has
# no roadmap here or its epic is missing; the page then says so for that
# phase instead of dying with it.
_status_html_phase_run() {
  local rec phase phases=""
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _status_rec "$rec"
    case "$_ST_AUTOPILOT" in
      on | stopped) ;;
      *) continue ;;
    esac
    phase=$(_status_phase_of "$_ST_APFACTS")
    [ -n "$phase" ] || continue
    _status_in "$phase" "$phases" || phases="$phases$phase
"
  done <<EOF
$_STATUS_LIVE
EOF
  [ -n "$phases" ] || return 0
  printf '<section id="phase-run">\n<h2>Phase run</h2>\n'
  while IFS= read -r phase; do
    [ -n "$phase" ] || continue
    _status_html_one_phase "$phase"
  done < <(printf '%s\n' "$phases" | sort -u)
  printf '</section>\n'
}

# _status_phase_of <autopilot facts line> — the run's phase, or nothing when
# it is not part of one.
_status_phase_of() {
  local phase
  phase=$(printf '%s\n' "$1" | cut -f 7)
  [ "$phase" != "-" ] || phase=""
  printf '%s\n' "$phase"
}

# _status_html_one_phase <spec-id>/<n> — one running phase: its waves and free
# slots, the tasks of it that are in flight here, and what an earlier wave
# still holds. The waves, the slots and the blockers are `spec plan`'s answer;
# the tasks are the page's own live records, which already carry the pull
# request and the receipt `spec plan` knows nothing about.
_status_html_one_phase() {
  local phase="$1" sid="${1%/*}" num="${1##*/}" rows="" kind a b c
  local waves="" slots="" blockers="" problems=""
  printf '<h3><code>%s</code> · phase %s</h3>\n' "$(_status_h "$sid")" "$(_status_h "$num")"
  rows=$(spec_plan "$sid" --phase "$num" --format tsv 2>/dev/null) || rows=""
  if [ -z "$rows" ]; then
    printf '<p class="empty">No plan for this phase here; <code>jig spec plan %s --phase %s</code> says why.</p>\n' \
      "$(_status_h "$sid")" "$(_status_h "$num")"
  else
    while IFS="$(printf '\t')" read -r kind a b c; do
      case "$kind" in
        parallel) slots=$(_status_phase_slots "$a" "$b") ;;
        wave) waves="$waves${waves:+, }wave $a $b" ;;
        blocker) blockers="$blockers${blockers:+, }$b" ;;
        problem) problems="$problems<li>$(_status_h "wave $a: \"$c\" is $b")</li>" ;;
      esac
    done < <(printf '%s\n' "$rows")
    printf '<p class="muted">%s%s</p>\n' "$(_status_h "${waves:-no waves}")" \
      "${slots:+ · $(_status_h "$slots")}"
  fi
  _status_html_phase_tasks "$phase"
  [ -z "$blockers" ] || printf '<p class="muted">The next wave waits on: %s.</p>\n' "$(_status_h "$blockers")"
  [ -z "$problems" ] || printf '<p>The waves list has a problem:</p>\n<ul>%s</ul>\n' "$problems"
}

# _status_html_phase_tasks <phase> — the live tasks of one phase, each with
# where its agent is, its pull request and its receipt. A task whose knowledge
# decision is recorded is waiting to ship: that is the coordinator's queue,
# and it is marked so the person can see how much of the wave is already done.
_status_html_phase_tasks() {
  local want="$1" rec body=""
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _status_rec "$rec"
    [ "$(_status_phase_of "$_ST_APFACTS")" = "$want" ] || continue
    body="$body<tr><td class=\"id\"><code>$(_status_h "$_ST_ID")</code></td>"
    if [ "$_ST_KC" = true ]; then
      body="$body<td>waiting to ship</td>"
    else
      body="$body<td>$(_status_h "${_ST_AUTOPILOT:-building}")</td>"
    fi
    case "$_ST_PR_URL" in
      https://*) body="$body<td><a href=\"$(_status_h "$_ST_PR_URL")\">$(_status_h "$_ST_PR_URL")</a></td>" ;;
      *) body="$body<td class=\"muted\">-</td>" ;;
    esac
    body="$body<td>$(_status_h "${_ST_RECEIPT#receipt: }")</td></tr>
"
  done <<EOF
$_STATUS_LIVE
EOF
  [ -n "$body" ] || return 0
  printf '<div class="scroll"><table>\n'
  printf '<thead><tr><th>Task</th><th>Run</th><th>Pull request</th><th>Receipt</th></tr></thead>\n<tbody>\n'
  printf '%s' "$body"
  printf '</tbody>\n</table></div>\n'
}

# _status_phase_slots <limit> <building> — "N of M slots free", the phrase
# `jig spec plan` prints, with the same floor at zero.
_status_phase_slots() {
  local limit="$1" building="$2" free
  case "$limit$building" in
    '' | *[!0-9]*) return 0 ;;
  esac
  free=$((limit - building))
  [ "$free" -ge 0 ] || free=0
  printf '%s of %s slots free' "$free" "$limit"
}

# _status_html_tasks — "Running now": one row per live task except a stopped
# autopilot run, which is a card above. Autopilot runs first, then the other
# started tasks, then ready ones, then tasks filed but not started; paused
# tasks fold away below. The receipt is what `task receipt --check` answers
# (task_receipt_check) and the blocking findings are _task_blocking_findings'
# own lines.
_status_html_tasks() {
  local rec rows="" paused_rows="" rank row tab
  tab=$(printf '\t')
  printf '<section id="tasks">\n<h2>Running now</h2>\n'
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _status_rec "$rec"
    [ "$_ST_AUTOPILOT" != stopped ] || continue
    row=$(_status_html_task_row)
    if [ "$_ST_PAUSED" = true ]; then
      paused_rows="$paused_rows$row
"
      continue
    fi
    if [ "$_ST_AUTOPILOT" = on ]; then rank=1
    elif [ -z "$_ST_BRANCH" ]; then rank=4
    elif [ "$_ST_STATUS" = ready ]; then rank=3
    else rank=2
    fi
    rows="$rows$rank$tab$row
"
  done <<EOF
$_STATUS_LIVE
EOF
  if [ -n "$rows" ]; then
    _status_html_task_table "$(printf '%s' "$rows" | sort -s -t "$tab" -k 1,1 | cut -f 2-)
"
  else
    printf '<p class="empty">Nothing is running.</p>\n'
  fi
  if [ -n "$paused_rows" ]; then
    printf '<details id="paused"><summary>Paused</summary>\n'
    _status_html_task_table "$paused_rows"
    printf '</details>\n'
  fi
  if [ "$_STATUS_FINISHED" -gt 0 ]; then
    printf '<p class="muted">%d finished, not listed (<code>jig task list --all</code>).</p>\n' "$_STATUS_FINISHED"
  fi
  printf '</section>\n'
}

_status_html_task_table() {
  printf '<div class="scroll"><table>\n'
  printf '<thead><tr><th>Task</th><th>Class</th><th>Status</th><th>Stage</th><th>Base</th><th>Worktree</th><th>Review receipt</th><th>Blocking findings</th></tr></thead>\n<tbody>\n'
  printf '%s' "$1"
  printf '</tbody>\n</table></div>\n'
}

# _status_html_task_row — the row of the task _status_rec last read, on one
# line.
_status_html_task_row() {
  local blocking bline receipt cls
  printf '<tr><td class="id"><code>%s</code></td><td>%s</td><td>%s' \
    "$(_status_h "$_ST_ID")" "$(_status_h "${_ST_CLASS:--}")" "$(_status_h "$_ST_STATUS")"
  if [ "$_ST_PAUSED" = "true" ]; then
    printf ' <span class="badge warn">paused</span>'
    [ -z "$_ST_REASON" ] || printf ' <span class="muted">%s</span>' "$(_status_h "$_ST_REASON")"
  fi
  printf '</td><td>'
  _status_html_stage
  # The Task Base, and only where there is one: it is recorded by `jig task
  # start` (_task_start_base), and a task that has not started has none. The
  # project default is not a safe stand-in — a task linked to a spec with an
  # open epic is cut from the epic, so the default would be shown as fact and
  # be wrong. The text page and `jig task list` already print the base only
  # when it is there; an empty cell reads like the Worktree column's.
  if [ -n "$_ST_BASE" ]; then
    printf '</td><td>%s</td>' "$(_status_h "$_ST_BASE")"
  else
    printf '</td><td class="muted">-</td>'
  fi
  if [ -n "$_ST_WT" ]; then
    printf '<td class="path"><code>%s</code><br><span class="muted">%s uncommitted</span></td>' \
      "$(_status_h "$_ST_WT")" "$(_status_h "${_ST_WT_NOTE##* uncommitted=}")"
  else
    printf '<td class="muted">-</td>'
  fi
  receipt=${_ST_RECEIPT#receipt: }
  case "$receipt" in
    current) cls="ok" ;;
    stale* | *required*) cls="bad" ;;
    *) cls="" ;;
  esac
  printf '<td><span class="badge%s">%s</span></td>' "${cls:+ $cls}" "$(_status_h "$receipt")"
  blocking=$(_task_blocking_findings "$_ST_ID")
  if [ -z "$blocking" ]; then
    printf '<td class="muted">none</td></tr>'
  else
    printf '<td><ul class="findings">'
    while IFS= read -r bline; do
      [ -n "$bline" ] || continue
      printf '<li><code>%s</code></li>' "$(_status_h "$bline")"
    done < <(printf '%s\n' "$blocking")
    printf '</ul><span class="muted">details: <code>jig task findings %s</code></span></td></tr>' \
      "$(_status_h "$_ST_ID")"
  fi
}

# _status_html_stage — where the task _status_rec last read is on its route.
# Only an autopilot run records its stage (its journal, _task_autopilot_facts);
# for any other task the files in its workspace are facts about files, not a
# stage (ADR-0020), so none is claimed — except the gate a T3/T4 design waits
# at (_task_gate_state).
_status_html_stage() {
  local repairs stage stage_at ago
  if [ "$_ST_AUTOPILOT" = on ]; then
    repairs=$(printf '%s\n' "$_ST_APFACTS" | cut -f 2)
    stage=$(printf '%s\n' "$_ST_APFACTS" | cut -f 3)
    stage_at=$(printf '%s\n' "$_ST_APFACTS" | cut -f 4)
    if [ -z "$stage" ] || [ "$stage" = "-" ]; then
      stage="starting"
    fi
    printf '<span class="badge">autopilot</span> %s' "$(_status_h "$stage")"
    ago=""
    [ -z "$stage_at" ] || [ "$stage_at" = "-" ] || ago=$(_status_ago "$stage_at")
    case "$ago" in
      '') ;;
      "just now") printf ' <span class="muted">just started</span>' ;;
      *) printf ' <span class="muted">for %s</span>' "$(_status_h "$ago")" ;;
    esac
    printf ' <span class="muted">repairs %s/2</span>' "$(_status_h "${repairs:-0}")"
    return 0
  fi
  if [ -z "$_ST_BRANCH" ]; then
    printf '<span class="muted">filed, not started</span>'
    return 0
  fi
  case "$_ST_GATE" in
    waiting) printf '<span class="badge warn">design at the gate</span>' ;;
    changed) printf '<span class="badge warn">design changed after approval</span>' ;;
    approved) printf '<span class="badge ok">design approved</span>' ;;
    *) printf '<span class="muted">not tracked outside autopilot</span>' ;;
  esac
}

# _status_html_specs — `spec list`'s rows (spec_list_rows), each spec's
# progress by phase (spec_phase_rows) and the open epics `jig status` names
# (spec_epic_status).
_status_html_specs() {
  local rows phases id title state epics eline
  printf '<section id="specs">\n<h2>Specifications</h2>\n'
  rows=$(spec_list_rows)
  if [ -z "$rows" ]; then
    printf '<p class="empty">No specifications.</p>\n</section>\n'
    return 0
  fi
  printf '<div class="scroll"><table>\n'
  printf '<thead><tr><th>Spec</th><th>Title</th><th>Progress</th></tr></thead>\n<tbody>\n'
  while IFS="$(printf '\t')" read -r id title state; do
    [ -n "$id" ] || continue
    printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' \
      "$(_status_h "$id")" "$(_status_h "$title")" "$(_status_h "$state")"
  done < <(printf '%s\n' "$rows")
  printf '</tbody>\n</table></div>\n'

  phases=$(spec_phase_rows)
  while IFS="$(printf '\t')" read -r id title state; do
    [ -n "$id" ] || continue
    _status_html_phases "$id" "$title" "$phases"
  done < <(printf '%s\n' "$rows")

  epics=$(spec_epic_status)
  if [ -n "$epics" ]; then
    printf '<ul>\n'
    while IFS= read -r eline; do
      [ -n "$eline" ] || continue
      printf '<li>%s</li>\n' "$(_status_h "$eline")"
    done < <(printf '%s\n' "$epics")
    printf '</ul>\n'
  fi
  printf '</section>\n'
}

# _status_html_phases <spec-id> <title> <spec_phase_rows> — one spec's phases.
_status_html_phases() {
  local want="$1" title="$2" id phase ptitle ndone total filed fog source shown_source="" pct
  local body=""
  while IFS="$(printf '\t')" read -r id phase ptitle ndone total filed fog source; do
    [ "$id" = "$want" ] || continue
    [ -z "$source" ] || shown_source="$source"
    pct=0
    [ "$total" -eq 0 ] || pct=$((ndone * 100 / total))
    [ "$phase" != "-" ] || phase=""
    [ "$ptitle" != "-" ] || ptitle=""
    body="$body$(printf '<tr><td>%s</td><td>%s</td><td><span class="bar"><span style="width: %d%%"></span></span>%s/%s done</td><td>%s</td><td>%s</td></tr>' \
      "$(_status_h "$phase")" "$(_status_h "$ptitle")" "$pct" "$(_status_h "$ndone")" "$(_status_h "$total")" \
      "$(_status_h "$filed")" "$(_status_h "$fog")")
"
  done < <(printf '%s\n' "$3")
  [ -n "$body" ] || return 0
  printf '<h3><code>%s</code> %s</h3>\n' "$(_status_h "$want")" "$(_status_h "$title")"
  [ -z "$shown_source" ] || printf '<p class="muted">From %s.</p>\n' "$(_status_h "$shown_source")"
  printf '<div class="scroll"><table>\n'
  printf '<thead><tr><th>Phase</th><th>Title</th><th>Progress</th><th>Filed</th><th>Fog</th></tr></thead>\n<tbody>\n'
  printf '%s' "$body"
  printf '</tbody>\n</table></div>\n'
}

# _status_html_summary — the counts the text report prints as single lines.
_status_html_summary() {
  printf '<section id="summary">\n<h2>At a glance</h2>\n<dl class="summary">\n'
  _status_html_item "Current task" "$_STATUS_CURRENT" 0
  _status_html_count "Knowledge awaiting decision" "$_SC_PROPOSALS"
  _status_html_count "Linked sources changed" "$_SC_SOURCES"
  _status_html_count "Needs consolidation" "$(_status_hk_count needs-consolidation)"
  _status_html_count "Worktrees kept" "$(_status_hk_count worktree-kept)"
  _status_html_count "Landed on the wrong base" "$(_status_hk_count wrong-base)"
  _status_html_item "Housekeeping last ran" "$(_status_housekeeping_age)" 0
  local agent_git
  agent_git=$(_status_agent_git)
  _status_html_item "agent.git" "${agent_git#agent.git: }" 0
  printf '</dl>\n</section>\n'
}

# _status_framework_versions <project-version> — compares the project's
# installed framework version (from .ai/manifest) against the framework
# version of whatever `jig` the current PATH selects, and prints exactly one
# line, plus a directional hint on mismatch (design.md §3-4).
#
# Read-only and offline, and it runs nothing: the global version is the one
# its checkout declares in scripts/lib/version.sh (jig_declared_version), not
# the output of executing it, so a broken or hanging global checkout cannot
# hang `status` (design.md §3, decided 2026-09-14).
#
# "Unavailable" is never printed with a hint, since there is nothing to act
# on. It covers both a PATH with no framework `jig` and a checkout whose
# version file cannot be read; a CI runner or a colleague who only cloned the
# project has no global install, and a hint there would repeat on every run.
# In link mode the global executable can be the very checkout this dispatcher
# runs from — a normal "current", not a missing global (common.sh,
# jig_global_executable).
_status_framework_versions() {
  local project="$1" global_exe global
  if ! global_exe=$(jig_global_executable) \
     || ! global=$(jig_declared_version "${global_exe%/scripts/jig}"); then
    printf '%s\n' "framework versions: project=$project global=unavailable"
    return 0
  fi
  if [ "$project" = "$global" ]; then
    printf '%s\n' "framework versions: project=$project global=$global current"
    return 0
  fi
  printf '%s\n' "framework versions: project=$project global=$global mismatch"
  if jig_release_version "v$global" >/dev/null 2>&1 && jig_release_version "v$project" >/dev/null 2>&1; then
    if jig_version_newer "$global" "$project"; then
      printf '%s\n' "hint: the global framework is newer; run \`jig upgrade --dry-run\`"
      return 0
    fi
    if jig_version_newer "$project" "$global"; then
      printf '%s\n' "hint: the project is newer than the global framework; run \`jig self-update\`"
      return 0
    fi
  fi
  # Not both orderable as release versions (e.g. a "dev" branch checkout), or
  # some other non-directional disagreement: no basis to name a direction.
  printf '%s\n' "hint: run \`jig self-update\`, then \`jig upgrade --dry-run\`"
}

# _status_flagged_ids <flag> — the tasks <flag> still stands for: the ones the
# last housekeeping run flagged with it, minus the ones a fact read from this
# disk already contradicts. The one place that answer is decided; the page's
# cards and the counts in both reports call it, so they cannot disagree.
#
# The cut is the cost of asking again, not the kind of card. What a task's own
# state file says, and whether a worktree is still on disk, are read here for
# nothing, and the page is redrawn after every command -- so a card those
# facts contradict is not built at all. What the forge saw (merged, closed,
# open, work that landed on another branch) costs a network request, which
# this page never makes on the write path
# (adr-20260924-the-status-page-keeps-the-readers-place): those stay borrowed
# and keep saying "as of" the run that saw them.
_status_flagged_ids() {
  local flag="$1" re
  case "$flag" in
    # The one flag whose name is not a literal regex.
    'abandoned?') re='flags=[^ ]*abandoned[?]' ;;
    *) re="flags=[^ ]*$flag" ;;
  esac
  _status_hk_recheck "$flag" "$(_status_hk_ids "$re")"
}

# _status_hk_recheck <flag> <ids> — <ids> without those the live answer
# contradicts.
#
# A recheck may only contradict, never invent. A task with no state file, and
# a kept worktree the log recorded no path for, keep their card: absence of an
# answer is not an answer, and a page that hid cards because it failed to look
# would be worse than one a run behind.
_status_hk_recheck() {
  local flag="$1" id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # The log is a file, and a line edited by hand can carry an id no command
    # would accept. Asking a peer about one dies in `task_dir` -- inside a
    # report, which may not fail on a peer's data, and by way of `jig_die`,
    # which redraws the very page being drawn. So it is not asked: an id
    # there is no way to check keeps its card, like every other answer the
    # page does not have.
    jig_valid_id "$id" || { printf '%s\n' "$id"; continue; }
    case "$flag" in
      needs-consolidation)
        # "Merged" is borrowed and stays so; "nobody has closed it yet" is
        # free to ask again, and closing the task is exactly what the card
        # asks for (ADR-0030).
        case "$(task_state_get "$id" status)" in
          consolidated | abandoned) continue ;;
        esac
        ;;
      'abandoned?')
        # housekeeping_decide drops this flag for a task already abandoned
        # (abandoned:closed). The page says the same thing a run earlier,
        # instead of asking a question that has been answered.
        [ "$(task_state_get "$id" status)" != abandoned ] || continue
        ;;
      worktree-kept)
        _status_worktree_kept "$id" || continue
        ;;
      # wrong-base and anything new: only the forge and the history know, so
      # the flag stands until the next run.
    esac
    printf '%s\n' "$id"
  done <<EOF
$2
EOF
}

# _status_worktree_kept <id> — false when the worktree housekeeping kept for
# <id> is gone from disk.
#
# The path comes from housekeeping's own `worktree=<path> action=keep` line,
# not from the task's branch. The flag has two shapes -- a worktree of its own
# and this checkout with the branch in it (_hk_checkout_keep) -- and a branch
# lookup sees neither the second nor a worktree the page is being drawn
# inside, since _task_worktrees leaves out the current checkout.
_status_worktree_kept() {
  local path
  path=$(_status_hk_worktree "$1")
  # Nothing recorded (an older log, or the checkout shape before it was
  # logged): no contradiction, so the card stands.
  [ -n "$path" ] || return 0
  [ -d "$path" ]
}

# _status_hk_worktree <id> — the path of the worktree the last housekeeping run
# kept for <id>, from its `action=keep` line; nothing when there is none.
#
# The task id is matched on the whole `task=` field, never as a substring:
# `task=wk` must not answer for `task=wk2`. The path is cut between
# ` worktree=` and the ` action=keep` that follows it rather than read as a
# field, because the log writes it unquoted and a worktree path may hold
# spaces; read field-wise it would come back truncated, and a truncated path
# is not a directory, which would drop exactly the card this function is
# meant to keep.
_status_hk_worktree() {
  local hk_log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  [ -f "$hk_log" ] || return 0
  JIG_HK_ID="$1" awk '
    /^--- run / { p = ""; next }
    {
      id = ""
      for (i = 1; i <= NF; i++) if ($i ~ /^task=/) id = substr($i, 6)
      if (id != ENVIRON["JIG_HK_ID"]) next
      a = index($0, " worktree=")
      b = index($0, " action=keep")
      if (a > 0 && b > a) p = substr($0, a + 10, b - a - 10)
    }
    END { if (p != "") print p }
  ' "$hk_log"
}

# What .ai/config.local.yaml changes, and why a value in it does nothing
# (ADR-0038). Silent when there is no local file anywhere. The answers come
# from config.sh, so this report and cfg cannot disagree about a key.
_status_config_local() {
  local file own key value kind
  file=$(jig_config_local_file)
  own="$JIG_PROJECT/$JIG_AI_DIR/config.local.yaml"
  if [ "$own" != "$file" ] && [ -f "$own" ]; then
    printf 'config.local: ignored %s (a worktree reads %s)\n' "$own" "$file"
  fi
  if [ -f "$file" ]; then
    while IFS="$(printf '\t')" read -r key value kind; do
      if [ "$kind" = local ]; then
        printf 'config.local: %s=%s\n' "$key" "$value"
      else
        printf 'config.local: ignored %s (not a local key)\n' "$key"
      fi
    done < <(jig_config_local_entries)
    if ! jig_config_local_ignored; then
      printf 'config.local: %s is not ignored by git and can be committed (fix: jig init)\n' \
        "$JIG_AI_DIR/config.local.yaml"
    fi
  fi

  # A JIG_CFG_LOCAL_ONLY_KEYS key (config.sh) set in the *project's* committed
  # config.yaml is never read there: `cfg` answers only from the local file
  # and the default for it. A silent no-op is the worst outcome for a value
  # someone deliberately wrote, so it is named here even when there is no
  # local file at all.
  local pkey pvalue t
  t=$(printf '\t')
  # shellcheck disable=SC2034 # pvalue: read shape must match
  # jig_config_project_ignored's two columns; the message names the key only.
  while IFS="$t" read -r pkey pvalue; do
    [ -n "$pkey" ] || continue
    printf 'config.local: %s in %s is ignored (set it in %s)\n' \
      "$pkey" "$JIG_AI_DIR/config.yaml" "$JIG_AI_DIR/config.local.yaml"
  done < <(jig_config_project_ignored)
}

# _status_agent_git — one line naming the review queue `agent.git`'s level
# (config.sh) leaves for the human, always printed: the level is `none` by
# default, and "none" is exactly the state this line exists to make visible
# alongside every other level (design.md, .ai/specs/autopilot/).
_status_agent_git() {
  local level queue
  if level=$(jig_agent_git); then
    case "$level" in
      none) queue="uncommitted files" ;;
      commit) queue="unpushed commits" ;;
      push) queue="pushed branches without a pull request" ;;
      pr) queue="open pull requests" ;;
      merge) queue="pull requests left open: red or silent CI, a draft, branch protection" ;;
    esac
    printf 'agent.git: %s (review queue: %s)\n' "$level" "$queue"
  else
    printf 'agent.git: invalid value %s (expected none|commit|push|pr|merge)\n' "$level"
  fi
}

# Whether the housekeeping trigger is wired up for the installed runtimes.
#
# Each adapter answers for its own runtime (the hint is empty when the trigger
# is in place), so no vendor-specific path or file format appears here —
# ARCHITECTURE.md keeps that knowledge in adapters. Like the `pending` line
# above, the whole line is omitted rather than guessed when the source
# checkout that holds the adapters is gone: "could not check" and "checked and
# found nothing" are different states.
_status_session_hook() {
  local source a adir hint
  source=$(manifest_source 2>/dev/null) || return 0
  [ -n "$source" ] || return 0
  [ -d "$source/adapters" ] || return 0
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"

  local rc
  for a in $(cfg_list adapters "claude codex"); do
    adir=$(adapters_dir "$source/adapters" "$a") || continue
    [ -f "$adir/adapter.sh" ] || continue
    # shellcheck disable=SC1090
    . "$adir/adapter.sh"
    command -v "adapter_${a}_session_hook_hint" >/dev/null 2>&1 || continue
    rc=0
    hint=$("adapter_${a}_session_hook_hint" "$JIG_PROJECT") || rc=$?
    # 2 is the skip code: this runtime has no session hook, so there is
    # nothing for the reader to install and nothing worth a line here.
    [ "$rc" = 2 ] && continue
    if [ -n "$hint" ]; then
      printf 'session hook (%s): not installed\n' "$a"
    else
      printf 'session hook (%s): installed\n' "$a"
    fi
  done
}

# Whether the instruction file each installed runtime reads carries Jig's
# workflow. A project that had its own AGENTS.md or CLAUDE.md before `init`
# keeps it (ADR-0003), and then the agent never hears of `jig-task`; this line
# is how that stops being silent. The adapter answers (an empty hint means
# connected), for the same reason as the session hook line above, and the line
# is omitted when the source checkout holding the adapters is gone.
#
# Connected is not the whole answer, because a section nothing updates goes
# stale where nobody looks: the marked-section state is reported too, and it
# is the same for every runtime — the section lives in AGENTS.md whatever
# reads it (adr-20260924-jig-owns-a-marked-section-of-the-instructions).
_status_instructions() {
  local source a adir hint file recorded section
  source=$(manifest_source 2>/dev/null) || return 0
  [ -n "$source" ] || return 0
  [ -d "$source/adapters" ] || return 0
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"
  # shellcheck source=lib/section.sh
  . "$JIG_LIB/section.sh"

  recorded=$(manifest_instructions_section 2>/dev/null) || recorded=""
  section=$(jig_section_report_state "$JIG_PROJECT/AGENTS.md" "$recorded")

  for a in $(cfg_list adapters "claude codex"); do
    adir=$(adapters_dir "$source/adapters" "$a") || continue
    [ -f "$adir/adapter.sh" ] || continue
    # shellcheck disable=SC1090
    . "$adir/adapter.sh"
    command -v "adapter_${a}_instructions_hint" >/dev/null 2>&1 || continue
    hint=$("adapter_${a}_instructions_hint" "$JIG_PROJECT") || hint=""
    if [ -n "$hint" ]; then
      file=$("adapter_${a}_instructions_file")
      printf 'instructions (%s): no Jig section in %s (run the jig-init skill)\n' "$a" "$file"
    elif [ "$section" = unmarked ]; then
      printf 'instructions (%s): Jig section in AGENTS.md is not marked — upgrades cannot reach it (run the jig-init skill)\n' "$a"
    elif [ "$section" = modified ]; then
      printf 'instructions (%s): Jig section in AGENTS.md was changed here; upgrades keep your text\n' "$a"
    else
      printf 'instructions (%s): ok\n' "$a"
    fi
  done
}

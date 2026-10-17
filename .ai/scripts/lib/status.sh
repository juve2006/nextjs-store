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
  local mode=text arg
  # `--json` anywhere asks for what needs the reader as data, in the envelope
  # (lib/json.sh). It is looked for before anything else runs, so that every
  # refusal below it is an envelope too.
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _status_json "$@"
      return $?
    fi
  done
  while [ $# -gt 0 ]; do
    case "$1" in
      --html) [ "$mode" = open ] || mode=html; shift ;;
      --open) mode=open; shift ;;
      --refresh) mode=refresh; shift ;;
      *) jig_fail usage "status: unknown argument: $1 (usage: jig status [--html | --open | --json])" ;;
    esac
  done
  jig_require_repo
  if [ "$mode" != text ]; then
    _status_page "$mode"
    return 0
  fi
  _status_load
  # shellcheck source=lib/output.sh
  . "$JIG_LIB/output.sh"
  out_init
  # The form is decided here and nowhere below: the plain report
  # (_status_report) is what every other reader gets — the status page and
  # every redraw of it, a pipe, an agent — so none of them can be handed the
  # terminal form (adr-20261005-output-is-decorated-only-on-a-terminal).
  if out_terminal; then
    _status_terminal_report
  else
    _status_report
  fi
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
  if ! _status_counts_read; then
    _status_counts
    _status_counts_save || true
  fi
}

# _status_counts_read — the counts the last full run saved, without computing
# or writing anything; exit 1 when there are none. `jig status --json` reads
# them through this alone: a read writes nothing.
_status_counts_read() {
  local file="$JIG_PROJECT/$JIG_AI_DIR/runtime/status-counts" key value
  [ -f "$file" ] || return 1
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
#
# `jig status --json` reports these counts, so new ones raise the clone's
# revision (adr-20261016-the-clone-revision-is-a-claimed-name): otherwise a
# consumer that read the old counts at revision R would see R again after the
# refresh and never read them. Only when a count changed, not for `at:` alone,
# which every full redraw moves. jig_revision_bump, not jig_record_changed: this
# is the page's own redraw, which must not mark the page to redraw again.
_status_counts_save() {
  local dir="$JIG_PROJECT/$JIG_AI_DIR/runtime" file tmp before="" after
  file="$dir/status-counts"
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  mkdir -p "$dir" || return 1
  [ ! -f "$file" ] || before=$(sed '/^at: /d' "$file" 2>/dev/null) || before=""
  after=$(
    printf 'proposals: %s\n' "${_SC_PROPOSALS:-unknown}"
    printf 'sources_changed: %s\n' "${_SC_SOURCES:-unknown}"
    printf 'pending: %s\n' "${_SC_PENDING:-unknown}"
  )
  if ! { printf 'at: %s\n' "$_SC_AT"; printf '%s\n' "$after"; } > "$tmp"; then return 1; fi
  if ! mv "$tmp" "$file"; then return 1; fi
  [ "$before" = "$after" ] || jig_revision_bump
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
  # After task.sh: its rechecks ask task_state_get.
  # shellcheck source=lib/hklog.sh
  . "$JIG_LIB/hklog.sh"
  # shellcheck source=lib/notify.sh
  . "$JIG_LIB/notify.sh"
}

# _status_report — the plain-text report `jig status` prints. At a terminal
# the same lines are read back and regrouped by _status_terminal, which knows
# every line shape printed here: a new one is classified there too, or it is
# shown as a line of its own under what is fine.
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
  _status_autopilot_git
  _status_notify

  if manifest_exists; then
    local proj_version
    proj_version=$(manifest_header_get jig.version)
    printf '%s\n' "manifest: version=$proj_version mode=$(manifest_header_get jig.mode) source=$(manifest_source)"
    _status_framework_versions "$proj_version"
  else
    printf '%s\n' "manifest: missing"
  fi
  _status_new_release_hint

  # Drift: one pass over the manifest, then one git process for every file
  # still on disk (jig_hash_list). A manifest_hash_of and a jig_hash per path
  # cost 1.5 s on a 72-file install — the manifest reread for every path, and
  # a git startup for every hash. Both lists stay in manifest order.
  local modified="" missing="" mcount=0 xcount=0 line rel mhash lhash drift_tmp
  drift_tmp=$(mktemp -d "${TMPDIR:-/tmp}/jig-status-drift.XXXXXX")
  jig_cleanup_add -d "$drift_tmp"
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
    # Where `jig task list` shows it (adr-20261010-a-task-carries-its-tracker-issue).
    [ -z "$_ST_ISSUE" ] || line="$line issue=$_ST_ISSUE"
    # A lighter route than the class's own is worth a word; `full`, the
    # default, adds none (adr-20261002-route-depth-is-a-personal-choice).
    [ "$_ST_DEPTH" != lean ] || line="$line depth=lean"
    # A class lowered mid-route shows where the class does, so a lowering is
    # never quieter than the gate it may have skipped
    # (adr-20261004-a-route-stage-is-proven-by-its-record).
    [ -z "$_ST_LOWERED" ] || line="$line lowered=$_ST_LOWERED"
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
    # task.sh, asked `cheap`), read once per task in _status_live_collect: a receipt that
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
  _status_notify_hook
  _status_instructions
}

# --- the terminal form (adr-20261005-output-is-decorated-only-on-a-terminal) ----
#
# At a terminal `jig status` is read by section. A heading names the version,
# the project and the install and ends in the verdict; then what needs the
# reader — a refusal, a stale or blocked task, a hint, a flag housekeeping
# left — each with what to do; then a section each for the install, the
# settings, the tasks, the knowledge and the recent activity in this checkout,
# one row per item in aligned columns. It is the plain report read back line by
# line, so the plain form stays byte for byte what it was, and the two forms
# cannot say different things. Two facts the plain report does not carry are
# asked in the same process: the project's name, for the heading, and who
# holds HEAD here (jig_checkout_occupants, the rule every refusal uses).

# What one terminal report tells the reader, filled by _status_terminal.
_STT_NEED_LEVEL=()   # fail | warn, one per item that needs the reader
_STT_NEED_TEXT=()    # its status line
_STT_NEED_DETAIL=()  # its detail lines, "label<TAB>text", newline-joined
_STT_TASKS=()        # task lines that need nothing, without "task "
_STT_OTHERS=()       # work recorded here: "label<TAB>command<TAB>age"
_STT_INSTALL=()      # install rows: "key<TAB>text"
_STT_KNOW=()         # knowledge rows: "key<TAB>text<TAB>hint"
_STT_CFG=()          # config.local keys in effect, "key=value"
_STT_REST=()         # any line no rule here knows
_STT_HOOKS=()        # session hooks installed, "session hook (claude)"
_STT_INSTR=()        # runtimes whose instructions are fine
_STT_INSTR_OWN=()    # runtimes whose Jig section was changed here
_STT_AGENT=""        # the agent.git line's value, when it is valid
_STT_AUTOPILOT=""    # the autopilot.git line's value, when it is valid
_STT_CURRENT=""      # the current task, when it is not ambiguous
_STT_UNSEEN=""       # 1 when the runtime does not name its sessions
_STT_MODE=""         # the install's mode (copy, link)
_STT_CURRENT_FW=""   # 1 when the project's framework is the global one
_STT_INIT=""         # 1 when the project is initialised
_STT_NAME=""         # the project's name, for the heading
_STT_HEAD=""         # who holds HEAD here: "<name> <seconds> <command>"

# _status_terminal_report — the plain report into a file, in this shell (its
# answers are memoised into globals cmd_status still reads), then its
# terminal form.
_status_terminal_report() {
  local tmp root
  tmp=$(mktemp "${TMPDIR:-/tmp}/jig-status-report.XXXXXX")
  jig_cleanup_add "$tmp"
  _status_report > "$tmp"
  root=$(jig_config_clone_root)
  _STT_NAME=${root##*/}
  _STT_HEAD=$(jig_checkout_occupants)
  _STT_HEAD=${_STT_HEAD%%$'\n'*}
  _status_terminal < "$tmp"
  rm -f "$tmp"
}

# _status_need <level> <text> — one item that needs the reader.
_status_need() {
  _STT_NEED_LEVEL+=("$1")
  _STT_NEED_TEXT+=("$2")
  _STT_NEED_DETAIL+=("")
}

# _status_task_needs <task line> — exit 0 when a `task ...` line asks for the
# reader: paused, blocking findings, a stale review, a stopped run, a lowered
# class (adr-20261004-a-route-stage-is-proven-by-its-record). Only the fields
# the line builder writes are looked at, never the text a person wrote — a
# worktree path or a pause reason may hold any of those words.
_status_task_needs() {
  local t="$1" head last
  # The fixed words before the worktree, the base and the pause.
  head=${t%% worktree=*}
  head=${head%% base=*}
  head=${head%% paused*}
  case "$head" in *" lowered="*) return 0 ;; esac
  # The words after the pause reason, peeled off from the end.
  while :; do
    last=${t##* }
    case "$last" in
      blocking=*[!0-9]* | blocking=) break ;;
      blocking=* | review=stale | autopilot=stopped) return 0 ;;
      autopilot=on) ;;
      *) break ;;
    esac
    t=${t% *}
  done
  case "$t" in
    *" paused" | *" paused ("*")") return 0 ;;
  esac
  return 1
}

# _status_need_detail <label> <text> — a detail line under the last item.
_status_need_detail() {
  local i=$((${#_STT_NEED_TEXT[@]} - 1)) d
  d=${_STT_NEED_DETAIL[$i]}
  if [ -n "$d" ]; then d="$d"$'\n'; fi
  _STT_NEED_DETAIL[i]="$d$1"$'\t'"$2"
}

# _status_terminal — read the plain report on stdin and print its terminal
# form.
_status_terminal() {
  local l t v m version="" prev_need="" list="" finished="" ntasks=0 hk=""
  _STT_NEED_LEVEL=() _STT_NEED_TEXT=() _STT_NEED_DETAIL=() _STT_TASKS=() _STT_OTHERS=()
  _STT_INSTALL=() _STT_KNOW=() _STT_CFG=() _STT_REST=() _STT_HOOKS=() _STT_INSTR=()
  _STT_INSTR_OWN=()
  _STT_AGENT="" _STT_CURRENT="" _STT_UNSEEN="" _STT_MODE="" _STT_CURRENT_FW="" _STT_INIT=""
  while IFS= read -r l || [ -n "$l" ]; do
    # A line indented by two spaces belongs to the list named above it
    # (modified:, missing:), which belongs to the drift line before that.
    case "$l" in
      "  "*)
        if [ -n "$list" ]; then
          _status_need_detail "$list" "${l#  }"
          continue
        fi
        ;;
    esac
    list=""
    # A hint is a detail of the line it follows; the newer-release hint is
    # an item of its own, since nothing above it asked for it.
    case "$l" in
      "hint: jig v"*" is out; "*)
        t=${l#hint: }
        _status_need warn "${t%%; *}"
        _status_need_detail hint "${t#*; }"
        prev_need=""
        continue
        ;;
      "hint: "*)
        if [ -n "$prev_need" ]; then
          _status_need_detail hint "${l#hint: }"
        else
          _status_need warn "${l#hint: }"
        fi
        prev_need=""
        continue
        ;;
    esac
    prev_need=""
    case "$l" in
      "jig "*) [ -n "$version" ] || version=${l#jig } ;;
      "initialised: yes") _STT_INIT=1 ;;
      "initialised: "*) _status_need warn "$l"; prev_need=1 ;;
      "config.local: "*" is not ignored by git"*" (fix: "*")")
        t=${l##* (fix: }
        _status_need warn "${l% (fix: *}"
        _status_need_detail fix "${t%)}"
        ;;
      "config.local: ignored "* | "config.local: "*" is ignored (set it in "*)
        _status_need warn "$l"
        ;;
      "config.local: "*) _STT_CFG+=("${l#config.local: }") ;;
      "notify: "*) _status_need warn "$l" ;;
      "agent.git: invalid value "*) _status_need fail "$l" ;;
      "agent.git: "*) _STT_AGENT=${l#agent.git: } ;;
      "autopilot.git: invalid value "*) _status_need fail "$l" ;;
      "autopilot.git: "*) _STT_AUTOPILOT=${l#autopilot.git: } ;;
      "manifest: version="*)
        t=${l#manifest: version=}
        v=${t%% mode=*}
        m=${t#* mode=}
        _STT_MODE=${m%% source=*}
        ;;
      "manifest: "*) _status_need warn "$l" ;;
      "framework versions: "*" current")
        _STT_CURRENT_FW=1
        t=${l#*project=}
        _STT_INSTALL+=("framework"$'\t'"${t%% *} (project = global, current)")
        ;;
      "framework versions: "*"=unavailable")
        t=${l#*project=}
        _STT_INSTALL+=("framework"$'\t'"${t%% *} (global jig unavailable)")
        ;;
      "framework versions: "*) _status_need warn "$l"; prev_need=1 ;;
      "drift: 0 modified, 0 missing, 0 pending")
        _STT_INSTALL+=("drift"$'\t'"$(out_join "0 modified" "0 missing" "0 pending")")
        ;;
      # Pending is left off the plain line when it cannot be told, and "could
      # not check" is not "nothing pending".
      "drift: 0 modified, 0 missing")
        _STT_INSTALL+=("drift"$'\t'"$(out_join "0 modified" "0 missing" "pending unknown")")
        ;;
      "drift: "*) _status_need warn "$l" ;;
      "modified:" | "missing:") list=${l%:} ;;
      "proposals: none") _STT_KNOW+=("proposals"$'\t'"none"$'\t') ;;
      "proposals: "* | "sources changed: "*) _status_need warn "$l" ;;
      "specs: none") _STT_KNOW+=("specs"$'\t'"none"$'\t') ;;
      "specs: "*" (jig spec list)")
        t=${l#specs: }
        _STT_KNOW+=("specs"$'\t'"${t% (jig spec list)}"$'\t'"jig spec list")
        ;;
      "epic: "*", branch missing") _status_need warn "$l" ;;
      "epic: "*) _STT_KNOW+=("epic"$'\t'"${l#epic: }"$'\t') ;;
      "task "*)
        ntasks=$((ntasks + 1))
        if _status_task_needs "$l"; then
          _status_need warn "$l"
        else
          _STT_TASKS+=("${l#task }")
        fi
        ;;
      "no active tasks") ;;
      "("*" finished; jig task list --all)")
        t=${l#(}
        finished=${t%% *}
        ;;
      "current task: ambiguous"*) _status_need warn "$l" ;;
      "current task: "*) _STT_CURRENT=${l#current task: } ;;
      "working here: "*" (jig "*", "*" ago)")
        t=${l#working here: }
        v=${t%% (jig *}
        t=${t##* (jig }
        t=${t% ago)}
        _STT_OTHERS+=("$v"$'\t'"${t%, *}"$'\t'"${t##*, }")
        ;;
      # A runtime that does not name its sessions is a boundary, not
      # something to fix: every person in a terminal of their own has one.
      "sessions: not observable (no active runtime names its sessions here)")
        _STT_UNSEEN=1
        ;;
      "sessions: "*) _status_need warn "$l" ;;
      "housekeeping: 0 days ago") hk="ran today" ;;
      "housekeeping: never") hk="never ran" ;;
      "housekeeping: "*) hk="ran ${l#housekeeping: }" ;;
      "needs consolidation: "*" (see "*")" | "worktrees kept: "*" (see "*")" \
        | "wrong base: "*" (see "*")")
        t=${l##* (see }
        _status_need warn "${l% (see *}"
        _status_need_detail see "${t%)}"
        ;;
      "session hook ("*"): installed") _STT_HOOKS+=("${l%: installed}") ;;
      "session hook ("*) _status_need warn "$l" ;;
      "notify hook ("*"): connected") _STT_HOOKS+=("${l%: connected}") ;;
      "notify hook ("*) _status_need warn "$l" ;;
      "instructions ("*"): ok")
        t=${l#instructions (}
        _STT_INSTR+=("${t%%)*}")
        ;;
      # Text a person changed in their own section is theirs to keep, and an
      # upgrade keeps it: nothing to do, as doctor says too.
      "instructions ("*"): Jig section in AGENTS.md was changed here; upgrades keep your text")
        t=${l#instructions (}
        _STT_INSTR_OWN+=("${t%%)*}")
        ;;
      "instructions ("*) _status_need warn "$l" ;;
      "") ;;
      *) _STT_REST+=("$l") ;;
    esac
  done
  _status_terminal_hooks
  [ -z "$hk" ] || _STT_INSTALL+=("housekeeping"$'\t'"$hk")
  _status_terminal_print "$version" "$ntasks" "$finished"
}

# _status_terminal_hooks — the install's "hooks" row: the session hooks that
# are installed and the runtimes whose instructions carry Jig's section.
_status_terminal_hooks() {
  local -a parts=()
  local t
  if [ ${#_STT_HOOKS[@]} -gt 0 ]; then parts+=("${_STT_HOOKS[@]}"); fi
  if [ ${#_STT_INSTR[@]} -gt 0 ]; then
    t=$(printf '%s, ' "${_STT_INSTR[@]}")
    parts+=("instructions (${t%, })")
  fi
  if [ ${#_STT_INSTR_OWN[@]} -gt 0 ]; then
    t=$(printf '%s, ' "${_STT_INSTR_OWN[@]}")
    parts+=("instructions changed here (${t%, })")
  fi
  [ ${#parts[@]} -gt 0 ] || return 0
  _STT_INSTALL+=("hooks"$'\t'"$(out_join "${parts[@]}")")
}

# _status_terminal_print <version> <tasks> <finished> — print what
# _status_terminal gathered: the heading, then a section each. A section with
# nothing in it is left out; what needs the reader is said once, in its own
# section, and not again in the section it belongs to.
_status_terminal_print() {
  local version="$1" ntasks="$2" finished="$3" level i n t head verdict vlevel=ok
  n=${#_STT_NEED_TEXT[@]}

  head="jig $version"
  [ -z "$_STT_NAME" ] || head="$head$(out_join "" "$_STT_NAME")"
  if [ -z "$_STT_INIT" ]; then
    head="$head$(out_join "" "not initialised")"
  else
    [ -z "$_STT_MODE" ] || head="$head$(out_join "" "$_STT_MODE mode")"
    [ -z "$_STT_CURRENT_FW" ] || head="$head$(out_join "" "up to date")"
  fi
  if [ "$n" = 0 ]; then
    verdict="nothing needs you"
  else
    vlevel=warn
    for level in "${_STT_NEED_LEVEL[@]}"; do
      if [ "$level" = fail ]; then vlevel=fail; fi
    done
    if [ "$n" = 1 ]; then verdict="1 item needs you"; else verdict="$n items need you"; fi
  fi
  out_heading "$head" "$vlevel" "$verdict"

  if [ "$n" -gt 0 ]; then
    out_section "Needs you" "$n"
    for level in fail warn; do
      i=0
      while [ "$i" -lt "$n" ]; do
        if [ "${_STT_NEED_LEVEL[$i]}" = "$level" ]; then
          printf '  '
          out_status "$level" "${_STT_NEED_TEXT[$i]}"
          while IFS= read -r t; do
            [ -n "$t" ] || continue
            printf '  '
            out_detail "${t%%$'\t'*}" "${t#*$'\t'}"
          done <<< "${_STT_NEED_DETAIL[$i]}"
        fi
        i=$((i + 1))
      done
    done
  fi
  # An uninitialised project's report stops before everything else.
  [ -n "$_STT_INIT" ] || return 0

  if [ ${#_STT_INSTALL[@]} -gt 0 ]; then
    out_section "Install"
    for t in "${_STT_INSTALL[@]}"; do
      out_row ok 6 ok plain 14 "${t%%$'\t'*}" plain 0 "${t#*$'\t'}"
    done
  fi
  _status_terminal_settings
  _status_terminal_tasks "$ntasks" "$finished"
  if [ ${#_STT_KNOW[@]} -gt 0 ]; then
    out_section "Knowledge & specs"
    local key rest
    for t in "${_STT_KNOW[@]}"; do
      key=${t%%$'\t'*}
      rest=${t#*$'\t'}
      out_row plain 12 "$key" plain 40 "${rest%%$'\t'*}" dim 0 "${rest#*$'\t'}"
    done
  fi
  _status_terminal_activity
  if [ ${#_STT_REST[@]} -gt 0 ]; then
    out_section "Other"
    for t in "${_STT_REST[@]}"; do out_row plain 0 "$t"; done
  fi
}

# _status_terminal_settings — agent.git and the config.local keys in effect.
# Keys that share their first segment (housekeeping.*, claude.*) are one row;
# agent.git is the agent.git line, with the queue it leaves for the reader.
_status_terminal_settings() {
  local -a keys=() vals=() labels=() texts=()
  local t k p i j n w=12 done_p=""
  [ -n "$_STT_AGENT" ] || [ ${#_STT_CFG[@]} -gt 0 ] || return 0
  if [ -n "$_STT_AGENT" ]; then
    t=${_STT_AGENT#* (}
    labels+=("agent.git")
    texts+=("$(out_join "${_STT_AGENT%% (*}" "${t%)}")")
  fi
  if [ -n "$_STT_AUTOPILOT" ]; then
    t=${_STT_AUTOPILOT#* (}
    labels+=("autopilot.git")
    texts+=("$(out_join "${_STT_AUTOPILOT%% (*}" "${t%)}")")
  fi
  if [ ${#_STT_CFG[@]} -gt 0 ]; then
    for t in "${_STT_CFG[@]}"; do
      [ "${t%%=*}" != agent.git ] || continue
      [ "${t%%=*}" != autopilot.git ] || continue
      keys+=("${t%%=*}")
      vals+=("${t#*=}")
    done
  fi
  i=0
  while [ "$i" -lt ${#keys[@]} ]; do
    k=${keys[$i]}
    p=${k%%.*}
    case " $done_p " in *" $p "*) i=$((i + 1)); continue ;; esac
    j=0 n=0
    while [ "$j" -lt ${#keys[@]} ]; do
      if [ "${keys[$j]%%.*}" = "$p" ] && [ "${keys[$j]}" != "$p" ]; then n=$((n + 1)); fi
      j=$((j + 1))
    done
    if [ "$n" -ge 2 ]; then
      done_p="$done_p $p"
      local -a sub=()
      j=0
      while [ "$j" -lt ${#keys[@]} ]; do
        if [ "${keys[$j]%%.*}" = "$p" ] && [ "${keys[$j]}" != "$p" ]; then
          sub+=("${keys[$j]#*.} ${vals[$j]}")
        fi
        j=$((j + 1))
      done
      labels+=("$p")
      t=$(printf '%s\037' "${sub[@]}")
      texts+=("${t%$'\037'}")
    else
      labels+=("$k")
      texts+=("${vals[$i]}")
    fi
    i=$((i + 1))
  done
  # Nothing left when the one key is an agent.git the report refused: that
  # is under "Needs you", and an empty section says nothing.
  [ ${#labels[@]} -gt 0 ] || return 0
  for k in "${labels[@]}"; do
    [ $((${#k} + 3)) -le "$w" ] || w=$((${#k} + 3))
  done
  if [ ${#_STT_CFG[@]} -gt 0 ]; then out_section "Settings" "config.local"; else out_section "Settings"; fi
  # A row of several keys that would run past the section's width goes on
  # under itself, whole items to a line.
  local room=$((OUT_WIDTH - 2 - w)) label line item
  local -a items=()
  i=0
  while [ "$i" -lt ${#labels[@]} ]; do
    label=${labels[$i]} line="" items=()
    IFS=$'\037' read -r -a items <<< "${texts[$i]}"
    for item in "${items[@]}"; do
      if [ -n "$line" ] && [ $((${#line} + ${#OUT_SEP} + ${#item})) -gt "$room" ]; then
        out_row plain "$w" "$label" plain 0 "$line"
        label="" line=""
      fi
      if [ -n "$line" ]; then line="$line$OUT_SEP$item"; else line=$item; fi
    done
    out_row plain "$w" "$label" plain 0 "$line"
    i=$((i + 1))
  done
}

# --- tasks grouped by the spec they belong to ------------------------------------
#
# A task belongs to the spec its task.md links to (jig_spec_link, the reading
# `task start` and every spec command use). A spec whose roadmap declares an
# epic (jig_spec_epic) is that epic's group; any other spec is a group of its
# own; a task that links to no spec here, or to two, is under "Other tasks".
# Epics come first, then specs, each in `spec list`'s order. The grouping is
# drawn by the terminal form and the page only: the plain report a pipe reads
# keeps its `task ...` lines as they were.

_STG_IDS=()      # the task ids asked about
_STG_SIDS=()     # the spec each belongs to, empty for none
_STG_KEYS=()     # the groups that have tasks, in order: spec ids
_STG_TITLE=()    # each group's title: the spec's first heading, or its id
_STG_KIND=()     # epic | spec
_STG_DONE=()     # roadmap items done, empty when the roadmap was not read
_STG_TOTAL=()    # roadmap items in all, empty likewise
_STG_SID=""      # _status_group_of's answer

# _status_task_groups <id>... — fill the _STG_* globals for these task ids.
# _STG_KEYS stays empty when none of them belongs to a spec. Progress is
# spec_phase_rows summed — the counts `jig spec list` and the page's phases
# show, read from the epic's branch when progress is made there (ADR-0040).
_status_task_groups() {
  local id sid root ws file used=" " sums s d t kind title pass
  _STG_IDS=() _STG_SIDS=() _STG_KEYS=() _STG_TITLE=() _STG_KIND=() _STG_DONE=() _STG_TOTAL=()
  root=$(spec_dir)
  ws="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  for id in "$@"; do
    sid=""
    file="$ws/$id/task.md"
    if [ -f "$file" ]; then sid=$(jig_spec_link "$file" 2>/dev/null) || sid=""; fi
    if [ -n "$sid" ] && [ ! -d "$root/$sid" ]; then sid=""; fi
    _STG_IDS+=("$id")
    _STG_SIDS+=("$sid")
    [ -z "$sid" ] || used="$used$sid "
  done
  [ "$used" != " " ] || return 0
  [ -n "$_STATUS_PHASE_READY" ] || _status_phase_rows_collect
  sums=$(printf '%s\n' "$_STATUS_PHASE_ROWS" | awk -F '\t' '
    NF >= 5 { if (!($1 in d)) o[++n] = $1; d[$1] += $4; t[$1] += $5 }
    END { for (i = 1; i <= n; i++) printf "%s\t%d\t%d\n", o[i], d[o[i]], t[o[i]] }')
  for pass in epic spec; do
    while IFS= read -r sid; do
      [ -n "$sid" ] || continue
      case "$used" in *" $sid "*) ;; *) continue ;; esac
      kind=spec
      if [ -f "$root/$sid/roadmap.md" ] \
         && [ -n "$(jig_spec_epic "$root/$sid/roadmap.md" 2>/dev/null || true)" ]; then
        kind=epic
      fi
      [ "$kind" = "$pass" ] || continue
      title=""
      [ ! -f "$root/$sid/spec.md" ] || title=$(spec_title "$root/$sid/spec.md")
      d="" t=""
      while IFS=$'\t' read -r s id; do
        if [ "$s" = "$sid" ]; then d=${id%%$'\t'*} t=${id#*$'\t'}; fi
      done <<SUMS
$sums
SUMS
      _STG_KEYS+=("$sid")
      _STG_TITLE+=("${title:-$sid}")
      _STG_KIND+=("$kind")
      _STG_DONE+=("$d")
      _STG_TOTAL+=("$t")
    done < <(spec_ids)
  done
}

# spec_phase_rows, asked once per report: the page shows it twice, in "Running
# now" and under Specifications, and each call reads every open epic's roadmap
# from its branch.
_STATUS_PHASE_ROWS=""
_STATUS_PHASE_READY=""
_status_phase_rows_collect() {
  _STATUS_PHASE_ROWS=$(spec_phase_rows)
  _STATUS_PHASE_READY=1
}

# _status_group_of <task-id> — the spec the task belongs to, into _STG_SID;
# empty for "Other tasks".
_status_group_of() {
  local i=0
  _STG_SID=""
  while [ "$i" -lt ${#_STG_IDS[@]} ]; do
    if [ "${_STG_IDS[$i]}" = "$1" ]; then _STG_SID=${_STG_SIDS[$i]}; return 0; fi
    i=$((i + 1))
  done
}

# _status_group_label <index> — "epic · 3/5 done" for the group at <index>
# of _STG_KEYS, without the count when the roadmap was not read; into
# _STG_LABEL.
_STG_LABEL=""
_status_group_label() {
  _STG_LABEL=${_STG_KIND[$1]}
  if [ -n "${_STG_TOTAL[$1]}" ]; then
    _STG_LABEL="$_STG_LABEL$OUT_SEP${_STG_DONE[$1]}/${_STG_TOTAL[$1]} done"
  fi
}

# _status_terminal_tasks <tasks> <finished> — one row per task that needs
# nothing (a task that does is under "Needs you"): its class, its id, and
# what differs from a task on its branch here — its own worktree and the files
# waiting there, a base of its own, a lighter route, a running autopilot.
# When any of them belongs to a spec, the rows are grouped
# (_status_task_groups): a line per epic or spec with its progress, its tasks
# under it on the branches of a tree, and "Other tasks" last.
_status_terminal_tasks() {
  local ntasks="$1" finished="$2" t id rest words w class wd counts
  local -a ids=() classes=() notes=() note=()
  if [ "$ntasks" -gt 0 ]; then counts="$ntasks active"; else counts="no active tasks"; fi
  [ -z "$finished" ] || counts=$(out_join "$counts" "$finished finished")
  if [ ${#_STT_TASKS[@]} -gt 0 ]; then
    for t in "${_STT_TASKS[@]}"; do
      id=${t%% *}
      rest=${t#* }
      # The worktree's path is the one field a person chose: cut it out
      # before the rest is split into words.
      case "$rest" in
        *" worktree="*" uncommitted="*)
          words="${rest%% worktree=*} worktree uncommitted=${rest##* uncommitted=}"
          ;;
        *) words=$rest ;;
      esac
      class=""
      note=()
      for wd in $words; do
        case "$wd" in
          class=*) class=${wd#class=} ;;
          status=active) ;;
          status=*) note+=("${wd#status=}") ;;
          depth=*) note+=("${wd#depth=}") ;;
          worktree) note+=("worktree") ;;
          uncommitted=0) ;;
          uncommitted=*) note+=("${wd#uncommitted=} uncommitted") ;;
          base=*) note+=("base ${wd#base=}") ;;
          autopilot=on) note+=("autopilot on") ;;
          *) note+=("$wd") ;;
        esac
      done
      ids+=("$id")
      classes+=("${class:--}")
      t=""
      if [ ${#note[@]} -gt 0 ]; then
        for wd in "${note[@]}"; do
          if [ -n "$t" ]; then t="$t$OUT_SEP$wd"; else t=$wd; fi
        done
      fi
      notes+=("$t")
    done
  fi
  [ "$ntasks" -gt 0 ] || [ -n "$finished" ] || [ -n "$_STT_CURRENT" ] || return 0
  out_section "Tasks" "$counts"
  w=20
  for id in "${ids[@]+"${ids[@]}"}"; do
    [ $((${#id} + 3)) -le "$w" ] || w=$((${#id} + 3))
  done
  _STG_KEYS=()
  if [ ${#ids[@]} -gt 0 ]; then _status_task_groups "${ids[@]}"; fi
  local i=0 g key title text last
  local -a members=()
  if [ ${#_STG_KEYS[@]} -eq 0 ]; then
    while [ "$i" -lt ${#ids[@]} ]; do
      _status_terminal_task_row "" "${classes[$i]}" "$w" "${ids[$i]}" "${notes[$i]}"
      i=$((i + 1))
    done
  fi
  # One pass per group, and one more for "Other tasks".
  g=0
  while [ ${#_STG_KEYS[@]} -gt 0 ] && [ "$g" -le ${#_STG_KEYS[@]} ]; do
    if [ "$g" -lt ${#_STG_KEYS[@]} ]; then
      key=${_STG_KEYS[$g]}
      title=${_STG_TITLE[$g]}
      _status_group_label "$g"
      text="($_STG_LABEL)"
    else
      key="" title="Other tasks" text=""
    fi
    g=$((g + 1))
    members=()
    i=0
    while [ "$i" -lt ${#ids[@]} ]; do
      _status_group_of "${ids[$i]}"
      if [ "$_STG_SID" = "$key" ]; then members+=("$i"); fi
      i=$((i + 1))
    done
    [ ${#members[@]} -gt 0 ] || continue
    out_row bold $((${#title} + 2)) "$title" dim 0 "$text"
    last=${members[$((${#members[@]} - 1))]}
    for i in "${members[@]}"; do
      if [ "$i" = "$last" ]; then t=$OUT_TREE_LAST; else t=$OUT_TREE; fi
      _status_terminal_task_row "$t" "${classes[$i]}" "$w" "${ids[$i]}" "${notes[$i]}"
    done
  done
  [ -z "$_STT_CURRENT" ] || out_row dim 4 "$OUT_MARK" plain 0 "current task: $_STT_CURRENT"
}

# _status_terminal_task_row <branch> <class> <width> <id> <notes> — one task's
# row, on <branch> of a group's tree, or flat when <branch> is empty.
_status_terminal_task_row() {
  local cstyle
  case "$2" in
    T3 | T4) cstyle=warn ;;
    T0 | T1) cstyle=dim ;;
    *) cstyle=plain ;;
  esac
  if [ -n "$1" ]; then
    out_row dim 3 "$1" "$cstyle" 4 "$2" bold "$3" "$4" warn 0 "$5"
  else
    out_row "$cstyle" 4 "$2" bold "$3" "$4" warn 0 "$5"
  fi
}

# _status_terminal_activity — what was recorded in this checkout lately
# (checkout.sh), folded: the latest record on a row of its own, then one row
# per command and hour, the records of each counted and their first ids
# named. The last row says who holds HEAD here, the same rule a refusal uses
# (jig_checkout_occupants).
_status_terminal_activity() {
  local t n=0 oldest="" age subject cmd ids cw=12 hold
  local -a ages=() subjects=() cmds=() idlists=()
  if [ ${#_STT_OTHERS[@]} -gt 0 ]; then
    n=${#_STT_OTHERS[@]}
    while IFS=$'\t' read -r age subject cmd ids; do
      [ -n "$age" ] || continue
      if [ "$age" = "@oldest" ]; then oldest=$subject; continue; fi
      ages+=("$age")
      subjects+=("$subject")
      cmds+=("$cmd")
      idlists+=("$ids")
    done < <(printf '%s\n' "${_STT_OTHERS[@]}" | _status_activity_fold)
  fi
  if [ "$n" = 0 ]; then
    out_section "Recent activity here" "no records"
  elif [ "$n" = 1 ]; then
    out_section "Recent activity here" "1 record, $oldest ago"
  else
    out_section "Recent activity here" "$n records, last $oldest"
  fi
  # The command first, so that what it was run on has the rest of the
  # line: a group names as many of its ids as fit there.
  local i=0 room
  while [ "$i" -lt ${#ages[@]} ]; do
    [ $((${#cmds[$i]} + 3)) -le "$cw" ] || cw=$((${#cmds[$i]} + 3))
    i=$((i + 1))
  done
  [ "$cw" -le 30 ] || cw=30
  room=$((OUT_WIDTH - 2 - 6 - cw))
  i=0
  while [ "$i" -lt ${#ages[@]} ]; do
    subject=${subjects[$i]}
    case "$subject" in
      [0-9]*" "*)
        t=plain
        if [ -n "${idlists[$i]}" ]; then
          _status_fit_ids $((room - ${#subject} - 2)) "${idlists[$i]}"
          subject="$subject: $_STT_FIT"
        fi
        ;;
      *) t=bold ;;
    esac
    out_row dim 6 "${ages[$i]}" plain "$cw" "${cmds[$i]}" "$t" 0 "$subject"
    i=$((i + 1))
  done
  # Only the task is named: the record's command may be this very report,
  # which refreshed it a moment ago.
  if [ -n "$_STT_HEAD" ]; then
    hold="task ${_STT_HEAD%% *} holds HEAD here"
  else
    hold="nothing here holds HEAD"
  fi
  [ -z "$_STT_UNSEEN" ] || hold=$(out_join "$hold" "sessions not observable")
  out_row dim 6 "$OUT_MARK" plain 0 "$hold"
}

# _status_fit_ids <width> <ids> — as many of the comma-separated <ids> as fit
# in <width> characters, whole, followed by "more" when any is left out; into
# _STT_FIT. When not even the first fits, "more" alone.
_STT_FIT=""
_status_fit_ids() {
  local room="$1" list="$2" more="$OUT_MORE" cut=0 id t need
  case "$list" in *", $more") list=${list%, "$more"}; cut=1 ;; esac
  _STT_FIT=""
  while [ -n "$list" ]; do
    id=${list%%, *}
    if [ "$id" = "$list" ]; then list=""; else list=${list#*, }; fi
    if [ -n "$_STT_FIT" ]; then t="$_STT_FIT, $id"; else t=$id; fi
    need=${#t}
    # Whatever is still left needs room for the "more" that says so.
    if [ -n "$list" ] || [ "$cut" = 1 ]; then need=$((need + 2 + ${#more})); fi
    if [ "$need" -gt "$room" ]; then
      if [ -n "$_STT_FIT" ]; then _STT_FIT="$_STT_FIT, $more"; else _STT_FIT=$more; fi
      return 0
    fi
    _STT_FIT=$t
  done
  if [ "$cut" = 1 ]; then _STT_FIT="$_STT_FIT, $more"; fi
  return 0
}

# _status_activity_fold — "label<TAB>command<TAB>age" lines on stdin (age as
# jig_checkout_ago prints it), folded into rows "age<TAB>subject<TAB>command<TAB>ids",
# youngest first, then one "@oldest<TAB><age>" line. The latest record is a
# row of its own; the rest are grouped by command and by the hour of their
# age, a group's age being its youngest record's. A group of one names its
# record; a larger one counts them ("6 tasks") and names up to three ids,
# then "more".
_status_activity_fold() {
  awk -F '\t' '
    {
      a = $3; s = a + 0
      if (a ~ /m$/) s *= 60; else if (a ~ /h$/) s *= 3600
      printf "%010d\t%s\t%s\t%s\n", s, a, $1, $2
    }' | sort | MORE="$OUT_MORE" awk -F '\t' '
    function name(l) { sub(/^task /, "", l); return l }
    {
      s = $1 + 0; oldest = $2
      if (NR == 1) { first = $2 "\t" name($3) "\t" $4 "\t"; next }
      k = int(s / 3600) "\t" $4
      if (!(k in c)) { order[++m] = k; age[k] = $2; cmd[k] = $4 }
      c[k]++
      if ($3 ~ /^task /) { t[k]++; if (t[k] <= 3) ids[k] = ids[k] (t[k] > 1 ? ", " : "") name($3); else more_[k] = 1 }
      else o[k]++
      one[k] = name($3)
    }
    END {
      if (NR == 0) exit
      print first
      for (j = 1; j <= m; j++) {
        k = order[j]
        if (c[k] == 1) { print age[k] "\t" one[k] "\t" cmd[k] "\t"; continue }
        if (!o[k]) subj = c[k] " tasks"; else if (!t[k]) subj = c[k] " sessions"; else subj = c[k] " records"
        l = ids[k]; if (more_[k]) l = l ", " ENVIRON["MORE"]
        print age[k] "\t" subj "\t" cmd[k] "\t" l
      }
      print "@oldest\t" oldest
    }'
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
# <autopilot> <pr_url> <knowledge_consolidated> <route_depth> <class_lowered_from> <issue>, joined by \037; each value is
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
        printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n",
          v["task_id"], v["class"], v["status"], v["paused"], v["paused_reason"],
          v["branch"], v["base_branch"], v["autopilot"], v["pr_url"], v["knowledge_consolidated"],
          v["route_depth"], v["class_lowered_from"], v["issue"]
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
# the receipt line `jig task receipt --check` prints (task_receipt_check, asked
# `cheap`: no `jig context` process per task, so "not checked", not "current",
# when the diff has not moved). With
# `page`, also the answers only the page shows: the gate of a T3/T4 design
# (_task_gate_state) and the autopilot run (_task_autopilot_facts).
_status_live_collect() {
  local page="${1:-}" row id class status paused reason branch base autopilot pr_url kc own_depth lowered issue
  local wt wt_note receipt gate facts depth setting us="$_STATUS_US"
  _STATUS_FINISHED=0
  _STATUS_LIVE=""
  _STATUS_WORKTREES=$(_task_worktrees)
  _STATUS_DEFAULT_BASE=$(cfg git.base_branch main)
  setting=$(_task_route_setting)
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS="$us" read -r id class status paused reason branch base autopilot pr_url kc own_depth lowered issue <<EOF
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
    receipt=$(task_receipt_check "$id" cheap || true)
    gate="" facts=""
    if [ "$page" = page ]; then
      case "$class" in
        T3 | T4) gate=$(_task_gate_state "$id") ;;
      esac
      [ -z "$autopilot" ] || facts=$(_task_autopilot_facts "$id")
    fi
    # The task's route depth, as task.sh's rule answers it
    # (_task_route_depth_of) for the key the state row already holds and the
    # person's route.depth, read once above.
    depth=$(_task_route_depth_of "$own_depth" "$setting")
    depth=${depth%%$'\t'*}
    _STATUS_LIVE="$_STATUS_LIVE$id$us$class$us$status$us$paused$us$reason$us$branch$us$base$us$autopilot$us$pr_url$us$kc$us$wt$us$wt_note$us$receipt$us$gate$us$depth$us$lowered$us$issue$us$facts
"
  done <<EOF
$(_status_task_rows)
EOF
  _STATUS_LIVE_READY=1
}

# _status_rec <record> — one _STATUS_LIVE record into the _ST_* globals.
# _ST_APFACTS is _task_autopilot_facts' line, tab-separated, or empty; it is
# the last field because it is the one holding tabs. _ST_DEPTH is the task's
# route depth (_task_route_depth): `full` or `lean`. _ST_LOWERED is the class
# the task was lowered from (`class_lowered_from`), empty when it never was.
# _ST_ISSUE is the task's tracker issue (`issue`), empty when it has none.
_status_rec() {
  IFS="$_STATUS_US" read -r _ST_ID _ST_CLASS _ST_STATUS _ST_PAUSED _ST_REASON _ST_BRANCH _ST_BASE \
    _ST_AUTOPILOT _ST_PR_URL _ST_KC _ST_WT _ST_WT_NOTE _ST_RECEIPT _ST_GATE _ST_DEPTH _ST_LOWERED _ST_ISSUE \
    _ST_APFACTS <<EOF
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
  jig_cleanup_add "$cur_err_file"
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
# Counted from hklog_flagged_ids, so this line and the page's cards name the
# same tasks: a count that said two while the cards showed one would send the
# reader looking for a task that is not there.
_status_hk_count() {
  hklog_flagged_ids "$1" | grep -c . || true
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
  jig_cleanup_add "$_STATUS_HTML_TMP"
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

# _status_hk_load — the last housekeeping run, into _STATUS_HK_AT (UTC),
# _STATUS_HK_FORGE and _STATUS_HK_WHEN (the reader's zone); all empty when it
# never ran. Read once, for the page and for `jig status --json` alike.
_status_hk_load() {
  _STATUS_HK_RUN=$(hklog_last_run)
  _STATUS_HK_AT=$(printf '%s\n' "$_STATUS_HK_RUN" | cut -f 1)
  _STATUS_HK_FORGE=$(printf '%s\n' "$_STATUS_HK_RUN" | cut -f 2)
  _STATUS_HK_WHEN=""
  [ -z "$_STATUS_HK_AT" ] || _STATUS_HK_WHEN=$(_status_when "$_STATUS_HK_AT")
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

  _status_hk_load

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

# _status_html_needs — the "Needs you" section: one card per attention item
# (_status_attention), in its order. Nothing to do is said out loud too.
# `jig status --json` reports the same items (_status_json), so the page and
# the data cannot disagree about what needs the reader.
_status_html_needs() {
  local attn rec kind stype sid tasks title detail todo url label badge
  attn=$(_status_attention)
  printf '<section id="needs">\n<h2>Needs you</h2>\n'
  if [ -n "$attn" ]; then
    printf '<div class="cards">\n'
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      # shellcheck disable=SC2034 # tasks is the JSON's field; a card names its subject
      IFS="$_STATUS_US" read -r kind stype sid tasks title detail todo url <<REC
$rec
REC
      case "$stype" in
        phase) label="phase $sid" ;;
        *) label=$sid ;;
      esac
      badge=""
      case "$kind" in
        autopilot-stopped | phase-stopped) badge='<span class="badge warn">autopilot stopped</span>' ;;
      esac
      _status_card "$title" "$label" "$detail" "$todo" "$url" "$badge"
    done <<ATTN
$attn
ATTN
    printf '</div>\n'
  else
    printf '<p class="nothing">Nothing needs you right now.</p>\n'
    if [ -n "$_STATUS_HK_AT" ] && _status_hk_stale "$_STATUS_HK_AT" "$_STATUS_HK_FORGE"; then
      printf '<p class="muted">Pull request data is stale, so a pull request waiting for you may be missing here.</p>\n'
    fi
  fi
  printf '</section>\n'
}

# _status_attn <kind> <subject-type> <subject-id> <tasks> <title> <detail>
# <todo> [url] — one attention item as a record: the fields joined by \037 on
# one line. <kind> is the stable word a program reads (schemas/json.md);
# <subject-type> is `task`, `phase` or `project` (whose <subject-id> is
# empty); <tasks> the ids the item is about, space-separated.
_status_attn() {
  local us="$_STATUS_US"
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$1" "$us" "$2" "$us" "$3" "$us" "$4" "$us" \
    "$5" "$us" "$6" "$us" "$7" "$us" "${8:-}"
}

# _status_attention — what only the reader can do, one record (_status_attn)
# per item, most urgent first: a new jig release, a stopped autopilot run, a
# design at its gate, a finished task waiting for its git step, a pull request
# to review or merge, a merged task to close, work that landed wrong or was
# left in a worktree, knowledge to decide. Each says in plain words what to do.
#
# The one answer to "what needs the reader": the page renders it as cards and
# `jig status --json` as items. It reads what the page reads — _STATUS_LIVE
# (_status_live_collect page), the last housekeeping run (_status_hk_load) and
# the counts (_SC_*) — and both print the same records, so nothing is computed
# twice.
_status_attention() {
  local stopped="" gates="" git_steps="" rec id stop_reason stop_at ago level queue url live hk_note pr_ids=""
  local nc wrong kept closed open settled phase phase_stops=""
  hk_note=""
  [ -z "$_STATUS_HK_AT" ] || hk_note="housekeeping at $_STATUS_HK_WHEN"
  level=$(jig_agent_git 2>/dev/null) || level=none
  settled=$(hklog_ids ' remote=(merged|closed) ')

  # 0. A new jig release is out (task status-says-a-newer-jig-exists): the
  # one item here that is about the framework itself rather than any task,
  # so it leads, first of all — a person who never runs `jig doctor` learns
  # of it only from this page and the plain-text hint (_status_new_release_hint).
  local latest_release
  if latest_release=$(_status_latest_release_available); then
    _status_attn release-available project "" "" "jig v$latest_release is out" "" \
      "jig self-update, then jig upgrade"
  fi

  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    _status_rec "$rec"
    # A pull request jig opened, unless housekeeping already saw it settled.
    # Collected before anything below, because the branches that follow end
    # the iteration: a task whose autopilot stopped is exactly the one that
    # has just been shipped, and its pull request was the item most likely to
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
      # item quotes it as what was said then -- the age leads, and the reason
      # follows a colon -- instead of appending the age to a sentence that
      # then reads as true now. What is true now is derived here, in the
      # items around this one.
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
      # held back here and becomes a single item below — the page says what
      # the coordinator says in chat, one message for the whole wave.
      phase=$(printf '%s\n' "$_ST_APFACTS" | cut -f 7)
      if [ -n "$phase" ] && [ "$phase" != "-" ]; then
        phase_stops="$phase_stops$phase	$_ST_ID	$stop_reason
"
        continue
      fi
      stopped="$stopped$(_status_attn autopilot-stopped task "$_ST_ID" "$_ST_ID" \
        "Autopilot stopped and is waiting for you" "$stop_reason" \
        "Answer the agent in this task's session; it resumes the run.")
"
      continue
    fi
    # 2. A design waits at its human gate, or changed after it was approved.
    case "$_ST_GATE" in
      waiting)
        gates="$gates$(_status_attn gate-waiting task "$_ST_ID" "$_ST_ID" \
          "A design is waiting for your decision" "design.md in the task's workspace" \
          "Read the design the agent showed you and approve it, or say what to change.")
" ;;
      changed)
        gates="$gates$(_status_attn gate-changed task "$_ST_ID" "$_ST_ID" \
          "A design changed after you approved it" "design.md in the task's workspace" \
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
      [ -z "$queue" ] || git_steps="$git_steps$(_status_attn git-step task "$_ST_ID" "$_ST_ID" \
        "Ready for your step in git" "agent.git: $level" "$queue")
"
    fi
  done <<LIVE
$_STATUS_LIVE
LIVE
  # Most urgent first, whatever order the workspaces came in; a phase run's
  # stops come first of all, as one item per phase — after only a new
  # release, which is not about any task.
  _status_attention_phase_stops "$phase_stops"
  printf '%s' "$stopped$gates$git_steps"

  # 4. A pull request waits for review or merge: one jig opened (pr_url), or
  # one the last housekeeping run saw open (a closed task's too).
  #
  # Deliberately outside hklog_flagged_ids, and "a closed task's too" is the
  # reason: closing a task does not merge its pull request, so a consolidated
  # task with `remote=open` contradicts nothing and this item still asks for
  # something real. Only the forge can answer whether it is open, which is why
  # it is worded in the past tense and asks for a refresh first.
  #
  # One live answer does reach it, in the loop below: a task the person
  # abandoned. That disproves no flag either -- it makes the item's ask wrong,
  # so the item changes what it asks instead of disappearing.
  open=$(hklog_ids ' remote=open ')
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _status_in "$id" "$pr_ids" || pr_ids="$pr_ids$id
"
  done <<OPEN
$open
OPEN
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # Guarded for the same reason as in _hklog_recheck: these ids include
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
      # not work to merge. So this item keeps the borrowed fact and changes
      # what it asks for, which is the one thing the local answer is good for
      # here. `consolidated` is deliberately not treated this way: a closed
      # task with an open pull request is worth looking at, and merging it is
      # still the right move.
      #
      # Borrowed exactly as much as the item below it, and worded the same
      # way: past tense, and a refresh asked for first. Only what the task's
      # own state says -- that it was abandoned -- is present tense here. A
      # change about items claiming more than they know may not add one.
      _status_attn pull-request-of-abandoned-task task "$id" "$id" \
        "A pull request was open for a task you abandoned" "${hk_note:+open as of $hk_note}" \
        "It may have been closed or merged since: jig last asked the forge then. Run jig housekeeping to refresh, then close on the forge what is still open, or reopen the task. Nothing here will merge it." "$url"
    elif _status_in "$id" "$open"; then
      # Borrowed knowledge: housekeeping asks the forge once a cadence, so this
      # one may have been merged since. Past tense, and the first thing asked
      # for is a refresh -- the imperative below it is the one the reader acts
      # on, so it must not tell them to merge what may already be merged.
      _status_attn pull-request-was-open task "$id" "$id" \
        "A pull request was open at the last housekeeping run" "open as of $hk_note" \
        "It may have been merged since: jig last asked the forge then. Run jig housekeeping to refresh, then review and merge what is still open." "$url"
    else
      _status_attn pull-request-waiting task "$id" "$id" \
        "A pull request is waiting for review or merge" "opened by jig task ship" \
        "Review it and merge it; jig merges one itself only at agent.git: merge, on green CI." "$url"
    fi
  done <<PRS
$pr_ids
PRS

  # 5. Merged and ready to close (needs-consolidation, ADR-0030). 6. Work that
  # landed elsewhere, a pull request closed unmerged, a worktree left behind:
  # kept, and only a person can say what happens next.
  #
  # Through hklog_flagged_ids, so a flag this disk already disproves -- a
  # task closed since the run, a worktree removed since it -- makes no item,
  # and the same four answers reach the counts.
  nc=$(hklog_flagged_ids needs-consolidation)
  wrong=$(hklog_flagged_ids wrong-base)
  closed=$(hklog_flagged_ids 'abandoned?')
  kept=$(hklog_flagged_ids worktree-kept)
  _status_attention_per_task needs-consolidation "$nc" "Merged: the task can be closed" "$hk_note" \
    "Tell the agent to close this task (jig-consolidate)."
  _status_attention_per_task wrong-base "$wrong" "The work landed on a different branch than planned" "$hk_note" \
    "Check where its pull request was merged; the details are in .ai/runtime/housekeeping.log."
  _status_attention_per_task closed-unmerged "$closed" "The pull request was closed without merging" "$hk_note" \
    "Reopen it, or tell the agent to abandon the task."
  _status_attention_per_task worktree-kept "$kept" "A worktree was kept because it still holds work" "$hk_note" \
    "Commit or discard what is left in the task's worktree; the next housekeeping removes it."

  # 7. Knowledge nobody has agreed to yet reaches no agent (ADR-0016).
  if [ -n "$_SC_PROPOSALS" ] && [ "$_SC_PROPOSALS" -gt 0 ]; then
    _status_attn knowledge-proposed project "" "" "Knowledge is waiting for your decision" \
      "$_SC_PROPOSALS document(s) proposed" "Ask the agent: what's proposed? (jig-accept)"
  fi
  if [ -n "$_SC_SOURCES" ] && [ "$_SC_SOURCES" -gt 0 ]; then
    _status_attn sources-changed project "" "" "Adopted rule files changed since you approved them" \
      "$_SC_SOURCES file(s)" "Ask the agent to go through the changed sources with you (jig-accept)."
  fi
}

# _status_attention_per_task <kind> <ids> <title> <detail> <todo> — one item
# per id.
_status_attention_per_task() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _status_attn "$1" task "$id" "$id" "$3" "$4" "$5"
  done <<IDS
$2
IDS
}

# _status_attention_phase_stops <lines> — one item per phase, from
# `<phase>\t<task-id>\t<stop reason>` lines. Several stopped tasks of one
# phase make one item with all of them listed: in a phase run the person is
# asked once, in the coordinator's session, about the whole wave — the page
# says the same thing rather than handing them a card each
# (adr-20260922-a-phase-run-is-coordinated).
_status_attention_phase_stops() {
  local lines="$1" phases="" phase id reason detail n ids todo
  [ -n "$lines" ] || return 0
  phases=$(printf '%s\n' "$lines" | cut -f 1 | grep -v '^$' | sort -u)
  while IFS= read -r phase; do
    [ -n "$phase" ] || continue
    detail="" n=0 ids=""
    while IFS="$(printf '\t')" read -r _ id reason; do
      [ -n "$id" ] || continue
      n=$((n + 1))
      detail="$detail${detail:+; }$id — $reason"
      ids="$ids${ids:+ }$id"
    done < <(printf '%s\n' "$lines" | awk -F '\t' -v p="$phase" '$1 == p')
    if [ "$n" -gt 1 ]; then
      todo="Answer in the coordinator's session; it resumes the tasks."
    else
      todo="Answer in the coordinator's session; it resumes the task."
    fi
    _status_attn phase-stopped phase "$phase" "$ids" "A phase run is waiting for you" "$detail" "$todo"
  done < <(printf '%s\n' "$phases")
}

# --- `jig status --json` ----------------------------------------------------------
#
# What needs the reader, as data: the page's "Needs you" items
# (_status_attention), in its order, in the envelope every `--json` read
# prints (adr-20261015-a-read-is-one-json-envelope; schemas/json.md). It reads
# what the page's redraw reads — the counts the last full run saved, never
# counted again when they exist — and writes nothing: no page, no counts. Run in
# a task worktree it reads the main checkout, as the page does (_status_json).

# _status_json [--json] — the producer json_run runs for `jig status --json`.
_status_json() {
  local arg attn rec kind stype sid tasks title detail todo url objs="" o t tl hk stale root
  for arg in "$@"; do
    [ "$arg" = --json ] || jig_fail usage "status --json: unknown argument: $arg (usage: jig status --json)"
  done
  jig_require_repo
  # A task worktree borrows the owner's workspaces (ADR-0029), and the runtime
  # the page reads — the housekeeping log, the latest release, the saved
  # counts — is the owner's too. So the read is the owner's checkout, as the
  # page is, but answered by this jig: the envelope is always the one the
  # caller asked, never an older main checkout's. This subshell is the
  # producer's own, so nothing outside it sees the switch.
  root=$(jig_config_clone_root)
  if [ "$root" != "$JIG_PROJECT" ]; then
    JIG_PROJECT=$root
    cd "$root" || jig_die "status --json: cannot read the main checkout: $root"
  fi
  [ -f "$JIG_PROJECT/$JIG_AI_DIR/config.yaml" ] \
    || jig_fail not-initialised "status --json: project is not initialised; run: jig init"
  _status_load
  # The counts the last full run saved for the page. Without them, only the
  # two the items need are counted, and saved nowhere: what `jig upgrade`
  # would install is the slowest of the three and no item reads it.
  if ! _status_counts_read; then
    _SC_PROPOSALS=$(km_proposed_count)
    _SC_SOURCES=$(km_changed_sources_count)
    _SC_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  _status_live_collect page
  _status_hk_load
  attn=$(_status_attention)
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    IFS="$_STATUS_US" read -r kind stype sid tasks title detail todo url <<REC
$rec
REC
    json_quote "$kind"; o="{\"kind\":$_JSON"
    json_quote "$stype"; o="$o,\"subject\":{\"type\":$_JSON"
    json_str_or_null "$sid"; o="$o,\"id\":$_JSON}"
    tl=""
    for t in $tasks; do
      json_quote "$t"
      tl="$tl${tl:+,}$_JSON"
    done
    o="$o,\"tasks\":[$tl]"
    json_quote "$title"; o="$o,\"title\":$_JSON"
    json_str_or_null "$detail"; o="$o,\"detail\":$_JSON"
    json_quote "$todo"; o="$o,\"todo\":$_JSON"
    json_str_or_null "$url"; o="$o,\"url\":$_JSON}"
    objs="$objs${objs:+,}$o"
  done <<ATTN
$attn
ATTN
  hk=null
  if [ -n "$_STATUS_HK_AT" ]; then
    stale=false
    ! _status_hk_stale "$_STATUS_HK_AT" "$_STATUS_HK_FORGE" || stale=true
    json_quote "$_STATUS_HK_AT"; hk="{\"ran_at\":$_JSON"
    json_str_or_null "$_STATUS_HK_FORGE"; hk="$hk,\"forge\":$_JSON,\"stale\":$stale}"
  fi
  json_str_or_null "$_SC_AT"
  printf '{"attention":[%s],"housekeeping":%s,"knowledge_counts_at":%s}\n' "$objs" "$hk" "$_JSON"
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
# own lines. When any of these tasks belongs to a spec, the rows are grouped as
# the terminal groups them (_status_task_groups): a heading per epic or spec
# with its progress, its own table under it, and "Other tasks" last.
_status_html_tasks() {
  local rec rows="" paused_rows="" rank row tab
  local -a ids=()
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
    ids+=("$_ST_ID")
    rows="$rows$rank$tab$_ST_ID$tab$row
"
  done <<EOF
$_STATUS_LIVE
EOF
  _STG_KEYS=()
  if [ ${#ids[@]} -gt 0 ]; then _status_task_groups "${ids[@]}"; fi
  if [ -z "$rows" ]; then
    printf '<p class="empty">Nothing is running.</p>\n'
  elif [ ${#_STG_KEYS[@]} -eq 0 ]; then
    _status_html_task_table "$(printf '%s' "$rows" | sort -s -t "$tab" -k 1,1 | cut -f 3-)
"
  else
    _status_html_task_groups "$(printf '%s' "$rows" | sort -s -t "$tab" -k 1,1 | cut -f 2-)"
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

# _status_html_task_groups <rows> — "<id><TAB><row>" lines, already in the
# order "Running now" shows them, as one heading and table per group of
# _STG_KEYS, then "Other tasks". A group's heading names its spec as the
# specifications below do, says whether it is an epic, and draws its progress
# with the phases' bar.
_status_html_task_groups() {
  local g=0 key id row body pct heading
  while [ "$g" -le ${#_STG_KEYS[@]} ]; do
    if [ "$g" -lt ${#_STG_KEYS[@]} ]; then
      key=${_STG_KEYS[$g]}
      heading="<h3><code>$(_status_h "$key")</code>"
      # A spec with no heading of its own is titled by its id: said once.
      [ "${_STG_TITLE[$g]}" = "$key" ] || heading="$heading $(_status_h "${_STG_TITLE[$g]}")"
      heading="$heading <span class=\"badge\">$(_status_h "${_STG_KIND[$g]}")</span>"
      if [ -n "${_STG_TOTAL[$g]}" ]; then
        pct=0
        [ "${_STG_TOTAL[$g]}" -eq 0 ] || pct=$((${_STG_DONE[$g]} * 100 / ${_STG_TOTAL[$g]}))
        heading="$heading$(printf ' <span class="muted"><span class="bar"><span style="width: %d%%"></span></span>%s/%s done</span>' \
          "$pct" "$(_status_h "${_STG_DONE[$g]}")" "$(_status_h "${_STG_TOTAL[$g]}")")"
      fi
      heading="$heading</h3>"
    else
      key="" heading="<h3>Other tasks</h3>"
    fi
    g=$((g + 1))
    body=""
    while IFS=$'\t' read -r id row; do
      [ -n "$id" ] || continue
      _status_group_of "$id"
      [ "$_STG_SID" = "$key" ] || continue
      body="$body$row
"
    done <<EOF
$1
EOF
    [ -n "$body" ] || continue
    printf '%s\n' "$heading"
    _status_html_task_table "$body"
  done
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
  printf '<tr><td class="id"><code>%s</code></td><td>%s' \
    "$(_status_h "$_ST_ID")" "$(_status_h "${_ST_CLASS:--}")"
  [ "$_ST_DEPTH" != lean ] || printf ' <span class="badge">lean</span>'
  [ -z "$_ST_LOWERED" ] || printf ' <span class="badge warn">lowered from %s</span>' "$(_status_h "$_ST_LOWERED")"
  printf '</td><td>%s' "$(_status_h "$_ST_STATUS")"
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

  [ -n "$_STATUS_PHASE_READY" ] || _status_phase_rows_collect
  phases=$_STATUS_PHASE_ROWS
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
  agent_git=$(_status_autopilot_git)
  [ -z "$agent_git" ] || _status_html_item "autopilot.git" "${agent_git#autopilot.git: }" 0
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

# _status_latest_release_available — the version housekeeping's daily
# release check (.ai/runtime/latest-release, _hk_check_latest_release in
# housekeeping.sh) found strictly newer than the global framework this
# checkout uses, printed on success. Fails, printing nothing, on every other
# outcome — no file yet, the recorded check "failed", or the recorded
# version is not newer — since none of those is "you are current": task
# status-says-a-newer-jig-exists is explicit that this reads "нет файла / не
# удалось / не новее — ничего, никогда «у вас последняя»".
#
# Offline and read-only, unlike _status_framework_versions above: the
# network call already happened in housekeeping, at most once a cadence: this
# only reads its answer and jig_declared_version's (no execution, same
# reason jig_global_executable/jig_declared_version are used everywhere else
# in this file rather than running the global `jig`).
_status_latest_release_available() {
  local file="$JIG_PROJECT/$JIG_AI_DIR/runtime/latest-release" latest="" global_exe global tok
  [ -f "$file" ] || return 1
  while IFS= read -r tok; do
    case "$tok" in
      latest=*) latest=${tok#latest=} ;;
    esac
  done < <(tr ' ' '\n' < "$file")
  [ -n "$latest" ] || return 1
  global_exe=$(jig_global_executable) || return 1
  global=$(jig_declared_version "${global_exe%/scripts/jig}") || return 1
  jig_release_version "v$latest" >/dev/null 2>&1 || return 1
  jig_release_version "v$global" >/dev/null 2>&1 || return 1
  jig_version_newer "$latest" "$global" || return 1
  printf '%s\n' "$latest"
}

# _status_new_release_hint — the one line the plain-text report shows when
# _status_latest_release_available found something; nothing otherwise
# (task status-says-a-newer-jig-exists). The HTML page's own card
# (_status_html_needs) reads the same answer, so the two never disagree.
_status_new_release_hint() {
  local latest
  latest=$(_status_latest_release_available) || return 0
  printf '%s\n' "hint: jig v$latest is out; run \`jig self-update\`, then \`jig upgrade\`"
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
        # A secret's value lands in the transcript of the agent that runs
        # this, so it is named and never shown (_cfg_secret_key, config.sh).
        if _cfg_secret_key "$key"; then value=$JIG_CFG_MASK; fi
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
    # A secret there is worse than a no-op: once pushed it is anyone's, and
    # moving it to the local file does not take it back
    # (adr-20261009-autopilot-stops-reach-telegram).
    if _cfg_secret_key "$pkey"; then
      printf 'config.local: %s in %s is ignored (set it in %s; a token in a committed file is anyone'"'"'s once pushed: revoke it with @BotFather)\n' \
        "$pkey" "$JIG_AI_DIR/config.yaml" "$JIG_AI_DIR/config.local.yaml"
      continue
    fi
    printf 'config.local: %s in %s is ignored (set it in %s)\n' \
      "$pkey" "$JIG_AI_DIR/config.yaml" "$JIG_AI_DIR/config.local.yaml"
  done < <(jig_config_project_ignored)
}

# _status_notify — one line while the latest Telegram message failed
# (jig_notify_failing, notify.sh): a wrong token or chat id, or a sandbox with
# no network, would otherwise stay silent forever. A later success clears it.
_status_notify() {
  local at who why
  IFS=$'\t' read -r at who why <<EOF
$(jig_notify_failing)
EOF
  [ -n "$at" ] || return 0
  printf 'notify: Telegram messages are failing: %s (%s, %s)\n' "$why" "$who" "$at"
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

# _status_autopilot_git — one line naming the level an autopilot run ships
# at and the key it comes from (jig_autopilot_git, config.sh): `autopilot.git`
# when this clone sets it, else `agent.git`. Always printed, like the
# agent.git line: "a run ships the same as everything else" is the state a
# person most needs to see before trusting a run further.
_status_autopilot_git() {
  local line level key rc=0
  line=$(jig_autopilot_git) || rc=$?
  level=${line%%$'\t'*}
  key=${line#*$'\t'}
  if [ "$rc" -eq 0 ]; then
    printf 'autopilot.git: %s (from %s)\n' "$level" "$key"
  elif [ "$key" = autopilot.git ]; then
    printf 'autopilot.git: invalid value %s (expected none|commit|push|pr|merge)\n' "$level"
  fi
  # Nothing when it answers from an invalid agent.git: the agent.git line
  # already names that, and a second failure for one mistake reads as two.
  return 0
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

# Whether the runtime's notification hook reaches .ai/scripts/jig-notify-hook,
# printed only while `notify.interactive` is true: before that the hook would
# send nothing anyway, and a "not connected" line the reader never asked for
# is one they cannot clear (adr-20261010-a-waiting-session-reaches-telegram).
# The same adapter lookup as _status_session_hook; exit 2 — Codex — prints
# nothing.
_status_notify_hook() {
  local source a adir hint rc
  [ "$(cfg notify.interactive false)" = true ] || return 0
  source=$(manifest_source 2>/dev/null) || return 0
  [ -n "$source" ] || return 0
  [ -d "$source/adapters" ] || return 0
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"
  for a in $(cfg_list adapters "claude codex"); do
    adir=$(adapters_dir "$source/adapters" "$a") || continue
    [ -f "$adir/adapter.sh" ] || continue
    # shellcheck disable=SC1090
    . "$adir/adapter.sh"
    command -v "adapter_${a}_notify_hook_hint" >/dev/null 2>&1 || continue
    rc=0
    hint=$("adapter_${a}_notify_hook_hint" "$JIG_PROJECT") || rc=$?
    [ "$rc" = 2 ] && continue
    if [ -n "$hint" ]; then
      printf 'notify hook (%s): not connected (jig doctor shows the snippet)\n' "$a"
    else
      printf 'notify hook (%s): connected\n' "$a"
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

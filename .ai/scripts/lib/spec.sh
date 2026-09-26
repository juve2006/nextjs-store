# cmd_spec — specifications under .ai/specs/<id>/ (the jig-idea skill).
# Sourced by scripts/jig; defines cmd_spec.
#
# A specification is a plan, not knowledge: it lives outside .ai/knowledge/,
# carries no status, and everything reported here is derived from its files —
# the first heading of spec.md and the checkboxes of roadmap.md (ADR-0035).
#
# A task links to a spec through one `Spec: .ai/specs/<id>/ — Phase <n>` line in
# its task.md. `new` creates a spec, `done` checks a linked task's roadmap
# items, `remove` unlinks a spec's open tasks and moves the spec to trash,
# `close` removes a spec whose roadmap is complete, `epic` declares, cuts,
# finishes and reopens a spec's epic branch (ADR-0035, ADR-0040 as amended),
# and `ship` carries a declaration, an epic or an epic's final pull request as
# far as `agent.git` allows (adr-20260922-spec-work-ships-by-the-agent-git-level);
# `list` only reads.
# shellcheck shell=bash

SPEC_USAGE="usage: jig spec new <id> | jig spec list | jig spec plan <id> --phase <n> [--format text|tsv] | jig spec done <task-id> | jig spec close <id> [--leftovers-handled] | jig spec remove <id> [--dry-run] [--abandon-unstarted] | jig spec epic <id> [--release patch|minor|major | --finish [--leftovers-handled] | --reopen] | jig spec ship <id> [--message-file <file>] [--title <t>] [--body-file <file>]"

cmd_spec() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    # A command that changes a spec redraws the status page, whose progress
    # by phase it feeds (jig_status_page_touch, common.sh).
    new) spec_new "$@"; jig_status_page_touch ;;
    list) spec_list "$@" ;;
    plan) spec_plan "$@" ;;
    done) spec_done "$@"; jig_status_page_touch ;;
    remove) spec_remove "$@"; jig_status_page_touch ;;
    close) spec_close "$@"; jig_status_page_touch ;;
    epic) spec_epic "$@"; jig_status_page_touch ;;
    # Ships through git only; the spec's files are as `epic` left them.
    ship) spec_ship "$@" ;;
    help | -h | --help)
      printf '%s\n' "$SPEC_USAGE" >&2
      return 0
      ;;
    '')
      printf '%s\n' "$SPEC_USAGE" >&2
      exit 1
      ;;
    *) jig_die "spec: unknown subcommand: $sub ($SPEC_USAGE)" ;;
  esac
}

# spec_template <file> — the template to instantiate: the copy installed under
# .ai/templates/spec/ first, the framework checkout as a fallback for a
# project initialised before spec templates were installed (as km_template).
spec_template() {
  local installed src
  installed="$JIG_PROJECT/$JIG_AI_DIR/templates/spec/$1"
  if [ -f "$installed" ]; then
    printf '%s\n' "$installed"
    return 0
  fi
  src=$(jig_source_root)
  if [ -n "$src" ] && [ -f "$src/templates/spec/$1" ]; then
    printf '%s\n' "$src/templates/spec/$1"
    return 0
  fi
  return 1
}

# spec_new <id> — create .ai/specs/<id>/ with spec.md and roadmap.md from the
# templates. The id is validated here, at the one place the path is built:
# a directory with an invalid name would be skipped by every listing, so a
# spec created under one would silently not exist.
spec_new() {
  [ $# -ge 1 ] || jig_die "spec new: missing spec id (usage: jig spec new <id>)"
  [ $# -eq 1 ] || jig_die "spec new: unexpected argument: $2"
  local id="$1" root dir spec_tpl roadmap_tpl f
  spec_valid_id "$id" \
    || jig_die "spec new: invalid spec id: $id (letters, digits, '.', '_', '-'; no leading dot or dash)"
  jig_require_init
  # Both templates are resolved before anything is created, so a missing one
  # leaves no empty directory behind.
  spec_tpl=$(spec_template spec.md) \
    || jig_die "spec new: no template spec.md; run: jig upgrade"
  roadmap_tpl=$(spec_template roadmap.md) \
    || jig_die "spec new: no template roadmap.md; run: jig upgrade"
  root=$(spec_dir)
  dir="$root/$id"
  [ ! -e "$dir" ] || jig_die "spec new: spec already exists: $JIG_AI_DIR/specs/$id"
  mkdir -p "$root" || jig_die "spec new: cannot create $JIG_AI_DIR/specs"
  # A plain mkdir is the existence check that cannot race: it fails if the
  # directory appeared since the test above.
  mkdir "$dir" 2>/dev/null || jig_die "spec new: spec already exists: $JIG_AI_DIR/specs/$id"
  # Both files are written under temporary names first, so a failed copy
  # leaves nothing half-created and a retry works. The cleanup removes only
  # the files this run named and then `rmdir`s the directory, which refuses
  # anything that is not empty — it cannot delete what someone else put there.
  if ! cp "$spec_tpl" "$dir/spec.md.tmp.$$" || ! cp "$roadmap_tpl" "$dir/roadmap.md.tmp.$$"; then
    rm -f "$dir/spec.md.tmp.$$" "$dir/roadmap.md.tmp.$$"
    rmdir "$dir" 2>/dev/null || true
    jig_die "spec new: could not copy the templates into $JIG_AI_DIR/specs/$id"
  fi
  for f in spec.md roadmap.md; do
    mv "$dir/$f.tmp.$$" "$dir/$f" || jig_die "spec new: could not write $JIG_AI_DIR/specs/$id/$f"
    printf '%s/specs/%s/%s\n' "$JIG_AI_DIR" "$id" "$f"
  done
}

spec_dir() {
  printf '%s/%s/specs\n' "$JIG_PROJECT" "$JIG_AI_DIR"
}

# spec_valid_id <id> — the same grammar as a task id, from the one place both
# read it (common.sh, jig_valid_id).
spec_valid_id() {
  jig_valid_id "$1"
}

# spec_ids — valid spec ids, one per line, in directory order. A directory
# whose name is not a valid id is skipped rather than reported: nothing can
# address it by id.
spec_ids() {
  local root d id
  root=$(spec_dir)
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    id=${d##*/}
    spec_valid_id "$id" || continue
    printf '%s\n' "$id"
  done
}

spec_count() {
  spec_ids | grep -c . || true
}

# spec_title <spec.md> — the text of the first level-one heading, or empty.
spec_title() {
  sed -n 's/^#[[:space:]]\{1,\}//p' "$1" | head -n 1
}

# spec_progress <roadmap.md> — "roadmap D/T done, F filed, fog G": the sum of
# spec_phase_counts, so the whole and its phases cannot disagree.
spec_progress() {
  spec_phase_counts "$1" | awk -F '\t' '
    { done += $3; total += $4; filed += $5; fog += $6 }
    END { printf "roadmap %d/%d done, %d filed, fog %d\n", done, total, filed, fog }
  '
}

# spec_phase_counts <roadmap.md|-> — the roadmap counted by section, one
# `<phase>\t<title>\t<done>\t<total>\t<filed>\t<fog>` line each. The one place
# the counting rules for roadmap lines live (schemas/spec.md).
#
# An item is a checkbox line. Done is a checked one. Filed is an unchecked item
# whose text starts with a backticked task id followed by a dash — the id alone
# is not enough, because an item may just as well open with a backticked
# command name. Fog is an unchecked item whose text starts with `fog:`. Wave
# lines are a numbered list, not checkboxes, so they are never counted.
#
# A `## Phase <n> — <title>` heading opens phase <n>, listed even while it has
# no items. Items under any other `##` heading, or before the first one, are
# counted under `-` with that heading as their title (`-` when there is
# none), and listed only when there are some: every item is counted exactly
# once, which is what keeps spec_progress's sum equal to the old total.
spec_phase_counts() {
  awk '
    function reset() { done = 0; total = 0; filed = 0; fog = 0 }
    function flush() {
      if (phase != "-" || total > 0)
        printf "%s\t%s\t%d\t%d\t%d\t%d\n", phase, (title == "" ? "-" : title), done, total, filed, fog
    }
    BEGIN { phase = "-"; title = ""; reset() }
    /^##[[:space:]]/ {
      flush(); reset()
      h = $0
      sub(/^##[[:space:]]+/, "", h)
      gsub(/\t/, " ", h)
      if (h ~ /^Phase[[:space:]]+[0-9]+/) {
        sub(/^Phase[[:space:]]+/, "", h)
        phase = h
        sub(/[^0-9].*$/, "", phase)
        sub(/^[0-9]+[[:space:]]*/, "", h)
        sub(/^(—|--|-|:)[[:space:]]*/, "", h)
      } else {
        phase = "-"
      }
      title = h
      next
    }
    /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ {
      total++
      if ($0 ~ /\[[xX]\]/) { done++; next }
      text = $0
      sub(/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/, "", text)
      # "—" is matched as its UTF-8 bytes, which every awk compares as-is.
      if (text ~ /^`[A-Za-z0-9._-]+`[[:space:]]+(—|-|--)[[:space:]]/) filed++
      else if (text ~ /^fog:/) fog++
    }
    END { flush() }
  ' "$1"
}

# spec_phase_rows — every spec's progress by phase for the status page, one
# `<spec-id>\t<phase>\t<title>\t<done>\t<total>\t<filed>\t<fog>\t<source>` row
# per spec_phase_counts line, unformatted (ARCHITECTURE.md, Scripts layout).
# <source> is empty when the roadmap is this checkout's. A spec with an open
# epic that is not checked out here is read from the epic's ref — progress is
# made there (ADR-0040) — with no fetch, and <source> names the branch and
# whether the ref is the remote's as of the last fetch; with no ref at all it
# has no rows, and spec_list_rows already says `branch missing`.
spec_phase_rows() {
  local root id roadmap loc ref source
  root=$(spec_dir)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    roadmap="$root/$id/roadmap.md"
    [ -f "$roadmap" ] || continue
    loc=$(spec_roadmap_ref "$id") || continue
    if [ -n "$loc" ]; then
      IFS=$'\t' read -r ref source <<EOF
$loc
EOF
      jig_git_show_path "$ref" "$JIG_AI_DIR/specs/$id/roadmap.md" 2>/dev/null \
        | spec_phase_counts - | _spec_phase_prefix "$id" "$source" || true
      continue
    fi
    spec_phase_counts "$roadmap" | _spec_phase_prefix "$id" ""
  done < <(spec_ids)
}

# spec_roadmap_ref <spec-id> — where the current roadmap of a spec is read.
# Nothing when this checkout's copy is current: no epic, a finished one, or the
# epic is checked out here. "<ref>\t<source>" when an open epic elsewhere holds
# it — progress is made there (ADR-0040) — read with no fetch; <source> names
# the branch and whether the ref is the remote's as of the last fetch. Exit 1
# when that epic has no ref here at all, 2 when git rejects its name — no
# fetch can bring that one. The one place both the status page
# (spec_phase_rows) and `spec plan` decide it, so they cannot disagree.
spec_roadmap_ref() {
  local roadmap line branch here ref
  roadmap="$(spec_dir)/$1/roadmap.md"
  line=$(jig_spec_epic "$roadmap" 2>/dev/null) || line=""
  [ -n "$line" ] || return 0
  [ "${line##* }" != finished ] || return 0
  branch=${line% *}
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" != "$here" ] || return 0
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 2
  ref=$(jig_base_ref "$branch")
  [ -n "$ref" ] || return 1
  case "$ref" in
    refs/remotes/*) printf '%s\t%s as of the last fetch\n' "$ref" "$branch" ;;
    *) printf '%s\t%s\n' "$ref" "$branch" ;;
  esac
}

# _spec_phase_prefix <id> <source> — frame spec_phase_counts lines as rows.
# Values reach awk through the environment: a `-v` value has its escapes
# expanded.
_spec_phase_prefix() {
  JIG_SP_ID="$1" JIG_SP_SOURCE="$2" awk '{ printf "%s\t%s\t%s\n", ENVIRON["JIG_SP_ID"], $0, ENVIRON["JIG_SP_SOURCE"] }'
}

# spec_list — `jig spec list`: one aligned line per spec, from spec_list_rows.
spec_list() {
  [ $# -eq 0 ] || jig_die "spec list: unexpected argument: $1"
  jig_require_repo
  local rows
  rows=$(spec_list_rows)
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | awk -F '\t' '
    { id[NR] = $1; t[NR] = $2; s[NR] = $3
      if (length($1) > wi) wi = length($1)
      if (length($2) > wt) wt = length($2) }
    # The width is spliced into the format, not passed as `*`: not every awk
    # on a supported machine takes a dynamic width.
    END { fmt = "%-" wi "s   %-" wt "s   %s\n"
          for (i = 1; i <= NR; i++) printf fmt, id[i], t[i], s[i] }
  '
}

# spec_list_rows — what `spec list` answers, one "<id><TAB><title><TAB><state>"
# row per spec, unformatted. `jig spec list` aligns it; `jig status --html`
# renders it (ARCHITECTURE.md, Scripts layout: a reporting command consumes a
# peer's answer, never recomputes it).
spec_list_rows() {
  local root id title state missing
  root=$(spec_dir)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    title="" missing=""
    if [ -f "$root/$id/spec.md" ]; then
      title=$(spec_title "$root/$id/spec.md")
    else
      missing="spec.md"
    fi
    [ -f "$root/$id/roadmap.md" ] || missing="${missing:+$missing, }roadmap.md"
    if [ -n "$missing" ]; then
      state="incomplete (no $missing)"
    else
      state=$(spec_list_state "$root/$id/roadmap.md")
    fi
    [ -n "$title" ] || title="-"
    # A tab cannot occur in any field: ids exclude it, and a heading is one
    # line whose tabs are folded to spaces here.
    title=$(printf '%s' "$title" | tr '\t' ' ')
    printf '%s\t%s\t%s\n' "$id" "$title" "$state"
  done < <(spec_ids)
}

# spec_list_state <roadmap.md> — what `spec list` says about a spec's progress.
#
# The roadmap of a spec with an open epic is edited only on the epic, so its
# copy anywhere else is stale by design: off the epic the line names where
# progress is instead of showing old checkmarks as current. A finished epic's
# roadmap reaches the default branch with the epic, current again (ADR-0040).
spec_list_state() {
  local roadmap="$1" line branch here
  line=$(jig_spec_epic "$roadmap" 2>/dev/null) || line=""
  if [ -z "$line" ] || [ "${line##* }" = finished ]; then
    spec_progress "$roadmap"
    return 0
  fi
  branch=${line% *}
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$here" = "$branch" ]; then
    printf '%s (on %s)\n' "$(spec_progress "$roadmap")" "$branch"
  elif ! git check-ref-format --branch "$branch" >/dev/null 2>&1 \
       || [ -z "$(jig_base_ref "$branch")" ]; then
    printf '%s — branch missing\n' "$branch"
  else
    printf '%s — progress is on the epic\n' "$branch"
  fi
}

# spec_epic_status — one line per spec with an open epic, for `jig status`:
# where its work is, and how far the epic has fallen behind the default
# branch it is kept current with by merging (ADR-0040). Read-only; the refs
# are whatever this checkout last fetched.
spec_epic_status() {
  local root id line branch default base_ref epic_ref behind
  root=$(spec_dir)
  default=$(cfg git.base_branch main)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -f "$root/$id/roadmap.md" ] || continue
    line=$(jig_spec_epic "$root/$id/roadmap.md" 2>/dev/null) || continue
    [ -n "$line" ] || continue
    [ "${line##* }" = open ] || continue
    branch=${line% *}
    epic_ref=""
    if git check-ref-format --branch "$branch" >/dev/null 2>&1; then
      epic_ref=$(jig_base_ref "$branch")
    fi
    if [ -z "$epic_ref" ]; then
      printf 'epic: %s on %s, branch missing\n' "$id" "$branch"
      continue
    fi
    base_ref=$(jig_base_ref "$default")
    if [ -z "$base_ref" ]; then
      printf 'epic: %s on %s\n' "$id" "$branch"
      continue
    fi
    behind=$(git -C "$JIG_PROJECT" rev-list --count "$epic_ref..$base_ref" 2>/dev/null) || behind=""
    if [ -n "$behind" ]; then
      printf 'epic: %s on %s, %s commits behind %s\n' "$id" "$branch" "$behind" "$default"
    else
      printf 'epic: %s on %s\n' "$id" "$branch"
    fi
  done < <(spec_ids)
}

# --- phase plan ------------------------------------------------------------------

# spec_plan <id> --phase <n> [--format text|tsv] — which tasks of a roadmap
# phase may start now, for a phase run and the person watching it.
#
# A phase run follows the waves strictly: wave N starts only once every item
# of every earlier wave has merged, whichever phase the item belongs to — the
# waves are one numbered list over the whole roadmap, and `after:` is prose
# nobody parses. Read-only and offline: the roadmap from where
# spec_roadmap_ref says it is current, each filed item's task from its
# workspace `state` (spec_task_state), and whether its work merged only from
# what is already answered — a checked item, a closed task (ADR-0030 closes a
# task only after its change landed), or `remote=merged` in the newest run of
# the housekeeping log. No fetch, no forge call.
#
# `--format tsv` is the machine form a coordinator reads, one row per line:
#   parallel <limit> <building>
#   wave    <n> <merged|open|waiting>
#   item    <wave|-> <task-id|-> <state> <merged> <paused> <autopilot> <next> <title>
#   blocker <wave> <task-id|-> <state> <title>
#   problem <wave|-> <unmatched|ambiguous|repeated> <wave entry>
# The `parallel` row comes first; each `wave` row is followed by its items;
# items of the phase in no wave come after the waves, then the unmerged items
# of earlier waves that hold the phase's first waiting wave, then every problem
# of the waves list.
#
# `parallel` answers how many more tasks of the open wave a coordinator may
# start: <limit> is `autopilot.parallel` and <building> counts the open wave's
# tasks an agent is still building (run `on`, knowledge not consolidated).
# Plan answers "what may start now", and the limit is part of that answer, so
# no reader of it counts slots itself. An `autopilot.parallel` no reader
# understands answers 1 here — the safest count a report can name without
# refusing to report. `jig config set` never writes such a value, so only a
# hand-edited local file can hold one, and `jig status`'s `config.local:`
# line shows it as it stands.
# <state>: not-filed, fog, no-workspace, not-started, active, ready,
# consolidated, abandoned, done (checked, no workspace here). <merged>: roadmap,
# closed, housekeeping or no. <next>: start, running, file, fog, find,
# abandoned, wait, unscheduled, done.
spec_plan() {
  local id="" phase="" format=text
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        [ $# -ge 2 ] || jig_die "spec plan: --phase requires a value"
        phase="$2"
        shift 2
        ;;
      --format)
        [ $# -ge 2 ] || jig_die "spec plan: --format requires a value"
        format="$2"
        shift 2
        ;;
      -*) jig_die "spec plan: unknown argument: $1" ;;
      *)
        [ -z "$id" ] || jig_die "spec plan: unexpected argument: $1"
        id="$1"
        shift
        ;;
    esac
  done
  [ -n "$id" ] || jig_die "spec plan: missing spec id (usage: jig spec plan <id> --phase <n> [--format text|tsv])"
  spec_valid_id "$id" || jig_die "spec plan: invalid spec id: $id"
  [ -n "$phase" ] || jig_die "spec plan: missing --phase <n>"
  case "$phase" in
    *[!0-9]*) jig_die "spec plan: --phase takes a phase number: $phase" ;;
  esac
  case "$format" in
    text | tsv) ;;
    *) jig_die "spec plan: --format is text or tsv: $format" ;;
  esac
  jig_require_init

  local roadmap rel loc ref="" source text parsed epic
  roadmap="$(spec_dir)/$id/roadmap.md"
  rel="$JIG_AI_DIR/specs/$id/roadmap.md"
  [ -f "$roadmap" ] || jig_die "spec plan: no such spec, or it has no roadmap: $rel"
  local lrc=0
  loc=$(spec_roadmap_ref "$id") || lrc=$?
  if [ "$lrc" -ne 0 ]; then
    epic=$(jig_spec_epic "$roadmap" 2>/dev/null) || epic=""
    [ "$lrc" -ne 2 ] || jig_die "spec plan: git rejects the epic branch name ${epic% *} in $rel"
    jig_die "spec plan: $id is built on ${epic% *}, which this checkout has no branch of; fetch it first"
  fi
  source="$rel"
  if [ -n "$loc" ]; then
    IFS=$'\t' read -r ref source <<LOC
$loc
LOC
    text=$(jig_git_show_path "$ref" "$rel" 2>/dev/null) \
      || jig_die "spec plan: $source has no $rel"
  else
    text=$(cat "$roadmap") || jig_die "spec plan: cannot read $rel"
  fi

  parsed=$(printf '%s\n' "$text" | _spec_plan_parse)
  # No reader here stops before the end of its input: bash writes a pipe line
  # by line, and under pipefail the SIGPIPE a reader that quit early leaves
  # printf with fails the check now and then (conventions/shell.md).
  case $'\n'"$parsed"$'\n' in
    *$'\n'waves$'\n'*) ;;
    *) jig_die "spec plan: $source has no \`## Waves\` list; a phase run starts tasks by wave" ;;
  esac
  local title
  title=$(printf '%s\n' "$parsed" | awk -F '\t' -v p="$phase" '$1 == "phase" && $2 + 0 == p + 0 && !f { print $3; f = 1 }')
  printf '%s\n' "$parsed" | awk -F '\t' -v p="$phase" '$1 == "phase" && $2 + 0 == p + 0 { f = 1 } END { exit !f }' \
    || jig_die "spec plan: $source has no Phase $phase"

  local rows limit
  # A report never refuses over a setting it only quotes: an autopilot.parallel
  # no reader understands answers 1, the safest count. `jig config set`
  # validates before writing, so only a hand-edited local file reaches this.
  limit=$(jig_autopilot_parallel) || limit=1
  rows=$(printf '%s\n' "$parsed" | _spec_plan_enrich \
    | JIG_SP_PHASE="$phase" JIG_SP_PARALLEL="$limit" _spec_plan_decide)
  if [ "$format" = tsv ]; then
    [ -z "$rows" ] || printf '%s\n' "$rows"
    return 0
  fi
  printf '%s\n' "$rows" | JIG_SP_PHASE="$phase" JIG_SP_TITLE="$title" JIG_SP_SOURCE="$source" _spec_plan_text
}

# _spec_plan_parse — the roadmap on stdin as rows, all phases:
#   phase   <n> <title>
#   waves                         (the `## Waves` heading is there)
#   wave    <n>                   (every numbered wave, in listed order)
#   item    <phase|-> <wave|-> <checked 0|1> <task-id|-> <filed|fog|plain> <title>
#   problem <wave> <unmatched|ambiguous|repeated> <entry>
#
# Items and headings follow spec_phase_counts' grammar; an item's indented
# lines that follow it are part of its text. A wave line is `<n>. ` and its
# entries are separated by `;`. An entry names an item when it equals the
# item's title — its text without the leading `` `task-id` — `` or `fog:`, up
# to the first dash with a space on each side (`—`, `--`, `-`) or ` (after:` —
# ignoring case, backticks and runs of spaces, or when it equals the item's
# task id, backticked or not. An entry that names no item, or more than one,
# is a problem, and so is an item two entries name: that item is placed in no
# wave rather than in a guessed one. `<…>` template placeholders are skipped.
_spec_plan_parse() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function norm(s) { gsub(/`/, "", s); gsub(/[[:space:]]+/, " ", s); return tolower(trim(s)) }
    function clean(s) { gsub(/\t/, " ", s); s = trim(s); return (s == "" ? "-" : s) }
    function end_item(   t, tid, kind) {
      if (!cur) return
      t = itext[cur]; kind = "plain"; tid = ""
      if (t ~ /^`[A-Za-z0-9._-]+`[[:space:]]+(—|--|-)[[:space:]]/) {
        tid = substr(t, 2); sub(/`.*$/, "", tid)
        # The same grammar as jig_valid_id: no leading dot or dash.
        if (tid ~ /^[.-]/) tid = ""
        else { sub(/^`[^`]*`[[:space:]]+(—|--|-)[[:space:]]+/, "", t); kind = "filed" }
      } else if (t ~ /^fog:/) {
        sub(/^fog:[[:space:]]*/, "", t); kind = "fog"
      }
      if (match(t, /[[:space:]]\(after:/)) t = substr(t, 1, RSTART - 1)
      if (match(t, /[[:space:]](—|--|-)[[:space:]]/)) t = substr(t, 1, RSTART - 1)
      iid[cur] = tid; ikind[cur] = kind; ititle[cur] = clean(t); inorm[cur] = norm(t)
      cur = 0
    }
    function end_wave(   parts, m, j, e) {
      if (wn == "") return
      m = split(wtext, parts, ";")
      for (j = 1; j <= m; j++) {
        e = trim(parts[j]); sub(/\.$/, "", e); e = trim(e)
        if (e == "" || e ~ /^</) continue
        ne++; went[ne] = e; ewave[ne] = wn
      }
      wn = ""
    }
    BEGIN { phase = "-"; OFS = "\t" }
    /^##[[:space:]]/ {
      end_item(); end_wave()
      h = $0
      sub(/^##[[:space:]]+/, "", h)
      gsub(/\t/, " ", h)
      inwaves = 0
      if (h ~ /^Phase[[:space:]]+[0-9]+/) {
        sub(/^Phase[[:space:]]+/, "", h)
        phase = h
        sub(/[^0-9].*$/, "", phase)
        phase = phase + 0
        sub(/^[0-9]+[[:space:]]*/, "", h)
        sub(/^(—|--|-|:)[[:space:]]*/, "", h)
        print "phase", phase, clean(h)
      } else {
        phase = "-"
        if (h ~ /^Waves[[:space:]]*$/) { inwaves = 1; print "waves" }
      }
      next
    }
    /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ {
      end_item(); end_wave()
      t = $0
      sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/, "", t)
      if (t ~ /^</) next
      n++; cur = n
      iphase[n] = phase; ichecked[n] = ($0 ~ /\[[xX]\]/) ? 1 : 0; itext[n] = t
      next
    }
    inwaves && /^[0-9]+\.[[:space:]]/ {
      end_item(); end_wave()
      wn = $0; sub(/\..*$/, "", wn); wn = wn + 0
      if (!(wn in seenw)) { seenw[wn] = 1; nw++; worder[nw] = wn }
      wtext = $0; sub(/^[0-9]+\.[[:space:]]*/, "", wtext)
      next
    }
    /^[[:space:]]+[^[:space:]]/ {
      if (cur) { itext[cur] = itext[cur] " " trim($0); next }
      if (wn != "") { wtext = wtext " " trim($0); next }
    }
    { end_item(); end_wave() }
    END {
      end_item(); end_wave()
      for (k = 1; k <= nw; k++) print "wave", worder[k]
      for (k = 1; k <= ne; k++) {
        e = went[k]; eid = e; gsub(/`/, "", eid); eid = trim(eid); en = norm(e)
        cnt = 0; hit = 0
        for (i = 1; i <= n; i++) {
          if ((iid[i] != "" && eid == iid[i]) || (inorm[i] != "" && en == inorm[i])) { cnt++; hit = i }
        }
        if (cnt == 0) { print "problem", ewave[k], "unmatched", clean(e); continue }
        if (cnt > 1) { print "problem", ewave[k], "ambiguous", clean(e); continue }
        if (!(hit in first)) { first[hit] = k; continue }
        if (!(hit in rep)) { rep[hit] = 1; print "problem", ewave[first[hit]], "repeated", clean(went[first[hit]]) }
        print "problem", ewave[k], "repeated", clean(e)
      }
      for (i = 1; i <= n; i++) {
        w = ((i in first) && !(i in rep)) ? ewave[first[i]] : "-"
        print "item", iphase[i], w, ichecked[i], (iid[i] == "" ? "-" : iid[i]), ikind[i], ititle[i]
      }
    }
  '
}

# _spec_plan_enrich — the parsed rows on stdin, each `item` row replaced by
#   item <phase> <wave> <task-id|-> <state> <merged> <paused> <autopilot> <building> <title>
# from the task's workspace in this checkout and the housekeeping log; every
# other row passes through. Workspaces are read, never written: `state` is
# `jig task`'s alone.
#
# <building> is 1 when an agent is still building this task — its run is `on`
# and its knowledge is not consolidated yet — and 0 otherwise. That is the
# slot `autopilot.parallel` counts: a task whose work is consolidated and only
# waiting its turn to ship holds none
# (adr-20260922-a-phase-run-is-coordinated). The field is internal to this
# pipeline; _spec_plan_decide folds it into the `parallel` row and prints the
# item row spec_plan documents.
_spec_plan_enrich() {
  local merged_ids line iphase wave checked tid ikind ititle
  local state merged paused autopilot building tdir st
  merged_ids=" $(_spec_plan_hk_merged | tr '\n' ' ') "
  while IFS= read -r line; do
    case "$line" in
      item$'\t'*) ;;
      *) printf '%s\n' "$line"; continue ;;
    esac
    IFS=$'\t' read -r _ iphase wave checked tid ikind ititle <<ROW
$line
ROW
    state="" merged=no paused=false autopilot=- building=0
    [ "$checked" != 1 ] || merged=roadmap
    if [ "$ikind" = fog ]; then
      state=fog
    elif [ "$tid" = - ]; then
      state=not-filed
      [ "$checked" != 1 ] || state="done"
    else
      tdir=$(spec_task_dir "$tid") || tdir=""
      if [ -n "$tdir" ] && [ -f "$tdir/state" ]; then
        st=$(spec_task_state "$tdir" status)
        state=${st:-unknown}
        if [ "$st" = active ] \
           && { [ -z "$(spec_task_state "$tdir" branch)" ] || [ -z "$(spec_task_state "$tdir" base_commit)" ]; }; then
          state=not-started
        fi
        if [ "$(spec_task_state "$tdir" paused)" = true ]; then
          paused=true
        fi
        autopilot=$(spec_task_state "$tdir" autopilot)
        [ -n "$autopilot" ] || autopilot=-
        if [ "$autopilot" = on ] && [ "$(spec_task_state "$tdir" knowledge_consolidated)" != true ]; then
          building=1
        fi
        if [ "$merged" = no ] && [ "$st" = consolidated ]; then
          merged=closed
        fi
      else
        state=no-workspace
        [ "$checked" != 1 ] || state="done"
      fi
      if [ "$merged" = no ]; then
        case "$merged_ids" in
          *" $tid "*) merged=housekeeping ;;
        esac
      fi
    fi
    printf 'item\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$iphase" "$wave" "$tid" "$state" "$merged" "$paused" "$autopilot" "$building" "$ititle"
  done
}

# _spec_plan_hk_merged — the task ids the newest housekeeping run found merged
# into their base (`remote=merged` on a task line after the last `--- run`
# marker; domains/housekeeping documents the log's line shape). Nothing when
# housekeeping never ran here.
_spec_plan_hk_merged() {
  local log="$JIG_PROJECT/$JIG_AI_DIR/runtime/housekeeping.log"
  [ -f "$log" ] || return 0
  awk '
    # split("", seen) clears the array portably.
    /^--- run / { split("", seen); n = 0; next }
    / remote=merged( |$)/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^task=/) {
          id = substr($i, 6)
          if (!(id in seen)) { seen[id] = 1; ids[++n] = id }
        }
      }
    }
    END { for (i = 1; i <= n; i++) print ids[i] }
  ' "$log"
}

# _spec_plan_decide — the enriched rows on stdin, the phase in JIG_SP_PHASE and
# the slot limit in JIG_SP_PARALLEL; prints the TSV spec_plan documents. A wave
# is merged when every item in it merged and none of its entries is a problem;
# it is open when every wave numbered below it is merged. Only an open wave's
# items may start, and at most one wave is open and not merged at a time — the
# `parallel` row counts the agents building that wave's tasks. It counts them
# whatever phase they belong to: the waves are one list over the whole roadmap,
# and an agent building a neighbouring phase's task holds a slot on the same
# machine.
_spec_plan_decide() {
  awk -F '\t' '
    BEGIN { OFS = "\t"; want = ENVIRON["JIG_SP_PHASE"] + 0; limit = ENVIRON["JIG_SP_PARALLEL"] + 0 }
    $1 == "wave" { w = $2 + 0; if (!(w in known)) { known[w] = 1; nw++; wl[nw] = w }; next }
    $1 == "problem" { np++; pr[np] = $0; if ($2 != "-") bad[$2 + 0] = 1; next }
    $1 == "item" {
      n++; ph[n] = $2; wv[n] = $3; id[n] = $4; st[n] = $5; mg[n] = $6; pa[n] = $7; ap[n] = $8; bd[n] = $9; ti[n] = $10
      if (wv[n] != "-" && mg[n] == "no") unmerged[wv[n] + 0] = 1
      next
    }
    function next_of(i,   w) {
      if (mg[i] != "no") return "done"
      if (wv[i] == "-") return "unscheduled"
      w = wv[i] + 0
      if (!open[w]) return "wait"
      if (st[i] == "fog") return "fog"
      if (st[i] == "not-filed") return "file"
      if (st[i] == "no-workspace") return "find"
      if (st[i] == "not-started") return "start"
      if (st[i] == "abandoned") return "abandoned"
      return "running"
    }
    function item_row(i) { print "item", wv[i], id[i], st[i], mg[i], pa[i], ap[i], next_of(i), ti[i] }
    END {
      # Waves in ascending order: a plain insertion sort, the list is short.
      for (a = 2; a <= nw; a++) { v = wl[a]; for (b = a - 1; b >= 1 && wl[b] > v; b--) wl[b + 1] = wl[b]; wl[b + 1] = v }
      prev = 1
      for (a = 1; a <= nw; a++) {
        w = wl[a]
        merged[w] = !(w in unmerged) && !(w in bad)
        open[w] = prev
        if (!merged[w]) prev = 0
      }
      building = 0
      for (a = 1; a <= nw; a++) {
        w = wl[a]
        if (merged[w] || !open[w]) continue
        for (i = 1; i <= n; i++) if (wv[i] != "-" && wv[i] + 0 == w && bd[i] + 0 == 1) building++
      }
      print "parallel", limit, building
      firstwait = ""
      for (a = 1; a <= nw; a++) {
        w = wl[a]; has = 0
        for (i = 1; i <= n; i++) if (ph[i] != "-" && ph[i] + 0 == want && wv[i] != "-" && wv[i] + 0 == w) has = 1
        if (!has) continue
        wstate = merged[w] ? "merged" : (open[w] ? "open" : "waiting")
        if (wstate == "waiting" && firstwait == "") firstwait = w
        print "wave", w, wstate
        for (i = 1; i <= n; i++) if (ph[i] != "-" && ph[i] + 0 == want && wv[i] != "-" && wv[i] + 0 == w) item_row(i)
      }
      for (i = 1; i <= n; i++) if (ph[i] != "-" && ph[i] + 0 == want && wv[i] == "-") item_row(i)
      if (firstwait != "") {
        for (a = 1; a <= nw && wl[a] < firstwait; a++) {
          w = wl[a]
          for (i = 1; i <= n; i++)
            if (wv[i] != "-" && wv[i] + 0 == w && mg[i] == "no") print "blocker", w, id[i], st[i], ti[i]
        }
      }
      for (k = 1; k <= np; k++) print pr[k]
    }
  '
}

# _spec_plan_text — the TSV on stdin for a person: the phase, each wave with
# its items, what earlier waves still hold, the problems, and what may start.
_spec_plan_text() {
  awk -F '\t' '
    function label(s, p, a, m,   l) {
      l = s
      if (s == "not-filed") l = "not filed"
      else if (s == "no-workspace") l = "no workspace here"
      else if (s == "not-started") l = "not started"
      if (m == "housekeeping") l = l ", merged"
      if (p == "true") l = l ", paused"
      if (a != "-") l = l ", autopilot " a
      return l
    }
    function pad(s, w) { while (length(s) < w) s = s " "; return s }
    { row[NR] = $0 }
    $1 == "item" { l = label($4, $6, $7, $5); if (length($3) > wid) wid = length($3); if (length(l) > wl) wl = length(l); if (length($8) > wn) wn = length($8) }
    $1 == "blocker" { l = label($4, "false", "-", "no"); if (length($3) > bid) bid = length($3); if (length(l) > bl) bl = length(l) }
    END {
      t = ENVIRON["JIG_SP_TITLE"]
      printf "Phase %s%s\n", ENVIRON["JIG_SP_PHASE"], (t == "" || t == "-") ? "" : " — " t
      printf "roadmap: %s\n", ENVIRON["JIG_SP_SOURCE"]
      items = 0; loose = 0; blockers = 0; start = ""; file = ""; limit = 0; building = 0
      for (r = 1; r <= NR; r++) {
        split(row[r], f, "\t")
        if (f[1] == "parallel") { limit = f[2] + 0; building = f[3] + 0 }
        else if (f[1] == "wave") printf "wave %s — %s\n", f[2], f[3]
        else if (f[1] == "item") {
          items++
          if (f[2] == "-" && !loose) { print "not in any wave:"; loose = 1 }
          printf "  %s  %s  %s  %s\n", pad(f[3], wid), pad(label(f[4], f[6], f[7], f[5]), wl), pad(f[8], wn), f[9]
          if (f[8] == "start") start = start (start == "" ? "" : ", ") f[3]
          if (f[8] == "file") file = file (file == "" ? "" : "; ") f[9]
        } else if (f[1] == "blocker") {
          if (!blockers) print "waiting on earlier waves:"
          blockers++
          printf "  wave %s  %s  %s  %s\n", f[2], pad(f[3], bid), pad(label(f[4], "false", "-", "no"), bl), f[5]
        } else if (f[1] == "problem") {
          why = (f[3] == "unmatched") ? "names no roadmap item" : (f[3] == "ambiguous") ? "names more than one roadmap item" : "names an item another wave entry names too"
          printf "problem: wave %s entry \"%s\" %s\n", f[2], f[4], why
        }
      }
      if (!items) print "no items in this phase"
      free = limit - building
      if (free < 0) free = 0
      printf "may start now: %s (%d of %d slots free)\n", (start == "" ? "none" : start), free, limit
      if (file != "") printf "to file first: %s\n", file
    }
  '
}

# --- epic branches ---------------------------------------------------------------

# spec_epic <id> [--finish | --reopen] — the epic branch of a spec released
# once, at the end (ADR-0040).
#
# Without a flag: declare the epic with an `Epic: epic/<id>` line when the
# roadmap has none, and stop — the line has to reach the default branch before
# the epic is cut from it, or neither the epic nor a checkout of the default
# branch would know where the spec's tasks go. With the line on the freshest
# default branch, cut `epic/<id>` there, without a checkout; pushing it is the
# human's step. `--finish`, on the epic after the default branch was merged
# into it, closes the line before the final pull request; `--reopen` takes
# that back when review of the final pull request needs a fix.
spec_epic() {
  [ $# -ge 1 ] || jig_die "spec epic: missing spec id (usage: jig spec epic <id> [--release <level> | --finish | --reopen])"
  local id="$1" mode=declare handled=0 release=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --finish) [ "$mode" = declare ] || jig_die "spec epic: --finish and --reopen exclude each other"; mode=finish ;;
      --reopen) [ "$mode" = declare ] || jig_die "spec epic: --finish and --reopen exclude each other"; mode=reopen ;;
      --leftovers-handled) handled=1 ;;
      --release)
        [ $# -ge 2 ] || jig_die "spec epic: --release requires a value (patch|minor|major)"
        release="$2"
        shift ;;
      *) jig_die "spec epic: unexpected argument: $1" ;;
    esac
    shift
  done
  spec_valid_id "$id" || jig_die "spec epic: invalid spec id: $id"
  [ "$handled" -eq 0 ] || [ "$mode" = finish ] || jig_die "spec epic: --leftovers-handled goes with --finish"
  [ -z "$release" ] || [ "$mode" = declare ] || jig_die "spec epic: --release goes with declaring the epic, not with --finish or --reopen"
  [ -z "$release" ] || spec_release_valid "$release" \
    || jig_die "spec epic: invalid release level: $release (expected patch|minor|major)"
  jig_require_init
  if [ "$mode" = reopen ]; then
    spec_epic_reopen "$id"
    return 0
  fi
  local roadmap rel line rc=0
  roadmap="$(spec_dir)/$id/roadmap.md"
  rel="$JIG_AI_DIR/specs/$id/roadmap.md"
  [ -f "$roadmap" ] || jig_die "spec epic: no such spec, or it has no roadmap: $rel"
  line=$(jig_spec_epic "$roadmap") || rc=$?
  [ "$rc" -ne 2 ] || jig_die "spec epic: $rel declares more than one epic; keep one Epic: line"
  spec_release_check "spec epic" "$rel" < "$roadmap" >/dev/null

  case "$mode" in
    declare) spec_epic_declare "$id" "$roadmap" "$rel" "$line" "$release" ;;
    finish) spec_epic_finish "$id" "$roadmap" "$rel" "$line" "$handled" ;;
  esac
}

spec_epic_declare() {
  local id="$1" roadmap="$2" rel="$3" line="$4" release="${5:-}" branch default start commit on_default rc=0
  if [ -z "$line" ]; then
    branch="epic/$id"
    git check-ref-format --branch "$branch" >/dev/null 2>&1 \
      || jig_die "spec epic: git rejects the branch name: $branch"
    spec_epic_write "$roadmap" "declare" "$branch" "$release"
    printf '%s: Epic: %s\n' "$rel" "$branch"
    [ -z "$release" ] || printf '%s: Release: %s\n' "$rel" "$release"
    jig_info "spec epic: $(spec_ship_hint declare "$id" "$branch" "$rel")"
    return 0
  fi
  [ -z "$release" ] || jig_die "spec epic: $rel declares ${line% *} already; the release level is recorded when the epic is declared — edit its Release: line instead"
  branch=${line% *}
  [ "${line##* }" = open ] || jig_die "spec epic: $rel marks epic $branch finished, as an older jig did; a finished epic's spec is removed now — delete the spec, or drop \"— finished\" to reopen it"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || jig_die "spec epic: git rejects the branch name: $branch"
  if [ -n "$(jig_base_ref "$branch")" ]; then
    printf 'exists: %s\n' "$branch"
    return 0
  fi

  default=$(cfg git.base_branch main)
  jig_fetch_branches "spec epic" "$default"
  # Checked again after the fetch: the epic may have been pushed by somebody
  # else since this checkout last looked.
  jig_fetch_branches "spec epic" "$branch" 2>/dev/null
  if [ -n "$(jig_base_ref "$branch")" ]; then
    printf 'exists: %s\n' "$branch"
    return 0
  fi
  start=$(jig_fresh_base_ref "$default" "spec epic") || exit 1
  [ "$start" != HEAD ] || jig_die "spec epic: $default exists neither here nor on origin"
  commit=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$start^{commit}" 2>/dev/null) \
    || jig_die "spec epic: cannot resolve $start"
  on_default=$(jig_git_show_path "$commit" "$rel" 2>/dev/null | jig_spec_epic -) || rc=$?
  if [ "$rc" -ne 0 ] || [ "$on_default" != "$branch open" ]; then
    jig_die "spec epic: the Epic: line of $rel is not on $default yet; merge it into $default first"
  fi
  git -C "$JIG_PROJECT" branch "$branch" "$commit" >/dev/null 2>&1 \
    || jig_die "spec epic: could not create $branch"
  printf 'created: %s at %s\n' "$branch" "$commit"
  jig_info "spec epic: $(spec_ship_hint cut "$id" "$branch" "$rel")"
}

spec_epic_finish() {
  local id="$1" roadmap="$2" rel="$3" line="$4" handled="$5" branch here default start
  [ -n "$line" ] || jig_die "spec epic: $rel declares no epic"
  branch=${line% *}
  [ "${line##* }" = open ] || jig_die "spec epic: $rel marks epic $branch finished, as an older jig did; drop \"— finished\" from the line, then run --finish again"
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$here" = "$branch" ] || jig_die "spec epic: --finish runs on $branch; switch to it first"
  default=$(cfg git.base_branch main)
  jig_fetch_branches "spec epic" "$default"
  start=$(jig_fresh_base_ref "$default" "spec epic") || exit 1
  if [ "$start" != HEAD ] \
     && ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$start" HEAD 2>/dev/null; then
    jig_die "spec epic: $branch does not contain the latest $default; merge $default into it first"
  fi
  # The spec leaves with the epic's final pull request: its decisions are in
  # knowledge by now, and what is not is decided by a human first.
  local release
  release=$(spec_release_check "spec epic" "$rel" < "$roadmap") || exit 1
  spec_close_dir "$id" "spec epic" "$handled"
  # The level the version is raised by in this commit, as recorded when the
  # epic was declared; the rule that picks one when none was is the caller's.
  printf 'release: %s\n' "${release:-not recorded}"
  jig_info "spec epic: $(spec_ship_hint finish "$id" "$branch" "$rel")"
}

# spec_epic_reopen <id> — bring back the spec `--finish` removed, on its epic,
# when review of the final pull request needs a fix: fixes are ordinary tasks,
# and a task finds its epic through the spec. Restored from git, never from
# trash, which is local and expires: from HEAD while the removal is not
# committed, else from the commit before the one that deleted the roadmap.
# Files are written with `git show`, so the index is left alone.
spec_epic_reopen() {
  local id="$1" dir rel roadmap src del line rc=0 branch here path
  dir="$(spec_dir)/$id"
  rel="$JIG_AI_DIR/specs/$id"
  roadmap="$rel/roadmap.md"
  [ ! -e "$dir" ] || jig_die "spec epic: $rel is here; --reopen restores a spec that --finish removed"
  if git -C "$JIG_PROJECT" cat-file -e "HEAD:$roadmap" 2>/dev/null; then
    src=HEAD
  else
    del=$(git -C "$JIG_PROJECT" log -1 --diff-filter=D --format=%H -- "$roadmap" 2>/dev/null) || del=""
    [ -n "$del" ] || jig_die "spec epic: no removed spec $id in the history of this branch"
    src="$del^"
  fi
  line=$(jig_git_show_path "$src" "$roadmap" 2>/dev/null | jig_spec_epic -) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$line" ]; then
    jig_die "spec epic: the removed $roadmap declares no epic"
  fi
  branch=${line% *}
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$here" = "$branch" ] || jig_die "spec epic: --reopen runs on $branch; switch to it first"
  # Restored into a directory of its own first and moved into place whole: a
  # failure halfway must not leave a partial spec that the "is here" check
  # would then refuse to restore over. A partial copy goes to trash, not to
  # `rm`: scripts delete nothing outside workspaces and trash (RULES.md). Only
  # paths under the spec's own directory are listed, so none lands elsewhere.
  local tmp sub
  tmp="$dir.restore.$$"
  mkdir "$tmp" || jig_die "spec epic: cannot create $tmp"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    sub=${path#"$rel/"}
    if ! mkdir -p "$tmp/$(dirname "$sub")" \
       || ! jig_git_show_path "$src" "$path" > "$tmp/$sub"; then
      spec_trash_partial "$tmp" "$id"
      jig_die "spec epic: could not restore $path"
    fi
  done < <(git -C "$JIG_PROJECT" ls-tree -r --name-only "$src" -- "$rel/")
  if ! mv "$tmp" "$dir"; then
    spec_trash_partial "$tmp" "$id"
    jig_die "spec epic: could not move the restored spec into $rel"
  fi
  printf 'restored: %s from %s\n' "$rel" "$(git -C "$JIG_PROJECT" rev-parse --short "$src")"
  jig_info "spec epic: fix it with ordinary tasks, then run \`jig spec epic $id --finish\` again"
}

# spec_trash_partial <dir> <id> — move a partial restore out of the way, to
# trash; best effort, the caller dies either way.
spec_trash_partial() {
  local dest
  dest=$(jig_trash_dest "spec-$2-restore")
  if mkdir -p "${dest%/*}" 2>/dev/null; then
    mv "$1" "$dest" 2>/dev/null || true
  fi
}

# --- release level ----------------------------------------------------------------

# spec_release_valid <level> — patch, minor or major.
spec_release_valid() {
  case "$1" in patch | minor | major) return 0 ;; *) return 1 ;; esac
}

# spec_release_check <who> <rel> — read a roadmap on stdin and print the level
# its `Release:` line records, or nothing when it has none. The line says how
# far the epic's final pull request raises the version; it is recorded when
# the epic is declared, while the human still answers (jig-idea §8), so an
# unattended run never has to guess a release a human would have chosen.
# Every line starting with `Release:` counts, so a line with a typo or a
# trailing remark is refused instead of silently read as "not recorded". Dies
# on a value other than patch|minor|major and on two lines that disagree.
spec_release_check() {
  local who="$1" rel="$2" out rc=0
  out=$(awk '
    /^Release:/ {
      v = $0
      sub(/^Release:[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v !~ /^(patch|minor|major)$/) { print v; bad = 1; exit }
      if (found == "") found = v
      else if (found != v) conflict = 1
    }
    END {
      if (bad) exit 1
      if (conflict) exit 2
      if (found != "") print found
    }') || rc=$?
  case "$rc" in
    0) [ -z "$out" ] || printf '%s\n' "$out" ;;
    2) jig_die "$who: $rel records more than one release level; keep one Release: line" ;;
    *) jig_die "$who: $rel records an invalid release level: ${out:-(empty)} (expected Release: patch|minor|major)" ;;
  esac
}

# --- shipping spec work (adr-20260922-spec-work-ships-by-the-agent-git-level) -----

# spec_ship_level — agent.git for the next-step lines `spec epic` prints: an
# invalid value reads as `none` here, because only `spec ship` may refuse it.
spec_ship_level() {
  local level
  level=$(jig_agent_git 2>/dev/null) || level=none
  printf '%s\n' "$level"
}

# spec_ship_hint declare|cut|finish <id> <branch> <rel> — the step after
# `spec epic`, named by whose it is at this clone's agent.git level.
# shellcheck disable=SC2016 # the backticks are literal: they quote a command
spec_ship_hint() {
  local step="$1" id="$2" branch="$3" rel="$4" level default does
  level=$(spec_ship_level)
  default=$(cfg git.base_branch main)
  case "$step" in
    declare)
      case "$level" in
        commit) does="it commits; the push and the pull request into $default are yours" ;;
        push) does="it commits and pushes; the pull request into $default is yours" ;;
        pr | merge) does="it commits, pushes and opens the pull request into $default" ;;
        *)
          printf 'commit %s and merge it into %s, then run `jig spec epic %s` again to cut %s\n' "$rel" "$default" "$id" "$branch"
          return 0 ;;
      esac
      printf 'stage %s/ and run `jig spec ship %s` (agent.git: %s — %s); once it is merged into %s, run `jig spec epic %s` again to cut %s\n' \
        "${rel%/roadmap.md}" "$id" "$level" "$does" "$default" "$id" "$branch"
      ;;
    cut)
      case "$level" in
        push | pr | merge) printf 'push it with `jig spec ship %s`\n' "$id" ;;
        *) printf 'push it with `git push -u origin %s` — yours at agent.git: %s\n' "$branch" "$level" ;;
      esac
      ;;
    finish)
      case "$level" in
        commit) does="it commits; pushing $branch and the pull request into $default are yours" ;;
        push) does="it commits and pushes $branch; the pull request into $default is yours" ;;
        pr) does="it commits, pushes $branch and opens the pull request into $default" ;;
        merge) does="it commits, pushes $branch and opens the pull request into $default, and merges it once CI passed only in an unattended run" ;;
        *)
          printf 'commit the removal with the version bump, then open the pull request from %s into %s\n' "$branch" "$default"
          return 0 ;;
      esac
      printf 'stage the removal with the version bump and run `jig spec ship %s` (agent.git: %s — %s)\n' "$id" "$level" "$does"
      ;;
  esac
}

# spec_ship <id> [--message-file <file>] [--title <t>] [--body-file <file>]
#
# Carries spec work as far as `agent.git` allows, through the same git steps as
# `task ship` (jig_ship_*, common.sh). What to ship is read from the state of
# the checkout, never from a flag, and printed first as `mode: <mode>`:
#
# - declare — the spec is here and its Epic: line is not on the freshest
#   default branch yet (or it has no epic): commit what is staged, all of it
#   under the spec's own directory, on a branch of its own — `spec/<id>`,
#   switched to from the default branch — push it and open the pull request
#   into the default branch.
# - epic — the Epic: line is on the default branch and the epic exists here:
#   push it (after it was cut, or after the default branch was merged into it).
#   Commits nothing.
# - final — on the epic, with the spec removed by `spec epic --finish`: commit
#   the staged removal and version bump, push the epic, open its pull request
#   into the default branch — and at `merge`, in an unattended run only, merge
#   it (spec_ship_final).
#
# A declaration's pull request is never merged here, and outside an unattended
# run neither is the final one: that merge is the release. At `none` it exits
# 3, like `task ship`: the skill reads it as "the human's step".
spec_ship() {
  [ $# -ge 1 ] || jig_die "spec ship: missing spec id (usage: jig spec ship <id> [--message-file <file>] [--title <t>] [--body-file <file>])"
  local id="$1" message_file="" title="" body_file=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --message-file)
        [ $# -ge 2 ] || jig_die "spec ship: --message-file requires a value"
        message_file="$2"
        shift 2 ;;
      --title)
        [ $# -ge 2 ] || jig_die "spec ship: --title requires a value"
        title="$2"
        shift 2 ;;
      --body-file)
        [ $# -ge 2 ] || jig_die "spec ship: --body-file requires a value"
        body_file="$2"
        shift 2 ;;
      *) jig_die "spec ship: unexpected argument: $1" ;;
    esac
  done
  spec_valid_id "$id" || jig_die "spec ship: invalid spec id: $id"
  jig_require_init
  [ -z "$message_file" ] || [ -f "$message_file" ] || jig_die "spec ship: --message-file: no such file: $message_file"
  [ -z "$body_file" ] || [ -f "$body_file" ] || jig_die "spec ship: --body-file: no such file: $body_file"

  # Level first, before anything else changes (as `task ship`).
  local level
  level=$(jig_agent_git) || jig_die "spec ship: invalid agent.git: $level (expected none|commit|push|pr|merge)"
  if [ "$level" = none ]; then
    printf "spec ship: agent.git is none in this clone; committing, pushing and the pull request are the human's\n" >&2
    exit 3
  fi

  local dir rel roadmap here default line branch mode rc=0 start on_default
  dir="$(spec_dir)/$id"
  rel="$JIG_AI_DIR/specs/$id"
  roadmap="$rel/roadmap.md"
  default=$(cfg git.base_branch main)
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$here" ] || jig_die "spec ship: HEAD is detached; switch to a branch first"

  if [ -d "$dir" ]; then
    [ -f "$dir/roadmap.md" ] || jig_die "spec ship: $rel has no roadmap"
    line=$(jig_spec_epic "$dir/roadmap.md") || rc=$?
    [ "$rc" -ne 2 ] || jig_die "spec ship: $roadmap declares more than one epic; keep one Epic: line"
    spec_release_check "spec ship" "$roadmap" < "$dir/roadmap.md" >/dev/null
    mode=declare
    if [ -n "$line" ]; then
      branch=${line% *}
      [ "${line##* }" = open ] || jig_die "spec ship: $roadmap marks epic $branch finished, as an older jig did; a finished epic's spec is removed now"
      git check-ref-format --branch "$branch" >/dev/null 2>&1 \
        || jig_die "spec ship: git rejects the branch name: $branch"
      if [ "$here" = "$branch" ]; then
        mode=epic
      else
        jig_fetch_branches "spec ship" "$default"
        start=$(jig_fresh_base_ref "$default" "spec ship") || exit 1
        if [ "$start" != HEAD ]; then
          rc=0
          on_default=$(jig_git_show_path "$start" "$roadmap" 2>/dev/null | jig_spec_epic -) || rc=$?
          [ "$rc" -ne 0 ] || [ "$on_default" != "$branch open" ] || mode=epic
        fi
      fi
    fi
  else
    mode=final
    branch=$(spec_ship_removed_epic "$id") || exit 1
    [ "$here" = "$branch" ] \
      || jig_die "spec ship: $rel is not here; an epic's final pull request is shipped from $branch — switch to it first"
  fi

  printf 'mode: %s\n' "$mode"
  case "$mode" in
    declare) spec_ship_declare "$id" "$level" "$here" "$default" "$message_file" "$title" "$body_file" "$line" ;;
    epic) spec_ship_epic "$id" "$level" "$branch" ;;
    final) spec_ship_final "$id" "$level" "$branch" "$default" "$message_file" "$title" "$body_file" ;;
  esac
}

# spec_ship_removed_epic <id> — the epic a removed spec declared, read from git
# the way `epic --reopen` reads it: HEAD while the removal is not committed,
# else the commit before the one that deleted the roadmap. Dies when this
# branch never held the spec with an open Epic: line.
spec_ship_removed_epic() {
  local id="$1" roadmap src line rc=0
  roadmap="$JIG_AI_DIR/specs/$id/roadmap.md"
  src=$(spec_ship_removed_src "$id") || exit 1
  line=$(jig_git_show_path "$src" "$roadmap" 2>/dev/null | jig_spec_epic -) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$line" ] || [ "${line##* }" != open ]; then
    jig_die "spec ship: the removed $roadmap declares no open epic; only an epic's final pull request ships a removed spec"
  fi
  # Validated where it is read, as the release level the final PR carries.
  jig_git_show_path "$src" "$roadmap" 2>/dev/null | spec_release_check "spec ship" "$roadmap" >/dev/null || exit 1
  printf '%s\n' "${line% *}"
}

# spec_ship_removed_src <id> — the commit a removed spec is read from, as a
# hash: HEAD while its removal is not committed, else the commit before the
# one that deleted its roadmap. A hash, not `HEAD`: the final ship commits the
# removal and reads the roadmap again after that. Dies when this branch never
# held it.
spec_ship_removed_src() {
  local id="$1" roadmap del ref
  roadmap="$JIG_AI_DIR/specs/$id/roadmap.md"
  if git -C "$JIG_PROJECT" cat-file -e "HEAD:$roadmap" 2>/dev/null; then
    ref=HEAD
  else
    del=$(git -C "$JIG_PROJECT" log -1 --diff-filter=D --format=%H -- "$roadmap" 2>/dev/null) || del=""
    [ -n "$del" ] || jig_die "spec ship: no spec $id here, and none removed in the history of this branch"
    ref="$del^"
  fi
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null \
    || jig_die "spec ship: cannot resolve $ref"
}

# spec_ship_steps <level> <branch> <base> <message-file> <title> <body-file> [<draft>] —
# commit, push <branch>, open its pull request into <base>, stopping where
# <level> stops; the same steps and stop lines as `task ship`.
spec_ship_steps() {
  local level="$1" branch="$2" base="$3" message_file="$4" title="$5" body_file="$6" draft="${7:-0}"
  jig_ship_commit "spec ship" "$message_file"
  # The same order as `task ship` (common.sh, "what a ship may send out"):
  # a declaration and a final pull request both carry commits, and both are
  # refused here rather than on the forge.
  jig_ship_require_commits "spec ship" "$branch" "$base"
  if [ "$level" = commit ]; then
    printf "stopped at commit: push is the human's\n"
    return 0
  fi
  jig_ship_push "spec ship" "$branch"
  if [ "$level" = push ]; then
    printf "stopped at push: the pull request is the human's\n"
    return 0
  fi
  jig_ship_pr "spec ship" "$branch" "$base" "$message_file" "$title" "$body_file" "$draft"
}

spec_ship_declare() {
  local id="$1" level="$2" here="$3" default="$4" message_file="$5" title="$6" body_file="$7" line="$8"
  local rel branch p bad=""
  rel="$JIG_AI_DIR/specs/$id"
  [ -n "$message_file" ] || jig_die "spec ship: declaring commits; --message-file is required"
  case "$here" in
    epic/*) jig_die "spec ship: $here is an epic branch; the declaration goes into $default from a branch of its own" ;;
  esac
  jig_ship_check_staged "spec ship"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$rel/"*) ;;
      *) bad="$bad
$p" ;;
    esac
  done <<EOF
$(jig_ship_staged)
EOF
  bad=$(printf '%s\n' "$bad" | sed '/^$/d')
  if [ -n "$bad" ]; then
    jig_die "spec ship: a declaration commits only $rel/; staged outside it:
$bad"
  fi
  branch="$here"
  if [ "$here" = "$default" ]; then
    # Nothing is committed to the default branch: the declaration gets a
    # branch of its own, and the working tree and index come along unchanged.
    branch="spec/$id"
    git check-ref-format --branch "$branch" >/dev/null 2>&1 \
      || jig_die "spec ship: git rejects the branch name: $branch"
    if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
      jig_die "spec ship: $branch exists already; switch to it and run again"
    fi
    git -C "$JIG_PROJECT" switch --quiet -c "$branch" >/dev/null 2>&1 \
      || jig_die "spec ship: could not switch to a new branch $branch"
    printf 'switched to %s\n' "$branch"
  fi
  spec_ship_steps "$level" "$branch" "$default" "$message_file" "$title" "$body_file"
  [ -z "$line" ] || jig_info "spec ship: once $branch is merged into $default, run \`jig spec epic $id\` to cut ${line% *}"
}

spec_ship_epic() {
  local id="$1" level="$2" branch="$3"
  [ -z "$(jig_ship_staged)" ] \
    || jig_die "spec ship: pushing $branch commits nothing, and something is staged; commit it through a task or unstage it first"
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
    || jig_die "spec ship: $branch is not a local branch here; cut it with \`jig spec epic $id\`"
  if [ "$level" = commit ]; then
    printf "stopped at commit: pushing %s is the human's\n" "$branch"
    return 0
  fi
  # The one ship that sends no commit and means to: an epic is pushed so that
  # it exists on the forge for its tasks to target, and one cut an hour ago
  # has nothing of its own yet (common.sh, "what a ship may send out").
  jig_ship_sends_no_commit "an epic branch is pushed to exist, not to carry a change"
  jig_ship_push "spec ship" "$branch"
}

# The body file spec_ship_final writes for a draft; script-global because the
# EXIT trap that removes it runs after the function returned
# (conventions/shell.md). jig_ship_pr leaves the trap alone when it is given a
# body file, so this is the one EXIT trap of the process.
_SPEC_SHIP_BODY_TMP=""

# spec_ship_final — the epic's final pull request. At `merge`, in an unattended
# run (`autopilot.unattended`, the key itself: an epic finish belongs to no
# task's run), the merge is the agent's too
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci), and only
# after spec_ship_final_ready finds nothing left; the release level the
# roadmap recorded decides first: `major` is never released without a human —
# the pull request opens as a draft that says so — and no `Release:` line
# reads as `minor`. Anywhere else the merge is the human's, as it was.
spec_ship_final() {
  local id="$1" level="$2" branch="$3" default="$4" message_file="$5" title="$6" body_file="$7"
  local rel start src release draft=0 unattended=0
  rel="$JIG_AI_DIR/specs/$id"
  [ -n "$message_file" ] || jig_die "spec ship: the final pull request commits; --message-file is required"
  jig_fetch_branches "spec ship" "$default"
  start=$(jig_fresh_base_ref "$default" "spec ship") || exit 1
  # Checked again although --finish checked it: the default branch may have
  # moved between the finish and the ship.
  if [ "$start" != HEAD ] \
     && ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$start" HEAD 2>/dev/null; then
    jig_die "spec ship: $branch does not contain the latest $default; merge $default into it first"
  fi
  jig_ship_check_staged "spec ship"
  [ -z "$(git -C "$JIG_PROJECT" ls-files --cached -- "$rel/" 2>/dev/null)" ] \
    || jig_die "spec ship: the removal of $rel/ is not staged; stage it with the version bump first"

  src=$(spec_ship_removed_src "$id") || exit 1
  if [ "$level" = merge ] && jig_unattended; then
    unattended=1
    release=$(jig_git_show_path "$src" "$rel/roadmap.md" 2>/dev/null \
      | spec_release_check "spec ship" "$rel/roadmap.md") || exit 1
    if [ -z "$release" ]; then
      printf 'release: minor (no Release: line; the unattended default)\n'
    else
      printf 'release: %s\n' "$release"
    fi
    if [ "$release" = major ]; then
      draft=1
      _SPEC_SHIP_BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-spec-body.XXXXXX")
      trap '[ -z "${_SPEC_SHIP_BODY_TMP:-}" ] || rm -f "$_SPEC_SHIP_BODY_TMP"' EXIT
      {
        printf 'Needs a human: major release?\n\n'
        if [ -n "$body_file" ]; then cat "$body_file"; else tail -n +2 "$message_file"; fi
      } > "$_SPEC_SHIP_BODY_TMP"
      body_file="$_SPEC_SHIP_BODY_TMP"
    fi
  fi

  spec_ship_steps "$level" "$branch" "$default" "$message_file" "$title" "$body_file" "$draft"
  [ "$level" = merge ] || return 0
  if [ "$unattended" -eq 0 ]; then
    printf "not merged: the epic's final merge is the release, and outside an unattended run it is the human's\n"
    return 0
  fi
  if [ "$draft" -eq 1 ]; then
    printf 'not merged: a major release needs a human; the pull request is a draft\n'
    return 0
  fi
  local left
  left=$(spec_ship_final_ready "$id" "$branch" "$default" "$src")
  if [ -n "$left" ]; then
    printf 'not merged: %s\n' "$left"
    return 0
  fi
  jig_ship_merge "spec ship" "$JIG_SHIP_URL" "$(git -C "$JIG_PROJECT" rev-parse HEAD)" merge-commit
}

# spec_ship_final_ready <id> <branch> <default> <src> — what still stands in
# the way of merging the epic, as one line, or nothing: the epic behind the
# freshest default branch, the spec back on disk, a roadmap item left
# unchecked (fog is not an item: it is dropped with the spec, and the skill
# quotes it in the pull request), or a task cut from the epic whose branch is
# not in it. Read again right before the merge, not trusted from the finish.
spec_ship_final_ready() {
  local id="$1" branch="$2" default="$3" src="$4" start items tasks
  jig_fetch_branches "spec ship" "$default"
  start=$(jig_fresh_base_ref "$default" "spec ship") || exit 1
  if [ "$start" != HEAD ] \
     && ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$start" HEAD 2>/dev/null; then
    printf '%s does not contain the latest %s\n' "$branch" "$default"
    return 0
  fi
  if [ -e "$(spec_dir)/$id" ]; then
    printf 'the spec %s is on disk again\n' "$id"
    return 0
  fi
  items=$(jig_git_show_path "$src" "$JIG_AI_DIR/specs/$id/roadmap.md" 2>/dev/null | spec_unchecked_items)
  if [ -n "$items" ]; then
    printf 'the epic is not finished: %s roadmap item(s) unchecked, first: %s\n' \
      "$(printf '%s\n' "$items" | wc -l | tr -d ' ')" "${items%%$'\n'*}"
    return 0
  fi
  tasks=$(spec_epic_unmerged_tasks "$branch")
  if [ -n "$tasks" ]; then
    printf 'task(s) cut from %s not merged into it: %s\n' "$branch" "$(printf '%s\n' "$tasks" | tr '\n' ' ' | sed 's/ $//')"
    return 0
  fi
}

# spec_unchecked_items — read a roadmap on stdin and print each unchecked item
# that is real work: not a `fog:` item and not a template `<placeholder>`,
# the way spec_leftovers names them.
spec_unchecked_items() {
  awk '/^[[:space:]]*[-*][[:space:]]+\[ \]/ {
    t = $0; sub(/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/, "", t)
    if (t !~ /^</ && t !~ /^fog:/) print t
  }'
}

# spec_epic_unmerged_tasks <branch> — the ids of the tasks in this checkout's
# workspace cut from <branch> (base_branch) whose own branch is not in HEAD.
# An abandoned task, one never started, and one whose branch exists nowhere
# any more are not counted: there is nothing of theirs left to merge. A task
# merged by squash is counted — its commits are not in the epic, and saying
# so is the safe side.
spec_epic_unmerged_tasks() {
  local want="$1" root dir name state base tbranch status ref
  root="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  [ -d "$root" ] || return 0
  for dir in "$root"/*/; do
    name=${dir%/}
    name=${name##*/}
    jig_valid_id "$name" || continue
    state="$root/$name/state"
    [ -f "$state" ] || continue
    base=$(sed -n 's/^base_branch:[[:space:]]*//p' "$state" | head -n 1)
    [ "$base" = "$want" ] || continue
    status=$(sed -n 's/^status:[[:space:]]*//p' "$state" | head -n 1)
    [ "$status" != abandoned ] || continue
    tbranch=$(sed -n 's/^branch:[[:space:]]*//p' "$state" | head -n 1)
    [ -n "$tbranch" ] || continue
    ref=$(jig_base_ref "$tbranch")
    [ -n "$ref" ] || continue
    git -C "$JIG_PROJECT" merge-base --is-ancestor "$ref" HEAD 2>/dev/null || printf '%s\n' "$name"
  done
  return 0
}

# --- closing a spec --------------------------------------------------------------

# spec_leftovers <spec-dir> — what removing the spec would lose, one line each:
# `item: <text>` for every unchecked roadmap item, fog included, and
# `question: <text>` / `assumption: <text>` for every entry of the spec's
# "Open questions" and "Assumptions left untested" sections. The template's own
# `<placeholder>` entries are not leftovers. Only the first line of a wrapped
# entry is printed: enough to name it.
spec_leftovers() {
  local dir="$1"
  if [ -f "$dir/roadmap.md" ]; then
    awk '/^[[:space:]]*[-*][[:space:]]+\[ \]/ {
      t = $0; sub(/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/, "", t)
      if (t !~ /^</) print "item: " t
    }' "$dir/roadmap.md"
  fi
  if [ -f "$dir/spec.md" ]; then
    awk '
      /^## / { kind = ""; if ($0 ~ /^## Open questions[[:space:]]*$/) kind = "question"
               else if ($0 ~ /^## Assumptions left untested[[:space:]]*$/) kind = "assumption"; next }
      kind != "" && /^[-*][[:space:]]+/ {
        t = $0; sub(/^[-*][[:space:]]+/, "", t)
        if (t !~ /^</ && t != "") print kind ": " t
      }' "$dir/spec.md"
  fi
}

# spec_close_dir <id> <who> <handled> — the removal both `spec close` and
# `spec epic --finish` end in: refuse while leftovers are undecided, then move
# the spec to trash like `spec remove` — without unlinking any task: they are
# closed, or the one closing the spec has not landed yet and keeps its link.
spec_close_dir() {
  local id="$1" who="$2" handled="$3" dir leftovers dest rel_dest
  dir="$(spec_dir)/$id"
  leftovers=$(spec_leftovers "$dir")
  if [ -n "$leftovers" ] && [ "$handled" -ne 1 ]; then
    printf '%s\n' "$leftovers" | sed 's/^/  /' >&2
    jig_die "$who: $JIG_AI_DIR/specs/$id still holds what knowledge does not (above); move each one to another spec or task, or drop it, then run again with --leftovers-handled"
  fi
  dest=$(jig_trash_dest "spec-$id")
  rel_dest=${dest#"$JIG_PROJECT"/}
  mkdir -p "${dest%/*}" || jig_die "$who: cannot create ${rel_dest%/*}"
  mv "$dir" "$dest" || jig_die "$who: could not move $JIG_AI_DIR/specs/$id to $rel_dest"
  printf 'removed: %s/specs/%s -> %s\n' "$JIG_AI_DIR" "$id" "$rel_dest"
}

# spec_close <id> [--leftovers-handled] — remove a spec whose work is done, in
# the change that finished it (ADR-0035 as amended). A spec built on an epic is
# closed by `spec epic --finish`, on the epic.
spec_close() {
  [ $# -ge 1 ] || jig_die "spec close: missing spec id (usage: jig spec close <id> [--leftovers-handled])"
  local id="$1" handled=0 dir line rc=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --leftovers-handled) handled=1 ;;
      *) jig_die "spec close: unexpected argument: $1" ;;
    esac
    shift
  done
  spec_valid_id "$id" || jig_die "spec close: invalid spec id: $id"
  jig_require_init
  dir="$(spec_dir)/$id"
  [ -d "$dir" ] || jig_die "spec close: no such spec: $JIG_AI_DIR/specs/$id"
  if [ -f "$dir/roadmap.md" ]; then
    line=$(jig_spec_epic "$dir/roadmap.md") || rc=$?
    if [ "$rc" -eq 2 ] || [ -n "$line" ]; then
      jig_die "spec close: $id is built on an epic; close it with \`jig spec epic $id --finish\` on the epic"
    fi
  fi
  spec_close_dir "$id" "spec close" "$handled"
  jig_info "spec close: commit the removal together with the change that finished the spec"
}

# spec_epic_write <roadmap> declare <branch> [<release>] — add the Epic: line,
# and the Release: line under it when a level is given (replacing any Release:
# line already there), atomically, after the Destination: paragraph; refuses a
# roadmap without one.
spec_epic_write() {
  local roadmap="$1" branch="$3" release="${4:-}" tmp
  tmp="$roadmap.tmp.$$"
  # The destination is a paragraph and may wrap: the line goes after the
  # paragraph ends, never inside the sentence.
  awk -v b="$branch" -v r="$release" '
    function declare() { print ""; print "Epic: " b; if (r != "") print "Release: " r }
    r != "" && /^Release:/ { next }
    {
      if (pending && !done && $0 ~ /^[[:space:]]*$/) { declare(); done = 1 }
      print
      if (!pending && $0 ~ /^Destination:/) pending = 1
    }
    END {
      if (done) exit 0
      if (!pending) exit 3
      declare()
    }
  ' "$roadmap" > "$tmp" || {
    rm -f "$tmp"
    jig_die "spec epic: $roadmap has no Destination: line to put the Epic: line after"
  }
  mv "$tmp" "$roadmap" || jig_die "spec epic: could not write $roadmap"
}

# --- task links ----------------------------------------------------------------

# spec_task_dir <task-id> — a task workspace in this checkout. The one place
# spec.sh builds a path from a task id (RULES.md): spec.sh may not source
# task.sh, so it cannot reach task_dir, and checks the same grammar through
# jig_valid_id. Returns 1 for an invalid id instead of dying, because callers
# run it inside $(...), where jig_die would only leave the subshell.
spec_task_dir() {
  jig_valid_id "$1" || return 1
  printf '%s/%s/workspace/tasks/%s\n' "$JIG_PROJECT" "$JIG_AI_DIR" "$1"
}

# spec_task_state <task-dir> <key> — one key of a task's state file, or
# nothing. Read-only: `state` is written by `jig task` alone.
spec_task_state() {
  [ -f "$1/state" ] || return 0
  sed -n "s/^$2:[[:space:]]*//p" "$1/state" | head -n 1
}

# _spec_done_phase_refusal <task-id> <task-dir> — the reason `spec done` must
# not run here, or nothing.
#
# A task of a phase run (`autopilot_phase`, set by `task autopilot start
# --phase`) is one of a wave whose tasks all change neighbouring lines of the
# same roadmap. Checking an item from inside the task's own branch is how
# those branches conflict, so in a phase run the coordinator checks items in
# the epic checkout after the merge, not the agent before it
# (adr-20260922-a-phase-run-is-coordinated). The refusal is narrow on purpose:
# only in the task's own branch, which is where an agent runs, and never in
# the epic checkout the coordinator runs from.
_spec_done_phase_refusal() {
  local tid="$1" tdir="$2" phase branch here
  phase=$(spec_task_state "$tdir" autopilot_phase)
  [ -n "$phase" ] || return 0
  branch=$(spec_task_state "$tdir" branch)
  [ -n "$branch" ] || return 0
  here=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null) || here=""
  [ "$here" = "$branch" ] || return 0
  printf 'spec done: %s runs in phase %s; in a phase run the coordinator checks items after the merge, in the epic checkout. Leave the roadmap alone and finish consolidation.\n' \
    "$tid" "$phase"
}

# spec_done <task-id> — check the roadmap items that name a linked task.
#
# Called by jig-consolidate when the knowledge decision is recorded, before the
# commit, so the checkmark lands on the base branch in the same change as the
# work (ADR-0035 as amended). An item names the task when its text starts with
# the backticked id and a dash, the grammar `jig spec list` counts as filed.
# A phase run is the exception: see _spec_done_phase_refusal.
spec_done() {
  [ $# -ge 1 ] || jig_die "spec done: missing task id (usage: jig spec done <task-id>)"
  [ $# -eq 1 ] || jig_die "spec done: unexpected argument: $2"
  local tid="$1" tdir sid roadmap tmp out rc=0 refusal
  jig_require_init
  tdir=$(spec_task_dir "$tid") || jig_die "spec done: invalid task id: $tid"
  [ -f "$tdir/task.md" ] || jig_die "spec done: unknown task: $tid (no $JIG_AI_DIR/workspace/tasks/$tid/task.md)"
  refusal=$(_spec_done_phase_refusal "$tid" "$tdir")
  [ -z "$refusal" ] || jig_die "$refusal"
  sid=$(jig_spec_link "$tdir/task.md") || rc=$?
  [ "$rc" = 0 ] || jig_die "spec done: $tid links to more than one spec in its task.md"
  if [ -z "$sid" ]; then
    printf 'spec done: %s is not linked to a spec\n' "$tid"
    return 0
  fi
  [ -d "$(spec_dir)/$sid" ] \
    || jig_die "spec done: $tid links to $JIG_AI_DIR/specs/$sid/, which does not exist"
  roadmap="$(spec_dir)/$sid/roadmap.md"
  [ -f "$roadmap" ] || jig_die "spec done: no roadmap.md in $JIG_AI_DIR/specs/$sid/"

  tmp="$roadmap.tmp.$$"
  rc=0
  # Exit 3: no item names the task. Exit 4: every item that does is checked.
  # The id is compared as a string, not a pattern: `.` is legal in an id.
  out=$(awk -v id="$tid" -v tmp="$tmp" '
    {
      line = $0
      if (line ~ /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/) {
        text = line
        sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/, "", text)
        head = "`" id "`"
        if (substr(text, 1, length(head)) == head &&
            substr(text, length(head) + 1) ~ /^[[:space:]]+(—|-|--)[[:space:]]/) {
          matched++
          if (line ~ /^[[:space:]]*[-*][[:space:]]+\[ \]/) {
            sub(/\[ \]/, "[x]", line)
            marked++
            print line
          }
        }
      }
      print line > tmp
    }
    END {
      close(tmp)
      if (matched == 0) exit 3
      if (marked == 0) exit 4
    }
  ' "$roadmap") || rc=$?
  case "$rc" in
    0)
      mv "$tmp" "$roadmap" || jig_die "spec done: could not write $JIG_AI_DIR/specs/$sid/roadmap.md"
      printf 'spec done: %s checked in %s/specs/%s/roadmap.md\n' "$tid" "$JIG_AI_DIR" "$sid"
      printf '%s\n' "$out" | sed 's/^/  /'
      spec_done_complete_hint "$sid" "$roadmap"
      ;;
    3)
      rm -f "$tmp"
      jig_die "spec done: no item in $JIG_AI_DIR/specs/$sid/roadmap.md names $tid; the roadmap and the task disagree"
      ;;
    4)
      rm -f "$tmp"
      printf 'spec done: %s already done in %s/specs/%s/roadmap.md\n' "$tid" "$JIG_AI_DIR" "$sid"
      ;;
    *)
      rm -f "$tmp"
      jig_die "spec done: could not read $JIG_AI_DIR/specs/$sid/roadmap.md"
      ;;
  esac
}

# spec_done_complete_hint <spec-id> <roadmap> — say so when no planned item is
# left unchecked: the spec is closed in the change that finished it, and fog
# alone does not keep it open (ADR-0035 as amended).
spec_done_complete_hint() {
  local sid="$1" roadmap="$2" epic
  if awk '/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]+/ && !/\[ \][[:space:]]+fog:/ { found = 1 } END { exit !found }' "$roadmap"; then
    return 0
  fi
  epic=$(jig_spec_epic "$roadmap" 2>/dev/null) || epic=""
  if [ -n "$epic" ]; then
    printf 'spec done: %s roadmap complete; close it with %s on %s\n' "$sid" "\`jig spec epic $sid --finish\`" "${epic% *}"
  else
    printf 'spec done: %s roadmap complete; close it with %s\n' "$sid" "\`jig spec close $sid\`"
  fi
}

# spec_roadmap_ids <roadmap.md> — task ids named by unchecked items, one per
# line, each once.
spec_roadmap_ids() {
  awk '
    /^[[:space:]]*[-*][[:space:]]+\[ \]/ {
      text = $0
      sub(/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/, "", text)
      if (text ~ /^`[A-Za-z0-9._-]+`[[:space:]]+(—|-|--)[[:space:]]/) {
        id = substr(text, 2)
        sub(/`.*$/, "", id)
        # The same grammar as jig_valid_id: no leading dot or dash.
        if (id ~ /^[.-]/) next
        if (!(id in seen)) { seen[id] = 1; print id }
      }
    }
  ' "$1"
}

# spec_remove <id> [--dry-run] [--abandon-unstarted] — take a spec out of the
# project: unlink its open tasks in this checkout, optionally abandon the ones
# never started, and move the spec directory to trash.
#
# Tasks are found through their own `Spec:` lines, not the roadmap: the
# roadmap is shared and may not name a task filed here, while workspaces are
# local. Roadmap ids with no workspace here are reported, never guessed at.
# Workspace links are skipped, as housekeeping skips them: a workspace belongs
# to the checkout that filed it (ADR-0029).
#
# Abandoning goes through the dispatcher, `"$JIG_SELF" task abandon`, so a task
# `state` is still written by `jig task` alone. A started task is never
# abandoned: its branch may hold work.
spec_remove() {
  local sid="" dry=0 abandon=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --abandon-unstarted) abandon=1; shift ;;
      -*) jig_die "spec remove: unknown argument: $1" ;;
      *)
        [ -z "$sid" ] || jig_die "spec remove: unexpected argument: $1"
        sid="$1"
        shift
        ;;
    esac
  done
  [ -n "$sid" ] || jig_die "spec remove: missing spec id (usage: jig spec remove <id> [--dry-run] [--abandon-unstarted])"
  spec_valid_id "$sid" || jig_die "spec remove: invalid spec id: $sid"
  jig_require_init

  local root dir expect real
  root=$(spec_dir)
  dir="$root/$sid"
  [ -d "$dir" ] || jig_die "spec remove: no such spec: $JIG_AI_DIR/specs/$sid"
  expect=$(cd "$root" && pwd -P) || jig_die "spec remove: cannot resolve $JIG_AI_DIR/specs"
  real=$(cd "$dir" && pwd -P) || jig_die "spec remove: cannot resolve $JIG_AI_DIR/specs/$sid"
  case "$real" in
    "$expect"/*) ;;
    *) jig_die "spec remove: refusing to move a path outside $JIG_AI_DIR/specs: $real" ;;
  esac

  # Collect every decision before changing anything.
  local tasks_root d tid link lrc st branch base plan="" local_ids=""
  tasks_root="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  # A checkout whose task directory is itself a link owns none of the tasks
  # under it: the link leads into the checkout that filed them, and unlinking
  # a spec here would rewrite another checkout's `task.md` from a branch it
  # knows nothing about. Per task that refusal is the `[ ! -L "$d" ]` skip
  # below; for a borrowed directory the answer is the same for every task at
  # once, and is said rather than left to look like an empty queue.
  local borrowed=0
  if [ -L "$tasks_root" ]; then
    borrowed=1
    jig_warn "spec remove: this checkout borrows its task workspaces, so no task is unlinked here; run it in the checkout that owns them"
  fi
  for d in "$tasks_root"/*/; do
    [ "$borrowed" = 0 ] || break
    d=${d%/}
    [ -d "$d" ] || continue
    [ ! -L "$d" ] || continue
    tid=${d##*/}
    jig_valid_id "$tid" || continue
    local_ids="$local_ids $tid "
    [ -f "$d/task.md" ] || continue
    lrc=0
    link=$(jig_spec_link "$d/task.md") || lrc=$?
    if [ "$lrc" != 0 ]; then
      # A task that links to two specs cannot be unlinked by guessing which
      # line is meant; it is left alone and named when one of them is this
      # spec.
      if spec_links_to "$d/task.md" "$sid"; then
        plan="${plan}conflict $tid
"
      fi
      continue
    fi
    [ "$link" = "$sid" ] || continue
    st=$(spec_task_state "$d" status)
    case "$st" in
      consolidated | abandoned)
        plan="${plan}keep $tid $st
"
        continue
        ;;
    esac
    # Abandon comes before unlink: the `Spec:` line is what finds the task, so
    # removing it first would make a failed abandon impossible to retry — the
    # rerun would no longer see the task at all. An abandoned task that still
    # links is closed, and closed tasks keep their line.
    if [ "$abandon" = 1 ]; then
      branch=$(spec_task_state "$d" branch)
      base=$(spec_task_state "$d" base_commit)
      if [ -z "$branch" ] || [ -z "$base" ]; then
        plan="${plan}abandon $tid
"
      fi
    fi
    plan="${plan}unlink $tid
"
  done
  if [ -f "$dir/roadmap.md" ]; then
    while IFS= read -r tid; do
      [ -n "$tid" ] || continue
      case "$local_ids" in
        *" $tid "*) ;;
        *) plan="${plan}elsewhere $tid
" ;;
      esac
    done < <(spec_roadmap_ids "$dir/roadmap.md")
  fi

  local dest rel_dest action rest
  dest=$(jig_trash_dest "spec-$sid")
  rel_dest=${dest#"$JIG_PROJECT"/}

  while IFS=' ' read -r action tid rest; do
    [ -n "$action" ] || continue
    case "$action" in
      unlink)
        if [ "$dry" = 1 ]; then
          printf 'would-unlink   %s\n' "$tid"
          continue
        fi
        spec_unlink_task "$tasks_root/$tid/task.md" "$sid" \
          || jig_die "spec remove: could not unlink $tid; nothing else was changed after it"
        printf 'unlinked       %s\n' "$tid"
        ;;
      abandon)
        if [ "$dry" = 1 ]; then
          printf 'would-abandon  %s (not started)\n' "$tid"
          continue
        fi
        "$JIG_SELF" task abandon "$tid" >/dev/null \
          || jig_die "spec remove: could not abandon $tid; the spec was not moved"
        printf 'abandoned      %s (not started)\n' "$tid"
        ;;
      keep) printf 'kept           %s (%s)\n' "$tid" "$rest" ;;
      conflict) printf 'kept           %s (links to more than one spec)\n' "$tid" ;;
      elsewhere) printf 'not-here       %s (named in the roadmap, no workspace in this checkout)\n' "$tid" ;;
    esac
  done < <(printf '%s' "$plan")

  if [ "$dry" = 1 ]; then
    printf 'would-move     %s/specs/%s -> %s\n' "$JIG_AI_DIR" "$sid" "$rel_dest"
    return 0
  fi
  mkdir -p "${dest%/*}" || jig_die "spec remove: cannot create ${rel_dest%/*}"
  mv "$dir" "$dest" || jig_die "spec remove: could not move $JIG_AI_DIR/specs/$sid to $rel_dest"
  printf 'moved          %s/specs/%s -> %s\n' "$JIG_AI_DIR" "$sid" "$rel_dest"
}

# spec_links_to <task.md> <spec-id> — whether any `Spec:` line names exactly
# <spec-id>. The id is compared as a string: `.` is legal in an id, and as a
# pattern it would match `a.b` against `axb`.
spec_links_to() {
  awk -v sid="$2" '
    /^Spec: \.ai\/specs\// {
      id = $0
      sub(/^Spec: \.ai\/specs\//, "", id)
      sub(/\/.*$/, "", id)
      if (id == sid) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# spec_unlink_task <task.md> <spec-id> — drop the task's `Spec:` lines that
# link to <spec-id>, and nothing else. Written atomically.
spec_unlink_task() {
  local file="$1" sid="$2" tmp
  tmp="$file.tmp.$$"
  if ! awk -v sid="$sid" '
    /^Spec: \.ai\/specs\// {
      id = $0
      sub(/^Spec: \.ai\/specs\//, "", id)
      sub(/\/.*$/, "", id)
      if (id == sid) next
    }
    { print }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

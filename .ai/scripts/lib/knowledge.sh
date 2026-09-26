# jig knowledge — create, validate and maintain .ai/knowledge
# (schemas/frontmatter.md, ADR-0004, ADR-0010).
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

KM_USAGE="usage: jig knowledge check [--quiet]
       jig knowledge new <feature|adr|convention> <slug> [--domains a,b] [--paths g,g] [--proposed]
       jig knowledge new <feature|adr|convention> <slug> --source <path> --proposed [--domains a,b] [--paths g,g]
       jig knowledge new <feature|adr|convention> <slug> --copy <path> [--secrets-reviewed] [--domains a,b] [--paths g,g]
       jig knowledge new <domain|glossary|rule> <domain> [--paths g,g] [--proposed]
       jig knowledge paths [--task <id>] [--files <list>|-]
       jig knowledge paths add|remove <id> <glob>
       jig knowledge summary <id> <text>
       jig knowledge stages add|remove <id> <stage>
       jig knowledge proposed
       jig knowledge accept <id>...
       jig knowledge reject <id>...
       jig knowledge inventory [--scope <dir>]
       jig knowledge stale [--strict]
       jig knowledge reviewed <id> [--date YYYY-MM-DD]
       jig knowledge sources [--diff <id>]
       jig knowledge adr-convention
       jig knowledge changed --base <ref> | --task <id>"

# Directory holding the project's knowledge; set once by cmd_knowledge so
# every subcommand and the path builder below agree on the root.
KM_DIR=""

cmd_knowledge() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    check | new | paths | stale | reviewed | accept | reject | proposed | inventory | summary | stages | changed | sources | adr-convention) ;;
    *) jig_die "$KM_USAGE" ;;
  esac

  jig_require_init
  km_init

  case "$sub" in
    check) km_check "$@" ;;
    new) km_new "$@" ;;
    paths) km_paths "$@" ;;
    stale) km_stale "$@" ;;
    reviewed) km_reviewed "$@" ;;
    accept) km_accept "$@" ;;
    reject) km_reject "$@" ;;
    proposed) km_proposed "$@" ;;
    summary) km_summary "$@" ;;
    stages) km_stages "$@" ;;
    inventory) km_inventory "$@" ;;
    changed) km_changed "$@" ;;
    sources) km_sources "$@" ;;
    adr-convention) km_adr_convention "$@" ;;
  esac
}

# --- helpers -----------------------------------------------------------------

# km_glob_matches <glob> — exit 0 when the glob matches at least one path in
# the repository (excluding .git/).
km_glob_matches() {
  local glob="$1" pattern hit
  pattern=$(jig_glob_pattern "$glob")
  hit=$(find "$JIG_PROJECT" -path "$JIG_PROJECT/.git" -prune -o \
    -path "$JIG_PROJECT/$pattern" -print -quit 2>/dev/null)
  [ -n "$hit" ]
}

# km_id_known <id> <ids_file> — exit 0 when <id> is a line in <ids_file>.
km_id_known() {
  [ -s "$2" ] && grep -qxF "$1" "$2"
}

# --- reporting -----------------------------------------------------------------

KM_FAILURES=0
KM_WARNINGS=0
KM_DOCS=0
KM_QUIET=0
KM_LIST_FILE=""
KM_IDS_FILE=""
KM_IDS_ALL_FILE=""
KM_ADR_NUMS_FILE=""
# Held by km_paths_report's EXIT trap, which fires after the function has
# returned — so it must not be `local` (convention-shell).
KM_UNCOVERED_FILE=""

# km_init — everything a km_* function needs before it can read a document: the
# frontmatter parser it delegates to, and the root it resolves paths against.
#
# A function rather than two lines inside `cmd_knowledge`, because `jig measure`
# consumes these reports too. Setup transcribed at a second call site is setup
# that silently misses the next step this one gains, and the failure would be a
# report computed against a half-initialised library rather than an error.
km_init() {
  # shellcheck source=lib/frontmatter.sh
  . "$JIG_LIB/frontmatter.sh"
  KM_DIR="$JIG_PROJECT/$JIG_AI_DIR/knowledge"
}

km_fail() {
  KM_FAILURES=$((KM_FAILURES + 1))
  printf 'FAIL %s: %s\n' "$1" "$2"
}

km_warn() {
  KM_WARNINGS=$((KM_WARNINGS + 1))
  [ "$KM_QUIET" -eq 1 ] || printf 'WARN %s: %s\n' "$1" "$2"
}

# --- link checking -------------------------------------------------------------

# km_check_links <file> <relpath> — scan the body (after frontmatter) for
# `](relative/path)` targets and fail on any that resolve to a missing path.
km_check_links() {
  local file="$1" relpath="$2" start doc_dir target dir base resolved_dir
  start=$(fm_body_start "$file")
  doc_dir=$(dirname "$file")

  # NOTE: read from process substitution, not a pipe, so the loop body runs
  # in the current shell — a `cmd | while` pipe would run the loop in a
  # subshell and any km_fail counter increments would be lost on exit.
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in
      http://* | https://* | mailto:* | '#'* | /*) continue ;;
    esac
    target="${target%%#*}"
    [ -n "$target" ] || continue

    dir=$(dirname "$doc_dir/$target")
    base=$(basename "$target")
    resolved_dir=$(cd "$dir" 2>/dev/null && pwd) || resolved_dir=""
    if [ -z "$resolved_dir" ] || [ ! -e "$resolved_dir/$base" ]; then
      km_fail "$relpath" "broken link: $target"
    fi
  done < <(tail -n "+${start}" "$file" | grep -o -E '\]\([^)]+\)' | sed 's/^\](//; s/)$//')
}

# --- per-document checks --------------------------------------------------------

# km_check_scalar_yaml <file> <relpath> — fail every frontmatter scalar that
# jig's own reader accepts but a real YAML parser rejects.
#
# fm_get takes everything after the first `key: `, so `summary: Terms: a, b`
# reads back correctly here while any YAML parser sees a nested mapping and
# refuses the document — which is how this was found, in an editor rather than
# in a check. Frontmatter is meant to be read by both, so the two readers must
# agree. `jig knowledge summary` quotes what needs quoting (fm_set); this catches
# what a hand edit or another tool wrote.
km_check_scalar_yaml() {
  local file="$1" relpath="$2" line key value
  while IFS= read -r line; do
    # Block-list items and continuation lines are not `key: value` pairs.
    case "$line" in
      ' '* | '' | '#'*) continue ;;
      *': '*) ;;
      *) continue ;;
    esac
    key="${line%%:*}"
    case "$key" in
      *[!a-z_]*) continue ;;
    esac
    value="${line#*: }"
    # An inline list is its own form, and a quoted scalar is already safe.
    case "$value" in
      '['*) continue ;;
      '"'*'"') continue ;;
    esac
    case "$value" in
      *': '* | *:)
        km_fail "$relpath" "unquoted '$key' reads as a nested mapping in YAML; quote it"
        ;;
    esac
  done < <(fm_block "$file")
}

# km_check_doc <file> <relpath> <require_fm> <ids_file> <ids_all_file> <adr_nums_file>
km_check_doc() {
  local file="$1" relpath="$2" require_fm="$3" ids_file="$4" ids_all_file="$5" adr_nums_file="$6"
  local is_global has_fm
  is_global=0
  jig_knowledge_is_global "$file" && is_global=1

  has_fm=1
  fm_has "$file" || has_fm=0

  if [ "$is_global" -eq 0 ]; then
    if [ "$has_fm" -eq 0 ]; then
      if [ "$require_fm" -eq 1 ]; then
        km_fail "$relpath" "missing frontmatter"
      else
        km_warn "$relpath" "missing frontmatter"
      fi
    else
      km_check_scalar_yaml "$file" "$relpath"
      km_check_doc_frontmatter "$file" "$relpath" "$ids_file" "$ids_all_file" "$adr_nums_file"
    fi
  fi

  km_check_links "$file" "$relpath"
}

# km_check_doc_frontmatter — id/type/status/adr/supersedes/domains/paths checks.
km_check_doc_frontmatter() {
  local file="$1" relpath="$2" ids_file="$3" ids_all_file="$4" adr_nums_file="$5"
  local id type status date supersedes domains paths_out reviewed source
  local reldir under_adr base num slug stamp day_ok

  id=$(fm_get "$file" id)
  type=$(fm_get "$file" type)
  status=$(fm_get "$file" status)
  source=$(jig_knowledge_source "$file")

  case "$id" in
    '' | *[!a-z0-9-]*) km_fail "$relpath" "missing or invalid id" ;;
    *)
      if km_id_known "$id" "$ids_file"; then
        km_fail "$relpath" "duplicate id: $id"
      else
        printf '%s\n' "$id" >> "$ids_file"
      fi
      ;;
  esac

  case "$type" in
    feature | adr | convention | domain | glossary | rule) ;;
    *) km_fail "$relpath" "missing or invalid type" ;;
  esac

  case "$type" in
    feature | convention | domain | glossary | rule)
      case "$status" in
        proposed | active | deprecated | superseded | rejected) ;;
        *) km_fail "$relpath" "missing or invalid status" ;;
      esac
      ;;
    adr)
      case "$status" in
        proposed | accepted | superseded | deprecated | rejected) ;;
        *) km_fail "$relpath" "missing or invalid status" ;;
      esac
      ;;
    *)
      case "$status" in
        proposed | active | deprecated | superseded | accepted | rejected) ;;
        *) km_fail "$relpath" "missing or invalid status" ;;
      esac
      ;;
  esac

  # relpath is "<JIG_AI_DIR>/knowledge/<...>"; adr/ is a direct child of
  # .ai/knowledge/, so strip that prefix and check what remains.
  reldir="${relpath#"$JIG_AI_DIR"/knowledge/}"
  case "$reldir" in
    adr/*) under_adr=1 ;;
    *) under_adr=0 ;;
  esac

  if [ "$under_adr" -eq 1 ]; then
    base=$(basename "$file")
    case "$base" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*.md)
        # Named by the day it was written (adr-20260918-adr-names-are-dated).
        # The name's day is its `date:`: a record copied under another's name
        # would otherwise carry a day nobody wrote it on.
        stamp=$(printf '%s' "$base" | cut -c1-8)
        slug=$(printf '%s' "$base" | sed 's/^[0-9]\{8\}-//; s/\.md$//')
        case "$stamp" in
          ????0[1-9][0-3][0-9] | ????1[0-2][0-3][0-9]) day_ok=1 ;;
          *) day_ok=0 ;;
        esac
        case "$stamp" in ??????00 | ??????3[2-9]) day_ok=0 ;; esac
        if [ "$day_ok" -eq 0 ]; then
          km_fail "$relpath" "ADR file name starts with an invalid date: $stamp"
        else
          case "$slug" in
            '' | *[!a-z0-9-]*) km_fail "$relpath" "ADR file name must match YYYYMMDD-<slug>.md (or a legacy NNNN-<slug>.md)" ;;
          esac
          date=$(fm_get "$file" date)
          if [ -z "$source" ] && [ "$stamp" != "$(printf '%s' "$date" | tr -d -)" ]; then
            km_fail "$relpath" "ADR file date $stamp does not match date: ${date:-none}"
          fi
        fi
        ;;
      [0-9][0-9][0-9][0-9]-*.md)
        # A legacy numbered record: valid for good, its number never reused.
        num=$(printf '%s' "$base" | cut -c1-4)
        slug=$(printf '%s' "$base" | sed 's/^[0-9]\{4\}-//; s/\.md$//')
        case "$slug" in
          '' | *[!a-z0-9-]*) km_fail "$relpath" "ADR file name must match YYYYMMDD-<slug>.md (or a legacy NNNN-<slug>.md)" ;;
          *)
            if km_id_known "$num" "$adr_nums_file"; then
              km_fail "$relpath" "duplicate ADR number: $num"
            else
              printf '%s\n' "$num" >> "$adr_nums_file"
            fi
            ;;
        esac
        ;;
      *) km_fail "$relpath" "ADR file name must match YYYYMMDD-<slug>.md (or a legacy NNNN-<slug>.md)" ;;
    esac

    # Only flag a *valid-but-wrong* type here; an already-invalid type was
    # reported once by the type check above and does not need a second
    # (redundant) failure.
    case "$type" in
      feature | convention) km_fail "$relpath" "document under adr/ must have type: adr" ;;
    esac
  fi

  # A linked team ADR keeps its date in its source (ADR-0036).
  if [ "$type" = "adr" ] && [ -z "$source" ]; then
    date=$(fm_get "$file" date)
    case "$date" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) km_fail "$relpath" "missing or invalid date" ;;
    esac
  fi

  reviewed=$(fm_get "$file" reviewed_at)
  if [ -n "$reviewed" ]; then
    case "$reviewed" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) km_fail "$relpath" "invalid reviewed_at: $reviewed (expected YYYY-MM-DD)" ;;
    esac
  fi

  supersedes=$(fm_get "$file" supersedes)
  if [ -n "$supersedes" ] && ! km_id_known "$supersedes" "$ids_all_file"; then
    km_fail "$relpath" "supersedes unknown id: $supersedes"
  fi

  domains=$(fm_list "$file" domains)
  paths_out=$(fm_list "$file" paths)
  if [ -z "$domains" ] && [ -z "$paths_out" ]; then
    km_warn "$relpath" "document has neither domains nor paths: listed in every catalog, never required"
  fi

  if [ -n "$paths_out" ]; then
    # Process substitution, not a pipe: keeps the loop (and km_warn's counter
    # increment) in the current shell instead of a throwaway subshell.
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      km_glob_matches "$glob" || km_warn "$relpath" "paths glob matches no file: $glob"
    done < <(printf '%s\n' "$paths_out")
  fi

  if jig_knowledge_status_resolvable "$status" && [ -z "$(fm_get "$file" summary)" ]; then
    km_warn "$relpath" "no summary; it reads as (no summary) in the context catalog"
  fi

  km_check_load "$file" "$relpath"
  km_check_topics "$file" "$relpath"
  km_check_stages "$file" "$relpath"
  km_check_domain_placement "$file" "$relpath" "$domains"
  if [ -n "$source" ]; then
    km_check_source "$relpath" "$type" "$status" "$source" "$id"
  fi
}

# km_check_source <relpath> <type> <status> <source> <id> — a stub's link to an
# existing document (ADR-0036). Needs the tracked list and the seen-sources file
# km_check prepares; without them only the shape is checked.
km_check_source() {
  local relpath="$1" type="$2" status="$3" src="$4" id="$5" problem seen
  case "$type" in
    adr | convention | feature) ;;
    *) km_fail "$relpath" "source: links adr, convention or feature documents, not: ${type:-none}" ;;
  esac
  problem=$(km_source_problem "$src")
  if [ -n "$problem" ]; then
    km_fail "$relpath" "invalid source '$src': $problem"
  elif [ -n "${KM_TRACKED_FILE:-}" ] && ! km_source_tracked "$src" "$KM_TRACKED_FILE"; then
    km_fail "$relpath" "source is missing, a symlink, or not tracked by git with this exact case: $src"
  fi
  if [ -n "${KM_SOURCES_FILE:-}" ]; then
    seen=$(awk -F '\t' -v s="$src" '$1 == s { print $2; exit }' "$KM_SOURCES_FILE")
    if [ -n "$seen" ]; then
      km_fail "$relpath" "source already linked by $seen: $src"
    else
      printf '%s\t%s\n' "$src" "${id:-$relpath}" >> "$KM_SOURCES_FILE"
    fi
  fi
  return 0
}

# km_check_load <file> <relpath> — `load` is optional and defaults to
# `matched`; an unknown value is a failure rather than a silent fallback,
# because falling back would quietly downgrade a document the author meant to
# be always required.
km_check_load() {
  local file="$1" relpath="$2" load
  load=$(fm_get "$file" load)
  [ -n "$load" ] || return 0
  case "$load" in
    always | domain | matched) ;;
    *) km_fail "$relpath" "invalid load: $load (expected always, domain or matched)" ;;
  esac
}

# km_check_topics <file> <relpath> — topics are tags, same shape as domains.
km_check_topics() {
  local file="$1" relpath="$2" topic
  while IFS= read -r topic; do
    [ -n "$topic" ] || continue
    case "$topic" in
      -* | *- | *[!a-z0-9-]*)
        km_fail "$relpath" "invalid topic: $topic (expected [a-z0-9-], no leading or trailing '-')" ;;
    esac
  done < <(fm_list "$file" topics)
}

# km_check_domain_placement <file> <relpath> <domains> — a document filed under
# domains/<d>/ must claim <d> in its `domains` list. The directory is for human
# navigation and never implies applicability (ADR-0004), so the two must agree
# explicitly or the document would be findable by eye and unreachable by
# resolution.
km_check_domain_placement() {
  local file="$1" relpath="$2" domains="$3" prefix rest dir
  prefix="$JIG_AI_DIR/knowledge/domains/"
  case "$relpath" in
    "$prefix"*) rest="${relpath#"$prefix"}" ;;
    *) return 0 ;;
  esac
  dir="${rest%%/*}"
  [ "$dir" = "$rest" ] && return 0
  jig_has_line "$dir" "$domains" \
    || km_fail "$relpath" "filed under domains/$dir/ but does not declare domain: $dir"
}

# --- summary --------------------------------------------------------------------

# km_summary <id> <text> — set the one-line `summary` a reader sees in the context
# catalog.
#
# A command rather than a hand edit, because RULES.md says frontmatter is written by
# the tooling: `knowledge check` warns until a resolvable document has one, and a
# warning nothing can satisfy without breaking an invariant is not a warning, it is a
# trap.
km_summary() {
  [ $# -ge 2 ] || jig_die "usage: jig knowledge summary <id> <text>"
  local id="$1" text="$2" doc
  shift 2
  [ $# -eq 0 ] || jig_die "knowledge summary: unknown argument: $1"

  case "$text" in
    '') jig_die "knowledge summary: text may not be empty" ;;
    # The reader strips a trailing `# comment` before anything else and the grammar has
    # no escape (schemas/frontmatter.md), so a `#` would silently truncate the value on
    # the next read.
    *'#'*) jig_die "knowledge summary: text may not contain '#'" ;;
  esac

  doc=$(km_doc_by_id "$id")
  fm_set "$doc" summary "$text" || jig_die "knowledge summary: could not write: $id"
  printf 'summary    %s\n' "$(km_rel "$doc")"
}

# --- accept / reject --------------------------------------------------------------

# km_require_proposed <id> — die unless <id> names a document whose status is
# `proposed`; otherwise print its file path. Shared by accept and reject so the
# two commands refuse the same things, in the same words.
km_require_proposed() {
  local id="$1" doc status
  doc=$(km_doc_by_id "$id")
  status=$(fm_get "$doc" status)
  [ "$status" = proposed ] \
    || jig_die "knowledge: not a proposed document: $id (status: ${status:-none})"
  printf '%s\n' "$doc"
}

# km_dedupe_ids <id>... — the given ids with repeats removed, first occurrence
# order preserved, one per line.
#
# accept and reject report how many documents they changed. Counting arguments
# instead would let `accept feature-a feature-a` claim two documents were
# accepted when one was, and the point of this loop is an accurate account of
# what a human decided. Order is preserved rather than sorted so the output
# still follows the order the ids were given in.
km_dedupe_ids() {
  local id seen=""
  for id in "$@"; do
    case "$seen" in
      *"|$id|"*) continue ;;
    esac
    seen="$seen|$id|"
    printf '%s\n' "$id"
  done
}

# km_accept <id>... — promote one or more proposed documents to their resolvable
# status.
#
# This is the whole point of `status: proposed` (ADR on proposed knowledge): a mapped
# document sits at its real path, in git, validated, and mechanically unable to reach an
# agent's context until a human runs this. The command refuses anything that is not
# proposed, so it cannot be used to revive a superseded document by accident.
#
# Every id is validated before any document is written: a review loop that promotes
# nine documents and dies on the tenth must not leave the batch half-applied.
km_accept() {
  [ $# -ge 1 ] || jig_die "usage: jig knowledge accept <id>..."
  local id doc type target count=0 ids src tracked=""
  ids=$(km_dedupe_ids "$@")

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    doc=$(km_require_proposed "$id") || exit 1
    # A stub is accepted only with a link that works: an accepted stub whose
    # source is missing would stop every task that selects it. Checked against
    # the index with exact case, as `knowledge check` does, before anything in
    # the batch is written.
    src=$(jig_knowledge_source "$doc")
    [ -n "$src" ] || continue
    if [ -z "$tracked" ]; then
      tracked=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-tracked.XXXXXX")
      km_tracked_list "$tracked" || { rm -f "$tracked"; jig_die "knowledge accept: could not list the files git tracks"; }
    fi
    if [ -n "$(km_source_problem "$src")" ] || ! km_source_tracked "$src" "$tracked"; then
      rm -f "$tracked"
      jig_die "knowledge accept: $id links $src, which is missing, invalid or not tracked by git with this exact case; fix the link or reject it"
    fi
  done <<EOF
$ids
EOF
  [ -z "$tracked" ] || rm -f "$tracked"

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    doc=$(km_doc_by_id "$id")
    type=$(fm_get "$doc" type)
    if [ "$type" = adr ]; then target=accepted; else target=active; fi
    fm_set "$doc" status "$target" \
      || jig_die "knowledge accept: could not write: $id"
    # The text a human approved, by content: a later edit to the source makes
    # the stub `changed` until someone reviews it again (ADR-0036 as amended).
    src=$(jig_knowledge_source "$doc")
    if [ -n "$src" ]; then
      fm_set "$doc" source_hash "$(jig_hash "$JIG_PROJECT/$src")" \
        || jig_die "knowledge accept: could not record the source hash of: $id"
    fi
    printf 'accepted   %s  (status: %s)\n' "$(km_rel "$doc")" "$target"
    count=$((count + 1))
  done <<EOF
$ids
EOF
  printf 'knowledge accept: %d accepted\n' "$count"
}

# km_reject <id>... — mark one or more proposed documents `rejected`. Never
# deletes or moves a file: the user has decided reject means the document
# stays, on the record, at its real path — only its status changes, and
# `rejected` is unresolvable like every other historical status.
km_reject() {
  [ $# -ge 1 ] || jig_die "usage: jig knowledge reject <id>..."
  local id doc count=0 ids
  ids=$(km_dedupe_ids "$@")

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    km_require_proposed "$id" >/dev/null
  done <<EOF
$ids
EOF

  local packs=0 type
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    doc=$(km_doc_by_id "$id")
    type=$(fm_get "$doc" type)
    case "$type" in
      domain | glossary | rule) packs=$((packs + 1)) ;;
    esac
    fm_set "$doc" status rejected \
      || jig_die "knowledge reject: could not write: $id"
    printf 'rejected   %s  (status: rejected)\n' "$(km_rel "$doc")"
    count=$((count + 1))
  done <<EOF
$ids
EOF
  printf 'knowledge reject: %d rejected\n' "$count"

  # A domain pack's path is fixed by its type and domain (km_domain_file), so a
  # rejected pack keeps the only slot that domain has: no better pack can be
  # proposed for it afterwards. Rejecting one therefore means "not this domain",
  # never "not this draft" — revising a draft is done in place while it is still
  # proposed (ADR-0019). Said here because this is the moment it matters.
  if [ "$packs" -gt 0 ]; then
    jig_warn "a rejected domain pack keeps its domain's only slot; to revise a draft instead, edit it while it is still proposed"
  fi
}

# --- proposed ---------------------------------------------------------------------

# km_is_proposed <doc> — true when <doc> carries frontmatter whose status is
# `proposed`.
#
# One definition, because two commands ask this question: `jig knowledge
# proposed` lists what is waiting and `jig status` counts it. If they disagreed,
# the count a human is shown on arrival would not match the list they then act
# on — the same argument that made jig_knowledge_status_resolvable a single
# helper in ADR-0016.
km_is_proposed() {
  local doc="$1"
  fm_has "$doc" || return 1
  [ "$(fm_get "$doc" status)" = proposed ]
}

# km_proposed_count — how many documents are awaiting a decision, as a bare
# number on stdout. For `jig status`, which reports the count and leaves the
# listing to `jig knowledge proposed`.
km_proposed_count() {
  local doc count=0
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    km_is_proposed "$doc" || continue
    count=$((count + 1))
  done < <(km_docs)
  printf '%s\n' "$count"
}

# km_proposed — list every document with status: proposed, so a human returning
# to the repository can find what is awaiting `accept` or `reject` without
# grepping for the status by hand.
km_proposed() {
  [ $# -eq 0 ] || jig_die "usage: jig knowledge proposed"
  local doc id type rel summary src count=0

  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    km_is_proposed "$doc" || continue

    id=$(fm_get "$doc" id)
    type=$(fm_get "$doc" type)
    rel=$(km_rel "$doc")
    summary=$(fm_get "$doc" summary)
    src=$(jig_knowledge_source "$doc")
    [ -z "$src" ] || rel="$rel  -> $src"
    count=$((count + 1))
    if [ -n "$summary" ]; then
      printf 'proposed:  %s  (%s)  %s  %s\n' "$id" "$type" "$rel" "$summary"
    else
      printf 'proposed:  %s  (%s)  %s\n' "$id" "$type" "$rel"
    fi
  done < <(km_docs)

  if [ "$count" -eq 0 ]; then
    printf 'knowledge proposed: nothing proposed\n'
  else
    printf 'knowledge proposed: %d proposed\n' "$count"
  fi
  return 0
}

# --- inventory -------------------------------------------------------------------

# km_inventory [--scope <dir>] — deterministic facts about the repository's shape, for
# an agent that is about to propose a knowledge map.
#
# It deliberately prints neither the knowledge catalog nor the coverage gaps: those are
# `jig context resolve --catalog` and `jig knowledge paths`. Two commands printing the
# same fact is how the two come to disagree about it.
km_inventory() {
  local scope=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)
        [ $# -ge 2 ] || jig_die "knowledge inventory: --scope requires a value"
        scope="$2"; shift 2 ;;
      *) jig_die "knowledge inventory: unknown argument: $1" ;;
    esac
  done

  # A caller-supplied path, so it is validated before it is joined to the project root
  # (RULES.md invariant, ADR-0008).
  if [ -n "$scope" ]; then
    case "$scope" in
      /*) jig_die "knowledge inventory: --scope must be repository-relative: $scope" ;;
      *..*) jig_die "knowledge inventory: --scope may not contain '..': $scope" ;;
      *[!A-Za-z0-9._/-]*)
        jig_die "knowledge inventory: invalid --scope '$scope': expected [A-Za-z0-9._/-]" ;;
    esac
    scope="${scope%/}"
    [ -d "$JIG_PROJECT/$scope" ] \
      || jig_die "knowledge inventory: no such directory: $scope"
  fi

  local prefix="" spec="." f dir count last="" inv state doc src
  if [ -n "$scope" ]; then
    prefix="$scope/"
    spec="$scope"
  fi

  # Script-global: the EXIT trap runs after this function has returned.
  KM_INV_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jig-knowledge-inventory.XXXXXX")
  trap 'if [ -n "${KM_INV_TMP:-}" ]; then rm -rf "$KM_INV_TMP"; fi' EXIT INT TERM
  inv="$KM_INV_TMP"

  # Every listing is read with -z: without it git quotes a non-ASCII name
  # ("Docs/\320\277…"), and a quoted name is a path that does not exist.
  git -C "$JIG_PROJECT" ls-files -z -- "$spec" > "$inv/tracked.z" \
    || jig_die "knowledge inventory: could not list tracked files"
  tr '\0' '\n' < "$inv/tracked.z" | sort > "$inv/tracked"

  # Root-level tracked files are named, not counted: this is where manifests live, and
  # naming them is a fact. Which manifest means which stack is a judgement, and it is
  # already declared once in each profile's `detect` globs — inventory neither repeats
  # that mapping nor calls profiles_detect, which can only see stacks whose profile the
  # project already installed and would therefore answer a question with itself. The
  # agent reading this listing recognises `composer.json` on sight (ADR-0001).
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f="${f#"$prefix"}"
    case "$f" in */*) continue ;; esac
    printf '%-14s %s\n' "root:" "$prefix$f"
  done < "$inv/tracked"

  # Candidates for adoption (ADR-0036): tracked, untracked and ignored files, each
  # line `<state><TAB><path>`. Ignored directories are listed collapsed
  # (--directory) and never walked: node_modules/ would otherwise be thousands of
  # lines, and the report names what it did not look into instead.
  git -C "$JIG_PROJECT" ls-files -z --others --exclude-standard -- "$spec" > "$inv/untracked.z" \
    || jig_die "knowledge inventory: could not list untracked files"
  git -C "$JIG_PROJECT" ls-files -z --others --ignored --exclude-standard --directory -- "$spec" \
    > "$inv/ignored.z" || jig_die "knowledge inventory: could not list ignored files"
  {
    sed 's/^/tracked	/' "$inv/tracked"
    tr '\0' '\n' < "$inv/untracked.z" | sed 's/^/untracked	/'
    tr '\0' '\n' < "$inv/ignored.z" | sed 's/^/ignored	/'
  } > "$inv/all"

  # One pass sorts every candidate into an instruction file, a document or a
  # skipped directory. `CLAUDE.local.md` holds one person's preferences, not
  # project rules, and is never listed. Framework and runtime-skill directories
  # are Jig's own. Which documents hold rules is the agent's judgement.
  awk -F '\t' -v ai="$JIG_AI_DIR/" '
    function instruction(p, b) {
      b = p
      sub(/.*\//, "", b)
      if (b == "AGENTS.md" || b == "CLAUDE.md" || b == "GEMINI.md") return 1
      if (b == ".cursorrules" || b == ".windsurfrules") return 1
      if (p == ".github/copilot-instructions.md") return 1
      if (p ~ /\/\.github\/copilot-instructions\.md$/) return 1
      if (p ~ /^\.cursor\/rules\/[^\/]*\.mdc$/ || p ~ /\/\.cursor\/rules\/[^\/]*\.mdc$/) return 1
      return 0
    }
    {
      state = $1
      p = substr($0, length(state) + 2)
      if (p == "") next
      # A tab would split the records below, and a name with a tab cannot be a
      # linked source anyway (km_source_problem).
      if (index(p, "\t")) next
      if (index(p, ai) == 1 || index(p, ".git/") == 1) next
      if (index(p, ".claude/skills/") == 1 || index(p, ".codex/skills/") == 1) next
      if (state == "ignored" && p ~ /\/$/) { print "skip\t" p; next }
      b = p
      sub(/.*\//, "", b)
      lb = tolower(b)
      if (lb == "claude.local.md") next
      if (instruction(p)) { print "inst\t" p "\t" state; next }
      if (lb ~ /\.(md|mdc|markdown|rst|adoc)$/) print "doc\t" p "\t" state
    }
  ' "$inv/all" | sort > "$inv/class"

  # Sources already linked by a stub, so a repeated adoption does not propose
  # them twice.
  : > "$inv/linked"
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    src=$(jig_knowledge_source "$doc")
    [ -n "$src" ] || continue
    printf '%s\t%s\n' "$src" "$(fm_get "$doc" id)" >> "$inv/linked"
  done < <(km_docs)

  # A tracked instruction file prints as it always has, plus the stub that links
  # it; one git does not track says so, because nothing but this line tells the
  # agent it is not shared.
  while IFS='	' read -r f doc state; do
    [ "$f" = inst ] || continue
    src=$(awk -F '\t' -v p="$doc" '$1 == p { print $2; exit }' "$inv/linked")
    if [ "$state" = tracked ] && [ -z "$src" ]; then
      printf '%-14s %s\n' "instructions:" "$doc"
    elif [ "$state" = tracked ]; then
      printf '%-14s %s  (linked by %s)\n' "instructions:" "$doc" "$src"
    else
      printf '%-14s %s  (%s)\n' "instructions:" "$doc" "$state"
    fi
  done < "$inv/class"

  # Tracked files grouped by their first path segment below the scope: the coarsest
  # honest description of where the code is.
  # `${f#"$prefix"}` and not a `sed` expression: the scope reaches this line as a
  # literal, and a path is full of characters a substitution would read as syntax
  # (convention-shell).
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f="${f#"$prefix"}"
    case "$f" in */*) ;; *) continue ;; esac
    dir="${f%%/*}"
    if [ "$dir" != "$last" ]; then
      if [ -n "$last" ]; then
        printf '%-14s %s  (%s)\n' "tree:" "$prefix$last" "$(km_files_word "$count")"
      fi
      last="$dir"; count=0
    fi
    count=$((count + 1))
  done < "$inv/tracked"
  if [ -n "$last" ]; then
    printf '%-14s %s  (%s)\n' "tree:" "$prefix$last" "$(km_files_word "$count")"
  fi

  # Sizes: one `wc -c` over every document, not a process per file. Matched to the
  # documents by order, not by name: in the C locale wc prints every non-ASCII
  # byte of a name as `?`. Its `total` lines never name a candidate, which always
  # carries an extension. When the counts disagree — a file became unreadable —
  # no size is printed rather than a size next to the wrong file.
  # Only existing regular files are measured: a symlink would report the size of
  # whatever it points at, possibly outside the repository, and a name git split
  # at a newline is a path that does not exist. Both still get their doc: line.
  : > "$inv/docs"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$JIG_PROJECT/$f" ] && [ ! -L "$JIG_PROJECT/$f" ]; then
      printf '%s\n' "$f" >> "$inv/docs"
    fi
  done < <(awk -F '\t' '$1 == "doc" { print $2 }' "$inv/class")
  : > "$inv/sizes"
  if [ -s "$inv/docs" ]; then
    tr '\n' '\0' < "$inv/docs" \
      | (cd "$JIG_PROJECT" && xargs -0 wc -c) > "$inv/sizes" 2>/dev/null || true
  fi

  # FILENAME, not NR == FNR: either of the first two files may be empty
  # (convention-shell).
  awk -F '\t' -v sizes="$inv/sizes" -v docs="$inv/docs" -v linked="$inv/linked" '
    FILENAME == sizes {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      n = line
      sub(/[^0-9].*$/, "", n)
      sub(/^[0-9]+[[:space:]]/, "", line)
      if (line == "total") next
      s[++ns] = n
      next
    }
    FILENAME == docs { d[++nd] = $0; next }
    FILENAME == linked { by[$1] = $2; next }
    !mapped {
      mapped = 1
      if (ns == nd) for (i = 1; i <= nd; i++) size[d[i]] = s[i]
    }
    $1 == "doc" {
      extra = $3
      if ($2 in size) extra = extra ", " size[$2] " bytes"
      if ($2 in by) extra = extra ", linked by " by[$2]
      printf "%-14s %s  (%s)\n", "doc:", $2, extra
    }
    $1 == "skip" { printf "%-14s %s  (ignored directory, not inspected)\n", "skipped:", $2 }
  ' "$inv/sizes" "$inv/docs" "$inv/linked" "$inv/class"

  return 0
}

# --- requires graph ------------------------------------------------------------
# Lines of the meta file collected by pass 1:
#   <id><TAB><relpath><TAB><status><TAB><req,req,...>

# km_meta_field <meta-file> <id> <n> — field <n> of the meta line for <id>,
# empty when no document declares that id.
km_meta_field() {
  awk -F '\t' -v want="$2" -v n="$3" '$1 == want { print $n; exit }' "$1"
}

# km_check_requires <meta-file> — validate the `requires` graph as a whole:
# every target exists, every target is active, and no cycle exists. No single
# document can check this, because a requirement may be declared anywhere and
# a cycle is a property of the graph.
#
# Cycles are found by topological peel rather than recursion: bash 3.2 has no
# associative arrays, and repeatedly settling the documents whose requirements
# are all settled needs no stack. Whatever cannot be peeled sits on a cycle.
km_check_requires() {
  local meta="$1" t id relpath status reqs req target_status
  [ -s "$meta" ] || return 0
  t=$(printf '\t')

  local settled unsettled next progress all_settled
  settled="${TMPDIR:-/tmp}/jig-knowledge-settled.$$"
  unsettled="${TMPDIR:-/tmp}/jig-knowledge-unsettled.$$"
  next="${TMPDIR:-/tmp}/jig-knowledge-next.$$"
  : > "$settled"
  : > "$unsettled"

  # Existence and lifecycle, one document at a time. The meta file is streamed
  # and queried at once; SC2094 reads that as a read/write overlap, but both
  # accesses are reads (km_meta_field only prints).
  # shellcheck disable=SC2094
  while IFS="$t" read -r id relpath status reqs; do
    [ -n "$id" ] || continue
    if [ -z "$reqs" ]; then
      printf '%s\n' "$id" >> "$settled"
      continue
    fi
    printf '%s%s%s%s%s\n' "$id" "$t" "$relpath" "$t" "$reqs" >> "$unsettled"
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      target_status=$(km_meta_field "$meta" "$req" 3)
      if [ -z "$target_status" ]; then
        km_fail "$relpath" "requires unknown id: $req"
        # Already reported, and unresolvable: settling it keeps the peel below
        # from reporting the same document a second time as a cycle.
        printf '%s\n' "$req" >> "$settled"
      elif ! jig_knowledge_status_resolvable "$target_status"; then
        km_fail "$relpath" "requires inactive document: $req (status: $target_status)"
      fi
    done < <(printf '%s\n' "$reqs" | tr ',' '\n')
  done < "$meta"

  # The peel. Reading from a file (not a pipe) keeps km_fail's counter in this
  # shell.
  progress=1
  while [ "$progress" -eq 1 ]; do
    progress=0
    : > "$next"
    while IFS="$t" read -r id relpath reqs; do
      [ -n "$id" ] || continue
      all_settled=1
      while IFS= read -r req; do
        [ -n "$req" ] || continue
        grep -qxF -- "$req" "$settled" || all_settled=0
      done < <(printf '%s\n' "$reqs" | tr ',' '\n')
      if [ "$all_settled" -eq 1 ]; then
        printf '%s\n' "$id" >> "$settled"
        progress=1
      else
        printf '%s%s%s%s%s\n' "$id" "$t" "$relpath" "$t" "$reqs" >> "$next"
      fi
    done < "$unsettled"
    cp "$next" "$unsettled"
  done

  while IFS="$t" read -r id relpath reqs; do
    [ -n "$id" ] || continue
    km_fail "$relpath" "requires cycle through: $id"
  done < "$unsettled"

  rm -f "$settled" "$unsettled" "$next"
}

# --- entry point -----------------------------------------------------------------

km_check() {
  KM_QUIET=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) KM_QUIET=1 ;;
      *) jig_die "usage: jig knowledge check [--quiet]" ;;
    esac
    shift
  done

  KM_FAILURES=0
  KM_WARNINGS=0
  KM_DOCS=0

  local require_fm=0
  cfg_bool knowledge.require_frontmatter true && require_fm=1

  local kdir="$KM_DIR"
  local file id relpath

  # NOTE: these hold mktemp paths and must stay script-global (not `local`):
  # the EXIT trap below fires after km_check has already returned, once its
  # `local` variables would be gone, so it needs names that are still bound.
  KM_LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-list.XXXXXX")
  KM_IDS_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-ids.XXXXXX")
  KM_IDS_ALL_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-ids-all.XXXXXX")
  KM_ADR_NUMS_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-adr-nums.XXXXXX")
  KM_META_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-meta.XXXXXX")
  KM_TRACKED_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-tracked.XXXXXX")
  KM_SOURCES_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-sources.XXXXXX")
  trap 'rm -f "$KM_LIST_FILE" "$KM_IDS_FILE" "$KM_IDS_ALL_FILE" "$KM_ADR_NUMS_FILE" "$KM_META_FILE" "$KM_TRACKED_FILE" "$KM_SOURCES_FILE"' EXIT INT TERM

  # One git call for every linked source in the knowledge base, not one per stub
  # (convention-shell).
  km_tracked_list "$KM_TRACKED_FILE" \
    || jig_die "knowledge check: could not list the files git tracks"

  if [ -d "$kdir" ]; then
    find "$kdir" -type f -name '*.md' | sort > "$KM_LIST_FILE"
  fi

  # Pass 1: collect all declared ids up front, so `supersedes` can reference an
  # id defined in a document that sorts after the one referencing it, and the
  # `requires` graph can be walked in either direction.
  local t meta_status meta_reqs
  t=$(printf '\t')
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    jig_knowledge_is_global "$file" && continue
    fm_has "$file" || continue
    id=$(fm_get "$file" id)
    [ -n "$id" ] || continue
    printf '%s\n' "$id" >> "$KM_IDS_ALL_FILE"
    relpath=$(jig_relpath "$file" "$JIG_PROJECT")
    meta_status=$(fm_get "$file" status)
    meta_reqs=$(fm_list "$file" requires | sed '/^$/d' | tr '\n' ',' | sed 's/,$//')
    printf '%s%s%s%s%s%s%s\n' \
      "$id" "$t" "$relpath" "$t" "$meta_status" "$t" "$meta_reqs" >> "$KM_META_FILE"
  done < "$KM_LIST_FILE"

  # Pass 2: full validation.
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    KM_DOCS=$((KM_DOCS + 1))
    relpath=$(jig_relpath "$file" "$JIG_PROJECT")
    km_check_doc "$file" "$relpath" "$require_fm" "$KM_IDS_FILE" "$KM_IDS_ALL_FILE" "$KM_ADR_NUMS_FILE"
  done < "$KM_LIST_FILE"

  # Pass 3: the `requires` graph, which no single document can validate alone.
  km_check_requires "$KM_META_FILE"

  [ "$KM_QUIET" -eq 1 ] \
    || printf 'knowledge check: %d documents, %d failures, %d warnings\n' \
      "$KM_DOCS" "$KM_FAILURES" "$KM_WARNINGS"

  [ "$KM_FAILURES" -eq 0 ]
}

# --- document lookup -----------------------------------------------------------

# km_docs — every knowledge document that can carry frontmatter, sorted.
# One enumeration, shared with `context` (common.sh): the three global
# documents are excluded, everything else counts wherever it sits.
km_docs() { jig_knowledge_docs; }

# km_type_dir <type> — the subdirectory a document type lives in.
km_type_dir() {
  case "$1" in
    feature) printf 'features\n' ;;
    convention) printf 'conventions\n' ;;
    adr) printf 'adr\n' ;;
    *) jig_die "knowledge: unknown type '$1' (expected one of: $JIG_DOC_TYPES)" ;;
  esac
}

# km_doc_file <dir> <name> — path of a knowledge document. This is the single
# place a knowledge path is built from a caller-supplied name, so the name is
# validated here, before any read, write or `sed` that embeds it
# (RULES.md invariant, ADR-0008).
km_doc_file() {
  local dir="$1" name="$2"
  case "$dir" in
    features | conventions | adr | sources) ;;
    *) jig_die "knowledge: unknown document directory: $dir" ;;
  esac
  case "$name" in
    '' | -* | *- | *[!a-z0-9-]*)
      jig_die "knowledge: invalid name '$name': expected [a-z0-9-], no leading or trailing '-'" ;;
  esac
  printf '%s/%s/%s.md\n' "$KM_DIR" "$dir" "$name"
}

# km_domain_dir <domain> — directory of a domain pack. The second place (with
# km_doc_file) where a knowledge path is built from a caller-supplied name, so
# the name is validated here, before any read, write or `sed` that embeds it
# (RULES.md invariant, ADR-0008).
km_domain_dir() {
  local domain="$1"
  case "$domain" in
    '' | -* | *- | *[!a-z0-9-]*)
      jig_die "knowledge: invalid domain '$domain': expected [a-z0-9-], no leading or trailing '-'" ;;
  esac
  printf '%s/domains/%s\n' "$KM_DIR" "$domain"
}

# km_domain_file <type> <domain> — path of one document of a domain pack. The
# file name is fixed by type, so a pack always has the same shape and a reader
# can find the rules of a domain without consulting an index.
km_domain_file() {
  local type="$1" domain="$2" base dir
  case "$type" in
    domain) base="OVERVIEW.md" ;;
    glossary) base="GLOSSARY.md" ;;
    rule) base="RULES.md" ;;
    *) jig_die "knowledge: type '$type' is not a domain document" ;;
  esac
  dir=$(km_domain_dir "$domain") || exit 1
  printf '%s/%s\n' "$dir" "$base"
}

# km_doc_by_id <id> — path of the document declaring <id>. Duplicate ids are
# a `knowledge check` failure, so the first match is the only match.
#
# An id carries its type (`convention-style`, `adr-20260918-x`), while
# `knowledge new` prints a path and takes a bare slug: a miss names the ids
# ending in `-<want>`, so the slug someone just typed leads to the real id.
km_doc_by_id() {
  local want="$1" doc found="" id near=""
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    id=$(fm_get "$doc" id)
    if [ "$id" = "$want" ]; then
      found="$doc"
      break
    fi
    case "$id" in
      *-"$want") near="${near:+$near, }$id" ;;
    esac
  done < <(km_docs)
  if [ -z "$found" ]; then
    [ -z "$near" ] || jig_die "knowledge: no document with id: $want (ids carry their type; did you mean: $near?)"
    jig_die "knowledge: no document with id: $want"
  fi
  printf '%s\n' "$found"
}

# km_rel <file> — repo-relative path, the form every command prints.
# km_changed — knowledge documents created, modified or deleted since a base.
#
# Consolidation's own report is prose written by the agent ("say what was
# written and where"), so its accuracy is the agent's accuracy. `.ai/knowledge/`
# is committed, so git already knows the exact answer; this command asks it.
# Mechanics to scripts, judgement to the agent (ADR-0001) — the agent still
# explains what the change *means*.
#
# `--base` is required, following `task changes` (ADR-0022): where to count
# from is a decision, not something a command may guess. `--task` supplies it
# from the task's own fork point when that exists.
km_changed() {
  jig_require_init
  local base="" task_id="" line status rel old_rel seen=""
  local created=0 modified=0 deleted=0 renamed=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || jig_die "knowledge changed: --base requires a value"; base="$2"; shift 2 ;;
      --task) [ $# -ge 2 ] || jig_die "knowledge changed: --task requires a value"; task_id="$2"; shift 2 ;;
      *) jig_die "usage: jig knowledge changed --base <ref> | --task <id>" ;;
    esac
  done

  if [ -z "$base" ] && [ -n "$task_id" ]; then
    # shellcheck source=lib/task.sh
    . "$JIG_LIB/task.sh"
    [ -f "$(task_dir "$task_id")/state" ] \
      || jig_die "knowledge changed: unknown task: $task_id"
    base=$(task_state_get "$task_id" base_commit)
    [ -n "$base" ] \
      || jig_die "knowledge changed: task $task_id has no base_commit; pass --base <ref>"
  fi
  [ -n "$base" ] || jig_die "usage: jig knowledge changed --base <ref> | --task <id>"
  base=$(jig_review_commit "$base" "knowledge changed")

  local kdir="$JIG_AI_DIR/knowledge"

  # Tracked changes, base against the working tree so uncommitted consolidation
  # is visible — which is the state the report is wanted in.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    status=${line%%	*}
    rel=${line#*	}
    case "$status" in
      R*|C*)
        # A rename arrives as "<status>\t<old>\t<new>". Splitting on the first
        # tab alone printed both paths on one line and called it a modification.
        # For a knowledge document the rename usually *is* the change — the id
        # lives in the filename — so it gets its own word.
        old_rel=${rel%%	*}
        rel=${rel#*	}
        case "$rel" in *.md) ;; *) continue ;; esac
        printf 'renamed    %s -> %s\n' "$old_rel" "$rel"
        renamed=$((renamed + 1))
        seen="$seen
$rel"
        continue
        ;;
    esac
    case "$rel" in *.md) ;; *) continue ;; esac
    seen="$seen
$rel"
    case "$status" in
      A*) printf 'created    %s\n' "$rel"; created=$((created + 1)) ;;
      D*) printf 'deleted    %s\n' "$rel"; deleted=$((deleted + 1)) ;;
      *)  printf 'modified   %s\n' "$rel"; modified=$((modified + 1)) ;;
    esac
  done < <(git -C "$JIG_PROJECT" diff --name-status "$base" -- "$kdir" 2>/dev/null | LC_ALL=C sort -k2,2)

  # A document written during consolidation is usually still untracked, and
  # `git diff` cannot see it — the exact case this command exists for.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in *.md) ;; *) continue ;; esac
    # The two layers are not disjoint: a file removed from the index but left
    # in the worktree is "deleted" to diff and untracked to ls-files, and was
    # reported twice — as created *and* deleted, for one file.
    case "
$seen" in *"
$rel"*) continue ;; esac
    printf 'created    %s\n' "$rel"
    created=$((created + 1))
  done < <(git -C "$JIG_PROJECT" ls-files --others --exclude-standard -- "$kdir" 2>/dev/null | LC_ALL=C sort)

  # Sources of stubs: consolidation edits the rule where it lives, and a report
  # blind to that file would say "0 changed" for a task that changed a team's
  # rules (ADR-0036 as amended). Only files a stub names — nothing else outside
  # .ai/knowledge/ is reported. A renamed source reads as deleted here; the stub
  # it leaves behind is `missing` in `jig knowledge sources`.
  local sources edits=0 note src_list src_seen=""
  sources=$(km_stub_sources)
  if [ -n "$sources" ]; then
    src_list=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-changed.XXXXXX")
    printf '%s\n' "$sources" | awk -F '\t' '{ print ":(literal)" $1 }' > "$src_list"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status=${line%%	*}
      rel=${line#*	}
      note=$(km_source_note "$rel" "$sources")
      case "$status" in
        A*) printf 'created    %s  (%s)\n' "$rel" "$note" ;;
        D*) printf 'deleted    %s  (%s)\n' "$rel" "$note" ;;
        *)  printf 'modified   %s  (%s)\n' "$rel" "$note" ;;
      esac
      src_seen="$src_seen
$rel"
      edits=$((edits + 1))
    done < <(tr '\n' '\0' < "$src_list" | xargs -0 git -C "$JIG_PROJECT" diff --no-renames --name-status "$base" -- 2>/dev/null | LC_ALL=C sort -k2,2)
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      # As for documents above: a source removed from the index but kept on
      # disk is both "deleted" and untracked; it is one edit.
      case "
$src_seen
" in *"
$rel
"*) continue ;; esac
      printf 'created    %s  (%s)\n' "$rel" "$(km_source_note "$rel" "$sources")"
      edits=$((edits + 1))
    done < <(tr '\n' '\0' < "$src_list" | xargs -0 git -C "$JIG_PROJECT" ls-files --others --exclude-standard -- 2>/dev/null | LC_ALL=C sort)
    rm -f "$src_list"
  fi

  # Filter is "*.md under .ai/knowledge/", not jig_knowledge_docs: that helper
  # deliberately omits the three global documents, and a consolidation that
  # edits RULES.md is exactly what this report must not hide. The source count
  # goes last, so every earlier number keeps its position.
  printf 'knowledge changed: %d created, %d modified, %d renamed, %d deleted, %d source edits\n' \
    "$created" "$modified" "$renamed" "$deleted" "$edits"
}

# km_stub_sources — "<source><TAB><id><TAB><type>" for every stub that is not
# retired: proposed, active or accepted. One line per source, in document order.
km_stub_sources() {
  local doc src status
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    src=$(jig_knowledge_source "$doc")
    [ -n "$src" ] || continue
    status=$(fm_get "$doc" status)
    case "$status" in
      proposed | active | accepted) ;;
      *) continue ;;
    esac
    printf '%s\t%s\t%s\n' "$src" "$(fm_get "$doc" id)" "$(fm_get "$doc" type)"
  done < <(km_docs)
}

# km_source_note <source> <km_stub_sources output> — "source of <id>", and
# ", a decision record" when the stub is an ADR: a team's accepted decision
# is never edited in place, so an edit to one must stand out in the report.
km_source_note() {
  printf '%s\n' "$2" | awk -F '\t' -v s="$1" '$1 == s {
    printf "source of %s%s\n", $2, ($3 == "adr" ? ", a decision record" : ""); exit }'
}

# km_adr_convention — where a project keeps its own decision records, and how it
# numbers them, read from the sources its ADR stubs link: one line per
# directory. The numbering is the leading digits of every file there, linked or
# not; the width is the most common digit count; the example is the highest
# numbered file, which a new record is written after. Facts only: the new file
# is written by an agent after that example, never from Jig's template
# (ADR-0036 as amended).
km_adr_convention() {
  [ $# -eq 0 ] || jig_die "usage: jig knowledge adr-convention"
  local dirs dir src root real
  # A stub's `source:` is read from a file anyone can edit, and a source can be
  # swapped after acceptance: every directory is checked like any other stored
  # source before it is listed (RULES.md), never enumerated outside the
  # repository.
  root=$(cd -P "$JIG_PROJECT" && pwd -P) || jig_die "knowledge adr-convention: cannot resolve the repository root"
  dirs=$(km_stub_sources | awk -F '\t' '$3 == "adr" { print $1 }' | while IFS= read -r src; do
    [ -n "$src" ] || continue
    if [ -n "$(km_source_problem "$src")" ]; then
      printf 'invalid\t%s\n' "$src"
      continue
    fi
    # No `case` here: bash 3.2 misreads its `)` inside a command substitution.
    if [ "${src#*/}" != "$src" ]; then dir=${src%/*}; else dir=.; fi
    printf 'dir\t%s\n' "$dir"
  done | LC_ALL=C sort -u)
  if [ -z "$dirs" ]; then
    printf 'adr-dir: none (use jig knowledge new adr)\n'
    return 0
  fi
  local kind
  while IFS='	' read -r kind dir; do
    [ -n "$dir" ] || continue
    if [ "$kind" = invalid ]; then
      printf 'adr-dir: none for %s  (invalid source path, not read)\n' "$dir"
      continue
    fi
    if [ ! -d "$JIG_PROJECT/$dir" ] || [ -L "$JIG_PROJECT/$dir" ]; then
      printf 'adr-dir: %s  (missing)\n' "$dir"
      continue
    fi
    real=$(cd -P "$JIG_PROJECT/$dir" 2>/dev/null && pwd -P) || real=""
    case "$real/" in
      "$root/"*) ;;
      *) printf 'adr-dir: %s  (outside the repository, not read)\n' "$dir"; continue ;;
    esac
    find "$JIG_PROJECT/$dir" -maxdepth 1 -type f 2>/dev/null \
      | sed 's|.*/||' | LC_ALL=C sort \
      | awk -v dir="$dir" '
          # More than nine digits is not a numbering anyone uses, and would
          # overflow into a nonsense "next".
          match($0, /^[0-9]+/) && RLENGTH <= 9 {
            digits = substr($0, 1, RLENGTH); n = digits + 0; w = RLENGTH
            widths[w]++
            if (n > max || !seen) { max = n; example = $0; seen = 1 }
            next
          }
          { if (plain == "") plain = $0 }
          END {
            if (!seen) {
              printf "adr-dir: %s  unnumbered  example %s/%s\n", dir, dir, plain
              exit
            }
            best = 0
            for (k in widths) if (widths[k] > best || (widths[k] == best && k + 0 > bw)) { best = widths[k]; bw = k + 0 }
            printf "adr-dir: %s  next %0" bw "d  width %d  example %s/%s\n", dir, max + 1, bw, dir, example
          }'
  done <<EOF
$dirs
EOF
}

km_rel() { jig_relpath "$1" "$JIG_PROJECT"; }

# km_files_word <count> — "1 file" / "3 files".
km_files_word() {
  if [ "$1" = 1 ]; then printf '1 file'; else printf '%s files' "$1"; fi
}

# --- new -----------------------------------------------------------------------

# km_template_rel <type> — the template's path under templates/knowledge/.
#
# The three domain-pack templates live in a `domain/` subdirectory shaped like
# the pack itself, and not as `glossary.md` beside the global `GLOSSARY.md`:
# on a case-insensitive filesystem (macOS by default) those are one file, and
# writing one silently destroys the other.
km_template_rel() {
  case "$1" in
    domain) printf 'domain/OVERVIEW.md\n' ;;
    glossary) printf 'domain/GLOSSARY.md\n' ;;
    rule) printf 'domain/RULES.md\n' ;;
    *) printf '%s.md\n' "$1" ;;
  esac
}

# km_template <type> — the template to instantiate: the copy installed under
# .ai/templates/knowledge/ first, the framework checkout as a fallback for a
# project initialised before templates were installed.
km_template() {
  local type="$1" rel installed src
  rel=$(km_template_rel "$type")
  installed="$JIG_PROJECT/$JIG_AI_DIR/templates/knowledge/$rel"
  if [ -f "$installed" ]; then
    printf '%s\n' "$installed"
    return 0
  fi
  src=$(jig_source_root)
  if [ -n "$src" ] && [ -f "$src/templates/knowledge/$rel" ]; then
    printf '%s\n' "$src/templates/knowledge/$rel"
    return 0
  fi
  jig_die "knowledge: no template for type '$type'; run: jig upgrade"
}

# --- linked sources ----------------------------------------------------------------
#
# A stub under .ai/knowledge/sources/ links an existing document with `source:`
# (ADR-0036). Its path comes from a caller, so it is validated where it is
# accepted — `jig knowledge new` — and again by `jig knowledge check`, which
# also sees stubs written by hand (RULES.md).

# km_source_problem <path> — why <path> cannot be a linked source, or nothing.
# Shape only; whether git tracks it is km_source_tracked.
km_source_problem() {
  local src="$1" base lower nl tab
  nl=$'\n'
  tab=$'\t'
  case "$src" in
    '') printf 'empty path'; return 0 ;;
    /*) printf 'must be repository-relative'; return 0 ;;
  esac
  # `#` and `"` cannot be stored in frontmatter; brackets, parentheses and a
  # backslash break the markdown link the stub carries.
  case "$src" in
    *"$nl"* | *"$tab"* | *'#'* | *'"'* | *\\* | *'('* | *')'* | *'['* | *']'*)
      printf "may not contain '#', '\"', a backslash, brackets, parentheses, a tab or a newline"
      return 0
      ;;
  esac
  case "/$src/" in
    */../* | */./* | *//*) printf 'must be a plain file path without dot segments'; return 0 ;;
  esac
  case "$src" in
    "$JIG_AI_DIR" | "$JIG_AI_DIR"/*) printf 'may not point inside %s/' "$JIG_AI_DIR"; return 0 ;;
  esac
  # git's own directory, a submodule's included, in any case: a case-insensitive
  # filesystem opens `.GIT/config` as `.git/config`, and its remote URLs can
  # carry credentials no secret pattern recognises.
  case "/$(printf '%s' "$src" | tr '[:upper:]' '[:lower:]')/" in
    */.git/*) printf 'may not point inside .git/'; return 0 ;;
  esac
  base=${src##*/}
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  if [ "$lower" = claude.local.md ]; then
    printf 'CLAUDE.local.md is never linked'
  fi
  return 0
}

# km_tracked_list <out> — every path git tracks, one per line, into <out>.
# Read with -z so a non-ASCII name arrives as it is, not quoted.
km_tracked_list() {
  git -C "$JIG_PROJECT" ls-files -z > "$1.z" || { rm -f "$1.z"; return 1; }
  tr '\0' '\n' < "$1.z" > "$1"
  rm -f "$1.z"
}

# km_source_tracked <path> <tracked-list> — true when git tracks <path> with
# exactly this case and it is a regular file, not a symlink. Compared as a
# string, never as a pathspec: on a case-insensitive filesystem
# `[ -f docs/x.md ]` is true for `Docs/x.md`, and a pathspec would read a leading
# `:` as magic. The index keeps a deleted file until it is staged, hence the -f.
# A tracked symlink is refused because `-f` follows it: `docs/x.md -> /etc/passwd`
# is a well-formed path to a file outside the repository. A symlinked directory
# needs no check: git tracks no path through one.
km_source_tracked() {
  grep -qxF -- "$1" "$2" || return 1
  [ -f "$JIG_PROJECT/$1" ] && [ ! -L "$JIG_PROJECT/$1" ]
}

# km_source_linked_by <path> — id of the document whose `source:` is <path>,
# or nothing.
km_source_linked_by() {
  local want="$1" doc
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    if [ "$(jig_knowledge_source "$doc")" = "$want" ]; then
      fm_get "$doc" id
      return 0
    fi
  done < <(km_docs)
  return 0
}

# km_source_link_body <file> <path> — replace the template's {{SOURCE_LINK}}
# with a relative markdown link from .ai/knowledge/sources/ to <path>, the link
# `knowledge check` already verifies. The path reaches awk through the
# environment, never as a substitution: a replacement reads `&` as syntax
# (convention-shell).
km_source_link_body() {
  local file="$1" src="$2" prefix="" seg rest
  rest="$JIG_AI_DIR/knowledge/sources"
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    [ -z "$seg" ] || prefix="../$prefix"
    case "$rest" in */*) rest=${rest#*/} ;; *) rest="" ;; esac
  done
  KM_SOURCE_LINK="[$src]($prefix$src)" awk '
    {
      i = index($0, "{{SOURCE_LINK}}")
      if (i) $0 = substr($0, 1, i - 1) ENVIRON["KM_SOURCE_LINK"] substr($0, i + 15)
      print
    }
  ' "$file" > "$file.tmp" || { rm -f "$file.tmp"; return 1; }
  mv "$file.tmp" "$file"
}

# km_csv_lines <csv> — split "a, b" into one item per line.
km_csv_lines() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
}

# km_new_abandon <build> <message> — remove the unfinished build and fail, so a
# retry starts from nothing and no half-filled document is ever left behind.
km_new_abandon() {
  rm -f "$1"
  jig_die "$2"
}

# km_new <type> <slug> [--domains a,b] [--paths g,g] [--proposed] — instantiate a
# template as a new document and print its path.
#
# `--proposed` makes the document a proposal from its first moment (ADR-0016): a
# skill that writes inferences about someone else's code, as jig-map does, must not
# create them resolvable and demote them afterwards. It is a flag rather than
# `--status <s>` because `proposed` is the only other status a document can
# sensibly be born with; the template supplies the resolvable one.
km_new() {
  local type="" slug="" domains="" paths_in="" proposed=0 source="" has_source=0 copy="" has_copy=0 secrets_reviewed=0
  [ $# -ge 2 ] || jig_die "$KM_USAGE"
  type="$1"
  slug="$2"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --domains) [ $# -ge 2 ] || jig_die "knowledge new: --domains requires a value"
        domains="$2"; shift 2 ;;
      --paths) [ $# -ge 2 ] || jig_die "knowledge new: --paths requires a value"
        paths_in="$2"; shift 2 ;;
      --source) [ $# -ge 2 ] || jig_die "knowledge new: --source requires a value"
        source="$2"; has_source=1; shift 2 ;;
      --copy) [ $# -ge 2 ] || jig_die "knowledge new: --copy requires a value"
        copy="$2"; has_copy=1; shift 2 ;;
      --secrets-reviewed) secrets_reviewed=1; shift ;;
      --proposed) proposed=1; shift ;;
      *) jig_die "knowledge new: unknown argument: $1" ;;
    esac
  done

  # The type is resolved to a path before the template is looked up, so an
  # unknown type is reported as an unknown type rather than as a missing
  # template.
  local dir template file id stamp rel build problem linked tracked
  [ "$has_source" -eq 0 ] || [ "$has_copy" -eq 0 ] \
    || jig_die "knowledge new: --source links a tracked file and --copy copies an untracked one; give one of them"
  [ "$secrets_reviewed" -eq 0 ] || [ "$has_copy" -eq 1 ] \
    || jig_die "knowledge new: --secrets-reviewed goes with --copy"
  if [ "$has_copy" -eq 1 ]; then
    case "$type" in
      adr | convention | feature) ;;
      *) jig_die "knowledge new: --copy makes adr, convention or feature documents, not: $type" ;;
    esac
    km_copy_check "$copy" "$secrets_reviewed"
    # What a skill writes is proposed until a human accepts it (ADR-0016).
    proposed=1
  fi
  if [ "$has_source" -eq 1 ]; then
    # A stub linking an existing document (ADR-0036). Everything that can refuse
    # refuses before anything is written.
    case "$type" in
      adr | convention | feature) ;;
      *) jig_die "knowledge new: --source links adr, convention or feature documents, not: $type" ;;
    esac
    # A stub is written by a skill, and what a skill writes is proposed until a
    # human accepts it (ADR-0016): every link a stub hands agents is a human's
    # decision.
    [ "$proposed" -eq 1 ] \
      || jig_die "knowledge new: --source requires --proposed; a human accepts every link with jig knowledge accept"
    problem=$(km_source_problem "$source")
    [ -z "$problem" ] || jig_die "knowledge new: invalid --source '$source': $problem"
    tracked=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-tracked.XXXXXX")
    if ! km_tracked_list "$tracked"; then
      rm -f "$tracked"
      jig_die "knowledge new: could not list the files git tracks"
    fi
    if ! km_source_tracked "$source" "$tracked"; then
      rm -f "$tracked"
      jig_die "knowledge new: --source is not a regular file git tracks with this exact case (symlinks are refused): $source"
    fi
    rm -f "$tracked"
    linked=$(km_source_linked_by "$source")
    [ -z "$linked" ] || jig_die "knowledge new: $source is already linked by $linked"
    file=$(km_doc_file sources "$slug")
    id="$type-$slug"
    template=$(km_template source)
  else
    case "$type" in
      domain | glossary | rule)
        # For a domain document the slug *is* the domain: the pack lives under
        # domains/<domain>/ and the file name is fixed by type.
        file=$(km_domain_file "$type" "$slug") || exit 1
        id="$type-$slug"
        # A pack file that did not claim its own domain would fail
        # `knowledge check` immediately (km_check_domain_placement), so the
        # default is the only sensible one.
        [ -n "$domains" ] || domains="$slug"
        ;;
      adr)
        # Named by the day it is written, not by a running number: two
        # branches cut from one main used to take the same next number
        # (adr-20260918-adr-names-are-dated). The day is the one `date:` gets.
        dir=$(km_type_dir "$type")
        stamp=$(jig_today | tr -d -)
        file=$(km_doc_file "$dir" "$stamp-$slug")
        id="adr-$stamp-$slug"
        ;;
      *)
        dir=$(km_type_dir "$type")
        file=$(km_doc_file "$dir" "$slug")
        id="$type-$slug"
        ;;
    esac
    template=$(km_template "$type")
  fi

  [ -e "$file" ] && jig_die "knowledge: document already exists: $(km_rel "$file")"

  # The document is assembled beside its final path and moved there in one step,
  # complete. Filled in place, it would sit at its real path for a moment as the
  # bare template, carrying the template's resolvable status — for a proposal,
  # exactly the window `--proposed` exists to close. The build name does not end
  # in `.md`, so nothing that walks knowledge documents can see it.
  mkdir -p "$(dirname "$file")"
  build="$file.new.$$"
  if [ "$has_copy" -eq 1 ]; then
    # The template's frontmatter, then the copied file's body in place of the
    # template's: the original is only ever read.
    km_copy_build "$template" "$JIG_PROJECT/$copy" > "$build" \
      || km_new_abandon "$build" "knowledge new: could not write $(km_rel "$file")"
  else
    cp "$template" "$build" || km_new_abandon "$build" "knowledge new: could not write $(km_rel "$file")"
  fi

  fm_set "$build" id "$id" || km_new_abandon "$build" "knowledge new: could not write id: $id"
  if [ "$has_source" -eq 1 ]; then
    fm_set "$build" type "$type" || km_new_abandon "$build" "knowledge new: could not write type"
    fm_set "$build" source "$source" || km_new_abandon "$build" "knowledge new: could not write source"
    km_source_link_body "$build" "$source" \
      || km_new_abandon "$build" "knowledge new: could not write the link to $source"
  elif [ "$type" = adr ] && [ "$has_copy" -eq 1 ]; then
    fm_set "$build" date "$(jig_today)" \
      || km_new_abandon "$build" "knowledge new: could not write date"
  elif [ "$type" = adr ]; then
    fm_set "$build" date "$(jig_today)" \
      || km_new_abandon "$build" "knowledge new: could not write date"
  fi
  if [ "$proposed" -eq 1 ]; then
    fm_set "$build" status proposed \
      || km_new_abandon "$build" "knowledge new: could not write status"
  fi
  # A rejected item (see _fm_valid_item) is refused here, before the document
  # exists at its path.
  if [ -n "$domains" ] && ! km_csv_lines "$domains" | fm_list_set "$build" domains; then
    km_new_abandon "$build" "knowledge new: invalid --domains value: $domains"
  fi
  if [ -n "$paths_in" ] && ! km_csv_lines "$paths_in" | fm_list_set "$build" paths; then
    km_new_abandon "$build" "knowledge new: invalid --paths value: $paths_in"
  fi
  mv "$build" "$file" || km_new_abandon "$build" "knowledge new: could not move the finished document into place: $(km_rel "$file")"

  rel=$(km_rel "$file")
  if [ "$has_copy" -eq 1 ]; then
    printf 'copied %s -> %s (proposed)\n' "$copy" "$rel"
    jig_info "the original $copy stays where it is; another tool may still load it, and jig never deletes it"
    return 0
  fi
  printf '%s\n' "$rel"
}

# km_copy_check <path> <secrets-reviewed> — everything that can refuse a copy,
# before anything is written. The path is caller-supplied: its shape is checked
# like a linked source's, then it must be a regular file, not a symlink, inside
# the repository once symlinked directories are resolved, and not tracked by
# git — a tracked file is linked in place, never copied (ADR-0036).
km_copy_check() {
  local src="$1" reviewed="$2" problem root dir hits
  problem=$(km_source_problem "$src")
  [ -z "$problem" ] || jig_die "knowledge new: invalid --copy '$src': $problem"
  if [ ! -f "$JIG_PROJECT/$src" ] || [ -L "$JIG_PROJECT/$src" ]; then
    jig_die "knowledge new: --copy is not a regular file (symlinks are refused): $src"
  fi
  root=$(cd -P "$JIG_PROJECT" && pwd -P) || jig_die "knowledge new: cannot resolve the repository root"
  dir=$(cd -P "$(dirname "$JIG_PROJECT/$src")" 2>/dev/null && pwd -P) \
    || jig_die "knowledge new: cannot resolve the directory of $src"
  case "$dir/" in
    "$root/"*) ;;
    *) jig_die "knowledge new: --copy leaves the repository through a symlinked directory: $src" ;;
  esac
  # A hard link is the same file as another path, possibly outside the
  # repository, and no -L or cd -P can tell: a file with more than one link is
  # refused. GNU `stat -c` first — BSD `stat -f %l` means something else to GNU
  # stat and would succeed with the wrong number.
  local links
  links=$(stat -c %h "$JIG_PROJECT/$src" 2>/dev/null) || links=$(stat -f %l "$JIG_PROJECT/$src" 2>/dev/null) || links=""
  case "$links" in
    1) ;;
    '' | *[!0-9]*) jig_die "knowledge new: cannot tell whether $src is a hard link; copy refused" ;;
    *) jig_die "knowledge new: --copy is a hard link ($links links); a hard link can be a file outside the repository: $src" ;;
  esac
  if [ -n "$(git -C "$JIG_PROJECT" ls-files -- ":(literal)$src" 2>/dev/null)" ]; then
    jig_die "knowledge new: $src is tracked by git; link it in place with --source instead"
  fi
  hits=$(km_secret_scan "$JIG_PROJECT/$src" | LC_ALL=C sort -t ' ' -k2,2n -u)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    if [ "$reviewed" -ne 1 ]; then
      jig_die "knowledge new: possible secrets in $src (above); look at those lines, remove real secrets from the file, then run again with --secrets-reviewed"
    fi
    jig_warn "knowledge new: copying $src with the possible secrets above marked reviewed"
  else
    jig_warn "knowledge new: no obvious secrets in $src; the check finds obvious ones only, so read the file before it is committed"
  fi
}

# km_secret_scan <file> — "line <n>: <kind>" for every line that looks like it
# holds a secret. Never the matched text: a scan whose report carries the
# secret has copied it into a log, a terminal and an agent's context. Obvious
# shapes only — known token prefixes, key blocks, credential assignments — and
# a pattern check is no proof of absence; the human reading the file is.
km_secret_scan() {
  local file="$1" kind pat flags
  # grep exits 1 on no match; under pipefail that would be the function's
  # status, and a clean file would fail the caller's assignment.
  while IFS='	' read -r kind flags pat; do
    [ -n "$kind" ] || continue
    if [ "$flags" = i ]; then
      grep -niE -e "$pat" "$file" 2>/dev/null || true
    else
      grep -nE -e "$pat" "$file" 2>/dev/null || true
    fi | cut -d: -f1 | while IFS= read -r n; do
      printf 'line %s: %s\n' "$n" "$kind"
    done
  done <<'EOF'
aws-access-key	-	AKIA[0-9A-Z]{16}
private-key	-	-----BEGIN [A-Z ]*PRIVATE KEY-----
github-token	-	gh[pousr]_[A-Za-z0-9]{36,}
github-token	-	github_pat_[A-Za-z0-9_]{20,}
slack-token	-	xox[baprs]-[A-Za-z0-9-]{10,}
openai-anthropic-key	-	sk-(ant-)?[A-Za-z0-9_-]{20,}
jwt	-	eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.
assignment	i	(api[_-]?key|secret|token|passw(or)?d)[A-Za-z0-9_]*["' ]*[:=][ "']*[^ "'<>$]{8,}
EOF
}

# km_copy_build <template> <file> — the template's frontmatter followed by the
# copied file's body. Another tool's frontmatter at the top of the file (Cursor
# `.mdc`) is dropped and printed on stderr: its fields mean something else, and
# Jig's own come from the flags a human agreed to.
km_copy_build() {
  local template="$1" file="$2"
  awk '
    NR == 1 && $0 == "---" { infm = 1; print; next }
    infm { print; if ($0 == "---") exit }
  ' "$template"
  printf '\n'
  awk '
    NR == 1 && $0 == "---" { buf = $0 "\n"; infm = 1; next }
    infm && $0 == "---" { infm = 0; dropped = 1; printf "removed frontmatter:\n%s---\n", buf > "/dev/stderr"; next }
    infm { buf = buf $0 "\n"; next }
    { print }
    END { if (infm) { printf "%s", buf } }
  ' "$file"
}

# --- paths ---------------------------------------------------------------------

km_paths() {
  case "${1:-}" in
    add | remove) km_paths_edit "$@" ;;
    *) km_paths_report "$@" ;;
  esac
}

# km_paths_edit add|remove <id> <glob> — maintain one document's `paths`.
# The agent decides which glob belongs where; rewriting the frontmatter block
# is mechanical and therefore a script's job (ADR-0001).
km_paths_edit() {
  local op="$1"
  shift
  [ $# -eq 2 ] || jig_die "usage: jig knowledge paths $op <id> <glob>"
  local id="$1" glob="$2" file rel
  file=$(km_doc_by_id "$id")
  rel=$(km_rel "$file")

  # Membership is decided here rather than read off the writer's exit status:
  # a writer returns non-zero both for "the list already said that" and for a
  # failed write, and reporting a failed write as "unchanged" would be a lie.
  local listed=0
  if jig_has_line "$glob" "$(fm_list "$file" paths)"; then listed=1; fi

  if [ "$op" = add ]; then
    if [ "$listed" -eq 1 ]; then
      printf 'unchanged  %s  %s (already listed)\n' "$rel" "$glob"
    else
      fm_list_add "$file" paths "$glob" \
        || jig_die "knowledge paths: failed to write $rel"
      printf 'added      %s  %s\n' "$rel" "$glob"
    fi
  else
    if [ "$listed" -eq 0 ]; then
      printf 'unchanged  %s  %s (not listed)\n' "$rel" "$glob"
    else
      fm_list_remove "$file" paths "$glob" \
        || jig_die "knowledge paths: failed to write $rel"
      printf 'removed    %s  %s\n' "$rel" "$glob"
    fi
  fi
}

# km_all_globs — every `paths` glob declared anywhere in the knowledge base.
km_all_globs() {
  local doc
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    fm_list "$doc" paths
  done < <(km_docs) | sed '/^$/d' | sort -u
}

# km_file_covered <file> <globs> — exit 0 when any glob matches the path.
km_file_covered() {
  local file="$1" globs="$2" glob pattern
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    pattern=$(jig_glob_pattern "$glob")
    # shellcheck disable=SC2254
    case "$file" in
      $pattern) return 0 ;;
    esac
  done < <(printf '%s\n' "$globs")
  return 1
}

# km_paths_report [--task <id>] [--files <list>|-]
#
# Two directions of the same question, "do `paths` still describe the code":
# files this task touched that no document claims, and globs that claim
# nothing. `--task` is accepted for symmetry with `jig context` and validates
# the task exists; the file set is git-derived either way, because a workspace
# belongs to its checkout and the checkout is on the task's branch (ADR-0008).
km_paths_report() {
  local task="" files_arg="" have_files=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || jig_die "knowledge paths: --task requires a value"
        task="$2"; shift 2 ;;
      --files) [ $# -ge 2 ] || jig_die "knowledge paths: --files requires a value"
        files_arg="$2"; have_files=1; shift 2 ;;
      *) jig_die "$KM_USAGE" ;;
    esac
  done

  local files globs file
  # An explicit --task must name a real workspace, exactly as `jig context`
  # treats it: naming a task is a deliberate choice and a typo is an error.
  if [ -n "$task" ]; then
    # shellcheck source=lib/task.sh
    . "$JIG_LIB/task.sh"
    [ -f "$(task_dir "$task")/state" ] \
      || jig_die "knowledge paths: unknown task: $task"
  fi

  if [ "$have_files" -eq 1 ]; then
    if [ "$files_arg" = "-" ]; then
      files=$(cat)
    else
      files=$(printf '%s\n' "$files_arg" | tr ', ' '\n')
    fi
    files=$(printf '%s\n' "$files" | sed '/^$/d' | sort -u)
  else
    # A named task is judged against its own base (ADR-0039); without one,
    # jig_task_base answers with the configured base.
    files=$(jig_git_touched_files --base-branch "$(jig_task_base "$task")")
  fi

  globs=$(km_all_globs)

  KM_UNCOVERED_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-uncovered.XXXXXX")
  trap 'rm -f "$KM_UNCOVERED_FILE"' EXIT INT TERM

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # Knowledge and workspace files are not the subject of `paths`.
    case "$file" in "$JIG_AI_DIR"/*) continue ;; esac
    # A deleted path cannot be covered by a glob that must match the tree.
    [ -e "$JIG_PROJECT/$file" ] || continue
    km_file_covered "$file" "$globs" && continue
    # dirname of a root-level file is ".", which prints as "./" — the glob a
    # reader would write for it, not an empty path.
    printf '%s/\n' "$(dirname "$file")"
  done < <(printf '%s\n' "$files") > "$KM_UNCOVERED_FILE"

  local count line dir uncovered=0 unmatched=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=${line%% *}
    dir=${line#* }
    uncovered=$((uncovered + 1))
    printf 'uncovered: %s  (%s)\n' "$dir" "$(km_files_word "$count")"
  done < <(sort "$KM_UNCOVERED_FILE" | uniq -c | sed 's/^[[:space:]]*//')

  local doc rel glob
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    rel=$(km_rel "$doc")
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      km_glob_matches "$glob" && continue
      unmatched=$((unmatched + 1))
      printf 'unmatched: %s  (%s)\n' "$rel" "$glob"
    done < <(fm_list "$doc" paths)
  done < <(km_docs)

  printf 'knowledge paths: %d uncovered directories, %d unmatched globs\n' \
    "$uncovered" "$unmatched"
}

# --- stale ---------------------------------------------------------------------

# km_date_num <YYYY-MM-DD> — comparable integer. String comparison of dates
# would depend on the collation locale; this does not.
km_date_num() { printf '%s' "$1" | tr -d '-'; }

# km_stale [--strict]
#
# Reports documents that have drifted away from the code they describe
# (ADR-0010). Historical documents — superseded, deprecated, rejected — are
# skipped: they describe the past on purpose. This is a report, not a gate:
# it exits 0 unless --strict is given, so `verify` does not start failing on
# knowledge that is merely aging.
km_stale() {
  local strict=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict) strict=1; shift ;;
      *) jig_die "usage: jig knowledge stale [--strict]" ;;
    esac
  done

  local doc rel status reviewed glob any_match last src state
  local docs=0 stale=0 unreviewed=0 orphaned=0 planned=0 changed=0 first_unmatched

  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    status=$(fm_get "$doc" status)
    jig_knowledge_status_resolvable "$status" || continue

    any_match=0
    first_unmatched=""
    set --
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      if km_glob_matches "$glob"; then
        any_match=1
        set -- "$@" "$(jig_glob_pattern "$glob")"
      elif [ -z "$first_unmatched" ]; then
        first_unmatched="$glob"
      fi
    done < <(fm_list "$doc" paths)

    # A document without `paths` makes no claim about code and cannot drift.
    [ "$any_match" -eq 1 ] || [ -n "$first_unmatched" ] || continue

    docs=$((docs + 1))
    rel=$(km_rel "$doc")

    # Globs matching nothing mean one of two different things, and `reviewed_at`
    # tells them apart without a new field. Stamped once: the document did match
    # code, which has since moved or been deleted — real rot. Never stamped: it
    # never matched, so the code is not written yet. The T3 route decides at the
    # gate and implements afterwards (ADR-0009), so forward-looking documents are
    # normal here and must not be reported as rot.
    if [ "$any_match" -eq 0 ]; then
      reviewed=$(fm_get "$doc" reviewed_at)
      if [ -z "$reviewed" ]; then
        planned=$((planned + 1))
        printf 'planned:    %s  (no file matches yet: %s)\n' "$rel" "$first_unmatched"
      else
        orphaned=$((orphaned + 1))
        printf 'orphaned:   %s  (reviewed %s, no file matches: %s)\n' \
          "$rel" "$reviewed" "$first_unmatched"
      fi
      continue
    fi

    reviewed=$(fm_get "$doc" reviewed_at)
    if [ -z "$reviewed" ]; then
      unreviewed=$((unreviewed + 1))
      printf 'unreviewed: %s  (never reconciled with the code)\n' "$rel"
      continue
    fi

    last=$(git -C "$JIG_PROJECT" log -1 --date=short --format=%cd -- "$@" 2>/dev/null)
    [ -n "$last" ] || continue
    if [ "$(km_date_num "$last")" -gt "$(km_date_num "$reviewed")" ]; then
      stale=$((stale + 1))
      printf 'stale:      %s  (reviewed %s, code changed %s)\n' "$rel" "$reviewed" "$last"
    fi
  done < <(km_docs)

  # A linked source drifts by content, not by date: a squash merge or an
  # unstamped human edit would make dates noise (ADR-0036 as amended).
  while IFS="$(printf '\t')" read -r state doc src; do
    case "$state" in
      changed)
        changed=$((changed + 1))
        printf 'changed:    %s  (source %s differs from the approved text)\n' "$(km_rel "$doc")" "$src"
        ;;
      unrecorded)
        changed=$((changed + 1))
        printf 'changed:    %s  (source %s has no approved text recorded)\n' "$(km_rel "$doc")" "$src"
        ;;
    esac
  done < <(km_source_states)

  # The new count goes last: `jig measure` reads this line's numbers by position.
  printf 'knowledge stale: %d documents with paths, %d stale, %d unreviewed, %d orphaned, %d planned, %d changed sources\n' \
    "$docs" "$stale" "$unreviewed" "$orphaned" "$planned" "$changed"

  # `planned` is not a defect: the document is ahead of the code on purpose, so
  # --strict does not fail on it.
  [ "$strict" -eq 0 ] && return 0
  [ $((stale + unreviewed + orphaned + changed)) -eq 0 ]
}

# --- reviewed ------------------------------------------------------------------

# km_reviewed <id> [--date YYYY-MM-DD] — stamp a document as reconciled with
# the code. `jig-consolidate` calls this for every document it touched; that
# is what keeps `reviewed_at` honest and `stale` meaningful.
km_reviewed() {
  local id="" date=""
  [ $# -ge 1 ] || jig_die "usage: jig knowledge reviewed <id> [--date YYYY-MM-DD]"
  id="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --date) [ $# -ge 2 ] || jig_die "knowledge reviewed: --date requires a value"
        date="$2"; shift 2 ;;
      *) jig_die "knowledge reviewed: unknown argument: $1" ;;
    esac
  done

  [ -n "$date" ] || date=$(jig_today)
  case "$date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) jig_die "knowledge reviewed: invalid date '$date' (expected YYYY-MM-DD)" ;;
  esac

  local file rel src
  file=$(km_doc_by_id "$id")
  rel=$(km_rel "$file")
  # Reviewing a stub approves its source as it is now: the recorded hash moves
  # with the stamp, so a changed source stops being reported.
  src=$(jig_knowledge_source "$file")
  if [ -n "$src" ]; then
    jig_knowledge_read_path "$file" >/dev/null \
      || jig_die "knowledge reviewed: $id links $src, which is missing; fix the link or reject it"
    fm_set "$file" source_hash "$(jig_hash "$JIG_PROJECT/$src")" \
      || jig_die "knowledge reviewed: failed to write $rel"
  fi
  fm_set "$file" reviewed_at "$date" \
    || jig_die "knowledge reviewed: failed to write $rel"
  printf 'reviewed   %s  %s\n' "$rel" "$date"
}

# --- linked sources ----------------------------------------------------------

# km_source_states — "<state><TAB><doc><TAB><source>" for every stub, in
# document order. For a resolvable stub the state is `ok` when its source
# hashes to `source_hash`, `changed` when it does not, `unrecorded` when no
# hash was ever recorded — nothing approved the current text, so it counts as
# changed — and `missing` when the source is not there. Any other stub is
# `proposed` or its own status. One git process hashes every present source.
#
# The one definition of "changed", because three commands report it: `jig
# status` counts, `knowledge stale` lists and `knowledge sources` shows.
km_source_states() {
  local doc src status rows paths hashes t
  t=$(printf '\t')
  rows=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-sources.XXXXXX")
  paths="$rows.paths"
  hashes="$rows.hashes"
  : > "$paths"
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    src=$(jig_knowledge_source "$doc")
    [ -n "$src" ] || continue
    status=$(fm_get "$doc" status)
    if ! jig_knowledge_status_resolvable "$status"; then
      printf '%s%s%s%s%s\n' "${status:-unknown}" "$t" "$doc" "$t" "$src" >> "$rows"
    elif ! jig_knowledge_read_path "$doc" >/dev/null; then
      printf 'missing%s%s%s%s\n' "$t" "$doc" "$t" "$src" >> "$rows"
    else
      printf 'hash%s%s%s%s\n' "$t" "$doc" "$t" "$src" >> "$rows"
      printf '%s\n' "$src" >> "$paths"
    fi
  done < <(km_docs)
  if ! jig_hash_list "$JIG_PROJECT" "$paths" > "$hashes"; then
    rm -f "$rows" "$paths" "$hashes"
    jig_die "knowledge: could not hash the linked sources"
  fi
  local state recorded current
  exec 3< "$hashes"
  while IFS="$t" read -r state doc src; do
    [ -n "$doc" ] || continue
    if [ "$state" = hash ]; then
      IFS= read -r current <&3 || current=""
      recorded=$(fm_get "$doc" source_hash)
      if [ -z "$recorded" ]; then
        state=unrecorded
      elif [ "$recorded" = "$current" ]; then
        state=ok
      else
        state=changed
      fi
    fi
    printf '%s%s%s%s%s\n' "$state" "$t" "$doc" "$t" "$src"
  done < "$rows"
  exec 3<&-
  rm -f "$rows" "$paths" "$hashes"
}

# km_changed_sources_count — accepted stubs whose source text nobody approved:
# `changed` and `unrecorded`. A bare number, for `jig status`.
km_changed_sources_count() {
  km_source_states | awk -F '\t' '$1 == "changed" || $1 == "unrecorded" { n++ } END { print n + 0 }'
}

# km_sources [--diff <id>] — every stub with the state of its source, or the
# difference between the text accepted for one stub and its source now. The
# mechanics `jig-accept` needs to put a changed source in front of a human
# (ADR-0001); the decision is theirs: `knowledge reviewed <id>` approves the
# current text, `knowledge reject <id>` drops the link.
km_sources() {
  if [ $# -eq 0 ]; then
    km_sources_list
    return 0
  fi
  if [ "$1" != --diff ] || [ $# -ne 2 ]; then
    jig_die "usage: jig knowledge sources [--diff <id>]"
  fi
  km_sources_diff "$2"
}

km_sources_list() {
  local state doc src size n=0 changed=0 unrecorded=0 missing=0 t
  t=$(printf '\t')
  while IFS="$t" read -r state doc src; do
    [ -n "$doc" ] || continue
    n=$((n + 1))
    case "$state" in
      changed) changed=$((changed + 1)) ;;
      unrecorded) unrecorded=$((unrecorded + 1)) ;;
      missing) missing=$((missing + 1)) ;;
    esac
    if [ "$state" != missing ] && [ -f "$JIG_PROJECT/$src" ]; then
      size=$(wc -c < "$JIG_PROJECT/$src" | tr -d ' ')
      printf '%-11s %s -> %s (%s bytes)\n' "$state" "$(km_rel "$doc")" "$src" "$size"
    else
      printf '%-11s %s -> %s\n' "$state" "$(km_rel "$doc")" "$src"
    fi
  done < <(km_source_states)
  printf 'knowledge sources: %d linked, %d changed, %d unrecorded, %d missing\n' \
    "$n" "$changed" "$unrecorded" "$missing"
}

km_sources_diff() {
  local id="$1" doc src hash old
  doc=$(km_doc_by_id "$id")
  src=$(jig_knowledge_source "$doc")
  [ -n "$src" ] || jig_die "knowledge sources: $id links no source"
  jig_knowledge_read_path "$doc" >/dev/null \
    || jig_die "knowledge sources: $id links $src, which is missing"
  hash=$(fm_get "$doc" source_hash)
  if [ -z "$hash" ]; then
    printf 'knowledge sources: %s has no recorded source_hash; review %s whole\n' "$id" "$src"
    return 0
  fi
  if [ "$(jig_hash "$JIG_PROJECT/$src")" = "$hash" ]; then
    printf 'knowledge sources: %s is unchanged since it was approved\n' "$src"
    return 0
  fi
  # The approved text exists only if git still has that blob: a source
  # committed at that version does, one accepted uncommitted may not. Nothing
  # is stored to make up for it — the current text is then reviewed whole.
  if ! git -C "$JIG_PROJECT" cat-file -e "$hash^{blob}" 2>/dev/null; then
    printf 'knowledge sources: no stored text for %s; review %s whole\n' "$hash" "$src"
    return 0
  fi
  old=$(mktemp "${TMPDIR:-/tmp}/jig-knowledge-approved.XXXXXX")
  git -C "$JIG_PROJECT" cat-file -p "$hash" > "$old" \
    || { rm -f "$old"; jig_die "knowledge sources: could not read $hash"; }
  diff -u --label "$src (approved)" --label "$src" "$old" "$JIG_PROJECT/$src" || true
  rm -f "$old"
}

# Stages are optional relevance metadata; never task state or a filtering policy.
km_check_stages() {
  local file="$1" relpath="$2" stage
  while IFS= read -r stage; do
    [ -n "$stage" ] || continue
    jig_valid_stage "$stage" || km_fail "$relpath" "invalid stage: $stage"
  done < <(fm_list "$file" stages)
}

km_stages() {
  [ $# -eq 3 ] || jig_die "usage: jig knowledge stages add|remove <id> <stage>"
  local op="$1" id="$2" stage="$3" doc current
  case "$op" in add | remove) ;; *) jig_die "knowledge stages: invalid operation: $op" ;; esac
  jig_valid_stage "$stage" || jig_die "knowledge stages: invalid stage: $stage"
  doc=$(km_doc_by_id "$id") || return 1
  current=$(fm_list "$doc" stages)
  if jig_has_line "$stage" "$current"; then
    if [ "$op" = remove ]; then fm_list_remove "$doc" stages "$stage" || return 1; fi
  elif [ "$op" = add ]; then
    fm_list_add "$doc" stages "$stage" || return 1
  fi
  printf 'stages     %s\n' "$(km_rel "$doc")"
}

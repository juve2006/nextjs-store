# cmd_context — relevant knowledge for a task (ADR-0014; ADR-0004; ADR-0008).
# Sourced by scripts/jig; defines cmd_context. Deterministic: no LLM, no
# judgement calls beyond the matching rules below. bash 3.2 compatible: no
# associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# Global files, in the fixed order they are reported, when present.
_CTX_GLOBAL_FILES="GLOSSARY.md ARCHITECTURE.md RULES.md"

# Workspace artifacts other than task.md, in the fixed order they are
# reported, when present (domains/task).
_CTX_WORKSPACE_ARTIFACTS="discovery.md spec.md alternatives.md design.md plan.md review.md verification.md handoff.md"

CTX_USAGE="usage: jig context [--task <id>] [--files <list>|-] [--domains a,b] [--all] [--format list|paths]
       jig context resolve   [selectors] [--catalog]
       jig context pending   [selectors]
       jig context guard     [selectors]
       jig context acknowledge --task <id> --files <list>|-

selectors: --task <id>|--no-task --stage <stage> --files <list>|- --domains a,b --topics a,b --ids a,b --all"

cmd_context() {
  jig_require_init
  # shellcheck source=lib/frontmatter.sh
  . "$JIG_LIB/frontmatter.sh"
  # shellcheck source=lib/task.sh
  . "$JIG_LIB/task.sh"

  # A subcommand is a bare word; every option of the stateless form starts
  # with `--`, so the two cannot be confused and `jig context` keeps working
  # exactly as before (ADR-0014).
  case "${1:-}" in
    resolve) shift; ctx_resolve "$@"; return $? ;;
    pending) shift; ctx_pending "$@"; return $? ;;
    guard) shift; ctx_guard "$@"; return $? ;;
    acknowledge) shift; ctx_acknowledge "$@"; return $? ;;
    -* | '') ;;
    *) jig_die "$CTX_USAGE" ;;
  esac

  ctx_stateless "$@"
}

# --- the stateless form (unchanged behaviour) ---------------------------------

ctx_stateless() {
  local task_id="" no_task=0 files_arg="" files_stdin=0 domains_arg="" show_all=0 format="list"
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || jig_die "context: --task requires a value"; task_id="$2"; shift 2 ;;
      --no-task) no_task=1; shift ;;
      --stage) jig_die "context: --stage requires the progressive form; use jig context resolve" ;;
      --files)
        [ $# -ge 2 ] || jig_die "context: --files requires a value"
        if [ "$2" = "-" ]; then files_stdin=1; else files_arg="$2"; fi
        shift 2
        ;;
      --domains) [ $# -ge 2 ] || jig_die "context: --domains requires a value"; domains_arg="$2"; shift 2 ;;
      --all) show_all=1; shift ;;
      --format)
        [ $# -ge 2 ] || jig_die "context: --format requires a value"
        case "$2" in
          list | paths) format="$2" ;;
          *) jig_die "context: invalid --format: $2 (want list or paths)" ;;
        esac
        shift 2
        ;;
      *) jig_die "context: unknown argument: $1" ;;
    esac
  done

  # --- task resolution --------------------------------------------------------
  # An explicit --task must name a real workspace (the caller made a
  # deliberate choice); the implicit `task current` lookup fails silently on
  # "no candidate" — a normal outcome, not an error (ADR-0014: if nothing
  # matched, only global + workspace are returned). On "several candidates"
  # (exit 2, design.md §2) the workspace section is omitted too — picking one
  # would risk loading the wrong task's artifacts — but this time it is not
  # silent: task_current's own stderr (one line per candidate) is forwarded
  # so the caller can see why.
  if [ "$no_task" -eq 1 ] && [ -n "$task_id" ]; then jig_die "context: --task conflicts with --no-task"; fi
  if [ -n "$task_id" ]; then
    [ -f "$(task_dir "$task_id")/state" ] || jig_die "context: unknown task: $task_id"
  elif [ "$no_task" -eq 0 ]; then
    local tc_rc=0 tc_err_file
    tc_err_file=$(mktemp "${TMPDIR:-/tmp}/jig-context-current.XXXXXX")
    task_id=$(task_current 2>"$tc_err_file") || tc_rc=$?
    [ "$tc_rc" -eq 2 ] && cat "$tc_err_file" >&2
    [ "$tc_rc" -eq 0 ] || task_id=""
    rm -f "$tc_err_file"
  fi

  # --- files --------------------------------------------------------------------
  local files
  if [ "$files_stdin" -eq 1 ]; then
    files=$(cat)
  elif [ -n "$files_arg" ]; then
    files=$(printf '%s' "$files_arg" | tr ',' '\n')
  else
    # Against the selected task's own base (ADR-0039); with no task,
    # jig_task_base answers with the configured one.
    files=$(jig_git_touched_files --base-branch "$(jig_task_base "$task_id")")
  fi

  # --- domains --------------------------------------------------------------------
  local domains=""
  if [ -n "$domains_arg" ]; then
    domains=$(printf '%s' "$domains_arg" | tr ',' ' ')
  elif [ -n "$task_id" ]; then
    local task_domains
    task_domains=$(task_state_get "$task_id" domains)
    [ -n "$task_domains" ] && domains=$(printf '%s' "$task_domains" | tr ',' ' ')
  fi

  # --- rows: label<TAB>path<TAB>reason, in report order --------------------------
  local t rows=""
  t=$(printf '\t')

  local g
  for g in $_CTX_GLOBAL_FILES; do
    [ -f "$JIG_PROJECT/$JIG_AI_DIR/knowledge/$g" ] || continue
    rows="$rows
global${t}${JIG_AI_DIR}/knowledge/${g}${t}"
  done

  local matched
  matched=$(_ctx_matched_docs "$files" "$domains" "$show_all") || exit 1
  if [ -n "$matched" ]; then
    rows="$rows
$(printf '%s\n' "$matched" | sed "s/^/matched${t}/")"
  fi

  if [ -n "$task_id" ]; then
    local wdir="$JIG_AI_DIR/workspace/tasks/$task_id" wf
    if [ -f "$JIG_PROJECT/$wdir/task.md" ]; then
      rows="$rows
workspace${t}${wdir}/task.md${t}"
    fi
    for wf in $_CTX_WORKSPACE_ARTIFACTS; do
      [ -f "$JIG_PROJECT/$wdir/$wf" ] || continue
      rows="$rows
workspace${t}${wdir}/${wf}${t}"
    done
  fi

  rows=$(printf '%s\n' "$rows" | sed '/^$/d')

  # --- render --------------------------------------------------------------------
  [ -z "$rows" ] && return 0

  if [ "$format" = "paths" ]; then
    printf '%s\n' "$rows" | cut -f2
    return 0
  fi

  local label path reason
  while IFS="$t" read -r label path reason; do
    [ -n "$label" ] || continue
    if [ -n "$reason" ]; then
      printf '%-10s %s  (%s)\n' "$label:" "$path" "$reason"
    else
      printf '%-10s %s\n' "$label:" "$path"
    fi
  done < <(printf '%s\n' "$rows")
}

# --- knowledge matching -------------------------------------------------------------

# _ctx_path_matches_any <glob> <files-newline-list> — exit 0 when <glob>
# matches at least one line of <files>.
_ctx_path_matches_any() {
  local glob="$1" files="$2" pattern file
  pattern=$(jig_glob_pattern "$glob")
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # shellcheck disable=SC2254
    case "$file" in
      $pattern) return 0 ;;
    esac
  done < <(printf '%s\n' "$files")
  return 1
}

# _ctx_domain_matches_any <domain> <space-separated wanted domains>
_ctx_domain_matches_any() {
  local d="$1" domains="$2" want
  for want in $domains; do
    [ "$d" = "$want" ] && return 0
  done
  return 1
}

# _ctx_doc_reason <doc> <files> <domains> — print "paths: <glob>" or
# "domains: <domain>" for the first matching entry (frontmatter order,
# paths checked before domains) and exit 0; exit 1 and print nothing when
# neither matches.
_ctx_doc_reason() {
  local doc="$1" files="$2" domains="$3" glob dom

  if [ -n "$files" ]; then
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      if _ctx_path_matches_any "$glob" "$files"; then
        printf 'paths: %s\n' "$glob"
        return 0
      fi
    done < <(fm_list "$doc" paths)
  fi

  if [ -n "$domains" ]; then
    while IFS= read -r dom; do
      [ -n "$dom" ] || continue
      if _ctx_domain_matches_any "$dom" "$domains"; then
        printf 'domains: %s\n' "$dom"
        return 0
      fi
    done < <(fm_list "$doc" domains)
  fi

  return 1
}

# _ctx_matched_docs <files> <domains> <show_all> — "<relpath><TAB><reason>"
# lines, one per matching document, sorted by path.
#
# Enumeration is jig_knowledge_docs, shared with `knowledge` (common.sh): it
# walks .ai/knowledge recursively where this used to read three fixed
# directories, so a document filed anywhere else — a domain pack included —
# is resolved instead of silently ignored.
_ctx_matched_docs() {
  local files="$1" domains="$2" show_all="$3"
  local t doc status reason relpath out=""
  t=$(printf '\t')

  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue

    if [ "$show_all" -ne 1 ]; then
      status=$(fm_get "$doc" status)
      jig_knowledge_status_resolvable "$status" || continue
    fi

    reason=$(_ctx_doc_reason "$doc" "$files" "$domains") || continue
    relpath=$(_ctx_read_path "$doc") || exit 1
    [ -z "$(jig_knowledge_source "$doc")" ] || reason="$reason; linked by $(fm_get "$doc" id)"
    out="$out
${relpath}${t}${reason}"
  done < <(jig_knowledge_docs)

  printf '%s\n' "$out" | sed '/^$/d' | sort
}

# --- progressive resolution ----------------------------------------------------
# The stateless form above answers "what matches this diff". The subcommands
# below answer the question a working agent actually has: what must I have read
# before I am allowed to change these files, and what have I not read yet.
#
# Selectors are shared by resolve, pending and guard, and land in CTX_* rather
# than being threaded through every helper: bash 3.2 has no way to return a
# record, and passing seven positional arguments down four call levels is how
# they drift apart.

_ctx_reset_selectors() {
  CTX_TASK=""
  CTX_NO_TASK=0
  CTX_STAGE=""
  CTX_FILES=""
  CTX_DOMAINS=""
  CTX_TOPICS=""
  CTX_IDS=""
  CTX_CATALOG=0
  CTX_ALL=0
}

# _ctx_parse_selectors <args...> — fill CTX_*. A task supplies its domains when
# --domains is absent, and the Git change set supplies the files when --files
# is absent, exactly as the stateless form does.
_ctx_parse_selectors() {
  local files_stdin=0 files_arg="" domains_arg=""
  _ctx_reset_selectors

  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || jig_die "context: --task requires a value"; CTX_TASK="$2"; shift 2 ;;
      --no-task) CTX_NO_TASK=1; shift ;;
      --stage) [ $# -ge 2 ] || jig_die "context: --stage requires a value"; jig_valid_stage "$2" || jig_die "context: invalid stage: $2"; CTX_STAGE="$2"; shift 2 ;;
      --files)
        [ $# -ge 2 ] || jig_die "context: --files requires a value"
        if [ "$2" = "-" ]; then files_stdin=1; else files_arg="$2"; fi
        shift 2
        ;;
      --domains) [ $# -ge 2 ] || jig_die "context: --domains requires a value"; domains_arg="$2"; shift 2 ;;
      --topics) [ $# -ge 2 ] || jig_die "context: --topics requires a value"; CTX_TOPICS=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
      --ids) [ $# -ge 2 ] || jig_die "context: --ids requires a value"; CTX_IDS=$(printf '%s' "$2" | tr ',' ' '); shift 2 ;;
      --catalog) CTX_CATALOG=1; shift ;;
      --all) CTX_ALL=1; shift ;;
      *) jig_die "context: unknown argument: $1" ;;
    esac
  done

  if [ "$CTX_NO_TASK" -eq 1 ] && [ -n "$CTX_TASK" ]; then jig_die "context: --task conflicts with --no-task"; fi
  _ctx_check_globals
  if [ -n "$CTX_TASK" ]; then
    [ -f "$(task_dir "$CTX_TASK")/state" ] || jig_die "context: unknown task: $CTX_TASK"
  elif [ "$CTX_NO_TASK" -eq 0 ]; then
    # Same contract as the stateless form: "no candidate" is a normal outcome
    # and stays silent, but "several candidates" (exit 2) forwards task_current's
    # own listing so the caller can see why no workspace was selected
    # (ADR-0014, ADR-0012). Swallowing it would make the progressive commands
    # quieter than the command they extend.
    local tc_rc=0 tc_err_file
    tc_err_file=$(mktemp "${TMPDIR:-/tmp}/jig-context-current.XXXXXX")
    CTX_TASK=$(task_current 2>"$tc_err_file") || tc_rc=$?
    if [ "$tc_rc" -eq 2 ]; then cat "$tc_err_file" >&2; fi
    if [ "$tc_rc" -ne 0 ]; then CTX_TASK=""; fi
    rm -f "$tc_err_file"
  fi

  if [ "$files_stdin" -eq 1 ]; then
    CTX_FILES=$(cat)
  elif [ -n "$files_arg" ]; then
    CTX_FILES=$(printf '%s' "$files_arg" | tr ',' '\n')
  else
    CTX_FILES=$(jig_git_touched_files --base-branch "$(jig_task_base "$CTX_TASK")")
  fi

  if [ -n "$domains_arg" ]; then
    CTX_DOMAINS=$(printf '%s' "$domains_arg" | tr ',' ' ')
  elif [ -n "$CTX_TASK" ]; then
    local task_domains
    task_domains=$(task_state_get "$CTX_TASK" domains)
    # A full `if`, not `[ ... ] && ...`: this is the last statement of the
    # function, so a short-circuited `&&` would become its return value and,
    # under `set -e`, abort the caller silently for every task that has no
    # domains — which is most of them.
    if [ -n "$task_domains" ]; then
      CTX_DOMAINS=$(printf '%s' "$task_domains" | tr ',' ' ')
    fi
  fi
}

# _ctx_active_docs — knowledge documents eligible for selection: frontmatter
# present, and not retired unless --all.
_ctx_active_docs() {
  local doc status
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    if [ "$CTX_ALL" -ne 1 ]; then
      status=$(fm_get "$doc" status)
      jig_knowledge_status_resolvable "$status" || continue
    fi
    printf '%s\n' "$doc"
  done < <(jig_knowledge_docs)
}

# _ctx_id_map <file> — write "<id><TAB><abs-path>" for every eligible document.
_ctx_id_map() {
  local out="$1" doc id t
  t=$(printf '\t')
  : > "$out"
  while IFS= read -r doc; do
    id=$(fm_get "$doc" id)
    [ -n "$id" ] || continue
    printf '%s%s%s\n' "$id" "$t" "$doc" >> "$out"
  done < <(_ctx_active_docs)
}

# _ctx_select_reason <doc> — why this document's full body is required, or
# nothing. `load` defaults to `matched`, so existing documents need no
# migration.
#
# A `matched` document is NOT selected by domain alone: domain membership is a
# discovery signal, not proof the body is relevant, so it surfaces in the
# catalog instead. This is the one place the progressive resolver deliberately
# differs from the stateless form, which keeps promoting a domain match.
_ctx_select_reason() {
  local doc="$1" load glob dom top

  load=$(fm_get "$doc" load)
  [ -n "$load" ] || load=matched

  if [ "$load" = always ]; then
    printf 'load: always\n'
    return 0
  fi

  if [ "$load" = domain ]; then
    [ -n "$CTX_DOMAINS" ] || return 1
    while IFS= read -r dom; do
      [ -n "$dom" ] || continue
      if _ctx_domain_matches_any "$dom" "$CTX_DOMAINS"; then
        printf 'domains: %s\n' "$dom"
        return 0
      fi
    done < <(fm_list "$doc" domains)
    return 1
  fi

  if [ -n "$CTX_FILES" ]; then
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      if _ctx_path_matches_any "$glob" "$CTX_FILES"; then
        printf 'paths: %s\n' "$glob"
        return 0
      fi
    done < <(fm_list "$doc" paths)
  fi

  if [ -n "$CTX_TOPICS" ]; then
    while IFS= read -r top; do
      [ -n "$top" ] || continue
      # Same tag comparison as domains; the helper is named for its first
      # caller, not for the only kind of tag it can compare.
      if _ctx_domain_matches_any "$top" "$CTX_TOPICS"; then
        printf 'topics: %s\n' "$top"
        return 0
      fi
    done < <(fm_list "$doc" topics)
  fi

  if [ -n "$CTX_STAGE" ] && [ -n "$CTX_DOMAINS" ] && [ "$load" = matched ]; then
    if jig_has_line "$CTX_STAGE" "$(fm_list "$doc" stages)"; then
      while IFS= read -r dom; do
        [ -n "$dom" ] || continue
        if _ctx_domain_matches_any "$dom" "$CTX_DOMAINS"; then
          printf 'stage: %s; domain: %s\n' "$CTX_STAGE" "$dom"
          return 0
        fi
      done < <(fm_list "$doc" domains)
    fi
  fi

  return 1
}

# _ctx_listed <rows-file> <relpath> — exit 0 when a row of <rows-file> is for
# <relpath>. awk reads the file itself: `cut | grep -q` quits before cut has
# written a long file, and pipefail turns cut's SIGPIPE into "not listed".
_ctx_listed() {
  JIG_CTX_P="$2" awk -F '\t' '$1 == ENVIRON["JIG_CTX_P"] { f = 1 } END { exit !f }' "$1"
}

# _ctx_required_rows <rows-file> — write "<relpath><TAB><reason>" for every
# required knowledge document: load policy and selector matches, the ids named
# with --ids, then the transitive `requires` closure.
_ctx_required_rows() {
  local rows="$1" t doc reason relpath id idmap
  t=$(printf '\t')
  : > "$rows"

  while IFS= read -r doc; do
    reason=$(_ctx_select_reason "$doc") || continue
    relpath=$(jig_relpath "$doc" "$JIG_PROJECT")
    printf '%s%s%s\n' "$relpath" "$t" "$reason" >> "$rows"
  done < <(_ctx_active_docs)

  idmap="${TMPDIR:-/tmp}/jig-context-idmap.$$"
  _ctx_id_map "$idmap"

  for id in $CTX_IDS; do
    doc=$(awk -F "$t" -v want="$id" '$1 == want { print $2; exit }' "$idmap")
    [ -n "$doc" ] || { rm -f "$idmap"; jig_die "context: no active document with id: $id"; }
    relpath=$(jig_relpath "$doc" "$JIG_PROJECT")
    if _ctx_listed "$rows" "$relpath"; then continue; fi
    printf '%s%sid: %s\n' "$relpath" "$t" "$id" >> "$rows"
  done

  _ctx_close_requires "$rows" "$idmap"
  rm -f "$idmap"

  sort -o "$rows" "$rows"
  _ctx_check_selected_sources "$rows"
}

# _ctx_read_path <doc> — what the agent reads for <doc> (jig_knowledge_read_path),
# or death when <doc> is a stub whose source is missing. Only a selected
# document comes here: a stub nobody selected is listed in the catalog as
# "missing source" instead, so that someone else's reorganisation of `docs/`
# stops only the tasks the rule applies to (ADR-0014 as amended).
_ctx_read_path() {
  local doc="$1" readp rc=0
  readp=$(jig_knowledge_read_path "$doc") || rc=$?
  if [ "$rc" -ne 0 ]; then
    jig_die "context: $(jig_relpath "$doc" "$JIG_PROJECT") is selected but its source $readp is missing; fix the link or reject the stub"
  fi
  printf '%s\n' "$readp"
}

# _ctx_check_selected_sources <rows-file> — die on the first required stub
# whose source is missing. Run where the rows are built, in the calling shell:
# the readers below run inside $(...), where jig_die would end only a subshell.
_ctx_check_selected_sources() {
  local relpath reason
  while IFS="$(printf '\t')" read -r relpath reason; do
    [ -n "$relpath" ] || continue
    _ctx_read_path "$JIG_PROJECT/$relpath" >/dev/null
  done < "$1"
}

# _ctx_read_rows <rows-file> — the required rows as the agent reads them: a
# stub's row names its source, and its reason says which stub linked it. The
# rows themselves keep document paths, which `requires` closure and the
# catalog's de-duplication read frontmatter from.
_ctx_read_rows() {
  local relpath reason doc t
  t=$(printf '\t')
  while IFS="$t" read -r relpath reason; do
    [ -n "$relpath" ] || continue
    doc="$JIG_PROJECT/$relpath"
    if [ -n "$(jig_knowledge_source "$doc")" ]; then
      printf '%s%s%s; linked by %s\n' "$(jig_knowledge_read_path "$doc")" "$t" "$reason" "$(fm_get "$doc" id)"
    else
      printf '%s%s%s\n' "$relpath" "$t" "$reason"
    fi
  done < "$1"
}

# _ctx_close_requires <rows-file> <id-map> — add the transitive `requires`
# closure to the required set, in place.
#
# A requirement that resolves to nothing is fatal here rather than quietly
# dropped: returning a partial context that looks complete is exactly the
# failure this feature exists to prevent. `jig knowledge check` reports the
# same thing earlier and in bulk.
_ctx_close_requires() {
  local rows="$1" idmap="$2" t snapshot added relpath reason doc reqid reqdoc reqrel id
  t=$(printf '\t')
  snapshot="${TMPDIR:-/tmp}/jig-context-rows.$$"

  added=1
  while [ "$added" -eq 1 ]; do
    added=0
    cp "$rows" "$snapshot"
    # The snapshot is read here and removed on the fatal path below; SC2094
    # reads that as a read/write overlap, but the removal is followed
    # immediately by jig_die.
    # shellcheck disable=SC2094
    while IFS="$t" read -r relpath reason; do
      [ -n "$relpath" ] || continue
      doc="$JIG_PROJECT/$relpath"
      id=$(fm_get "$doc" id)
      while IFS= read -r reqid; do
        [ -n "$reqid" ] || continue
        reqdoc=$(awk -F "$t" -v want="$reqid" '$1 == want { print $2; exit }' "$idmap")
        if [ -z "$reqdoc" ]; then
          rm -f "$snapshot"
          jig_die "context: $relpath requires unknown or inactive document: $reqid; run: jig knowledge check"
        fi
        reqrel=$(jig_relpath "$reqdoc" "$JIG_PROJECT")
        if _ctx_listed "$rows" "$reqrel"; then continue; fi
        printf '%s%srequires: %s\n' "$reqrel" "$t" "$id" >> "$rows"
        added=1
      done < <(fm_list "$doc" requires)
    done < "$snapshot"
  done

  rm -f "$snapshot"
}

# Validate synchronously: errors inside a process-substitution producer are lost.
_ctx_check_globals() {
  local g
  for g in $_CTX_GLOBAL_FILES; do
    if [ ! -f "$JIG_PROJECT/$JIG_AI_DIR/knowledge/$g" ] || [ ! -r "$JIG_PROJECT/$JIG_AI_DIR/knowledge/$g" ]; then
      jig_die "context: missing or unreadable mandatory global: $JIG_AI_DIR/knowledge/$g; restore project knowledge"
    fi
  done
}

# _ctx_global_rows — "<relpath><TAB>global" for each global document present.
_ctx_global_rows() {
  local t g
  t=$(printf '\t')
  for g in $_CTX_GLOBAL_FILES; do
    [ -f "$JIG_PROJECT/$JIG_AI_DIR/knowledge/$g" ] || continue
    printf '%s/knowledge/%s%sglobal\n' "$JIG_AI_DIR" "$g" "$t"
  done
}

# _ctx_catalog_rows <rows-file> — "<relpath><TAB><id><TAB><summary>" for active
# documents of the entered domains that are NOT required, plus every active
# project-wide document — one with neither `domains` nor `paths`, such as a
# team's own ADR or conventions linked in place (ADR-0036). Such a document
# belongs to no domain an agent could enter and matches no file it could
# touch, so without this it would reach no agent at all (ADR-0014 amendment
# 2026-09-18). Metadata only: the agent decides whether to pull one in with
# --ids, and no body is loaded merely because it is listed.
_ctx_catalog_rows() {
  local rows="$1" t doc relpath id summary dom hit readp read_rc doms
  t=$(printf '\t')

  while IFS= read -r doc; do
    relpath=$(jig_relpath "$doc" "$JIG_PROJECT")
    if _ctx_listed "$rows" "$relpath"; then continue; fi
    hit=0
    doms=$(fm_list "$doc" domains)
    if [ -z "$doms" ]; then
      [ -z "$(fm_list "$doc" paths)" ] && hit=1
    elif [ -n "$CTX_DOMAINS" ]; then
      while IFS= read -r dom; do
        [ -n "$dom" ] || continue
        _ctx_domain_matches_any "$dom" "$CTX_DOMAINS" && { hit=1; break; }
      done <<EOF_DOMS
$doms
EOF_DOMS
    fi
    [ "$hit" -eq 1 ] || continue
    id=$(fm_get "$doc" id)
    summary=$(fm_get "$doc" summary)
    [ -n "$summary" ] || summary="(no summary)"
    if [ -n "$(jig_knowledge_source "$doc")" ]; then
      read_rc=0
      readp=$(jig_knowledge_read_path "$doc") || read_rc=$?
      if [ "$read_rc" -eq 0 ]; then
        relpath=$readp
      else
        summary="missing source: $readp"
      fi
    fi
    printf '%s%s%s%s%s\n' "$relpath" "$t" "$id" "$t" "$summary"
  done < <(_ctx_active_docs) | sort
}

# _ctx_workspace_rows — the current task's own artifacts.
_ctx_workspace_rows() {
  local t wdir wf
  t=$(printf '\t')
  [ -n "$CTX_TASK" ] || return 0
  wdir="$JIG_AI_DIR/workspace/tasks/$CTX_TASK"
  [ -f "$JIG_PROJECT/$wdir/task.md" ] && printf '%s/task.md%sworkspace\n' "$wdir" "$t"
  for wf in $_CTX_WORKSPACE_ARTIFACTS; do
    [ -f "$JIG_PROJECT/$wdir/$wf" ] || continue
    printf '%s/%s%sworkspace\n' "$wdir" "$wf" "$t"
  done
}

ctx_resolve() {
  _ctx_parse_selectors "$@"

  local rows relpath reason id summary
  rows="${TMPDIR:-/tmp}/jig-context-required.$$"
  _ctx_required_rows "$rows"

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    printf '%-10s %s\n' "global:" "$relpath"
  done < <(_ctx_global_rows | cut -f1)

  while IFS="$(printf '\t')" read -r relpath reason; do
    [ -n "$relpath" ] || continue
    printf '%-10s %s  (%s)\n' "required:" "$relpath" "$reason"
  done < <(_ctx_read_rows "$rows")

  if [ "$CTX_CATALOG" -eq 1 ]; then
    while IFS="$(printf '\t')" read -r relpath id summary; do
      [ -n "$relpath" ] || continue
      printf '%-10s %s  [%s] %s\n' "catalog:" "$relpath" "$id" "$summary"
    done < <(_ctx_catalog_rows "$rows")
  fi

  while IFS="$(printf '\t')" read -r relpath reason; do
    [ -n "$relpath" ] || continue
    printf '%-10s %s\n' "workspace:" "$relpath"
  done < <(_ctx_workspace_rows)

  rm -f "$rows"
}

# --- the context ledger ----------------------------------------------------------
# One line per acknowledged document: `<git-hash><TAB><repo-relative-path>`,
# stored in the task workspace, which is gitignored — an acknowledgement is a
# fact about one session, never durable knowledge (RULES.md).
#
# What it proves is narrow and worth stating plainly: the agent said it read
# the document. It is not evidence of comprehension, and a passing guard is not
# evidence that the knowledge was applied. Same standing as "a skip is not a
# pass" — useful precisely because nobody overstates it.

_ctx_ledger_file() {
  printf '%s/context\n' "$(task_dir "$1")"
}

# _ctx_check_knowledge_path <relpath> — a caller-supplied path is validated
# before it is joined to the project root (RULES.md invariant, ADR-0008).
_ctx_check_knowledge_path() {
  local rel="$1"
  case "$rel" in
    /*) jig_die "context acknowledge: path must be repository-relative: $rel" ;;
    *..*) jig_die "context acknowledge: path may not contain '..': $rel" ;;
  esac
  case "$rel" in
    "$JIG_AI_DIR/knowledge/"*.md) ;;
    *)
      # A source an accepted stub links is read in the stub's place, so its
      # reading is acknowledged too — that file, not any file (ADR-0015 as
      # amended).
      _ctx_is_linked_source "$rel" \
        || jig_die "context acknowledge: not a knowledge document or a linked source: $rel"
      ;;
  esac
  case "$rel" in
    "$JIG_AI_DIR/knowledge/"*.md) ;;
    *)
      # The same test resolution applies: no symlink, nothing outside the
      # repository (jig_knowledge_read_path).
      if [ ! -f "$JIG_PROJECT/$rel" ] || [ -L "$JIG_PROJECT/$rel" ]; then
        jig_die "context acknowledge: no such document: $rel"
      fi
      local root dir
      root=$(cd -P "$JIG_PROJECT" && pwd -P)
      dir=$(cd -P "$(dirname "$JIG_PROJECT/$rel")" 2>/dev/null && pwd -P) \
        || jig_die "context acknowledge: no such document: $rel"
      case "$dir/" in
        "$root/"*) ;;
        *) jig_die "context acknowledge: linked source leaves the repository: $rel" ;;
      esac
      ;;
  esac
  [ -f "$JIG_PROJECT/$rel" ] || jig_die "context acknowledge: no such document: $rel"
}

# _ctx_is_linked_source <relpath> — true when a resolvable stub links <relpath>.
_ctx_is_linked_source() {
  local want="$1" doc
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    fm_has "$doc" || continue
    [ "$(jig_knowledge_source "$doc")" = "$want" ] || continue
    jig_knowledge_status_resolvable "$(fm_get "$doc" status)" && return 0
  done < <(jig_knowledge_docs)
  return 1
}

ctx_acknowledge() {
  local task_id="" files_arg="" files_stdin=0 files ledger tmp rel t hash count
  t=$(printf '\t')

  while [ $# -gt 0 ]; do
    case "$1" in
      --task) [ $# -ge 2 ] || jig_die "context: --task requires a value"; task_id="$2"; shift 2 ;;
      --files)
        [ $# -ge 2 ] || jig_die "context: --files requires a value"
        if [ "$2" = "-" ]; then files_stdin=1; else files_arg="$2"; fi
        shift 2
        ;;
      *) jig_die "context: unknown argument: $1" ;;
    esac
  done

  [ -n "$task_id" ] || jig_die "context acknowledge: --task is required"
  [ -f "$(task_dir "$task_id")/state" ] || jig_die "context: unknown task: $task_id"

  if [ "$files_stdin" -eq 1 ]; then
    files=$(cat)
  elif [ -n "$files_arg" ]; then
    files=$(printf '%s' "$files_arg" | tr ',' '\n')
  else
    jig_die "context acknowledge: --files is required"
  fi
  files=$(printf '%s\n' "$files" | sed '/^$/d')
  [ -n "$files" ] || jig_die "context acknowledge: --files is empty"

  ledger=$(_ctx_ledger_file "$task_id")
  tmp="$ledger.tmp.$$"

  # Rewrite through a temporary and `mv` (convention-shell): a crash must not
  # leave a half-written ledger, which would read as "already acknowledged".
  : > "$tmp"
  if [ -f "$ledger" ]; then
    while IFS="$t" read -r hash rel; do
      [ -n "$rel" ] || continue
      if jig_has_line "$rel" "$files"; then continue; fi
      printf '%s%s%s\n' "$hash" "$t" "$rel" >> "$tmp"
    done < "$ledger"
  fi

  # Every path is validated before any is hashed, then all are hashed by one
  # git process (jig_hash_list) and paired back by position — `paste` joins
  # with a tab, which is the ledger's own separator.
  count=0
  : > "$tmp.rel"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _ctx_check_knowledge_path "$rel"
    printf '%s\n' "$rel" >> "$tmp.rel"
    count=$((count + 1))
  done < <(printf '%s\n' "$files")
  if ! jig_hash_list "$JIG_PROJECT" "$tmp.rel" > "$tmp.hash"; then
    rm -f "$tmp" "$tmp.rel" "$tmp.hash"
    jig_die "context acknowledge: could not hash the documents"
  fi
  paste "$tmp.hash" <(printf '%s\n' "$files") >> "$tmp"
  rm -f "$tmp.rel" "$tmp.hash"

  sort -o "$tmp" "$tmp"
  mv "$tmp" "$ledger"
  printf 'acknowledged %s document(s) for %s\n' "$count" "$task_id"
}

# _ctx_tracked_paths <rows-file> — every path whose reading is tracked: the
# globals plus the required set. Workspace artifacts are returned by resolve
# but never acknowledged; they are the task's own output, not knowledge it owes
# a reading of.
_ctx_tracked_paths() {
  { _ctx_global_rows | cut -f1; _ctx_read_rows "$1" | cut -f1; } | sort -u
}

# _ctx_pending_paths <rows-file> <ledger> — tracked documents with no
# acknowledgement, or whose content has changed since one. A changed document
# becomes pending again: that is the point of hashing rather than listing.
#
# One git process hashes every tracked document and one awk compares them with
# the ledger, in tracked-path order; the per-document loop started a git and an
# awk for each. The two inputs are tagged rather than joined on NR == FNR,
# which goes wrong when the ledger is empty (conventions/shell.md).
_ctx_pending_paths() {
  local rows="$1" ledger="$2" paths relpath tmp t
  t=$(printf '\t')
  paths=$(_ctx_tracked_paths "$rows")
  [ -n "$paths" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jig-context-pending.XXXXXX")
  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    printf '%s\n' "$relpath"
  done > "$tmp" < <(printf '%s\n' "$paths")
  if ! jig_hash_list "$JIG_PROJECT" "$tmp" > "$tmp.hash"; then
    rm -f "$tmp" "$tmp.hash"
    jig_die "context: could not hash the tracked documents"
  fi
  {
    # $t, not a `\t` escape: BSD sed does not read one in a replacement.
    if [ -f "$ledger" ]; then sed "s/^/L$t/" "$ledger"; fi
    paste "$tmp.hash" <(printf '%s\n' "$paths" | sed '/^$/d') | sed "s/^/W$t/"
  } | awk -F '\t' '$1 == "L" { have[$3] = $2; next } $1 == "W" && have[$3] != $2 { print $3 }'
  rm -f "$tmp" "$tmp.hash"
}

ctx_pending() {
  _ctx_parse_selectors "$@"
  local rows ledger
  rows="${TMPDIR:-/tmp}/jig-context-required.$$"
  _ctx_required_rows "$rows"
  if [ -z "$CTX_TASK" ]; then
    rm -f "$rows"
    # Keep the historical implicit "no current task" result silent. An
    # explicit research request says why no ledger exists so callers cannot
    # overstate it as a completed read check (ADR-0021).
    if [ "$CTX_NO_TASK" -eq 1 ]; then
      printf 'context pending: no task workspace; nothing tracked\n'
    fi
    return 0
  fi
  ledger=$(_ctx_ledger_file "$CTX_TASK")
  _ctx_pending_paths "$rows" "$ledger"
  rm -f "$rows"
}

ctx_guard() {
  _ctx_parse_selectors "$@"

  local rows ledger pending tracked_count pending_count
  rows="${TMPDIR:-/tmp}/jig-context-required.$$"
  _ctx_required_rows "$rows"

  # T0 and T1 deliberately have no workspace (jig-task), so there is no ledger
  # to check. Saying so out loud is the whole point: a skill can call the guard
  # unconditionally, and the report never implies a check that did not happen.
  if [ -z "$CTX_TASK" ]; then
    rm -f "$rows"
    printf 'context guard: no task workspace; nothing tracked\n'
    return 0
  fi

  ledger=$(_ctx_ledger_file "$CTX_TASK")

  pending=$(_ctx_pending_paths "$rows" "$ledger")
  tracked_count=$(_ctx_tracked_paths "$rows" | sed '/^$/d' | wc -l | tr -d ' ')
  rm -f "$rows"

  if [ -z "$pending" ]; then
    printf 'context guard: ok (%s document(s) acknowledged)\n' "$tracked_count"
    return 0
  fi

  pending_count=$(printf '%s\n' "$pending" | sed '/^$/d' | wc -l | tr -d ' ')
  printf 'context guard: %s of %s document(s) not acknowledged:\n' \
    "$pending_count" "$tracked_count" >&2
  printf '%s\n' "$pending" | sed 's/^/  /' >&2
  printf 'read them, then: jig context acknowledge --task %s --files <list>\n' \
    "$CTX_TASK" >&2
  return 1
}

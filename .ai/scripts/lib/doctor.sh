# cmd_doctor — "does my environment work", for the person running jig rather
# than for a task in flight (ARCHITECTURE.md, Scripts layout: reporting
# commands). Sourced by scripts/jig; defines cmd_doctor.
#
# Distinct from `status`, which answers "what is going on with my tasks" and
# must keep answering that and nothing else. `doctor` exists because Windows
# support widens the set of things that can be silently wrong before a task
# ever starts — no symlinks, no `jig` on PATH, a dropped executable bit after
# a Windows checkout — and an installer needs one command to run last, and a
# confused user one command to run first.
#
# A reporting command, in the narrow sense ARCHITECTURE.md carves out for
# `status`/`measure`: it sources peer libraries and calls their functions
# (jig_global_executable, jig_link_detect, upgrade_pending, manifest_source,
# _status_framework_versions, adapter_*_session_hook_hint) rather than
# recomputing any of their answers, and it never writes anything — including
# through `upgrade_pending`, which is backed by `cmd_upgrade --dry-run`.
#
# Must run both outside a git repository (global checks only) and inside an
# uninitialised one (global checks plus one line), so it calls neither
# jig_require_repo nor jig_require_init — both die, which would turn "your
# environment has a problem" into "doctor itself refuses to run".
# shellcheck shell=bash

# --- report lines ------------------------------------------------------------
#
# One line per check: a 6-column status word (`ok`, `warn` or `fail`, the
# widest padded to the others rather than the reverse) then "<check>: <what
# was seen>", and for warn/fail a second line naming the fix. Counters are
# the caller's locals (cmd_doctor), updated here by dynamic scope — the same
# pattern _upgrade_process_path uses for new_entries, so no check has to
# thread three counters through every call.

_doctor_line() {
  printf '%-6s%s: %s\n' "$1" "$2" "$3"
}

_doctor_ok() {
  _doctor_line ok "$1" "$2"
  ok_count=$((ok_count + 1))
}

_doctor_warn() {
  _doctor_line warn "$1" "$2"
  warn_count=$((warn_count + 1))
  [ -z "${3:-}" ] || printf '      fix: %s\n' "$3"
}

_doctor_fail() {
  _doctor_line fail "$1" "$2"
  fail_count=$((fail_count + 1))
  [ -z "${3:-}" ] || printf '      fix: %s\n' "$3"
}

# _doctor_bracket_list <value> — an `.ai/manifest` or `.ai/config.yaml`
# header value shaped `[a, b]` (jig.manifest's own `adapters:` line), as
# space-separated words. Mirrors config.sh's cfg_list, but manifest headers
# are read through manifest_header_get, never through cfg (bound to
# .ai/config.yaml) — the manifest, not the config, is what a project actually
# has installed, which is what "session hook" below must answer against.
_doctor_bracket_list() {
  printf '%s\n' "$1" | tr -d '[]' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# --- global checks (no repository required) ---------------------------------

_doctor_check_git() {
  local v
  if v=$(git --version 2>/dev/null); then
    _doctor_ok "git" "$v"
  else
    _doctor_fail "git" "not found on PATH" "install git: https://git-scm.com/downloads"
  fi
}

# Effective config (`git config --get`, not --local): a global identity is
# enough to commit from any project, and this is the same lookup `git commit`
# itself does. Both fields are named in one fix line rather than two, so a
# reader who is missing both is not told to run doctor twice.
_doctor_check_git_identity() {
  local name email missing="" fixes=""
  name=$(git config --get user.name 2>/dev/null) || name=""
  email=$(git config --get user.email 2>/dev/null) || email=""
  if [ -z "$name" ]; then
    missing="user.name"
    fixes='git config --global user.name "Your Name"'
  fi
  if [ -z "$email" ]; then
    if [ -n "$missing" ]; then missing="$missing, user.email"; else missing="user.email"; fi
    if [ -n "$fixes" ]; then
      fixes="$fixes; git config --global user.email you@example.com"
    else
      fixes="git config --global user.email you@example.com"
    fi
  fi
  if [ -n "$missing" ]; then
    _doctor_warn "git identity" "not set: $missing" "$fixes"
  else
    _doctor_ok "git identity" "$name <$email>"
  fi
}

# jig_global_executable already answers "which jig, if any, does PATH
# select, and is it a framework checkout" (common.sh); a missing global copy
# is a warn, not a fail, because a project's own installed copy
# (.ai/scripts/jig) works without one.
_doctor_check_global_jig() {
  local exe="$1" root version
  if [ -z "$exe" ]; then
    _doctor_warn "global jig" "not found on PATH" \
      "curl -fsSL https://raw.githubusercontent.com/fapost-lab/jig/main/install.sh | bash"
    return 0
  fi
  root="${exe%/scripts/jig}"
  if version=$(jig_declared_version "$root"); then
    _doctor_ok "global jig" "$exe ($version)"
  else
    _doctor_warn "global jig" "$exe (version unreadable)" \
      "curl -fsSL https://raw.githubusercontent.com/fapost-lab/jig/main/install.sh | bash"
  fi
}

# jig_link_detect (common.sh) is the single measurement of which kind of
# directory link this machine can make; a task worktree needs one (ADR-0029).
# "none" is a warn, not a fail — a project that never uses task worktrees is
# unaffected.
_doctor_check_link_kind() {
  jig_link_detect
  case "$_JIG_LINK_KIND" in
    symlink) _doctor_ok "directory links" "symlink" ;;
    junction) _doctor_ok "directory links" "junction (symlinks unavailable)" ;;
    *) _doctor_warn "directory links" "task worktrees are unavailable" \
         "enable Windows Developer Mode, or use a local NTFS or POSIX filesystem" ;;
  esac
}

# jig.cmd (the Windows launcher next to the global jig symlink) only matters
# on a machine that can run .cmd files at all — detected the same way the
# rest of the framework detects Windows-specific capabilities elsewhere: by
# asking for the tool, never by reading uname/OSTYPE (a POSIX layer on
# Windows, e.g. Git Bash, answers "MINGW"/"Darwin" inconsistently, while
# `command -v cmd` answers the actual question: can this shell hand work to
# cmd.exe).
_doctor_check_jigcmd_global() {
  local exe="$1" dir
  command -v cmd >/dev/null 2>&1 || return 0
  [ -n "$exe" ] || return 0
  dir=$(dirname "$exe")
  if [ -f "$dir/jig.cmd" ]; then
    _doctor_ok "jig.cmd (global)" "$dir/jig.cmd"
  else
    _doctor_warn "jig.cmd (global)" "missing next to $exe" \
      "update the global framework (jig self-update)"
  fi
}

# --- project checks (initialised project only) -------------------------------

# Reuses status.sh's own comparison rather than a second one: _status_
# framework_versions already reads the manifest version, resolves the global
# one through jig_declared_version and orders them with jig_version_newer,
# and prints the directional hint. Doctor only reformats that one line into
# its own ok/warn shape — recomputing the comparison here is exactly the
# "second implementation of the same answer" ARCHITECTURE.md's Scripts
# layout section warns against.
#
# It also leaves the outcome of that comparison in the caller's `version_state`
# and `version_project` (cmd_doctor's locals, by the same dynamic scope the
# counters above use), because the upgrade check below has to read it: the two
# lines answer different questions and a reader who is not told so reads them
# as a contradiction.
_doctor_check_framework_version() {
  local proj_version out first hint
  if ! manifest_exists; then
    _doctor_warn "framework version" "manifest missing" "jig init"
    return 0
  fi
  proj_version=$(manifest_header_get jig.version)
  version_project=$proj_version
  out=$(_status_framework_versions "$proj_version")
  # Its own "framework versions: " prefix is stripped, since _doctor_line
  # already prints the check name once; the rest of the line (project=...
  # global=... current/mismatch) is kept verbatim.
  first=${out%%$'\n'*}
  first=${first#framework versions: }
  hint=$(printf '%s\n' "$out" | sed -n 's/^hint: //p')
  case "$first" in
    *mismatch*) version_state=mismatch; _doctor_warn "framework version" "$first" "$hint" ;;
    *unavailable*) version_state=unavailable; _doctor_ok "framework version" "$first" ;;
    *) version_state=current; _doctor_ok "framework version" "$first" ;;
  esac
}

# upgrade_pending (upgrade.sh) is the same staleness check `jig status`'s
# drift line and `jig verify`'s refusal-to-run-stale gate both call; its 0/3
# contract ("3: pending state is unknown right now") is reused as-is rather
# than reimplemented, and its "unknown" case is a fail here — unlike status,
# where it is silently omitted — because doctor exists specifically to
# surface an environment problem the user should act on.
#
# Pending items and the framework version answer different questions: pending
# is this install measured against its source, the version is a number two
# checkouts declare. The two part company whenever the source moves without a
# release (the ordinary state of a framework checkout on an unmerged branch),
# and equally when a framework-owned file is edited or deleted here, or a
# profile is added to .ai/config.yaml — so the line says which question pending
# answers and names the source, rather than naming a cause it has not checked.
# A reader shown "current" above and "41 pending" here otherwise reads a plain
# contradiction. `version_state` and `version_project` come from the version
# check above, which runs first (cmd_doctor).
_doctor_check_upgrade() {
  local pending rc=0 n src=""
  pending=$(upgrade_pending) || rc=$?
  if [ "$rc" != 0 ]; then
    # shellcheck disable=SC2016
    _doctor_fail "upgrade check" "cannot determine pending state" \
      'run `jig upgrade --dry-run` to see the error'
    return 0
  fi
  n=$(printf '%s\n' "$pending" | grep -c . || true)
  if [ "$n" -eq 0 ]; then
    _doctor_ok "upgrade check" "up to date"
    return 0
  fi
  # upgrade_pending returned 0, so its dry run resolved the source root; a
  # source that cannot be read at all lands in the fail branch above.
  src=$(manifest_source 2>/dev/null) || src=""
  if [ "$version_state" = current ] && [ -n "$src" ]; then
    _doctor_warn "upgrade check" \
      "$n pending item(s) although the version is the same ($version_project): pending measures this install against its source, $src" \
      "jig upgrade"
  else
    _doctor_warn "upgrade check" "$n pending item(s)" "jig upgrade"
  fi
}

# Windows loses the executable bit on checkout more easily than POSIX loses
# anything: a plain `git clone` on NTFS can hand back mode 100644 for a file
# the repository tracks as 100755 (core.fileMode defaults to false there).
# Read from the index (`git ls-files -s`), not the working tree's real
# permission bits, for the same reason the executable-bits rule in the
# manifest is a hash of *content*: the question is "did the file this
# project tracks lose its bit", not "what does this filesystem report",
# which for an NTFS-backed checkout would misreport nearly everything.
# Untracked entry points (not yet committed) are not in the index at all and
# are silently out of scope, matching the task's own instruction.
_doctor_check_executable_bits() {
  local t line mode path bad="" tracked_any=0 list
  t=$(printf '\t')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tracked_any=1
    mode=${line%% *}
    path=${line#*"$t"}
    [ "$mode" = "100755" ] || bad="$bad
$path"
  done < <(git -C "$JIG_PROJECT" ls-files -s -- \
    .ai/scripts/jig .ai/scripts/jig-session-hook '.ai/profiles/*/verify.sh' 2>/dev/null)
  bad=$(printf '%s\n' "$bad" | sed '/^$/d')
  if [ -n "$bad" ]; then
    list=$(printf '%s\n' "$bad" | tr '\n' ' ' | sed 's/ $//')
    _doctor_warn "executable bits" "missing +x: $list" "git add --chmod=+x $list"
  elif [ "$tracked_any" = 1 ]; then
    _doctor_ok "executable bits" "tracked entry points executable"
  else
    _doctor_ok "executable bits" "not committed yet"
  fi
}

_doctor_check_jigcmd_project() {
  command -v cmd >/dev/null 2>&1 || return 0
  if [ -f "$JIG_PROJECT/$JIG_AI_DIR/scripts/jig.cmd" ]; then
    _doctor_ok "jig.cmd (project)" "$JIG_AI_DIR/scripts/jig.cmd"
  else
    _doctor_warn "jig.cmd (project)" "missing" "jig upgrade"
  fi
}

# Mirrors status.sh's _status_session_hook (same source lookup, same
# adapter_<name>_session_hook_hint contract, same exit-2-means-"not
# applicable" convention, ADR-0024) but reports per-adapter ok/warn lines
# with a fix instead of one collapsed "installed"/"not installed" line, and
# reads the adapter list from the manifest header rather than
# .ai/config.yaml: the manifest is what this project actually has installed,
# and doctor's other project checks (framework version, upgrade check) are
# already keyed off it.
_doctor_check_session_hooks() {
  local source a adir hint rc fix
  source=$(manifest_source 2>/dev/null) || return 0
  [ -n "$source" ] || return 0
  [ -d "$source/adapters" ] || return 0
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"

  for a in $(_doctor_bracket_list "$(manifest_header_get adapters)"); do
    adir=$(adapters_dir "$source/adapters" "$a") || continue
    [ -f "$adir/adapter.sh" ] || continue
    # shellcheck disable=SC1090
    . "$adir/adapter.sh"
    command -v "adapter_${a}_session_hook_hint" >/dev/null 2>&1 || continue
    rc=0
    hint=$("adapter_${a}_session_hook_hint" "$JIG_PROJECT") || rc=$?
    if [ "$rc" = 2 ]; then
      _doctor_ok "session hook ($a)" "not applicable to this runtime"
      continue
    fi
    if [ -n "$hint" ]; then
      if command -v "adapter_${a}_install_session_hook" >/dev/null 2>&1; then
        fix="jig init --session-hook"
      else
        fix="see the hint above"
      fi
      _doctor_warn "session hook ($a)" "not installed" "$fix"
    else
      _doctor_ok "session hook ($a)" "installed"
    fi
  done
}

# Whether each installed runtime's instruction file carries Jig's workflow; the
# adapter answers, as for the session hook. A warn, not a fail: jig itself
# works, but the agent will not follow its routes until the section is merged.
_doctor_check_instructions() {
  local source a adir hint file recorded section
  source=$(manifest_source 2>/dev/null) || return 0
  [ -n "$source" ] || return 0
  [ -d "$source/adapters" ] || return 0
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"
  # shellcheck source=lib/section.sh
  . "$JIG_LIB/section.sh"

  # The same answer `jig status` prints, from the same function: a section
  # jig cannot reach is as much a problem as no section at all, and the two
  # reports may not disagree about which it is.
  recorded=$(manifest_instructions_section 2>/dev/null) || recorded=""
  section=$(jig_section_report_state "$JIG_PROJECT/AGENTS.md" "$recorded")

  for a in $(_doctor_bracket_list "$(manifest_header_get adapters)"); do
    adir=$(adapters_dir "$source/adapters" "$a") || continue
    [ -f "$adir/adapter.sh" ] || continue
    # shellcheck disable=SC1090
    . "$adir/adapter.sh"
    command -v "adapter_${a}_instructions_hint" >/dev/null 2>&1 || continue
    hint=$("adapter_${a}_instructions_hint" "$JIG_PROJECT") || hint=""
    if [ -n "$hint" ]; then
      file=$("adapter_${a}_instructions_file")
      _doctor_warn "instructions ($a)" "no Jig section in $file" \
        "run the jig-init skill, which merges the section with your consent"
    elif [ "$section" = unmarked ]; then
      _doctor_warn "instructions ($a)" "Jig section in AGENTS.md is not marked, so upgrades cannot reach it" \
        "run the jig-init skill, which adds the markers with your consent"
    elif [ "$section" = modified ]; then
      _doctor_ok "instructions ($a)" "Jig section changed here; upgrades keep your text"
    else
      _doctor_ok "instructions ($a)" "Jig section present and kept current"
    fi
  done
}

# Only when a local config file exists: whether git keeps it out of commits.
# config.sh answers (jig_config_local_ignored), as it does for status.
_doctor_check_config_local() {
  local file
  file=$(jig_config_local_file)
  [ -f "$file" ] || return 0
  if jig_config_local_ignored; then
    _doctor_ok "config.local" "ignored by git"
  else
    _doctor_warn "config.local" "not ignored by git, can be committed" "jig init"
  fi
}

# Whether .ai/config.yaml still describes the set of keys this version reads.
# Not a fault, and never a fail: an absent key takes its default and
# everything works, which is the design (schemas/config.md). But that file is
# also the only place a person ever sees which keys exist, and an upgrade does
# not touch it (ADR-0024) — so after one it keeps describing the version it
# was written for, and a key added since is a capability nobody was told
# about. That is an environment fact, which is doctor's question, and not
# anything a task is waiting on, which is why it is not a `status` line.
#
# It is also the other half of a question doctor already half-answers:
# _doctor_check_agent_git below reports a local-only key written into
# .ai/config.yaml, where nothing reads it. One command answers both.
#
# Silent when there is nothing to say, like _doctor_check_config_local above
# and the two jig.cmd checks: a report printed on every run is a report that
# stops being read. config.sh decides what counts (jig_config_unmentioned
# leaves out the local-only keys, and counts a commented line as a mention).
_doctor_check_config_keys() {
  local unmentioned unknown n
  unmentioned=$(jig_config_unmentioned | tr '\n' ' ' | sed 's/ $//')
  unknown=$(jig_config_unknown | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$unmentioned" ]; then
    n=$(printf '%s\n' "$unmentioned" | wc -w | tr -d ' ')
    unmentioned=$(printf '%s\n' "$unmentioned" | sed 's/ /, /g')
    _doctor_ok "config keys" \
      "$n not mentioned in $JIG_AI_DIR/config.yaml, each on its default: $unmentioned (jig config keys)"
  fi
  if [ -n "$unknown" ]; then
    _doctor_warn "config keys" \
      "$JIG_AI_DIR/config.yaml sets keys jig does not read: $(printf '%s\n' "$unknown" | sed 's/ /, /g')" \
      "correct the spelling, or remove the lines (jig config keys lists every key)"
  fi
}

# Whether `agent.git` (JIG_CFG_LOCAL_ONLY_KEYS, config.sh) is in a state
# `jig task ship` can actually use: not shadowed by a project-layer value it
# will never read, and not an unrecognised word either way. config.sh answers
# both (jig_config_project_ignored, jig_agent_git), as it does for status.
_doctor_check_agent_git() {
  local ignored level
  ignored=$(jig_config_project_ignored | cut -f1)
  # Both problems are reported when both hold: an ignored project value must
  # not hide an invalid local one, which is what makes `task ship` refuse.
  if jig_has_line agent.git "$ignored"; then
    _doctor_warn "agent.git" "set in $JIG_AI_DIR/config.yaml, ignored there" \
      "move it to $JIG_AI_DIR/config.local.yaml"
    if level=$(jig_agent_git); then return 0; fi
  fi
  if level=$(jig_agent_git); then
    _doctor_ok "agent.git" "$level"
  else
    _doctor_warn "agent.git" "invalid value: $level (expected none|commit|push|pr|merge)" \
      "set agent.git to none, commit, push, pr or merge in $JIG_AI_DIR/config.local.yaml"
  fi
}

# --- cmd_doctor ---------------------------------------------------------------

cmd_doctor() {
  [ $# -eq 0 ] || jig_die "doctor: unknown argument: $1"

  local ok_count=0 warn_count=0 fail_count=0
  # Set by _doctor_check_framework_version, read by _doctor_check_upgrade.
  local version_state="" version_project=""
  local global_exe=""
  global_exe=$(jig_global_executable) || global_exe=""

  _doctor_check_git
  _doctor_check_git_identity
  _doctor_check_global_jig "$global_exe"
  _doctor_check_link_kind
  _doctor_check_jigcmd_global "$global_exe"

  local repo=""
  repo=$(jig_repo_root) || repo=""
  if [ -n "$repo" ]; then
    JIG_PROJECT=$(cd -P "$repo" 2>/dev/null && pwd -P) || JIG_PROJECT="$repo"
    export JIG_PROJECT
    if [ -f "$JIG_PROJECT/$JIG_AI_DIR/config.yaml" ]; then
      # shellcheck source=lib/manifest.sh
      . "$JIG_LIB/manifest.sh"
      # shellcheck source=lib/upgrade.sh
      . "$JIG_LIB/upgrade.sh"
      # shellcheck source=lib/status.sh
      . "$JIG_LIB/status.sh"

      _doctor_check_framework_version
      _doctor_check_upgrade
      _doctor_check_executable_bits
      _doctor_check_jigcmd_project
      _doctor_check_session_hooks
      _doctor_check_instructions
      _doctor_check_config_local
      _doctor_check_config_keys
      _doctor_check_agent_git
    else
      _doctor_warn "project" "not initialised" "jig init"
    fi
  fi

  printf 'doctor: %d ok, %d warn, %d fail\n' "$ok_count" "$warn_count" "$fail_count"
  [ "$fail_count" -eq 0 ]
}

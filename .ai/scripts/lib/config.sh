# Reader for .ai/config.yaml — flat YAML subset (domains/install).
# Keys are `section.key: value`; lists are inline `[a, b]`; no nesting.
#
# Two layers (ADR-0038): .ai/config.local.yaml, gitignored and owned by the
# person whose clone it is, then .ai/config.yaml, committed and owned by the
# project. The local layer answers only for JIG_CFG_LOCAL_KEYS.
# shellcheck shell=bash

# Keys whose answer may differ between contributors without changing what the
# project does: they govern gitignored state on one machine, or a place on its
# disk. Everything else — base branch, profiles, forge — must be the same for
# every contributor and for CI, so a local value for it is ignored and
# reported by `jig status`. Adding a key here is a decision about that test,
# not a convenience; record it in schemas/config.md. `git.delete_merged_branches`
# is one: which of its own branches a clone keeps is that clone's business
# (adr-20261007-a-merged-branch-leaves-with-its-work).
#
# `agent.git`, `autopilot.git`, `agent.ci_timeout`, `autopilot.unattended`,
# `autopilot.parallel` and `route.depth` are also in JIG_CFG_LOCAL_ONLY_KEYS
# below (with `run.exec`, `run.path` and the `claude.*_model` and
# `codex.*_model` and `executor.*` keys): they
# answer
# *only* from this list, never falling back to the project layer the way every
# other key here does.
JIG_CFG_LOCAL_KEYS="housekeeping.cadence housekeeping.fetch housekeeping.trash_ttl housekeeping.abandoned_ttl housekeeping.stale_after checkout.busy_ttl verify.busy_ttl git.worktree_root git.delete_merged_branches agent.git autopilot.git agent.ci_timeout autopilot.unattended autopilot.parallel route.depth release.merge run.exec run.path claude.implement_model claude.review_model codex.implement_model codex.review_model executor.implement_runtime executor.review_runtime executor.implement_model executor.review_model notify.telegram.token notify.telegram.chat_id notify.autopilot notify.interactive"

# Keys whose project-layer value `cfg` never reads at all: only the local
# file and the default answer. A key belongs here, rather than merely in
# JIG_CFG_LOCAL_KEYS, when a value committed to .ai/config.yaml would hand
# every contributor the same thing a local key exists to keep personal —
# `agent.git` grants an agent git rights, and a project-wide grant would make
# every contributor's agent commit, whether that contributor agreed to it or
# not (spec: .ai/specs/autopilot/). `autopilot.git` is the same grant for the
# shipping an autopilot run does, so a person can trust a run further, or less
# far, than the work they watch. `autopilot.unattended` lets a run ask
# nothing and `agent.ci_timeout` bounds how long a merge waits for CI: both
# decide what one person's agent does on their behalf, for the same reason
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci).
# `autopilot.parallel` bounds how many task agents a phase run builds at once,
# which is a question about one person's machine and their tolerance for
# agents working unwatched, not about the project.
# `route.depth` trades one person's time against process: `lean` trims the
# stages a class route allows trimming, never below the class's floor. A
# committed value would make that trade for every contributor
# (adr-20261002-route-depth-is-a-personal-choice).
# `release.merge` says whether this person's unattended agent may merge an
# epic's final pull request, which is the release: who merges one is the
# owner's choice, not the project's (this ADR amendment: ADR-0040, 2026-10-04).
# `run.exec` says where this machine runs the project's checks — a container
# on one laptop, the host on a colleague's — and a committed value would send
# every contributor's checks to one person's environment
# (adr-20261001-checks-run-where-the-project-runs). `run.path` is the same
# question for a host runtime that is not first on PATH (Laravel Herd): a
# directory on one person's machine.
# The `claude.*_model` and `codex.*_model` keys name the model a stage is
# handed to when the agent delegates it to a subagent: which model is worth
# its cost depends on one person's plan, runtime and budget, and a committed
# value would spend every contributor's. Jig carries the value as an opaque
# string and never interprets it; empty means no delegation
# (adr-20261005-jig-names-the-roles-not-the-models).
# `executor.*_runtime` selects which installed runtime owns a stage. This is
# personal because it chooses a process, account and permission boundary;
# `executor.*_model` is an optional opaque model for that external process.
# Neither setting grants the process a new permission in a project config.
# `notify.telegram.token` and `notify.telegram.chat_id` say where one person's
# Telegram messages go, and `notify.autopilot` whether their autopilot runs
# send any: a committed token is a bot anyone can use once it is pushed, and a
# committed chat id would send every contributor's stops to one person
# (adr-20261009-autopilot-stops-reach-telegram). `notify.interactive` says
# whether an ordinary session that waits for them sends one too, through the
# hook they opted into (adr-20261010-a-waiting-session-reaches-telegram).
# `jig_config_project_ignored` reports a project-layer value here so it does
# not silently do nothing.
JIG_CFG_LOCAL_ONLY_KEYS="agent.git autopilot.git agent.ci_timeout autopilot.unattended autopilot.parallel route.depth release.merge run.exec run.path claude.implement_model claude.review_model codex.implement_model codex.review_model executor.implement_runtime executor.review_runtime executor.implement_model executor.review_model notify.telegram.token notify.telegram.chat_id notify.autopilot notify.interactive"

# Path of the config file for the current project (JIG_PROJECT must be set).
jig_config_file() { printf '%s/%s/config.yaml\n' "$JIG_PROJECT" "$JIG_AI_DIR"; }

# jig_config_clone_root — the main checkout of the clone JIG_PROJECT belongs
# to. A worktree answers with the checkout it was added from, so one local
# file serves every worktree of a clone, including one made after the file.
#
# Read from git's own files rather than `git rev-parse --git-common-dir`: cfg
# runs in a command substitution per key, where a cached answer does not
# survive, and the session hook promises no git on its idle path. A worktree's
# `.git` is a file naming its git directory, and that directory's `commondir`
# names the shared one. Anything else — a main checkout, a submodule (no
# commondir), a separate git dir or a bare repository (common dir not named
# .git) — answers JIG_PROJECT itself.
jig_config_clone_root() {
  local line="" gitdir root
  if [ -f "$JIG_PROJECT/.git" ]; then
    IFS= read -r line < "$JIG_PROJECT/.git" || [ -n "$line" ] || line=""
    gitdir=${line#gitdir: }
    if [ -n "$gitdir" ] && [ "$gitdir" != "$line" ]; then
      root=$(
        common="" here=""
        cd "$JIG_PROJECT" 2>/dev/null || exit 1
        cd "$gitdir" 2>/dev/null || exit 1
        [ -f commondir ] || exit 1
        IFS= read -r common < commondir || [ -n "$common" ] || exit 1
        cd "$common" 2>/dev/null || exit 1
        # No `case` here: bash 3.2 misparses its `)` inside `$( )`.
        here=$(pwd -P)
        [ "${here##*/}" = .git ] || exit 1
        cd .. && pwd -P
      ) && { printf '%s\n' "$root"; return 0; }
    fi
  fi
  printf '%s\n' "$JIG_PROJECT"
}

# Path of the local config file for the current clone.
jig_config_local_file() { printf '%s/%s/config.local.yaml\n' "$(jig_config_clone_root)" "$JIG_AI_DIR"; }

# jig_config_local_key <key> — exit 0 when <key> may be set in the local file.
jig_config_local_key() {
  case " $JIG_CFG_LOCAL_KEYS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# jig_config_local_only_key <key> — exit 0 when <key> answers only from the
# local file and the default: the project layer is never consulted for it
# (JIG_CFG_LOCAL_ONLY_KEYS).
jig_config_local_only_key() {
  case " $JIG_CFG_LOCAL_ONLY_KEYS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- the key inventory --------------------------------------------------------

# jig_config_keys — one `<key> <default>` line per configuration key jig reads,
# in the order schemas/config.md tables them. The key is the first word; the
# rest of the line is the default, written the way a person writes it in the
# file (`[claude, codex]`, not the space-separated form `cfg_list` hands back).
#
# Whether a key is local is deliberately not repeated here: JIG_CFG_LOCAL_KEYS
# and JIG_CFG_LOCAL_ONLY_KEYS above already answer that, and a second copy of
# a fact is a second thing to keep true. jig_config_key_scope reads them.
#
# This list is written by hand, and `tests/config.t.sh` is what keeps it
# honest. That test greps scripts/ for every `cfg`, `cfg_bool`, `cfg_list` and
# `cfg_list_lines` call and refuses to pass unless the call sites, this list,
# schemas/config.md, templates/config.yaml and docs/configuration.mdx agree on
# one set of keys and one set of defaults. A list nothing computes is a list
# that lapses — RULES.md says exactly that about its own deletion paragraph —
# so the computing lives in the test, where a false positive is a failure
# somebody fixes, and not in the report, where it would be a lie told to a
# user.
jig_config_keys() {
  cat <<'EOF'
profiles [generic]
adapters [claude, codex]
git.base_branch main
git.branch_per_task true
git.branch_template task/{id}
git.worktree_root ../<project>.worktrees
git.delete_merged_branches true
worktree.carry []
worktree.share []
forge auto
task.issue_pattern
housekeeping.cadence 1d
housekeeping.fetch true
housekeeping.trash_ttl 7d
housekeeping.abandoned_ttl 14d
housekeeping.stale_after 60d
checkout.busy_ttl 12h
agent.git none
autopilot.git
agent.ci_timeout 30
autopilot.unattended false
autopilot.parallel 2
route.depth full
release.merge agent
knowledge.require_frontmatter true
verify.full_run local
verify.busy_ttl 30m
run.exec auto
run.path auto
claude.implement_model
claude.review_model
codex.implement_model
codex.review_model
executor.implement_runtime
executor.review_runtime
executor.implement_model
executor.review_model
notify.telegram.token
notify.telegram.chat_id
notify.autopilot true
notify.interactive false
EOF
}

# jig_config_key_known <key> — exit 0 when <key> is a key jig reads.
jig_config_key_known() {
  jig_has_line "$1" "$(jig_config_keys | cut -d' ' -f1)"
}

# jig_config_key_scope <key> — which file answers for <key>: `project`,
# `local` (the local file wins, .ai/config.yaml still answers when it is
# silent) or `local only` (the project layer is never read). Derived from the
# two lists above, never stored a second time.
jig_config_key_scope() {
  if jig_config_local_only_key "$1"; then
    printf 'local only\n'
  elif jig_config_local_key "$1"; then
    printf 'local\n'
  else
    printf 'project\n'
  fi
}

# _cfg_mentions <file> <key> — exit 0 when <file> has a line that mentions
# <key>, a commented one included.
#
# A comment counts, unlike in _config_has_key, and the difference is the whole
# point: that function asks what `cfg` will read, this one asks what the file
# tells a person. `# verify.full_run: local` sets nothing and documents the
# key, and templates/config.yaml ships three keys exactly that way — read
# strictly, a project would be told on its first day that it is missing them.
_cfg_mentions() {
  [ -f "$1" ] || return 1
  JIG_CFG_KEY="$2" awk '
    BEGIN { k = ENVIRON["JIG_CFG_KEY"]; n = length(k) + 1 }
    {
      line = $0
      sub(/^[ \t]*#*[ \t]*/, "", line)
      if (substr(line, 1, n) == k ":") { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# jig_config_unmentioned — one line per key this version reads that the
# project's .ai/config.yaml says nothing about, commented lines counted as
# saying something. Reporting only, for `jig doctor` and `jig config keys`:
# every one of these keys is answering on its default right now and nothing is
# broken (schemas/config.md). What is broken is the file as documentation —
# after an upgrade it goes on describing the version it was written for, so a
# key added since is one nobody was told about.
#
# JIG_CFG_LOCAL_ONLY_KEYS are left out. `cfg` never reads the project layer
# for them, so naming one here would send a person to write a line that does
# nothing; the opposite mistake, one of them written into that file anyway, is
# what jig_config_project_ignored reports.
jig_config_unmentioned() {
  local file key rest
  file=$(jig_config_file)
  [ -f "$file" ] || return 0
  while read -r key rest; do
    [ -n "$key" ] || continue
    if jig_config_local_only_key "$key"; then continue; fi
    _cfg_mentions "$file" "$key" || printf '%s\n' "$key"
  done < <(jig_config_keys)
}

# jig_config_unknown — one line per key the project's .ai/config.yaml sets
# that jig does not read at all: a misspelling, or a key a later version
# removed. Only lines that actually set a key, never a comment — a key named
# in prose is documentation, and a typo in a comment sets nothing.
jig_config_unknown() {
  local file key
  file=$(jig_config_file)
  [ -f "$file" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    jig_config_key_known "$key" || printf '%s\n' "$key"
  done < <(sed -n 's/^\([A-Za-z0-9_.-]*\):.*/\1/p' "$file" | awk '!seen[$0]++')
}

# jig_config_project_ignored — "<key><TAB><value>" for every local-only key
# that is nonetheless set in the project's .ai/config.yaml, where `cfg` never
# reads it. Reporting only, for `jig status` and `jig doctor`: nothing here
# changes what `cfg` answers.
jig_config_project_ignored() {
  local key value
  for key in $JIG_CFG_LOCAL_ONLY_KEYS; do
    value=$(_cfg_read "$(jig_config_file)" "$key")
    [ -n "$value" ] || continue
    printf '%s\t%s\n' "$key" "$value"
  done
}

# jig_config_local_ignored — exit 0 when git ignores the local file, so its
# settings cannot reach a commit. Only reporting commands ask: cfg reads the
# file either way (ADR-0038), and this costs a git process.
jig_config_local_ignored() {
  local root
  root=$(jig_config_clone_root)
  git -C "$root" check-ignore -q "$JIG_AI_DIR/config.local.yaml" 2>/dev/null
}

# jig_config_local_entries — one `<key><TAB><value><TAB>local|ignored` line per
# key set in the local file, in file order; nothing when there is no file.
# `ignored` is a key outside JIG_CFG_LOCAL_KEYS, including a misspelt one.
jig_config_local_entries() {
  local file key value
  file=$(jig_config_local_file)
  [ -f "$file" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value=$(_cfg_read "$file" "$key")
    [ -n "$value" ] || continue
    if jig_config_local_key "$key"; then
      printf '%s\t%s\tlocal\n' "$key" "$value"
    else
      printf '%s\t%s\tignored\n' "$key" "$value"
    fi
  done < <(sed -n 's/^\([A-Za-z0-9_.-]*\):.*/\1/p' "$file" | awk '!seen[$0]++')
}

# _cfg_read <file> <key> — the value of <key> in one file, or nothing.
# The first matching line wins; a trailing `# comment` is not part of it.
_cfg_read() {
  [ -f "$1" ] || return 0
  sed -n "s/^${2}:[[:space:]]*//p" "$1" | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | head -n 1
}

# cfg <key> [default] — print the scalar value of <key>: the local file when
# the key may be set there, then .ai/config.yaml, then the default. An empty
# value falls through to the next layer. A JIG_CFG_LOCAL_ONLY_KEYS key stops
# after the local file: its project layer is never read, by design (see the
# comment above that list).
cfg() {
  local key="$1" default="${2:-}" value=""
  if jig_config_local_key "$key"; then
    value=$(_cfg_read "$(jig_config_local_file)" "$key")
  fi
  if [ -z "$value" ] && ! jig_config_local_only_key "$key"; then
    value=$(_cfg_read "$(jig_config_file)" "$key")
  fi
  printf '%s\n' "${value:-$default}"
}

# cfg_list <key> [default-list] — print an inline list as space-separated words.
cfg_list() {
  cfg "$1" "${2:-}" | tr -d '[]' | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# cfg_list_lines <key> — items of an inline list `key: [a, b]`, one per line,
# quotes stripped; nothing when the key is absent or empty. A bare scalar is
# read as a one-item list, and `a, b` without brackets splits the same way.
#
# The reader to use for paths. cfg_list prints one space-separated line, and
# every caller consumes it with a bareword `for p in $list`, which lets bash
# apply pathname expansion to a glob-shaped item and silently replace the
# literal pattern with whatever files happen to match — or with nothing.
# Same hazard, same answer and same shape as _profiles_list_lines in
# scripts/lib/profiles.sh.
cfg_list_lines() {
  local raw
  raw=$(cfg "$1" "")
  [ -n "$raw" ] || return 0
  case "$raw" in
    \[*\]) raw=$(printf '%s' "$raw" | sed 's/^\[//; s/\]$//') ;;
  esac
  printf '%s\n' "$raw" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/' \
    | sed '/^$/d'
}

# cfg_bool <key> [default] — exit 0 when the value is true/yes/1.
cfg_bool() {
  case "$(cfg "$1" "${2:-false}")" in
    true|yes|1|on) return 0 ;;
    *) return 1 ;;
  esac
}

# jig_agent_git — print agent.git's level (none|commit|push|pr|merge,
# default none) and exit 0; for anything else, still print the value read (so a
# caller can report *what* was invalid) and exit 1. Never `jig_die`s itself:
# `jig status` must be able to report an invalid value without dying, the
# same reason `_hk_forge_init`/`jig_forge_kind` split validation from the die
# they do use in a command that may fairly refuse to run at all.
jig_agent_git() {
  local value
  value=$(cfg agent.git none)
  printf '%s\n' "$value"
  _cfg_agent_git_level "$value"
}

# jig_autopilot_git — `<level><TAB><key>`: the git level an autopilot run
# ships at, and the key it came from. `autopilot.git` when this clone sets it,
# else `agent.git`: nothing has to be filled in, and a clone without the key
# ships a run exactly as it ships everything else. Exit 1, still printing the
# value read and its key, when the level is not one of
# none|commit|push|pr|merge, like jig_agent_git: a set but invalid
# autopilot.git never falls back to agent.git, because the person who set it
# did not mean agent.git.
jig_autopilot_git() {
  local value
  value=$(cfg autopilot.git "")
  if [ -n "$value" ]; then
    printf '%s\tautopilot.git\n' "$value"
    _cfg_agent_git_level "$value"
    return
  fi
  value=$(cfg agent.git none)
  printf '%s\tagent.git\n' "$value"
  _cfg_agent_git_level "$value"
}

# _cfg_agent_git_level <value> — exit 0 when <value> is an agent.git level.
# Shared by the reader above and `jig config set`, so the two cannot disagree.
_cfg_agent_git_level() {
  case "$1" in
    none | commit | push | pr | merge) return 0 ;;
    *) return 1 ;;
  esac
}

# jig_ci_timeout — print agent.ci_timeout, the minutes a merge waits for the
# pull request's checks (default 30; 0 looks once and does not wait), and exit
# 0; for anything but a whole number, print the value read and exit 1, like
# jig_agent_git.
jig_ci_timeout() {
  local value
  value=$(cfg agent.ci_timeout 30)
  if ! _cfg_minutes "$value"; then
    printf '%s\n' "$value"
    return 1
  fi
  printf '%s\n' "$((10#$value))"
}

# _cfg_minutes <value> — exit 0 when <value> is a whole number of minutes
# agent.ci_timeout accepts: digits only, at most four of them.
_cfg_minutes() {
  case "$1" in
    '' | *[!0-9]* | ?????*) return 1 ;;
    *) return 0 ;;
  esac
}

# jig_unattended — exit 0 when this clone opted in to autopilot runs that ask
# nothing (`autopilot.unattended: true`, local-only). Read once by `task
# autopilot start`, which records the answer for the run, and by `spec ship`,
# whose epic finish has no run to record it in.
jig_unattended() {
  [ "$(cfg autopilot.unattended false)" = true ]
}

# jig_autopilot_parallel — print autopilot.parallel, how many tasks of a
# roadmap phase a coordinator may have agents building at once (default 2), and
# exit 0; for anything but a whole number in 1..16, print the value read and
# exit 1, like jig_agent_git. Only agents *building* a task count: one whose
# work is consolidated and waiting for its turn to ship holds no slot, and the
# short-lived agents that repair the merge queue are outside the limit
# (adr-20260922-a-phase-run-is-coordinated).
jig_autopilot_parallel() {
  local value
  value=$(cfg autopilot.parallel 2)
  if ! _cfg_parallel "$value"; then
    printf '%s\n' "$value"
    return 1
  fi
  printf '%s\n' "$((10#$value))"
}

# jig_release_merge — print release.merge, who merges an epic's final pull
# request in an unattended run at `agent.git: merge`: `agent` (the default,
# as before) or `human`, which opens it and leaves the merge — the release —
# to the person. Exit 1 with the value read for anything else, which every
# reader takes as `human`: a mistake never merges a release.
jig_release_merge() {
  local value
  value=$(cfg release.merge agent)
  if _cfg_release_merge "$value"; then
    printf '%s\n' "$value"
  else
    printf 'human\n'
    return 1
  fi
}

_cfg_release_merge() {
  case "$1" in
    agent | human) return 0 ;;
    *) return 1 ;;
  esac
}

# jig_route_depth — print route.depth, how much of a class's route this
# person runs (`full`, the default, or `lean`), and exit 0; for anything else
# print the value read and exit 1, like jig_agent_git. Every reader takes an
# invalid value as `full`: a mistake costs process, never a stage
# (adr-20261002-route-depth-is-a-personal-choice).
jig_route_depth() {
  local value
  value=$(cfg route.depth full)
  printf '%s\n' "$value"
  _cfg_route_depth "$value"
}

# _cfg_route_depth <value> — exit 0 when <value> is a route depth. Shared by
# the reader above, `jig config set` and `jig task`, so they cannot disagree.
_cfg_route_depth() {
  case "$1" in
    full | lean) return 0 ;;
    *) return 1 ;;
  esac
}

# _cfg_chat_id <value> — exit 0 when <value> is a Telegram chat id: digits,
# with a leading `-` for a group, or a public `@name`. Shared by `jig config
# set` and the sender (notify.sh), which checks a value written by hand before
# it uses it.
_cfg_chat_id() {
  case "$1" in
    @*) case "${1#@}" in '' | *[!A-Za-z0-9_]*) return 1 ;; esac ;;
    -*) case "${1#-}" in '' | *[!0-9]*) return 1 ;; esac ;;
    *) case "$1" in '' | *[!0-9]*) return 1 ;; esac ;;
  esac
  return 0
}

# _cfg_secret_key <key> — exit 0 when <key>'s value is a secret no command
# prints: `jig config show`, `jig config set` and `jig status` print
# JIG_CFG_MASK in its place (adr-20261009-autopilot-stops-reach-telegram).
JIG_CFG_MASK='********'
_cfg_secret_key() {
  [ "$1" = notify.telegram.token ]
}

# _cfg_parallel <value> — exit 0 when <value> is a count autopilot.parallel
# accepts: digits only, 1 to 16. Shared by the reader above and
# `jig config set`, so the two cannot disagree. The ceiling is not a measured
# limit of any machine; it is low enough that a typo cannot start a swarm.
_cfg_parallel() {
  case "$1" in
    '' | *[!0-9]* | ???*) return 1 ;;
  esac
  [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 16 ]
}

# jig_config_value_problem <key> <value> — print why <value> cannot be set for
# the local key <key>, and exit 1; print nothing and exit 0 when it can. The
# rules are the readers' own, so a value `jig config set` accepts is one every
# reader understands the way the person meant it:
# - housekeeping.cadence: whole days (`<n>d` or `<n>`), because the session
#   hook and `jig status` read it in days and treat anything else as 1d;
# - the other housekeeping durations, checkout.busy_ttl and verify.busy_ttl:
#   `<n>[dhms]`, `jig_duration_seconds` — `0` is a legal value for
#   verify.busy_ttl and means "never wait";
# - housekeeping.fetch, git.delete_merged_branches and autopilot.unattended:
#   `true` or `false` — cfg_bool
#   would take yes/1/on too, jig_unattended only `true`; the one spelling
#   both read alike;
# - agent.git, autopilot.git and agent.ci_timeout: the checks of jig_agent_git and
#   jig_ci_timeout;
# - autopilot.parallel: the check of jig_autopilot_parallel;
# - route.depth: the check of jig_route_depth;
# - release.merge: `agent` or `human`;
# - git.worktree_root: any path _cfg_read gives back unchanged;
# - run.exec: `auto`, `host` or a command prefix of plain words — runenv.sh
#   splits it on blanks and interprets nothing, so a quote, `$`, backtick or
#   backslash would reach the command as a literal character;
# - run.path: `auto` or the absolute path of a directory, unquoted — read as
#   one value, so a blank inside it is kept (Herd's macOS home has one); a
#   relative one would name a different folder from wherever verify starts;
# - claude.*_model and codex.*_model: anything — the value is
#   the runtime's to understand, never Jig's
#   (adr-20261005-jig-names-the-roles-not-the-models);
# - notify.telegram.chat_id: a chat id, digits with an optional `-`, or an
#   `@name`; notify.autopilot and notify.interactive: `true` or `false`;
# - notify.telegram.token: never — a token on a command line is in `ps`, the
#   shell's history and the agent's transcript, so it is written into the file
#   by hand (adr-20261009-autopilot-stops-reach-telegram).
# Nothing may hold a line break, a `#` (_cfg_read cuts a comment there) or
# surrounding blanks (it trims them).
jig_config_value_problem() {
  local key="$1" value="$2" nl cr
  nl=$(printf '\nx'); nl=${nl%x}
  cr=$(printf '\r')
  case "$value" in
    '') printf 'an empty value; leave the key out to use the default\n'; return 1 ;;
    *"$nl"* | *"$cr"*) printf 'a line break\n'; return 1 ;;
    *'#'*) printf "a '#', which the file reads as the start of a comment\n"; return 1 ;;
    [[:space:]]* | *[[:space:]]) printf 'leading or trailing blanks\n'; return 1 ;;
  esac
  case "$key" in
    housekeeping.cadence)
      case "${value%d}" in
        '' | *[!0-9]* | ?????????*) printf 'not a whole number of days (e.g. 1d, 3d)\n'; return 1 ;;
      esac
      ;;
    housekeeping.trash_ttl | housekeeping.abandoned_ttl | housekeeping.stale_after \
      | checkout.busy_ttl | verify.busy_ttl)
      case "${value%[dhms]}" in
        '' | *[!0-9]* | ?????????*) printf 'not a duration (e.g. 7d, 12h, 30m, 90s)\n'; return 1 ;;
      esac
      ;;
    housekeeping.fetch | git.delete_merged_branches | autopilot.unattended | notify.autopilot \
      | notify.interactive)
      case "$value" in
        true | false) ;;
        *) printf 'not true or false\n'; return 1 ;;
      esac
      ;;
    agent.git | autopilot.git)
      _cfg_agent_git_level "$value" \
        || { printf 'not a level: none, commit, push, pr or merge\n'; return 1; }
      ;;
    agent.ci_timeout)
      _cfg_minutes "$value" \
        || { printf 'not a whole number of minutes (0 to 9999)\n'; return 1; }
      ;;
    autopilot.parallel)
      _cfg_parallel "$value" \
        || { printf 'not a whole number of tasks (1 to 16)\n'; return 1; }
      ;;
    route.depth)
      _cfg_route_depth "$value" \
        || { printf 'not a depth: full or lean\n'; return 1; }
      ;;
    release.merge)
      _cfg_release_merge "$value" \
        || { printf 'not agent or human\n'; return 1; }
      ;;
    run.exec)
      case "$value" in
        *[\"\'\`\$\\]*)
          printf 'a quote, $, backtick or backslash; write the command prefix as plain words (e.g. docker compose exec -T app)\n'
          return 1
          ;;
      esac
      ;;
    run.path)
      case "$value" in
        auto | /* | [A-Za-z]:[\\/]*) ;;
        *) printf 'not auto or an absolute path of a folder\n'; return 1 ;;
      esac
      ;;
    git.worktree_root)
      case "$value" in
        \"* | \'*) printf 'quoted; write the path without quotes\n'; return 1 ;;
      esac
      ;;
    executor.implement_runtime | executor.review_runtime)
      case "$value" in
        claude | codex) ;;
        *) printf 'not a runtime: claude or codex\n'; return 1 ;;
      esac
      ;;
    claude.implement_model | claude.review_model | codex.implement_model | codex.review_model | executor.implement_model | executor.review_model) ;;
    notify.telegram.chat_id)
      _cfg_chat_id "$value" \
        || { printf 'not a chat id: digits (a group starts with -), or @name\n'; return 1; }
      ;;
    notify.telegram.token)
      printf 'a bot token is never set on a command line, where ps, the shell history and the transcript keep it; run %s/scripts/jig notify setup in your own terminal, or write the line notify.telegram.token: <token> into %s/config.local.yaml yourself\n' "$JIG_AI_DIR" "$JIG_AI_DIR"
      return 1
      ;;
    *) printf 'not a local key\n'; return 1 ;;
  esac
  return 0
}

# --- jig config ---------------------------------------------------------------
# `jig config set <key> <value> [<key> <value>...] --local [--dry-run]`,
# `jig config unset <key> [<key>...] --local [--dry-run]` and
# `jig config show --local`. Writes only the clone's .ai/config.local.yaml,
# and never .ai/config.yaml: that file is the team's, edited by hand and
# reviewed like code (ADR-0038).
#
# `set` writes only keys in JIG_CFG_LOCAL_KEYS and only values the readers
# accept. `unset` takes any key the file holds, local or not: a key no reader
# answers from is exactly the one a person wants gone, and refusing it would
# leave the only way to remove it a hand edit of a file the tooling owns
# (ADR-0001).

# Referenced from the EXIT trap, so global (convention-shell).
_CONFIG_TMP=""

cmd_config() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    set) _config_set "$@" ;;
    unset) _config_unset "$@" ;;
    show) _config_show "$@" ;;
    keys) _config_keys "$@" ;;
    help | -h | --help)
      printf 'usage: jig config set <key> <value> [<key> <value>...] --local [--dry-run]\n'
      printf '       jig config unset <key> [<key>...] --local [--dry-run]\n'
      printf '       jig config show --local\n'
      printf '       jig config keys\n'
      printf 'local keys: %s\n' "$JIG_CFG_LOCAL_KEYS"
      ;;
    '') jig_die "config: missing subcommand (usage: jig config set|unset|show|keys ...)" ;;
    *) jig_die "config: unknown subcommand: $sub (usage: jig config set|unset|show|keys ...)" ;;
  esac
}

# _config_display_path <file> — <file> relative to the project when inside it.
_config_display_path() {
  case "$1" in
    "$JIG_PROJECT"/*) printf '%s\n' "${1#"$JIG_PROJECT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_config_refuse_project() {
  jig_die "config $1: only --local is supported: .ai/config.yaml is the team's file, edited by hand and reviewed like code; your own settings go in .ai/config.local.yaml (jig config $1 ... --local)"
}

# _config_warn_ignored <shown path> — the warning `jig status` prints.
_config_warn_ignored() {
  jig_config_local_ignored \
    || jig_warn "config: $1 is not ignored by git and can be committed (fix: jig init)"
}

_config_show() {
  local local_flag=0 file shown
  while [ $# -gt 0 ]; do
    case "$1" in
      --local) local_flag=1; shift ;;
      *) jig_die "config show: unknown argument: $1 (usage: jig config show --local)" ;;
    esac
  done
  [ "$local_flag" = 1 ] || _config_refuse_project show
  jig_require_repo
  file=$(jig_config_local_file)
  shown=$(_config_display_path "$file")
  if [ ! -f "$file" ]; then
    printf 'no local settings: %s does not exist\n' "$shown"
    return 0
  fi
  _config_print_masked "$file"
  # Then the keys in it that no reader answers from — the `ignored` kind of
  # jig_config_local_entries, the same answer `jig status` gives. Printing the
  # file alone showed a misspelt or non-local key as if it were a setting,
  # which is the one thing this command must not do; each is named with the
  # command that removes it, since `jig config set` cannot.
  jig_config_local_entries | awk -F'\t' '
    $3 == "ignored" {
      printf "ignored: %s (not a local key; jig config unset %s --local)\n", $1, $1
    }'
}

# _config_print_masked <file> — <file> as it is, except that a secret
# (_cfg_secret_key) reads JIG_CFG_MASK: what this prints lands in an agent's
# transcript. Every `config` output that shows the file goes through here —
# `show`, and the `--dry-run` of `set` and `unset`. Masked twice over: the
# line that sets the key, and the value itself wherever it appears, read the
# way `cfg` reads it (_cfg_read matches the key as a pattern, so a line
# `notify_telegram_token:` answers for it too).
_config_print_masked() {
  local secret
  secret=$(_cfg_read "$1" notify.telegram.token)
  JIG_CFG_MASK_VALUE="$JIG_CFG_MASK" JIG_CFG_SECRET="$secret" awk '
    BEGIN { m = ENVIRON["JIG_CFG_MASK_VALUE"]; s = ENVIRON["JIG_CFG_SECRET"]; k = "notify.telegram.token:" }
    substr($0, 1, length(k)) == k { print k " " m; next }
    {
      line = $0
      if (s != "") {
        out = ""
        while ((i = index(line, s)) > 0) {
          out = out substr(line, 1, i - 1) m
          line = substr(line, i + length(s))
        }
        line = out line
      }
      print line
    }
  ' "$1"
}

# _config_keys — `jig config keys`. Every key jig reads, its default, which
# file answers for it, and whether this project's .ai/config.yaml mentions it
# at all. Read-only, and the one command that can answer "which keys exist" —
# `config show` prints a file, and a file only names the keys somebody
# already wrote down.
#
# No `--local` here, and no refusal without it: the other subcommands guard a
# write to a file the team owns, and this one writes nothing.
_config_keys() {
  [ $# -eq 0 ] || jig_die "config keys: unknown argument: $1 (usage: jig config keys)"
  # jig_require_init, not jig_require_repo: the last column is what this
  # project's .ai/config.yaml mentions, and without that file every key would
  # be reported as unmentioned, which is true of nothing.
  jig_require_init
  local file key default note
  file=$(jig_config_file)
  printf '%-31s%-25s%s\n' "key" "default" "answered by"
  while read -r key default; do
    [ -n "$key" ] || continue
    # An empty default — a key that is off until a person sets it — prints as
    # `-`, so the columns still read as columns.
    [ -n "$default" ] || default=-
    note=""
    if ! jig_config_local_only_key "$key" && ! _cfg_mentions "$file" "$key"; then
      note="not mentioned in $JIG_AI_DIR/config.yaml"
    fi
    # Two formats rather than one padded to the widest: a row with no note
    # would otherwise end in blanks, which every diff and every editor that
    # strips them would then argue about.
    if [ -n "$note" ]; then
      printf '%-31s%-25s%-13s%s\n' "$key" "$default" "$(jig_config_key_scope "$key")" "$note"
    else
      printf '%-31s%-25s%s\n' "$key" "$default" "$(jig_config_key_scope "$key")"
    fi
  done < <(jig_config_keys)
  printf '\n'
  printf 'local: may be set in %s/config.local.yaml, which wins for it\n' "$JIG_AI_DIR"
  printf 'local only: read from %s/config.local.yaml and never from config.yaml\n' "$JIG_AI_DIR"
  printf 'a key nothing mentions is answering on its default; nothing is wrong, and\n'
  printf 'nothing but a person edits %s/config.yaml (ADR-0024)\n' "$JIG_AI_DIR"
}

# _config_apply <in> <out> <key> <value> — <in> with <key> set to <value>: the
# first `<key>:` line replaced, the one `cfg` reads, else a line appended.
# The value reaches awk through the environment, where a backslash in a path
# stays a backslash (`awk -v` would read it as an escape).
_config_apply() {
  JIG_CFG_KEY="$3" JIG_CFG_VALUE="$4" awk '
    BEGIN { k = ENVIRON["JIG_CFG_KEY"]; v = ENVIRON["JIG_CFG_VALUE"]; n = length(k) + 1 }
    !done && substr($0, 1, n) == k ":" { print k ": " v; done = 1; next }
    { print }
    END { if (!done) print k ": " v }
  ' "$1" > "$2"
}

_config_set() {
  local local_flag=0 dry=0 n=0 key value problem file dir shown i
  # The pairs, in order: an array, because a value is checked for line breaks
  # below and must reach that check intact.
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --local) local_flag=1; shift ;;
      --dry-run) dry=1; shift ;;
      --*) jig_die "config set: unknown flag: $1 (usage: jig config set <key> <value> [<key> <value>...] --local [--dry-run])" ;;
      *) args[n]="$1"; n=$((n + 1)); shift ;;
    esac
  done
  [ "$local_flag" = 1 ] || _config_refuse_project set
  if [ "$n" -eq 0 ] || [ $((n % 2)) -ne 0 ]; then
    jig_die "config set: expected <key> <value> pairs (usage: jig config set <key> <value> [<key> <value>...] --local [--dry-run])"
  fi

  # Every pair is checked before anything is written: one bad value leaves
  # the file as it was.
  i=0
  while [ "$i" -lt "$n" ]; do
    key=${args[i]}; value=${args[i + 1]}
    if ! jig_config_local_key "$key"; then
      jig_die "config set: $key is not a local key; the local file answers only for: $JIG_CFG_LOCAL_KEYS (anything else belongs to the team's .ai/config.yaml, edited by hand)"
    fi
    if ! problem=$(jig_config_value_problem "$key" "$value"); then
      if _cfg_secret_key "$key"; then
        jig_die "config set: $key: refused: $problem"
      fi
      jig_die "config set: $key: invalid value '$value': $problem"
    fi
    i=$((i + 2))
  done

  jig_require_repo
  file=$(jig_config_local_file)
  dir=${file%/*}
  shown=$(_config_display_path "$file")
  [ -d "$dir" ] || jig_die "config set: no $JIG_AI_DIR/ directory at ${dir%/*}; run jig init there first"

  _CONFIG_TMP="$file.tmp.$$"
  jig_cleanup_add "$_CONFIG_TMP"
  jig_cleanup_add "$_CONFIG_TMP.next"
  if [ -f "$file" ]; then
    cat "$file" > "$_CONFIG_TMP"
  else
    printf '%s\n' \
      "# Your own Jig settings for this clone: gitignored, never committed." \
      "# Only local keys are read from here (jig config set --local)." > "$_CONFIG_TMP"
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    _config_apply "$_CONFIG_TMP" "$_CONFIG_TMP.next" "${args[i]}" "${args[i + 1]}"
    mv "$_CONFIG_TMP.next" "$_CONFIG_TMP"
    i=$((i + 2))
  done

  if [ "$dry" = 1 ]; then
    _config_print_masked "$_CONFIG_TMP"
    rm -f "$_CONFIG_TMP"
    printf 'config: dry run, nothing written to %s\n' "$shown" >&2
    _config_warn_ignored "$shown"
    return 0
  fi
  mv "$_CONFIG_TMP" "$file"
  # A setting can change what a read reports (the git level and unattended
  # mode decide what a person may do next), so a written one raises the
  # clone's revision.
  jig_record_changed
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'config: %s: %s (%s)\n' "${args[i]}" "${args[i + 1]}" "$shown"
    i=$((i + 2))
  done
  _config_warn_ignored "$shown"
}

# _config_has_key <file> <key> — exit 0 when <file> has a line setting <key>.
# The same anchoring _cfg_read and _config_apply use, so "is it there", "what
# does it read" and "what does a write replace" cannot disagree.
_config_has_key() {
  JIG_CFG_KEY="$2" awk '
    BEGIN { k = ENVIRON["JIG_CFG_KEY"]; n = length(k) + 1 }
    substr($0, 1, n) == k ":" { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# _config_remove <in> <out> <key> — <in> without any line that sets <key>.
# Every occurrence, not only the first one `cfg` reads: reporting a key as
# removed while a later duplicate still sets it is the kind of half-truth this
# command exists to clear away.
_config_remove() {
  JIG_CFG_KEY="$3" awk '
    BEGIN { k = ENVIRON["JIG_CFG_KEY"]; n = length(k) + 1 }
    substr($0, 1, n) == k ":" { next }
    { print }
  ' "$1" > "$2"
}

# _config_unset — `jig config unset <key> [<key>...] --local [--dry-run]`.
#
# Any key the file holds, local or not (see the section header). A key the file
# does not hold is reported and costs nothing: this is how a person clears out
# what `jig status` and `jig config show` call `ignored`, and a refusal there
# would send them back to editing the file by hand.
_config_unset() {
  local local_flag=0 dry=0 n=0 key file shown i removed=0
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --local) local_flag=1; shift ;;
      --dry-run) dry=1; shift ;;
      --*) jig_die "config unset: unknown flag: $1 (usage: jig config unset <key> [<key>...] --local [--dry-run])" ;;
      *) args[n]="$1"; n=$((n + 1)); shift ;;
    esac
  done
  [ "$local_flag" = 1 ] || _config_refuse_project unset
  [ "$n" -gt 0 ] \
    || jig_die "config unset: missing key (usage: jig config unset <key> [<key>...] --local [--dry-run])"

  # A key is a name the file's own grammar allows (jig_config_local_entries
  # reads exactly this set); anything else could never be in the file, so
  # saying so beats silently removing nothing.
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${args[i]}" in
      '' | *[!A-Za-z0-9_.-]*)
        jig_die "config unset: not a key name: '${args[i]}' (letters, digits, '.', '_' and '-')" ;;
    esac
    i=$((i + 1))
  done

  jig_require_repo
  file=$(jig_config_local_file)
  shown=$(_config_display_path "$file")
  if [ ! -f "$file" ]; then
    printf 'no local settings: %s does not exist\n' "$shown"
    return 0
  fi

  _CONFIG_TMP="$file.tmp.$$"
  jig_cleanup_add "$_CONFIG_TMP"
  jig_cleanup_add "$_CONFIG_TMP.next"
  cat "$file" > "$_CONFIG_TMP"
  # The report is built here, against the file as it still is, so "unset" and
  # "not set" say what actually happened rather than what was asked for.
  local report=""
  i=0
  while [ "$i" -lt "$n" ]; do
    key=${args[i]}
    if _config_has_key "$_CONFIG_TMP" "$key"; then
      _config_remove "$_CONFIG_TMP" "$_CONFIG_TMP.next" "$key"
      mv "$_CONFIG_TMP.next" "$_CONFIG_TMP"
      removed=$((removed + 1))
      report="$report$(printf 'config: unset %s (%s)' "$key" "$shown")
"
    else
      report="$report$(printf 'config: %s is not set (%s)' "$key" "$shown")
"
    fi
    i=$((i + 1))
  done

  if [ "$dry" = 1 ]; then
    # stdout is the file that would be written and nothing else, as it is for
    # `config set --dry-run`: `jig-setup` shows that output to a person as the
    # file. The per-key lines go to stderr with the dry-run notice, and say
    # "would unset", because this run removed nothing. A secret still in the
    # file is masked, as `show` masks it.
    _config_print_masked "$_CONFIG_TMP"
    rm -f "$_CONFIG_TMP"
    printf '%s' "$report" | sed 's/^config: unset /config: would unset /' >&2
    printf 'config: dry run, nothing written to %s\n' "$shown" >&2
    return 0
  fi
  # An untouched file is left untouched, mtime included: nothing was asked of
  # it that it did not already satisfy.
  if [ "$removed" -gt 0 ]; then
    mv "$_CONFIG_TMP" "$file"
    jig_record_changed
  else
    rm -f "$_CONFIG_TMP"
  fi
  printf '%s' "$report"
}

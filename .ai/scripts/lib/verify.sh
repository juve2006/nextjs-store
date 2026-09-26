# cmd_verify — run active profiles' checks (ARCHITECTURE.md, Scripts layout;
# domains/verify). Sourced by
# scripts/jig; defines cmd_verify.
#
# Scope protocol (ADR-0013): with --changed, the changed-file list is computed
# once here and handed to each profile that declares `scope: [changed]` in its
# profile.yaml, through JIG_VERIFY_SCOPE and JIG_VERIFY_FILES. A profile that
# does not declare support is run unscoped and reported as such: a silently
# ignored scope would make `pass` mean something different per profile.
#
# CI-backed projects (ADR-0041): `verify.full_run: ci` in .ai/config.yaml is
# the project's claim that its CI runs the full set. A flag-less `jig verify`
# then narrows to what changed since the merge base with git.base_branch,
# unless CI is set or --full is given. A project map
# (.ai/verify/<profile>.map) is parsed here, never in a profile, and handed to
# profiles declaring `scope: [changed, map]` as JIG_VERIFY_MAPPED.
#
# One run per clone, and a run that dies is not a pass
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass): a run
# takes a record every worktree of the clone can see and waits while another
# holds it, and a profile that was killed rather than failed is reported as a
# third outcome, `incomplete`, with exit code 3.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# --- scope helpers -----------------------------------------------------------

# _verify_changed_files [<base>] — repo-relative paths of files that differ
# from <base> (when given) or from HEAD, plus untracked files, one per line,
# sorted and deduplicated. Staged and unstaged changes both count: a project
# is verified in the state it is in, not in the state it was committed in.
_verify_changed_files() {
  local base="$1"
  if [ -n "$base" ]; then
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
      || jig_die "verify: not a commit: $base"
  fi
  {
    [ -z "$base" ] || git -C "$JIG_PROJECT" diff --name-only "$base" --
    git -C "$JIG_PROJECT" rev-parse --verify --quiet HEAD >/dev/null \
      && git -C "$JIG_PROJECT" diff --name-only HEAD --
    git -C "$JIG_PROJECT" ls-files --others --exclude-standard
  } 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u
}

# _verify_ref_label <ref> — how a base ref reads in the report:
# refs/remotes/origin/main -> origin/main, refs/heads/main -> main.
_verify_ref_label() {
  local ref="$1"
  ref=${ref#refs/remotes/}
  ref=${ref#refs/heads/}
  printf '%s\n' "$ref"
}

# _verify_map_check <map> — validate a project map before anything uses it.
# Prints `<line>: <reason>` for the first bad line and exits 1; exits 0 when
# every line is usable. A line is `<glob> <decision>...` where the decision is
# `-`, `ALL`, or one or more filters; `-` and `ALL` stand alone. Checked as a
# whole, not only the lines a run happens to match: a line that is wrong today
# narrows the wrong way the day a path starts matching it.
_verify_map_check() {
  local map="$1" line n=0 glob rest tok count special
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # A map saved on Windows ends its lines in CR; the filter must not.
    line=${line//$'\r'/}
    line=${line%%#*}
    # Word splitting must not expand a glob against the working directory.
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [ $# -gt 0 ] || continue
    glob="$1"
    shift
    [ $# -gt 0 ] || { printf '%d: no decision for %s\n' "$n" "$glob"; return 1; }
    count=$#
    special=0
    for tok in "$@"; do
      case "$tok" in
        -|ALL) special=1 ;;
      esac
    done
    if [ "$special" = 1 ] && [ "$count" -gt 1 ]; then
      rest="$*"
      printf "%d: '-' and 'ALL' stand alone: %s\n" "$n" "$rest"
      return 1
    fi
  done < "$map"
  return 0
}

# _verify_map_apply <map> <files> — one `<path><TAB><decision>` line per path
# in <files>: the tokens of the first map line whose glob matches, or `?` when
# none does. Globs follow `detect`: `**` and `*` both match across `/`, and a
# glob is matched against the path string, never the filesystem. Run only on
# a map _verify_map_check accepted.
_verify_map_apply() {
  local map="$1" files="$2" path line glob decision found
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    found=0
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line//$'\r'/}
      line=${line%%#*}
      # Word splitting must not expand a glob against the working directory.
      set -f
      # shellcheck disable=SC2086
      set -- $line
      set +f
      [ $# -gt 0 ] || continue
      glob=${1//\*\*/*}
      shift
      # shellcheck disable=SC2254
      case "$path" in
        $glob) decision="$*"; found=1; break ;;
      esac
    done < "$map"
    [ "$found" = 1 ] || decision='?'
    printf '%s\t%s\n' "$path" "$decision"
  done < "$files"
}

# --- one run per clone -------------------------------------------------------
#
# Eight agents, each obeying "avoid simultaneous duplicate full runs" with one
# run of its own, produced eight full sets on one machine: load average 364, a
# set that takes 5-6 minutes alone taking forty, and two reviews stalled at 40
# and 50 minutes. The rule was written for one actor and says nothing about a
# population, so nobody broke it. What was missing is a fact the machine can
# see for itself.
#
# Waiting, not refusing: run serially and the eight sets finish at 6, 12, 18 …
# 48 minutes — seven of the eight answers sooner than under contention, the
# average at 27 minutes against forty, only the last later by one set's length.
# What settles it is everything else on the machine: the two reviews that
# stalled at 40 and 50 minutes were not running a suite, they were queued
# behind eight of them. A refusal would break CI and honest parallel work; a
# warning is the same prose that already failed.

# _verify_busy_dir — where the record lives, or nothing.
#
# The clone's main checkout, which `jig_config_clone_root` already computes by
# reading git's own files — one answer from every worktree, no `git` process.
# ADR-0038 made reading there a named exception to ADR-0008; this extends it to
# writing, because what is being protected belongs to no checkout: the CPU is
# one per clone, and the eight runs were in eight different worktrees.
_verify_busy_dir() {
  local root
  root=$(jig_config_clone_root) || return 1
  [ -n "$root" ] || return 1
  printf '%s/%s/runtime/verify\n' "$root" "$JIG_AI_DIR"
}

# _verify_busy_ttl — how long a record still counts, in seconds. `0` is a
# duration the grammar already spells, and it switches the whole mechanism off:
# the escape for someone who genuinely wants parallel local runs, without a new
# flag to learn.
#
# One key with a working default, never one a person must fill. The duration
# grammar is the framework's one (`jig_duration_seconds`), and a mistyped value
# leaves the default standing rather than taking `jig verify` down.
_verify_busy_ttl() {
  local raw seconds
  raw=$(cfg verify.busy_ttl "30m")
  seconds=$(jig_duration_seconds "$raw" 2>/dev/null) || seconds=""
  case "$seconds" in
    '' | *[!0-9]*) seconds=1800 ;;
  esac
  printf '%s\n' "$seconds"
}

# _verify_busy_mtime <file> — the file's mtime in seconds, or nothing.
#
# The BSD-then-GNU pair the session hook and the checkout record use, but
# **chosen on the value, never on the exit status** — and that distinction is
# the whole of this comment, because getting it wrong silently disabled the
# lock on every GNU system.
#
# `stat -f '%m' <file>` under GNU coreutils does not simply fail: `-f` means
# --file-system, so `%m` is read as a FILE operand, which errors, and then the
# real file prints a **file-system block on stdout**. The command exits
# non-zero, so `cmd && return 0` falls through to the GNU form and appends the
# real mtime to that block. The caller then holds several lines where it
# expected a number, rejects them, and reads the record's holder as gone: on
# Linux and in Git Bash the record was never once seen as live, and
# `jig verify` never waited for anything. It passed on macOS, where BSD stat
# answers the first form, which is exactly how it reached CI.
#
# `_jig_checkout_mtimes` survives the same idiom only because it reads its
# output line by line and skips what is not numeric. This reads one file, so it
# checks the value it got instead.
_verify_busy_mtime() {
  local out
  out=$(stat -f '%m' "$1" 2>/dev/null) || out=""
  case "$out" in
    '' | *[!0-9]*) out=$(stat -c '%Y' "$1" 2>/dev/null) || out="" ;;
  esac
  case "$out" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# _verify_busy_value <file> <key> — the first `<key>: <value>` line, read by the
# shell alone. The CR is stripped explicitly because `read` keeps one where sed
# would not, and this record may be written under Windows.
_verify_busy_value() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "$key: "*)
        printf '%s\n' "${line#"$key": }"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# _verify_busy_holder <dir> <ttl> — "<age in seconds> <checkout>" when a live
# run holds the record, nothing when none does.
#
# Two independent tests, and the record is live only when both pass:
#
#   1. `kill -0 <pid>` — a shell builtin, not `ps`, which ADR-0002 rules out
#      and which behaves differently under Git Bash anyway. This is the normal
#      path: a run killed by the sandbox gives the clone back at the next poll,
#      and that is exactly the death this task was written about.
#   2. the record's mtime is within the ttl — the backstop for when (1) is
#      wrong: another user's process reads as dead (EPERM), a recycled pid
#      reads as alive. Both errors are bounded. "Wrongly dead" is today's
#      behaviour; "wrongly alive" waits no longer than the ttl.
#
# A record with no readable pid falls back to the ttl alone, so a torn read can
# only cost a wait, never a wrong start.
_verify_busy_holder() {
  local dir="$1" ttl="$2" file mtime now age pid checkout
  file="$dir/busy/run"
  [ -f "$file" ] || return 1
  mtime=$(_verify_busy_mtime "$file") || return 1
  case "$mtime" in
    '' | *[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  if [ "$now" -lt "$mtime" ]; then age=0; else age=$((now - mtime)); fi
  [ "$age" -le "$ttl" ] || return 1
  pid=$(_verify_busy_value "$file" pid) || pid=""
  case "$pid" in
    '' | *[!0-9]*) ;;
    "$$") return 1 ;;
    *) kill -0 "$pid" 2>/dev/null || return 1 ;;
  esac
  checkout=$(_verify_busy_value "$file" checkout) || checkout=""
  [ -n "$checkout" ] || checkout="another checkout"
  printf '%s %s\n' "$age" "$checkout"
}

# _verify_busy_claim <dir> — take the record, or fail.
#
# `mkdir` is the claim. Under ADR-0002 it is the one atomic primitive available
# on POSIX and in Git Bash alike, and atomicity is the whole point: with a plain
# flag file, eight waiters wake together when the holder leaves and produce the
# eight simultaneous sets again. The kernel is the arbiter, so the reclaim of an
# expired record races safely too.
#
# The body is written straight into the claimed directory rather than through a
# temporary: only the claimant can write there, a reader that catches a partial
# file falls back to the ttl, and a leftover temporary would make `rmdir` refuse
# for good.
_verify_busy_claim() {
  local dir="$1"
  mkdir "$dir/busy" 2>/dev/null || return 1
  printf 'checkout: %s\npid: %s\n' "$JIG_PROJECT" "$$" > "$dir/busy/run" 2>/dev/null || {
    rmdir "$dir/busy" 2>/dev/null || true
    return 1
  }
  return 0
}

# _verify_busy_release <dir> — give the record back.
#
# The shape ADR-0035 allows `jig spec new`: one named file removed, then
# `rmdir`, which refuses a directory that is not empty. No `rm -rf` on a
# computed path anywhere, and the path is checked to be the one this code
# builds before anything is deleted (RULES.md).
_verify_busy_release() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  case "$dir" in
    */"$JIG_AI_DIR"/runtime/verify) ;;
    *) return 0 ;;
  esac
  rm -f "$dir/busy/run" 2>/dev/null || true
  rmdir "$dir/busy" 2>/dev/null || true
  return 0
}

# _verify_busy_acquire — hold the clone for this run, waiting while another has
# it. Sets JIG_VERIFY_BUSY to the directory when the record is ours, so the
# EXIT trap gives it back, and prints one line to stdout when a wait happened:
# the evidence belongs in the report, while the waiting itself goes to stderr,
# where it cannot become part of output a caller reads.
#
# Nothing here may fail `jig verify`. Every path that cannot answer gives up and
# lets the run go ahead: a record that cannot be taken is a missed serialisation,
# which is today's behaviour, while a refusal would be a new way to break.
_verify_busy_acquire() {
  local dir ttl holder age checkout waited=0 announced=0 said=0 ago futile=0

  # CI parallelism is deliberate and each job has a machine of its own. `CI` is
  # the signal this command already trusts for `verify.full_run` (ADR-0041), so
  # the mechanism is off there rather than queueing jobs meant to run at once.
  [ -z "${CI:-}" ] || return 0

  ttl=$(_verify_busy_ttl)
  [ "$ttl" -gt 0 ] || return 0
  dir=$(_verify_busy_dir) || return 0
  [ -n "$dir" ] || return 0

  # A `jig verify` started by a run that already holds this clone — a suite that
  # verifies its own project — must not wait for itself.
  [ "${JIG_VERIFY_BUSY_HELD:-}" != "$dir" ] || return 0

  # A directory that cannot be made at all — a read-only clone root, a
  # permission the agent does not have — is not a reason to refuse to verify.
  mkdir -p "$dir" 2>/dev/null || return 0

  while :; do
    if _verify_busy_claim "$dir"; then
      JIG_VERIFY_BUSY="$dir"
      export JIG_VERIFY_BUSY_HELD="$dir"
      if [ "$waited" -gt 0 ]; then
        printf 'verify: waited %s for the run in %s\n' \
          "$(jig_checkout_ago "$waited")" "$checkout"
      fi
      return 0
    fi
    holder=$(_verify_busy_holder "$dir" "$ttl") || holder=""
    if [ -z "$holder" ]; then
      # Nobody live is behind the record: take it back, by the two bounded
      # deletions above, and let the loop claim it. `mkdir` still decides
      # between two reclaimers.
      _verify_busy_release "$dir"
      # Neither claiming nor reclaiming worked, and nobody is holding it: the
      # filesystem is answering no, not another run. A few attempts allow for
      # losing the reclaim race to a neighbour; after that, verify anyway. A
      # record that cannot be taken is a missed serialisation, which is what
      # every run did until today — spinning here would be a new way to hang.
      futile=$((futile + 1))
      if [ "$futile" -ge 5 ]; then
        jig_info "verify: cannot take the run record in $dir; running without it"
        return 0
      fi
      continue
    fi
    futile=0
    age=${holder%% *}
    checkout=${holder#* }
    ago=$(jig_checkout_ago "$age")
    if [ "$announced" = 0 ]; then
      announced=1
      jig_info "verify: another run holds this clone (in $checkout, started $ago ago); waiting for it"
      jig_info "  two sets at once make both slower than running them in turn;" \
        "set verify.busy_ttl: 0 in .ai/config.local.yaml never to wait"
    elif [ $((waited - said)) -ge 60 ]; then
      said="$waited"
      jig_info "verify: still waiting ($(jig_checkout_ago "$waited"))"
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

# _verify_cleanup — the one EXIT trap: temporary files and the run record. Its
# variables are script-global, never `local`, because the trap runs after the
# function that set them has returned (conventions/shell.md).
_verify_cleanup() {
  rm -f "${JIG_VERIFY_TMP:-}" "${JIG_VERIFY_MAP_TMP:-}" 2>/dev/null || true
  if [ -n "${JIG_VERIFY_BUSY:-}" ]; then
    _verify_busy_release "$JIG_VERIFY_BUSY"
    JIG_VERIFY_BUSY=""
  fi
  return 0
}

cmd_verify() {
  jig_require_init
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"

  # Each --profile value is split on commas only (never on internal
  # whitespace) and every resulting token is validated immediately via
  # _profiles_valid_name. Splitting on generic whitespace instead of just
  # ',' would silently turn one malformed token containing a space (e.g.
  # "a b") into two well-formed single-word names, defeating validation
  # entirely; an entirely empty value (`--profile ''`) is checked up front
  # since piping an empty string through `tr`/`read` yields zero lines, not
  # one empty line, and would otherwise be dropped rather than rejected.
  local list_only=0 explain=0 profile_given=0 profiles_words="" p pdir raw tok
  local scope=0 base="" nfiles=0 scope_ok note full=0 explicit=0 full_run
  local header="" base_branch base_ref mb map map_ok map_err
  local incomplete=0 covered=0 explained=0 unknown=0 plan_output plan_bad
  JIG_VERIFY_TMP=""
  JIG_VERIFY_MAP_TMP=""
  JIG_VERIFY_BUSY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --changed) scope=1; explicit=1; shift ;;
      --full) full=1; shift ;;
      --base)
        [ $# -ge 2 ] || jig_die "verify: --base requires a value"
        base="$2"
        shift 2
        ;;
      --profile)
        [ $# -ge 2 ] || jig_die "verify: --profile requires a value"
        profile_given=1
        raw="$2"
        [ -n "$raw" ] || jig_die "invalid profile name: $raw"
        while IFS= read -r tok; do
          tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
          _profiles_valid_name "$tok" || jig_die "invalid profile name: $tok"
          case " $profiles_words " in
            *" $tok "*) ;;
            *) profiles_words="$profiles_words $tok" ;;
          esac
        done < <(printf '%s\n' "$raw" | tr ',' '\n')
        shift 2
        ;;
      --list) list_only=1; shift ;;
      --explain) explain=1; shift ;;
      *) jig_die "verify: unknown argument: $1" ;;
    esac
  done
  profiles_words="${profiles_words# }"

  if [ "$list_only" = 1 ] && [ "$explain" = 1 ]; then
    jig_die "verify: --list cannot be combined with --explain"
  fi

  [ "$profile_given" = 1 ] || profiles_words=$(profiles_active)

  local installed_dir
  installed_dir=$(profiles_installed_dir)

  if [ "$list_only" = 1 ]; then
    for p in $profiles_words; do
      pdir=$(profiles_dir "$installed_dir" "$p")
      if [ -d "$pdir" ]; then
        printf '%s: installed\n' "$p"
      else
        printf '%s: not installed\n' "$p"
      fi
    done
    return 0
  fi

  # --- mode -------------------------------------------------------------------
  # `verify.full_run` is a claim the project makes, so a value that is neither
  # answer is refused rather than read as one of them: a typo must not quietly
  # narrow every run, nor quietly stop narrowing.
  full_run=$(cfg verify.full_run local)
  case "$full_run" in
    local|ci) ;;
    *) jig_die "verify: invalid verify.full_run: $full_run (expected local or ci)" ;;
  esac

  if [ "$full" = 1 ] && { [ "$scope" = 1 ] || [ -n "$base" ]; }; then
    jig_die "verify: --full cannot be combined with --changed or --base"
  fi
  if [ -n "$base" ] && [ "$scope" = 0 ]; then
    [ "$full_run" = ci ] || jig_die "verify: --base requires --changed"
    explicit=1
  fi

  if [ "$full_run" = ci ] && [ "$scope" = 0 ] && [ "$explicit" = 0 ]; then
    # Explicit narrowing (--changed, --base) wins over CI; CI and --full win
    # over the configured default. Without the CI check, a project whose CI
    # calls `jig verify` would narrow the one run the key relies on.
    if [ "$full" = 1 ]; then
      header="verify: full run (--full)"
    elif [ -n "${CI:-}" ]; then
      header="verify: full run (CI is set)"
    else
      scope=1
      base_branch=$(cfg git.base_branch main)
      base_ref=$(jig_base_ref "$base_branch")
      mb=""
      if [ -n "$base_ref" ]; then
        mb=$(git -C "$JIG_PROJECT" merge-base "$base_ref" HEAD 2>/dev/null) || mb=""
      fi
      if [ -n "$mb" ]; then
        base="$mb"
        header=$(printf 'verify: scope changed since %s@%s (verify.full_run: ci, full set runs in CI)' \
          "$(_verify_ref_label "$base_ref")" "$(git -C "$JIG_PROJECT" rev-parse --short "$mb")")
      else
        header="verify: scope changed in the working tree only, no merge base with $base_branch (verify.full_run: ci, full set runs in CI)"
      fi
    fi
  elif [ "$full_run" = ci ] && [ "$scope" = 0 ] && [ -n "$base" ]; then
    scope=1
    header=$(printf 'verify: scope changed since %s (--base)' "$base")
  fi

  # --- staleness gate --------------------------------------------------------
  # A pass from a stale install is meaningless: refuse before running any
  # profile when the current config would still need `jig upgrade` to place
  # framework-owned files (a skill or profile added to the source but never
  # copied/linked in — the gap `jig status`'s drift count used to miss
  # entirely, since drift only covers paths already recorded in the
  # manifest). Skipped only for `--list`, handled above; not folded into the
  # `verify: %d profiles, ...` tally below, which counts profiles, not
  # framework files.
  # shellcheck source=lib/upgrade.sh
  . "$JIG_LIB/upgrade.sh"
  local fw_pending fw_pending_rc=0 fw_pending_n
  fw_pending=$(upgrade_pending) || fw_pending_rc=$?
  if [ "$fw_pending_rc" = 0 ]; then
    fw_pending_n=$(printf '%s\n' "$fw_pending" | grep -c . || true)
    if [ "$fw_pending_n" -gt 0 ]; then
      printf '%s\n' "$fw_pending"
      local fw_word='files'
      if [ "$fw_pending_n" = 1 ]; then fw_word='file'; fi
      printf 'FAIL framework: %d framework %s not installed (run jig upgrade)\n' \
        "$fw_pending_n" "$fw_word"
      return 1
    fi
  fi
  # fw_pending_rc != 0: pending state unknown (e.g. no source checkout on
  # this machine, domains/install) — proceed and verify the profiles normally.

  # One trap for both the temporary files and the run record: the record has to
  # come back on every exit, not only on a run that narrowed.
  trap '_verify_cleanup' EXIT INT TERM

  if [ "$scope" = 1 ]; then
    JIG_VERIFY_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-verify-files.XXXXXX") \
      || jig_die "verify: cannot create temporary file"
    _verify_changed_files "$base" > "$JIG_VERIFY_TMP"
    nfiles=$(grep -c . < "$JIG_VERIFY_TMP" || true)
  fi

  [ -z "$header" ] || printf '%s\n' "$header"

  # Taken here, after every refusal above has had its chance: nobody should
  # wait for the clone only to be told their arguments were wrong.
  if [ "$explain" = 0 ]; then
    _verify_busy_acquire
  else
    printf 'verify: plan only — no checks have run\n'
  fi

  profiles_check_requires

  local total=0 pass=0 failn=0 skip=0 rc
  for p in $profiles_words; do
    total=$((total + 1))
    pdir=$(profiles_dir "$installed_dir" "$p")

    if [ ! -d "$pdir" ]; then
      if [ "$explain" = 1 ]; then
        printf 'PLAN %s: unknown (not installed; run jig upgrade)\n' "$p"
        unknown=$((unknown + 1))
      else
        printf 'FAIL %s: not installed (run jig upgrade)\n' "$p"
        failn=$((failn + 1))
      fi
      continue
    fi

    # Did anything here have something to check? A profile that covers a stack
    # says yes by being here at all — the stack was recognised, whatever its
    # tools, or its missing verify.sh, then did. A fallback says nothing either
    # way. Asked before the checks below, so a profile that is installed but
    # broken still counts as "there was something to check": that is a defect to
    # fix, not a project nothing covers.
    if ! profiles_is_fallback "$pdir"; then
      covered=1
    fi

    if [ ! -f "$pdir/verify.sh" ]; then
      if [ "$explain" = 1 ]; then
        printf 'PLAN %s: unknown (no verify.sh)\n' "$p"
        unknown=$((unknown + 1))
      else
        printf 'SKIP %s: no verify.sh\n' "$p"
        skip=$((skip + 1))
      fi
      continue
    fi

    if [ "$explain" = 1 ] && ! profiles_supports "$pdir" explain; then
      printf 'PLAN %s: unknown (profile does not support explain)\n' "$p"
      unknown=$((unknown + 1))
      continue
    fi

    note=""
    scope_ok=0
    if [ "$scope" = 1 ]; then
      if profiles_supports "$pdir" changed; then
        scope_ok=1
        note=" (scope: changed, $nfiles files)"
      else
        note=" (scope ignored: profile declares no scope support, ran full set)"
      fi
    fi

    if [ "$scope_ok" = 1 ] && [ "$nfiles" -eq 0 ] && [ "$explain" = 0 ]; then
      skip=$((skip + 1))
      printf 'RESULT %s: skip (scope: changed, no changed files)\n' "$p"
      continue
    fi

    # The project map (ADR-0041): parsed here, once, so every profile reads
    # the same decisions. A broken map fails this profile without running it
    # — a line silently skipped would narrow the checks the wrong way.
    map_ok=0
    if [ "$scope_ok" = 1 ] && [ "$nfiles" -gt 0 ] && profiles_supports "$pdir" map; then
      map="$JIG_AI_DIR/verify/$p.map"
      if [ -f "$JIG_PROJECT/$map" ]; then
        if ! map_err=$(_verify_map_check "$JIG_PROJECT/$map"); then
          if [ "$explain" = 1 ]; then
            failn=$((failn + 1))
            printf 'PLAN %s: error (map %s:%s)\n' "$p" "$map" "$map_err"
          else
            failn=$((failn + 1))
            printf 'RESULT %s: fail (map %s:%s)\n' "$p" "$map" "$map_err"
          fi
          continue
        fi
        JIG_VERIFY_MAP_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-verify-map.XXXXXX") \
          || jig_die "verify: cannot create temporary file"
        _verify_map_apply "$JIG_PROJECT/$map" "$JIG_VERIFY_TMP" > "$JIG_VERIFY_MAP_TMP"
        map_ok=1
        note=" (scope: changed, $nfiles files, map $map)"
      fi
    fi

    # A profile without declared support is run with the scope variables
    # cleared, never merely unset by the caller's environment: an installed
    # verify.sh kept by `upgrade` as keep-modified must not read a scope it
    # was never written to honour.
    set +e
    # Run through `bash`, never exec the file directly: a profile committed
    # from Windows (or by any checkout that lost the executable bit, e.g.
    # `upgrade`'s keep-modified path copying a user file) has mode 100644,
    # and the result of a check must not depend on file mode.
    if [ "$explain" = 1 ]; then
      if [ "$map_ok" = 1 ]; then
        plan_output=$( cd "$JIG_PROJECT" \
          && JIG_VERIFY_EXPLAIN=1 JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
             JIG_VERIFY_MAPPED="$JIG_VERIFY_MAP_TMP" bash "$pdir/verify.sh" )
      elif [ "$scope_ok" = 1 ]; then
        plan_output=$( cd "$JIG_PROJECT" \
          && unset JIG_VERIFY_MAPPED \
          && JIG_VERIFY_EXPLAIN=1 JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
             bash "$pdir/verify.sh" )
      else
        plan_output=$( cd "$JIG_PROJECT" \
          && unset JIG_VERIFY_SCOPE JIG_VERIFY_FILES JIG_VERIFY_MAPPED \
          && JIG_VERIFY_EXPLAIN=1 bash "$pdir/verify.sh" )
      fi
    elif [ "$map_ok" = 1 ]; then
      ( cd "$JIG_PROJECT" \
        && unset JIG_VERIFY_EXPLAIN \
        && JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
           JIG_VERIFY_MAPPED="$JIG_VERIFY_MAP_TMP" \
           bash "$pdir/verify.sh" )
    elif [ "$scope_ok" = 1 ]; then
      ( cd "$JIG_PROJECT" \
        && unset JIG_VERIFY_EXPLAIN JIG_VERIFY_MAPPED \
        && JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
           bash "$pdir/verify.sh" )
    else
      ( cd "$JIG_PROJECT" \
        && unset JIG_VERIFY_EXPLAIN JIG_VERIFY_SCOPE JIG_VERIFY_FILES JIG_VERIFY_MAPPED \
        && bash "$pdir/verify.sh" )
    fi
    rc=$?
    set -e
    if [ "$map_ok" = 1 ]; then
      rm -f "$JIG_VERIFY_MAP_TMP"
      JIG_VERIFY_MAP_TMP=""
    fi

    if [ "$explain" = 1 ]; then
      plan_bad=$(printf '%s\n' "$plan_output" \
        | grep -vE "^PLAN $p: .+: (full|filtered|skip|conditional) \\(.+\\)$") || plan_bad=""
      if [ "$rc" -ne 0 ] || [ -z "$plan_output" ] || [ -n "$plan_bad" ]; then
        printf 'PLAN %s: error (profile explain contract failed)\n' "$p"
        failn=$((failn + 1))
      else
        printf '%s\n' "$plan_output"
        explained=$((explained + 1))
      fi
      continue
    fi

    # A run that died is neither a pass nor a fail. Exit code 3 is a profile
    # saying so; 128+N is the profile itself killed by a signal, which no
    # profile has to be taught — `Killed: 9` and `Terminated: 15` reach every
    # stack the same way.
    case "$rc" in
      0) pass=$((pass + 1)); printf 'RESULT %s: pass%s\n' "$p" "$note" ;;
      2) skip=$((skip + 1)); printf 'RESULT %s: skip%s\n' "$p" "$note" ;;
      3)
        incomplete=$((incomplete + 1))
        printf 'RESULT %s: incomplete%s\n' "$p" "$note"
        ;;
      *)
        if [ "$rc" -ge 128 ]; then
          incomplete=$((incomplete + 1))
          printf 'RESULT %s: incomplete (killed by signal %d)%s\n' "$p" "$((rc - 128))" "$note"
        else
          failn=$((failn + 1))
          printf 'RESULT %s: fail%s\n' "$p" "$note"
        fi
        ;;
    esac
  done

  if [ "$explain" = 1 ]; then
    printf 'verify: %d profiles explained, %d unknown, %d error; no checks ran\n' \
      "$explained" "$unknown" "$failn"
    if [ "$failn" -gt 0 ] || [ "$total" -eq 0 ]; then return 1; fi
    if [ "$unknown" -gt 0 ]; then return 2; fi
    return 0
  fi

  printf 'verify: %d profiles, %d pass, %d fail, %d skip, %d incomplete\n' \
    "$total" "$pass" "$failn" "$skip" "$incomplete"
  # Incomplete outranks fail: a run something was killed in is not evidence, so
  # the failures in it cannot be trusted either. Nothing is lost — a real
  # failure comes back on the next run, and an artefact of an overloaded
  # machine does not. Exit 3 means "run it again", never "it is broken".
  if [ "$incomplete" -gt 0 ]; then
    printf 'verify: the run did not finish, so it neither passed nor failed — run it again\n'
    return 3
  fi
  # A run in which nothing passed and nothing failed checked nothing, and the
  # exit code has to say so. `[ "$failn" -eq 0 ]` alone answered 0 for a set of
  # pure skips: on a project with no shellcheck and no test runner, `jig verify`
  # reported success having examined not one line of it, and `jig task ship` and
  # the autopilot read that code.
  #
  # But "nothing was checked" is two states, and only one of them is anybody's
  # fault. **The difference is whether there was anything to check.**
  #
  #   - A profile covering this stack took part and every check skipped: the
  #     stack was recognised and its tools are missing. There was something to
  #     check and it was not checked, for a reason somebody can fix. That is the
  #     blind pass this rule exists to stop, and it is refused — exit 3, sharing
  #     the code with the killed run because both mean no verdict was produced.
  #   - Only fallback profiles took part: no profile covers this project at all.
  #     There is nothing to install and nothing to wait for, so refusing would
  #     stop work over a state the person cannot resolve. It does not refuse —
  #     and it does not say `ok` either. It says plainly that nothing was
  #     checked, and `jig task ship` says it again at the moment of shipping,
  #     where it has consequences, rather than only here ten minutes earlier.
  if [ "$pass" -eq 0 ] && [ "$failn" -eq 0 ] && [ "$total" -gt 0 ]; then
    if [ "$covered" = 1 ]; then
      printf 'verify: nothing was checked, so this is not a pass — install the project'"'"'s tools so its profile can run\n'
      return 3
    fi
    printf 'verify: nothing here checks this project — no profile covers it, so this run verified nothing\n'
    return 0
  fi
  [ "$failn" -eq 0 ]
}

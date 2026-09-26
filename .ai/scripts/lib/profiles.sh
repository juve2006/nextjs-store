# Profile discovery, activation, detection and the requires closure
# (domains/verify). Sourced by scripts/lib/verify.sh; scripts/lib/init.sh also
# sources it directly to compute the profile suggestion at init time.
# Depends on scripts/lib/common.sh (JIG_AI_DIR, jig_source_root, jig_warn)
# and scripts/lib/config.sh (cfg_list), both already sourced by the
# dispatcher before any command library.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# --- profile.yaml reader -----------------------------------------------------

# profile_get <profile-dir> <key> — scalar value of <key> in
# <profile-dir>/profile.yaml. Same flat-YAML shape as .ai/config.yaml, but a
# plain file, not a frontmatter block, so it is read directly rather than
# through `cfg` (bound to .ai/config.yaml) or `fm_get` (bound to a
# frontmatter block). Prints the raw value, including a literal `[...]` for
# list keys — see _profiles_list_lines to read those. Prints nothing when
# the file or the key is absent.
profile_get() {
  local dir="$1" key="$2" file value
  file="$dir/profile.yaml"
  [ -f "$file" ] || return 0
  value=$(sed -n "s/^${key}:[[:space:]]*//p" "$file" | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' | head -n 1)
  printf '%s\n' "$value"
}

# _profiles_list_lines <profile-dir> <key> — items of an inline list
# `key: [a, b]`, one per line, quotes stripped. Prints nothing for a scalar
# value (e.g. generic's `detect: always`) or an absent key.
#
# One-per-line output is deliberate: every caller consumes it with
# `while read`, never a bareword `for` loop — an unquoted `for x in $list`
# would let bash apply pathname expansion to glob-shaped items such as
# `scripts/**/*.sh` against the real tree, silently replacing the literal
# pattern with whatever files happen to match (or nothing at all).
_profiles_list_lines() {
  local dir="$1" key="$2" raw
  raw=$(profile_get "$dir" "$key")
  case "$raw" in
    \[*\])
      raw=$(printf '%s' "$raw" | sed 's/^\[//; s/\]$//')
      printf '%s\n' "$raw" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/' \
        | sed '/^$/d'
      ;;
  esac
}

# _profiles_dedup <words> — space-separated words, first-occurrence order
# kept, duplicates dropped.
_profiles_dedup() {
  local w result=""
  for w in $1; do
    case " $result " in
      *" $w "*) ;;
      *) result="$result $w" ;;
    esac
  done
  printf '%s\n' "${result# }"
}

# profiles_is_fallback <profile-dir> — true when the profile declares that it
# claims nothing about the code: `verifies: nothing` in its profile.yaml.
#
# **Declared, never inferred, and in particular never read off `detect`.**
# `detect` answers when a profile *applies*; this answers what it *asserts*.
# They coincide in `generic` and nowhere else by necessity: a secret scanner or
# a licence-header check is exactly the kind of profile that should apply
# everywhere and does make a claim about the code. Reading `detect: always` as
# "claims nothing" would put such a profile in the wrong bucket, and the day its
# tool was missing it would report that nothing checks the project and ship
# unverified — the very inversion this distinction exists to prevent.
#
# Absence means the profile verifies something, which is the cautious default:
# a profile written before this field existed keeps refusing when its checks all
# skip, rather than quietly becoming unverifiable
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).
profiles_is_fallback() {
  [ "$(profile_get "$1" verifies)" = "nothing" ]
}

# profiles_supports <profile-dir> <capability> — true when the profile's
# profile.yaml lists <capability> under `scope`. Support is declared, never
# inferred: profiles are copied into projects (ADR-0003) and `upgrade` keeps
# user-modified copies, so a caller meets scripts written before a capability
# existed. Absence is the answer for all of them.
profiles_supports() {
  local item
  while IFS= read -r item; do
    [ "$item" = "$2" ] && return 0
  done < <(_profiles_list_lines "$1" scope)
  return 1
}

# --- validation ----------------------------------------------------------------
# A profile or adapter name can arrive from --profile/--profiles/--adapters
# or from .ai/config.yaml (profiles_active, cfg_list). Every consumer that
# turns such a name into a filesystem path goes through profiles_dir or
# adapters_dir below instead of concatenating it directly, so a name like
# `..` or `../../x` can never resolve outside the given root (mirrors
# scripts/lib/task.sh's task_dir / _task_valid_id).

# _profiles_valid_name <name> — true when <name> is safe as a single path
# segment: starts with a letter or digit (rules out `.`, `..`, and hidden
# directories) and contains only [A-Za-z0-9_-] thereafter (rules out `/`, so
# a name can never walk into a parent directory).
_profiles_valid_name() {
  case "$1" in
    [A-Za-z0-9]*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# profiles_dir <root> <name> — absolute path of <name>'s directory under
# <root> (profiles_source_dir or profiles_installed_dir). Dies via jig_die
# with "invalid profile name: <name>" before printing anything when <name>
# is not shaped like a profile name; otherwise prints <root>/<name>.
profiles_dir() {
  _profiles_valid_name "$2" || jig_die "invalid profile name: $2"
  printf '%s/%s\n' "$1" "$2"
}

# _adapters_valid_name <name> — same shape constraint as
# _profiles_valid_name; adapter names come from the same untrusted sources
# (--adapters/.ai/config.yaml's `adapters` list) and are used to build a
# path under <source>/adapters/.
_adapters_valid_name() {
  case "$1" in
    [A-Za-z0-9]*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# adapters_dir <root> <name> — absolute path of <name>'s directory under
# <root> (e.g. <source>/adapters). Mirrors profiles_dir; used by init.sh and
# upgrade.sh before sourcing <root>/<name>/adapter.sh.
adapters_dir() {
  _adapters_valid_name "$2" || jig_die "invalid adapter name: $2"
  printf '%s/%s\n' "$1" "$2"
}

# --- directories --------------------------------------------------------------

# profiles_source_dir — the profiles/ directory under the framework source
# checkout this copy of jig runs from (jig_source_root), or nothing when
# this is not a source checkout (installed copy, no JIG_SOURCE match).
profiles_source_dir() {
  local src
  src=$(jig_source_root)
  [ -n "$src" ] || return 0
  printf '%s/profiles\n' "$src"
}

# profiles_installed_dir — where profiles are installed inside the current
# project. JIG_PROJECT must already be set (jig_require_repo/init).
profiles_installed_dir() {
  printf '%s/%s/profiles\n' "$JIG_PROJECT" "$JIG_AI_DIR"
}

# --- glob matching -------------------------------------------------------------
# Mirrors scripts/lib/knowledge.sh's km_glob_to_findpath / km_glob_matches.
# Not shared by sourcing knowledge.sh: each command sources only the
# libraries it needs, and knowledge.sh's helpers are private to km_check.

# Translate a `detect` glob (repo-relative) into a `find -path` pattern.
# `**` matches any depth, including zero directories; BSD/GNU `find -path`
# both match `*` against `/` too (no FNM_PATHNAME), so collapsing `**/` and
# `**` down to a single `*` is sufficient and correct.
_profiles_glob_to_findpath() {
  printf '%s' "$1" | sed 's#[*][*]/#*#g; s#[*][*]#*#g'
}

# _profiles_glob_matches <glob> — exit 0 when <glob> matches at least one
# path in JIG_PROJECT. .git/ and the directories other stacks install their
# dependencies into are not searched: `jig init` activates what it detects
# (adr-20260918-init-activates-detected-profiles), and a .sh file inside node_modules/ or a .csproj inside a
# vendored package is not what the project is written in.
_profiles_glob_matches() {
  local glob="$1" pattern hit
  pattern=$(_profiles_glob_to_findpath "$glob")
  hit=$(find "$JIG_PROJECT" \
    \( -path "$JIG_PROJECT/.git" -o -name node_modules -o -name vendor \
       -o -name .venv -o -name venv -o -name .dart_tool -o -name .ai \) -prune -o \
    -path "$JIG_PROJECT/$pattern" -print -quit 2>/dev/null)
  [ -n "$hit" ]
}

# --- activation ----------------------------------------------------------------

# profiles_active — the project's configured `profiles` list (.ai/config.yaml),
# with `generic` always first and duplicates dropped. Dies via jig_die when
# the config lists a name that is not shaped like a profile name: a
# traversal attempt in .ai/config.yaml is reachable through every command
# that defaults to the active profiles (verify, upgrade, flag-less init),
# not just an explicit --profile flag, so it is rejected here too.
profiles_active() {
  local configured p
  configured=$(cfg_list profiles generic)
  for p in $configured; do
    _profiles_valid_name "$p" || jig_die "invalid profile name: $p"
  done
  _profiles_dedup "generic $configured"
}

# --- detection -------------------------------------------------------------

# profiles_detect [<profiles-root>] — names of every profile under
# <profiles-root> whose `detect` globs match a path in the current project
# (JIG_PROJECT), one per line; `generic` is always first. Defaults
# <profiles-root> to profiles_source_dir; prints just `generic` when no
# root can be determined. Applies the `requires` closure: a matched profile
# pulls in every profile it requires, even one whose own detect globs did
# not match (e.g. laravel's artisan match pulls in php).
profiles_detect() {
  local root="${1:-}" p name matched glob result="generic" req changed
  [ -n "$root" ] || root=$(profiles_source_dir)

  if [ -n "$root" ] && [ -d "$root" ]; then
    for p in "$root"/*/; do
      [ -d "$p" ] || continue
      p="${p%/}"
      name=$(basename "$p")
      [ "$name" = "generic" ] && continue
      case "$(profile_get "$p" detect)" in
        always)
          result="$result $name"
          ;;
        \[*\])
          matched=0
          while IFS= read -r glob; do
            [ -n "$glob" ] || continue
            _profiles_glob_matches "$glob" && { matched=1; break; }
          done < <(_profiles_list_lines "$p" detect)
          [ "$matched" = 1 ] && result="$result $name"
          ;;
      esac
    done

    # requires closure: keep pulling in required profiles until a full pass
    # adds nothing new.
    changed=1
    while [ "$changed" = 1 ]; do
      changed=0
      for name in $result; do
        p=$(profiles_dir "$root" "$name")
        [ -d "$p" ] || continue
        while IFS= read -r req; do
          [ -n "$req" ] || continue
          case " $result " in
            *" $req "*) ;;
            *) result="$result $req"; changed=1 ;;
          esac
        done < <(_profiles_list_lines "$p" requires)
      done
    done
  fi

  result=$(_profiles_dedup "$result")
  printf '%s\n' "$result" | tr ' ' '\n' | sed '/^$/d'
}

# --- requires check ----------------------------------------------------------

# profiles_check_requires — jig_warn (stderr) for every active profile whose
# `requires` are not all active. Advisory only: always returns 0.
profiles_check_requires() {
  local active p name req installed_dir
  active=$(profiles_active)
  installed_dir=$(profiles_installed_dir)
  for name in $active; do
    p=$(profiles_dir "$installed_dir" "$name")
    [ -d "$p" ] || continue
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      case " $active " in
        *" $req "*) ;;
        *) jig_warn "profile '$name' requires '$req', which is not active" ;;
      esac
    done < <(_profiles_list_lines "$p" requires)
  done
  return 0
}

# --- worktree bootstrap declarations -----------------------------------------
# A task worktree starts as a git checkout, so it holds nothing git does not
# track: no vendor/, no node_modules/, no .env. A profile declares what its
# stack keeps outside git, and `jig task start --worktree` carries it over
# from the owning checkout (adr-20260924-a-worktree-carries-what-git-does-not).

# _profiles_declared <key> — `<profile><TAB><item>` for every item the active
# profiles declare under <key>, first-occurrence order, an item never repeated
# whichever profile named it first. Reads the profiles installed in this
# project: those are the ones it actually runs, and `upgrade` keeps a copy a
# user edited (ADR-0003).
_profiles_declared() {
  local key="$1" root name dir item seen=""
  root=$(profiles_installed_dir)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    dir=$(profiles_dir "$root" "$name") || return 1
    [ -d "$dir" ] || continue
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      case "$seen" in
        *"<$item>"*) continue ;;
      esac
      seen="$seen<$item>"
      printf '%s\t%s\n' "$name" "$item"
    done < <(_profiles_list_lines "$dir" "$key")
  done < <(profiles_active | tr ' ' '\n')
  return 0
}

# profiles_carry — `<profile><TAB><path>` for each path the active profiles
# declare as derived state to copy into a new task worktree.
profiles_carry() { _profiles_declared carry; }

# profiles_lock — `<profile><TAB><path>` for each lock file the active
# profiles name. A lock file that differs between the owning checkout and the
# worktree means carried state is stale, not wrong.
profiles_lock() { _profiles_declared lock; }

# profiles_install <profile> — the command that installs <profile>'s
# dependencies from the network, or nothing. It is printed for a human to run,
# never executed: `task start` is not a build command, the agent's sandbox may
# hold no network, and the case this whole mechanism exists for is a host with
# no toolchain at all, where running it could not work anyway (adr-20260924-a-worktree-carries-what-git-does-not).
profiles_install() {
  local dir
  dir=$(profiles_dir "$(profiles_installed_dir)" "$1") || return 0
  profile_get "$dir" install
}

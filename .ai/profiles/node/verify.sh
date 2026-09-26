#!/usr/bin/env bash
# Verification for the node profile. Called by `jig verify` from the
# repository root. Exit 0 = pass, 1 = fail, 2 = skip (no check could run).
# Prints one line per check: "node: <check>: pass|fail|skip (<note>)".
#
# The package manager is the stack toolchain (adr-20260918-profiles-narrow-per-check-with-project-tools): resolved from
# $PATH, never from node_modules. It is chosen by package.json's own
# "packageManager" field (pnpm@…, yarn@…, bun@…, npm@…) when present, else
# by the lock file on disk (pnpm-lock.yaml -> pnpm, yarn.lock -> yarn,
# bun.lock/bun.lockb -> bun), else npm — npm's own default and this
# profile's original behaviour. bun is special-cased to `bun run test`:
# `bun test` is Bun's own built-in test runner and ignores the package.json
# script entirely, unlike every other manager's "test" shorthand.
#
# Checks: the "test", "lint" and "typecheck" scripts, each only when
# package.json declares it (grep-based: SPEC requires no mandatory
# dependency besides git, so a JSON parser such as jq cannot be assumed
# present — see _node_has_script, unchanged from the original profile).
#
# Narrowing (ADR-0041, adr-20260918-profiles-narrow-per-check-with-project-tools), per check:
# - lint narrows to the changed js/jsx/ts/tsx/mjs/cjs/mts/cts files, but
#   only when the "lint" script itself invokes eslint and
#   node_modules/.bin/eslint exists — the project's own eslint, never a
#   global one. Otherwise, or when a project-wide file changed, the full
#   lint script runs, with a reason.
# - test detects the project's runner (vitest or jest) from package.json's
#   own dependencies and node_modules/.bin/<runner>. jest narrows through
#   `--findRelatedTests`, confirmed non-empty first via `--listTests`
#   (`--listTests` only lists and exits, so this never runs a test). vitest
#   has no documented, unexecuted way to count related tests for arbitrary
#   source files (its `related` command runs them directly); narrowing is
#   therefore limited to changed files that are themselves test files
#   (*.test.*/*.spec.*), run directly. Any other changed source file, or no
#   runner found, sends test to the full script.
# - typecheck never narrows: a per-file check cannot see the errors a
#   changed file introduces in code that calls it, unnarrowed like mypy.
# - package.json, any lock file, tsconfig*, and the eslint/vite/vitest/jest
#   configs affect the whole project and send lint and test to their full
#   set.
# Where a check bypasses the project's own script to call a runner
# directly, the note names that runner (`scope: vitest related, 3 files`).
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin node

# Files whose change can alter the result of lint or test project-wide.
NODE_ALL_GLOBS="package.json package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb tsconfig.json tsconfig.*.json .eslintrc .eslintrc.* eslint.config.* vite.config.* vitest.config.* jest.config.*"

NODE_TEST_EXTS="js jsx ts tsx mjs cjs mts cts"

# _node_has_script <name> — true when package.json declares a "<name>"
# script. Grep-based on purpose: SPEC requires no mandatory dependency
# besides git, so a JSON parser (e.g. jq) cannot be assumed present.
_node_has_script() {
  [ -f package.json ] || return 1
  grep -qE "\"$1\"[[:space:]]*:" package.json
}

# _node_dep_present <name> — true when package.json lists <name> as any
# kind of dependency. Same grep-based approach as _node_has_script: it does
# not distinguish dependencies/devDependencies/peerDependencies, which is
# harmless here since the question is only "is the package installed".
_node_dep_present() {
  [ -f package.json ] || return 1
  grep -qE "\"$1\"[[:space:]]*:" package.json
}

# _node_pm — the package manager name: package.json's own "packageManager"
# field wins; else the lock file on disk; else npm.
_node_pm() {
  local field
  if [ -f package.json ]; then
    # grep reads the file itself and stops at the first hit. Piping it into
    # `head` instead puts a writer in front of a reader that quits early, and
    # under pipefail a writer still writing when that happens turns a found
    # value into an empty one (conventions/shell.md). One `packageManager`
    # line never grew far enough for that, but how big someone else's
    # package.json gets is not a thing this function should have to know.
    field=$(grep -m 1 -oE '"packageManager"[[:space:]]*:[[:space:]]*"[a-zA-Z0-9._-]+@[^"]+"' package.json)
    case "$field" in
      *pnpm@*) printf 'pnpm\n'; return 0 ;;
      *yarn@*) printf 'yarn\n'; return 0 ;;
      *bun@*) printf 'bun\n'; return 0 ;;
      *npm@*) printf 'npm\n'; return 0 ;;
    esac
  fi
  if [ -f pnpm-lock.yaml ]; then printf 'pnpm\n'; return 0; fi
  if [ -f yarn.lock ]; then printf 'yarn\n'; return 0; fi
  if [ -f bun.lock ] || [ -f bun.lockb ]; then printf 'bun\n'; return 0; fi
  printf 'npm\n'
  return 0
}

# _node_local_bin <name> — the path of <name> in node_modules/.bin, probing
# both the extensionless (Unix, and npm's own cross-platform shim) and
# Windows-suffixed forms by what exists, never by OS name (ADR-0037).
# Nothing when the project's own environment does not have it.
_node_local_bin() {
  local name="$1"
  if [ -f "node_modules/.bin/$name" ]; then
    printf 'node_modules/.bin/%s\n' "$name"
    return 0
  fi
  if [ -f "node_modules/.bin/$name.cmd" ]; then
    printf 'node_modules/.bin/%s.cmd\n' "$name"
    return 0
  fi
  if [ -f "node_modules/.bin/$name.exe" ]; then
    printf 'node_modules/.bin/%s.exe\n' "$name"
    return 0
  fi
  return 0
}

# _node_lint_uses_eslint — true when the "lint" script's own text invokes
# eslint. Not inlined into a `$( )`: bash 3.2 misparses a `case` written
# there.
_node_lint_uses_eslint() {
  local script
  [ -f package.json ] || return 1
  script=$(grep -m 1 -oE '"lint"[[:space:]]*:[[:space:]]*"[^"]*"' package.json)
  case "$script" in
    *eslint*) return 0 ;;
  esac
  return 1
}

# _node_test_runner — "vitest" or "jest" when package.json depends on one
# (vitest preferred when both are present), "" when neither is declared.
_node_test_runner() {
  if _node_dep_present vitest; then
    printf 'vitest\n'
    return 0
  fi
  if _node_dep_present jest; then
    printf 'jest\n'
    return 0
  fi
  return 0
}

# _node_is_source_ext <path> — one of the extensions lint and test narrow
# by.
_node_is_source_ext() {
  case "$1" in
    *.js | *.jsx | *.ts | *.tsx | *.mjs | *.cjs | *.mts | *.cts) return 0 ;;
  esac
  return 1
}

# _node_is_test_file <path> — a *.test.* or *.spec.* file, by the naming
# convention both vitest and jest ship with by default.
_node_is_test_file() {
  case "${1##*/}" in
    *.test.* | *.spec.*) return 0 ;;
  esac
  return 1
}

# _node_all_glob_changed — true when a changed path matches NODE_ALL_GLOBS.
# `set -f` around the match: unlike the literal filenames go/php/laravel
# glob lists use, NODE_ALL_GLOBS' patterns contain `*`, and an unquoted
# expansion of a real, unrelated file on disk (e.g. an existing
# tsconfig.build.json) would otherwise be pathname-expanded before `case`
# ever sees it.
_node_all_glob_changed() {
  local rc
  set -f
  # shellcheck disable=SC2086
  jp_changed_any $NODE_ALL_GLOBS
  rc=$?
  set +f
  return $rc
}

MGR=$(_node_pm)
MGR_BIN=""
if command -v "$MGR" >/dev/null 2>&1; then
  MGR_BIN="$MGR"
fi

case "$MGR" in
  npm) TEST_LABEL="npm test"; LINT_LABEL="npm run lint"; TYPECHECK_LABEL="npm run typecheck" ;;
  # bun reserves `bun test` for its own built-in test runner (see
  # _node_full_test); the check line must name the command actually run.
  bun) TEST_LABEL="bun run test"; LINT_LABEL="bun run lint"; TYPECHECK_LABEL="bun run typecheck" ;;
  *) TEST_LABEL="$MGR test"; LINT_LABEL="$MGR run lint"; TYPECHECK_LABEL="$MGR run typecheck" ;;
esac

# _node_full_test <note> — run the project's own "test" script (never
# narrowed here). bun reserves `bun test` for its own built-in test
# runner, so bun alone needs `run`.
_node_full_test() {
  if [ "$MGR" = bun ]; then
    jp_run "$TEST_LABEL" "$1" "$MGR_BIN" run test
  else
    jp_run "$TEST_LABEL" "$1" "$MGR_BIN" test
  fi
}

_node_full_lint() {
  jp_run "$LINT_LABEL" "$1" "$MGR_BIN" run lint
}

_node_full_typecheck() {
  jp_run "$TYPECHECK_LABEL" "$1" "$MGR_BIN" run typecheck
}

# --- test ----------------------------------------------------------------

# _node_builtin_jest <path> — the filter jest's own --findRelatedTests
# understands: the changed path itself (jest resolves a test file passed to
# --findRelatedTests to itself, and a source file to whatever imports it).
# ALL for a project-wide file, a deleted-looking non-source path, or
# anything that is not one of NODE_TEST_EXTS; nothing for documentation.
_node_builtin_jest() {
  local f="$1"
  if _node_builtin_all_glob "$f"; then
    printf 'ALL\n'
    return 0
  fi
  case "$f" in
    *.md | *.mdx | docs/* | .ai/*) return 0 ;;
  esac
  if ! _node_is_source_ext "$f"; then
    printf 'ALL\n'
    return 0
  fi
  printf '%s\n' "$f"
  return 0
}

# _node_builtin_vitest <path> — a changed test file narrows to itself.
# Any other changed source file is ALL: vitest's `related` command runs
# the tests it finds rather than listing them, so there is no way to
# confirm a narrowed run would select anything without already running it
# (design note D4). ALL for a project-wide file too; nothing for
# documentation.
_node_builtin_vitest() {
  local f="$1"
  if _node_builtin_all_glob "$f"; then
    printf 'ALL\n'
    return 0
  fi
  case "$f" in
    *.md | *.mdx | docs/* | .ai/*) return 0 ;;
  esac
  if ! _node_is_source_ext "$f"; then
    printf 'ALL\n'
    return 0
  fi
  if _node_is_test_file "$f"; then
    printf '%s\n' "$f"
  else
    printf 'ALL\n'
  fi
  return 0
}

# _node_builtin_all_glob <path> — like _node_all_glob_changed, but against
# one path (used from _node_builtin_jest/_node_builtin_vitest, which see
# one changed path at a time through jp_decide).
_node_builtin_all_glob() {
  local f="$1" g
  set -f
  for g in $NODE_ALL_GLOBS; do
    # shellcheck disable=SC2254
    case "$f" in
      $g) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}

# _node_test_via_jest <jest-bin> <manager-version-note>
_node_test_via_jest() {
  local jest="$1" mv="$2" v filters n listing missing
  v=$(jp_version "$jest" --version)
  filters=$(jp_decide _node_builtin_jest)
  if [ -z "$filters" ]; then
    jp_skip "$TEST_LABEL" "scope: no changed file maps to a test"
    return 0
  fi
  if [ "$filters" = ALL ]; then
    _node_full_test "$mv, scope: not narrowable, ran full set"
    return 0
  fi
  IFS='
'
  set -f
  # shellcheck disable=SC2086
  set -- $filters
  set +f
  IFS=$' \t\n'
  if missing=$(jp_first_missing "$@"); then
    _node_full_test "$mv, scope: filter '$missing' selects no tests, ran full set"
    return 0
  fi
  # --listTests only lists and exits; it never runs a test, so this is safe
  # to call before deciding whether to narrow.
  listing=$("$jest" --listTests --findRelatedTests "$@" 2>/dev/null) || listing=""
  n=$(printf '%s\n' "$listing" | grep -c . || true)
  if [ "$n" -eq 0 ]; then
    _node_full_test "$mv, scope: jest finds no related tests, ran full set"
  else
    jp_run "$TEST_LABEL" "$v, scope: jest related, $n files" "$jest" --findRelatedTests "$@"
  fi
}

# _node_test_via_vitest <vitest-bin> <manager-version-note>
_node_test_via_vitest() {
  local vitest="$1" mv="$2" v filters missing
  v=$(jp_version "$vitest" --version)
  filters=$(jp_decide _node_builtin_vitest)
  if [ -z "$filters" ]; then
    jp_skip "$TEST_LABEL" "scope: no changed file maps to a test"
    return 0
  fi
  if [ "$filters" = ALL ]; then
    _node_full_test "$mv, scope: not narrowable, ran full set"
    return 0
  fi
  IFS='
'
  set -f
  # shellcheck disable=SC2086
  set -- $filters
  set +f
  IFS=$' \t\n'
  if missing=$(jp_first_missing "$@"); then
    _node_full_test "$mv, scope: filter '$missing' selects no tests, ran full set"
    return 0
  fi
  jp_run "$TEST_LABEL" "$v, scope: vitest related, $# files" "$vitest" run "$@"
}

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  if ! _node_has_script test || [ -z "$MGR_BIN" ]; then
    jp_plan "$TEST_LABEL" skip "no test script or $MGR not found"
  elif ! jp_scoped; then
    jp_plan "$TEST_LABEL" full "full scope"
  else
    runner=$(_node_test_runner)
    runner_bin=""
    if [ -n "$runner" ]; then runner_bin=$(_node_local_bin "$runner"); fi
    if [ -z "$runner_bin" ]; then
      jp_plan "$TEST_LABEL" full "no local supported runner for narrowing"
    elif [ "$runner" = jest ]; then
      filters=$(jp_decide _node_builtin_jest)
      if [ -n "$filters" ] && [ "$filters" != ALL ]; then
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          if [ ! -e "$f" ]; then filters=ALL; break; fi
        done <<EOF
$filters
EOF
      fi
      if [ -n "$filters" ] && [ "$filters" != ALL ]; then
        jp_plan "$TEST_LABEL" conditional "related tests for $(printf '%s\n' "$filters" | paste -sd, -) require jest --listTests; full set possible"
      else
        jp_plan_selection "$TEST_LABEL" "$filters" "test files"
      fi
    else
      filters=$(jp_decide _node_builtin_vitest)
      if [ -n "$filters" ] && [ "$filters" != ALL ]; then
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          if [ ! -e "$f" ]; then filters=ALL; break; fi
        done <<EOF
$filters
EOF
      fi
      jp_plan_selection "$TEST_LABEL" "$filters" "test files"
    fi
  fi

  if ! _node_has_script lint || [ -z "$MGR_BIN" ]; then
    jp_plan "$LINT_LABEL" skip "no lint script or $MGR not found"
  else
    eslint_bin=""
    if _node_lint_uses_eslint; then eslint_bin=$(_node_local_bin eslint); fi
    if [ -z "$eslint_bin" ] || ! jp_scoped || _node_all_glob_changed; then
      jp_plan "$LINT_LABEL" full "lint script or project configuration requires full set"
    else
      # shellcheck disable=SC2086
      files=$(jp_changed $NODE_TEST_EXTS)
      if [ -z "$files" ]; then
        jp_plan "$LINT_LABEL" skip "no changed lintable files"
      else
        jp_plan "$LINT_LABEL" filtered "eslint files: $(printf '%s\n' "$files" | paste -sd, -)"
      fi
    fi
  fi

  if ! _node_has_script typecheck || [ -z "$MGR_BIN" ]; then
    jp_plan "$TYPECHECK_LABEL" skip "no typecheck script or $MGR not found"
  else
    jp_plan "$TYPECHECK_LABEL" full "typecheck cannot narrow by file"
  fi
  exit 0
fi

if ! _node_has_script test || [ -z "$MGR_BIN" ]; then
  jp_skip "$TEST_LABEL" "no test script or $MGR not found"
else
  mgr_v=$(jp_version "$MGR_BIN" --version)
  if ! jp_scoped; then
    _node_full_test "$mgr_v"
  else
    runner=$(_node_test_runner)
    runner_bin=""
    [ -z "$runner" ] || runner_bin=$(_node_local_bin "$runner")
    if [ -z "$runner" ] || [ -z "$runner_bin" ]; then
      _node_full_test "$mgr_v, scope: not narrowable, ran full set"
    else
      case "$runner" in
        jest) _node_test_via_jest "$runner_bin" "$mgr_v" ;;
        vitest) _node_test_via_vitest "$runner_bin" "$mgr_v" ;;
      esac
    fi
  fi
fi

# --- lint ------------------------------------------------------------------

if ! _node_has_script lint || [ -z "$MGR_BIN" ]; then
  jp_skip "$LINT_LABEL" "no lint script or $MGR not found"
else
  eslint_bin=""
  if _node_lint_uses_eslint; then
    eslint_bin=$(_node_local_bin eslint)
  fi
  mgr_v=$(jp_version "$MGR_BIN" --version)
  if [ -z "$eslint_bin" ]; then
    note="$mgr_v"
    if jp_scoped; then note="$mgr_v, scope: not narrowable, ran full set"; fi
    _node_full_lint "$note"
  elif ! jp_scoped; then
    _node_full_lint "$mgr_v"
  elif _node_all_glob_changed; then
    _node_full_lint "$mgr_v, scope: project configuration changed, whole project"
  else
    # shellcheck disable=SC2086
    files=$(jp_changed $NODE_TEST_EXTS)
    if [ -z "$files" ]; then
      jp_skip "$LINT_LABEL" "scope: no changed lintable files"
    else
      v=$(jp_version "$eslint_bin" --version)
      n=$(printf '%s\n' "$files" | grep -c .)
      IFS='
'
      set -f
      # shellcheck disable=SC2086
      set -- $files
      set +f
      IFS=$' \t\n'
      jp_run "$LINT_LABEL" "$v, scope: eslint, $n files" "$eslint_bin" "$@"
    fi
  fi
fi

# --- typecheck ---------------------------------------------------------------

if ! _node_has_script typecheck || [ -z "$MGR_BIN" ]; then
  jp_skip "$TYPECHECK_LABEL" "no typecheck script or $MGR not found"
else
  mgr_v=$(jp_version "$MGR_BIN" --version)
  note="$mgr_v"
  if jp_scoped; then note="$mgr_v, scope: not narrowable, ran full set"; fi
  _node_full_typecheck "$note"
fi

jp_end

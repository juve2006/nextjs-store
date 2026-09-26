#!/usr/bin/env bash
# Verification for the generic profile. Called by `jig verify` from the
# repository root. Exits 1 when this is not a git repository and 2 otherwise —
# nothing applicable was checked, which is this profile's ordinary answer.
#
# It used to exit 0 and print `generic: ok`, on the strength of one test — "is
# this a git repository" — that cannot be false anywhere jig runs, because
# `jig_require_repo` has already refused by then. That pass said nothing about
# the project and yet made the whole run green: on a project with no shellcheck
# and no test runner, `jig verify` answered 0 having examined not one line of
# it, and `jig task ship` and the autopilot read that code
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).
#
# The rule applied here is not a new one. `jp_end` has always exited 2 for a
# profile that ran no applicable check; this profile predates the library and
# never got it. The git test stays, as the guard it is: it can fail, and it can
# no longer pass.
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin generic

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  jp_plan repository skip "this fallback profile verifies nothing about the code"
  exit 0
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  jp_fail repository "not a git repository"
  jp_end
fi

jp_skip repository "no stack-specific checks: this profile verifies nothing about the code"
jp_end

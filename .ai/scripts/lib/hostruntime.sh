# Does the host's runtime match what the project asks for
# (adr-20261001-checks-run-where-the-project-runs; domains/verify). Sourced by
# doctor.sh and verify.sh; defines hostruntime_report.
#
# Only meaningful when the project's checks run on this machine: a caller that
# found an environment prefix (RUNENV_EXEC) has nothing to ask of the host's
# PHP. Which runtime the host would use comes from one place,
# _hostruntime_version, so a detector that changes which binary the host runs
# (Herd) changes it once.
#
# What a project asks for is read from the file its own tool reads:
#
#   php      composer.json    require.php          (Composer's constraints)
#   node     package.json     engines.node         (npm's constraints)
#   python   .python-version  first line           (a version; 3.12 means 3.12.x)
#
# The constraint forms understood are the common ones: ^ ~ >= > <= < = and a
# bare version, x/* wildcards, comparators joined by a space or a comma (and),
# and alternatives joined by | or || (or). Anything else — a hyphen range, a
# stability flag, a dev branch — is "could not compare", never a quiet ok.
# bash 3.2 compatible.
# shellcheck shell=bash

# _hr_parse <version> — split a version or a partial one into HR_A HR_B HR_C
# (missing parts 0), HR_N (how many numeric parts were written) and HR_WILD
# (1 when it ended in a wildcard, or was one: `*`, `x`). Exit 1 when it is not
# of that shape.
_hr_parse() {
  local v="$1" rest part
  v=${v#v}
  HR_A=0 HR_B=0 HR_C=0 HR_N=0 HR_WILD=0
  case "$v" in
    '*' | x | X) HR_WILD=1; return 0 ;;
    '' | *[!0-9.xX*]*) return 1 ;;
    .* | *..* | *.) return 1 ;;
  esac
  rest=$v
  while [ -n "$rest" ]; do
    part=${rest%%.*}
    if [ "$rest" = "$part" ]; then rest=""; else rest=${rest#*.}; fi
    if [ "$HR_WILD" = 1 ]; then return 1; fi
    case "$part" in
      '*' | x | X) HR_WILD=1; continue ;;
      '' | *[!0-9]*) return 1 ;;
    esac
    HR_N=$((HR_N + 1))
    case "$HR_N" in
      1) HR_A=$((10#$part)) ;;
      2) HR_B=$((10#$part)) ;;
      3) HR_C=$((10#$part)) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# _hr_range <operator> <version> <mode> — the comparator as HR_LO (inclusive)
# and HR_HI (exclusive), either empty for unbounded. <mode> is the dialect:
# composer (php), npm (node), or prefix (a bare 3.12 is any 3.12.x). Exit 1
# when the comparator cannot be read, or means something the dialects disagree
# on and this reader would have to guess.
_hr_range() {
  local op="$1" mode="$3" a b c n full
  HR_LO="" HR_HI=""
  _hr_parse "$2" || return 1
  a=$HR_A b=$HR_B c=$HR_C n=$HR_N
  full="$a.$b.$c"
  if [ "$HR_WILD" = 1 ]; then
    case "$op" in '' | =) ;; *) return 1 ;; esac
    case "$n" in
      0) ;;
      1) HR_LO="$a.0.0"; HR_HI="$((a + 1)).0.0" ;;
      2) HR_LO="$a.$b.0"; HR_HI="$a.$((b + 1)).0" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  case "$op" in
    '^')
      HR_LO=$full
      if [ "$a" -gt 0 ]; then HR_HI="$((a + 1)).0.0"
      elif [ "$n" -eq 1 ]; then HR_HI="1.0.0"
      elif [ "$b" -gt 0 ]; then HR_HI="0.$((b + 1)).0"
      elif [ "$n" -eq 2 ]; then HR_HI="0.1.0"
      else HR_HI="0.0.$((c + 1))"
      fi
      ;;
    '~')
      HR_LO=$full
      # Composer's ~1.2 is >=1.2 <2.0; npm's is >=1.2.0 <1.3.0.
      if [ "$n" -eq 1 ] || { [ "$n" -eq 2 ] && [ "$mode" = composer ]; }; then
        HR_HI="$((a + 1)).0.0"
      else
        HR_HI="$a.$((b + 1)).0"
      fi
      ;;
    '>=') HR_LO=$full ;;
    '<') HR_HI=$full ;;
    '>' | '<=')
      # `>8.2` means >=8.3 to npm and >8.2.0 to Composer: only a full version
      # is unambiguous.
      [ "$n" -eq 3 ] || return 1
      if [ "$op" = '>' ]; then HR_LO="$a.$b.$((c + 1))"; else HR_HI="$a.$b.$((c + 1))"; fi
      ;;
    '' | =)
      HR_LO=$full
      if [ "$n" -eq 3 ] || [ "$mode" = composer ]; then
        # Composer: 8.4 is exactly 8.4.0.
        HR_HI="$a.$b.$((c + 1))"
      elif [ "$n" -eq 2 ]; then
        HR_HI="$a.$((b + 1)).0"
      else
        HR_HI="$((a + 1)).0.0"
      fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

# _hr_satisfies <host-version> <constraint> <mode> — exit 0 when the host
# version meets the constraint, 1 when it does not, 2 when the constraint is
# not one this reader can judge. Alternatives are tried one by one; within
# one, a comparator that is false makes it false whatever else it holds, and
# one that cannot be read makes it unknown unless another is false.
_hr_satisfies() {
  local host="$1" constraint="$2" mode="$3"
  local alt tok op ver words anyalt=0 anyunknown=0 anytrue=0 altfalse altunknown
  local -a toks
  _hr_parse "$host" || return 2
  if [ "$HR_WILD" = 1 ] || [ "$HR_N" -lt 1 ]; then return 2; fi
  host="$HR_A.$HR_B.$HR_C"
  # A hyphen range (8.1 - 8.5) is a form of its own, not two comparators.
  case " $constraint " in *" - "*) return 2 ;; esac
  # "a || b" and "a | b" both become one alternative per line; "a, b" and
  # "a b" both separate comparators; "> 1.2" is joined into ">1.2".
  words=$(printf '%s\n' "$constraint" | tr '|' '\n' | tr ',' ' ' \
    | sed 's/\([<>=^~]\)[[:space:]][[:space:]]*/\1/g')
  while IFS= read -r alt; do
    read -r -a toks <<JIGEOF
$alt
JIGEOF
    if [ "${#toks[@]}" -eq 0 ]; then continue; fi
    anyalt=1
    altfalse=0 altunknown=0
    for tok in "${toks[@]}"; do
      op=${tok%%[0-9vxX*]*}
      ver=${tok#"$op"}
      case "$op" in
        '' | = | '^' | '~' | '>=' | '>' | '<=' | '<') ;;
        *) altunknown=1; continue ;;
      esac
      if ! _hr_range "$op" "$ver" "$mode"; then altunknown=1; continue; fi
      if [ -n "$HR_LO" ] && jig_version_lt "$host" "$HR_LO"; then altfalse=1; fi
      if [ -n "$HR_HI" ] && ! jig_version_lt "$host" "$HR_HI"; then altfalse=1; fi
    done
    if [ "$altfalse" = 1 ]; then continue; fi
    if [ "$altunknown" = 1 ]; then anyunknown=1; else anytrue=1; fi
  done <<JIGEOF
$words
JIGEOF
  if [ "$anyalt" = 0 ]; then return 2; fi
  if [ "$anytrue" = 1 ]; then return 0; fi
  if [ "$anyunknown" = 1 ]; then return 2; fi
  return 1
}

# _hostruntime_json_string <file> <object> <key> — the string value of <key>
# inside the object named <object> of a JSON file ("require" → "php";
# "engines" → "node"). A reader of the shapes these two manifests are written
# in, not a JSON parser; nothing when it is not there.
_hostruntime_json_string() {
  [ -f "$1" ] || return 0
  tr -d '\r\n' < "$1" | awk -v obj="$2" -v key="$3" '
    {
      i = index($0, "\"" obj "\"")
      if (!i) next
      s = substr($0, i + length(obj) + 2)
      if (!match(s, /^[ \t]*:[ \t]*\{/)) next
      s = substr(s, RLENGTH + 1)
      j = index(s, "}")
      if (j) s = substr(s, 1, j - 1)
      if (match(s, "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\"")) {
        v = substr(s, RSTART, RLENGTH)
        sub(/^[^:]*:[ \t]*"/, "", v)
        sub(/"$/, "", v)
        print v
      }
    }'
}

# _hostruntime_required <runtime> — prints `<constraint><TAB><where it came
# from><TAB><mode>`; nothing when the project asks for nothing.
_hostruntime_required() {
  local c
  case "$1" in
    php)
      c=$(_hostruntime_json_string "$JIG_PROJECT/composer.json" require php)
      if [ -n "$c" ]; then printf '%s\tcomposer.json require.php\tcomposer\n' "$c"; fi
      ;;
    node)
      c=$(_hostruntime_json_string "$JIG_PROJECT/package.json" engines node)
      if [ -n "$c" ]; then printf '%s\tpackage.json engines.node\tnpm\n' "$c"; fi
      ;;
    python)
      [ -f "$JIG_PROJECT/.python-version" ] || return 0
      c=$(sed -n '1p' "$JIG_PROJECT/.python-version" | tr -d '\r' | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
      if [ -n "$c" ]; then printf '%s\t.python-version\tprefix\n' "$c"; fi
      ;;
  esac
  return 0
}

# _hostruntime_version <runtime> — the version of the runtime the project's
# commands would meet on this machine; exit 1 when there is none. The one
# place that says which binary that is.
_hostruntime_version() {
  local out PATH=$PATH
  # A host runtime that is not first on PATH (Herd, run.path) is the one the
  # checks meet: runenv_resolve names its directory.
  if [ -n "${RUNENV_PATH:-}" ]; then PATH="$RUNENV_PATH:$PATH"; fi
  case "$1" in
    php)
      command -v php >/dev/null 2>&1 || return 1
      out=$(php -r 'echo PHP_VERSION;' 2>/dev/null) || return 1
      ;;
    node)
      command -v node >/dev/null 2>&1 || return 1
      out=$(node --version 2>/dev/null) || return 1
      ;;
    python)
      if command -v python3 >/dev/null 2>&1; then
        out=$(python3 --version 2>&1) || return 1
      elif command -v python >/dev/null 2>&1; then
        out=$(python --version 2>&1) || return 1
      else
        return 1
      fi
      out=${out#Python }
      ;;
    *) return 1 ;;
  esac
  out=${out#v}
  # 8.4.0RC1, 20.1.0-nightly: the numbers up front are what is compared.
  out=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\(\.[0-9][0-9]*\)*\).*/\1/p')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# hostruntime_report — one line per runtime the project states a requirement
# for: `<state><TAB><runtime><TAB><text>`, state `ok`, `mismatch` or `unknown`
# ("could not compare"). Needs JIG_PROJECT and version.sh; the caller has
# already established that checks run on the host.
hostruntime_report() {
  local rt req constraint where mode host rc
  for rt in php node python; do
    req=$(_hostruntime_required "$rt")
    [ -n "$req" ] || continue
    constraint=$(printf '%s\n' "$req" | cut -f1)
    where=$(printf '%s\n' "$req" | cut -f2)
    mode=$(printf '%s\n' "$req" | cut -f3)
    if ! host=$(_hostruntime_version "$rt"); then
      printf 'unknown\t%s\tcould not compare: %s is not available on this machine (%s asks for %s)\n' \
        "$rt" "$rt" "$where" "$constraint"
      continue
    fi
    rc=0
    _hr_satisfies "$host" "$constraint" "$mode" || rc=$?
    case "$rc" in
      0) printf 'ok\t%s\t%s %s meets %s (%s)\n' "$rt" "$rt" "$host" "$constraint" "$where" ;;
      1) printf 'mismatch\t%s\t%s %s on this machine does not meet %s (%s)\n' "$rt" "$rt" "$host" "$constraint" "$where" ;;
      *) printf 'unknown\t%s\tcould not compare: %s %s against %s (%s) is a form jig does not read\n' "$rt" "$rt" "$host" "$constraint" "$where" ;;
    esac
  done
}

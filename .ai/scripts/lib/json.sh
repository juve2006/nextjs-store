# JSON output: the one place Jig writes JSON, and the envelope every `--json`
# read is printed in (adr-20261015-a-read-is-one-json-envelope; schemas/json.md).
# Sourced by the commands that offer `--json`; sourcing it twice is harmless,
# since it only defines functions and constants.
#
#   json_run <producer> [args...]
#       Run <producer> and print exactly one envelope line on stdout:
#         {"schema":1,"revision":…,"generated_at":"…","data":<producer's stdout>}
#       with the revision and the time both taken before the producer runs
#       or, when the producer fails or prints nothing,
#         {"schema":1,"revision":…,"generated_at":"…","error":{"code":"…","message":"…"}}
#       The producer prints one JSON value and nothing else on stdout; what it
#       prints on stderr reaches stderr unchanged, but for the code markers
#       below. Returns the producer's status (1 when it succeeded without
#       printing anything).
#       `code` is the stable failure code the refusal named — `jig_fail <code>`
#       (common.sh) — or `failed` when it named none (schemas/json.md, "Failure
#       codes").
#
#   json_quote <s>        _JSON <- <s> as a JSON string, quotes included
#   json_str_or_null <s>  _JSON <- null for an empty <s>, else json_quote
#   json_int_or_null <s>  _JSON <- <s> when it is a non-negative integer, else null
#   json_bool <s>         _JSON <- true for `true`, else false
#
# The builders set the global _JSON rather than print, so a producer can build
# a record field by field without a subshell per field.
#
# Written by the shell, without jq or any other dependency (ADR-0002). Strings
# are escaped for `"`, `\` and every control byte; other bytes, UTF-8 included,
# pass through as they are.
# shellcheck shell=bash

_JSON=""

# The control bytes other than tab, newline and carriage return, which
# json_quote replaces by name before it looks for these. Built once, not typed:
# a literal control byte in a source file is invisible in every editor.
_JSON_CTRL=$(printf '\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037')

json_quote() {
  local s="$1" out="" c i n code
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  case "$s" in
    *["$_JSON_CTRL"]*)
      # Rare (a hand-edited state file, an escape sequence in a reason), so a
      # byte-by-byte pass is paid only when one is there.
      n=${#s}
      i=0
      while [ "$i" -lt "$n" ]; do
        c=${s:$i:1}
        case "$c" in
          ["$_JSON_CTRL"])
            printf -v code '\\u%04x' "'$c"
            out="$out$code"
            ;;
          *) out="$out$c" ;;
        esac
        i=$((i + 1))
      done
      s=$out
      ;;
  esac
  _JSON="\"$s\""
}

json_str_or_null() {
  if [ -z "$1" ]; then _JSON=null; else json_quote "$1"; fi
}

json_int_or_null() {
  case "$1" in
    '' | *[!0-9]*) _JSON=null ;;
    *) _JSON=$((10#$1)) ;;
  esac
}

json_bool() {
  if [ "$1" = true ]; then _JSON=true; else _JSON=false; fi
}

# json_revision — the clone's revision every envelope reports: the counter
# every Jig write raises (jig_revision_read, common.sh;
# adr-20261016-the-clone-revision-is-a-claimed-name), `0` before the first one.
json_revision() {
  jig_revision_read
}

# The marker _jig_die_as (common.sh) prints just before a refusal's message
# inside a producer: a unit separator and `jig: code: `, then the code.
_JSON_CODE_MARK=$(printf '\037jig: code: ')

# _json_error_from <stderr-file> <status> — the refusal as two lines: its
# code, then its message. The message is what the last `jig: error: ` said, to
# the end of the file (a message can span lines), or the bare exit status when
# nothing said why (`set -e` on a failed command). The code is the one the
# marker on the line right before that message named; `failed` when there is
# no such marker — a refusal by plain jig_die, by a child jig, by a message
# printed without either, or no message at all — or when what it names is not
# a code (lowercase words joined by `-`).
_json_error_from() {
  local both code msg
  both=$(JIG_JSON_MARK="$_JSON_CODE_MARK" awk '
    BEGIN { mark = ENVIRON["JIG_JSON_MARK"]; pending = "" }
    index($0, mark) == 1 { pending = substr($0, length(mark) + 1); next }
    index($0, "jig: error: ") == 1 {
      code = pending; text = substr($0, 13); on = 1; pending = ""; next
    }
    { pending = "" }
    on { text = text "\n" $0 }
    END { printf "%s\n%s", code, text }
  ' "$1")
  code=${both%%$'\n'*}
  msg=${both#*$'\n'}
  # The letters are spelled out: a range such as [a-z] takes capitals too in
  # some locales, and a code is lowercase.
  case "$code" in
    [abcdefghijklmnopqrstuvwxyz]*)
      case "$code" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) code=failed ;; esac
      ;;
    *) code=failed ;;
  esac
  [ -n "$msg" ] || { msg="exited with status $2"; code=failed; }
  printf '%s\n%s' "$code" "$msg"
}

json_run() {
  local producer="$1" out err rc at rev both code
  shift
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Read before the data, never after: a write that lands while the producer
  # reads then raises the revision past this one, and the consumer's next read
  # sees it. Read after, the revision could cover a write the data missed, and
  # the consumer would never learn of it.
  rev=$(json_revision)
  out=$(mktemp "${TMPDIR:-/tmp}/jig-json.XXXXXX")
  jig_cleanup_add "$out"
  err=$(mktemp "${TMPDIR:-/tmp}/jig-json.XXXXXX")
  jig_cleanup_add "$err"
  # The producer runs in a subshell of its own, so that whatever ends it — a
  # jig_die anywhere below it, `set -e`, an unknown argument — ends there and
  # is reported here, in the one envelope. Not `( … ) || rc=$?`: inside a
  # condition bash ignores `set -e` for the whole subshell, and the producer
  # would run on past its own failures.
  # _JIG_JSON_CODES asks _jig_die_as for its code marker, in the producer's
  # subshell only, and unexported: a child jig's refusal is plain text, and
  # reads as `failed`.
  set +e
  ( set -e; _JIG_JSON_CODES=1; "$producer" "$@" ) >"$out" 2>"$err"
  rc=$?
  set -e
  # The person reads stderr as the text form prints it: the markers are for
  # the code below, never for them.
  if LC_ALL=C grep -q "^$_JSON_CODE_MARK" "$err"; then
    JIG_JSON_MARK="$_JSON_CODE_MARK" awk 'index($0, ENVIRON["JIG_JSON_MARK"]) != 1' "$err" >&2
  else
    cat "$err" >&2
  fi
  printf '{"schema":1,"revision":%s,"generated_at":"%s",' "$rev" "$at"
  if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    printf '"data":%s}\n' "$(cat "$out")"
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    rc=1
    both=$(printf 'failed\nprinted no data')
  else
    both=$(_json_error_from "$err" "$rc")
  fi
  code=${both%%$'\n'*}
  json_quote "${both#*$'\n'}"
  printf '"error":{"code":"%s","message":%s}}\n' "$code" "$_JSON"
  return "$rc"
}

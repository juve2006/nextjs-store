# shellcheck shell=bash
# Telegram messages on autopilot events (spec: notifications, phase 1;
# adr-20261009-autopilot-stops-reach-telegram).
#
# An autopilot run that stops, ends, or — unattended — approves its own design
# or decides for the person, sends one short plain-text message to the
# person's Telegram:
#
#   ⏸ <project> · <task-id>
#   <the task's short description>
#   <the journal's text>
#   <the pull request URL>            (end only, when the task has one)
#
# Sending never holds up or fails the command that triggered it: the cheap
# checks run here, everything else — reading git and task.md, curl — runs
# detached, in a process group of its own, with every descriptor on /dev/null.
# With a key missing, `notify.autopilot: false` or no curl, nothing is sent and
# nothing is printed.
#
# The bot token never reaches a command line: curl reads the URL that holds it
# from stdin (`--config -`), and the text goes form-encoded from a file
# (`--data-urlencode text@<file>`), never spliced into a config line. Nothing
# here prints the token; JIG_CFG_MASK (config.sh) is what every reader prints
# instead.
#
# The outcome of the latest send of a task is one line in `notify`, beside the
# run's journal and never in it: the journal is appended to by copy-and-`mv`
# with no lock, and a sender writing there at the moment the agent records the
# next event would lose one of the two lines.
#
# Requires config.sh (cfg, jig_config_clone_root, jig_unattended, _cfg_chat_id,
# JIG_CFG_MASK), and task.sh (task_dir, task_state_get, _task_autopilot_mode,
# _task_likely_owner) for a task's messages and a waiting session's; a phase
# run's (jig_notify_phase) need no task.sh.

# jig_notify_token_ok <token> — exit 0 when <token> has a bot token's shape,
# `<digits>:<letters, digits, _ and ->`. Checked before the token is written
# into curl's config, so a quote or a line break in a hand-edited file can
# never reach that line.
jig_notify_token_ok() {
  case "$1" in
    *[!A-Za-z0-9_:-]* | :* | *: | *:*:*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  case "${1%%:*}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# jig_notify_autopilot <id> <event> <text> — send the message for one journal
# event, detached. Always exits 0 and prints nothing. Called right after the
# event was journaled, so a message never runs ahead of the record it reports.
jig_notify_autopilot() {
  local id="$1" event="$2" text="$3" token chat
  case "$event" in
    stop | end | approve | decide) ;;
    *) return 0 ;;
  esac
  case "$(cfg notify.autopilot true)" in
    false | no | 0 | off) return 0 ;;
  esac
  token=$(cfg notify.telegram.token "")
  chat=$(cfg notify.telegram.chat_id "")
  if [ -z "$token" ] || [ -z "$chat" ]; then return 0; fi
  command -v curl >/dev/null 2>&1 || return 0
  # `set -m` puts the sender in a process group of its own, so a runtime that
  # kills the command's group when the command returns does not take the
  # message with it. The braces end in `exit`, which runs the sender's own
  # cleanup list (bash 3.2 skips the EXIT trap of a subshell that runs off its
  # end).
  (
    set -m
    { _notify_send "$id" "$event" "$text" "$token" "$chat"; exit 0; } \
      </dev/null >/dev/null 2>&1 &
  ) </dev/null >/dev/null 2>&1
  return 0
}

# _notify_send <id> <event> <text> <token> <chat> — the detached half: build
# the message, send it, record the outcome. Never dies.
_notify_send() {
  set +e
  set +o pipefail
  local id="$1" event="$2" text="$3" token="$4" chat="$5" dir msg outcome
  dir=$(task_dir "$id") || return 0
  [ -d "$dir" ] || return 0
  msg=$(mktemp "$dir/notify.text.XXXXXX") || return 0
  jig_cleanup_add "$msg"
  _notify_message "$id" "$event" "$text" > "$msg"
  outcome=$(_notify_post "$token" "$chat" "$msg" "$dir")
  _notify_record "$id" "$event" "${outcome:-failed: no answer}"
  return 0
}

# _notify_post <token> <chat> <text-file> <work-dir> — send <text-file> to
# <chat>, and print the outcome as one line: `ok`, or `failed: <why>` with the
# token cut out, no tab or line break, at most 200 characters. Exit 0 on `ok`,
# 1 otherwise. The one place Jig calls Telegram: the autopilot's detached
# sender and `jig notify test` both go through it, so a test that passes has
# taken the path a real message takes. <work-dir> holds curl's answer while
# it is read; the files are removed before this returns.
#
# The shapes are checked before anything is sent: a token is written into
# curl's config line, so a quote or a line break in a hand-edited file must
# never reach it.
_notify_post() {
  local token="$1" chat="$2" msg="$3" dir="$4" resp err code detail
  if ! jig_notify_token_ok "$token"; then
    printf 'failed: notify.telegram.token is not a bot token (<digits>:<letters>)\n'
    return 1
  fi
  if ! _cfg_chat_id "$chat"; then
    printf 'failed: notify.telegram.chat_id is not a chat id (digits, or @name)\n'
    return 1
  fi
  # Removed on every path below, not registered for exit: both callers run
  # this inside `$(...)`, whose exit list is not theirs (conventions/shell.md).
  resp=$(mktemp "$dir/notify.resp.XXXXXX") || { printf 'failed: cannot write to %s\n' "$dir"; return 1; }
  err=$(mktemp "$dir/notify.err.XXXXXX") || { rm -f "$resp"; printf 'failed: cannot write to %s\n' "$dir"; return 1; }

  code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
    | curl -q --config - -sS --max-time 10 --connect-timeout 5 \
        -o "$resp" -w '%{http_code}' \
        --data-urlencode "chat_id=$chat" \
        --data-urlencode "text@$msg" 2>"$err")
  if [ "$code" = 200 ] && grep -q '"ok":[[:space:]]*true' "$resp" 2>/dev/null; then
    rm -f "$resp" "$err"
    printf 'ok\n'
    return 0
  fi
  detail=$(sed -n 's/.*"description":[[:space:]]*"\([^"]*\)".*/\1/p' "$resp" 2>/dev/null | sed -n 1p)
  [ -n "$detail" ] || detail=$(sed -n 1p "$err" 2>/dev/null)
  [ -n "$detail" ] || detail="HTTP ${code:-000}"
  case "$code" in
    '' | 000) ;;
    *) case "$detail" in "HTTP $code"*) ;; *) detail="HTTP $code: $detail" ;; esac ;;
  esac
  rm -f "$resp" "$err"
  _notify_outcome "failed: $detail" "$token"
  return 1
}

# _notify_message <id> <event> <text> — the message text, lines joined by a
# newline, no trailing one: the mark with `<project> · <id>`, the task's short
# description (left out when there is none), the journal's text, and for `end`
# the pull request URL when the task has one.
_notify_message() {
  local id="$1" event="$2" text="$3" mark desc url
  case "$event" in
    stop)
      # Nothing waits for the person in an unattended run: `resume` is refused
      # there, so the mark must not ask for an answer nobody can give.
      if [ "$(_task_autopilot_mode "$id")" = unattended ]; then mark='⛔'; else mark='⏸'; fi
      ;;
    end) mark='✅' ;;
    *) mark='🤖' ;;
  esac
  if [ -z "$text" ] && [ "$event" = end ]; then text="Run ended"; fi
  printf '%s %s · %s' "$mark" "$(_notify_project)" "$id"
  desc=$(_notify_description "$id")
  [ -z "$desc" ] || printf '\n%s' "$(_notify_cut "$desc" 80)"
  [ -z "$text" ] || printf '\n%s' "$(_notify_cut "$text" 300)"
  if [ "$event" = end ]; then
    url=$(task_state_get "$id" pr_url)
    [ -z "$url" ] || printf '\n%s' "$url"
  fi
}

# _notify_project — the repository's name from origin's URL, the same in every
# clone and worktree; with no origin, the main clone's directory name (a
# worktree's directory is named after its task, not the project).
_notify_project() {
  local url
  url=$(git -C "$JIG_PROJECT" remote get-url origin 2>/dev/null)
  url=${url%/}
  url=${url%.git}
  url=${url##*/}
  url=${url##*:}
  if [ -z "$url" ]; then
    url=$(jig_config_clone_root)
    url=${url%/}
    url=${url##*/}
  fi
  printf '%s\n' "$url"
}

# _notify_description <id> — the heading of the task's task.md when it says
# more than the id, else the first sentence of its `## Goal`.
_notify_description() {
  local id="$1" file head goal
  file="$(task_dir "$id")/task.md"
  [ -f "$file" ] || return 0
  head=$(sed -n 's/^# //p' "$file" | sed -n 1p)
  head=$(printf '%s' "$head" | sed 's/[[:space:]]*$//')
  if [ -n "$head" ] && [ "$head" != "$id" ]; then
    printf '%s\n' "$head"
    return 0
  fi
  # The template's `<!-- ... -->` guidance is not a description: comments are
  # dropped, on one line or across several, before a word is kept.
  goal=$(awk '
    /^## / { if (inside) exit_now = 1; inside = ($0 ~ /^## Goal[[:space:]]*$/); next }
    exit_now || !inside { next }
    {
      line = $0
      while (1) {
        if (incomment) {
          e = index(line, "-->")
          if (e == 0) { line = ""; break }
          line = substr(line, e + 3); incomment = 0
        }
        b = index(line, "<!--")
        if (b == 0) break
        rest = substr(line, b + 4)
        e = index(rest, "-->")
        if (e == 0) { line = substr(line, 1, b - 1); incomment = 1; break }
        line = substr(line, 1, b - 1) substr(rest, e + 3)
      }
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") { if (text != "" && !incomment && $0 !~ /-->/) exit_now = 1; next }
      text = (text == "" ? line : text " " line)
    }
    END { print text }
  ' "$file")
  case "$goal" in
    *". "*) goal="${goal%%. *}." ;;
  esac
  printf '%s\n' "$goal"
}

# _notify_cut <text> <n> — <text> cut to at most <n> characters, with `…` when
# anything was cut. Counted in characters, never bytes, and without relying on
# a UTF-8 locale being installed: under LC_ALL=C each byte is one position, and
# a UTF-8 continuation byte (0x80–0xBF) never starts a character. A cut in the
# middle of a character would hand Telegram invalid UTF-8, which it refuses.
_notify_cut() {
  local LC_ALL=C
  local s="$1" max="$2" i=0 n=0 len b
  # A character is at most four bytes: nothing past that can be kept.
  s=${s:0:$((max * 4 + 4))}
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    b=${s:i:1}
    case "$b" in
      [$'\x80'-$'\xbf']) ;;
      *)
        n=$((n + 1))
        if [ "$n" -gt "$max" ]; then
          printf '%s…\n' "${s:0:i}"
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
  done
  if [ "$len" -lt "${#1}" ]; then
    printf '%s…\n' "$s"
  else
    printf '%s\n' "$s"
  fi
}

# _notify_outcome <outcome> [<token>] — <outcome> as one line with no tab,
# the token cut out of it, kept to 200 characters: what `notify` records and
# `jig notify test` prints.
_notify_outcome() {
  local outcome="$1" token="${2:-}"
  outcome=$(printf '%s' "$outcome" | tr '\t\r\n' '   ')
  if [ -n "$token" ]; then
    outcome=${outcome//"$token"/$JIG_CFG_MASK}
  fi
  _notify_cut "$outcome" 200
}

# _notify_record <id> <event> <outcome> — the task's `notify` file: one line,
# `<UTC time>\t<event>\t<ok | failed: why>`, the latest send only, replaced
# atomically. <outcome> comes from _notify_post, already one masked line; it
# is passed through _notify_outcome again so nothing else can break the line.
_notify_record() {
  local dir
  dir=$(task_dir "$1") || return 0
  _notify_record_in "$dir" "$2" "$3"
}

# _notify_record_in <dir> <event> <outcome> — the `notify` file in <dir>, as
# _notify_record describes it: a task's workspace, a phase run's
# (_notify_phase_dir), or the checkout's runtime directory for a waiting
# session with no task (_notify_session_send).
_notify_record_in() {
  local dir="$1" event="$2" outcome file tmp
  [ -d "$dir" ] || return 0
  file="$dir/notify"
  outcome=$(_notify_outcome "$3")
  tmp=$(mktemp "$dir/notify.tmp.XXXXXX") || return 0
  jig_cleanup_add "$tmp"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$outcome" > "$tmp" \
    && mv "$tmp" "$file"
}

# jig_notify_failing — `<time>\t<who>\t<why>` when the latest send of all
# tasks, phase runs and waiting sessions failed; nothing otherwise. <who> is
# `task <id>`, `spec <id>`, or `a waiting session` for the checkout's own
# `runtime/notify` — a waiting session with no task (jig_notify_session). A
# later success anywhere clears it, so a warning that stays is one that is
# still true. A directory whose name is not a valid id is skipped, never
# handed to a path builder.
jig_notify_failing() {
  local ws session f name who line ts outcome best_ts="" best=""
  ws="$JIG_PROJECT/$JIG_AI_DIR/workspace"
  session="$JIG_PROJECT/$JIG_AI_DIR/runtime/notify"
  for f in "$ws"/tasks/*/notify "$ws"/specs/*/notify "$session"; do
    [ -f "$f" ] || continue
    if [ "$f" = "$session" ]; then
      who="a waiting session"
    else
      name=${f%/notify}
      who=${name%/*}
      name=${name##*/}
      jig_valid_id "$name" || continue
      case "$who" in
        */specs) who="spec $name" ;;
        *) who="task $name" ;;
      esac
    fi
    IFS= read -r line < "$f" || [ -n "$line" ] || continue
    IFS=$'\t' read -r ts _ outcome <<EOF
$line
EOF
    [ -n "$ts" ] || continue
    # A tie in the same second goes to a failure: hiding one is the worse
    # mistake.
    if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]] \
      || { [ "$ts" = "$best_ts" ] && [ "${outcome#failed: }" != "$outcome" ]; }; then
      best_ts=$ts
      best="$who"$'\t'"$outcome"
    fi
  done
  [ -n "$best" ] || return 0
  case "${best#*$'\t'}" in
    "failed: "*) printf '%s\t%s\t%s\n' "$best_ts" "${best%%$'\t'*}" "${best#*$'\t'failed: }" ;;
  esac
  return 0
}

# --- a phase run's stop -------------------------------------------------------
# `jig spec stop` (spec.sh): the coordinator of a phase run stops for the
# person — a wave waiting for an answer, or, unattended, a draft or a problem
# ending the run. A phase run has no journal (adr-20260922-a-phase-run-is-
# coordinated), so the command is the record, and the message goes as a task's
# stop does, under the same keys, checks and detached sender:
#
#   ⏸ <project> · <spec-id> · phase <n>
#   <the spec's title>
#   <the reason>
#
# The outcome is the `notify` file of `.ai/workspace/specs/<spec-id>/`, which
# jig_notify_failing reads beside the tasks'.

# jig_notify_phase <spec-id> <phase> <title> <text> — send the stop of phase
# <phase> of <spec-id>, detached. <title> is the spec's (spec.sh reads it: this
# file reads no spec). Always exits 0 and prints nothing.
jig_notify_phase() {
  local spec="$1" phase="$2" title="$3" text="$4" token chat
  case "$(cfg notify.autopilot true)" in
    false | no | 0 | off) return 0 ;;
  esac
  token=$(cfg notify.telegram.token "")
  chat=$(cfg notify.telegram.chat_id "")
  if [ -z "$token" ] || [ -z "$chat" ]; then return 0; fi
  command -v curl >/dev/null 2>&1 || return 0
  # Detached as jig_notify_autopilot's sender is, for the same reasons.
  (
    set -m
    { _notify_phase_send "$spec" "$phase" "$title" "$text" "$token" "$chat"; exit 0; } \
      </dev/null >/dev/null 2>&1 &
  ) </dev/null >/dev/null 2>&1
  return 0
}

# _notify_phase_dir <spec-id> — `.ai/workspace/specs/<spec-id>`, from an id the
# caller validated; refused here too, as every path builder does.
_notify_phase_dir() {
  jig_valid_id "$1" || return 1
  printf '%s/%s/workspace/specs/%s\n' "$JIG_PROJECT" "$JIG_AI_DIR" "$1"
}

# _notify_phase_send <spec-id> <phase> <title> <text> <token> <chat> — the
# detached half of jig_notify_phase. Never dies.
_notify_phase_send() {
  set +e
  set +o pipefail
  local spec="$1" phase="$2" title="$3" text="$4" token="$5" chat="$6" dir msg outcome
  dir=$(_notify_phase_dir "$spec") || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  msg=$(mktemp "$dir/notify.text.XXXXXX") || return 0
  jig_cleanup_add "$msg"
  _notify_phase_message "$spec" "$phase" "$title" "$text" > "$msg"
  outcome=$(_notify_post "$token" "$chat" "$msg" "$dir")
  _notify_record_in "$dir" stop "${outcome:-failed: no answer}"
  return 0
}

# _notify_phase_message <spec-id> <phase> <title> <text> — the message text,
# no trailing newline. `⛔` when this clone runs unattended: nobody is asked,
# the run has ended; `⏸` when the wave waits for the person's answer.
_notify_phase_message() {
  local mark='⏸'
  if jig_unattended; then mark='⛔'; fi
  printf '%s %s · %s · phase %s' "$mark" "$(_notify_project)" "$1" "$2"
  [ -z "$3" ] || printf '\n%s' "$(_notify_cut "$3" 80)"
  [ -z "$4" ] || printf '\n%s' "$(_notify_cut "$4" 300)"
}

# --- jig notify ---------------------------------------------------------------
# `jig notify setup` and `jig notify test` (spec: notifications, phase 1;
# adr-20261009-autopilot-stops-reach-telegram).
#
# `setup` is the person's: it asks for the bot token without showing it, so it
# runs only with a terminal on stdin and refuses at once without one — the
# agent's shell has none, which is what keeps the token out of the agent's
# transcript. No piped token is accepted for the same reason. `test` is
# anybody's, and is meant to run from the agent's own session: a sandbox that
# keeps the agent off the network keeps the autopilot's messages off it too.

cmd_notify() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    setup) _notify_setup "$@" ;;
    test) _notify_test "$@" ;;
    help | -h | --help)
      printf 'usage: jig notify setup    ask for the Telegram bot token (hidden) and chat id in your\n'
      printf '                           own terminal, write them to %s/config.local.yaml, send a test\n' "$JIG_AI_DIR"
      printf '       jig notify test     send one test message now, the way autopilot sends its own\n'
      ;;
    '') jig_die "notify: missing subcommand (usage: jig notify setup|test)" ;;
    *) jig_die "notify: unknown subcommand: $sub (usage: jig notify setup|test)" ;;
  esac
}

# _notify_terminal — exit 0 when stdin is a terminal. A function of its own so
# the tests, which have no terminal, can stand in for one; production code
# never overrides it.
_notify_terminal() {
  [ -t 0 ]
}

# _notify_test — `jig notify test`. Exit 0 when Telegram took the message.
_notify_test() {
  [ $# -eq 0 ] || jig_die "notify test: unknown argument: $1 (usage: jig notify test)"
  jig_require_repo
  _notify_test_send "notify test"
}

# _notify_test_send <label> — send `🔔 <project> · notifications work` through
# _notify_post, synchronously, and report: one stdout line on success, jig_die
# with Telegram's answer (token masked) otherwise. <label> prefixes errors.
_notify_test_send() {
  local label="$1" token chat dir msg outcome failing failing_who
  token=$(cfg notify.telegram.token "")
  chat=$(cfg notify.telegram.chat_id "")
  [ -n "$token" ] \
    || jig_die "$label: notify.telegram.token is not set; run .ai/scripts/jig notify setup in your own terminal"
  [ -n "$chat" ] \
    || jig_die "$label: notify.telegram.chat_id is not set; run .ai/scripts/jig notify setup in your own terminal"
  command -v curl >/dev/null 2>&1 \
    || jig_die "$label: curl is not installed or not on PATH; Jig sends Telegram messages with curl"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jig-notify.XXXXXX") \
    || jig_die "$label: cannot create a temporary directory"
  jig_cleanup_add -d "$dir"
  msg="$dir/text"
  printf '🔔 %s · notifications work' "$(_notify_project)" > "$msg"
  if ! outcome=$(_notify_post "$token" "$chat" "$msg" "$dir"); then
    jig_die "$label: Telegram did not take the message: ${outcome#failed: }"
  fi
  printf 'notify: test message sent to chat %s\n' "$chat"
  case "$(cfg notify.autopilot true)" in
    false | no | 0 | off)
      printf 'notify: notify.autopilot is false, so autopilot runs send nothing until it is true\n' ;;
  esac
  failing=$(jig_notify_failing)
  if [ -n "$failing" ]; then
    failing_who=${failing#*$'\t'}
    failing_who=${failing_who%%$'\t'*}
    printf 'notify: jig status still reports the failure of %s; it clears with the next message that gets through\n' \
      "$failing_who"
  fi
  return 0
}

# _notify_setup — `jig notify setup`. Asks for the token (hidden) and the chat
# id, checks both, writes them to the local file, then sends the test. Exit
# status is the test's: the settings stay written when it fails, so the person
# sees Telegram's answer and runs setup again to correct them.
_notify_setup() {
  # The argument is never echoed: the one a person is likeliest to pass here
  # is the token.
  [ $# -eq 0 ] || jig_die "notify setup: takes no arguments; it asks for the token itself, without showing it (usage: jig notify setup)"
  _notify_terminal \
    || jig_die "notify setup: asks for the bot token without showing it, so it needs your terminal; run it yourself there: .ai/scripts/jig notify setup"
  jig_require_repo
  local file dir shown token chat old_token old_chat prompt
  file=$(jig_config_local_file)
  dir=${file%/*}
  shown=$(_config_display_path "$file")
  [ -d "$dir" ] || jig_die "notify setup: no $JIG_AI_DIR/ directory at ${dir%/*}; run jig init there first"
  # A secret goes only into a file git will never commit.
  jig_config_local_ignored \
    || jig_die "notify setup: $shown is not ignored by git, and the token would be one commit away from being anyone's (fix: jig init)"

  old_token=$(cfg notify.telegram.token "")
  old_chat=$(cfg notify.telegram.chat_id "")

  printf 'The bot token comes from @BotFather in Telegram (/newbot). It is not shown as you type.\n' >&2
  prompt='Bot token: '
  [ -z "$old_token" ] || prompt='Bot token (Enter keeps the one set): '
  printf '%s' "$prompt" >&2
  _notify_ask hidden
  printf '\n' >&2
  token=$(_notify_trim "$_NOTIFY_ANSWER")
  [ -n "$token" ] || token=$old_token
  [ -n "$token" ] || jig_die "notify setup: no token entered; nothing written"
  jig_notify_token_ok "$token" \
    || jig_die "notify setup: that is not a bot token (<digits>:<letters>); nothing written"

  printf 'Your chat id: send your bot any message, then open\n' >&2
  printf 'https://api.telegram.org/bot<token>/getUpdates and take "chat":{"id": ...}.\n' >&2
  prompt='Chat id: '
  [ -z "$old_chat" ] || prompt="Chat id [$old_chat]: "
  printf '%s' "$prompt" >&2
  _notify_ask shown
  chat=$(_notify_trim "$_NOTIFY_ANSWER")
  [ -n "$chat" ] || chat=$old_chat
  [ -n "$chat" ] || jig_die "notify setup: no chat id entered; nothing written"
  _cfg_chat_id "$chat" \
    || jig_die "notify setup: not a chat id: digits (a group starts with -), or @name; nothing written"

  _notify_write_local "$file" "$token" "$chat"
  printf 'config: notify.telegram.token: %s (%s)\n' "$JIG_CFG_MASK" "$shown"
  printf 'config: notify.telegram.chat_id: %s (%s)\n' "$chat" "$shown"
  _notify_test_send "notify setup"
}

# _notify_ask hidden|shown — read one line from stdin into _NOTIFY_ANSWER (a
# global: the read must run in this shell, not in a `$(...)`, for the terminal
# restore below to belong to it). A hidden read turns the terminal's echo off;
# its state is saved first and put back on every exit, Ctrl-C included — bash
# leaves echo off when the INT trap exits in the middle of `read -s`. Both
# reads are bounded: a runtime that hands commands a pseudo-terminal passes
# the terminal check, and nobody there will ever type, so the wait ends with
# the same refusal rather than lasting for ever.
_NOTIFY_ANSWER=""
_NOTIFY_STTY=""
_NOTIFY_ASK_SECONDS=300
_notify_ask() {
  local rc=0 start=$SECONDS
  _NOTIFY_ANSWER=""
  if [ "$1" = hidden ]; then
    if [ -t 0 ] && _NOTIFY_STTY=$(stty -g 2>/dev/null) && [ -n "$_NOTIFY_STTY" ]; then
      jig_on_exit _notify_restore_tty
    fi
    IFS= read -r -s -t "$_NOTIFY_ASK_SECONDS" _NOTIFY_ANSWER || rc=$?
    _notify_restore_tty
  else
    IFS= read -r -t "$_NOTIFY_ASK_SECONDS" _NOTIFY_ANSWER || rc=$?
  fi
  # A failed read is the end of input — a last line with no line break still
  # counts — or the timeout. bash 4 reports the timeout above 128; bash 3.2
  # reports it as 1, like the end of input, so the clock tells them apart.
  if [ "$rc" -gt 128 ] || { [ "$rc" -ne 0 ] && [ $((SECONDS - start)) -ge "$_NOTIFY_ASK_SECONDS" ]; }; then
    printf '\n' >&2
    jig_die "notify setup: nothing typed for $_NOTIFY_ASK_SECONDS s; run it yourself in your own terminal: .ai/scripts/jig notify setup"
  fi
  return 0
}

# _notify_restore_tty — put the terminal back as _notify_ask found it. From
# /dev/tty, not stdin: on exit this runs inside the exit list's loop, whose
# stdin is a here-document (common.sh, _jig_exit_run).
_notify_restore_tty() {
  [ -z "$_NOTIFY_STTY" ] || stty "$_NOTIFY_STTY" </dev/tty 2>/dev/null || true
}

# _notify_trim <text> — <text> without surrounding blanks or carriage returns:
# a token pasted from a Windows clipboard or with a stray space still counts.
_notify_trim() {
  local s="$1"
  s=${s//$'\r'/}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

# _notify_write_local <file> <token> <chat> — <file> with both keys set, the
# way `jig config set` writes (_config_apply), replaced in one `mv`. Written
# under umask 077: the file now holds a secret, so it ends up readable by its
# owner only (Windows ignores the mode).
_notify_write_local() {
  local file="$1" tmp
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  jig_cleanup_add "$tmp.next"
  (
    umask 077
    if [ -f "$file" ]; then
      cat "$file" > "$tmp"
    else
      printf '%s\n' \
        "# Your own Jig settings for this clone: gitignored, never committed." \
        "# Only local keys are read from here (jig config set --local)." > "$tmp"
    fi
    _config_apply "$tmp" "$tmp.next" notify.telegram.token "$2" && mv "$tmp.next" "$tmp" \
      && _config_apply "$tmp" "$tmp.next" notify.telegram.chat_id "$3" && mv "$tmp.next" "$tmp" \
      && { chmod 600 "$tmp" 2>/dev/null || true; } \
      && mv "$tmp" "$file"
  ) || jig_die "notify setup: could not write $file"
}

# --- a waiting session --------------------------------------------------------
# An ordinary session — no autopilot run behind it — that waits for the
# person's permission or answer sends the same short message as an autopilot
# stop, when they asked for it with `notify.interactive: true` and connected
# the runtime's hook to `.ai/scripts/jig-notify-hook` themselves
# (adr-20261010-a-waiting-session-reaches-telegram; ADR-0024: Jig prints the
# snippet and never edits the runtime's config):
#
#   ⏸ <project> · <task-id>          (no task: the branch; detached: nothing)
#   <the task's short description>   (with a task only)
#   Waiting for your permission      (permission) | Waiting for your answer (input)
#
# The runtime decides when a session waits; Jig only forwards it. Everything
# the autopilot's sender guarantees holds here too, because this goes through
# the same _notify_post and the same detached launch.

# jig_notify_session <permission|input> — send the message for one wait of the
# session in $JIG_PROJECT, detached. Always exits 0 and prints nothing. The
# cheap checks run here; finding the task, building the text and curl run in
# the detached sender.
jig_notify_session() {
  local kind="$1" token chat
  case "$kind" in
    permission | input) ;;
    *) return 0 ;;
  esac
  [ "$(cfg notify.interactive false)" = true ] || return 0
  token=$(cfg notify.telegram.token "")
  chat=$(cfg notify.telegram.chat_id "")
  if [ -z "$token" ] || [ -z "$chat" ]; then return 0; fi
  command -v curl >/dev/null 2>&1 || return 0
  # The same launch as jig_notify_autopilot, for the same reasons.
  (
    set -m
    { _notify_session_send "$kind" "$token" "$chat"; exit 0; } \
      </dev/null >/dev/null 2>&1 &
  ) </dev/null >/dev/null 2>&1
  return 0
}

# _notify_session_send <kind> <token> <chat> — the detached half. The task is
# the one `task current` would name for this branch; zero or several name
# none. A wait for an answer while that task's autopilot run is `on` or
# `stopped` sends nothing: the run's own journal has already said it stopped,
# and the runtime's "waiting for input" a minute later would say it twice.
# A permission prompt the journal never sees, so it is sent whatever the run.
_notify_session_send() {
  set +e
  set +o pipefail
  local kind="$1" token="$2" chat="$3" branch id="" dir msg outcome
  branch=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null) || branch=""
  if [ -n "$branch" ]; then
    id=$(_task_likely_owner "$branch" 2>/dev/null) || id=""
  fi
  if [ -n "$id" ] && [ "$kind" = input ]; then
    case "$(task_state_get "$id" autopilot)" in
      on | stopped) return 0 ;;
    esac
  fi
  if [ -n "$id" ]; then
    dir=$(task_dir "$id") || return 0
  else
    dir="$JIG_PROJECT/$JIG_AI_DIR/runtime"
    mkdir -p "$dir" 2>/dev/null || return 0
  fi
  [ -d "$dir" ] || return 0
  msg=$(mktemp "$dir/notify.text.XXXXXX") || return 0
  jig_cleanup_add "$msg"
  _notify_session_message "$kind" "$id" "$branch" > "$msg"
  outcome=$(_notify_post "$token" "$chat" "$msg" "$dir")
  _notify_record_in "$dir" wait "${outcome:-failed: no answer}"
  return 0
}

# _notify_session_message <kind> <id> <branch> — the text, lines joined by a
# newline, no trailing one. <id> and <branch> may be empty.
_notify_session_message() {
  local kind="$1" id="$2" branch="$3" desc
  printf '⏸ %s' "$(_notify_project)"
  if [ -n "$id" ]; then
    printf ' · %s' "$id"
  elif [ -n "$branch" ]; then
    printf ' · %s' "$(_notify_cut "$branch" 80)"
  fi
  if [ -n "$id" ]; then
    desc=$(_notify_description "$id")
    [ -z "$desc" ] || printf '\n%s' "$(_notify_cut "$desc" 80)"
  fi
  case "$kind" in
    permission) printf '\nWaiting for your permission' ;;
    *) printf '\nWaiting for your answer' ;;
  esac
}

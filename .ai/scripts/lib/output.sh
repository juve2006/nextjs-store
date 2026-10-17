# Terminal output: the one place that decides whether a command's report is
# read by a person at a terminal or by a pipe, and the blocks a report is
# built from (adr-20261005-output-is-decorated-only-on-a-terminal). Sourced by
# the commands that print a report through it; sourcing it twice is harmless,
# since it only defines functions and constants.
#
# Two forms, decided once per process by out_init:
#
#   - plain: stdout is not a terminal — a pipe, a file, CI, an agent. Every
#     block prints exactly the bytes the command printed before this layer
#     existed, so logs, agents and the test suite's assertions see no change.
#   - terminal: stdout is a terminal. A command may then group and reorder
#     what it says (that is its own decision, asked through out_terminal), and
#     the blocks add colour unless NO_COLOR is set or TERM is dumb.
#
# Words carry the meaning in both forms; colour only reinforces it, because a
# monochrome terminal, a colour-blind reader and a copy into a chat all lose
# it. ASCII, except the few marks a section is drawn with (a rule, a middle
# dot, an ellipsis, the branches of a tree), which are UTF-8 only when the locale says UTF-8 and ASCII
# otherwise: a console code page may not have anything else. No tput: it is an
# external program with its own terminfo (ADR-0002), and these few SGR codes
# are understood by every terminal Jig targets, Git Bash's included.
# shellcheck shell=bash

_OUT_TERMINAL=0
_OUT_COLOR=0
_OUT_UTF8=0

_OUT_RESET=$'\033[0m'
_OUT_BOLD=$'\033[1m'
_OUT_GREEN=$'\033[32m'
_OUT_YELLOW=$'\033[33m'
_OUT_RED_BOLD=$'\033[1;31m'
_OUT_CYAN=$'\033[36m'
_OUT_CYAN_BOLD=$'\033[1;36m'
_OUT_DIM=$'\033[2m'

# The width a section is drawn to: the terminal every report is read in, at
# its narrowest. Fixed, not measured: COLUMNS is not exported to a child, and
# tput is not a dependency (ADR-0002).
OUT_WIDTH=80

# The marks a section is drawn with, ASCII until out_init finds a UTF-8
# locale: the rule under a heading (private, out_section draws it), and three a
# command may read once out_init has run — the separator between items of one
# row (OUT_SEP), the mark of a row that is a remark rather than an item
# (OUT_MARK) and "more" (OUT_MORE). Read as variables, not asked through a
# function: a $(...) per cell is a process per item (conventions/shell.md).
_OUT_RULE='-'
OUT_SEP=' | '
# shellcheck disable=SC2034 # read by the commands that source this layer
OUT_MARK='.'
# shellcheck disable=SC2034 # read by the commands that source this layer
OUT_MORE='...'
# shellcheck disable=SC2034 # read by the commands that source this layer
OUT_TREE='|-'
# shellcheck disable=SC2034 # read by the commands that source this layer
OUT_TREE_LAST='`-'

# One two-byte character: one in a shell whose locale is UTF-8, two otherwise.
_OUT_UTF8_PROBE=$'\xc2\xb7'

# The width the level word is padded to: the widest word plus one space.
_OUT_PAD='      '

# out_init — decide the form for this process. Memoises into globals, so it is
# called as a plain command, never through $(...) (conventions/shell.md).
#
# JIG_TERMINAL overrides the measurement: 1 treats stdout as a terminal (the
# tests, Windows CI, a reader piping into `less -R`), 0 never does (an agent
# whose runtime hands commands a pseudo-terminal). Anything else measures.
out_init() {
  case "${JIG_TERMINAL:-}" in
    1) _OUT_TERMINAL=1 ;;
    0) _OUT_TERMINAL=0 ;;
    *)
      if [ -t 1 ]; then _OUT_TERMINAL=1; else _OUT_TERMINAL=0; fi
      ;;
  esac
  _OUT_COLOR=0
  if [ "$_OUT_TERMINAL" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
    _OUT_COLOR=1
  fi
  # The locale decides the marks, as the C library itself reads it: the
  # first of LC_ALL, LC_CTYPE and LANG that is set. Only a terminal gets
  # anything but ASCII.
  _OUT_UTF8=0
  _OUT_RULE='-' OUT_SEP=' | ' OUT_MARK='.' OUT_MORE='...' OUT_TREE='|-' OUT_TREE_LAST='`-'
  if [ "$_OUT_TERMINAL" = 1 ]; then
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
        # Only if this shell could take that locale: otherwise ${#var}
        # counts bytes, and every column after a mark would be off.
        if [ ${#_OUT_UTF8_PROBE} = 1 ]; then
          _OUT_UTF8=1
          # shellcheck disable=SC2034 # OUT_MARK, OUT_MORE, OUT_TREE*: read by the commands
          _OUT_RULE=$'\xe2\x94\x80' OUT_SEP=$' \xc2\xb7 ' OUT_MARK=$'\xc2\xb7' OUT_MORE=$'\xe2\x80\xa6'
          # shellcheck disable=SC2034
          OUT_TREE=$'\xe2\x94\x9c\xe2\x94\x80' OUT_TREE_LAST=$'\xe2\x94\x94\xe2\x94\x80'
        fi
        ;;
    esac
  fi
  return 0
}

# out_terminal — exit 0 when the report is read at a terminal: the question a
# command asks before it groups or reorders anything.
out_terminal() {
  [ "$_OUT_TERMINAL" = 1 ]
}

# _out_level_color <level> — the SGR prefix for a level word, empty for an
# unknown one.
_out_level_color() {
  case "$1" in
    ok) printf '%s' "$_OUT_GREEN" ;;
    warn) printf '%s' "$_OUT_YELLOW" ;;
    fail) printf '%s' "$_OUT_RED_BOLD" ;;
    ask) printf '%s' "$_OUT_CYAN" ;;
  esac
}

# out_status <level> <text> — one status line: the level word (ok, warn, fail,
# or ask for a question; the answer is typed after it) padded to six columns, then the text. Plain form: printf '%-6s%s\n'.
out_status() {
  local level="$1" text="$2" color
  if [ "$_OUT_COLOR" = 1 ]; then
    color=$(_out_level_color "$level")
    printf '%s%s%s%s%s\n' "$color" "$level" "$_OUT_RESET" "${_OUT_PAD:${#level}}" "$text"
  else
    printf '%-6s%s\n' "$level" "$text"
  fi
}

# out_detail <label> <text> — a line that belongs to the status line above it,
# indented under its text: "      fix: <what to do>".
out_detail() {
  if [ "$_OUT_COLOR" = 1 ]; then
    printf '%s%s%s:%s %s\n' "$_OUT_PAD" "$_OUT_BOLD" "$1" "$_OUT_RESET" "$2"
  else
    printf '%s%s: %s\n' "$_OUT_PAD" "$1" "$2"
  fi
}

# out_group <level> <summary> <name>... — many items of one level said once:
# "ok    13 passed: git, git identity, ...". Nothing is printed for no names.
out_group() {
  local level="$1" summary="$2" names="" n
  shift 2
  [ $# -gt 0 ] || return 0
  for n in "$@"; do
    if [ -n "$names" ]; then names="$names, $n"; else names=$n; fi
  done
  out_status "$level" "$summary: $names"
}

# out_gap — the blank line between two groups of blocks.
out_gap() {
  printf '\n'
}

# out_summary <text> — the closing line of a report.
out_summary() {
  if [ "$_OUT_COLOR" = 1 ]; then
    printf '%s%s%s\n' "$_OUT_BOLD" "$1" "$_OUT_RESET"
  else
    printf '%s\n' "$1"
  fi
}

# --- sections (a report read by section: jig status) ----------------------------
#
# A report too long to read as one list is drawn as a heading line, then
# sections: a title on a rule, and rows of aligned columns under it, within
# OUT_WIDTH columns. These
# blocks are for the terminal form; their plain form is still ASCII without
# colour, pinned in tests/output.t.sh like every other block.

# _out_len <text> — the number of characters in <text>, as the locale counts
# them (bash's ${#var}), into _OUT_LEN. A global, not stdout: it is asked once
# per cell, and a $(...) per cell is a process per item.
_OUT_LEN=0
_out_len() {
  _OUT_LEN=${#1}
}

# _out_fill <n> <char> — <char> repeated <n> times, into _OUT_FILL.
_OUT_FILL=""
_out_fill() {
  local n="$1" c="$2"
  _OUT_FILL=""
  while [ "$n" -gt 0 ]; do
    _OUT_FILL="$_OUT_FILL$c"
    n=$((n - 1))
  done
}

# _out_style <style> — the SGR prefix of a cell style into _OUT_SGR, empty
# for plain or without colour. Styles: plain, bold, dim, title, and the level
# words ok, warn, fail and ask, which colour as out_status does. A global, not
# stdout, for the same reason as _out_len.
_OUT_SGR=""
_out_style() {
  _OUT_SGR=""
  [ "$_OUT_COLOR" = 1 ] || return 0
  case "$1" in
    bold) _OUT_SGR=$_OUT_BOLD ;;
    dim) _OUT_SGR=$_OUT_DIM ;;
    title) _OUT_SGR=$_OUT_CYAN_BOLD ;;
    ok) _OUT_SGR=$_OUT_GREEN ;;
    warn) _OUT_SGR=$_OUT_YELLOW ;;
    fail) _OUT_SGR=$_OUT_RED_BOLD ;;
    ask) _OUT_SGR=$_OUT_CYAN ;;
  esac
  return 0
}

# out_join <item>... — the items in one line, separated by the section
# separator (" · " on a UTF-8 terminal, " | " otherwise). Printed without a
# newline, for a cell's text.
out_join() {
  local first=1 i
  for i in "$@"; do
    if [ "$first" = 1 ]; then first=0; else printf '%s' "$OUT_SEP"; fi
    printf '%s' "$i"
  done
}

# out_heading <text> <level> <verdict> — the first line of a sectioned report:
# <text> on the left, <verdict> coloured by <level> (ok, warn, fail) on the
# right edge of the section width, or two spaces after a <text> too long for
# that.
out_heading() {
  local text="$1" level="$2" verdict="$3" pad reset=""
  _out_len "$text$verdict"
  pad=$((OUT_WIDTH - _OUT_LEN))
  [ "$pad" -ge 2 ] || pad=2
  _out_fill "$pad" ' '
  _out_style "$level"
  if [ -n "$_OUT_SGR" ]; then reset=$_OUT_RESET; fi
  printf '%s%s%s%s%s\n' "$text" "$_OUT_FILL" "$_OUT_SGR" "$verdict" "$reset"
}

# out_section <title> [<counts>] — a blank line, then the section's title on a
# rule drawn to the section width: "── Tasks  (3 active) ──────…". The title
# is bold cyan, the rule dim, the counts plain.
out_section() {
  local title="$1" counts="${2:-}" text n t="" d="" r=""
  text="$_OUT_RULE$_OUT_RULE $title"
  [ -z "$counts" ] || text="$text  ($counts)"
  _out_len "$text "
  n=$((OUT_WIDTH - _OUT_LEN))
  [ "$n" -ge 3 ] || n=3
  _out_fill "$n" "$_OUT_RULE"
  if [ "$_OUT_COLOR" = 1 ]; then t=$_OUT_CYAN_BOLD d=$_OUT_DIM r=$_OUT_RESET; fi
  printf '\n%s%s%s %s%s%s' "$d" "$_OUT_RULE$_OUT_RULE" "$r" "$t" "$title" "$r"
  [ -z "$counts" ] || printf '  (%s)' "$counts"
  printf ' %s%s%s\n' "$d" "$_OUT_FILL" "$r"
}

# out_row <style> <width> <text> [<style> <width> <text>]... — one row of a
# section, indented by two spaces: each cell in its style, padded to its width
# (which includes the gap to the next cell), the last cell never padded. A
# text as wide as its cell or wider is followed by one space, never run into
# the next cell. Nothing trails the last text: an empty last cell adds no
# spaces.
out_row() {
  local style width text line="  " owed="" pad
  while [ $# -ge 3 ]; do
    style="$1" width="$2" text="$3"
    shift 3
    if [ -n "$text" ]; then
      _out_style "$style"
      line="$line$owed$_OUT_SGR$text"
      if [ -n "$_OUT_SGR" ]; then line="$line$_OUT_RESET"; fi
      owed=""
    fi
    [ $# -ge 3 ] || break
    _out_len "$text"
    pad=$((width - _OUT_LEN))
    if [ -n "$text" ] && [ "$pad" -lt 1 ]; then pad=1; fi
    if [ "$pad" -gt 0 ]; then
      _out_fill "$pad" ' '
      owed="$owed$_OUT_FILL"
    fi
  done
  printf '%s\n' "$line"
}

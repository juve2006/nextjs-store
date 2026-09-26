# Reader/writer for the marked instructions section: the part of a project's
# AGENTS.md that the framework writes and `jig upgrade` keeps current
# (domains/install, adr-20260924-jig-owns-a-marked-section-of-the-instructions).
#
# A format parser rather than a command, like lib/frontmatter.sh and
# lib/manifest.sh, and sourced by the commands that need it: init, upgrade,
# status and doctor.
#
# The section is delimited by two literal whole lines that jig itself wrote:
#
#     <!-- jig:begin -->
#     ...the framework's text...
#     <!-- jig:end -->
#
# Nothing outside those two lines is parsed. There is no partial understanding
# of the document to get wrong: either the pair is present exactly once and in
# order, or every function here reports `malformed` and the caller writes
# nothing. That is what separates this from editing a project-owned
# `settings.json`, which ADR-0024 refused because identifying the framework's
# entry there meant understanding arbitrary JSON.
#
# Line endings: a clone made by Git for Windows with core.autocrlf=true checks
# AGENTS.md out with CRLF (ADR-0037). The markers are therefore matched with a
# trailing-whitespace tolerance, the text is **compared and hashed normalised
# to LF** so the recorded hash is the same on every platform, and it is
# **written back in whatever line endings the file already uses** so a replace
# never leaves a file with mixed endings.
# shellcheck shell=bash

# The markers as a human types them, for the messages that tell someone what
# this file expects to find. Used by upgrade.sh and doctor.sh, which are
# other files as far as shellcheck can see.
# shellcheck disable=SC2034
JIG_SECTION_BEGIN='<!-- jig:begin -->'
# shellcheck disable=SC2034
JIG_SECTION_END='<!-- jig:end -->'

# Whole-line matches, tolerating trailing spaces and the CR of a CRLF file
# ([[:space:]] includes \r). The marker text carries no version and no hash:
# it is a literal that must stay matchable forever, so everything that changes
# between releases lives *inside* the section and travels with it.
_JIG_SECTION_BEGIN_RE='^<!-- jig:begin -->[[:space:]]*$'
_JIG_SECTION_END_RE='^<!-- jig:end -->[[:space:]]*$'

# jig_section_state <file>
# Prints `absent`, `ok` or `malformed`; always exits 0.
#
#   absent     the file is missing, or carries neither marker
#   ok         exactly one begin and one end, in that order
#   malformed  anything else: a repeated marker, a missing half of the pair,
#              or an end before its begin
#
# `malformed` is deliberately not something a caller repairs. A file whose
# markers jig cannot read unambiguously is a file jig does not write.
jig_section_state() {
  local file="$1" nb ne lb le
  if [ ! -f "$file" ]; then
    printf 'absent\n'
    return 0
  fi
  nb=$(grep -cE "$_JIG_SECTION_BEGIN_RE" "$file" || true)
  ne=$(grep -cE "$_JIG_SECTION_END_RE" "$file" || true)
  if [ "$nb" = 0 ] && [ "$ne" = 0 ]; then
    printf 'absent\n'
    return 0
  fi
  if [ "$nb" != 1 ] || [ "$ne" != 1 ]; then
    printf 'malformed\n'
    return 0
  fi
  lb=$(grep -nE "$_JIG_SECTION_BEGIN_RE" "$file" | sed -n 's/^\([0-9][0-9]*\):.*/\1/p')
  le=$(grep -nE "$_JIG_SECTION_END_RE" "$file" | sed -n 's/^\([0-9][0-9]*\):.*/\1/p')
  if [ "$lb" -lt "$le" ]; then
    printf 'ok\n'
  else
    printf 'malformed\n'
  fi
}

# jig_section_read <file>
# Prints the text between the markers, exclusive of the marker lines,
# normalised to LF. Prints nothing when the file has no usable pair, so
# callers check jig_section_state first; this function does not distinguish
# "no section" from "an empty section".
jig_section_read() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v b="$_JIG_SECTION_BEGIN_RE" -v e="$_JIG_SECTION_END_RE" '
    $0 ~ e { f = 0 }
    f { print }
    $0 ~ b { f = 1 }
  ' "$file" | tr -d '\r'
}

# jig_section_hash <file>
# The git blob hash of the LF-normalised section text — the same value on
# every platform, whatever core.autocrlf did to the file. This is what the
# manifest header records as `instructions.section` and what decides whether
# the project has changed the section since jig wrote it.
#
# One function produces the text for hashing, for comparing and for writing,
# so the three can never disagree about what "the section" is. That agreement
# is the whole safety of the replace decision: a hash taken over different
# bytes than the comparison uses is how an upgrade would overwrite somebody's
# edit while believing the section untouched.
jig_section_hash() {
  jig_section_read "$1" | git hash-object --stdin
}

# jig_section_report_state <file> <recorded>
# The one answer `jig status` and `jig doctor` both report, so the two can
# never disagree about it. <recorded> is the manifest's `instructions.section`
# value, passed in rather than read here: this file parses a document format
# and knows nothing about the manifest.
#
#   unmarked  no usable marker pair, or jig has no record of writing one —
#             either way `jig upgrade` cannot reach the section
#   modified  marked and recorded, but the text has been changed here, so
#             upgrade keeps it
#   current   marked, recorded and unchanged: upgrades arrive on their own
jig_section_report_state() {
  local file="$1" recorded="$2"
  if [ "$(jig_section_state "$file")" != ok ] || [ -z "$recorded" ]; then
    printf 'unmarked\n'
    return 0
  fi
  if [ "$(jig_section_hash "$file")" = "${recorded%% *}" ]; then
    printf 'current\n'
  else
    printf 'modified\n'
  fi
}

# jig_section_write <file> <section-file>
# Replace the marked region of <file> with the contents of <section-file>
# (the section text alone, without markers). The markers themselves stay.
#
# Refuses, touching nothing, unless <file>'s state is `ok`.
#
# Written beside the destination and renamed over it, never onto it — the
# same rule `_upgrade_place` follows, and for a related reason: a rename
# leaves whatever is reading the old file alone, and a half-written AGENTS.md
# is a file the framework cannot rebuild.
jig_section_write() {
  local file="$1" section="$2" tmp="$1.tmp.$$" crlf=0 first cr

  [ "$(jig_section_state "$file")" = ok ] || return 1

  cr=$(printf '\r')

  # Detect the file's line endings with the shell's own `read`, never with a
  # text tool. Under Git Bash grep, sed and awk take the CR of a CRLF file as
  # part of the line separator and drop it before any pattern sees it: on a
  # file whose every line ends CRLF, `grep -c '<CR>$'` answers 0 and
  # `grep -E '^<!-- jig:begin -->[[:space:]]*$' | sed -n 1p` hands back a
  # marker with no CR on it. Reading the line through the shell keeps the
  # byte, which is why `_verify_map_check` has to strip it there.
  IFS= read -r first < "$file" || :
  case "$first" in
    *"$cr") crlf=1 ;;
  esac

  # Carry the destination's mode across by copying it first and then
  # truncating that copy: `> "$tmp"` keeps the inode `cp -p` just gave the
  # right permissions.
  cp -p "$file" "$tmp" || jig_die "upgrade: could not write $file"
  {
    # head: everything up to and including the begin marker.
    awk -v b="$_JIG_SECTION_BEGIN_RE" '{ print } $0 ~ b { exit }' "$file"
    # body: the new section.
    cat "$section"
    # tail: the end marker and everything after it.
    awk -v e="$_JIG_SECTION_END_RE" '$0 ~ e { f = 1 } f { print }' "$file"
  } | {
    # The endings are applied once, to the whole result, rather than trusted
    # to survive three separate tools. The awk above cannot pass a CR through
    # on Windows — it never saw one — so the head and the tail arrive here
    # normalised whatever the file was, and a per-part "byte for byte" copy
    # would silently rewrite a Windows project's CRLF AGENTS.md as LF.
    if [ "$crlf" = 1 ]; then
      tr -d '\r' | sed "s/\$/$cr/"
    else
      tr -d '\r'
    fi
  } > "$tmp"
  mv -f "$tmp" "$file" || jig_die "upgrade: could not write $file"
}

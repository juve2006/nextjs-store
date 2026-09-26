# Reader for knowledge document frontmatter (schemas/frontmatter.md, ADR-0004).
# Grammar is a flat YAML subset: scalars, inline lists `[a, b]`, and one-level
# block lists `  - item` (two-space indent). No nesting, no multi-line scalars.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# fm_has <file> — exit 0 when the file starts with a `---` line and has a
# closing `---` line further down.
fm_has() {
  local file="$1"
  [ -f "$file" ] || return 1
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { found = 1; exit }
    END { exit !found }
  ' "$file"
}

# fm_block <file> — print the raw lines strictly between the opening and the
# first closing `---` delimiter. Prints nothing when there is no frontmatter.
fm_block() {
  local file="$1"
  awk '
    NR == 1 { if ($0 != "---") exit; in_block = 1; next }
    in_block && $0 == "---" { exit }
    in_block { print }
  ' "$file"
}

# fm_get <file> <key> — print the trimmed scalar value of <key> (trailing
# `# comment` stripped, surrounding double quotes stripped). Prints nothing
# when the key is absent or is a list (inline or block).
fm_get() {
  local file="$1" key="$2" block raw val
  block=$(fm_block "$file")
  [ -n "$block" ] || return 0
  raw=$(printf '%s\n' "$block" | sed -n "s/^${key}:[[:space:]]*//p" | head -n 1)
  val=$(printf '%s' "$raw" | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')
  case "$val" in
    '' | \[*) return 0 ;;
  esac
  val=$(printf '%s' "$val" | sed 's/^"\(.*\)"$/\1/')
  printf '%s\n' "$val"
}

# fm_list <file> <key> — print list items one per line, quotes stripped.
# Supports inline `key: [a, b]` and block `key:\n  - a\n  - b` forms.
fm_list() {
  local file="$1" key="$2" block inline_content
  block=$(fm_block "$file")
  [ -n "$block" ] || return 0

  # `grep -c` rather than `grep -q`: counting every match means reading to the
  # end of the input, so the printf behind it never writes into a closed pipe
  # (conventions/shell.md). The `head -n 1` below is the other shape the rule
  # allows: what writes into it is sed, with one short line left to write.
  if printf '%s\n' "$block" | grep -c -E "^${key}:[[:space:]]*\[" >/dev/null; then
    inline_content=$(printf '%s\n' "$block" \
      | sed -n "s/^${key}:[[:space:]]*\[\(.*\)\].*/\1/p" | head -n 1)
    printf '%s\n' "$inline_content" | tr ',' '\n' \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/' \
      | sed '/^$/d'
    return 0
  fi

  printf '%s\n' "$block" | awk -v key="$key" '
    capture == 0 {
      if ($0 ~ ("^" key ":[[:space:]]*(#.*)?$")) { capture = 1 }
      next
    }
    capture == 1 {
      if ($0 ~ /^  - /) {
        line = $0
        sub(/^  - /, "", line)
        print line
      } else {
        capture = 2
      }
    }
  ' | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//; s/^[[:space:]]*//; s/^"\(.*\)"$/\1/'
}

# fm_keys <file> — print top-level keys, one per line, in document order.
fm_keys() {
  local file="$1"
  fm_block "$file" | sed -n 's/^\([a-z_][a-z_]*\):.*/\1/p'
}

# fm_body_start <file> — print the 1-based line number of the first line
# after the closing `---`. Prints 1 when the file has no (valid) frontmatter,
# so callers can scan the whole file as the body.
fm_body_start() {
  local file="$1"
  awk '
    NR == 1 {
      if ($0 != "---") { print 1; found = 1; exit }
      in_block = 1; next
    }
    in_block && $0 == "---" { print NR + 1; found = 1; exit }
    END { if (!found) print 1 }
  ' "$file"
}

# --- writers -----------------------------------------------------------------
# Writers rewrite the whole file through a temporary and `mv`
# (convention-shell): a crash must not leave a half-written document. Keys and
# values reach awk as variables and are compared literally — never
# interpolated into a `sed` expression or a regex, because `paths` items are
# globs full of metacharacters (convention-shell, ADR-0008). A multi-line
# replacement is handed over as a *file* awk reads with getline, not as a
# `-v` assignment: BSD awk rejects a raw newline inside one.

# fm_is_list <file> <key> — exit 0 when <key> is written in either list form,
# inline `key: [...]` or a block `key:` with `  - ` items under it.
fm_is_list() {
  local file="$1" key="$2"
  fm_block "$file" | grep -c -E "^${key}:[[:space:]]*(\[|(#.*)?$)" >/dev/null
}

# _fm_valid_item <item> — exit 0 when the item can be read back unchanged.
# `#` cannot: fm_list strips a trailing comment before it strips the
# surrounding quotes, so a quoted `#` loses everything from the `#` onward
# *and* its closing quote. The grammar has no escape for it
# (schemas/frontmatter.md), so the writer refuses instead of corrupting.
_fm_valid_item() {
  case "$1" in
    *'#'*) return 1 ;;
    *) return 0 ;;
  esac
}

# _fm_valid_scalar <value> — exit 0 when the value can be written as a scalar
# and read back unchanged. `#` cannot, for the reason _fm_valid_item gives for
# list items: fm_get strips a trailing comment *before* it strips the
# surrounding quotes, so quoting does not rescue it. `"` cannot either — the
# grammar has no escape (schemas/frontmatter.md), so an inner quote ends the
# value for any real YAML parser. Both are refused rather than corrupted.
_fm_valid_scalar() {
  case "$1" in
    *'#'* | *'"'*) return 1 ;;
    *) return 0 ;;
  esac
}

# _fm_quote_scalar <value> — print the value ready to follow `key: `, quoted
# when plain YAML would read it as anything but this string.
#
# jig's own reader is forgiving: fm_get takes everything after the first
# `key: `, so `summary: Terms: a, b` reads back correctly here and breaks in
# every real YAML parser, which sees a nested mapping. The frontmatter is meant
# to be read by both, so the writer quotes what YAML requires and nothing more.
# Deliberately *not* quoted: values that merely look numeric or boolean. Doing
# so would rewrite `date: 2026-09-09` as a quoted string on every touch, which
# is churn for a field no caller reads as anything but text.
_fm_quote_scalar() {
  local value="$1" first="${1:0:1}"
  case "$first" in
    '-' | '?' | ':' | ',' | '[' | ']' | '{' | '}' | '&' | '*' | '!' | '|' \
      | '>' | "'" | '"' | '%' | '@' | '`' | ' ')
      printf '"%s"' "$value"
      return 0
      ;;
  esac
  case "$value" in
    '' | *': '* | *: | *' ') printf '"%s"' "$value" ;;
    *) printf '%s' "$value" ;;
  esac
}

# _fm_replace <file> — replace <file> with stdin, atomically. Refuses to write
# an empty document, so a failing awk upstream cannot truncate knowledge.
_fm_replace() {
  local file="$1" tmp="$1.tmp.$$"
  cat > "$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    printf 'jig: error: frontmatter: refusing to write an empty document: %s\n' \
      "$file" >&2
    return 1
  fi
  mv "$tmp" "$file"
}

# fm_set <file> <key> <value> — set a scalar key inside the frontmatter,
# replacing the existing line or appending just before the closing `---`.
# Scalars only: it refuses a key that currently holds a list, because
# overwriting `paths:` with a scalar would leave its `  - ` items orphaned
# under a key that no longer claims them, and every later read of that
# document would mis-parse them.
fm_set() {
  local file="$1" key="$2" value="$3"
  fm_has "$file" || return 1
  if fm_is_list "$file" "$key"; then
    printf 'jig: error: frontmatter: %s holds a list; use fm_list_set\n' "$key" >&2
    return 1
  fi
  if ! _fm_valid_scalar "$value"; then
    printf 'jig: error: frontmatter: %s may not contain '"'"'#'"'"' or '"'"'"'"'"': %s\n' \
      "$key" "$value" >&2
    return 1
  fi
  value=$(_fm_quote_scalar "$value")
  awk -v key="$key" -v value="$value" '
    NR == 1 { print; in_block = 1; next }
    in_block && $0 == "---" {
      if (!done) print key ": " value
      print; in_block = 0; done = 1; next
    }
    in_block && index($0, key ":") == 1 {
      if (!done) { print key ": " value; done = 1 }
      next
    }
    { print }
  ' "$file" | _fm_replace "$file"
}

# _fm_quote_item <item> — quote an item containing a character that reads as
# syntax, so `paths` globs come out `- "src/**"` while plain `domains` tags
# come out `- flow`, which is how the existing documents are written.
# `#` is deliberately absent: quoting does not save it (see _fm_valid_item),
# so it is rejected before reaching here rather than quoted into a lie.
_fm_quote_item() {
  case "$1" in
    *[][*?{},:\ ]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_list_set <file> <key> — read items from stdin (one per line) and write
# them as a block list, or `key: []` when stdin holds none. Replaces the key
# wherever it already is (inline or block), otherwise appends it before the
# closing `---`.
fm_list_set() {
  local file="$1" key="$2" items item rfile rc
  fm_has "$file" || return 1
  items=$(sed '/^$/d')

  while IFS= read -r item; do
    [ -n "$item" ] || continue
    _fm_valid_item "$item" && continue
    printf 'jig: error: frontmatter: %s item may not contain "#": %s\n' \
      "$key" "$item" >&2
    return 1
  done < <(printf '%s\n' "$items")

  rfile="${TMPDIR:-/tmp}/jig-fm-render.$$"
  if [ -z "$items" ]; then
    printf '%s: []\n' "$key" > "$rfile"
  else
    printf '%s:\n' "$key" > "$rfile"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      printf '  - %s\n' "$(_fm_quote_item "$item")" >> "$rfile"
    done < <(printf '%s\n' "$items")
  fi

  awk -v key="$key" -v rfile="$rfile" '
    function emit(   line) {
      while ((getline line < rfile) > 0) print line
      close(rfile)
    }
    NR == 1 { print; in_block = 1; next }
    in_block && $0 == "---" {
      if (!done) emit()
      print; in_block = 0; done = 1; next
    }
    in_block && skipping {
      if ($0 ~ /^  - /) next
      skipping = 0
    }
    in_block && index($0, key ":") == 1 {
      emit(); done = 1; skipping = 1; next
    }
    { print }
  ' "$file" | _fm_replace "$file"
  rc=$?
  rm -f "$rfile"
  return "$rc"
}

# fm_list_add <file> <key> <item> — append an item unless it is already
# present. Returns 1 (nothing written) when the list already holds it.
fm_list_add() {
  local file="$1" key="$2" item="$3" current
  current=$(fm_list "$file" "$key" | sed '/^$/d')
  case $'\n'"$current"$'\n' in *$'\n'"$item"$'\n'*) return 1 ;; esac
  { printf '%s\n' "$current" | sed '/^$/d'; printf '%s\n' "$item"; } \
    | fm_list_set "$file" "$key"
}

# fm_list_remove <file> <key> <item> — drop an item. Returns 1 (nothing
# written) when the list does not hold it.
fm_list_remove() {
  local file="$1" key="$2" item="$3" current remaining
  current=$(fm_list "$file" "$key" | sed '/^$/d')
  case $'\n'"$current"$'\n' in *$'\n'"$item"$'\n'*) ;; *) return 1 ;; esac
  # `|| true`: removing the last item leaves grep with nothing to select, and
  # its exit 1 would otherwise become the function's status under `pipefail`
  # — reporting "nothing removed" for a removal that did happen.
  remaining=$(printf '%s\n' "$current" | grep -vxF -- "$item" || true)
  printf '%s\n' "$remaining" | fm_list_set "$file" "$key"
}

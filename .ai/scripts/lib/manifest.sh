# Reader/writer for .ai/manifest (domains/install, ADR-0003). Sourced by
# scripts/lib/init.sh, scripts/lib/upgrade.sh and scripts/lib/status.sh.
# Assumes JIG_PROJECT and JIG_AI_DIR are already set (jig_require_repo).
# shellcheck shell=bash

# manifest_file
# Absolute path of the manifest for the current project.
manifest_file() {
  printf '%s/%s/manifest\n' "$JIG_PROJECT" "$JIG_AI_DIR"
}

# manifest_exists
manifest_exists() {
  [ -f "$(manifest_file)" ]
}

# manifest_header_get <key>
# Prints the value of a `key: value` header line (the lines above the `---`
# separator), or nothing when absent.
manifest_header_get() {
  local key="$1" file line
  file=$(manifest_file)
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    [ "$line" = "---" ] && break
    case "$line" in
      "$key":*)
        line="${line#*:}"
        # strip at most one leading space, matching the writer's "key: value"
        case "$line" in " "*) line="${line# }" ;; esac
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done < "$file"
}

# manifest_paths
# Prints every path tracked in the manifest body, one per line.
manifest_paths() {
  local file line in_body=0
  file=$(manifest_file)
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    if [ "$in_body" = 1 ]; then
      [ -n "$line" ] && printf '%s\n' "${line#* }"
    elif [ "$line" = "---" ]; then
      in_body=1
    fi
  done < "$file"
}

# manifest_entries
# Prints every body line of the manifest, "<hash> <path>", in one pass. Use it
# instead of calling manifest_hash_of in a loop: that rereads the whole file
# for every path, which is quadratic in the size of the install.
manifest_entries() {
  local file
  file=$(manifest_file)
  [ -f "$file" ] || return 0
  awk 'body { if ($0 != "") print; next } $0 == "---" { body = 1 }' "$file"
}

# manifest_hash_of <path>
# Prints the manifest hash recorded for <path> (relative to JIG_PROJECT), or
# nothing when the path is not tracked.
manifest_hash_of() {
  local target="$1" file line in_body=0 hash path
  file=$(manifest_file)
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    if [ "$in_body" = 1 ]; then
      [ -z "$line" ] && continue
      hash="${line%% *}"
      path="${line#* }"
      if [ "$path" = "$target" ]; then
        printf '%s\n' "$hash"
        return 0
      fi
    elif [ "$line" = "---" ]; then
      in_body=1
    fi
  done < "$file"
}

# manifest_write_entries <version> <source> <adapters> <mode> [<instructions-section>]
# Internal primitive: reads already-computed "<hash> <path>" lines from
# stdin and writes the whole manifest atomically (temp file + mv). Used by
# manifest_write below and directly by upgrade, which must preserve the
# existing hash of locally modified files instead of recomputing it.
#
# <instructions-section> is the optional `instructions.section` header value,
# "<hash> <path>": the hash of the marked section jig last wrote into the
# project's instructions file, and the file it wrote it into. Omitted or
# empty, the key is not written and jig claims ownership of no section.
#
# A header key, not a body entry, because the body is whole-file ownership
# keyed by path: every reader splits an entry on its first space, so there is
# no room for a third column, and a pseudo-path such as `AGENTS.md#jig` would
# enter manifest_paths and then be hashed, walked and reported as a missing
# file by readers that have every right to assume a path is a path. The
# header is where facts about the install already live — version, source,
# mode, adapters — and an unknown key there is invisible to every existing
# reader, so an older jig meeting a newer manifest reports no phantom drift
# (adr-20260924-jig-owns-a-marked-section-of-the-instructions).
#
# When <source> is the project itself (self-install/dogfooding, typically
# with --link), the absolute path is machine-specific and would break the
# manifest for anyone else who clones the project. Record "." instead;
# manifest_source resolves it back to JIG_PROJECT on read. Compared through
# `pwd -P` (physical paths) rather than as raw strings: JIG_PROJECT comes
# from `git rev-parse --show-toplevel`, which resolves symlinks, while
# <source> may not have been (e.g. a TMPDIR under a symlinked /var on
# macOS) even though both name the same directory.
manifest_write_entries() {
  local version="$1" source="$2" adapters="$3" mode="$4" section="${5:-}" file tmp
  local source_real project_real
  source_real=$(cd "$source" 2>/dev/null && pwd -P) || source_real="$source"
  project_real=$(cd "$JIG_PROJECT" 2>/dev/null && pwd -P) || project_real="$JIG_PROJECT"
  [ "$source_real" = "$project_real" ] && source="."
  file=$(manifest_file)
  tmp="$file.tmp.$$"
  mkdir -p "$(dirname "$file")"
  {
    # shellcheck disable=SC2016
    printf '# jig manifest. Do not edit by hand; maintained by `jig init` and `jig upgrade`.\n'
    printf 'jig.version: %s\n' "$version"
    printf 'jig.source: %s\n' "$source"
    printf 'jig.mode: %s\n' "$mode"
    printf 'installed_at: %s\n' "$(jig_today)"
    printf 'adapters: [%s]\n' "$adapters"
    if [ -n "$section" ]; then
      printf 'instructions.section: %s\n' "$section"
    fi
    printf -- '---\n'
    sort -k2,2
  } > "$tmp"
  mv "$tmp" "$file"
}

# manifest_source
# Prints the manifest's jig.source header, resolving "." (written when the
# project installed itself as its own source) back to JIG_PROJECT.
manifest_source() {
  local src
  src=$(manifest_header_get jig.source)
  if [ "$src" = "." ]; then
    printf '%s\n' "$JIG_PROJECT"
  else
    printf '%s\n' "$src"
  fi
}

# manifest_instructions_section
# Prints the recorded `instructions.section` header value, "<hash> <path>",
# or nothing when jig has never written a marked section into this project.
# Its absence is what tells init and upgrade that no section is theirs to
# replace — the difference between "we wrote this and may update it" and
# "somebody else's text that happens to sit between markers".
manifest_instructions_section() {
  manifest_header_get instructions.section
}

# manifest_write <version> <source> <adapters> <mode> [path...]
# Computes the hash of each given path (relative to JIG_PROJECT, hashed as it
# stands on disk right now) and writes the whole manifest atomically. Mode
# "link" is normally called with no paths (header only, no hash lines).
manifest_write() {
  local version="$1" source="$2" adapters="$3" mode="$4"
  shift 4
  local path
  {
    for path in "$@"; do
      printf '%s %s\n' "$(jig_hash "$JIG_PROJECT/$path")" "$path"
    done
  } | manifest_write_entries "$version" "$source" "$adapters" "$mode"
}

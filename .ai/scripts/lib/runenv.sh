# Where a project's checks run (adr-20261001-checks-run-where-the-project-runs;
# domains/verify). Sourced by verify.sh; defines runenv_resolve.
#
# `jig verify` decides once, before any profile starts, whether the project's
# commands run on this machine or through a command prefix that reaches the
# environment the project actually lives in (`docker compose exec -T -w <dir>
# <service>`). The answer comes from one local-only key, `run.exec`:
#
#   auto      (default) the detectors below; no detector and no sign that the
#             project lives in a container means the host
#   host      this machine, signs not consulted
#   <prefix>  plain words put in front of every command a profile runs
#
# A host runtime that is not first on PATH (Laravel Herd) needs no prefix but
# another PATH, which a prefix of plain words cannot carry when the directory
# holds a blank. A second local-only key answers it, `run.path`: `auto`
# (default; the Herd detector's answer, nothing otherwise) or a directory put
# first on PATH whenever the checks run on this machine.
#
# A sign without a detector is a refusal, never a quiet run on the host: a
# Laravel app on Sail whose `.env` says DB_HOST=mysql gave a wrong verdict
# from the host's PHP against a database that does not resolve there.
#
# With CI set, `auto` neither detects nor refuses: CI describes its own
# environment, and a project's existing pipeline must not change under it.
# bash 3.2 compatible.
# shellcheck shell=bash

RUNENV_EXEC=""
RUNENV_WHERE=""
RUNENV_UP=""
RUNENV_REFUSAL=""
RUNENV_PATH=""
_RUNENV_HERD=1

# _runenv_compose_file — the project's compose file, relative to JIG_PROJECT,
# in the order docker compose itself looks for one; nothing when there is none.
_runenv_compose_file() {
  local f
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [ -f "$JIG_PROJECT/$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 0
}

# _runenv_compose_read <file> — what the detectors need from a compose file:
# `S<TAB><service>` for every top-level service, `M<TAB><service><TAB>
# <target>` for every short-syntax volume that mounts the project root
# (`.:/x`, `./:/x`, quoted or not, with or without a mode), and
# `U<TAB><service>` for a volume that seems to mount it in a form this reader
# does not take apart — the long syntax (`source: .`), `$PWD`, or a flow list.
# A reader of the subset compose files are written in, not a YAML parser: what
# it cannot read becomes a sign rather than a detection, the cautious side.
# Line ends are CRLF-tolerant: a Windows checkout of the file reads the same.
_runenv_compose_read() {
  awk -v q="'" '
    function strip(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function unquote(s) {
      s = strip(s)
      if (s ~ ("^[\"" q "]")) s = substr(s, 2)
      if (s ~ ("[\"" q "]$")) s = substr(s, 1, length(s) - 1)
      return s
    }
    { sub(/\r$/, "") }
    /^[ \t]*(#|$)/ { next }
    {
      match($0, /^ */); ind = RLENGTH
      line = substr($0, ind + 1)
      if (ind == 0) {
        insvc = (line ~ /^services:[ \t]*(#.*)?$/); svcind = -1; svc = ""; keyind = -1; invol = 0
        next
      }
      if (!insvc) next
      if (svcind < 0) svcind = ind
      if (ind < svcind) next
      if (ind == svcind) {
        svc = line; sub(/:.*$/, "", svc); svc = unquote(svc)
        print "S\t" svc
        keyind = -1; invol = 0
        next
      }
      if (keyind < 0) keyind = ind
      if (ind == keyind && line !~ /^- /) {
        invol = (line ~ /^volumes:/)
        if (invol && line ~ /^volumes:[ \t]*\[/ && line ~ /(["\[, ]\.\/?:|PWD)/) print "U\t" svc
        next
      }
      if (ind < keyind || !invol) next
      if (line ~ /^- /) {
        v = unquote(substr(line, 3))
        n = split(v, p, ":")
        if ((p[1] == "." || p[1] == "./") && n >= 2 && p[2] != "") { print "M\t" svc "\t" p[2]; next }
        if (p[1] ~ /PWD/) { print "U\t" svc; next }
        line = v
      }
      sub(/^- /, "", line)
      if (line ~ /^source:/) {
        v = line; sub(/^source:/, "", v); v = unquote(v)
        if (v == "." || v == "./" || v ~ /PWD/) print "U\t" svc
      }
    }
  ' "$1"
}

# _runenv_dotenv <key> — the value of <key> in the project's .env, quotes
# stripped; the last assignment wins, as in a shell. Nothing when unset.
_runenv_dotenv() {
  [ -f "$JIG_PROJECT/.env" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$JIG_PROJECT/.env" \
    | sed -n '$p' | tr -d '\r' | sed "s/^[\"']//; s/[\"']\$//"
}

# _runenv_inside — exit 0 when this very process already runs in a project
# environment: the tool that owns it sets a marker in every shell it opens
# (a devcontainer, a Codespace, DDEV's web container, a Lando service). The
# project's commands then run here, and a prefix that goes looking for the
# container from inside it would find nothing.
_runenv_inside() {
  [ "${REMOTE_CONTAINERS:-}" = true ] || [ "${CODESPACES:-}" = true ] \
    || [ "${IS_DDEV_PROJECT:-}" = true ] || [ "${LANDO:-}" = ON ]
}

# _runenv_container <label> — a running container that carries <label> and
# mounts the project root: prints `<name><TAB><mount target>`, nothing when
# there is none (or docker does not answer). Looking at the mounts, not at
# names, keeps this independent of how a tool names its containers.
_runenv_container() {
  local id here real
  here=$JIG_PROJECT
  real=$(cd "$JIG_PROJECT" 2>/dev/null && pwd -P) || real=$here
  local ids
  ids=$(docker ps -q --filter "label=$1" 2>/dev/null) || ids=""
  # The devcontainer label holds the folder as the tooling spelt it, which
  # may be the real path of a symlinked one.
  case "$1" in
    devcontainer.local_folder=*)
      [ "$real" = "$here" ] || ids="$ids $(docker ps -q --filter "label=devcontainer.local_folder=$real" 2>/dev/null)"
      ;;
  esac
  for id in $ids; do
    docker inspect -f '{{.Name}}{{"\n"}}{{range .Mounts}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}' "$id" 2>/dev/null \
      | RUNENV_A="$here" RUNENV_B="$real" awk -F '\t' '
          NR == 1 { n = $1; sub(/^\//, "", n); next }
          ($1 == ENVIRON["RUNENV_A"] || $1 == ENVIRON["RUNENV_B"]) && $2 != "" { print n "\t" $2; exit }'
  done | sed -n '1p'
}

# _runenv_container_env <what> <label> <up> — shared by the detectors that
# reach a container through `docker exec`: sets the prefix from the container
# found by <label>; when there is none the environment is not running, which
# is a refusal that carries <up>, the command that starts it.
_runenv_container_env() {
  local found name target
  found=$(_runenv_container "$2")
  if [ -n "$found" ]; then
    name=$(printf '%s\n' "$found" | cut -f1)
    target=$(printf '%s\n' "$found" | cut -f2)
    RUNENV_EXEC="docker exec -i -w $target $name"
    RUNENV_WHERE="$RUNENV_EXEC ($1, detected)"
    RUNENV_UP="$3"
  else
    RUNENV_WHERE="$1, detected"
    RUNENV_REFUSAL="the environment is not running ($1: no running container mounts the project); start it with: $3"
  fi
}

# _runenv_detect — set RUNENV_EXEC, RUNENV_WHERE and RUNENV_UP from the first
# detector that recognises the project; exit 1 when none does. A detector that
# recognises the project but finds its environment stopped sets RUNENV_REFUSAL
# instead of a prefix, and still counts as a match. Order: Laravel Sail, DDEV,
# Lando, a devcontainer, then a docker compose service that mounts the project
# root — the tools with a manifest of their own before the generic reading of
# a compose file, which a devcontainer or Lando project may well contain.
_runenv_detect() {
  local file data svc target mounts unread n
  file=$(_runenv_compose_file)
  if [ -n "$file" ]; then
    data=$(_runenv_compose_read "$JIG_PROJECT/$file")
    mounts=$(printf '%s\n' "$data" | sed -n 's/^M	//p')
    unread=$(printf '%s\n' "$data" | sed -n 's/^U	//p')
  else
    mounts=""
    unread=""
  fi

  # Sail: its own launcher is installed and the service it runs commands in
  # (APP_SERVICE, laravel.test unless .env names another) mounts the project.
  # Sail runs them as its `sail` user; root would leave root-owned files in
  # the mounted tree.
  if [ -n "$mounts" ] && [ -f "$JIG_PROJECT/vendor/bin/sail" ]; then
    svc=$(_runenv_dotenv APP_SERVICE)
    [ -n "$svc" ] || svc=laravel.test
    target=$(printf '%s\n' "$mounts" | awk -F '\t' -v s="$svc" '$1 == s && !f { print $2; f = 1 }')
    if [ -n "$target" ]; then
      RUNENV_EXEC="docker compose exec -T -u sail -w $target $svc"
      RUNENV_WHERE="$RUNENV_EXEC (Laravel Sail, detected)"
      RUNENV_UP="./vendor/bin/sail up -d"
      return 0
    fi
  fi

  # DDEV: `ddev exec` runs in the web container at the directory that matches
  # the one it is run from. --raw hands the words over as they are: without
  # it DDEV joins them and has bash read the result, which loses quoting.
  if [ -f "$JIG_PROJECT/.ddev/config.yaml" ]; then
    RUNENV_EXEC="ddev exec --raw"
    RUNENV_WHERE="$RUNENV_EXEC (DDEV, detected)"
    RUNENV_UP="ddev start"
    return 0
  fi

  # Lando: `lando ssh -c` takes the command as one string, which a prefix of
  # plain words cannot build, so the service's container is reached directly:
  # Lando labels every container it starts.
  if [ -f "$JIG_PROJECT/.lando.yml" ]; then
    _runenv_container_env "Lando" "io.lando.container=TRUE" "lando start"
    return 0
  fi

  # A devcontainer: the CLI when it is installed (it finds the container by
  # the project folder, and `up` can start it); otherwise the container the
  # tooling labelled with that folder. A folder holding a devcontainer.json
  # is the only form read; other layouts stay a sign for the refusal.
  if [ -f "$JIG_PROJECT/.devcontainer/devcontainer.json" ] || [ -f "$JIG_PROJECT/.devcontainer.json" ]; then
    if command -v devcontainer >/dev/null 2>&1; then
      RUNENV_EXEC="devcontainer exec --workspace-folder ."
      RUNENV_WHERE="$RUNENV_EXEC (devcontainer, detected)"
      RUNENV_UP="devcontainer up --workspace-folder ."
    else
      _runenv_container_env "devcontainer" "devcontainer.local_folder=$JIG_PROJECT" "devcontainer up --workspace-folder . (or reopen the folder in the container from your editor)"
    fi
    return 0
  fi

  # One service, read in full: a second one, or a mount of the project this
  # reader could not take apart, leaves the choice to a person.
  [ -z "$unread" ] || return 1
  if [ -n "$mounts" ]; then
    n=$(printf '%s\n' "$mounts" | cut -f1 | sort -u | grep -c .)
    [ "$n" -eq 1 ] || return 1
    mounts=$(printf '%s\n' "$mounts" | sed -n '1p')
    svc=$(printf '%s\n' "$mounts" | cut -f1)
    target=$(printf '%s\n' "$mounts" | cut -f2)
    RUNENV_EXEC="docker compose exec -T -w $target $svc"
    RUNENV_WHERE="$RUNENV_EXEC (docker compose service $svc, detected)"
    RUNENV_UP="docker compose up -d"
    return 0
  fi

  # Nothing in the project names its environment from here on: a stack that
  # lives elsewhere on the machine and serves this folder. A compose file
  # that mounts the project, even ambiguously, is closer evidence and has
  # been answered above; so is any other sign in the project, which keeps
  # its refusal rather than lose it to a stack found on the machine.
  [ -z "$(_runenv_signs)" ] || return 1
  if _runenv_devilbox; then
    return 0
  fi
  _runenv_herd
}

# _runenv_devilbox — Devilbox serves every project under one data directory
# that lives outside the project (HOST_PATH_HTTPD_DATADIR, often customised),
# so nothing in the project names it. Its PHP container does: the compose
# service `php`, with the data directory bind-mounted at /shared/httpd. A
# container like that whose mount source is the project root or an ancestor
# of it is where the project runs, at the same relative path under
# /shared/httpd, as Devilbox's own user (MY_USER in the image, `devilbox`
# otherwise). Stopped containers count too (`ps -a`): one found only stopped
# is a refusal with its start command, not a quiet run on the host. So is a
# container that mounts only the main checkout of this worktree: its verdict
# would be about other code. Exit 1 when there is no such container, or no
# docker.
#
# Not "any container that mounts an ancestor of the project": a container
# that mounts $HOME would take every project's checks
# (adr-20261001-checks-run-where-the-project-runs).
_runenv_devilbox() {
  local ids id here real main="" found state name user rel wd dir
  command -v docker >/dev/null 2>&1 || return 1
  ids=$(docker ps -aq --filter label=com.docker.compose.service=php 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  here=$JIG_PROJECT
  real=$(cd "$JIG_PROJECT" 2>/dev/null && pwd -P) || real=$here
  if type jig_config_clone_root >/dev/null 2>&1; then
    main=$(cd "$(jig_config_clone_root)" 2>/dev/null && pwd -P) || main=""
    [ "$main" != "$real" ] || main=""
  fi
  # Docker Desktop reports a bind source under the path of its VM:
  # /host_mnt/Users/... on macOS, /run/desktop/mnt/host/c/... on Windows,
  # which is the path Git Bash spells /c/....
  found=$(
    for id in $ids; do
      docker inspect -f '{{.Name}}{{"\t"}}{{.State.Running}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project.working_dir"}}{{"\n"}}{{range .Mounts}}M{{"\t"}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}{{range .Config.Env}}E{{"\t"}}{{.}}{{"\n"}}{{end}}' "$id" 2>/dev/null \
        | tr -d '\r' | RUNENV_A="$here" RUNENV_B="$real" RUNENV_C="$main" awk -F '\t' '
            BEGIN { a = ENVIRON["RUNENV_A"]; b = ENVIRON["RUNENV_B"]; c = ENVIRON["RUNENV_C"] }
            NR == 1 { name = $1; sub(/^\//, "", name); run = $2; wd = $3; next }
            $1 == "E" && $2 ~ /^MY_USER=/ { u = $2; sub(/^MY_USER=/, "", u) }
            $1 == "M" && $3 == "/shared/httpd" { src = $2 }
            END {
              if (src == "") exit
              sub(/^\/host_mnt\//, "/", src)
              sub(/^\/run\/desktop\/mnt\/host\//, "/", src)
              if (src != "/") sub(/\/+$/, "", src)
              rel = ""
              if (a == src || b == src) rel = "."
              else if (index(a, src "/") == 1) rel = substr(a, length(src) + 2)
              else if (index(b, src "/") == 1) rel = substr(b, length(src) + 2)
              else if (c != "" && (c == src || index(c, src "/") == 1)) rel = "!"
              if (rel == "") exit
              if (u == "") u = "devilbox"
              state = (run == "true" ? 0 : 1)
              if (rel == "!") state = 2
              print state "\t" name "\t" u "\t" rel "\t" wd
            }'
    done | sort | sed -n '1p'
  )
  [ -n "$found" ] || return 1
  state=$(printf '%s\n' "$found" | cut -f1)
  name=$(printf '%s\n' "$found" | cut -f2)
  user=$(printf '%s\n' "$found" | cut -f3)
  rel=$(printf '%s\n' "$found" | cut -f4)
  wd=$(printf '%s\n' "$found" | cut -f5)
  dir=/shared/httpd
  [ "$rel" = . ] || dir="/shared/httpd/$rel"
  if [ -n "$wd" ]; then
    RUNENV_UP="cd $(_runenv_unix_path "$wd") && docker compose up -d"
  else
    RUNENV_UP="docker start $name"
  fi
  RUNENV_WHERE="Devilbox, detected"
  if [ "$state" = 2 ]; then
    RUNENV_REFUSAL="the environment does not see this checkout (Devilbox, detected): its PHP container $name mounts the main checkout's folder but not this worktree's, so its verdict would be about other code; put the worktree under Devilbox's data folder (git.worktree_root), or run jig verify in the main checkout"
    return 0
  fi
  case "$dir" in
    *[[:space:]]*)
      RUNENV_REFUSAL="the project's folder inside Devilbox ($dir) holds a blank, which a command prefix of plain words cannot reach; rename the folder, or set run.exec host to run the checks on this machine"
      return 0
      ;;
  esac
  if [ "$state" != 0 ]; then
    RUNENV_REFUSAL="the environment is not running (Devilbox: its PHP container $name is stopped); start it with: $RUNENV_UP"
    return 0
  fi
  RUNENV_EXEC="docker exec -i -u $user -w $dir $name"
  RUNENV_WHERE="$RUNENV_EXEC (Devilbox, detected)"
  return 0
}

# _runenv_unix_path <path> — <path> as this shell spells it: a Windows path
# (`C:\Users\x`) through cygpath when there is one, anything else unchanged.
_runenv_unix_path() {
  case "$1" in
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$1"
}

# _runenv_herd — Laravel Herd: the PHP of this machine, served from Herd's
# own bin directory, which need not be first on PATH (Homebrew's PHP, or a
# shell that never read the profile Herd edited). Recognised when Herd is
# installed — its home on macOS or on Windows, holding bin/php — and the
# project is one of its sites: a direct child of a directory Herd serves
# (`paths` in its Valet config: the parked folders and the Sites folder of
# links), or the target of a link there. A worktree answers for its main
# checkout: same project, same PHP. Sets RUNENV_PATH, no prefix; exit 1
# otherwise, and always while run.path names a directory of its own.
_runenv_herd() {
  local home bin conf roots root rreal p preal entry
  [ "$_RUNENV_HERD" = 1 ] || return 1
  for home in "$HOME/Library/Application Support/Herd" "$HOME/.config/herd"; do
    bin="$home/bin"
    conf="$home/config/valet/config.json"
    [ -e "$bin/php" ] || [ -e "$bin/php.exe" ] || [ -e "$bin/php.bat" ] || continue
    [ -f "$conf" ] || continue
    roots=$JIG_PROJECT
    if type jig_config_clone_root >/dev/null 2>&1; then
      roots="$roots
$(jig_config_clone_root)"
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      p=$(_runenv_unix_path "$p")
      preal=$(cd "$p" 2>/dev/null && pwd -P) || continue
      while IFS= read -r root; do
        [ -n "$root" ] || continue
        rreal=$(cd "$root" 2>/dev/null && pwd -P) || continue
        if [ "$(dirname "$rreal")" = "$preal" ]; then
          _runenv_herd_found "$bin"
          return 0
        fi
        for entry in "$p"/*; do
          [ -L "$entry" ] || continue
          if [ "$(cd "$entry" 2>/dev/null && pwd -P)" = "$rreal" ]; then
            _runenv_herd_found "$bin"
            return 0
          fi
        done
      done <<EOF
$roots
EOF
    done <<EOF
$(_runenv_herd_paths "$conf")
EOF
  done
  return 1
}

# _runenv_herd_paths <config.json> — the directories in its `paths` array,
# one per line, JSON escapes of `/` and `\` undone. A reader of the one
# array Valet writes, not a JSON parser.
_runenv_herd_paths() {
  tr -d '\r\n' < "$1" \
    | sed -n 's/.*"paths"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//; s#\\/#/#g; s#\\\\#\\#g'
}

_runenv_herd_found() {
  RUNENV_PATH=$1
  RUNENV_WHERE="host, with $1 first on PATH (Laravel Herd, detected)"
}

# _runenv_signs — the reasons to believe the project lives in a container that
# no detector recognised, joined with "; "; nothing when there are none. A
# compose file alone is not one: a database in a container beside an app on
# the host is an ordinary setup that runs its checks on the host today.
_runenv_signs() {
  local file data services mounts unread n db signs=""
  file=$(_runenv_compose_file)
  if [ -n "$file" ]; then
    data=$(_runenv_compose_read "$JIG_PROJECT/$file")
    services=$(printf '%s\n' "$data" | sed -n 's/^S	//p')
    mounts=$(printf '%s\n' "$data" | sed -n 's/^M	//p' | cut -f1 | sort -u)
    unread=$(printf '%s\n' "$data" | sed -n 's/^U	//p' | sort -u)
    n=$(printf '%s\n' "$mounts" | grep -c . || true)
    if [ "$n" -gt 1 ]; then
      signs="$signs; $n services in $file mount the project ($(printf '%s\n' "$mounts" | paste -sd, -))"
    fi
    if [ -n "$unread" ]; then
      signs="$signs; $(printf '%s\n' "$unread" | paste -sd, -) in $file mounts the project in a form jig does not read (long syntax, \$PWD or a flow list)"
    fi
    db=$(_runenv_dotenv DB_HOST)
    if [ -n "$db" ] && jig_has_line "$db" "$services"; then
      signs="$signs; .env sets DB_HOST=$db, a service in $file"
    fi
  fi
  # The three below are recognised when they carry their manifest; what is
  # left here is a folder without one, which no detector reads.
  if [ -d "$JIG_PROJECT/.devcontainer" ] || [ -f "$JIG_PROJECT/.devcontainer.json" ]; then
    signs="$signs; a devcontainer is defined"
  fi
  [ ! -d "$JIG_PROJECT/.ddev" ] || signs="$signs; a DDEV project (.ddev/)"
  printf '%s\n' "${signs#; }"
}

# _runenv_probe — exit 0 when the environment answers and shows this
# checkout; otherwise set RUNENV_REFUSAL and exit 1. One command for both
# questions: it fails when the container is not running or docker is not
# there, and its output is the environment's own `.git`. In a linked
# worktree `.git` is a file naming this worktree, so an environment that
# mounted the main checkout instead would show different text — and its
# verdict would be about other code. A main checkout is not compared: a
# container need not mount `.git` at all.
_runenv_probe() {
  local err out rc=0 mine last
  local -a pre
  read -r -a pre <<EOF
$RUNENV_EXEC
EOF
  # Without a file for its error output the probe still runs, and only the
  # refusal loses the environment's own words.
  if err=$(mktemp "${TMPDIR:-/tmp}/jig-runenv.XXXXXX"); then
    jig_cleanup_add "$err"
  else
    err=/dev/null
  fi
  out=$( cd "$JIG_PROJECT" && "${pre[@]}" sh -c 'cat .git 2>/dev/null; exit 0' </dev/null 2>"$err" ) || rc=$?
  last=""
  if [ "$err" != /dev/null ]; then
    last=$(sed '/^[[:space:]]*$/d' "$err" | sed -n '$p')
    rm -f "$err"
  fi
  if [ "$rc" -ne 0 ]; then
    RUNENV_REFUSAL="the environment is not running ($RUNENV_WHERE)${last:+: $last}"
    if [ -n "$RUNENV_UP" ]; then
      RUNENV_REFUSAL="$RUNENV_REFUSAL; start it with: $RUNENV_UP"
    else
      RUNENV_REFUSAL="$RUNENV_REFUSAL; start it, then run jig verify again"
    fi
    return 1
  fi
  if [ -f "$JIG_PROJECT/.git" ]; then
    mine=$(tr -d '\r' < "$JIG_PROJECT/.git")
    out=$(printf '%s\n' "$out" | tr -d '\r')
    if [ "$out" != "$mine" ]; then
      RUNENV_REFUSAL="the environment does not see this checkout ($RUNENV_WHERE): it mounts another copy of the project, so its verdict would be about other code; give this worktree an environment of its own, or run jig verify in the checkout the environment mounts"
      return 1
    fi
  fi
  return 0
}

# runenv_resolve — decide where the project's checks run. Sets RUNENV_EXEC
# (empty for the host), RUNENV_PATH (a directory to put first on PATH, for
# the host only), RUNENV_WHERE (what to tell a person), RUNENV_UP (how to
# start the environment, when known) and RUNENV_REFUSAL (non-empty: do not
# run anything, and say this). Needs cfg (config.sh) and JIG_PROJECT.
runenv_resolve() {
  local path
  RUNENV_PATH=""
  path=$(cfg run.path auto)
  _RUNENV_HERD=0
  [ "$path" != auto ] || _RUNENV_HERD=1
  _runenv_place
  [ -z "$RUNENV_REFUSAL" ] || return 0
  [ -z "$RUNENV_EXEC" ] || return 0
  [ "$path" != auto ] || return 0
  path=$(_runenv_unix_path "$path")
  case "$path" in
    /*) ;;
    *)
      RUNENV_REFUSAL="run.path is $path, not an absolute path; set the full path of the folder with jig config set run.path '<dir>' --local"
      return 0
      ;;
  esac
  if [ ! -d "$path" ]; then
    RUNENV_REFUSAL="run.path names $path, which is not a directory on this machine; fix it with jig config set run.path '<dir>' --local, or remove it with jig config unset run.path --local"
    return 0
  fi
  # shellcheck disable=SC2034  # read by verify.sh
  RUNENV_PATH=$path
  RUNENV_WHERE="$RUNENV_WHERE, with $path first on PATH (run.path)"
  return 0
}

# _runenv_place — runenv_resolve without run.path: the host, a prefix, or a
# refusal, from run.exec and the detectors.
_runenv_place() {
  local value signs
  RUNENV_EXEC=""
  RUNENV_WHERE="host"
  RUNENV_UP=""
  RUNENV_REFUSAL=""
  value=$(cfg run.exec auto)
  case "$value" in
    host)
      RUNENV_WHERE="host (run.exec: host)"
      return 0
      ;;
    auto)
      if [ -n "${CI:-}" ]; then
        RUNENV_WHERE="host (CI is set)"
        return 0
      fi
      if _runenv_inside; then
        RUNENV_WHERE="host (this shell is already inside the project's environment)"
        return 0
      fi
      if ! _runenv_detect; then
        signs=$(_runenv_signs)
        if [ -n "$signs" ]; then
          RUNENV_REFUSAL="this project looks like it runs in a container ($signs), and jig does not know how to run its checks there — run the jig-setup skill, or set the command prefix yourself: jig config set run.exec '<prefix>' --local (run.exec host runs them on this machine)"
        fi
        return 0
      fi
      [ -z "$RUNENV_REFUSAL" ] || return 0
      # A detector that answers with a PATH (Herd) leaves nothing to probe.
      [ -n "$RUNENV_EXEC" ] || return 0
      ;;
    *)
      RUNENV_EXEC="$value"
      RUNENV_WHERE="$value (run.exec)"
      ;;
  esac
  _runenv_probe || true
  return 0
}

# Sourced by tests/e2e.sh: the work directory, the isolated tmux and Helix,
# and the checks. Not run on its own.

need() {
  command -v "$1" >/dev/null || {
    echo "e2e: '$1' is not on PATH" >&2
    exit 1
  }
}
need hx
need tmux
need sqlite3
HX=$(command -v hx)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dadbod-e2e.XXXXXX")
# tmux, PostgreSQL and MariaDB put unix sockets in it, and a socket's path is
# limited to about 100 bytes.
if ((${#WORK} > 60)); then
  rmdir "$WORK"
  echo "e2e: the temporary directory's path is too long for unix sockets: $WORK" >&2
  echo "e2e: run it with a shorter TMPDIR, like TMPDIR=/tmp" >&2
  exit 1
fi
mkdir -p "$WORK/home" "$WORK/run"
chmod 700 "$WORK/run"

# Helix sees none of your configuration: a scratch HOME, and none of the
# variables that would point it, Steel or a database client somewhere else.
CLEAN_ENV="-u DATABASE_URL -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME"
CLEAN_ENV+=" -u STEEL_HOME -u STEEL_SEARCH_PATHS -u HELIX_RUNTIME"
CLEAN_ENV+=" -u PGHOST -u PGPORT -u PGUSER -u PGPASSWORD -u PGDATABASE -u PGSERVICE -u PGPASSFILE"
CLEAN_ENV+=" -u MYSQL_PWD -u MYSQL_HOST -u MYSQL_TCP_PORT"

mysql_pid=

# The tmux server Helix runs in. Each start of Helix gets a server on a
# socket of its own (hx_run): starting one on the socket of a server that was
# just told to exit races with its exit.
tmux_servers=0
tmux_socket="$WORK/tmux-0.sock"

tm() {
  HOME="$WORK/home" tmux -f /dev/null -S "$tmux_socket" "$@"
}

cleanup() {
  tm kill-server 2>/dev/null || true
  if [[ -d $WORK/pg ]]; then
    pg_ctl -D "$WORK/pg" -m immediate stop >/dev/null 2>&1 || true
  fi
  if [[ -n $mysql_pid ]]; then
    kill "$mysql_pid" 2>/dev/null || true
    wait "$mysql_pid" 2>/dev/null || true
  fi
  if [[ -n ${E2E_KEEP:-} ]]; then
    echo "e2e: kept $WORK"
  elif [[ -n $WORK && -d $WORK ]]; then
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

passed=0

screen() {
  tm capture-pane -p
}

# on_screen <text> [grep flag]: the text is a fixed string, or an extended
# regex with -E. The screen is captured first, so that grep stopping at its
# first match can't fail the pipeline.
on_screen() {
  local shot
  shot=$(screen) || return 1
  grep -q "${2:--F}" -- "$1" <<<"$shot"
}

fail() {
  echo "FAIL: $1" >&2
  echo "----- screen -----" >&2
  screen >&2 || true
  echo "------------------" >&2
  exit 1
}

# wait_for <description> <text> [grep flag]: polls the screen for up to 15s.
wait_for() {
  local i
  for i in $(seq 1 75); do
    if on_screen "$2" "${3:--F}"; then
      return 0
    fi
    sleep 0.2
  done
  fail "$1: never saw '$2'"
}

ok() {
  passed=$((passed + 1))
  echo "ok: $1"
}

expect() {
  wait_for "$1" "$2"
  ok "$1"
}

expect_re() {
  wait_for "$1" "$2" -E
  ok "$1"
}

# wait_until <description> <command...>: polls for up to 15s until the
# command succeeds. For what the screen doesn't show, like a server's state.
wait_until() {
  local description=$1 i
  shift
  for i in $(seq 1 75); do
    if "$@"; then
      return 0
    fi
    sleep 0.2
  done
  fail "$description: never happened"
}

# expect_gone <description> <text>: polls for up to 15s until the text is no
# longer on the screen. For what a new result replaces.
expect_gone() {
  local i
  for i in $(seq 1 75); do
    if ! on_screen "$2"; then
      ok "$1"
      return 0
    fi
    sleep 0.2
  done
  fail "$1: '$2' is still there"
}

# refute <description> <text>: the text is not on the screen right now. Only
# after something that shows the screen is up to date.
refute() {
  if on_screen "$2"; then
    fail "$1: saw '$2'"
  fi
  ok "$1"
}

keys() {
  tm send-keys "$@"
}

# Waits until Helix is in normal mode: only the focused window's status line
# shows the mode.
#
# Never send Escape followed by another key after a fixed pause: when Helix
# is busy both arrive together, and a terminal reads "Escape :" as Alt-:.
# Send Escape, then wait for what it does.
normal_mode() {
  wait_for "normal mode" " NOR "
}

leave_insert_mode() {
  keys Escape
  normal_mode
}

# A typed command, from normal mode.
cmd() {
  normal_mode
  keys -l ":$1"
  keys Enter
}

# open <file>: opens a file in the running Helix and waits until it is the
# focused buffer.
open() {
  local name
  name=$(basename "$1")
  cmd "open $1"
  wait_for "open $name" "NOR .*${name//./\\.}" -E
}

# hx_run <working directory> <steel config directory> <file>
#   HX_RUNTIME  `env` arguments deciding where the plugin keeps its files
#   HX_ENV      more variables for Helix
hx_run() {
  local runtime=${HX_RUNTIME:-"XDG_RUNTIME_DIR='$WORK/run'"}
  tm kill-server 2>/dev/null || true
  tmux_servers=$((tmux_servers + 1))
  tmux_socket="$WORK/tmux-$tmux_servers.sock"
  tm new-session -d -x 150 -y 40 -c "$1" \
    "env $CLEAN_ENV $runtime HELIX_STEEL_CONFIG='$2' ${HX_ENV:-} '$HX' '$3'; echo \"hx exited: \$?\"; sleep 600" ||
    {
      echo "FAIL: could not start tmux for Helix" >&2
      exit 1
    }
  wait_for "helix starts" "$(basename "$3")"
  if on_screen "error["; then
    fail "the plugin failed to load"
  fi
}

# Starts Helix on a file, with the plugin loaded from this checkout the way
# a developer gets it (.helix/init.scm).
hx_start() {
  hx_run "$ROOT" "$ROOT/.helix" "$1"
}

# Starts Helix on a file, with the repository installed as the package
# `dadbod` in Steel's package directory, and an init.scm that requires
# dadbod by its package name, as the README says to, plus a second plugin
# that uses dadbod's API (tests/fixtures/api-consumer).
hx_start_installed() {
  if [[ ! -d $WORK/installed ]]; then
    mkdir -p "$WORK/home/.local/share/steel/cogs" "$WORK/installed"
    ln -s "$ROOT" "$WORK/home/.local/share/steel/cogs/dadbod"
    echo ';; no commands of its own' >"$WORK/installed/helix.scm"
    {
      echo '(require "dadbod/dadbod.scm")'
      echo '(require "dadbod/tests/fixtures/api-consumer/consumer.scm")'
    } >"$WORK/installed/init.scm"
  fi
  hx_run "$WORK" "$WORK/installed" "$1"
}

# expect_only_results <description>: every Helix so far has left nothing in
# its session directory but the result file.
expect_only_results() {
  local file left=""
  for file in "$WORK"/run/dadbod-hx.*/*; do
    [[ -e $file ]] || continue
    [[ $(basename "$file") == result.dbout ]] || left+=" $file"
  done
  [[ -z $left ]] || fail "$1: left behind:$left"
  ok "$1"
}

# The same three statements for every database: the middle one fails.
write_broken_sql() {
  cat >"$1" <<'SQL'
select 'before the error';
select * from no_such_table;
select 'after the error';
SQL
}

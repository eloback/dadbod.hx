#!/usr/bin/env bash
# End-to-end test: drives :db-run in a real Helix against temporary databases.
#
#   tests/e2e.sh            (or `test-e2e` in the devenv shell)
#
# Helix runs in its own tmux server (own socket, no config) with a scratch
# HOME, so nothing of yours is touched. It needs the Steel-enabled `hx`, tmux
# and sqlite3. The PostgreSQL and MariaDB parts run when their server
# binaries are on PATH (they are in the devenv shell) and are skipped
# otherwise.
#
# E2E_KEEP=1 keeps the work directory, to look at what a failed run left.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

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

tm() {
  HOME="$WORK/home" tmux -f /dev/null -S "$WORK/tmux.sock" "$@"
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

refute() {
  if on_screen "$2"; then
    fail "$1: saw '$2'"
  fi
  ok "$1"
}

keys() {
  tm send-keys "$@"
}

# A typed command. Escape first, with a pause: sent together, the terminal
# would read "Escape :" as Alt-:.
cmd() {
  keys Escape
  sleep 0.3
  keys -l ":$1"
  keys Enter
}

# hx_run <working directory> <steel config directory> <file>
hx_run() {
  local runtime=${HX_RUNTIME:-"XDG_RUNTIME_DIR='$WORK/run'"}
  tm kill-server 2>/dev/null || true
  tm new-session -d -x 150 -y 40 -c "$1" \
    "env $CLEAN_ENV $runtime HELIX_STEEL_CONFIG='$2' ${HX_ENV:-} '$HX' '$3'; echo \"hx exited: \$?\"; sleep 600"
  wait_for "helix starts" "$(basename "$3")"
  if on_screen "error["; then
    fail "the plugin failed to load"
  fi
}

# Starts Helix on a file, with the plugin loaded from this checkout.
#   HX_RUNTIME  `env` arguments deciding where the plugin keeps its files
#   HX_ENV      more variables for Helix
hx_start() {
  hx_run "$ROOT" "$ROOT/.helix" "$1"
}

### SQLite

echo "== sqlite"
sqlite3 "$WORK/shop.db" "create table books (id integer primary key, title text);
insert into books (title) values ('Solaris'), ('Kindred');"

cat >"$WORK/two.sql" <<'SQL'
select title from books where id = 1;
select title from books where id = 2;
SQL
cat >"$WORK/broken.sql" <<'SQL'
select 'before the error';
select * from no_such_table;
select 'after the error';
SQL
# 0xE9 is "é" in Latin-1 and invalid in UTF-8.
cat >"$WORK/latin1.sql" <<'SQL'
select cast(x'636166e9' as text) as word;
select 'after the odd bytes';
SQL
: >"$WORK/empty.sql"

hx_start "$WORK/two.sql"

cmd "db-run"
expect "no URL and no \$DATABASE_URL is an error" "db-run: no database: give a URL"

cmd "db-run oracle://host/db"
expect "an unknown scheme is an error" "db-run: no adapter for 'oracle' databases"

cmd "db-run postgres://app:12/34@host/db"
expect "a URL that could be read two ways is an error" "db-run: database URL has an '@' after its host"
refute "and the error doesn't show its password" "34@"

cmd "db-run sqlite:$WORK/shop.db"
expect "the whole buffer runs when nothing is selected" "db-run: done in"
expect "the result names the database, without credentials" "-- sqlite:$WORK/shop.db"
expect "first statement's row" "| Solaris |"
expect "second statement's row" "| Kindred |"
# Only the focused window's status line shows the mode.
expect_re "the focus stays on the query buffer" "NOR .*two\.sql"

# Select the second line only; the URL is remembered.
keys Escape
sleep 0.3
keys g g j x
sleep 0.3
cmd "db-run"
expect "a later run reuses the URL" "db-run: done in"
sleep 0.5
refute "only the selection runs" "| Solaris |"
expect "the selection's row" "| Kindred |"

# The key from the README (.helix/init.scm binds it).
keys Escape
sleep 0.3
keys g g x
sleep 0.3
keys Space
sleep 0.3
keys x
expect "space x runs the selection" "| Solaris |"
sleep 0.5
refute "(and only the selection)" "| Kindred |"
keys j x
sleep 0.3

# The result window was closed, its buffer is still open.
keys C-w o
sleep 0.5
refute "(the result window is closed)" "result.dbout"
cmd "db-run"
expect "the result window comes back" "result.dbout"
expect "with the result" "| Kindred |"

# The result buffer was closed too.
keys C-w j
sleep 0.3
cmd "buffer-close"
sleep 0.5
refute "(the result buffer is closed)" "result.dbout"
cmd "db-run"
expect "the result buffer comes back" "result.dbout"
expect "with the result again" "| Kindred |"

keys C-w j
sleep 0.3
cmd "db-run"
expect "running from the result buffer is refused" "db-run: this is the result buffer"
keys C-w k

cmd "open $WORK/broken.sql"
wait_for "open broken.sql" "no_such_table"
cmd "db-run"
expect "a failing statement is reported" "db-run: the database client exited with code 1"
expect "output before the error is kept" "before the error"
expect "the client's error is shown" "no such table: no_such_table"
refute "nothing runs after the error" "| after the error |"

cmd "open $WORK/latin1.sql"
wait_for "open latin1.sql" "636166e9"
cmd "db-run"
expect "output that is not valid UTF-8 is still a result" "db-run: done in"
expect "with the row that has the odd bytes" "| caf"
expect "and everything after it" "| after the odd bytes "

cmd "open $WORK/empty.sql"
wait_for "open empty.sql" "empty.sql"
cmd "db-run"
expect "a blank buffer is an error" "db-run: nothing to run"

left=$(cd "$WORK/run" && ls dadbod-hx.*/ | sort -u | tr '\n' ' ')
[[ $left == "result.dbout " ]] || fail "temporary files were left behind: $left"
ok "only the result file is left in the session directory"
[[ $(ls -ld "$WORK"/run/dadbod-hx.* | cut -c1-10) == "drwx------" ]] ||
  fail "the session directory is not private"
ok "the session directory is private"

# Without XDG_RUNTIME_DIR the files go to a private directory under TMPDIR.
mkdir -p "$WORK/tmp"
HX_RUNTIME="-u XDG_RUNTIME_DIR TMPDIR='$WORK/tmp'" hx_start "$WORK/two.sql"
cmd "db-run sqlite:$WORK/shop.db"
expect "without XDG_RUNTIME_DIR the run still works" "db-run: done in"
[[ $(ls -ld "$WORK"/tmp/dadbod-hx.* | cut -c1-10) == "drwx------" ]] ||
  fail "the fallback directory is not private"
ok "the fallback directory is private"

# A PATH with mktemp (for the session directory) and nothing else.
mkdir -p "$WORK/nobin"
ln -s "$(command -v mktemp)" "$WORK/nobin/mktemp"
HX_ENV="PATH='$WORK/nobin'" hx_start "$WORK/two.sql"
cmd "db-run sqlite:$WORK/shop.db"
expect "a missing client is reported" "db-run: 'sqlite3' is not on PATH"

# Installed as a package: found by name in Steel's package directory, the way
# the README says to require it.
mkdir -p "$WORK/home/.local/share/steel/cogs" "$WORK/installed"
ln -s "$ROOT" "$WORK/home/.local/share/steel/cogs/dadbod"
echo ';; no commands of its own' >"$WORK/installed/helix.scm"
echo '(require "dadbod/dadbod.scm")' >"$WORK/installed/init.scm"
hx_run "$WORK" "$WORK/installed" "$WORK/two.sql"
cmd "db-run sqlite:$WORK/shop.db"
expect "installed as the 'dadbod' package, (require \"dadbod/dadbod.scm\") works" "| Kindred |"

### PostgreSQL

if command -v initdb >/dev/null && command -v pg_ctl >/dev/null && command -v psql >/dev/null; then
  echo "== postgres"
  # Password logins only, on a unix socket in the work directory: the run
  # only works if the password reaches psql through PGPASSWORD.
  password='s3cr@t/1'
  printf '%s\n' "$password" >"$WORK/pwfile"
  initdb -D "$WORK/pg" -U app --pwfile="$WORK/pwfile" --auth=scram-sha-256 >/dev/null
  mkdir -p "$WORK/pgsock"
  pg_ctl -D "$WORK/pg" -l "$WORK/pg.log" -w \
    -o "-c listen_addresses='' -c unix_socket_directories='$WORK/pgsock'" start >/dev/null
  PGPASSWORD=$password psql -q -h "$WORK/pgsock" -U app -d postgres -c \
    "create table authors (id serial primary key, name text); insert into authors (name) values ('Lem'), ('Butler');"

  cat >"$WORK/pg.sql" <<'SQL'
select name from authors order by id;
SQL
  cat >"$WORK/slow.sql" <<'SQL'
select pg_sleep(5);
select 'woke up';
SQL
  cat >"$WORK/pgbroken.sql" <<'SQL'
select 'before the error';
select * from no_such_table;
select 'after the error';
SQL

  hx_start "$WORK/pg.sql"
  # The password is percent-encoded in the URL: @ is %40 and / is %2F.
  cmd "db-run postgres://app:s3cr%40t%2F1@/postgres?host=$WORK/pgsock"
  expect "postgres: the query runs with the password from the URL" "db-run: done in"
  expect "postgres: rows" "Butler"
  expect "postgres: the result names the database" "-- postgres://app@/postgres"
  refute "postgres: the password is not shown" "s3cr"

  cmd "open $WORK/slow.sql"
  wait_for "open slow.sql" "pg_sleep"
  cmd "db-run"
  expect "postgres: a running query is announced" "db-run: running on postgres://app@/postgres"
  keys i
  expect "postgres: the editor is usable while the query runs" " INS "
  refute "postgres: (the query really was still running)" "db-run: done in"
  # The result arrives in insert mode. Showing it there would end insert
  # mode, and what is typed next would run as commands.
  expect "postgres: the slow query finishes" "db-run: done in"
  expect "postgres: the result waits for normal mode" "shown when back in normal mode"
  # The window still holds the last result, "(2 rows)"; the new one has
  # "(1 row)" twice.
  refute "postgres: (it is not shown yet)" "(1 row)"
  expect "postgres: insert mode is left alone" " INS "
  keys Escape
  expect "postgres: the result shows once back in normal mode" "(1 row)"

  cmd "open $WORK/pgbroken.sql"
  wait_for "open pgbroken.sql" "no_such_table"
  cmd "db-run"
  expect "postgres: a failing statement is reported" "db-run: the database client exited with code 3"
  expect "postgres: the server's error is shown" 'relation "no_such_table" does not exist'
  refute "postgres: nothing runs after the error" "| after the error"

  hx_start "$WORK/pg.sql"
  cmd "db-run postgres://app:wrong@/postgres?host=$WORK/pgsock"
  expect "postgres: a wrong password fails without prompting" "db-run: the database client exited with code 2"
  # The message is longer than the screen is wide, so only its start shows.
  expect "postgres: the authentication error is shown" "psql: error: connection to server on socket"

  HX_ENV="DATABASE_URL='postgres://app:s3cr%40t%2F1@/postgres?host=$WORK/pgsock'" hx_start "$WORK/pg.sql"
  cmd "db-run"
  expect "postgres: \$DATABASE_URL is used when no URL was given" "db-run: done in"
  expect "postgres: rows through \$DATABASE_URL" "Butler"
else
  echo "== postgres: SKIPPED (initdb, pg_ctl or psql not on PATH)"
fi

### MariaDB

if command -v mariadbd >/dev/null && command -v mariadb-install-db >/dev/null && command -v mariadb >/dev/null; then
  echo "== mariadb"
  # Below the range Linux hands out to outgoing connections (32768 and up).
  port=$((20000 + RANDOM % 12000))
  mariadb-install-db --no-defaults --datadir="$WORK/mysql" --auth-root-authentication-method=normal >/dev/null 2>&1
  mariadbd --no-defaults --datadir="$WORK/mysql" --socket="$WORK/mysql.sock" --pid-file="$WORK/mysql.pid" \
    --bind-address=127.0.0.1 --port="$port" >"$WORK/mysql.log" 2>&1 &
  mysql_pid=$!
  for _ in $(seq 1 100); do
    mariadb --no-defaults --socket="$WORK/mysql.sock" -u root -e "select 1" >/dev/null 2>&1 && break
    sleep 0.2
  done
  mariadb --no-defaults --socket="$WORK/mysql.sock" -u root -e "
    create database shop;
    create table shop.books (id int primary key auto_increment, title varchar(100));
    insert into shop.books (title) values ('Solaris'), ('Kindred');
    create user app@'127.0.0.1' identified by 's3cret';
    grant all on shop.* to app@'127.0.0.1';" ||
    fail "mariadb: the test server did not come up on port $port (see $WORK/mysql.log; E2E_KEEP=1 keeps it)"

  cat >"$WORK/my.sql" <<'SQL'
select title from books order by id;
SQL

  # Both schemes: each runs whichever of the two client names is on PATH.
  for scheme in mysql mariadb; do
    hx_start "$WORK/my.sql"
    cmd "db-run $scheme://app:s3cret@127.0.0.1:$port/shop"
    expect "$scheme: the query runs over TCP with the password from the URL" "db-run: done in"
    expect "$scheme: rows, as a table" "| Kindred |"
    expect "$scheme: the result names the database" "-- $scheme://app@127.0.0.1:$port/shop"
    refute "$scheme: the password is not shown" "s3cret"
  done
else
  echo "== mariadb: SKIPPED (mariadbd, mariadb-install-db or mariadb not on PATH)"
fi

echo
echo "e2e: $passed checks passed"

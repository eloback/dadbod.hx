# Sourced by tests/e2e.sh. SQLite needs no server, so this part also covers
# everything that isn't about one database: what runs, the result split,
# errors, files.

echo "== sqlite"
sqlite3 "$WORK/shop.db" "create table books (id integer primary key, title text);
insert into books (title) values ('Solaris'), ('Kindred');"

cat >"$WORK/two.sql" <<'SQL'
select title from books where id = 1;
select title from books where id = 2;
SQL
write_broken_sql "$WORK/broken.sql"
# 0xE9 is "é" in Latin-1 and invalid in UTF-8.
cat >"$WORK/latin1.sql" <<'SQL'
select cast(x'636166e9' as text) as word;
select 'after the odd bytes';
SQL
# Counts for longer than anyone will wait.
cat >"$WORK/slow.sql" <<'SQL'
select 'before the slow one';
with recursive c(x) as (select 1 union all select x + 1 from c where x < 100000000000)
select count(*) from c;
select 'after the slow one';
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

cmd "db-cancel"
expect "cancelling with nothing running is an error" "db-cancel: no query is running"

cmd "db-run sqlite:$WORK/shop.db"
expect "the whole buffer runs when nothing is selected" "db-run: done in"
expect "the result names the database, without credentials" "-- sqlite:$WORK/shop.db"
expect "first statement's row" "| Solaris |"
expect "second statement's row" "| Kindred |"
# Only the focused window's status line shows the mode.
expect_re "the focus stays on the query buffer" "NOR .*two\.sql"

# Select the second line only; the URL is remembered.
normal_mode
keys g g j x
expect_re "(the second line is selected)" "two\.sql .*1 sel +2:"
cmd "db-run"
expect_gone "a later run reuses the URL, and only the selection runs" "| Solaris |"
expect "the selection's row" "| Kindred |"

# A selection made in select mode (v): Helix stays in that mode after the
# command, and the result must not wait for it to end.
keys g g v g l
expect "(select mode)" " SEL "
cmd_from_select "db-run"
expect "a run from select mode shows its result at once" "| Solaris |"
expect_gone "(only the selection ran)" "| Kindred |"
keys Escape
normal_mode

# The key from the README (.helix/init.scm binds it).
keys g g x
expect_re "(the first line is selected)" "two\.sql .*1 sel +1:"
keys Space
sleep 0.3
keys x
expect "space x runs the selection" "| Solaris |"
expect_gone "(and only the selection)" "| Kindred |"
keys j x
expect_re "(the second line is selected again)" "two\.sql .*1 sel +2:"

# The result window was closed, its buffer is still open.
keys C-w o
expect_gone "(the result window is closed)" "result.dbout"
cmd "db-run"
expect "the result window comes back" "result.dbout"
expect "with the result" "| Kindred |"

# The result buffer was closed too.
keys C-w j
expect_re "(the result window has the focus)" "NOR .*result\.dbout"
cmd "buffer-close"
expect_gone "(the result buffer is closed)" "result.dbout"
cmd "db-run"
expect "the result buffer comes back" "result.dbout"
expect "with the result again" "| Kindred |"

keys C-w j
expect_re "(the result window has the focus again)" "NOR .*result\.dbout"
cmd "db-run"
expect "running from the result buffer is refused" "db-run: this is the result buffer"
keys C-w k

open "$WORK/broken.sql"
cmd "db-run"
expect "a failing statement is reported" "db-run: the database client exited with code 1"
expect "output before the error is kept" "| before the error "
expect "the client's error is shown" "no such table: no_such_table"
refute "nothing runs after the error" "| after the error |"

open "$WORK/latin1.sql"
cmd "db-run"
expect "output that is not valid UTF-8 is still a result" "db-run: done in"
expect "with the row that has the odd bytes" "| caf"
expect "and everything after it" "| after the odd bytes "

open "$WORK/slow.sql"
cmd "db-run"
expect "a slow query is announced" "db-run: running on sqlite:"
# Cancelled at once, maybe before the client has even started: it still ends.
cmd "db-cancel"
expect "sqlite: db-cancel right after db-run ends the run" "db-run: cancelled after"

# Cancelled while the slow statement runs. There is no server to ask whether
# it has begun, so give sqlite3 a moment.
cmd "db-run"
expect "(the slow query again)" "db-run: running on sqlite:"
sleep 1
cmd "db-cancel"
expect "sqlite: db-cancel stops the query" "db-run: cancelled after"
# Cells are padded to the header's width, so no closing "|" in these.
expect "sqlite: what ran before it is in the result" "| before the slow one "
expect "sqlite: so is the client's word on it" "interrupted"
refute "sqlite: nothing runs after a cancelled statement" "| after the slow one "

open "$WORK/empty.sql"
cmd "db-run"
expect "a blank buffer is an error" "db-run: nothing to run"

expect_only_results "only the result file is left in the session directory"
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

# A PATH with what the plugin itself needs (mktemp for the session
# directory, sh to start the client) and no database client.
mkdir -p "$WORK/nobin"
ln -s "$(command -v mktemp)" "$WORK/nobin/mktemp"
ln -s "$(command -v sh)" "$WORK/nobin/sh"
HX_ENV="PATH='$WORK/nobin'" hx_start "$WORK/two.sql"
cmd "db-run sqlite:$WORK/shop.db"
expect "a missing client is reported" "db-run: 'sqlite3' is not on PATH"

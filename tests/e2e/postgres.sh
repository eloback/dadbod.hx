# Sourced by tests/e2e.sh. Needs initdb, pg_ctl and psql; skipped without.

if ! (command -v initdb && command -v pg_ctl && command -v psql) >/dev/null; then
  echo "== postgres: SKIPPED (initdb, pg_ctl or psql not on PATH)"
  return 0
fi

echo "== postgres"
# Password logins only, on a unix socket in the work directory: a run only
# works if the password reaches psql through PGPASSWORD.
password='s3cr@t/1'
printf '%s\n' "$password" >"$WORK/pwfile"
initdb -D "$WORK/pg" -U app --pwfile="$WORK/pwfile" --auth=scram-sha-256 >/dev/null
mkdir -p "$WORK/pgsock"
pg_ctl -D "$WORK/pg" -l "$WORK/pg.log" -w \
  -o "-c listen_addresses='' -c port=5432 -c unix_socket_directories='$WORK/pgsock'" start >/dev/null
PGPASSWORD=$password psql -q -h "$WORK/pgsock" -p 5432 -U app -d postgres -c \
  "create table authors (id serial primary key, name text); insert into authors (name) values ('Lem'), ('Butler');"
# The password is percent-encoded in the URL: @ is %40 and / is %2F.
pg_url="postgres://app:s3cr%40t%2F1@/postgres?host=$WORK/pgsock"

cat >"$WORK/pg.sql" <<'SQL'
select name from authors order by id;
SQL
cat >"$WORK/pgslow.sql" <<'SQL'
select pg_sleep(5);
select 'woke up';
SQL
cat >"$WORK/pgforever.sql" <<'SQL'
select 'before the long sleep';
select pg_sleep(600);
select 'after the long sleep';
SQL
write_broken_sql "$WORK/pgbroken.sql"

hx_start "$WORK/pg.sql"
cmd "db-run $pg_url"
expect "postgres: the query runs with the password from the URL" "db-run: done in"
expect "postgres: rows" "Butler"
expect "postgres: the result names the database" "-- postgres://app@/postgres"
refute "postgres: the password is not shown" "s3cr"

open "$WORK/pgslow.sql"
cmd "db-run"
expect "postgres: a running query is announced" "db-run: running on postgres://app@/postgres"
keys i
expect "postgres: the editor is usable while the query runs" " INS "
refute "postgres: (the query really was still running)" "db-run: done in"
# The result arrives in insert mode. Showing it there would end insert
# mode, and what is typed next would run as commands.
expect "postgres: the slow query finishes" "db-run: done in"
expect "postgres: the result waits for the end of insert mode" "shown when you leave insert mode"
# The window still holds the last result, "(2 rows)"; the new one has
# "(1 row)" twice.
refute "postgres: (it is not shown yet)" "(1 row)"
expect "postgres: insert mode is left alone" " INS "
leave_insert_mode
expect "postgres: the result shows once back in normal mode" "(1 row)"

open "$WORK/pgforever.sql"
cmd "db-run"
expect "postgres: (a query that would run for ten minutes)" "db-run: running on postgres://app@/postgres"
# Cancelled once the server is running it: a cancel that comes while the
# client is still connecting just ends the client, and there is nothing for
# the server to say.
sleeping() {
  [[ $(PGPASSWORD=$password psql -At -h "$WORK/pgsock" -p 5432 -U app -d postgres -c \
    "select count(*) from pg_stat_activity where query like 'select pg_sleep(600)%' and state = 'active'") == "$1" ]]
}
wait_until "postgres: the server runs the query" sleeping 1
cmd "db-cancel"
expect "postgres: db-cancel asks the server to cancel" "db-run: cancelled after"
expect "postgres: the server says so" "canceling statement due to user request"
# In the result, not in the query above it: a row, after its line number.
expect_re "postgres: what ran before it is in the result" "[0-9] +before the long sleep"
refute "postgres: nothing runs after a cancelled statement" " after the long sleep"
wait_until "postgres: the server is no longer running it" sleeping 0
ok "postgres: the server is no longer running it"

open "$WORK/pgbroken.sql"
cmd "db-run"
expect "postgres: a failing statement is reported" "db-run: the database client exited with code 3"
expect "postgres: the server's error is shown" 'relation "no_such_table" does not exist'
refute "postgres: nothing runs after the error" "| after the error"

hx_start "$WORK/pg.sql"
cmd "db-run postgres://app:wrong@/postgres?host=$WORK/pgsock"
expect "postgres: a wrong password fails without prompting" "db-run: the database client exited with code 2"
# The message is longer than the screen is wide, so only its start shows.
expect "postgres: the authentication error is shown" "psql: error: connection to server on socket"

HX_ENV="DATABASE_URL='$pg_url'" hx_start "$WORK/pg.sql"
cmd "db-run"
expect "postgres: \$DATABASE_URL is used when no URL was given" "db-run: done in"
expect "postgres: rows through \$DATABASE_URL" "Butler"

HX_ENV="DATABASE_URL='$pg_url'" hx_start_installed "$WORK/pg.sql"
cmd "consumer-answer select name from authors order by id;"
expect "postgres: a quiet query gives rows only" "consumer: answer=Lem"

# The drawer, on a database given by $DATABASE_URL: its tables and a helper.
HX_ENV="DATABASE_URL='$pg_url'" hx_start "$WORK/pg.sql"
cmd "dbui"
expect "postgres: the database in use is in the drawer, without its password" "▸ current database  postgres://app@/postgres"
refute "postgres: (no password in the drawer)" "s3cr"
select_line "current database"
select_line "Tables"
expect "postgres: its tables are listed" "▸ authors"
select_line "authors"
select_line "Columns"
expect "postgres: a table helper runs" "| data_type"
expect "postgres: and answers about that table" "| integer"

# Helpers on tables whose names need quoting, and in another schema.
PGPASSWORD=$password psql -q -h "$WORK/pgsock" -p 5432 -U app -d postgres -c \
  'create schema sales; create table sales."Orders" (id int primary key, author_id int references authors (id));'
cmd "dbui"
find_line "Tables"
keys R
expect "postgres: R asks for the tables again; another schema's are named with it" "▸ sales.Orders"
select_line "sales.Orders"
select_line "Foreign Keys" "sales.Orders"
expect "postgres: a helper on a mixed-case table in another schema" "FOREIGN KEY (author_id) REFERENCES authors(id)"

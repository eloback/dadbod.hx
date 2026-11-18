# Sourced by tests/e2e.sh. Needs mariadbd, mariadb-install-db and mariadb;
# skipped without.

if ! (command -v mariadbd && command -v mariadb-install-db && command -v mariadb) >/dev/null; then
  echo "== mariadb: SKIPPED (mariadbd, mariadb-install-db or mariadb not on PATH)"
  return 0
fi

echo "== mariadb"
# Below the range Linux hands out to outgoing connections (32768 and up).
port=$((20000 + RANDOM % 12000))
mariadb-install-db --no-defaults --datadir="$WORK/mysql" --auth-root-authentication-method=normal >/dev/null 2>&1
mariadbd --no-defaults --datadir="$WORK/mysql" --socket="$WORK/mysql.sock" --pid-file="$WORK/mysql.pid" \
  --bind-address=127.0.0.1 --port="$port" >"$WORK/mysql.log" 2>&1 &
mysql_pid=$!
root() {
  mariadb --no-defaults --socket="$WORK/mysql.sock" -u root "$@"
}
for _ in $(seq 1 100); do
  root -e "select 1" >/dev/null 2>&1 && break
  sleep 0.2
done
root -e "
  create database shop;
  create table shop.books (id int primary key auto_increment, title varchar(100));
  insert into shop.books (title) values ('Solaris'), ('Kindred');
  create user app@'127.0.0.1' identified by 's3cret';
  grant all on shop.* to app@'127.0.0.1';" ||
  fail "mariadb: the test server did not come up on port $port (see $WORK/mysql.log; E2E_KEEP=1 keeps it)"

cat >"$WORK/my.sql" <<'SQL'
select title from books order by id;
SQL
cat >"$WORK/myforever.sql" <<'SQL'
select 'before the long sleep';
select sleep(600);
select 'after the long sleep';
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

open "$WORK/myforever.sql"
cmd "db-run"
expect "mariadb: (a query that would run for ten minutes)" "db-run: running on mariadb://app@127.0.0.1"
# Cancelled once the server is running it: a cancel that comes while the
# client is still connecting just ends the client, and there is nothing for
# the server to say.
sleeping() {
  [[ $(root -N -e "select count(*) from information_schema.processlist where info like 'select sleep(600)%'") == "$1" ]]
}
wait_until "mariadb: the server runs the query" sleeping 1
cmd "db-cancel"
expect "mariadb: db-cancel has the server kill the query" "db-run: cancelled after"
expect "mariadb: the server says so" "Query execution was interrupted"
refute "mariadb: nothing runs after a cancelled statement" "| after the long sleep "
wait_until "mariadb: the server is no longer running it" sleeping 0
ok "mariadb: the server is no longer running it"

HX_ENV="DATABASE_URL='mariadb://app:s3cret@127.0.0.1:$port/shop'" hx_start_installed "$WORK/my.sql"
cmd "consumer-answer select title from books order by id;"
expect "mariadb: a quiet query gives rows only" "consumer: answer=Solaris"

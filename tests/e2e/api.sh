# Sourced by tests/e2e.sh, after sqlite.sh (it uses its database).
#
# The repository installed as a package, and a second plugin using dadbod
# through dadbod/api.scm: what dadbod-ui will rest on.

echo "== installed, with a second plugin"

hx_start_installed "$WORK/two.sql"

cmd "consumer-url"
expect "api: no URL yet" "consumer: url=none"

cmd "db-run sqlite:$WORK/shop.db"
expect "installed as the 'dadbod' package, (require \"dadbod/dadbod.scm\") works" "| Kindred |"

cmd "consumer-url"
expect "api: the other plugin sees the URL :db-run used" "consumer: url=sqlite:$WORK/shop.db"

cmd "consumer-answer"
expect "api: a quiet query hands its answer to the plugin" "consumer: answer=42"
refute "api: (and shows nothing in the result split)" "| 42"

cmd "consumer-answer select title from books order by id;"
expect "api: quiet output is rows only, no table borders" "consumer: answer=Solaris"

cmd "consumer-answer select * from no_such_table;"
expect "api: a failing quiet query reports the failure and the client's error" \
  "consumer: failed: the database client exited with code 1 / "
expect "api: (the client's error)" "no such table: no_such_table"

cmd "consumer-run"
expect "api: the other plugin can run a query into the result split" "| from the consumer |"

# The other way round: a URL chosen in the second plugin is the one :db-run
# uses.
sqlite3 "$WORK/other.db" "create table things (name text); insert into things values ('from the other database');"
cat >"$WORK/things.sql" <<'SQL'
select name from things;
SQL
open "$WORK/things.sql"
cmd "consumer-use sqlite:$WORK/other.db"
expect "api: the other plugin chooses the database" "consumer: using sqlite:$WORK/other.db"
cmd "db-run"
expect "api: and :db-run runs against it" "| from the other database |"

cmd "consumer-use oracle://host/db"
expect "api: a URL dadbod can't run against is refused" "consumer: refused: no adapter for 'oracle' databases"

expect_only_results "api: quiet queries leave no files behind"

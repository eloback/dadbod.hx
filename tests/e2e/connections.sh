# Sourced by tests/e2e.sh, after sqlite.sh (it uses its database).
#
# Named connections, a database per buffer, :db-query, :db-rerun and the
# keys of the result window.

echo "== connections"

sqlite3 "$WORK/things.db" "create table things (name text); insert into things values ('a thing');"
cat >"$WORK/things.sql" <<'SQL'
select name from things;
SQL

# The user's connections file, in the scratch HOME: a URL, an environment
# variable, a command, and a line that can't be read.
mkdir -p "$WORK/home/.config/helix"
cat >"$WORK/home/.config/helix/dadbod-connections" <<EOF
# test connections
shop    sqlite:$WORK/shop.db
things  \$THINGS_URL
viacmd  !echo sqlite:$WORK/things.db
nowhere \$NOT_SET_ANYWHERE
both    sqlite:$WORK/things.db
broken
EOF

# A project with a connections file of its own: it adds one, replaces the
# user's "both", and tries to have a command run.
mkdir -p "$WORK/project/.helix"
cat >"$WORK/project/.helix/dadbod-connections" <<EOF
local  sqlite:$WORK/things.db
both   sqlite:$WORK/shop.db
evil   !touch $WORK/evil-ran; echo sqlite:$WORK/shop.db
EOF

# From the environment, as vim-dadbod-ui has it: a new one, and one that
# replaces the file's "shop".
HX_ENV="THINGS_URL='sqlite:$WORK/things.db' DB_UI_FROMENV='sqlite:$WORK/things.db' DB_UI_SHOP='sqlite:$WORK/things.db'" hx_run "$WORK/project" "$ROOT/.helix" "$WORK/two.sql"

cmd "db-use"
expect "db-use alone says nothing is chosen, and lists the connections" \
  "db-use: no database chosen  |  connections: shop, things, viacmd, nowhere, both, local, evil, fromenv"
expect "and reports a line of the file it couldn't read" "line 7: 'broken'"

cmd "db-run nosuch"
expect "an unknown connection is an error" "db-run: no connection called 'nosuch'"

cmd "db-run nowhere"
expect "a connection whose variable is unset is an error" "db-run: the environment variable NOT_SET_ANYWHERE is not set"

cmd "db-run both"
expect "a connection runs by its name" "| Kindred |"
expect "the result names the connection and its database" "-- both (sqlite:$WORK/shop.db)"

cmd "db-run fromenv"
expect "DB_UI_FROMENV in the environment is the connection fromenv" "-- fromenv (sqlite:$WORK/things.db)"
cmd "db-run shop"
expect "DB_UI_SHOP wins over the file's shop" "-- shop (sqlite:$WORK/things.db)"
cmd "db-run both"
expect "(back to a database with books)" "-- both (sqlite:$WORK/shop.db)"

cmd "db-use"
expect "db-use alone shows the buffer's database, by its name" "db-use: both  |"

cmd "db-run evil"
expect "a project's connection can't get its URL from a command" \
  "db-run: the connection 'evil' in .helix/dadbod-connections gets its URL from a command"
[[ ! -e $WORK/evil-ran ]] || fail "the project's command ran"
ok "and the command did not run"
cmd "db-use evil"
expect "nor through db-use" "db-use: the connection 'evil' in .helix/dadbod-connections"
[[ ! -e $WORK/evil-ran ]] || fail "the project's command ran through db-use"
ok "(it did not run)"

# A URL without its //: its password is in what would be shown.
cmd "db-use postgres:app:hunter2@host/db"
expect "a URL written wrong is refused" "db-use: postgres URLs need the //"
refute "and its password is not shown" "hunter2"

# A second buffer gets its own database; the first keeps its own.
open "$WORK/things.sql"
cmd "db-use things"
expect "db-use chooses a database for this buffer, here through \$THINGS_URL" \
  "db-use: things (sqlite:$WORK/things.db)"
cmd "db-run"
expect "the second buffer runs against its own database" "| a thing |"
open "$WORK/two.sql"
cmd "db-run"
expect "the first buffer still runs against its own" "| Kindred |"
expect_gone "(the other buffer's result is replaced)" "| a thing |"

open "$WORK/things.sql"
cmd "db-run viacmd"
expect "a connection whose URL a command prints" "-- viacmd (sqlite:$WORK/things.db)"
cmd "db-run local"
expect "a connection from the project's own file" "-- local (sqlite:$WORK/things.db)"

cmd "db-use oracle://host/db"
expect "db-use refuses what can't be run against" "db-use: no adapter for 'oracle' databases"

# A query typed at the prompt, against this buffer's database.
cmd "db-query select name || ' typed' from things"
expect ":db-query runs what is typed after it" "| a thing typed "
cmd "db-query"
expect ":db-query without a query is an error" "db-query: give the query"

# The result window's keys. R reruns the last query: the table gets a row
# in between, and the rerun shows it.
sqlite3 "$WORK/things.db" "insert into things values ('another thing');"
keys C-w j
expect_re "(the result window has the focus)" "NOR .*result\.dbout"
keys R
expect "R in the result window reruns the last query" "| another thing typed "
cmd "db-run"
expect ":db-run in the result window still refuses" "db-run: this is the result buffer"
keys q
expect_gone "q closes the result window" "result.dbout"
expect_re "(the query buffer has the focus again)" "NOR .*things\.sql"

cmd "db-rerun"
expect ":db-rerun brings the result back" "| another thing typed "

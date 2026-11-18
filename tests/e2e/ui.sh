# Sourced by tests/e2e.sh, after sqlite.sh and connections.sh (it uses their
# databases and the connections file in the scratch HOME).
#
# dadbod-ui: the drawer.

echo "== dadbod-ui"

HX_ENV="THINGS_URL='sqlite:$WORK/things.db'" hx_start "$WORK/two.sql"

cmd "dbui"
expect "the drawer opens, floating over the buffer" "? help   ret open   q close"
expect "(the buffer is still there under it)" "select title from books where id = 1;"
expect "and lists the connections" "▸ shop"
expect "all of them" "▸ viacmd"

select_line "shop"
expect "a connection opens to a new query, its saved queries and its tables" "+ New query"
expect "no saved queries yet" "▸ Saved queries (0)"

select_line "Tables"
expect "opening Tables asks the database, and lists what it answers" "▾ Tables (1)"
expect "the table" "▸ books"

select_line "books"
expect "a table opens to its helpers" "        Columns"

select_line "Columns"
expect_gone "choosing a helper closes the drawer" "? help   ret open   q close"
expect_re "and opens a query buffer of its own" "NOR .*books\.Columns\.sql"
expect "with the helper's query in it" "pragma table_info('books');"
expect "and runs it" "| title "
expect "against the connection the table is in" "-- shop (sqlite:$WORK/shop.db)"

cmd "dbui"
expect "the drawer comes back as it was left" "▾ books"

select_line "New query"
expect_re "a new query gets a file of its own" "NOR .*query-1\.sql"
keys i
type_text "select title from books where id = 2;"
leave_insert_mode
cmd "db-run"
expect "the query buffer runs against its connection, without naming it" "| Kindred |"
cmd "write"
expect "(the query is saved)" "written"

cmd "dbui"
expect "the saved query is counted" "Saved queries (1)"
select_line "Saved queries"
expect "and listed" "      query-1.sql"
select_line "query-1.sql"
expect_re "a saved query opens" "NOR .*query-1\.sql"
expect "with its text" "select title from books where id = 2;"

cmd "dbui"
find_line "query-1.sql"
keys d
expect "d asks before deleting" "delete query-1.sql? (y/n):"
keys -l "y"
keys Enter
expect "and deletes the saved query" "dbui: deleted query-1.sql"
expect "which is gone from the drawer" "Saved queries (0)"
[[ ! -e $WORK/home/.local/share/dadbod-ui/shop/query-1.sql ]] || fail "the saved query's file is still there"
ok "and from the disk"

keys "?"
expect "? shows the keys" "add a connection"
keys "?"
expect_gone "? hides them again" "add a connection"

# A connection whose URL can't be looked up: the reason is shown where its
# tables would be.
select_line "nowhere"
select_line "Tables" "nowhere"
expect "a database that can't be reached says why, in place of its tables" \
  "the environment variable NOT_SET_ANYWHERE is not set"

keys A
expect "A asks for a connection" "connection (name, then a URL"
keys -l "leaky postgres://app:hunter2@host/db"
keys Enter
expect "A refuses to save a URL with a password in it" "dbui: that URL has a password in it"
if grep -q hunter2 "$WORK/home/.config/helix/dadbod-connections"; then
  fail "the password was written to the connections file"
fi
ok "and writes nothing"
keys A
expect "(A again)" "connection (name, then a URL"
keys -l "extra sqlite:$WORK/things.db"
keys Enter
expect "and adds it" "dbui: added extra"
expect "to the drawer" "▸ extra"
grep -q "^extra sqlite:$WORK/things.db$" "$WORK/home/.config/helix/dadbod-connections" ||
  fail "the connection was not written to the connections file"
ok "and to the connections file"

# Moving: G to the last line, k up, g to the first; the arrow keys too.
keys G
keys Enter
expect "G goes to the last line (and ret opens it)" "▾ extra"
keys Enter
expect "(and closes it)" "▸ extra"

keys q
expect_gone "q closes the drawer" "? help   ret open   q close"
cmd "dbui"
expect "(the drawer again)" "? help   ret open   q close"
keys Escape
expect_gone "esc closes it too" "? help   ret open   q close"
normal_mode

# Installed as a package, with the option to run a query file when it is
# saved.
install_package
mkdir -p "$WORK/uiconfig"
echo ';; no commands of its own' >"$WORK/uiconfig/helix.scm"
cat >"$WORK/uiconfig/init.scm" <<'SCM'
(require "dadbod/dadbod.scm")
(require "dadbod/dadbod-ui.scm")
(require "dadbod/dadbod-ui/config.scm")
(dadbod-ui-set! 'execute-on-save #t)
SCM
hx_run "$WORK" "$WORK/uiconfig" "$WORK/two.sql"
cmd "dbui"
expect "installed as a package: the drawer opens" "▸ shop"
select_line "shop"
select_line "New query"
expect_re "(a new query)" "NOR .*query-1\.sql"
keys i
type_text "select title from books where id = 1;"
leave_insert_mode
cmd "write"
expect "with execute-on-save, saving the query runs it" "| Solaris |"

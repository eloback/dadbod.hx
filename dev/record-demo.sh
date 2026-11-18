#!/usr/bin/env bash
# Records the demo in the README: docs/demo.cast, and docs/demo.gif from it.
#
#   dev/record-demo.sh         (in the devenv shell, which has hx and sqlite3)
#
# Needs asciinema and agg on PATH:
#   nix shell nixpkgs#asciinema nixpkgs#asciinema-agg -c dev/record-demo.sh
#
# Helix runs in a tmux server of its own (own socket, no config) with a
# scratch HOME, as in the tests; asciinema records that tmux session while
# this script types into it. Paths on screen are relative, so nothing of the
# machine it was recorded on shows.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
for tool in hx tmux sqlite3 asciinema agg; do
  command -v "$tool" >/dev/null || {
    echo "record-demo: '$tool' is not on PATH" >&2
    exit 1
  }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dadbod-demo.XXXXXX")
cleanup() {
  tm kill-server 2>/dev/null || true
  [[ -n $WORK && -d $WORK ]] && rm -rf -- "$WORK"
}
tm() {
  HOME="$WORK/home" tmux -f /dev/null -S "$WORK/tmux.sock" "$@"
}
trap cleanup EXIT

COLS=100
ROWS=30

# A small bookshop.
mkdir -p "$WORK/home/.config/helix" "$WORK/shop/run"
chmod 700 "$WORK/shop/run"
sqlite3 "$WORK/shop/shop.db" <"$ROOT/dev/demo.sql"
cat >"$WORK/shop/report.sql" <<'SQL'
-- books per author
select a.name, count(*) as books
from authors a join books b on b.author_id = a.id
group by a.name order by books desc, a.name;

select title, published from books where published < 1970 order by published;
SQL
echo 'shop sqlite:shop.db' >"$WORK/home/.config/helix/dadbod-connections"
printf 'theme = "catppuccin_mocha"\n\n[editor]\ntrue-color = true\n' >"$WORK/home/.config/helix/config.toml"

# Both plugins from this checkout. A table helper is opened, not run at
# once, so that the demo shows the query before running it.
mkdir -p "$WORK/steel"
echo ';; no commands of its own' >"$WORK/steel/helix.scm"
cat >"$WORK/steel/init.scm" <<SCM
(require "$ROOT/dadbod.scm")
(require "$ROOT/dadbod-ui.scm")
(require "$ROOT/dadbod-ui/config.scm")
(dadbod-ui-set! 'run-helpers #f)
SCM

# Helix, in a detached tmux session of the recording's size.
tm new-session -d -x "$COLS" -y "$ROWS" -c "$WORK/shop" \
  "env -u DATABASE_URL XDG_RUNTIME_DIR=run HELIX_STEEL_CONFIG='$WORK/steel' COLORTERM=truecolor hx report.sql"
tm set-option -g status off
sleep 2

# Typing, at a speed a person can follow.
type_text() {
  local text=$1 i
  for ((i = 0; i < ${#text}; i++)); do
    local ch=${text:i:1}
    if [[ $ch == ";" ]]; then
      tm send-keys -l '\;'
    else
      tm send-keys -l "$ch"
    fi
    sleep 0.045
  done
}
key() {
  tm send-keys "$@"
  sleep 0.35
}
pause() {
  sleep "$1"
}

script() {
  pause 1.5
  # Select the first statement (three lines) in select mode and run just
  # that, against a connection by name.
  key 2 g g
  pause 0.5
  key v
  pause 0.5
  key j
  key j
  key g l
  pause 1.5
  type_text ":db-run shop"
  pause 0.6
  key Enter
  pause 3.5
  key Escape
  pause 0.5

  # Then the second one: a different result takes its place.
  key 6 g g
  pause 0.5
  key v
  pause 0.5
  key g l
  pause 1.5
  type_text ":db-run"
  pause 0.6
  key Enter
  pause 3.5
  key Escape
  pause 0.5

  # A query typed at the prompt.
  type_text ":db-query select count(*) as books from books"
  pause 0.6
  key Enter
  pause 3

  # The drawer: tables and a helper.
  type_text ":dbui"
  pause 0.5
  key Enter
  pause 1.5
  key Enter
  pause 0.8
  key j
  key j
  key j
  key Enter
  pause 1.5
  key j
  key j
  key Enter
  pause 1
  key j
  key j
  pause 0.8
  key Enter
  # The helper's query is open: look at it, then run it.
  pause 2.5
  type_text ":db-run"
  pause 0.6
  key Enter
  pause 4
}

# asciinema records a client attached to that session; the script types
# into the session meanwhile and detaches the client when it is done.
(
  sleep 1.5
  script
  tm detach-client
) &
driver=$!

HOME="$WORK/home" asciinema rec --overwrite --quiet --headless --window-size "${COLS}x${ROWS}" \
  --idle-time-limit 2 \
  --command "tmux -f /dev/null -S '$WORK/tmux.sock' attach" "$ROOT/docs/demo.cast"
wait "$driver" || true

# The recording's first line names the command and the shell that made it,
# with their paths on this machine: not for a file that is published. Its
# last events are tmux leaving (the screen cleared, a "detached" notice):
# without them the recording ends on the last thing shown.
sed -i -E '1s/"command":"[^"]*"/"command":"hx report.sql"/; 1s/"env":\{[^}]*\}/"env":{"TERM":"xterm-256color"}/; /\[detached \(from session/d; /\\u001b\[\?1049l/d' "$ROOT/docs/demo.cast"

agg --quiet --theme monokai --font-size 14 --last-frame-duration 3 "$ROOT/docs/demo.cast" "$ROOT/docs/demo.gif"
ls -la "$ROOT/docs/demo.cast" "$ROOT/docs/demo.gif"

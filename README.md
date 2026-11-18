# dadbod.hx

Run SQL from a [Helix](https://helix-editor.com/) buffer against a database and
read the result in a split, in the spirit of
[vim-dadbod](https://github.com/tpope/vim-dadbod).

It is a plugin for the Steel plugin system, so it needs Helix built from
[mattwparas's `steel-event-system` fork](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md).

It is young: two commands, `:db-run` and `:db-cancel`, and three adapters
(PostgreSQL, MySQL/MariaDB, SQLite). [docs/FEATURES.md](docs/FEATURES.md)
compares it with vim-dadbod feature by feature and says what comes next. A
companion plugin in the manner of vim-dadbod-ui is planned in this
repository ([dadbod-ui/](dadbod-ui/README.md)).

## Usage

```
:db-run postgres://app:secret@localhost:5432/shop
```

runs the buffer against that database and opens the result below it:

```
-- postgres://app@localhost:5432/shop
       name        | books
-------------------+-------
 Stanisław Lem     |     2
 Ursula K. Le Guin |     2
(2 rows)
```

- **What runs.** The primary selection, or the whole buffer when nothing is
  selected: a selection of one character is just the cursor, and so is a
  blank one. To run one statement, select it first: `x` for the line, `mip`
  for the paragraph. Mind that most Helix motions (`w`, `f`, `n`) leave a
  selection behind, and that selection is what would run.
- **Which database.** `:db-run <url>` uses that URL and remembers it for the
  rest of the session. `:db-run` alone uses the remembered URL, and otherwise
  `$DATABASE_URL`.
- **The result** is a file (`result.dbout`) shown in a horizontal split, which
  is reused by later runs. The focus stays on your query. The first line names
  the database, without the password.
- **Errors.** The client stops at the first failing statement. Its error
  message is in the result, and the status line reports the exit code.
- **Slow queries** don't freeze the editor: the client runs on its own thread
  and the result appears when it is done. If you are in insert or select
  mode at that moment, it appears once you are back in normal mode.
- **`:db-cancel`** stops the newest query still running. It asks the
  database to cancel the statement, so the server stops working on it, and
  what the query had produced so far is shown. For a client that doesn't
  react, run it again: that stops the client itself, but then the server may
  go on running the statement.

A key for it, in `init.scm`:

```scheme
(require "helix/keymaps.scm")

(keymap (global) (normal (space (x ":db-run"))))
```

## Databases

Each adapter calls the database's own command line client, which has to be on
`PATH`.

| URL | Client | Notes |
| --- | --- | --- |
| `postgres://user:password@host:port/database?params` (also `postgresql://`) | `psql` | The part after `?` is passed to libpq as it is (`sslmode=require`, `host=/run/postgresql`, ...). `~/.psqlrc` applies. |
| `mysql://user:password@host:port/database` | `mysql`, else `mariadb` | With a port the connection is forced to TCP; without one the client decides (a unix socket for `localhost`). No `?` parameters. |
| `mariadb://user:password@host:port/database` | `mariadb`, else `mysql` | The same. Where MariaDB also installs a `mysql` command that prints a deprecation warning, this scheme avoids it. |
| `sqlite:relative/file.db`, `sqlite:///absolute/file.db` (also `sqlite3:`) | `sqlite3` | A relative path is relative to Helix's working directory. A file that doesn't exist is created, as `sqlite3` does. No `?` parameters. |

Every part of the URL is optional where the client has a default:
`postgres:///shop` is the `shop` database on the default local socket.

In the user and the password, `/ ? # @ :` have to be percent-encoded: a
password `p@ss/word` is written `p%40ss%2Fword`. A URL that could be read two
ways (a raw `/` in the password, an IPv6 address without brackets, a port
that isn't a number) is an error, not a guess, and so is a part an adapter
doesn't support: nothing is silently dropped.

### Passwords

The password is taken out of the URL and handed to the client in its
environment (`PGPASSWORD`, `MYSQL_PWD`), so it is not in the arguments, where
`ps` would show it to other users, and not in the result or the status line.
Two things still hold it: Helix's command history, when you type the URL at
the prompt, and your shell's, when you export `DATABASE_URL` by hand. To keep
it out of both, leave it out of the URL and use the client's own mechanism
(`~/.pgpass`, `~/.my.cnf`).

A password given as a `?password=` parameter to PostgreSQL is not recognised
and stays in the arguments.

### Where the files go

The query and the result are written to a directory made with `mktemp -d`
(only you can read it): `$XDG_RUNTIME_DIR/dadbod-hx.XXXXXX`, which is gone at
logout, or without `XDG_RUNTIME_DIR`, `$TMPDIR/dadbod-hx.XXXXXX`. The query
file is deleted after the run. The result file is kept, since the buffer
shows it; the plugin never deletes it.

The client's output is copied byte for byte, so text that isn't UTF-8 is not
lost; Helix decides how to display it.

## Install

With `forge`, the package manager that comes with Steel:

```sh
forge pkg install --git https://github.com/eloback/dadbod.hx.git
```

then in `~/.config/helix/init.scm`:

```scheme
(require "dadbod/dadbod.scm")
```

and restart Helix. Without `forge`, put a checkout where Steel looks for
packages, under the name `dadbod`: in `$STEEL_HOME/cogs/` (by default
`~/.local/share/steel/cogs/`, or `~/.steel/cogs/` if `~/.steel` exists), or in any directory on `STEEL_SEARCH_PATHS`.

It needs `sh`, `kill` and `mktemp` on `PATH`, besides the database clients.

## Not there yet

The full list, with what is planned, is in
[docs/FEATURES.md](docs/FEATURES.md). The ones you will notice first:

- One result buffer: a new run replaces the last result. Two runs at the same
  time both finish, and the one that finishes last is the one shown.
- No named connections, no per-project connection file, no schema browser, no
  completion (an SQL language server does that better).
- Only the primary selection runs, not every selection.
- stdout comes first in the result, then stderr, whatever order the client
  wrote them in.
- No TLS or socket options for MySQL/MariaDB (they would be `?` parameters).

## Development

```
dadbod.scm        the plugin's entry: its typed commands
dadbod/
  api.scm         what other plugins (dadbod-ui) may use
  core/           no Helix: URLs, adapters, the client process, the session
  hx/             Helix: the editor module and what the commands do
dadbod-ui/        the companion plugin, not written yet
tests/            lint, unit tests (core/), end-to-end tests (a real Helix)
docs/
  DESIGN.md       how it is put together, and the rules that keep it so
  HELIX-API.md    what building it taught about Helix's Steel API
  FEATURES.md     vim-dadbod and vim-dadbod-ui, feature by feature: what is
                  here, what is next, what won't be
```

Read [docs/DESIGN.md](docs/DESIGN.md) before changing anything structural.
Adding a database is three steps, listed at the top of
`dadbod/core/adapters.scm`.

The dev shell is [devenv](https://devenv.sh) (`direnv allow`, or
`devenv shell`). It brings the Helix fork with Steel, at the commit the
plugin is tested against, the matching Steel tools (`steel`, `forge`,
`steel-language-server`), and the database clients and servers the tests
use. Inside the shell, `hx` is that pinned Helix, not your own.

```sh
test-unit            # the boundary lint and tests/unit/*.scm; about a second
test-unit session    # one file
test-e2e             # tests/e2e/*.sh, in a real Helix; about a minute
test-e2e sqlite api  # some parts
devenv test          # everything; quiet unless something fails
```

`tests/e2e.sh` starts Helix in a tmux server of its own (own socket, no
config, scratch `HOME`) and throwaway PostgreSQL and MariaDB servers in a
temporary directory. `E2E_KEEP=1` keeps that directory after a failure.

### Trying a change

Helix started inside this repository loads `.helix/init.scm` instead of your
own `init.scm`, and that file requires `dadbod.scm` from the checkout. So
`:db-run` here is always the code you are editing; restart Helix to pick up a
change. Your other plugins are not loaded in that Helix.

There is a playground database:

```sh
devenv up -d              # PostgreSQL with dev/seed.sql, on a unix socket
hx dev/playground.sql     # then :db-run ($DATABASE_URL is set by the shell)
devenv processes down
```

`.helix/languages.toml` sets up `steel-language-server` for the Scheme files.
Helix only starts it after `:workspace-trust` in this repository (until then
the status line shows `[⚠]`).

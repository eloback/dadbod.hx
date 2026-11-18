<div align="center">

# dadbod.hx

**Run SQL from [Helix](https://helix-editor.com/) and read the answer next to it.**

Two plugins for Helix's Steel plugin system, in the spirit of
[vim-dadbod](https://github.com/tpope/vim-dadbod) and
[vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui).

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Helix: Steel fork](https://img.shields.io/badge/helix-steel--event--system-8a5cf5.svg)](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-336791.svg?logo=postgresql&logoColor=white)
![MySQL / MariaDB](https://img.shields.io/badge/MySQL%20%2F%20MariaDB-00758f.svg?logo=mariadb&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-003b57.svg?logo=sqlite&logoColor=white)

[Usage](#usage) · [Connections](#connections) · [Databases](#databases) ·
[The drawer](dadbod-ui/README.md) · [Security](#security) · [Install](#install)

<img src="docs/demo.gif" alt="Running a buffer, a selection and a typed query against a database, then browsing its tables in the drawer" width="820">

</div>

- **dadbod** runs a buffer, a selection or a typed query through the
  database's own command line client and shows the result in a split:
  `:db-run`, `:db-use`, `:db-query`, `:db-rerun`, `:db-cancel`. This page.
- **dadbod-ui** is a drawer of your connections, their tables and saved
  queries: `:dbui`. [dadbod-ui/README.md](dadbod-ui/README.md).

They are loaded separately, and need Helix built from
[mattwparas's `steel-event-system` fork](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md),
where the plugin system lives. [docs/FEATURES.md](docs/FEATURES.md) compares
both with their Vim counterparts, feature by feature.

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
- **Which database.** `:db-run <database>` runs against it and chooses it
  for this buffer; a database is a URL or the name of a
  [connection](#connections). `:db-run` alone uses the buffer's database,
  else the one used last, else `$DATABASE_URL`. So two SQL files can each
  keep their own database.
- **The result** is a file (`result.dbout`) shown in a horizontal split, which
  is reused by later runs. The focus stays on your query. The first line names
  the database, without the password.
- **Errors.** The client stops at the first failing statement. Its error
  message is in the result, and the status line reports the exit code.
- **Slow queries** don't freeze the editor: the client runs on its own thread
  and the result appears when it is done. If you are typing in insert mode
  at that moment, it appears once you leave it.
- **`:db-cancel`** stops the newest query still running. It asks the
  database to cancel the statement, so the server stops working on it, and
  what the query had produced so far is shown. For a client that doesn't
  react, run it again: that stops the client itself, but then the server may
  go on running the statement.

The other commands:

| | |
| --- | --- |
| `:db-use <database>` | Choose this buffer's database without running anything. Alone, it shows which one is in use and the connections there are. |
| `:db-query <sql>` | Run what is typed after it: `:db-query select count(*) from users`. |
| `:db-rerun` | Run the last query again, against the same database. |
| `:db-cancel` | See above. |

In the result window, `R` reruns the last query, `C-c` cancels the one
running, and `q` closes the window.

A key for it, in `init.scm`:

```scheme
(require "helix/keymaps.scm")

(keymap (global) (normal (space (x ":db-run"))))
```

## Connections

A connection is a name for a database, so that you type `:db-run prod`.
Write them one per line, the name first, in
`~/.config/helix/dadbod-connections`, and for one project in
`.helix/dadbod-connections`:

```
# name   where the URL comes from
dev      postgres:///shop_dev
staging  $STAGING_DATABASE_URL
prod     !pass show databases/shop
```

After the name comes the URL itself, `$VARIABLE` for an environment variable
that holds it, or `!command` for a command that prints it (its first line is
taken). With the last two no password is in the file.

- The URL is looked up when you ask for that connection: each time a query
  runs against it, on `:db-use <name>`, and the first time dadbod-ui lists
  its tables. Showing or listing connections looks nothing up.
- A command runs through `sh` with no terminal, and Helix waits for it: it
  can't ask you anything, so use one that answers by itself (`pass` with a
  graphical pinentry or an unlocked agent).
- **The project's file is not trusted like your own**: it comes with the
  repository. It can't use `!command`, and it can add connections but not
  replace one of yours, so `prod` stays your `prod` (`:db-use` reports a
  project entry that was ignored for that). A connection it adds is shown
  with `[project]` after its name.

They also come from the environment, as in vim-dadbod-ui: a variable
`DB_UI_<NAME>` holding a URL is the connection `<name>` in lowercase
(`DB_UI_DEV=postgres:///shop_dev` is `dev`). That suits direnv and devenv.
The environment is read once, when Helix first needs the connections.

When a name is defined more than once among your own, the last of these
wins: your file, `init.scm`, the environment.

They can also be given in `init.scm`:

```scheme
(require "dadbod/dadbod/api.scm")
(dadbod-connections! "dev" "postgres:///shop_dev"
                     "prod" "!pass show databases/shop")
```

## Databases

Each adapter calls the database's own command line client, which has to be on
`PATH`.

| URL | Client | Notes |
| --- | --- | --- |
| `postgres://user:password@host:port/database?params` (also `postgresql://`) | `psql` | The part after `?` is passed to libpq as it is (`sslmode=require`, `host=/run/postgresql`, ...). `~/.psqlrc` applies. |
| `mysql://user:password@host:port/database?params` | `mysql`, else `mariadb` | With a port the connection is forced to TCP; without one the client decides (a unix socket for `localhost`). Parameters become the client's options of the same name: `ssl`, `ssl-ca`, `ssl-capath`, `ssl-cert`, `ssl-cipher`, `ssl-key`, `ssl-mode`, `ssl-verify-server-cert`, `protocol`, `socket`, `default-character-set`, `login-path` (`?ssl-ca=/etc/ca.pem`; `true` and `false` switch one on and off). A unix socket is `?socket=/path`. |
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

A password given as a `?password=` or `?sslpassword=` parameter to
PostgreSQL is refused: the parameters go to `psql` as an argument.

### Where the files go

The query and the result are written to a directory made with `mktemp -d`
(only you can read it): `$XDG_RUNTIME_DIR/dadbod-hx.XXXXXX`, which is gone at
logout, or without `XDG_RUNTIME_DIR`, `$TMPDIR/dadbod-hx.XXXXXX`. The query
file is deleted after the run. The result file is kept, since the buffer
shows it; the plugin never deletes it.

The client's output is copied byte for byte, so text that isn't UTF-8 is not
lost; Helix decides how to display it.

## Security

What to know before pointing it at a database you care about.

- **`:db-run` gives the buffer to the database's client, not only to the
  database.** The clients have commands of their own, and some run programs
  on your machine: `\!` and `\copy … program` in `psql`, `.shell` in
  `sqlite3`, `system` in `mysql`. Running an SQL file is running a script:
  read one you didn't write before you run it.
- **Where a query goes is shown before and after**: the status line while
  it runs and the result's first line name the database, with the URL's
  parameters (they can change the host: `hostaddr=`, `socket=`), without the
  password. dadbod-ui asks a database for its tables without showing that
  line; the drawer marks connections a project brought with `[project]`.
- **A repository can bring connections** (`.helix/dadbod-connections`), with
  the limits described under [Connections](#connections). Running a query
  against one sends the query, and whatever credentials your client finds
  for that host (`~/.pgpass`, `~/.my.cnf`), to a server the repository
  chose.
- **Table names come from the database.** The drawer's helpers quote them,
  and refuse a name with a backslash, a brace or a control character in it
  rather than guess how the server and the client would read it.
- **A result can contain anything**, including terminal control sequences
  if the database holds them. Helix draws the result buffer; what such bytes
  do there is up to Helix and your terminal.
- **Passwords** are kept out of process arguments, results and the status
  line; see [Passwords](#passwords) for where they still are. Queries and
  results are files in a directory only you can read; dadbod-ui's saved
  queries are in `~/.local/share/dadbod-ui`, created for you only.
- **Helix itself**, in the fork this needs, loads a repository's
  `.helix/init.scm` without asking. That is not this plugin's doing, but it
  means opening Helix in a repository already runs that repository's code.

To report a problem, open an issue, or for something sensitive use GitHub's
private vulnerability reporting on the repository.

## Install

With `forge`, the package manager that comes with Steel:

```sh
forge pkg install --git https://github.com/eloback/dadbod.hx.git
```

then in `~/.config/helix/init.scm`:

```scheme
(require "dadbod/dadbod.scm")
(require "dadbod/dadbod-ui.scm")    ; the drawer, if you want it
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
- No completion of table or column names (an SQL language server does that
  better), and none of connection names at the prompt: Helix's plugin API
  has no way to offer it.
- Only the primary selection runs, not every selection.
- stdout comes first in the result, then stderr, whatever order the client
  wrote them in.
- Only PostgreSQL, MySQL/MariaDB and SQLite.

## Development

```
dadbod.scm        dadbod's entry: its typed commands
dadbod/
  api.scm         what other plugins (dadbod-ui) and init.scm may use
  core/           no Helix: URLs, adapters, connections, the client process,
                  the session
  hx/             Helix: the editor module and what the commands do
dadbod-ui.scm     dadbod-ui's entry: its typed commands
dadbod-ui/
  config.scm      its options, for init.scm
  core/           no Helix: the drawer's model, the query files
  hx/             Helix: its editor module and the drawer
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

### The demo

`docs/demo.gif` and `docs/demo.cast` (an [asciinema](https://asciinema.org)
recording: `asciinema play docs/demo.cast`) are made by a script, so they can
be redone when the plugins change:

```sh
nix shell nixpkgs#asciinema nixpkgs#asciinema-agg -c devenv shell -- dev/record-demo.sh
```

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

## License

[MIT](LICENSE).

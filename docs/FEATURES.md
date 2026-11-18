# Features: where dadbod.hx stands next to vim-dadbod

What [vim-dadbod](https://github.com/tpope/vim-dadbod) does, taken from its
help file and source, what of it dadbod.hx has, and for the rest whether it
should be built and whether it can be. The second half does the same, more
briefly, for [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui).

**Can** is about Helix's Steel API at the pinned commit (see
[HELIX-API.md](HELIX-API.md)). **Should** is a judgement: is it worth having
in Helix, given how Helix works.

Verdicts: **have** · **next** (worth doing, and possible now) · **later**
(worth doing, but bigger or behind something else) · **maybe** (only if
someone needs it) · **no**.

## vim-dadbod

### Running queries

| vim-dadbod | dadbod.hx | Verdict |
| --- | --- | --- |
| `:{range}DB [url]` runs lines of the buffer | `:db-run [url]` runs the primary selection, or the whole buffer | **have** |
| Results in a preview window, a `.dbout` file | Results in a split, a `.dbout` file | **have** |
| Runs asynchronously, the editor stays usable | Worker thread per run | **have** |
| `<C-c>` in the result window cancels the query | `:db-cancel`; asks the database to cancel, escalates when repeated | **have** (the key: see "result window keys") |
| `:DB [url] {query}` runs a query typed at the prompt | `:db-query <sql>`, against the buffer's database | **have** |
| `:DB [url] < {file}` runs a file | Open the file and `:db-run` | **maybe**. One more command for something two keystrokes already do. |
| `:DB [url]` alone opens an interactive console (`psql`) | Nothing | **later, as an option**. Possible with the steel-pty terminal plugin, as lazygit.hx does. But that is a native library that has to match Helix's Steel exactly and can crash Helix at startup when it doesn't; dadbod has no native code today. If built: a separate, optional entry file. A terminal multiplexer pane does this job well already. |
| In the result window: `R` reruns, `r` reruns after editing the command, `gq` closes | In the result window: `R` reruns, `C-c` cancels, `q` closes; `:db-rerun` anywhere | **have**, without the edit-then-rerun: change the query in its buffer and run it. |
| Each run writes its own `.dbout` file; `:DB!` opens it in a window of its own instead of the one preview window | One result file, replaced by each run | **later**. Keep the last few results as files and add a way to step back through them. Wait for a real need: one split that updates is simpler to live with. |
| An operator, `db#op_exec()`, to run a motion or text object | Select, then `:db-run` | **no**. Helix selects first and then acts: `mip` then the key for `:db-run` is the same thing. |
| `User DBExecutePre` / `DBExecutePost` events for other plugins | `dadbod-on-event!` in `api.scm`: a run finished, the database changed, a connection was added | **have** |

### Choosing the database

| vim-dadbod | dadbod.hx | Verdict |
| --- | --- | --- |
| A URL given to the command | Same | **have** |
| `$DATABASE_URL` as the default | Same | **have** |
| The URL is remembered: `:DB g:db = url`, then `:DB` uses it | The database used last is remembered for the session | **have** |
| Scoped defaults `w:db`, `t:db`, `b:db`, `g:db`: a database per window, tab, buffer | A database per buffer: `:db-run <database>` and `:db-use <database>` choose it | **have** per buffer. Per window or tab: **no**. |
| Named URLs: `:DB g:prod = url`, then `:DB g:prod …` | Named connections, in a file per user and per project or from `init.scm`; a name can point at an environment variable or a command, so no password sits in a file | **have** |
| Project configuration through other plugins (rails.vim, heroku.vim) and `.env` files (dotenv.vim) | `$DATABASE_URL` from the shell, e.g. through direnv | **maybe**. Reading `DATABASE_URL` from a `.env` in the workspace is small. direnv already does it for people who use it; a per-project connections file (above) covers the rest. |
| Completion at the prompt: URL schemes, database names, table names | Nothing | **no**: a Steel command can't offer completions for its arguments. A picker of named connections does the useful part. |
| Asks for the password when the client reports an authentication failure | The client's error is shown | **no**: Helix's prompt can't hide what is typed. `~/.pgpass` and `~/.my.cnf` are the better answer anyway. |

### URLs and adapters

| vim-dadbod | dadbod.hx | Verdict |
| --- | --- | --- |
| `adapter://user:password@host:port/database`, `adapter:database`, percent-encoding | Same shapes; stricter: a URL that could be read two ways is an error | **have** |
| A database file's path as the URL (`~/db.sqlite3`) | `sqlite:` in front | **maybe**. Convenient, and one more way to guess wrong. |
| Query parameters: PostgreSQL gets the whole URL, MySQL/MariaDB get each one as `--key=value`, SQLite drops them | PostgreSQL: passed on whole. MySQL/MariaDB: a fixed list of options (TLS, protocol, socket, login path, character set), anything else is an error. SQLite: refused | **have**. Unknown ones stay an error: ignoring `ssl-mode=REQUIRED` is the wrong default. |
| A unix socket as a percent-encoded host (`mysql://user@%2Fvar%2Frun%2Fmysqld.sock/db`) | The same for MySQL/MariaDB, or `?socket=/path`; PostgreSQL through `?host=/dir` | **have** |
| PostgreSQL, MySQL, MariaDB, SQLite | Same | **have** |
| DuckDB, ClickHouse, SQL Server, Oracle, Redis, MongoDB, BigQuery, Snowflake, Presto, Impala, jq, osquery | Nothing | **maybe**, one at a time, when someone uses one. Any client that reads statements on stdin is one file in `core/adapters/` plus tests (DuckDB is nearly SQLite's). Each needs a way to run it in the end-to-end suite, which is the real cost, and is why they shouldn't be added unseen. |
| Your own adapter (`g:db_adapter_*`, `db#adapter#…` functions) | Adapters are records in a list, in the plugin | **later**: a function in `api.scm` to register an adapter from `init.scm`. Cheap once the adapter record has settled, which it won't have until dadbod-ui adds to it. |
| `jdbc:` URLs, dbext profiles and `g:dadbod_manage_dbext` | Nothing | **no**. Compatibility with other Vim plugins. |
| Windows paths (`sqlite:C:/…`) | Untested | **no**, until someone runs Helix with Steel on Windows and wants it. |

### Things dadbod.hx does that vim-dadbod doesn't

- The password never reaches the client's arguments (vim-dadbod passes the
  URL, password included, to `psql`, and `-p<password>` to `mysql`).
- Cancelling asks the database to cancel the statement (vim-dadbod stops the
  client, and the server may go on running it).
- Ambiguous URLs and unsupported parameters are errors.
- A result that arrives while typing waits until insert mode is left.

## vim-dadbod-ui

It is the second plugin of this repository
([dadbod-ui/README.md](../dadbod-ui/README.md)): `dadbod-ui.scm` and
`dadbod-ui/`, using dadbod through `dadbod/api.scm`.

**How it is built.** The drawer is a floating component over the editor,
like Helix's pickers, drawn from a model each frame. The model (the tree,
what is expanded, what each line means) is pure and is in
`dadbod-ui/core/`, tested like dadbod's; only drawing and keys touch Helix.

| vim-dadbod-ui | Needs from dadbod | Verdict |
| --- | --- | --- |
| A drawer listing connections, toggled by a command | `:dbui`; it floats over the editor like a picker instead of sitting beside it, since Helix can't size a split | **have** |
| Connections from an environment variable, from configuration, from a saved file (`:DBUIAddConnection`) | dadbod's connections (files, `init.scm`, `DB_UI_<NAME>` variables), plus the database in use; `A` in the drawer adds one to the user's file | **have** |
| Schemas and tables under each connection | Tables, asked from the database when the section is first opened; other schemas' tables as `schema.table` | **have**, without schemas as a level of their own: **maybe**. |
| Table helpers: List, Columns, Indexes, Foreign Keys, Primary Keys (PostgreSQL also References), and your own | The same five per adapter (SQLite has no separate Primary Key), run when chosen | **have** the built-in ones. Your own: **later**, with registering adapters. |
| A query buffer per connection; `:w` runs it (on by default there) | A query file per connection, bound to it; `'execute-on-save` option, off by default: saving and running are different intentions | **have** |
| Saved queries per connection, listed in the drawer; rename, delete | Every `.sql` file in the connection's folder; `d` deletes; renaming is Helix's `:move` | **have** |
| Async execution with a progress notice | dadbod has it | **have**, through dadbod |
| Connection details, last query time | — | **maybe** |
| Bind parameters (`:name` in a query, asked for at run time) | A prompt | **maybe**. Useful, and a prompt per parameter is clumsy; editing the query is the Helix-like answer. |
| Jump to the row a foreign key points at, from a result | Parsing result tables | **maybe**. Fragile: it reads the client's table output. |
| Toggle a result between table and expanded layout | A second output mode per adapter | **maybe**. `\x` in the query does it for PostgreSQL today. |
| Icons, drawer width, help text, notifications | Help with `?`; the status line for notices | **maybe**: icons and more options. A width isn't possible. |
| Completion of tables and columns (vim-dadbod-completion) | — | **no**. Not possible from a plugin as far as is known, and an SQL language server (`sqls`, `postgres-language-server`) is the right tool: Helix supports those natively. |

## What is left

Everything marked **next** above is done. What remains is by choice:

- **later**: an interactive console (needs a native terminal library),
  several results kept side by side, registering your own adapter and table
  helpers from `init.scm`.
- **maybe**: more databases (one file each, plus a way to test it), running a
  file without opening it, `.env` files, a file's path as a URL, and for the
  drawer bind parameters, foreign-key jumps, an expanded result layout,
  schemas as a level, icons.
- **no**: the items the plugin API can't do (completion at the prompt, a
  hidden password prompt, a sized side panel) and the ones that are Vim
  compatibility.

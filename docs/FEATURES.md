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
| `:DB [url] {query}` runs a query typed at the prompt | Nothing | **next**. Small: a command that takes the query as its arguments, like `:db-query select count(*) from users`. It can't share `:db-run`'s name, because there the first word is the URL. |
| `:DB [url] < {file}` runs a file | Open the file and `:db-run` | **maybe**. One more command for something two keystrokes already do. |
| `:DB [url]` alone opens an interactive console (`psql`) | Nothing | **later, as an option**. Possible with the steel-pty terminal plugin, as lazygit.hx does. But that is a native library that has to match Helix's Steel exactly and can crash Helix at startup when it doesn't; dadbod has no native code today. If built: a separate, optional entry file. A terminal multiplexer pane does this job well already. |
| In the result window: `R` reruns, `r` reruns after editing the command, `gq` closes | Nothing | **next**. Helix has keymaps per file extension, so keys can live on `.dbout` buffers only: rerun, cancel, close. dadbod has to remember the last query for the rerun. |
| Each run writes its own `.dbout` file; `:DB!` opens it in a window of its own instead of the one preview window | One result file, replaced by each run | **later**. Keep the last few results as files and add a way to step back through them. Wait for a real need: one split that updates is simpler to live with. |
| An operator, `db#op_exec()`, to run a motion or text object | Select, then `:db-run` | **no**. Helix selects first and then acts: `mip` then the key for `:db-run` is the same thing. |
| `User DBExecutePre` / `DBExecutePost` events for other plugins | `dadbod-query!` takes a callback | **later**, with dadbod-ui: hooks in `api.scm` for "a run started / finished". The session already produces those as effects. |

### Choosing the database

| vim-dadbod | dadbod.hx | Verdict |
| --- | --- | --- |
| A URL given to the command | Same | **have** |
| `$DATABASE_URL` as the default | Same | **have** |
| The URL is remembered: `:DB g:db = url`, then `:DB` uses it | The URL given last is remembered for the session | **have**, in a simpler form |
| Scoped defaults `w:db`, `t:db`, `b:db`, `g:db`: a database per window, tab, buffer | One URL for the whole session | **next**, as a database per buffer. `:db-use <url>` for this buffer, falling back to the session's. Without it, two SQL files for two databases mean retyping URLs, or running against the wrong one. Helix has no buffer variables, so dadbod keeps a table from document to URL. Per window or tab: **no**. |
| Named URLs: `:DB g:prod = url`, then `:DB g:prod …` | Nothing | **next**. Named connections: `:db-run prod`, defined in `init.scm` or a file. Also what dadbod-ui's drawer lists, so it belongs in dadbod and `api.scm`. The password question decides the design: names should be able to point at an environment variable or a command (`pass`, `passage`), so that no password sits in a file. |
| Project configuration through other plugins (rails.vim, heroku.vim) and `.env` files (dotenv.vim) | `$DATABASE_URL` from the shell, e.g. through direnv | **maybe**. Reading `DATABASE_URL` from a `.env` in the workspace is small. direnv already does it for people who use it; a per-project connections file (above) covers the rest. |
| Completion at the prompt: URL schemes, database names, table names | Nothing | **no**: a Steel command can't offer completions for its arguments. A picker of named connections does the useful part. |
| Asks for the password when the client reports an authentication failure | The client's error is shown | **no**: Helix's prompt can't hide what is typed. `~/.pgpass` and `~/.my.cnf` are the better answer anyway. |

### URLs and adapters

| vim-dadbod | dadbod.hx | Verdict |
| --- | --- | --- |
| `adapter://user:password@host:port/database`, `adapter:database`, percent-encoding | Same shapes; stricter: a URL that could be read two ways is an error | **have** |
| A database file's path as the URL (`~/db.sqlite3`) | `sqlite:` in front | **maybe**. Convenient, and one more way to guess wrong. |
| Query parameters: PostgreSQL gets the whole URL, MySQL/MariaDB get each one as `--key=value`, SQLite drops them | PostgreSQL: passed on whole. MySQL/MariaDB, SQLite: refused | **next** for MySQL/MariaDB: `ssl-ca`, `ssl-cert`, `ssl-key`, `ssl-mode`, `protocol`, `login-path`, and a socket path, each mapped to its option. Without TLS options it can't reach many hosted databases. Unknown ones stay an error: ignoring `ssl-mode=REQUIRED` is the wrong default. |
| A unix socket as a percent-encoded host (`mysql://user@%2Fvar%2Frun%2Fmysqld.sock/db`) | PostgreSQL through `?host=/dir`; MySQL: nothing | **next**, with the item above. |
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
- A result that arrives while typing waits for normal mode.

## vim-dadbod-ui

None of this exists yet. The repository is laid out for it
([DESIGN.md](DESIGN.md)): `dadbod-ui.scm` and `dadbod-ui/`, using dadbod
through `dadbod/api.scm`.

**What `dadbod/api.scm` still lacks for it**, to add when the drawer needs
each: a handle for a run and a way to cancel it (a quiet query to a dead host
can't be stopped today); a notice when the database in use changes or a run
finishes; checking a URL without switching to it, and which adapter it
belongs to; a query that returns table output for a buffer of the UI's own.

**How it can be built.** The drawer is a buffer, the way oil.hx is: text in a
scratch buffer, redrawn from a model, with a keymap that only applies to that
buffer. That is a known-good pattern in this API. The model (the tree, what is
expanded, what each line means) is pure and goes in `dadbod-ui/core/`, tested
like dadbod's; only drawing and keys touch Helix.

| vim-dadbod-ui | Needs from dadbod | Verdict |
| --- | --- | --- |
| A drawer listing connections, toggled by a command | Named connections | **next for the UI**: the first slice. Connections, expand and collapse, open a query buffer for one. |
| Connections from an environment variable, from configuration, from a saved file (`:DBUIAddConnection`) | Named connections, with passwords kept out of files | **next**, with the drawer. Adding one from inside Helix needs a prompt; editing the file is enough to start. |
| Schemas and tables under each connection | `dadbod-query!` (there), and per adapter the query that lists them (new fields on the adapter record) | **next**, second slice. This is what `'plain` output and `dadbod-query!` are for. |
| Table helpers: List, Columns, Indexes, Foreign Keys, Primary Keys (PostgreSQL also References), and your own | The helper queries per adapter | **next**, with tables. They are SQL templates with `{table}`, `{schema}`, `{dbname}` and a few more. |
| A query buffer per connection; `:w` runs it (on by default there) | A database per buffer; a hook on save (Helix has `document-saved`) | **next**. Depends on "a database per buffer" in dadbod. Running on save should be an option, off by default here: saving and running are different intentions. |
| Saved queries per connection, listed in the drawer; rename, delete | Files in a directory | **later**. Straightforward once the drawer exists. |
| Async execution with a progress notice | dadbod has it | **have**, through dadbod |
| Connection details, last query time | Run events in `api.scm` | **later** |
| Bind parameters (`:name` in a query, asked for at run time) | A prompt | **maybe**. Useful, and a prompt per parameter is clumsy; editing the query is the Helix-like answer. |
| Jump to the row a foreign key points at, from a result | Parsing result tables | **maybe**. Fragile: it reads the client's table output. |
| Toggle a result between table and expanded layout | A second output mode per adapter | **maybe**. `\x` in the query does it for PostgreSQL today. |
| Icons, drawer width, help text, notifications | — | **later**: configuration, after the behaviour. |
| Completion of tables and columns (vim-dadbod-completion) | — | **no**. Not possible from a plugin as far as is known, and an SQL language server (`sqls`, `postgres-language-server`) is the right tool: Helix supports those natively. |

## Suggested order

1. **A database per buffer** and **named connections** (dadbod). Both are
   needed by daily use and by the UI, and they decide how passwords are
   kept out of files.
2. **Result window keys** (rerun, cancel, close) and **a query at the
   prompt**. Small, and they make the plugin comfortable.
3. **MySQL/MariaDB parameters and sockets.** Needed for hosted databases.
4. **dadbod-ui, first slice**: the drawer with connections and query
   buffers. Then tables and helpers, which add the per-adapter fields.
5. The **maybe** items as they are asked for.

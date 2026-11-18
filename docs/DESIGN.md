# Design

How the repository is put together and why. Read this before changing the
structure; [HELIX-API.md](HELIX-API.md) before touching `hx/editor.scm`;
[FEATURES.md](FEATURES.md) for what is planned.

## One package, two plugins

```
cog.scm               the Steel package `dadbod`: this whole repository
dadbod.scm            plugin 1: its typed commands, and nothing else
dadbod/               plugin 1: what the commands do
  api.scm             what other plugins may use
  core/               no Helix
  hx/                 Helix
dadbod-ui.scm         plugin 2 (not written yet): its typed commands
dadbod-ui/            plugin 2: what they do
tests/  docs/  dev/
```

`dadbod` and `dadbod-ui` are separate plugins the way vim-dadbod and
vim-dadbod-ui are: each is loaded by its own line in `init.scm`, each works
without the other being loaded (dadbod-ui needs dadbod installed, not
required by the user), and dadbod knows nothing of dadbod-ui.

```scheme
(require "dadbod/dadbod.scm")       ; :db-run, :db-cancel
(require "dadbod/dadbod-ui.scm")    ; the drawer, once it exists
```

They share a repository and a package because `forge pkg install --git` can
only install a repository's root: a second package in a subdirectory could
not be installed that way. If dadbod-ui ever needs its own repository,
moving `dadbod-ui.scm` and `dadbod-ui/` out is all there is to it, because of
the rule below.

**dadbod-ui uses dadbod through `dadbod/api.scm` only.** That file is the
contract between the two: change anything else in dadbod freely, change
`api.scm` with dadbod-ui in mind. Steel identifies a module by its real path,
so both plugins get the same dadbod: the database chosen in the drawer is the
one `:db-run` runs against. (Two copies on disk are two dadbods: an installed
package next to a checkout loaded by its `.helix/init.scm`, say.) `tests/fixtures/api-consumer` is a small second
plugin that the end-to-end suite uses to hold `api.scm` to that.

## Entry files provide commands only

Whatever a file required from `init.scm` provides becomes a typed command in
Helix. So `dadbod.scm` provides `db-run` and `db-cancel`, with their `;;@doc`
comments (Helix shows them), and nothing else. A helper provided from there
by accident would be a command.

## `core/` and `hx/`

`core/` runs without Helix: plain Steel, tested with the `steel` interpreter
in about a second. `hx/` is what needs the editor, and is tested by driving a
real Helix, which takes a minute.

So far the bugs have all been on the Helix side. The first version's pure
modules were right almost as written; the status line being overwritten and
insert mode being ended by an arriving result were not found until the
end-to-end tests and a review. Hence: **as much as possible in `core/`, as
little as possible in `hx/`.**

| | |
| --- | --- |
| `core/url.scm` | Database URLs. Ambiguous input is an error, not a guess; errors never quote the URL. |
| `core/adapter.scm` | What an adapter is (`adapter`, `invocation`) and the rules all of them keep. |
| `core/adapters/*.scm` | One file per database. |
| `core/adapters.scm` | The registry. |
| `core/job.scm` | The client as a child process: run, wait, signal. |
| `core/result.scm` | A whole run into files, for a person (`run-to-result!`) or a program (`run-to-files!`). |
| `core/session.scm` | The state of a Helix session and what each event does to it. Pure. |
| `core/system.scm` | Files, environment, clock. |
| `hx/editor.scm` | The editor, as dadbod needs it. The only file that requires Helix modules. |
| `hx/commands.scm` | Holds the state, carries out the effects, runs the worker thread. |

### The rules, and what checks them

`tests/lint.sh` (run by `tests/unit.sh`) fails when:

1. a file other than an `hx/editor.scm` requires a Helix module;
2. a file in `core/` requires from `hx/`;
3. dadbod requires dadbod-ui, or dadbod-ui requires from dadbod anything but
   `api.scm`.

### `hx/editor.scm` is the only door to Helix

The plugin API exists only in an unmerged fork and will change. Every other
file asks `editor.scm` for what it needs in dadbod's terms (`selection-text`,
`show-in-split!`, `run-when-normal!`), so an API change is fixed in one file.
dadbod-ui gets its own `dadbod-ui/hx/editor.scm` for what a drawer needs.

### The session is a pure state machine

`core/session.scm` holds no state. Each function takes the session and what
happened and returns a `step`: the session afterwards and a list of effects,
as data (`(status "…")`, `(show 3)`, `(signal 3 "INT" "…")`).
`hx/commands.scm` keeps the one current session and carries the effects out.

That puts the decisions with real interleavings in them under unit tests:
which run a cancel hits, how it escalates, what a run that finishes after
being cancelled reports, runs finishing in any order. New user-visible
behaviour goes there first, with its tests; `commands.scm` only grows when
there is a new kind of effect.

## Adapters

An adapter is a record: a name, its URL schemes, and a function from a parsed
URL and an output mode to an `invocation` (client program candidates,
arguments, environment). The query always goes to the client on stdin.

- `'table` mode is for a person (`:db-run`); `'plain` is for a program
  (`dadbod-query!`): one row per line, no headers.
- The rules every adapter keeps are in `core/adapter.scm`, and
  `tests/unit/adapters.scm` checks them for each registered adapter from one
  table of sample URLs. An adapter without a row there fails the test, so
  the contract can't be skipped.

Adding a database: the three steps at the top of `core/adapters.scm`. When
dadbod-ui needs per-database knowledge (how to list tables, the table
helpers), it becomes more fields of the adapter record, not a second place
that knows about databases.

## Processes

- **Files, not pipes,** for the client's stdin, stdout and stderr. Nothing
  has to be read while it runs, so nothing can deadlock on a full pipe.
- **Bytes, not strings,** for its output. A Steel string must be UTF-8; a
  database can hold anything. stdout goes straight to its file, stderr is
  copied as bytes.
- **A pid file.** Steel gives no process id for a child and its `wait` holds
  the child until it exits, so a running client can't be killed through its
  handle. The client is started through `sh -c 'echo $$ > pidfile && exec
  "$@"'`: the shell records its pid and becomes the client. `signal-client!`
  reads the pid and runs `kill`.
- **Cancel is SIGINT first.** `psql`, `mysql`/`mariadb` and `sqlite3` all
  answer it by having the database cancel the statement and exiting with what
  they had (tried by hand once: after SIGTERM, PostgreSQL and MariaDB went on
  running the query with nobody listening; the end-to-end suite checks the
  SIGINT side). SIGTERM, then SIGKILL, are for a client that
  doesn't stop. A cancel that arrives before the client has set up its
  handler (it is still connecting) simply ends the client; one that arrives
  before the pid file exists is retried for a second.
- **A worker thread per run** waits for the client. It touches no state; it
  returns to the main thread with the outcome.
- **A run keeps the directory it started in.** The session's directory can
  be replaced while a run is going (see below), so each run's files are
  looked up where it started.
- **Helper processes are piped too.** `kill` and `mktemp` would otherwise
  print their errors onto Helix's screen.

## Files and secrets

- Query and result files live in a directory made by `mktemp -d`, under
  `XDG_RUNTIME_DIR` when there is one.
- The password is taken out of the URL when it is parsed. Only the
  password-free forms go into arguments (`db-url-without-password`) and onto
  the screen (`db-url-display`); the password itself goes to the client's
  environment.
- An adapter refuses what it doesn't understand instead of dropping it.

## Tests

| | needs | covers |
| --- | --- | --- |
| `tests/lint.sh`, `tests/lint-test.sh` | grep | the boundaries above, and that the lint catches each way of breaking them |
| `tests/unit/*.scm` | `steel` | `core/`, with `sh` standing in for a client (`system.scm` only through the others) |
| `tests/e2e/*.sh` | Helix, tmux, the database servers | the commands, in a real Helix, against real databases; `api.sh` covers the package install and `api.scm` |

A change in `core/` comes with unit tests. A change in `hx/` comes with an
end-to-end check, because nothing else exercises it. The end-to-end suite
runs Helix in a tmux server of its own with a scratch `HOME`; keep it that
way (`tests/e2e/lib.sh`).

## The pinned Helix

`devenv.yaml` pins the Helix fork and Steel by commit, and `devenv.nix`
refuses to build when Steel isn't the one that Helix was built with. The dev
shell's `hx` is therefore the one the suite last passed on.

Moving to a newer fork commit:

1. change the `helix-steel` commit in `devenv.yaml` (and `steel` to the commit
   the build error names, if it complains);
2. `devenv test`;
3. fix `dadbod/hx/editor.scm`, and note what changed in `HELIX-API.md`.

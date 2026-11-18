# dadbod-ui

A drawer of your databases for [dadbod.hx](../README.md), in the manner of
[vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui):
connections, their tables, ready-made queries about a table, and saved
queries.

It is a plugin of its own, loaded by its own line in `init.scm`, after
dadbod's:

```scheme
(require "dadbod/dadbod.scm")
(require "dadbod/dadbod-ui.scm")
```

## Usage

`:dbui` opens the drawer, floating over the editor the way Helix's pickers
do:

```
╭─ dadbod-ui ──────────────────────────────────────╮
│▾ shop
│    + New query
│  ▾ Saved queries (2)
│      monthly-report.sql
│      query-1.sql
│  ▾ Tables (3)
│    ▸ authors
│    ▾ books
│        List
│        Columns
│        Indexes
│        Primary Key
│        Foreign Keys
│▸ staging
│▸ current database  postgres://app@localhost/shop
╰─ ? help   ret open   q close ────────────────────╯
```

It lists your [connections](../README.md#connections), `DB_UI_<NAME>`
environment variables among them, and after them the
database dadbod is using when that isn't one of them (a URL you gave to
`:db-run`, or `$DATABASE_URL`).

| Key | |
| --- | --- |
| `j`, `k` | Move down and up. Also the arrow keys, `g` for the first line and `G` for the last. |
| `ret`, `o`, `l` | Open or close what is under the cursor. On **New query**, a saved query or a helper: open it, which closes the drawer. |
| `R` | Ask the database under the cursor for its tables again, and reread its saved queries. |
| `A` | Add a connection: type its name, a space, and its URL (or `$VARIABLE`, or `!command`). It is written to `~/.config/helix/dadbod-connections`. What you type is visible and the file is plain text, so a URL with a password in it is refused, and so is one dadbod can't read as a URL. |
| `d` | Delete the saved query under the cursor, after asking. |
| `?` | Show or hide these keys. |
| `q`, `esc` | Close the drawer. `:dbui` brings it back as you left it. |

While it is open the drawer gets every key, and your buffers stay as they
are underneath. It floats rather than sitting beside them because Helix
can't give a split a width: a side panel would take half the screen.

- **Tables** are asked from the database the first time the section is
  opened. If it can't be reached, the reason is shown in their place. More
  than 5000 are not listed.
- **`[project]`** after a connection means it comes from the repository's
  `.helix/dadbod-connections`, not from you.
- **A table's helpers** are ready-made queries: its rows (`List`, the first
  200), its columns, indexes and keys. Choosing one opens the query in a
  buffer and runs it.
- **New query** makes a file `query-N.sql` for that database and opens it.
  A query file runs against the database whose folder it is in: `:db-run`
  needs no name there, however the file was opened. To keep one under a
  better name, rename it inside its folder, with Helix's `:move` and the
  full path: `:move ~/.local/share/dadbod-ui/shop/monthly-report.sql`. (A
  bare name would move it to Helix's working directory, out of the drawer.)

Query files are kept per database in `~/.local/share/dadbod-ui/<name>/`
(`$XDG_DATA_HOME/dadbod-ui`). Every `.sql` file there is a saved query of
that database; you can put files there yourself. A database that isn't a
connection (the "current database" entry) shares one folder,
`current_database`, whichever database that is at the time.

## Options

In `init.scm`:

```scheme
(require "dadbod/dadbod-ui/config.scm")
(dadbod-ui-set! 'execute-on-save #t)
```

| | Default | |
| --- | --- | --- |
| `'execute-on-save` | `#f` | Saving one of dadbod-ui's query files runs it. |
| `'run-helpers` | `#t` | Choosing a table's helper runs it right away. With `#f` it only opens the query. |

## Not there

What vim-dadbod-ui has and this doesn't is listed, with reasons, in
[docs/FEATURES.md](../docs/FEATURES.md#vim-dadbod-ui): bind parameters,
jumping along foreign keys from a result, your own table helpers, schemas as
a level of their own (tables outside the default schema are listed as
`schema.table`), icons.

## How it fits in the repository

See [docs/DESIGN.md](../docs/DESIGN.md).

```
dadbod-ui.scm         at the repository's root: its typed commands, only them
dadbod-ui/
  config.scm          the options, for init.scm
  core/drawer.scm     the drawer's model: no Helix, unit-tested
  core/store.scm      where query files are kept
  hx/editor.scm       the only file here that requires Helix modules
  hx/drawer.scm       the drawer in Helix
```

It uses dadbod through `../dadbod/api.scm` and nothing else of dadbod, and
dadbod never requires anything from here; `tests/lint.sh` checks both.

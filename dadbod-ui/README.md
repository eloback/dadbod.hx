# dadbod-ui

Not written yet. This directory is where the companion plugin goes: a drawer
of connections, tables and saved queries, in the manner of
[vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui). What it
should do, and in which order, is in
[docs/FEATURES.md](../docs/FEATURES.md#vim-dadbod-ui).

It is a plugin of its own, loaded by its own line in `init.scm`:

```scheme
(require "dadbod/dadbod.scm")       ; dadbod: :db-run, :db-cancel
(require "dadbod/dadbod-ui.scm")    ; dadbod-ui
```

How it fits in the repository ([docs/DESIGN.md](../docs/DESIGN.md)):

```
dadbod-ui.scm         at the repository's root: its typed commands, only them
dadbod-ui/
  core/               the drawer's model: no Helix, unit-tested
  hx/editor.scm       the only file here that requires Helix modules
  hx/…                drawing the drawer, its keys
```

The rules, checked by `tests/lint.sh` from the first file on:

- it uses dadbod through `../dadbod/api.scm` and nothing else of dadbod;
- dadbod never requires anything from here;
- only `hx/editor.scm` requires Helix modules.

`tests/fixtures/api-consumer` is a tiny plugin that already uses dadbod this
way, and `tests/e2e/api.sh` runs it: start from there.

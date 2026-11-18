# Notes on Helix's Steel API

What building this plugin taught about the plugin API of
[mattwparas's fork](https://github.com/mattwparas/helix/blob/steel-event-system/STEEL.md),
at the commit pinned in `devenv.yaml`. The API is not stable: treat each line
as "true at that commit", and correct it here when a newer one differs.

Where to look things up: the fork's `STEEL.md` and `steel-docs.md`, and the
Scheme side of the bindings in `helix-term/src/commands/engine/steel/*.scm`
(the Rust side is `mod.rs` next to them).

## Commands

- **Whatever `init.scm` has in scope is a typed command.** A function
  provided by a file that `init.scm` requires becomes `:its-name`. So an
  entry file provides commands and nothing else.
- **Arguments** arrive as strings, split on whitespace: `(define (cmd . args))`.
  `%` is not expanded, so a percent-encoded URL comes through. Quotes are
  not safe to rely on.
- **The return value goes to the status line** unless it is `void`. A command
  that sets a status itself must return `void`, or its own message is
  replaced by the printed return value (this hid "running…" behind a thread
  handle).
- **`;;@doc` comments** above the definition are the command's description.
- **An error raised by a command** typed at the prompt goes to the status
  line and also opens a popup with the backtrace; from a key binding, the
  status line only. For a one-line message and no popup, catch it and call
  `set-error!`.
- **Steel puts a space in front of an error's message**: trim
  `(error-object-message err)` before showing it.

## The editor

- **Moving the focus puts Helix in normal mode.** `editor-set-focus!`, and
  commands that open a window (`helix.hsplit`), end insert mode. Doing that
  from a callback while the user types turns their next keys into commands.
  Check `(equal? (editor-mode) (string->editor-mode "normal"))` first and
  wait otherwise (`run-when-normal!`).
- **`current-highlighted-text!` is the primary selection.**
  `current-selection->string`, despite the name, is the single character
  under the cursor.
- **There is always a selection**: the cursor is a selection one character
  wide. "Nothing selected" has to be decided by the plugin.
- **`editor-doc-in-view?` returns the view** showing the document, or `#f`;
  not a boolean.
- **`editor-document->path`** is `#f` for a scratch buffer.
- **`editor-document-reload`** reloads a document that isn't focused.
- **An unnamed scratch buffer with text in it counts as modified** and gets
  in the way of `:q` (one named with `set-scratch-buffer-name!` doesn't). A
  real file never does, which is one reason results are files.
- **`equal?` works on modes** and on document and view ids.
- **Typed commands are callable**: `(require (prefix-in helix.
  "helix/commands.scm"))`, then `(helix.hsplit path)`, `(helix.goto-line 1)`.
  They run synchronously: the focus is on the new window when `hsplit`
  returns.

## Threads and time

- **The editor belongs to the main thread.** `(spawn-native-thread thunk)`
  runs a thunk elsewhere; from there `(hx.with-context thunk)` (in
  `helix/ext.scm`) queues a thunk onto the main thread without waiting for
  it. The worker here captures structs, strings and closures and that works;
  nothing else has been tried.
- **Keep state on the main thread.** Nothing here locks.
- **`enqueue-thread-local-callback-with-delay ms thunk`** is a timer on the
  main thread; polling with it is how fresco.hx and `run-when-normal!` wait.
- **A blocking call on the main thread freezes Helix**, including `wait` on a
  process.

## Processes and files (Steel, not Helix)

- `command`, `with-env-var`, `with-stdin` / `with-stdout` / `with-stderr`
  (file ports), `spawn-process`, `wait` (a `Result` of the exit code, `#f`
  when killed by a signal), `which`.
- **No pid, no kill while waiting**: `wait` holds the child, so `kill` on the
  same handle can't run meanwhile. Hence the pid file in `core/job.scm`.
- `wait->stdout` throws stderr and the exit code away.
- **A child inherits Helix's terminal** for every stream that isn't
  redirected or piped: whatever it prints lands in the middle of the screen.
  Pipe or redirect all of them (`with-stdout-piped`, `with-stderr-piped`).
- `open-output-file path #:exists 'truncate | 'append | 'error`.
- `read-port-to-string` raises on bytes that aren't UTF-8; use
  `read-port-to-bytes` and `write-bytes` for anything a program wrote.
- `rename-file-or-directory!`, `delete-file!`, `delete-directory!`,
  `create-directory!`, `canonicalize-path`, `is-dir?`, `path-exists?`,
  `read-dir`.
- There is no temporary-directory function; `mktemp -d` through `command`.
- `(require-builtin steel/time)` for `current-milliseconds` and
  `time/sleep-ms`.

## Modules and packages

- **A module is identified by its real path.** Required through a relative
  path, a package name, `..` or a symlink, it is loaded once and its state is
  shared.
- **`require` paths are relative to the requiring file.** A name that isn't
  found that way is looked up in `$STEEL_HOME/cogs`, then in
  `STEEL_SEARCH_PATHS` and Helix's config and runtime directories. Built-in
  module names (`helix/…`, `steel/…`) win over all of them.
- **`$STEEL_HOME`** defaults to `~/.steel` when that directory exists, and
  otherwise to `~/.local/share/steel`.
- **A name that isn't defined is a compile error for the whole file**, not a
  runtime error at the call.
- **`(provide)` with nothing in it is an error.**
- **`forge pkg install --git <url>` installs the repository's root** and
  copies everything in it. It has no option for a subdirectory. `forge
  install` in a working checkout failed here once, copying devenv's state
  directory (it holds sockets).
- **A dylib is loaded only from `$STEEL_HOME/native`**, and a dylib built
  against another Steel can crash Helix at startup. This plugin has none, on
  purpose.

## Configuration

- **Project-local Steel config**: with both `.helix/init.scm` and
  `.helix/helix.scm` in the workspace, Helix loads them *instead of* the ones
  in `~/.config/helix`. `HELIX_STEEL_CONFIG=<dir>` overrides both.
- **Workspace trust** (`:workspace-trust`) gates language servers and
  `.helix/languages.toml`, and shows `[⚠]` until given. It does **not** gate
  the project-local Steel config: opening Helix in a repository with those
  two files runs their code.
- **Per-buffer keymaps** exist (`set-global-buffer-or-extension-keymap`): by
  file extension, or by a label the plugin ties to a document (oil.hx does
  that for its buffer). The extension wins when both apply. Not used here
  yet; it is what the result buffer's keys and the dadbod-ui drawer need.

## What it can't do

Read from the fork's source, not tried:

- **No completion of a Steel command's arguments** at the `:` prompt: only
  the command's name completes, and there is nothing to register a completer
  with.
- **`prompt` can't hide what is typed.** (It is a global, not part of
  `helix/components.scm`.) So no password prompt.

## Not verified

- How the component API behaves for a docked panel, as opposed to a buffer.

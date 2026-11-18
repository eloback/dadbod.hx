#!/usr/bin/env bash
# Checks the lint itself: on copies of the plugin with one rule broken each,
# tests/lint.sh has to fail, and on allowed forms it has to pass.

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dadbod-lint.XXXXXX")
trap '[[ -d $WORK ]] && rm -rf -- "$WORK"' EXIT

failed=0

# A fresh copy of the plugin's files, with a dadbod-ui to break rules in.
fresh() {
  [[ -d $WORK/repo ]] && rm -rf -- "$WORK/repo"
  mkdir -p "$WORK/repo/dadbod-ui/core" "$WORK/repo/dadbod-ui/hx"
  cp -r "$ROOT/dadbod" "$ROOT/dadbod.scm" "$WORK/repo/"
  echo '(require "dadbod-ui/hx/drawer.scm")' >"$WORK/repo/dadbod-ui.scm"
  echo '(require "../../dadbod/api.scm")' >"$WORK/repo/dadbod-ui/hx/drawer.scm"
  echo '(require "helix/misc.scm")' >"$WORK/repo/dadbod-ui/hx/editor.scm"
  echo '(define model 1)' >"$WORK/repo/dadbod-ui/core/model.scm"
}

# check <pass|fail> <description> <file in the copy> <text to append>
check() {
  fresh
  if [[ -n ${3:-} ]]; then
    printf '%s\n' "$4" >>"$WORK/repo/$3"
  fi
  local result=pass
  "$ROOT/tests/lint.sh" "$WORK/repo" >/dev/null 2>&1 || result=fail
  if [[ $result == "$1" ]]; then
    echo "ok: lint: $2"
  else
    echo "FAIL: lint: $2 (expected the lint to $1)" >&2
    failed=1
  fi
}

check pass "the plugin as it is, with a well-behaved dadbod-ui"
check pass "dadbod-ui may name dadbod's api by its package path" dadbod-ui/hx/drawer.scm '(require "dadbod/dadbod/api.scm")'
check pass "a Helix module named in a comment is not a require" dadbod/core/url.scm ';; see "helix/misc.scm"'

check fail "core/ requiring a Helix module" dadbod/core/url.scm '(require "helix/misc.scm")'
check fail "a require split over two lines" dadbod/core/url.scm $'(require\n  "helix/misc.scm")'
check fail "a prefixed require split over two lines" dadbod/hx/commands.scm $'(require (prefix-in helix.\n  "helix/commands.scm"))'
check fail "a Helix builtin module" dadbod/core/url.scm '(require-builtin helix/core/text as text.)'
check fail "the entry file requiring a Helix module" dadbod.scm '(require "helix/misc.scm")'
check fail "an editor.scm that isn't the plugin's own" dadbod/core/editor.scm '(require "helix/misc.scm")'
check fail "core/ requiring from hx/" dadbod/core/url.scm '(require "../hx/commands.scm")'
check fail "core/ requiring the api" dadbod/core/url.scm '(require "../api.scm")'
check fail "dadbod requiring dadbod-ui" dadbod/hx/commands.scm '(require "../../dadbod-ui/core/model.scm")'
check fail "dadbod's entry requiring dadbod-ui's" dadbod.scm '(require "dadbod-ui.scm")'
check fail "dadbod-ui reaching into dadbod's core" dadbod-ui/hx/drawer.scm '(require "../../dadbod/core/url.scm")'
check fail "dadbod-ui requiring dadbod's entry file" dadbod-ui/hx/drawer.scm '(require "../../dadbod.scm")'
check fail "two modules in one require, one of them not allowed" dadbod-ui/hx/drawer.scm '(require "../../dadbod/api.scm" "../../dadbod/core/url.scm")'
check fail "dadbod-ui's core requiring a Helix module" dadbod-ui/core/model.scm '(require "helix/misc.scm")'

if ((failed)); then
  exit 1
fi

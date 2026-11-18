#!/usr/bin/env bash
# The checks that need no Helix: the boundary lint, then every unit test file.
#
#   tests/unit.sh            (or `test-unit` in the devenv shell)
#   tests/unit.sh session    only tests/unit/session.scm
#
# Needs `steel`. Exits non-zero when anything fails.

set -euo pipefail
cd "$(dirname "$0")/.."

command -v steel >/dev/null || {
  echo "unit: 'steel' is not on PATH" >&2
  exit 1
}

if (($# == 0)); then
  tests/lint.sh
  tests/lint-test.sh
  set -- url adapters connections job result session drawer
fi

failed=()
for name in "$@"; do
  echo "== $name"
  if ! steel "tests/unit/$name.scm"; then
    failed+=("$name")
  fi
done

if ((${#failed[@]})); then
  echo "unit: FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "unit: all passed"

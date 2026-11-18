#!/usr/bin/env bash
# End-to-end test: drives the commands in a real Helix against temporary
# databases.
#
#   tests/e2e.sh                  (or `test-e2e` in the devenv shell)
#   tests/e2e.sh sqlite api       only those parts (tests/e2e/<part>.sh)
#
# Helix runs in its own tmux server (own socket, no config) with a scratch
# HOME, so nothing of yours is touched. It needs the Steel-enabled `hx`, tmux
# and sqlite3. The PostgreSQL and MariaDB parts run when their server
# binaries are on PATH (they are in the devenv shell) and are skipped
# otherwise.
#
# E2E_KEEP=1 keeps the work directory, to look at what a failed run left.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# shellcheck source=tests/e2e/lib.sh
source "$ROOT/tests/e2e/lib.sh"

if (($# == 0)); then
  set -- sqlite api postgres mariadb
fi

for part in "$@"; do
  # shellcheck disable=SC1090
  source "$ROOT/tests/e2e/$part.sh"
done

echo
echo "e2e: $passed checks passed"

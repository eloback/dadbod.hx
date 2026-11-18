#!/usr/bin/env bash
# The boundaries docs/DESIGN.md describes, checked mechanically.
#
#   1. Only dadbod/hx/editor.scm and dadbod-ui/hx/editor.scm talk to Helix:
#      every other file reaches the editor through them, so a change in the
#      fork's API lands in one file.
#   2. core/ doesn't depend on hx/, on api.scm or on an entry file: what is
#      in core/ runs, and is tested, without Helix.
#   3. dadbod doesn't depend on dadbod-ui.
#   4. dadbod-ui uses dadbod only through dadbod/api.scm.
#
# It looks at the modules a file names, wherever in the file: every quoted
# string ending in .scm outside comments, and every `require-builtin`. So a
# require written over several lines, or naming several files, is seen too.
#
#   tests/lint.sh           check the repository
#   tests/lint.sh <dir>     check a copy of it (tests/lint-test.sh)

set -euo pipefail
cd "${1:-$(dirname "$0")/..}"

failed=0
complain() {
  echo "lint: $1" >&2
  failed=1
}

# The Scheme files of a plugin: its entry file and its directory.
files_of() {
  [[ -f $1.scm ]] && echo "$1.scm"
  [[ -d $1 ]] && find "$1" -name '*.scm'
  return 0
}

# The modules a file names, one per line.
modules_of() {
  sed 's/;.*//' "$1" | grep -oE '"[^"]*\.scm"' | tr -d '"' || true
  sed 's/;.*//' "$1" | tr '\n' ' ' | grep -oE 'require-builtin +[^ )]+' | sed -E 's/require-builtin +//' || true
}

while read -r file; do
  modules=$(modules_of "$file")

  # 1
  case "$file" in
    dadbod/hx/editor.scm | dadbod-ui/hx/editor.scm) ;;
    *)
      found=$(grep -E '^helix/' <<<"$modules" || true)
      [[ -z $found ]] || complain "$file uses Helix modules (only hx/editor.scm may): $(tr '\n' ' ' <<<"$found")"
      ;;
  esac

  # 2
  case "$file" in
    dadbod/core/* | dadbod-ui/core/*)
      found=$(grep -E '(^|/)hx/|(^|/)api\.scm$|(^|/)dadbod(-ui)?\.scm$' <<<"$modules" || true)
      [[ -z $found ]] || complain "$file is in core/ and reaches out of it: $(tr '\n' ' ' <<<"$found")"
      ;;
  esac

  case "$file" in
    # 3
    dadbod.scm | dadbod/*)
      found=$(grep -E 'dadbod-ui' <<<"$modules" || true)
      [[ -z $found ]] || complain "$file is part of dadbod and uses dadbod-ui: $(tr '\n' ' ' <<<"$found")"
      ;;
    # 4: what is left of a name once "dadbod-ui" is taken out still names
    # dadbod, and isn't its api.scm.
    dadbod-ui.scm | dadbod-ui/*)
      found=$(sed 's/dadbod-ui//g' <<<"$modules" | grep -E '(^|/)dadbod(/|\.scm$)' | grep -vE '(^|/)dadbod/api\.scm$' || true)
      [[ -z $found ]] || complain "$file is part of dadbod-ui and reaches into dadbod past api.scm: $(tr '\n' ' ' <<<"$found")"
      ;;
  esac
done < <(
  files_of dadbod
  files_of dadbod-ui
)

if ((failed)); then
  exit 1
fi
echo "lint: ok"

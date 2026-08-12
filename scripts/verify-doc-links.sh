#!/usr/bin/env bash
#
# Every relative markdown link must resolve to a real file. The docs cross-refer
# heavily (docs/02 → docs/05 → patches/README.md → …), so a renamed file breaks
# navigation silently.
#
# Only relative links are checked — external URLs are not fetched.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fails=0
checked=0

while IFS= read -r -d '' md; do
  dir=$(dirname "$md")

  # Pull the target out of every [text](target) on the page. Strips an #anchor
  # and a "title" suffix; skips absolute URLs, mailto:, and pure anchors.
  targets=$(grep -oE '\]\([^)]+\)' "$md" |
    sed -e 's/^](//' -e 's/)$//' -e 's/[[:space:]]\+".*$//' -e 's/#.*$//' |
    grep -vE '^(https?:|mailto:|$)' || true)

  [ -z "$targets" ] && continue

  while IFS= read -r target; do
    [ -z "$target" ] && continue
    checked=$((checked + 1))
    if [ ! -e "$dir/$target" ]; then
      printf '  \033[31m[FAIL]\033[0m %s → %s\n' "$md" "$target"
      fails=$((fails + 1))
    fi
  done <<<"$targets"
done < <(find . -name '*.md' -not -path './.git/*' -not -path './charts/*/charts/*' -print0)

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '\033[32m%d relative link(s) resolve\033[0m\n' "$checked"
else
  printf '\033[31m%d of %d link(s) broken\033[0m\n' "$fails" "$checked"
  exit 1
fi

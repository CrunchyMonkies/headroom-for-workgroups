#!/usr/bin/env bash
#
# Confirm every patch in patches/upstream.env still applies cleanly, in order,
# to the upstream commit pinned there.
#
# This is the check that detects a patch rotting. Nothing else would: the
# charts render fine, the image builds fine, and the failure only shows up at
# runtime — a memory subsystem that silently falls back to local SQLite, or a
# memory search that raises on every call.
#
#   scripts/verify-patch.sh              # apply to a throwaway tree, then discard
#   scripts/verify-patch.sh --keep       # leave the patched tree for inspection
#
# Requires network access.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# shellcheck source=../patches/upstream.env disable=SC1091
. patches/upstream.env

: "${HEADROOM_REPO:?not set in patches/upstream.env}"
: "${HEADROOM_BASE_COMMIT:?not set in patches/upstream.env}"
: "${HEADROOM_PATCHES:?not set in patches/upstream.env}"

# Deliberate word splitting: HEADROOM_PATCHES is a space-separated, ordered list.
# shellcheck disable=SC2206
PATCHES=($HEADROOM_PATCHES)
for p in "${PATCHES[@]}"; do
  [ -f "$REPO_ROOT/$p" ] || { echo "missing patch: $p" >&2; exit 1; }
done

WORK=$(mktemp -d)
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

printf '\n\033[1m── upstream\033[0m\n'
printf '  repo    %s\n  commit  %s\n' "$HEADROOM_REPO" "$HEADROOM_BASE_COMMIT"
for p in "${PATCHES[@]}"; do
  printf '  patch   %s (sha256 %s)\n' "$p" "$(sha256sum "$REPO_ROOT/$p" | cut -c1-16)"
done

# Fetch only the pinned commit — a full clone of upstream is not needed and the
# blob filter keeps this to seconds.
printf '\n\033[1m── fetching\033[0m\n'
git init -q "$WORK"
git -C "$WORK" remote add origin "https://github.com/${HEADROOM_REPO}.git"
if ! git -C "$WORK" fetch -q --depth 1 --filter=blob:none origin "$HEADROOM_BASE_COMMIT"; then
  echo "  could not fetch ${HEADROOM_BASE_COMMIT} from ${HEADROOM_REPO}" >&2
  echo "  (the commit may have been force-pushed away, or there is no network)" >&2
  exit 1
fi
git -C "$WORK" checkout -q FETCH_HEAD
printf '  ok\n'

# Applied for real, in order, rather than --check'd independently: patch N is
# generated against the tree with 1..N-1 already applied, so checking each one
# against pristine upstream would pass on patches that cannot actually stack.
printf '\n\033[1m── applying\033[0m\n'
for p in "${PATCHES[@]}"; do
  if git -C "$WORK" apply --3way "$REPO_ROOT/$p" 2>"$WORK/.err"; then
    printf '  \033[32m[ok]\033[0m   %s\n' "$p"
  else
    printf '  \033[31m[FAIL]\033[0m %s no longer applies to %s\n' "$p" "$HEADROOM_BASE_COMMIT"
    sed 's/^/        /' "$WORK/.err" >&2
    printf '\n  Re-base it: check out a newer upstream commit, re-apply by hand,\n'
    printf '  regenerate the patch, and bump HEADROOM_BASE_COMMIT in\n'
    printf '  patches/upstream.env. See docs/08-releasing.md.\n'
    exit 1
  fi
done

if [ "$KEEP" -eq 1 ]; then
  printf '\n  patched tree left at %s\n' "$WORK"
fi

printf '\n\033[32m%s patch(es) verified\033[0m\n' "${#PATCHES[@]}"

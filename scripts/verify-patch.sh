#!/usr/bin/env bash
#
# Confirm patches/0001 still applies cleanly to the upstream commit pinned in
# patches/upstream.env.
#
# This is the check that detects the patch rotting. Nothing else would: the
# charts render fine, the image builds fine, and the failure only shows up as a
# memory subsystem that silently falls back to local SQLite.
#
#   scripts/verify-patch.sh              # apply --check only (fast)
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
: "${HEADROOM_PATCH:?not set in patches/upstream.env}"

PATCH_ABS="$REPO_ROOT/$HEADROOM_PATCH"
[ -f "$PATCH_ABS" ] || { echo "missing patch: $HEADROOM_PATCH" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

printf '\n\033[1m── upstream\033[0m\n'
printf '  repo    %s\n  commit  %s\n  patch   %s (sha256 %s)\n' \
  "$HEADROOM_REPO" "$HEADROOM_BASE_COMMIT" "$HEADROOM_PATCH" \
  "$(sha256sum "$PATCH_ABS" | cut -c1-16)"

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

printf '\n\033[1m── applying\033[0m\n'
if git -C "$WORK" apply --3way --check "$PATCH_ABS" 2>"$WORK/.err"; then
  printf '  \033[32m[ok]\033[0m   patch applies cleanly\n'
else
  printf '  \033[31m[FAIL]\033[0m patch no longer applies to %s\n' "$HEADROOM_BASE_COMMIT"
  sed 's/^/        /' "$WORK/.err" >&2
  printf '\n  Re-base it: check out a newer upstream commit, re-apply by hand,\n'
  printf '  regenerate the patch, and bump HEADROOM_BASE_COMMIT in\n'
  printf '  patches/upstream.env. See docs/08-releasing.md.\n'
  exit 1
fi

if [ "$KEEP" -eq 1 ]; then
  git -C "$WORK" apply --3way "$PATCH_ABS"
  printf '\n  patched tree left at %s\n' "$WORK"
fi

printf '\n\033[32mpatch verified\033[0m\n'

#!/usr/bin/env bash
#
# Chart.yaml is the source of truth for the release version. Cutting a release
# means committing a version bump and then tagging it — CI never rewrites
# versions at package time, because that would silently desynchronise the
# umbrella's file:// dependency constraints from the charts they point at.
#
#   scripts/verify-versions.sh            # internal consistency only
#   scripts/verify-versions.sh v0.2.0     # also assert the tag matches
#
# See docs/08-releasing.md.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fails=0
ok()  { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fails=$((fails + 1)); }

# Top-level scalar out of a Chart.yaml, without needing yq.
chart_field() {
  local file=$1 key=$2
  grep -m1 "^${key}:" "$file" | sed -e "s/^${key}:[[:space:]]*//" -e 's/^"//' -e 's/"$//'
}

printf '\n\033[1m── chart versions\033[0m\n'

HR_VER=$(chart_field charts/headroom/Chart.yaml version)
IX_VER=$(chart_field charts/ix/Chart.yaml version)
WG_VER=$(chart_field charts/workgroup/Chart.yaml version)

printf '  headroom  %s\n  ix        %s\n  workgroup %s\n' "$HR_VER" "$IX_VER" "$WG_VER"

if [ "$HR_VER" = "$IX_VER" ] && [ "$IX_VER" = "$WG_VER" ]; then
  ok "all three charts agree"
else
  bad "chart versions disagree — they are released together and must match"
fi

# The umbrella pins each subchart. helm dependency update will happily vendor a
# stale copy if these drift, so they are part of the same fact.
printf '\n\033[1m── umbrella dependency pins\033[0m\n'
DEP_VERS=$(awk '/^dependencies:/{f=1; next} f && /^[[:space:]]+version:/{print $2}' \
  charts/workgroup/Chart.yaml)

if [ -z "$DEP_VERS" ]; then
  bad "found no dependency versions in charts/workgroup/Chart.yaml"
else
  while IFS= read -r dep; do
    if [ "$dep" = "$WG_VER" ]; then
      ok "dependency pinned at $dep"
    else
      bad "dependency pinned at $dep but the charts are $WG_VER"
    fi
  done <<<"$DEP_VERS"
fi

# image.tag defaults to .Chart.AppVersion, and release.yml tags the patched
# image with the release version — so a mismatch here publishes a chart that
# references an image tag nothing produced.
printf '\n\033[1m── headroom appVersion (drives the default image tag)\033[0m\n'
HR_APP=$(chart_field charts/headroom/Chart.yaml appVersion)
if [ "$HR_APP" = "$HR_VER" ]; then
  ok "appVersion $HR_APP tracks version $HR_VER"
else
  bad "appVersion is $HR_APP but version is $HR_VER"
fi

# ── optional: tag agreement ──────────────────────────────────────────────────

TAG=${1:-}
if [ -n "$TAG" ]; then
  printf '\n\033[1m── tag\033[0m\n'
  TAG_VER=${TAG#v}
  if [ "$TAG_VER" = "$WG_VER" ]; then
    ok "tag $TAG matches chart version $WG_VER"
  else
    bad "tag $TAG implies version $TAG_VER, but the charts say $WG_VER — bump Chart.yaml first"
  fi
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf '\033[32mversions consistent\033[0m\n'
else
  printf '\033[31m%d check(s) failed\033[0m\n' "$fails"
  exit 1
fi

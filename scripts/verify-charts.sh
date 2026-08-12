#!/usr/bin/env bash
#
# Chart verification. Run the whole thing locally with:
#
#   scripts/verify-charts.sh
#
# or one section at a time: lint | render | guards | schema
#
# CI (.github/workflows/ci.yml) calls the same sections, so a green run here is
# a green run there.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CHARTS=(charts/headroom charts/ix charts/workgroup)

# Gateway API is a CRD, so `helm template` cannot see it unless we say so. Every
# gateway-mode render needs this or it trips the chart's own capability guard.
GWAPI=(--api-versions gateway.networking.k8s.io/v1)

RENDER_DIR=""
fails=0

log()  { printf '\n\033[1m── %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  \033[33m[skip]\033[0m %s\n' "$*"; }

cleanup() { [ -n "$RENDER_DIR" ] && rm -rf "$RENDER_DIR"; }
trap cleanup EXIT

# ── deps ─────────────────────────────────────────────────────────────────────

need_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    echo "helm is required but not installed" >&2
    exit 127
  fi
}

# The umbrella's subcharts are file:// dependencies and must be vendored into
# charts/workgroup/charts/ before anything can render it.
build_deps() {
  helm dependency update charts/workgroup >/dev/null
}

# ── lint ─────────────────────────────────────────────────────────────────────

section_lint() {
  log "helm lint"
  for chart in "${CHARTS[@]}"; do
    if helm lint "$chart" >/dev/null 2>&1; then
      ok "$chart"
    else
      bad "$chart"
      helm lint "$chart" || true
    fi
  done
}

# ── render matrix ────────────────────────────────────────────────────────────

# render <name> <chart> [helm args...] — must succeed and emit non-empty YAML.
render() {
  local name=$1 chart=$2
  shift 2
  local out="$RENDER_DIR/${name}.yaml"
  if helm template rel "$chart" "$@" >"$out" 2>"$out.err"; then
    if [ -s "$out" ]; then
      ok "$name"
    else
      bad "$name (rendered empty)"
    fi
  else
    bad "$name"
    sed 's/^/        /' "$out.err"
  fi
}

section_render() {
  log "render matrix"
  RENDER_DIR="${RENDER_DIR:-$(mktemp -d)}"

  # headroom
  render hr-default charts/headroom
  render hr-ingress charts/headroom \
    --set expose.mode=ingress --set expose.host=headroom.example.com
  render hr-gateway charts/headroom "${GWAPI[@]}" \
    --set expose.mode=gateway --set expose.host=headroom.example.com \
    --set expose.gateway.parentRefs[0].name=gw \
    --set expose.gateway.parentRefs[0].namespace=gateway-system
  render hr-memory charts/headroom --set memory.enabled=true
  render hr-stateless charts/headroom --set stateless=true --set replicaCount=3
  render hr-external charts/headroom \
    --set memory.enabled=true \
    --set memory.qdrant.enabled=false \
    --set memory.qdrant.external.enabled=true \
    --set memory.qdrant.external.url=https://qdrant.example.com:6333 \
    --set memory.neo4j.enabled=false \
    --set memory.neo4j.external.enabled=true \
    --set memory.neo4j.external.uri=neo4j+s://db.example.com \
    --set memory.neo4j.auth.existingSecret=neo4j-creds

  # ix
  render ix-default charts/ix
  render ix-ingress-basic charts/ix \
    --set expose.mode=ingress --set expose.host=ix.example.com \
    --set auth.mode=basic --set auth.basic.existingSecret=ix-basic-auth
  render ix-gateway-oauth charts/ix "${GWAPI[@]}" \
    --set expose.mode=gateway --set expose.host=ix.example.com \
    --set expose.gateway.parentRefs[0].name=gw \
    --set auth.mode=oauth2Proxy \
    --set auth.oauth2Proxy.existingSecret=ix-oidc \
    --set auth.oauth2Proxy.oidcIssuerUrl=https://idp.example.com
  render ix-external charts/ix \
    --set arangodb.enabled=false \
    --set arangodb.external.enabled=true \
    --set arangodb.external.host=arango.example.com \
    --set arangodb.existingSecret=arango-creds

  # umbrella
  render wg-default charts/workgroup
  render wg-ingress charts/workgroup \
    --set global.expose.domain=dev.example.com \
    --set headroom.expose.mode=ingress \
    --set ix.expose.mode=ingress \
    --set ix.auth.mode=basic --set ix.auth.basic.existingSecret=ix-basic-auth
  render wg-gateway charts/workgroup "${GWAPI[@]}" \
    --set global.expose.domain=dev.example.com \
    --set global.expose.gatewayParentRefs[0].name=gw \
    --set headroom.expose.mode=gateway \
    --set ix.expose.mode=gateway \
    --set ix.auth.mode=oauth2Proxy \
    --set ix.auth.oauth2Proxy.existingSecret=ix-oidc \
    --set ix.auth.oauth2Proxy.oidcIssuerUrl=https://idp.example.com
}

# ── guard rails ──────────────────────────────────────────────────────────────

# expect_fail <expected substring> <chart> [helm args...]
#
# The charts validate at template time. These assert the refusal actually
# happens *and* that the message still says what the docs claim it says — a
# guard that fires with the wrong message is a documentation bug.
expect_fail() {
  local expect=$1 chart=$2
  shift 2
  local out
  if out=$(helm template rel "$chart" "$@" 2>&1); then
    bad "expected failure, but it rendered: $chart $*"
  elif printf '%s' "$out" | grep -qF -- "$expect"; then
    ok "$expect"
  else
    bad "failed, but not with the expected message: $expect"
    printf '%s\n' "$out" | sed 's/^/        /' | head -5
  fi
}

# expect_ok <label> <chart> [helm args...] — a guard that must NOT fire.
expect_ok() {
  local label=$1 chart=$2
  shift 2
  if helm template rel "$chart" "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    bad "$label"
    helm template rel "$chart" "$@" 2>&1 | sed 's/^/        /' | head -5
  fi
}

section_guards() {
  log "guard rails (each must refuse)"

  # -- headroom
  expect_fail 'headroom: expose.mode must be one of' charts/headroom \
    --set expose.mode=bogus
  expect_fail 'refusing to expose the proxy with auth.enabled=false' charts/headroom \
    --set expose.mode=ingress --set expose.host=h.example.com --set auth.enabled=false
  expect_fail 'expose.mode=ingress requires expose.host' charts/headroom \
    --set expose.mode=ingress
  expect_fail 'expose.mode=gateway requires expose.gateway.parentRefs' charts/headroom \
    --set expose.mode=gateway --set expose.host=h.example.com
  expect_fail 'requires the Gateway API' charts/headroom \
    --set expose.mode=gateway --set expose.host=h.example.com \
    --set expose.gateway.parentRefs[0].name=gw
  expect_fail 'published upstream image' charts/headroom \
    --set memory.enabled=true --set image.repository=ghcr.io/chopratejas/headroom
  expect_fail 'incompatible with stateless=true' charts/headroom \
    --set memory.enabled=true --set stateless=true
  expect_fail 'memory.qdrant.external.enabled=true requires' charts/headroom \
    --set memory.enabled=true --set memory.qdrant.external.enabled=true

  # -- ix
  expect_fail 'ix: expose.mode must be one of' charts/ix --set expose.mode=bogus
  expect_fail 'ix: auth.mode must be one of' charts/ix --set auth.mode=bogus
  expect_fail 'refusing to expose the memory-layer with auth.mode=none' charts/ix \
    --set expose.mode=ingress --set expose.host=i.example.com
  expect_fail 'no Gateway API equivalent' charts/ix "${GWAPI[@]}" \
    --set expose.mode=gateway --set expose.host=i.example.com \
    --set expose.gateway.parentRefs[0].name=gw --set auth.mode=basic
  expect_fail 'auth.mode=basic requires auth.basic.existingSecret' charts/ix \
    --set auth.mode=basic
  expect_fail 'auth.mode=oauth2Proxy requires auth.oauth2Proxy.existingSecret' charts/ix \
    --set auth.mode=oauth2Proxy
  expect_fail 'the memory-layer needs a database' charts/ix \
    --set arangodb.enabled=false

  # -- through the umbrella: the guards must propagate, not be swallowed
  expect_fail 'refusing to expose the memory-layer with auth.mode=none' charts/workgroup \
    --set global.expose.domain=dev.example.com --set ix.expose.mode=ingress

  log "guard rails (each must NOT fire)"
  # The chart default image is patched, so this is the one that flipped when
  # release.yml started publishing it. If it ever refuses again, the default
  # image.repository has drifted back to upstream.
  expect_ok 'memory.enabled=true on the default (patched) image' charts/headroom \
    --set memory.enabled=true
  expect_ok 'acknowledgeUnpatchedImage overrides the guard' charts/headroom \
    --set memory.enabled=true --set image.repository=ghcr.io/chopratejas/headroom \
    --set memory.acknowledgeUnpatchedImage=true
  expect_ok 'acknowledgeUnauthenticated overrides the ix guard' charts/ix \
    --set expose.mode=ingress --set expose.host=i.example.com \
    --set auth.acknowledgeUnauthenticated=true
}

# ── schema validation ────────────────────────────────────────────────────────

section_schema() {
  log "kubeconform"
  if ! command -v kubeconform >/dev/null 2>&1; then
    skip "kubeconform not installed — skipping strict schema validation"
    return
  fi
  if [ -z "$RENDER_DIR" ] || [ ! -d "$RENDER_DIR" ]; then
    skip "no rendered manifests (run the render section first)"
    return
  fi

  # Gateway API types are CRDs, so they need the community schema location.
  local crd_schema
  crd_schema='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

  local f
  for f in "$RENDER_DIR"/*.yaml; do
    if kubeconform -strict -summary -ignore-missing-schemas \
      -schema-location default -schema-location "$crd_schema" "$f" >/dev/null 2>&1; then
      ok "$(basename "$f")"
    else
      bad "$(basename "$f")"
      kubeconform -strict -schema-location default -schema-location "$crd_schema" "$f" 2>&1 |
        sed 's/^/        /' | head -10
    fi
  done
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  need_helm
  build_deps

  local section=${1:-all}
  case "$section" in
    lint)   section_lint ;;
    render) RENDER_DIR=$(mktemp -d); section_render ;;
    guards) section_guards ;;
    schema) RENDER_DIR=$(mktemp -d); section_render; section_schema ;;
    all)
      RENDER_DIR=$(mktemp -d)
      section_lint
      section_render
      section_guards
      section_schema
      ;;
    *)
      echo "usage: ${0##*/} [lint|render|guards|schema|all]" >&2
      exit 2
      ;;
  esac

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    printf '\033[32mall chart checks passed\033[0m\n'
  else
    printf '\033[31m%d check(s) failed\033[0m\n' "$fails"
    exit 1
  fi
}

main "$@"

# 2. Install the servers on Kubernetes

## Prerequisites

- Kubernetes 1.27+
- Helm 3.13+ (for `--dry-run=client`). Verified against Helm 4.0.
- A default StorageClass supporting `ReadWriteOnce` (both charts use PVCs)
- For `expose.mode: ingress` — an ingress controller. The chart's default
  annotations are nginx-flavoured; other controllers work but you will want to
  translate the timeout annotations (see [Exposure](#exposure)).
- For `expose.mode: gateway` — the Gateway API CRDs
  (`gateway.networking.k8s.io/v1`) and a Gateway to attach to. The charts check
  for this and fail rendering with a clear message if it is absent.
- For TLS — cert-manager, or a certificate Secret you create yourself.

Check what you have:

```sh
kubectl get storageclass
kubectl get ingressclass
kubectl api-resources | grep gateway.networking
```

---

## Install

### Both services together (recommended)

```sh
helm install wg oci://ghcr.io/crunchymonkies/charts/workgroup --version 0.1.3 \
  -n workgroup --create-namespace
```

Defaults: both services cluster-internal (`expose.mode: none`), Headroom
authenticated with a generated token, Ix backed by an ArangoDB with a generated
root password, NetworkPolicies on, Headroom semantic memory off.

`helm show values oci://ghcr.io/crunchymonkies/charts/workgroup --version 0.1.3`
prints the full values file without installing anything. Available versions are
listed on the [releases page](https://github.com/CrunchyMonkies/headroom-for-workgroups/releases);
the charts are published as OCI artefacts only, so there is no `helm repo add`
step.

### One at a time

```sh
helm install headroom oci://ghcr.io/crunchymonkies/charts/headroom --version 0.1.3 \
  -n workgroup --create-namespace
helm install ix       oci://ghcr.io/crunchymonkies/charts/ix       --version 0.1.3 \
  -n workgroup
```

The standalone charts are self-contained — the umbrella adds nothing but shared
hostname defaults.

### From a clone

Working from a checkout, or on a change you have not released yet:

```sh
helm dependency update charts/workgroup   # vendors the two local subcharts
helm install wg charts/workgroup -n workgroup --create-namespace
```

`helm dependency update` is only needed for the umbrella, and only from a
checkout — the published `workgroup` chart already carries both subcharts
inside it.

### Verify

```sh
kubectl -n workgroup get pods
kubectl -n workgroup port-forward svc/wg-headroom 8787:8787 &
curl -fsS http://127.0.0.1:8787/readyz

kubectl -n workgroup port-forward svc/wg-ix 8090:8090 &
curl -fsS http://127.0.0.1:8090/v1/health
```

Headroom's first start pulls compression models and can take a few minutes.
The startup probe allows five minutes by default
(`probes.startup.failureThreshold: 60` × 5s); the pod stays `0/1` until then,
which is expected, not a failure.

---

## Exposure

Both charts share one three-way toggle, so the umbrella can drive them
together.

```yaml
expose:
  mode: none          # none | ingress | gateway
  host: ""
  subdomain: headroom # used with the umbrella's global.expose.domain
  ingress:
    className: ""     # empty => global, else "nginx"
    annotations: {}
    tls:
      enabled: true
      secretName: ""  # empty => global, else "<release>-<chart>-tls"
  gateway:
    parentRefs: []    # [{name: my-gateway, namespace: gateway-system}]
    hostnames: []     # empty => [host]
```

### `none` — cluster-internal (the default)

ClusterIP only. Developers reach the services with `kubectl port-forward`.
This is the lowest-risk starting point and is a perfectly reasonable permanent
answer for a small team that already has cluster access — in particular,
Headroom exempts loopback callers from its token, so a port-forwarded proxy
needs no credential at all.

### `ingress`

```yaml
# values-ingress.yaml
global:
  expose:
    domain: dev.example.com
    ingressClassName: nginx
headroom:
  expose: { mode: ingress }
ix:
  expose: { mode: ingress }
  auth:
    mode: basic
    basic: { existingSecret: ix-basic-auth }
```

```sh
helm upgrade --install wg oci://ghcr.io/crunchymonkies/charts/workgroup --version 0.1.3 \
  -n workgroup -f values-ingress.yaml
```

That publishes `headroom.dev.example.com` and `ix.dev.example.com`.

The Headroom Ingress carries streaming-friendly annotations by default —
`proxy-read-timeout: 3600`, `proxy-send-timeout: 3600`, `proxy-body-size: 0`,
`proxy-buffering: off`. Model responses stream for minutes and the usual
60-second controller default cuts them off mid-completion. On a non-nginx
controller you must set the equivalent yourself via
`expose.ingress.annotations`.

The Ix Ingress uses a 64 MB body limit and 900-second timeouts: `ix map` on a
large repository commits one large patch in one long request.

### `gateway`

```yaml
global:
  expose:
    domain: dev.example.com
    gatewayParentRefs:
      - name: public-gateway
        namespace: gateway-system
headroom:
  expose: { mode: gateway }
ix:
  expose: { mode: gateway }
  auth:
    mode: none
    acknowledgeUnauthenticated: true   # guarded by a SecurityPolicy, see below
```

The Headroom HTTPRoute sets `timeouts.request: 0s` (no limit) for the same
streaming reason. Ix uses 900s.

Headroom needs nothing further while `auth.enabled: true`: it checks
`HEADROOM_PROXY_TOKEN` on every request itself, and leaves `/readyz` exempt so
a monitor can still reach it. If you have turned the token off so that
bearer-authenticating clients can connect, it needs the same source-address
treatment as Ix — see
[Restricting by source address](#restricting-by-source-address-instead), and
[07-troubleshooting.md](07-troubleshooting.md#unauthorized-with-a-valid-proxy-token--subscriptionoauth-clients)
for why you would.

Ix has no authentication of its own, and neither chart-provided mode helps here:
`auth.mode: basic` is implemented as ingress-controller annotations with **no
Gateway API equivalent** (combining the two is refused at template time), and
`oauth2Proxy` is a browser redirect the `ix` CLI cannot complete. Guard the
route by source address instead — see
[Restricting by source address](#restricting-by-source-address-instead).

### TLS

With cert-manager, add the issuer annotation and let it fill the Secret the
chart already names:

```yaml
headroom:
  expose:
    ingress:
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-prod
```

With a shared wildcard certificate you already hold, name it once:

```yaml
global:
  expose:
    tlsSecretName: wildcard-dev-example-com-tls
```

---

## Headroom values reference

The full annotated set is `charts/headroom/values.yaml`. The ones that matter:

| Key | Default | Notes |
| --- | --- | --- |
| `image.repository` | `ghcr.io/crunchymonkies/headroom` | this repo's patched build — see below |
| `image.tag` | `""` | empty ⇒ `.Chart.AppVersion`, which is the release version |
| `auth.enabled` | `true` | sets `HEADROOM_PROXY_TOKEN` |
| `auth.token` | `""` | empty ⇒ generated, then **preserved across upgrades** |
| `auth.existingSecret` | `""` | for external secret managers |
| `persistence.size` | `10Gi` | savings history, logs, local memory |
| `stateless` | `false` | `HEADROOM_STATELESS=1`; required for `replicaCount > 1` |
| `memory.enabled` | `false` | two StatefulSets and ~40Gi — see below |
| `upstream.anthropicApiUrl` / `openaiApiUrl` | `""` | point at a gateway or Azure/Bedrock shim |
| `updateCheck` | `false` | `HEADROOM_UPDATE_CHECK=off` |
| `offline` | `false` | `HEADROOM_OFFLINE=1` for air-gapped clusters |
| `corsOrigins` | `""` | `HEADROOM_CORS_ORIGINS` |
| `extraEnv` / `extraEnvFrom` | `[]` | anything not modelled above |
| `networkPolicy.proxyIngressFrom` | `[]` | empty ⇒ any pod may reach 8787 |

### Reading the generated token

```sh
kubectl -n workgroup get secret wg-headroom-secrets \
  -o jsonpath='{.data.proxy-token}' | base64 -d; echo
```

It is generated once and read back from the live Secret on every upgrade, so
`helm upgrade` never silently rotates every developer's credential. To rotate
deliberately, delete the Secret key or set `auth.token` explicitly.

### The image

The chart defaults to `ghcr.io/crunchymonkies/headroom`, built by this repo:
upstream at the commit pinned in [`patches/upstream.env`](../patches/upstream.env)
plus the patches that file lists. Both matter only to `memory.enabled: true`:

- `0001-headroom-neo4j-config-surface.patch` adds configuration surface and
  nothing else — with none of the new environment variables set the container
  behaves exactly as upstream's does — but it is what makes
  `memory.enabled: true` reachable at all.
- `0002-headroom-mem0-2x-search-api.patch` and
  `0003-headroom-direct-write-payload-key.patch` are the two halves of memory
  recall. Upstream calls mem0 with a 1.x signature that the 2.x it depends on
  rejects on every call, and writes each memory's text under a payload key that
  mem0 2.x does not read — so once the first is fixed, search finds the record,
  scores it, and discards it on the way out. See
  [`patches/README.md`](../patches/README.md).

To run upstream's published image instead:

```yaml
headroom:
  image:
    repository: ghcr.io/chopratejas/headroom
    tag: latest
```

The chart will then refuse `memory.enabled: true`, which is the point:

```
headroom: memory.enabled=true needs an image built with
patches/0001-headroom-neo4j-config-surface.patch, but image.repository is set
to the published upstream image … memory would silently stay on local SQLite.
```

That is not conservatism — the stock image has no configuration surface for the
Neo4j half of the `qdrant-neo4j` backend, so you would get a running Qdrant, a
running Neo4j, and a memory subsystem quietly ignoring both. If upstream merges
the patch, `memory.acknowledgeUnpatchedImage: true` overrides the guard.

### Semantic memory (Qdrant + Neo4j)

Off by default — it adds two StatefulSets and about 40Gi. Turning it on takes
two settings, not one, because Qdrant stores vectors but does not produce them:

```yaml
headroom:
  memory:
    enabled: true
    embeddings:
      existingSecret: headroom-embeddings   # key: api-key
```

Upstream's `qdrant-neo4j` backend embeds through an OpenAI-compatible
`/v1/embeddings` endpoint (`text-embedding-3-small`). With no key it fails to
initialize on every attempt, and because that failure is fail-open the proxy
starts, serves traffic, and simply never reports ready — `/readyz` stays 503
with `memory.initialized: false` until the startup probe kills the pod. So the
chart refuses to render instead:

```
headroom: memory.enabled=true requires memory.embeddings.apiKey or
memory.embeddings.existingSecret. Qdrant stores vectors but does not produce
them …
```

This is the **only** provider credential the proxy holds. Everything under
`/v1/*` still forwards each caller's own key upstream — see
[doc 5](05-security.md).

It does not have to be OpenAI. Point `baseUrl` at anything that speaks the same
API — a local embeddings server, LiteLLM, Azure OpenAI — and no prompt text
leaves your network:

```yaml
headroom:
  memory:
    enabled: true
    embeddings:
      baseUrl: http://litellm.llm.svc.cluster.local:4000/v1
      apiKey: unused-but-required     # most gateways ignore it; the client insists
```

The model name is upstream's default, `text-embedding-3-small`, and is not
configurable from the chart — serve it under that name, as an alias if need be.

`memory.enabled=true` is incompatible with `stateless=true` (upstream disables
memory when `HEADROOM_STATELESS` is set); the chart fails on that combination
too.

### Using managed datastores

```yaml
headroom:
  memory:
    enabled: true
    qdrant:
      enabled: false
      external:
        enabled: true
        url: https://qdrant.example.com:6333
        apiKeySecret: qdrant-api-key
    neo4j:
      enabled: false
      external:
        enabled: true
        uri: neo4j+s://abcd.databases.neo4j.io
      auth:
        existingSecret: neo4j-creds
```

---

## Ix values reference

Full set in `charts/ix/values.yaml`.

| Key | Default | Notes |
| --- | --- | --- |
| `auth.mode` | `none` | `none` \| `basic` \| `oauth2Proxy` |
| `auth.acknowledgeUnauthenticated` | `false` | required to expose with `auth.mode: none` |
| `arangodb.password` | `""` | empty ⇒ generated, preserved across upgrades |
| `arangodb.database` | `ix_memory` | |
| `arangodb.persistence.size` | `50Gi` | the graph grows with repo count × size |
| `arangodb.external.*` | disabled | point at a managed ArangoDB |
| `networkPolicy.apiIngressFrom` | `[]` | empty ⇒ any pod may reach the API |

Upstream's compose file runs ArangoDB with `ARANGO_NO_AUTH=1`. This chart never
does; the root password comes from a Secret in every configuration.

### The auth modes

> **Read this before choosing one.** The `ix` CLI cannot send credentials of any
> kind — no `Authorization` header, no token, no `.netrc`, and the runtime
> rejects `https://user:pass@host` outright. Every mode below therefore breaks
> the CLI, not just secures it. They exist for deployments where Ix is reached
> only by something you control (a service, a proxy you wrote, a browser UI).
> If developers are going to run `ix map` against this, see
> [Restricting by source address](#restricting-by-source-address-instead)
> below. The full reasoning is in
> [04-connect-cli-to-server.md](04-connect-cli-to-server.md#the-ix-cli-cannot-authenticate).

**`basic`** — HTTP basic auth via ingress-controller annotations. Cheapest to
set up, ingress-only.

```sh
htpasswd -c auth alice
htpasswd auth bob
kubectl -n workgroup create secret generic ix-basic-auth --from-file=auth
```

```yaml
ix:
  auth: { mode: basic, basic: { existingSecret: ix-basic-auth } }
```

**`oauth2Proxy`** — an oauth2-proxy sidecar in front of the API. The Service
targets the sidecar port instead of the API port, so the API is never reachable
except through it. Works with both `ingress` and `gateway`.

```sh
kubectl -n workgroup create secret generic ix-oidc \
  --from-literal=client-id=... \
  --from-literal=client-secret=... \
  --from-literal=cookie-secret="$(openssl rand -base64 32 | head -c 32 | base64)"
```

```yaml
ix:
  auth:
    mode: oauth2Proxy
    oauth2Proxy:
      existingSecret: ix-oidc
      provider: oidc
      oidcIssuerUrl: https://idp.example.com
      emailDomain: example.com
```

The sidecar runs with `--skip-jwt-bearer-tokens=true` so that a caller holding a
valid JWT can pass straight through without the interactive redirect. That is
for machine callers you write yourself; the `ix` CLI cannot use it, because it
cannot set a header.

### Restricting by source address instead

This is the only arrangement that leaves the CLI working. Expose Ix with
`auth.mode: none` plus `acknowledgeUnauthenticated: true`, and put a
source-address rule on the route. With Envoy Gateway:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ix-allow-lan
  namespace: workgroup
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: wg-ix          # <release>-ix — must track the release name
  authorization:
    defaultAction: Deny
    rules:
      - name: lan
        action: Allow
        principal:
          clientCIDRs:
            - 10.0.0.0/8
```

`acknowledgeUnauthenticated: true` then means "the guard's intent is met
elsewhere", not "unauthenticated is fine". Two conditions have to hold or the
rule silently passes everything:

- The gateway's LoadBalancer Service must be `externalTrafficPolicy: Local`.
  Under the `Cluster` default every request is SNAT'd to a node address, so a
  node-range CIDR matches unconditionally and the policy looks like it is
  working.
- Do not configure `clientIPDetection` / XFF trust on the Gateway unless you
  control everything upstream of it; otherwise the matched address comes from a
  header the client can set.

Confirm the policy actually attached — a typo in `targetRefs.name` detaches it
without error and leaves the API open:

```sh
kubectl -n workgroup get securitypolicy ix-allow-lan -o jsonpath='{.status}'
```

Be clear about what this buys: a perimeter, not a credential. Anyone inside the
allowed range can read and write the whole codebase graph.

**`none`** — only sensible with `expose.mode: none`. Attempting to expose it
anyway is refused:

```
ix: refusing to expose the memory-layer with auth.mode=none. The Ix API has
no built-in authentication and is write-capable…
```

`auth.acknowledgeUnauthenticated: true` overrides it if you have decided that a
private network makes it acceptable.

---

## Guard rails

Both charts validate at template time so a misconfiguration fails at
`helm install` rather than becoming a running-but-wrong deployment.

| Condition | Chart |
| --- | --- |
| `expose.mode` / `auth.mode` not a known value | both |
| exposed with no authentication | both |
| `expose.mode: ingress` with no host | both |
| `expose.mode: gateway` with no `parentRefs` | both |
| `expose.mode: gateway` and Gateway API not installed | both |
| `external.enabled` with no URL/URI/host | both |
| `memory.enabled` on an unpatched image | headroom |
| `memory.enabled` with no embeddings key | headroom |
| `memory.enabled` with `stateless: true` | headroom |
| `auth.mode: basic` with `expose.mode: gateway` | ix |
| `auth.mode` set but its Secret unnamed | ix |
| neither in-chart nor external database | ix |

Each has an explicit override where one makes sense
(`acknowledgeUnauthenticated`, `acknowledgeUnpatchedImage`).

---

## Uninstall

```sh
helm uninstall wg -n workgroup
```

Data survives. The credential Secrets and Headroom's workspace PVC carry
`helm.sh/resource-policy: keep`, and Kubernetes never garbage-collects the PVCs
a StatefulSet's `volumeClaimTemplates` created (Qdrant, Neo4j, ArangoDB). So a
reinstall with the same release name comes back with its data and its
passwords intact.

To discard everything:

```sh
kubectl -n workgroup delete pvc,secret -l app.kubernetes.io/instance=wg
```

Delete the Secrets and the PVCs **together**. Neo4j and ArangoDB persist their
user accounts on disk: keeping a volume while dropping its password locks you
out of the database on the next install.

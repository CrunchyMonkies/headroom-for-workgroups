# 5. Security

The two services have very different threat profiles. Headroom was designed to
be exposed and has real authentication; Ix was designed to sit on localhost and
has none.

---

## Headroom

### The credential model is the good news

The proxy holds **no provider API keys**. Each request arrives with the
caller's own `x-api-key` or `authorization` header and the proxy forwards that
same header upstream (`proxy/auth_mode.py`). Consequences worth stating
plainly:

- There is no shared team key in a Secret to leak.
- Compromising the proxy pod does not yield anyone's Anthropic or OpenAI
  account.
- Billing and rate limits stay attributed per developer.
- Revoking one person's access is a provider-side key revocation, not a
  redeployment.

**One exception, and only with `memory.enabled: true`.** The `qdrant-neo4j`
backend embeds through an OpenAI-compatible `/v1/embeddings` endpoint, so the
proxy does hold `memory.embeddings.apiKey` — a shared key, in a Secret, that
compromising the pod would yield. It is used for embeddings and nothing else;
no `/v1/*` traffic is ever billed to it. Two things worth doing:

- Scope it. A key restricted to the embeddings endpoint, or a spend cap, keeps
  the blast radius to what it is actually for.
- Or keep it in-house. `memory.embeddings.baseUrl` points at any compatible
  endpoint, so a self-hosted embeddings server (or a gateway like LiteLLM)
  removes both the shared key and the third party — memory text stops leaving
  your network at all, which matters more than the key does, since what gets
  embedded is the content of everyone's prompts.

What the proxy *does* see is prompt and completion content in transit, and it
records compression statistics. Treat it as it deserves: a service that sees
everything your agents send.

### Inbound authentication

`HEADROOM_PROXY_TOKEN` gates every `/v1/*` route. Accepted as either:

```
Authorization: Bearer <token>
X-Headroom-Proxy-Token: <token>
```

Loopback callers are exempt — that is what makes the `kubectl port-forward`
workflow work without a credential.

**Do not turn the default off without putting something in its place.**
In-cluster the proxy binds `0.0.0.0`, so with no token every `/v1/*` route is
reachable unauthenticated from the entire pod network. Upstream logs a loud
`event=proxy_open_bind` warning when this happens. The chart sets a token by
default and refuses to render an Ingress or HTTPRoute with `auth.enabled=false`
unless you set `auth.acknowledgeUnauthenticated: true`.

There is one legitimate reason to turn it off, and it is not "the token is
inconvenient": **the token and a bearer-authenticating client are mutually
exclusive.** The check reads `Authorization` before `X-Headroom-Proxy-Token`,
so it compares the client's own credential against the proxy token and rejects
it — Claude Code on a Claude subscription can never pass. If your team needs
those clients, `auth.enabled: false` plus a source-CIDR `SecurityPolicy` at the
gateway is a coherent posture; `auth.enabled: false` on its own is an open
proxy. Both halves are set out in
[07-troubleshooting.md](07-troubleshooting.md#unauthorized-with-a-valid-proxy-token--subscriptionoauth-clients).

Weigh what that actually exposes. The proxy holds no provider credential — it
forwards whatever key the client sends — so an unauthorized caller cannot spend
your provider budget. What they get is your compression capacity, and the
ability to send prompt text through a service that logs and stores it. A
network perimeter is a coarser control than a token: it authorizes an address,
not a person, and it cannot be revoked for one user.

The token is a single shared secret for the whole team. It authenticates
"someone from our team", not "Alice". If you need per-person attribution or
revocation, put an identity-aware proxy in front (the same oauth2-proxy pattern
`charts/ix` uses) and treat the Headroom token as a second, internal factor.

### Rotating the token

Generated tokens are read back from the live Secret on every upgrade, so
`helm upgrade` never silently rotates a credential every developer has
configured. To rotate deliberately:

```sh
kubectl -n workgroup delete secret wg-headroom-secrets
helm upgrade wg charts/workgroup -n workgroup
```

Then distribute the new value. Note this also regenerates the Neo4j password —
if memory is enabled, see [06-operations.md](06-operations.md) first, because
Neo4j persists its user on disk.

### `/health` leaks configuration

`/health` echoes upstream URLs and configuration. Upstream restricts it to
loopback callers, which is the right call, but it means:

- Never use it as a probe target (the chart uses `/livez` and `/readyz`).
- Never route it through an Ingress that could reach it from a pod-network
  origin the proxy considers local.

`/livez` and `/readyz` are explicitly auth-exempt and return nothing sensitive.

---

## Ix

### There is no authentication

Upstream's own API documentation: *"Local backend: no authentication. The
endpoint is bound to localhost."* The API is fully write-capable — anything
that can reach port 8090 can read the entire graph or delete it.

This shapes every default in `charts/ix`:

- `expose.mode: none` by default.
- Rendering an Ingress or HTTPRoute **fails** while `auth.mode: none`, with an
  explicit `auth.acknowledgeUnauthenticated: true` override.
- A NetworkPolicy restricts port 8090 to the peers you name.
- ArangoDB is never run with `ARANGO_NO_AUTH=1`, unlike upstream's compose.

### What the graph contains

Not your source, but a detailed structural map of it: file paths, symbol names,
signatures, call and reference edges. For most teams that is sensitive enough
to warrant the auth layer even on an internal network — it is a precise map of
what your systems are and how they connect.

### Choosing an auth mode

| | `basic` | `oauth2Proxy` |
| --- | --- | --- |
| Setup | one htpasswd Secret | an OIDC client + Secret |
| Identity | shared or per-user password | your IdP |
| Revocation | edit htpasswd, restart controller | IdP-side, immediate |
| Works with `gateway` | **no** | yes |
| Enforced by | the ingress controller | a sidecar in the pod |

`oauth2Proxy` is stronger for a reason beyond the identity story: it runs as a
sidecar and the Service targets the *sidecar's* port, so the API is unreachable
except through it. Basic auth is enforced by the ingress controller, so
anything already inside the cluster that can route to the Service bypasses it
entirely — the NetworkPolicy is what covers that gap.

The sidecar runs with `--skip-jwt-bearer-tokens=true` so the `ix` CLI can
present a bearer token; it cannot complete an interactive browser redirect.

---

## NetworkPolicies

Both charts ship policies, enabled by default. They require a CNI that
enforces them (Calico, Cilium, Antrea…) — on a CNI that ignores
NetworkPolicy they are inert and you should know that.

**Datastores are always locked to their consumer.** Qdrant and Neo4j accept
traffic only from the Headroom proxy pod; ArangoDB only from the Ix
memory-layer pod. This is not configurable, because there is no good reason to
want it otherwise.

**Application ingress is open by default within the cluster.** Both
`networkPolicy.proxyIngressFrom` (Headroom) and `networkPolicy.apiIngressFrom`
(Ix) default to `[]`, which means any pod may reach the service port. Narrow
it to your ingress controller:

```yaml
headroom:
  networkPolicy:
    proxyIngressFrom:
      - namespaceSelector:
          matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
ix:
  networkPolicy:
    apiIngressFrom:
      - namespaceSelector:
          matchLabels: { kubernetes.io/metadata.name: ingress-nginx }
```

Do this if you are running `auth.mode: basic` for Ix — the controller is the
only thing enforcing that auth, so it should be the only thing that can reach
the API.

---

## Secrets

Generated credentials — the Headroom proxy token, the Neo4j password, the
ArangoDB root password — are created on first install and preserved across
upgrades via `lookup` against the live Secret. They carry
`helm.sh/resource-policy: keep` so `helm uninstall` does not orphan a database
whose on-disk user still expects the old password.

For an external secret manager, supply your own instead:

```yaml
headroom:
  auth:
    existingSecret: headroom-token
    existingSecretKey: token
  memory:
    neo4j:
      auth:
        existingSecret: neo4j-creds
        existingSecretKey: password
ix:
  arangodb:
    existingSecret: arango-creds
    existingSecretKey: password
```

The charts then generate nothing and reference yours — compatible with External
Secrets Operator, Vault injection, or Sealed Secrets.

### On the client side

`install.sh` / `install.ps1` write one file:

| | |
| --- | --- |
| Path | `~/.config/headroom-workgroup/env.sh`, or `env.ps1` on Windows |
| Permissions | created under `umask 077` and `chmod 600`; on Windows, inherited ACEs are stripped and only the current user is granted access |
| Contains | `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `IX_ENDPOINT`, `ENABLE_TOOL_SEARCH`, and — if you gave a token — `HEADROOM_PROXY_TOKEN` and `ANTHROPIC_CUSTOM_HEADERS` |
| Never contains | `ANTHROPIC_API_KEY` or any other provider key. Your own key is not the server's business and the installer does not touch it. |

The file is created empty and locked down *before* the token is written into it,
so it never exists — even momentarily — readable by another local user.

Three ways to supply the token, in increasing order of care:

| | |
| --- | --- |
| `--token` / `-Token` | lands in your shell history; the installer warns |
| `--token-file` / `-TokenFile`, `--token-stdin` | read once, written to the config file |
| `--token-command` / `-TokenCommand` | **not stored at all** — the config file calls your secret manager each time, e.g. `--token-command 'pass show workgroup/headroom-token'` |

Omit it entirely when you reach the proxy over `kubectl port-forward`: loopback
callers are exempt from the token by design.

`-WriteProfile` on Windows also persists the *base URLs* at user scope so
GUI-launched editors see them. The token deliberately is not persisted that way
— user-scope environment variables are readable by every process you run.

---

## TLS

Terminate at the ingress or gateway. Neither application speaks TLS itself.

In-cluster traffic between the proxy and its datastores is plaintext on the pod
network. If your threat model includes a compromised node or a shared cluster,
use a service mesh for mTLS — neither chart implements transport encryption
internally.

`HEADROOM_TLS_STRICT` controls the proxy's *outbound* verification toward
providers. Leave it at its default; set it via `extraEnv` only if you are
deliberately routing through an intercepting corporate proxy.

---

## A checklist before exposing anything

- [ ] `auth.enabled: true` on Headroom, token distributed out-of-band
- [ ] `auth.mode` set to `basic` or `oauth2Proxy` on Ix
- [ ] TLS terminating at the ingress/gateway, with a real certificate
- [ ] `networkPolicy.*IngressFrom` narrowed to the ingress controller
- [ ] `/health` not routed through any Ingress rule
- [ ] `updateCheck: false` (default) — and `offline: true` if the cluster
      should make no outbound calls beyond the model providers
- [ ] Datastore passwords generated or supplied, never defaulted
- [ ] A rotation plan for the Headroom token

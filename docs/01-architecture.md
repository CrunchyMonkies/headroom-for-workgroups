# 1. Architecture

Two independent services. They do not talk to each other; they are deployed
together because a team tends to want both, and because the client-side
configuration story is the same shape for each.

---

## Headroom — the context-compression proxy

Headroom sits between an agent and a model provider. It compresses the context
window before the request goes upstream, and reports what that saved.

```
  developer's machine                        Kubernetes
  ┌──────────────────────┐         ┌──────────────────────────────┐
  │ Claude Code / agent  │         │  headroom proxy  :8787       │
  │   ANTHROPIC_BASE_URL ├────────►│    compress → forward        │──► api.anthropic.com
  │   + x-api-key (theirs)│  HTTPS │    ▲                         │──► api.openai.com
  └──────────────────────┘         │    │ (optional)              │
                                   │  Qdrant :6333   Neo4j :7687  │
                                   └──────────────────────────────┘
```

### The credential model

**The proxy stores no provider credentials.** Each request arrives carrying the
caller's own `x-api-key` or `authorization` header, and the proxy passes that
same header upstream (`proxy/auth_mode.py`). There is no shared team key
sitting in a Secret, and compromising the proxy does not hand an attacker
anyone's provider account.

Inbound authentication is separate and is the proxy's own: `HEADROOM_PROXY_TOKEN`,
sent as `Authorization: Bearer <token>` or `X-Headroom-Proxy-Token`. Loopback
callers are exempt, which is why a `kubectl port-forward` needs no header.

### Endpoints worth knowing

| Path      | Auth        | Use                                            |
| --------- | ----------- | ---------------------------------------------- |
| `/livez`  | exempt      | liveness probe                                 |
| `/readyz` | exempt      | readiness / startup probe                      |
| `/health` | **loopback only** | echoes upstream URLs and config — never expose or probe |
| `/v1/*`   | token       | the actual proxy surface                       |

`/health` returning config to loopback callers is deliberate upstream
behaviour, but it means it is useless as a probe target and undesirable as an
exposed route. The chart uses `/livez` and `/readyz`.

### State

Everything the proxy persists lives under `HEADROOM_WORKSPACE_DIR`
(`/home/nonroot/.headroom`, a declared `VOLUME`): savings history, the
dashboard's data, logs, and local SQLite memory. The chart backs this with a
PVC.

`HEADROOM_STATELESS=1` disables all filesystem writes, which is how you run
more than one replica — at the cost of that history and of local memory.

### Memory backends

| backend        | what it is                                    | needs        |
| -------------- | --------------------------------------------- | ------------ |
| `local`        | SQLite on the workspace volume — **default**  | nothing      |
| `qdrant-neo4j` | vector recall + a relationship graph          | a patched image, Qdrant, Neo4j, an embeddings endpoint |

The published upstream image cannot be configured to reach a Neo4j at all, so
`charts/headroom` defaults `memory.enabled=false` and refuses to enable it on
the stock image. See [patches/README.md](../patches/README.md) for the one-file
fix and how to build the image.

Qdrant stores vectors but does not produce them: `qdrant-neo4j` embeds through
an OpenAI-compatible `/v1/embeddings` endpoint (`text-embedding-3-small`), so
it also needs `memory.embeddings`. That can be OpenAI or anything speaking the
same API — see [02-install-server-k8s.md](02-install-server-k8s.md#semantic-memory-qdrant--neo4j).
`local` needs none of this; it embeds on-device.

---

## Ix — the codebase graph

Ix builds a queryable graph of a codebase — symbols, references, call paths —
and answers structural questions about it.

```
  developer's machine                        Kubernetes
  ┌───────────────────────────┐    ┌────────────────────────────────┐
  │ ix CLI                    │    │  memory-layer :8090            │
  │  tree-sitter parse (local)│    │    /v1/health                  │
  │  → graph patch            ├───►│    commitPatchBulk             │
  │  IX_ENDPOINT              │HTTP│         │                      │
  └───────────────────────────┘    │    ArangoDB :8529 (graph)      │
                                   └────────────────────────────────┘
```

### Why a remote backend works

The CLI does the parsing. It walks your working tree with tree-sitter on your
machine, diffs against what the server already knows, and pushes a *graph
patch* (`commitPatchBulk`). **Your source never leaves your machine as source**
— what crosses the wire is the extracted structure.

The one exception is `POST /v1/ingest {path}`, which hands the server a path
and expects it to read it. That is the local-Docker path and is not used
against a remote backend.

### Multi-user scoping

Already built in: `workspace_id` and `system_id`, settable per request via the
`x-ix-workspace` and `x-ix-system` headers. Several developers and several
repositories share one backend without colliding.

### Auto-map against a shared backend

`shouldSkipAutoMap` disables background auto-mapping when the endpoint is
remote — otherwise every client would push a write on every file change.
Against a shared backend you run `ix map .` deliberately. `IX_AUTO_MAP_CLOUD=1`
overrides this if you accept the write volume.

### Authentication

There is none. Upstream's own API docs say so plainly: *"Local backend: no
authentication. The endpoint is bound to localhost."* The API is write-capable
— anything that can reach port 8090 can read the graph or destroy it.

This is why `charts/ix` treats exposure as a decision you have to make
explicitly, and refuses to render an Ingress without an auth layer in front.
[docs/05-security.md](05-security.md) covers the options.

---

## How the charts fit together

```
charts/workgroup           umbrella — no templates of its own but NOTES
  ├── global.expose.*      one domain, ingress class, gateway, TLS secret
  ├── headroom  (file://../headroom)   condition: headroom.enabled
  └── ix        (file://../ix)         condition: ix.enabled
```

Each subchart reads `global.expose.*` only as a *fallback*; its own
`expose.*` values always win. So you can set the team domain once and still
override a single hostname.

Both charts implement the same three-way exposure toggle
(`none` | `ingress` | `gateway`) and the same `external.*` escape hatch on
every datastore, so pointing at a managed Qdrant, Neo4j or ArangoDB is a values
change rather than a fork.

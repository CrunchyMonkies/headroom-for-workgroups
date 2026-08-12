# Patches

Patches this repo carries against upstream. They are **not** required to run
either service — each one unlocks a specific capability that upstream does not
currently expose.

---

## `0001-headroom-neo4j-config-surface.patch`

**Against:** [`headroomlabs-ai/headroom`](https://github.com/headroomlabs-ai/headroom)
at the commit pinned in [`upstream.env`](upstream.env) — that file is the single
source of truth, and both CI and `scripts/verify-patch.sh` read it.
**Unlocks:** `memory.enabled=true` in `charts/headroom`
**Size:** 3 files changed, +148 / -6

> **You do not need to build this yourself.** CI builds it on every release and
> publishes it as `ghcr.io/crunchymonkies/headroom`, which is already the chart
> default. The manual steps below are for re-basing the patch onto a newer
> upstream, or for building it inside your own registry.

### The problem

Headroom's proxy supports two memory backends:

| backend        | storage                                  |
| -------------- | ---------------------------------------- |
| `local`        | SQLite on the workspace volume (default) |
| `qdrant-neo4j` | Qdrant vectors + a Neo4j relation graph  |

`ProxyConfig` already has fields for the second one — `memory_backend`,
`memory_neo4j_uri`, `memory_neo4j_user`, `memory_neo4j_password` — but on the
published image **nothing can set them**:

- The Qdrant half reads `HEADROOM_QDRANT_*` through `headroom/memory/qdrant_env.py`.
  The Neo4j half has no equivalent module; the fields are plain hardcoded
  defaults (`neo4j://localhost:7687`, user `neo4j`, empty password).
- `headroom proxy` has `--memory-qdrant-url` and friends, but no
  `--memory-backend` and no Neo4j flags at all.

So a container can be given a Qdrant, but never a Neo4j, and can never be told
to select the `qdrant-neo4j` backend. It silently stays on local SQLite.

Note this is *only* about the proxy's configuration surface. The backend
implementation itself is upstream's and is untouched.

### What the patch does

Three files, mirroring the existing Qdrant plumbing exactly:

1. **`headroom/memory/neo4j_env.py`** *(new)* — the missing sibling of
   `qdrant_env.py`. Reads `HEADROOM_NEO4J_URI`, `HEADROOM_NEO4J_USER`,
   `HEADROOM_NEO4J_PASSWORD`, treating whitespace-only values as unset.

2. **`headroom/proxy/models.py`** — turns the four hardcoded defaults into
   `field(default_factory=...)` resolvers. Adds `HEADROOM_MEMORY_BACKEND`,
   which validates against the known backend names and logs a warning + falls
   back to `local` on anything else rather than failing at import time.

3. **`headroom/cli/proxy.py`** — adds `--memory-backend`, `--memory-neo4j-uri`,
   `--memory-neo4j-user` and `--memory-neo4j-password`, each with the matching
   `envvar=`, following the same override pattern the Qdrant flags already use.

Behaviour with none of the new env vars set is byte-for-byte the previous
behaviour: backend `local`, `neo4j://localhost:7687`, user `neo4j`, empty
password.

### Checking that it still applies

```sh
scripts/verify-patch.sh          # fetches the pinned commit, git apply --check
scripts/verify-patch.sh --keep   # and leaves the patched tree for inspection
```

CI runs the first form on every push. It is the only check that catches this
patch rotting: without it, the image still builds and the failure surfaces only
as a memory subsystem that silently fell back to SQLite.

### Building the image yourself

```sh
. patches/upstream.env

git clone "https://github.com/${HEADROOM_REPO}" /tmp/headroom
cd /tmp/headroom
git checkout "$HEADROOM_BASE_COMMIT"

git apply --3way "$OLDPWD/$HEADROOM_PATCH"

docker build -t ghcr.io/YOUR-ORG/headroom:neo4j-patch .

# Sanity check: the new flags exist in the artefact, not just in the source
# tree. ENTRYPOINT is ["headroom","proxy"], so --help lands on the right command.
docker run --rm ghcr.io/YOUR-ORG/headroom:neo4j-patch --help | grep memory-

docker push ghcr.io/YOUR-ORG/headroom:neo4j-patch
```

That last assertion is what `.github/workflows/release.yml` runs before it
pushes anything — an unpatched build fails the release rather than shipping.

Then point the chart at it:

```yaml
image:
  repository: ghcr.io/YOUR-ORG/headroom
  tag: neo4j-patch
memory:
  enabled: true
```

If you point the chart back at upstream's published image and force
`memory.enabled=true`, it stops you:

```
headroom: memory.enabled=true needs an image built with
patches/0001-headroom-neo4j-config-surface.patch, but image.repository is set
to the published upstream image "ghcr.io/chopratejas/headroom". That image has
no configuration surface for the Neo4j half of the qdrant-neo4j backend, so
memory would silently stay on local SQLite.
```

### Re-basing onto a newer upstream

1. Find the new commit and try it: edit `HEADROOM_BASE_COMMIT` in
   `patches/upstream.env`, run `scripts/verify-patch.sh`.
2. If it still applies, you are done — commit the one-line change.
3. If it does not, `scripts/verify-patch.sh --keep` leaves a checkout to fix by
   hand; re-apply the three changes, then regenerate:
   `git -C <tree> diff > patches/0001-headroom-neo4j-config-surface.patch`.
4. Cut a release ([docs/08](../docs/08-releasing.md)) so the published image
   picks up the new base.

That guard exists because the failure mode is silent: without it you get a
running proxy, a running Qdrant, a running Neo4j, and a memory subsystem that
quietly ignores both.

### If upstream merges it

Set `memory.acknowledgeUnpatchedImage=true` and go back to the published image.
Verify first — the flags must be present:

```sh
kubectl -n <ns> exec deploy/<release>-headroom -- headroom proxy --help | grep memory-backend
```

### Not using memory at all

Leave `memory.enabled=false` (the default). The proxy uses local SQLite memory
on its workspace PVC. Compression, routing, savings tracking and the dashboard
all work exactly the same — you lose cross-session semantic recall, nothing
else. No patch, no Qdrant, no Neo4j.

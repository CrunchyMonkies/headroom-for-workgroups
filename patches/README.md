# Patches

Patches this repo carries against upstream. Neither is required to run either
service in its default configuration: `0001` unlocks a capability upstream does
not expose, and `0002` fixes a bug on a code path only `memory.enabled=true`
reaches. Both are already in the published image.

[`upstream.env`](upstream.env) is the single source of truth for the set — the
pinned commit and `HEADROOM_PATCHES`, **an ordered list**. Each patch is
generated against the tree with its predecessors applied, so the order in that
file is the order they must be applied in. CI, `scripts/verify-patch.sh` and
`.github/workflows/release.yml` all read it rather than naming patches
themselves.

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
scripts/verify-patch.sh          # fetches the pinned commit, applies every patch
scripts/verify-patch.sh --keep   # and leaves the patched tree for inspection
```

It applies the whole `HEADROOM_PATCHES` list in order against a throwaway
checkout, so it catches both a patch rotting against upstream and two patches
ceasing to stack. CI runs the first form on every push. It is the only check
that catches either: without it, the image still builds and the failure
surfaces only at runtime.

### Building the image yourself

```sh
. patches/upstream.env

git clone "https://github.com/${HEADROOM_REPO}" /tmp/headroom
cd /tmp/headroom
git checkout "$HEADROOM_BASE_COMMIT"

# In order — each patch is generated against the tree with its predecessors
# applied, which is why HEADROOM_PATCHES is a list and not a set.
for p in $HEADROOM_PATCHES; do git apply --3way "$OLDPWD/$p"; done

# The build arg is not optional. Upstream's Dockerfile defaults to
# HEADROOM_EXTRAS=proxy,code, which leaves out mem0ai, qdrant-client and neo4j —
# so the patch would give you the --memory-* flags with nothing behind them.
docker build --build-arg HEADROOM_EXTRAS=proxy,code,memory-stack \
  -t ghcr.io/YOUR-ORG/headroom:neo4j-patch .

# Two separate sanity checks, because they catch two separate mistakes, and both
# failures are silent at runtime: memory init is fail-open, so a bad image serves
# traffic and simply never reports ready.

# 1. The flags exist in the artefact, not just in the source tree.
#    ENTRYPOINT is ["headroom","proxy"], so --help lands on the right command.
docker run --rm ghcr.io/YOUR-ORG/headroom:neo4j-patch --help | grep memory-

# 2. The code behind them can actually import its dependencies.
docker run --rm --entrypoint python3 ghcr.io/YOUR-ORG/headroom:neo4j-patch \
  -c 'import qdrant_client, neo4j, mem0; print("memory-stack present")'

docker push ghcr.io/YOUR-ORG/headroom:neo4j-patch
```

Both assertions are what `.github/workflows/release.yml` runs before it pushes
anything — an unpatched or under-built image fails the release rather than
shipping. The second was added after `0.1.1` shipped patched but without the
extra, which looks identical until the proxy refuses to become ready.

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
   hand; re-apply the changes, then regenerate each patch from the tree with
   its predecessors already applied — `git -C <tree> diff -- <its files> >
   patches/000N-….patch`, one file scope per patch, so they stay separable.
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

---

## `0002-headroom-mem0-2x-search-api.patch`

**Against:** the same pinned commit, applied **after** `0001`.
**Fixes:** memory search and `memory_list` on the `qdrant-neo4j` backend
**Size:** 1 file changed, +25 / -6

### The problem

`headroom_ai` declares `mem0ai>=2.0.0,<3.0`, and 2.x moved entity scoping out of
the call signature. `DirectMem0Adapter.search_memories()` still calls the 1.x
one:

```python
results = await asyncio.to_thread(
    self._mem0_client.search,
    query=query,
    user_id=user_id,   # <- 2.x rejects this
    limit=top_k,       # <- 2.x ignores this (it is now top_k)
)
```

Against mem0 2.0.18 that raises on every call:

```
ValueError: Top-level entity parameters frozenset({'user_id'}) are not
supported in search(). Use filters={'user_id': '...'} instead.
```

**Nothing surfaces the failure.** Every caller catches the exception and logs a
warning — `proxy/memory_handler.py` does it at the auto-inject recall path, at
`memory_search`, at `memory_list`, and at the consolidation reads. `/readyz`
reports `memory.initialized: true` throughout because initialisation genuinely
succeeded. Saves work: `add()` still takes `user_id`, and the primary save path
writes straight to Qdrant without going through mem0 at all. So the observable
behaviour is a memory system that stores everything, reports healthy, and
recalls nothing — indefinitely.

There is a second mismatch on the same line. `memory_list` has no
`list_memories` on this backend, so `memory_handler` falls back to
`search_memories(query="")` as its "return everything" convention. Mem0 2.x
rejects that too (`Invalid query: cannot be empty or whitespace-only`), so
fixing only the filters leaves `memory_list` broken.

### What the patch does

Replaces the one call with the 2.x spelling — `filters={"user_id": ...}` and
`top_k=` — and routes a blank query to `get_all()`, which is 2.x's way to ask
for everything belonging to an entity. Nothing downstream changes: both return
`{"results": [...]}`, which the existing result parsing already handles.

Note what it does *not* do. `filters={"user_id": ...}` matches because the
direct-write path (`_write_facts_to_qdrant`) already puts a top-level `user_id`
in each Qdrant payload, and mem0 has already created the payload index for it.
No stored data has to move.

### Why not just pin mem0 instead

Because the pin would have to go backwards past upstream's own floor. The bug
is upstream code against upstream's own declared dependency range, not a version
skew this repo introduced — every 2.x release in `>=2.0.0,<3.0` fails this way.

### Checking that it is live

There are no new CLI flags to grep for, so the release workflow asserts it
against the source inside the built image:

```sh
docker run --rm --entrypoint python3 ghcr.io/crunchymonkies/headroom:<tag> -c '
import inspect
from headroom.memory.backends.direct_mem0 import DirectMem0Adapter
print(inspect.getsource(DirectMem0Adapter.search_memories))' | grep filters
```

End to end, the honest check is a round trip: save a memory, then search for it.
A green `/readyz` and a running Qdrant prove nothing here — that is exactly the
state the bug produces.

### If upstream merges it

Drop the entry from `HEADROOM_PATCHES` in `upstream.env` and bump
`HEADROOM_BASE_COMMIT` past the merge. Nothing else references it by name.

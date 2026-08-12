# 6. Operations

## Upgrades

```sh
helm upgrade wg oci://ghcr.io/crunchymonkies/charts/workgroup --version 0.2.0 \
  -n workgroup -f values-prod.yaml
```

Preview first — the charts validate at template time, so most misconfigurations
surface here rather than in the cluster:

```sh
CHART=oci://ghcr.io/crunchymonkies/charts/workgroup

helm diff upgrade wg "$CHART" --version 0.2.0 -n workgroup -f values-prod.yaml  # if you have helm-diff
helm template wg "$CHART" --version 0.2.0 -f values-prod.yaml >/dev/null        # otherwise: does it render?
```

Pin `--version` on every upgrade. Without it Helm resolves the newest published
chart, so `helm upgrade` becomes "upgrade to whatever exists today" rather than
a reviewable change.

Each chart version pulls its matching Headroom image — `image.tag` defaults to
the chart's `appVersion` — so a chart upgrade is also an image upgrade unless
you have pinned `headroom.image.tag` yourself.

Working from a clone instead:

```sh
helm dependency update charts/workgroup
helm upgrade wg charts/workgroup -n workgroup -f values-prod.yaml
```

The rest of this page uses the local-path form for brevity; substitute the OCI
reference and `--version` wherever you see `charts/workgroup`.

### Credentials survive upgrades

Generated secrets — the Headroom proxy token, the Neo4j password, the ArangoDB
root password — are read back from the live Secret via `lookup` before falling
back to generating a new one. A `helm upgrade` therefore does not silently
rotate a credential every developer has configured.

This depends on `lookup` reaching the cluster. It returns empty during
`helm template` and `--dry-run=client`, which is why a rendered manifest shows
a *different* random token each time — that is the dry run, not a rotation. If
you pipe `helm template` output into `kubectl apply`, you **will** rotate
credentials on every apply. Use `helm upgrade`.

### Rotating deliberately

```sh
kubectl -n workgroup delete secret wg-headroom-secrets
helm upgrade wg charts/workgroup -n workgroup
```

**If Headroom memory is enabled, do not do this casually.** Neo4j stores its
user account on disk in the PVC. Regenerating the password gives you a Secret
and a database that disagree, and the pod will fail to authenticate. Rotate the
Neo4j password inside the database first (`ALTER CURRENT USER SET PASSWORD`),
then set `memory.neo4j.auth.password` to the new value. The same applies to
ArangoDB.

To rotate only the proxy token, set it explicitly rather than deleting the
whole Secret:

```sh
helm upgrade wg charts/workgroup -n workgroup \
  --set headroom.auth.token="$(openssl rand -hex 24)" --reuse-values
```

---

## Storage

| Volume | Chart default | Holds |
| --- | --- | --- |
| Headroom workspace | 10Gi | savings history, dashboard data, logs, local SQLite memory |
| Qdrant | 20Gi | vector index |
| Neo4j | 20Gi | relationship graph |
| ArangoDB | 50Gi | the Ix codebase graph |

ArangoDB is the one that actually grows: roughly with (number of repositories ×
their size × how often they are re-mapped). Watch it.

```sh
kubectl -n workgroup exec sts/wg-ix-arangodb -- df -h /var/lib/arangodb3
kubectl -n workgroup exec deploy/wg-headroom -- df -h /home/nonroot/.headroom
```

Expanding a PVC needs a StorageClass with `allowVolumeExpansion: true`. Edit
the PVC directly — changing the chart value does not resize an existing volume,
and for the StatefulSets it will not even be applied (`volumeClaimTemplates`
are immutable after creation):

```sh
kubectl -n workgroup patch pvc data-wg-ix-arangodb-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
```

---

## Backups

### ArangoDB (Ix graph)

```sh
PW=$(kubectl -n workgroup get secret wg-ix-secrets \
       -o jsonpath='{.data.arango-password}' | base64 -d)

kubectl -n workgroup exec sts/wg-ix-arangodb -- \
  arangodump --server.password "$PW" --server.database ix_memory \
             --output-directory /tmp/dump --overwrite true

kubectl -n workgroup exec sts/wg-ix-arangodb -- tar cz -C /tmp dump > ix-$(date +%F).tar.gz
```

Restore with `arangorestore --input-directory /tmp/dump`.

The graph is derived data — worst case, every developer re-runs `ix map .`.
Back it up for convenience and to avoid a re-map storm, not because it is
irreplaceable.

### Neo4j (Headroom memory)

`neo4j-admin database dump` requires the database to be stopped, so for a
single-instance deployment take a volume snapshot instead, or scale to zero for
the window:

```sh
kubectl -n workgroup scale sts/wg-headroom-neo4j --replicas=0
# snapshot the PVC via your CSI driver
kubectl -n workgroup scale sts/wg-headroom-neo4j --replicas=1
```

### Qdrant

```sh
kubectl -n workgroup exec sts/wg-headroom-qdrant -- \
  curl -sX POST http://localhost:6333/collections/<name>/snapshots
```

### Headroom workspace

Savings history and dashboard data. Nice to keep, not critical:

```sh
kubectl -n workgroup exec deploy/wg-headroom -- \
  tar cz -C /home/nonroot .headroom > headroom-workspace-$(date +%F).tar.gz
```

---

## Scaling

### Headroom

`replicaCount > 1` requires `stateless: true`:

```yaml
headroom:
  replicaCount: 3
  stateless: true
```

`HEADROOM_STATELESS=1` disables all filesystem writes. You lose savings
history, the dashboard's data, and local memory — the proxy becomes a pure
compress-and-forward service. That is usually the right trade above a certain
request volume, but make it knowingly.

`stateless: true` is incompatible with `memory.enabled: true` (upstream
disables memory when stateless is set); the chart fails on that combination.

For one replica with memory: scale vertically. Compression is CPU-bound and
model loading is memory-bound, so raise `resources.limits.memory` before adding
CPU.

### Ix

The memory-layer is stateless and scales horizontally; ArangoDB single-instance
is the bottleneck. Under concurrent `ix map` load you will see write conflicts
before you see CPU saturation — tune the client side first
([below](#tuning-a-shared-ix-backend)), then give ArangoDB more memory.

---

## Tuning a shared Ix backend

Client-side environment variables, set per developer or team-wide:

| Variable | Default | Effect |
| --- | --- | --- |
| `IX_COMMIT_CONFLICT_RETRIES` | 6 | retries on an ArangoDB write conflict |
| `IX_COMMIT_CONCURRENCY` | 8 | parallel commit requests per client |
| `IX_COMMIT_HTTP_MAX_FILES` | 1000 | files per commit request |
| `IX_MAP_DEADLINE_MS` | 900000 | overall `ix map` deadline |
| `IX_AUTO_MAP_CLOUD` | unset | `1` re-enables background auto-map |

With several people mapping simultaneously, write conflicts are the normal
failure. Raise the retries and lower the concurrency:

```sh
export IX_COMMIT_CONFLICT_RETRIES=12
export IX_COMMIT_CONCURRENCY=4
```

Leave `IX_AUTO_MAP_CLOUD` unset. It is off against remote backends on purpose —
turning it on means every client pushes a write on every file change, which is
exactly the load pattern that produces the conflicts above.

---

## Logs and observability

```sh
kubectl -n workgroup logs -f deploy/wg-headroom
kubectl -n workgroup logs -f deploy/wg-ix
kubectl -n workgroup logs -f deploy/wg-ix -c oauth2-proxy   # if the sidecar is enabled
kubectl -n workgroup logs -f sts/wg-ix-arangodb
```

Headroom log lines worth grepping:

| Pattern | Meaning |
| --- | --- |
| `event=proxy_open_bind` | bound non-loopback with no token — fix this |
| `memory` | which backend was actually selected at startup |
| `compression` | per-request savings |

The memory one matters if you enabled `qdrant-neo4j`: it is how you confirm the
backend was selected rather than silently falling back to local SQLite.

```sh
kubectl -n workgroup logs deploy/wg-headroom | grep -i memory
```

Headroom also writes savings history into its workspace volume and serves a
dashboard from it — persistent only while `stateless: false`.

---

## Health checks

```sh
curl -fsS https://headroom.dev.example.com/readyz     # auth-exempt
curl -fsS https://ix.dev.example.com/v1/health        # behind your auth layer
```

Both are safe for external monitoring. Do not point a monitor at Headroom's
`/health` — it is loopback-restricted and echoes configuration.

---

## Routine checks

**Weekly** — PVC utilisation, particularly ArangoDB.

**Monthly** — pull the current upstream image tags; neither project publishes a
stability guarantee for `latest`, so pin `image.tag` in production and bump it
deliberately.

**Per upgrade** — after a Headroom bump, re-check that memory selected the
right backend (the log grep above). Upstream config surfaces change; the chart
guard catches the known gap, not a future one.

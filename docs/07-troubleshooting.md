# 7. Troubleshooting

Symptom → cause, for the failures this deployment actually produces.

---

## Install-time

### `helm install` fails with a `headroom:` or `ix:` message

Working as intended. The charts validate at template time so misconfigurations
fail before they become a running deployment. The message names the exact
values key to change. Full list in
[02-install-server-k8s.md § Guard rails](02-install-server-k8s.md#guard-rails).

The two you are most likely to hit:

```
ix: refusing to expose the memory-layer with auth.mode=none.
```
Set `ix.auth.mode` to `basic` or `oauth2Proxy`. Override with
`ix.auth.acknowledgeUnauthenticated: true` only if you have decided your
network makes it acceptable — [05-security.md](05-security.md) explains what
you are accepting.

```
headroom: memory.enabled=true needs an image built with patches/0001-…
```
The published image cannot be pointed at a Neo4j. Build the patched image
([patches/README.md](../patches/README.md)) or leave `memory.enabled: false`.

### `expose.mode=gateway requires the Gateway API … not installed`

```sh
kubectl api-resources | grep gateway.networking
```

If empty, install the Gateway API CRDs, or use `expose.mode: ingress`.

Note `helm template` does not see your cluster's API versions unless you tell
it: add `--api-versions gateway.networking.k8s.io/v1` when rendering locally.

### `no cached repo found` / missing dependencies on the umbrella

```sh
helm dependency update charts/workgroup
```

The subcharts are `file://` dependencies and must be built before install.
`charts/workgroup/charts/` is gitignored for that reason.

---

## Headroom

### The pod stays `0/1 Running` for minutes after install

Expected on a cold start. Headroom loads compression models before it reports
ready; the startup probe allows five minutes
(`probes.startup.failureThreshold: 60` × 5s).

```sh
kubectl -n workgroup logs deploy/wg-headroom --tail=50
```

If it is still not ready after that, look at memory — model loading is
memory-bound, and an OOMKill mid-load looks like a slow start:

```sh
kubectl -n workgroup describe pod -l app.kubernetes.io/component=proxy | grep -A3 "Last State"
```

Raise `resources.limits.memory` above the 4Gi default.

### `CrashLoopBackOff` with permission errors on `/home/nonroot/.headroom`

The image runs as uid 1000 and needs `fsGroup: 1000` to write the PVC. The
chart sets this; a `podSecurityContext` override or a restrictive Pod Security
Standard can undo it.

```sh
kubectl -n workgroup get pod -l app.kubernetes.io/component=proxy \
  -o jsonpath='{.items[0].spec.securityContext}'
```

Some CSI drivers ignore `fsGroup` entirely — check your StorageClass's
`fsGroupPolicy`.

### 401 from `/v1/*`

The proxy token is missing or wrong.

```sh
kubectl -n workgroup get secret wg-headroom-secrets \
  -o jsonpath='{.data.proxy-token}' | base64 -d; echo
```

Send it as either `X-Headroom-Proxy-Token: <t>` or
`Authorization: Bearer <t>`. Through a port-forward you need neither — loopback
callers are exempt — so if a port-forward works and the hostname does not, it
is the token.

Check whether your client is actually sending the header. Some clients drop
`ANTHROPIC_CUSTOM_HEADERS`; the `curl` in
[04-connect-cli-to-server.md](04-connect-cli-to-server.md#verify) isolates
this.

### Requests are cut off mid-response

The ingress timeout. Model responses stream for minutes and most controllers
default to 60 seconds. The chart's nginx annotations cover this
(`proxy-read-timeout: 3600`, `proxy-buffering: off`) — on any other controller
you must supply the equivalent yourself via `expose.ingress.annotations`.

For Gateway API the chart sets `timeouts.request: 0s`; check your Gateway
implementation honours it, since some enforce their own ceiling.

### Savings history is empty after a restart

Either `stateless: true` (which disables all filesystem writes by design), or
`persistence.enabled: false`, or the PVC did not bind:

```sh
kubectl -n workgroup get pvc
```

### Memory is enabled but nothing is being recalled

Confirm the backend was actually selected:

```sh
kubectl -n workgroup logs deploy/wg-headroom | grep -i memory
```

If it says `local`, the image is not the patched one — the stock image accepts
the Qdrant settings but has no way to reach a Neo4j, so it falls back silently.
That silent fallback is exactly why the chart refuses `memory.enabled: true`
against the upstream image. See [patches/README.md](../patches/README.md).

Then check the datastores are reachable *from the proxy pod*. It has to be that
pod — the NetworkPolicy locks Qdrant and Neo4j to it, so a debug pod will be
refused whether or not anything is wrong. The image is Python-based, so:

```sh
kubectl -n workgroup exec deploy/wg-headroom -- python3 -c \
  "import urllib.request;print(urllib.request.urlopen('http://wg-headroom-qdrant:6333/readyz').status)"

kubectl -n workgroup exec deploy/wg-headroom -- python3 -c \
  "import socket;socket.create_connection(('wg-headroom-neo4j',7687),5);print('neo4j reachable')"
```

### Provider calls fail with 401 from Anthropic/OpenAI

That is your own key, not the proxy's. The proxy holds no provider credentials
and forwards whatever key your client sends. Check `ANTHROPIC_API_KEY` is still
set in the shell you launched the agent from — setting `ANTHROPIC_BASE_URL`
does not replace it.

---

## Ix

### `Ix backend not reachable`

```sh
ix config get endpoint
echo "$IX_ENDPOINT"        # this wins over the config file
curl -fsS "$IX_ENDPOINT/v1/health"
```

Common causes, in the order they occur:

1. **`IX_ENDPOINT` still points at localhost** while a port-forward has died.
2. **The local Docker backend is running** and shadowing the remote one —
   `ix docker stop`.
3. **The auth layer is rejecting you** — a basic-auth 401 reads as
   "not reachable". `curl -v` shows the difference.
4. **The memory-layer is not ready** because ArangoDB is not:
   ```sh
   kubectl -n workgroup get pods -l app.kubernetes.io/instance=wg
   kubectl -n workgroup logs deploy/wg-ix -c wait-for-arangodb
   ```

### The memory-layer pod is stuck in `Init:0/1`

The `wait-for-arangodb` init container is polling. Look at ArangoDB:

```sh
kubectl -n workgroup logs sts/wg-ix-arangodb --tail=50
```

A password mismatch is the usual cause: ArangoDB persists its root user on
disk, so if the volume survived a reinstall that regenerated the Secret, the
two disagree. Either restore the old password into the Secret or delete the PVC
and start clean.

### `ix map` fails with write conflicts

Concurrent maps against one ArangoDB. Expected under team load; tune the client:

```sh
export IX_COMMIT_CONFLICT_RETRIES=12
export IX_COMMIT_CONCURRENCY=4
```

If it persists, ArangoDB needs more memory — see
[06-operations.md](06-operations.md#tuning-a-shared-ix-backend).

### `ix map` times out or 413s on a large repository

```sh
export IX_MAP_DEADLINE_MS=1800000     # 30 minutes
export IX_COMMIT_HTTP_MAX_FILES=250   # smaller requests
```

A 413 is the ingress body limit, not Ix. The chart sets 64 MB
(`proxy-body-size: 64m`); raise it via `ix.expose.ingress.annotations` if your
repo needs more.

### The graph is stale — changes are not showing up

Auto-map is disabled against a remote backend on purpose, so nothing re-maps
until you ask:

```sh
ix map .
```

`IX_AUTO_MAP_CLOUD=1` re-enables background mapping at the cost of a write per
change per client.

### Two people see different graphs for the same repo

They are scoped to different `workspace_id`s. Set it explicitly on both sides
(`x-ix-workspace`), or accept the separation — it is the mechanism that keeps
several developers on one backend from colliding.

### `ix doctor` reports the local backend unavailable

Correct, once your endpoint is remote and you have run `ix docker stop`.
`ix status` against the configured endpoint is the check that matters.

---

## Getting more detail

```sh
export IX_DEBUG=1
ix map . 2>&1 | tee ix-debug.log
```

```sh
kubectl -n workgroup logs -f deploy/wg-headroom
kubectl -n workgroup logs -f deploy/wg-ix
kubectl -n workgroup logs -f deploy/wg-ix -c oauth2-proxy
kubectl -n workgroup describe pod -l app.kubernetes.io/instance=wg
kubectl -n workgroup get events --sort-by=.lastTimestamp | tail -30
```

Render what Helm would apply, without touching the cluster:

```sh
helm template wg charts/workgroup -f values-prod.yaml \
  --api-versions gateway.networking.k8s.io/v1 | less
```

Remember that `lookup` returns empty outside a real install, so rendered
Secrets show freshly generated values. That is the dry run, not a rotation.

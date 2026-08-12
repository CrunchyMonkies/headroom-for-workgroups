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

### The startup probe keeps killing the pod, and the log looks fine

The banner prints, the proxy says `Press Ctrl+C to stop`, and the pod is still
restarted every few minutes. The startup probe is `GET /readyz`, and `/readyz`
is an aggregate — one unhealthy dependency holds the whole pod out of service
even though the process is running. Ask it which one:

```sh
kubectl -n workgroup exec deploy/wg-headroom -c proxy -- \
  python -c 'import urllib.request,urllib.error
try: print(urllib.request.urlopen("http://127.0.0.1:8787/readyz").read().decode())
except urllib.error.HTTPError as e: print(e.code, e.read().decode())'
```

Every check reports separately. `"memory":{"ready":false,"initialized":false}`
with everything else healthy means Headroom is up and Qdrant or Neo4j is not —
go fix that pod, not this one. `kompress` reporting `degraded` is
`"optional":true` and never blocks readiness.

### Qdrant is in `CrashLoopBackOff` with `Failed to create snapshots temp directory`

```
Panic occurred in file src/actix/mod.rs: Failed to create snapshots temp
directory at ./snapshots/tmp: PermissionDenied
```

Fixed in chart 0.1.1 — upgrade. Qdrant's working directory is `/qdrant`, its
default `snapshots_path` is the relative `./snapshots`, and that directory
comes from the image owned by root while the pod runs as uid 1000. Only the PVC
at `/qdrant/storage` is group-writable. The chart now sets
`QDRANT__STORAGE__SNAPSHOTS_PATH=/qdrant/storage/snapshots`; on an older chart
you can set the same variable yourself. Headroom will sit at `0/1` with
`memory.ready: false` for as long as this lasts.

### `helm upgrade` hangs and the replacement pod sits `Pending` forever

```
0/12 nodes are available: 1 node(s) didn't match PersistentVolume's node
affinity, 4 Insufficient memory, ...
```

Fixed in chart 0.1.2 — upgrade. The workspace claim is `ReadWriteOnce`, and a
RollingUpdate surges the new pod *before* retiring the old one: the new pod
cannot mount a volume the old pod still holds, and the old pod is not retired
until the new one is Ready. Neither side moves. On local or topology-bound
storage it is worse, because the new pod is also pinned to the volume's node and
has to fit there alongside the pod it is replacing. 0.1.2 sets
`strategy: Recreate` whenever `persistence.enabled` and not `stateless`.

To unwedge a running 0.1.0/0.1.1 install, delete the outgoing pod so the new one
can take the volume:

```sh
kubectl -n workgroup delete pod -l app.kubernetes.io/component=proxy \
  --field-selector status.phase=Running
```

### The proxy is `OOMKilled` on a node that is not out of memory

```
Last State: Terminated   Reason: OOMKilled   Exit Code: 137
```

Check whether the kernel — not the container's own limit — did the killing:

```sh
kubectl get events -A --field-selector reason=SystemOOM
```

If that lists other victims on the same node (`calico-node`, `cadvisor`, and
whatever else is unlucky), the node is oversubscribed and the proxy is
collateral. Its default `resources` request 512Mi and cap at 4Gi, so it is
Burstable with a wide burst window — which makes it a prime candidate for the
kernel's OOM killer on a contended node, regardless of how much it is actually
using.

The reason it cannot simply move is the workspace PVC. On local or
topology-bound storage the bound PV carries a node affinity, so the proxy is
pinned to whichever node that volume lives on — permanently, and independently
of where there is now room:

```sh
kubectl get pv "$(kubectl -n workgroup get pvc wg-headroom-workspace \
  -o jsonpath='{.spec.volumeName}')" -o jsonpath='{.spec.nodeAffinity}'
```

Compare against real capacity (`kubectl describe node <n> | grep -A5 'Allocated
resources'`). If the pinned node is the full one, deleting the claim is the fix
— with `WaitForFirstConsumer` it re-binds wherever the pod actually schedules:

```sh
kubectl -n workgroup scale deploy/wg-headroom --replicas=0
kubectl -n workgroup delete pvc wg-headroom-workspace
helm upgrade --install wg oci://ghcr.io/crunchymonkies/charts/workgroup \
  --version <same version> -n workgroup --reuse-values
kubectl -n workgroup scale deploy/wg-headroom --replicas=1
```

**The upgrade in the middle is not optional.** Unlike the Qdrant, Neo4j and
ArangoDB claims — which are StatefulSet `volumeClaimTemplates` and are recreated
automatically — the workspace claim is an ordinary chart resource. Delete it and
nothing brings it back on its own: the proxy sits `Pending` on
`persistentvolumeclaim "wg-headroom-workspace" not found` indefinitely, which
looks like a scheduling problem and is not one. Re-running the release recreates
it, and `WaitForFirstConsumer` then binds it wherever the pod lands.

Under the RKE2/k3s `HelmChart` CRD there is no `helm` binary to run, so force
helm-controller to reconcile by deleting its completed job instead:

```sh
kubectl -n kube-system delete job helm-install-<helmchart-name>
```

**That volume is not empty.** It holds the savings/compression history, the
proxy log, and — with `memory.enabled=false` — the entire local SQLite memory
store. Deleting it is cheap on a fresh install and lossy on an established one;
with the `qdrant-neo4j` backend the recall corpus lives in Qdrant and Neo4j, so
only the history and logs are lost. Back it up first if either matters.

Pin it deliberately if the cluster has one node that should host this — set
`nodeSelector` so the first bind lands there, rather than discovering months
later that it landed somewhere full.

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

### `/readyz` says `"memory":{"initialized":false}` and the log has no error

Look in the pod's own log file, not `kubectl logs` — the banner goes to stdout
but the logger writes to the workspace:

```sh
kubectl -n workgroup exec deploy/wg-headroom -c proxy -- \
  grep -i memory /home/nonroot/.headroom/logs/proxy.log | tail
```

`Memory: backend initialization failed (startup continues): Missing
credentials … set the OPENAI_API_KEY environment variable` means the
embeddings key is missing or wrong. Qdrant stores vectors; the `qdrant-neo4j`
backend produces them through an OpenAI-compatible `/v1/embeddings` endpoint.
Chart 0.1.1 refuses to render without `memory.embeddings.apiKey` or
`.existingSecret`, so this only happens on 0.1.0, on a hand-edited Secret, or
when `memory.embeddings.baseUrl` points somewhere that does not serve
`text-embedding-3-small`.

Note the shape of the failure: init is fail-open, so nothing crashes and
nothing appears on stdout. The proxy runs, answers requests, and never reports
ready — the startup probe restarts it every five minutes forever.

The same log line will instead say:

```
Memory: Failed to import qdrant-neo4j dependencies: qdrant-client not
installed. Install with: pip install 'headroom-ai[memory-stack]'
```

if the image was built without the `memory-stack` extra. Upstream's Dockerfile
defaults to `HEADROOM_EXTRAS=proxy,code`, which omits `mem0ai`,
`qdrant-client` and `neo4j` — so an image can carry patches/0001, accept every
`--memory-*` flag, and still be unable to run the backend behind them. Images
`0.1.2` and later are built with the extra and the release pipeline asserts the
three modules import before it publishes; `0.1.0` and `0.1.1` were not. Check
what you are running:

```sh
kubectl -n workgroup exec deploy/wg-headroom -c proxy -- \
  python3 -c "import qdrant_client, neo4j, mem0; print('memory-stack present')"
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
3. **An auth layer is rejecting you.** A 401 or 403 surfaces as
   "not reachable" — `curl -v "$IX_ENDPOINT/v1/health"` shows which it is, and
   the same request with `-u user:pass` proves it is the auth layer rather than
   the backend. There is no fix on the client side: the CLI cannot send
   credentials at all, so the auth layer has to come off. See
   [04-connect-cli-to-server.md](04-connect-cli-to-server.md#the-ix-cli-cannot-authenticate)
   for why, and
   [02-install-server-k8s.md](02-install-server-k8s.md#restricting-by-source-address-instead)
   for what to protect the route with instead.

   A 403 with an empty body from Envoy Gateway means a source-address rule
   denied you — you are outside the allowed CIDRs (on a VPN that egresses
   elsewhere, say):
   ```sh
   kubectl -n workgroup get securitypolicy -o yaml | grep -A4 clientCIDRs
   ```
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

### The memory-layer is `CrashLoopBackOff` and ArangoDB logs `401 … not authorized`

```
Caused by: com.arangodb.ArangoDBException: Response: 401, Error: 11 - not
authorized to execute this request
```

`/v1/health` answers 500 and both memory-layer probes fail, while ArangoDB
itself is `1/1` and healthy. The Secret and the StatefulSet read the same key,
so this is not a wiring error — ArangoDB's on-disk root user simply is not the
password in the Secret.

**On chart 0.1.2 and earlier, this is a chart bug and it happens on every
install.** The StatefulSet set `command: [arangod, …]`, which replaces the
image's `/entrypoint.sh` — and that entrypoint is the only thing that ever reads
`ARANGO_ROOT_PASSWORD`. It creates the root user by running
`arango-init-database`, gated on `[ "$1" = 'arangod' ]` and an empty data
directory. Override the entrypoint and `arangod` starts perfectly well, with the
Secret mounted, ignored, and no root user ever created. 0.1.3 changes
`command:` to `args:`, which keeps the entrypoint.

Nothing logs a complaint, which is what makes this expensive to diagnose. The
tell is the *absence* of a line — a correct first boot prints:

```
Initializing root user...Hang on...
```

If the ArangoDB log jumps straight to `ready for business` with no such line and
no `arango-init-database` output, bootstrap never ran:

```sh
kubectl -n workgroup logs wg-ix-arangodb-0 | grep -i 'initializing root'
```

Upgrading alone does not repair it, because the entrypoint's bootstrap is gated
on an empty data directory and yours is not empty. **Upgrade to 0.1.3 or later
and then delete the ArangoDB PVC**, so the fixed chart gets the empty directory
it needs:

```sh
kubectl -n workgroup delete sts wg-ix-arangodb --cascade=orphan
kubectl -n workgroup delete pod wg-ix-arangodb-0
kubectl -n workgroup delete pvc data-wg-ix-arangodb-0
# re-run the install/upgrade so helm recreates the StatefulSet
```

Do this only when the graph is empty or cheap to rebuild with `ix map`. If it is
worth keeping, dump it first with `arangodump` — root's password is the empty
string in this state, which is exactly why the dump will work.

That empty password is also the security half of this bug: an ArangoDB in this
state accepts anything that can reach port 8529. The chart's NetworkPolicy
limits that to the memory-layer pod, which is the only reason this is a bug
rather than an incident. Treat a cluster where that policy was disabled, or
where 8529 was exposed, as having had an unauthenticated graph database.

A genuinely separate way to reach the same 401 is an interrupted first boot:
if the container is killed partway through bootstrap, the directory is left
initialized with root's password never set. The repair is identical.

If instead ArangoDB's log ends with `ArangoDB … is ready for business` while
the pod is `0/1` and restarting on its liveness probe, that is the 0.1.0 probe
bug — upgrade to 0.1.1. Both probes and the init container polled
`/_api/version`, which requires authentication that none of them carry, so all
three saw 401 forever. `/_admin/server/availability` is the endpoint ArangoDB
answers anonymously, and 0.1.1 uses it in all three places. Confirm which one
you have:

```sh
kubectl -n workgroup describe pod wg-ix-arangodb-0 | grep -i 'probe failed'
```

`statuscode: 401` is this bug. Anything else is not.

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

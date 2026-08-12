# Headroom + Ix for Workgroups

Helm charts and documentation for running [Headroom](https://github.com/headroomlabs-ai/headroom)
and [Ix](https://github.com/ix-infrastructure/Ix) as **shared team services on
Kubernetes**, with each developer's local CLI pointed at them.

Both tools ship as single-developer, localhost-bound products: a Dockerfile, a
`docker-compose.yml`, and an install script that sets up a local backend.
Neither publishes a Helm chart or Kubernetes documentation. Turning them into
a workgroup deployment means solving authentication, persistence, exposure and
client→server mapping that upstream does not document. That gap is what this
repo fills.

## What you get

| Chart              | Deploys                                          | Port |
| ------------------ | ------------------------------------------------ | ---- |
| `charts/headroom`  | Headroom proxy (+ optional Qdrant & Neo4j)       | 8787 |
| `charts/ix`        | Ix memory-layer + ArangoDB                       | 8090 |
| `charts/workgroup` | Thin umbrella over both, sharing one hostname set | —    |

Plus `install.sh` / `install.ps1` for the client side, `docs/` — install,
connect, operate — and `patches/`, which carries one upstream patch needed for
Headroom's semantic memory backend.

## Quickstart

### The server

Cluster-internal first. Nothing is exposed; you reach both through
`kubectl port-forward`.

```sh
helm install wg oci://ghcr.io/crunchymonkies/charts/workgroup --version 0.1.1 \
  -n workgroup --create-namespace
```

```sh
kubectl -n workgroup port-forward svc/wg-headroom 8787:8787 &
kubectl -n workgroup port-forward svc/wg-ix 8090:8090 &
```

To publish them on real hostnames instead, see
[docs/02-install-server-k8s.md](docs/02-install-server-k8s.md).

### Each developer's machine

```sh
curl -fsSL https://raw.githubusercontent.com/CrunchyMonkies/headroom-for-workgroups/main/install.sh \
  | bash -s -- --headroom-url http://127.0.0.1:8787 --ix-url http://127.0.0.1:8090
```

```powershell
irm https://raw.githubusercontent.com/CrunchyMonkies/headroom-for-workgroups/main/install.ps1 -OutFile install.ps1
./install.ps1 -HeadroomUrl http://127.0.0.1:8787 -IxUrl http://127.0.0.1:8090
```

That installs both CLIs, stops the local Ix Docker backend that would otherwise
give you a second divergent graph, and writes
`~/.config/headroom-workgroup/env.sh` (`env.ps1` on Windows) with the endpoint
and token variables. `--dry-run` shows what it would do without doing it. Add
`--token-file ./token` once the proxy is reachable on something other than
loopback — see [docs/03](docs/03-install-cli.md).

## Releases

| Artefact | Where |
| --- | --- |
| Helm charts | `oci://ghcr.io/crunchymonkies/charts/{headroom,ix,workgroup}` |
| Patched Headroom image | `ghcr.io/crunchymonkies/headroom` — the chart default |
| `.tgz`, installers, `SHA256SUMS` | the [GitHub Release](https://github.com/CrunchyMonkies/headroom-for-workgroups/releases) |

The image is upstream Headroom at the commit pinned in
[`patches/upstream.env`](patches/upstream.env) plus one config-surface patch;
see [patches/README.md](patches/README.md) for why, and
[docs/08-releasing.md](docs/08-releasing.md) for how a release is cut.

## The two facts that shape everything else

**Headroom never holds a provider API key.** It forwards each caller's own
`x-api-key` / `authorization` header upstream. Every developer keeps using
their own Anthropic/OpenAI key; the shared server holds no provider
credentials to leak. This is what makes a team-wide proxy safe to run.

**Ix parses locally and pushes graph patches.** The `ix` CLI tree-sitter-parses
your working tree on your machine and sends the resulting graph patch over
HTTP. The server never reads your filesystem, so a remote backend genuinely
works — unlike the `POST /v1/ingest {path}` endpoint, which is the local-Docker
path and assumes a server-side path.

## Two things that will bite you

**`headroom wrap` is local-only.** It hardcodes `http://127.0.0.1:<port>` and
cannot be pointed at a remote proxy. Remote use goes through base-URL
environment variables, or a port-forward plus `headroom wrap --no-proxy`.
See [docs/04-connect-cli-to-server.md](docs/04-connect-cli-to-server.md).

**The Ix API has no authentication of any kind.** Upstream binds it to
localhost for exactly that reason, and it is fully write-capable. `charts/ix`
therefore defaults to `expose.mode: none` and *refuses to render* an Ingress
or HTTPRoute unless you configure an auth layer. See
[docs/05-security.md](docs/05-security.md).

## Documentation

| | |
| --- | --- |
| [01 Architecture](docs/01-architecture.md) | What each service is and how requests flow |
| [02 Install on Kubernetes](docs/02-install-server-k8s.md) | Helm install, values, Ingress and Gateway API, TLS |
| [03 Install the CLIs](docs/03-install-cli.md) | Per-developer client install |
| [04 Connect CLI → server](docs/04-connect-cli-to-server.md) | The mapping, per tool, with a copy-paste shell profile |
| [05 Security](docs/05-security.md) | Credential model, auth options, NetworkPolicies |
| [06 Operations](docs/06-operations.md) | Upgrades, backups, scaling, tuning |
| [07 Troubleshooting](docs/07-troubleshooting.md) | Symptoms → causes |
| [08 Releasing](docs/08-releasing.md) | Cutting a release, re-basing the patch, recovering a failed one |
| [Patches](patches/README.md) | The Headroom Neo4j config patch, and why it exists |

## Scope

This repo changes neither upstream repository. It consumes upstream's published
Ix image and both CLIs as they are; the one exception is the Headroom image,
which is rebuilt here from a pinned upstream commit plus
[one patch](patches/README.md) — with the new settings unset it behaves exactly
as upstream does, and `image.repository` points back at upstream in one line.
Ix Pro / Kartr (tunnel JWTs, `instances` config) and Headroom's beacon telemetry
worker are out of scope.

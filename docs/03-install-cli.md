# 3. Install the CLIs

This is what each developer runs on their own machine. Nothing here needs
cluster access.

---

## The short version: run the installer

`install.sh` and `install.ps1` in this repo do everything on this page *and*
the endpoint mapping from [document 4](04-connect-cli-to-server.md), including
the `ix docker stop` step below that is easy to miss.

```sh
curl -fsSL https://raw.githubusercontent.com/CrunchyMonkies/headroom-for-workgroups/main/install.sh \
  | bash -s -- --headroom-url https://headroom.example.com \
               --ix-url https://ix.example.com \
               --token-file ./headroom-token
```

```powershell
irm https://raw.githubusercontent.com/CrunchyMonkies/headroom-for-workgroups/main/install.ps1 -OutFile install.ps1
./install.ps1 -HeadroomUrl https://headroom.example.com `
              -IxUrl https://ix.example.com -TokenFile .\headroom-token
```

Both are also attached to every [release](https://github.com/CrunchyMonkies/headroom-for-workgroups/releases),
with a `SHA256SUMS` if you would rather verify before running.

Useful flags — the two scripts take the same set, spelled per platform:

| | |
| --- | --- |
| `--dry-run` / `-DryRun` | print every action, change nothing |
| `--token-file` / `-TokenFile` | read the token from a file (keeps it out of shell history) |
| `--token-command` / `-TokenCommand` | never store the token; the config calls out to your secret manager |
| `--skip-ix` / `--skip-headroom` | install one half only |
| `--write-profile` / `-WriteProfile` | edit your shell profile; off by default, the line is printed instead |
| `--no-verify` / `-NoVerify` | skip the closing reachability check |

With no token at all — the right answer when you reach the proxy through
`kubectl port-forward`, since loopback callers are exempt — just omit it.

Everything below is what the installer does for you, and what to run if you
would rather do it by hand.

---

## Headroom CLI

Python 3.13. Install as a tool, not into a project environment:

```sh
uv tool install --python 3.13 "headroom-ai[all]"
```

or

```sh
pip install "headroom-ai[all]"
```

Verify:

```sh
headroom --version
headroom --help
```

The `[all]` extra pulls the optional dependencies for the local compression
models. You can install the bare `headroom-ai` if you will only ever talk to a
remote proxy — but `[all]` costs little and keeps `headroom wrap --no-proxy`
and offline use working.

> **`npm install headroom-ai` is not this.** The npm package is the TypeScript
> SDK. It ships no CLI. If you follow a JavaScript-flavoured quickstart by
> reflex you will end up with a library and no `headroom` binary.

### What you get

| Command | Against a remote proxy |
| --- | --- |
| `headroom proxy` | runs a *local* proxy — not what you want here |
| `headroom wrap <cmd>` | **local-only**, see below |
| `headroom mcp install` | works, with `--proxy-url` |
| `headroom dashboard` | reads local state; the server's own history lives on the server |

`headroom wrap` hardcodes `http://127.0.0.1:<port>` internally and cannot be
pointed at a remote proxy. [Document 4](04-connect-cli-to-server.md) covers the
two ways around that.

---

## Ix CLI

Requires **Node 22+** and **ripgrep**.

```sh
node --version   # must be >= 22
rg --version
```

Install:

```sh
curl -fsSL https://ix-infra.com/install.sh | sh
```

PowerShell:

```powershell
irm https://ix-infra.com/install.ps1 | iex
```

Verify:

```sh
ix --version
ix doctor
```

### The installer also sets up a local backend

It configures a Docker-based ArangoDB + memory-layer stack for local use. In a
workgroup deployment **you do not want that running** — it competes with the
shared backend and gives you a second, divergent graph.

```sh
ix docker status     # check
ix docker stop       # if it is running
```

Never run `ix docker start` while pointed at the cluster endpoint.

`ix doctor` may report the local backend as unavailable after you stop it.
That is correct and expected once your endpoint is remote — `ix status` against
the configured endpoint is the check that matters.

---

## Both, on a new machine

```sh
# Headroom
uv tool install --python 3.13 "headroom-ai[all]"

# Ix
curl -fsSL https://ix-infra.com/install.sh | sh
ix docker stop 2>/dev/null || true

headroom --version && ix --version
```

That is exactly the sequence `install.sh` runs, minus the endpoint
configuration.

Next: [connect them to the server](04-connect-cli-to-server.md).

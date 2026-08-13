# 4. Connect the CLI to the server

The core of this repo. Both tools default to `localhost`; this is how you point
them at the cluster instead.

---

## Get the connection details

Ask whoever installed the charts, or read them yourself:

```sh
NS=workgroup
REL=wg

# Headroom proxy token
kubectl -n $NS get secret $REL-headroom-secrets \
  -o jsonpath='{.data.proxy-token}' | base64 -d; echo

# Hostnames, if exposed
kubectl -n $NS get ingress
kubectl -n $NS get httproute
```

If the services are cluster-internal (`expose.mode: none`, the default), you
use port-forwards instead — see [Cluster-internal](#cluster-internal-setup)
below.

---

## Headroom

### Point an agent at the proxy

Headroom is a drop-in replacement for the provider base URL. For Claude Code
and anything else that honours the Anthropic environment variables:

```sh
export ANTHROPIC_BASE_URL=https://headroom.dev.example.com
export ANTHROPIC_CUSTOM_HEADERS="X-Headroom-Proxy-Token: $HEADROOM_PROXY_TOKEN"
```

For OpenAI-compatible clients:

```sh
export OPENAI_BASE_URL=https://headroom.dev.example.com/v1
```

**Your provider API key does not change and does not go to the server's
config.** Keep `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` exactly as they were: the
proxy forwards whatever key your client sends upstream, and holds none of its
own.

> **While `auth.enabled: true`, your client must authenticate with an API key,
> not a bearer token.** The proxy's token check reads `Authorization` first and
> ignores `X-Headroom-Proxy-Token` whenever `Authorization` is present, so a
> client sending its own bearer credential is rejected with `unauthorized`
> however valid its proxy token. `x-api-key` clients are unaffected. **Claude
> Code logged in with a Claude subscription is a bearer client and cannot use
> the proxy**; the same Claude Code with `ANTHROPIC_API_KEY` set can. This is
> why `install.sh` exports `ANTHROPIC_BASE_URL` only when that key is present.
>
> There is no client-side fix — the two credentials cannot share the one
> `Authorization` slot. The server-side one is `auth.enabled: false` plus a
> source-address restriction at the gateway, which admits every client
> including subscription logins:
> [07-troubleshooting.md](07-troubleshooting.md#unauthorized-with-a-valid-proxy-token--subscriptionoauth-clients).

If your client cannot set a custom header, the token also works as a standard
bearer credential:

```sh
curl https://headroom.dev.example.com/v1/messages \
  -H "Authorization: Bearer $HEADROOM_PROXY_TOKEN" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-4-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
```

### Keep Claude Code's tool schemas deferred

Set this next to the base URL, always:

```sh
export ENABLE_TOOL_SEARCH=true
```

Claude Code normally defers tool definitions — it sends the tool *names* and
fetches a full schema only when a tool is actually used. Pointing
`ANTHROPIC_BASE_URL` at anything other than Anthropic turns that off unless
this variable is set ([headroom#746][746]), and every request then carries all
~82 schemas in full. That is ~129 KB of tokens per request, arriving at the
proxy for it to compress — work that vanishes entirely if the schemas are
never sent.

Both installers write this line for you. It is worth stating separately
because the cost is invisible: nothing errors, nothing warns, and the only
symptom is a larger-than-expected input token count on every call.

`headroom wrap` sets the same variable, and leaves a non-empty value alone —
so exporting it yourself composes with the wrapper rather than fighting it.
The accepted values are Claude Code's own, which `wrap --tool-search`
validates against but does not interpret: `true`/`1`/`yes`/`on`,
`false`/`0`/`no`/`off`, `auto`, and `auto:N` for `N` in 0–100. Only the falsy
set turns deferral off; everything else keeps it on. `true` is what both
installers write and what upstream's own `TOOL_SEARCH_DEFAULT` uses.

[746]: https://github.com/headroomlabs-ai/headroom/issues/746

### If streaming responses come back empty

A client that sends `stream: true` — which Claude Code always does — can get

```
API Error: API returned an empty or malformed response (HTTP 200)
```

That is not your client and not the gateway. Context-cache retrieval makes the
proxy buffer streamed requests and re-synthesise the SSE, and it commits the
`200` before it knows whether the upstream call worked. The fix is server-side
(`HEADROOM_NO_CCR=1`) and the symptom is worth recognising from the client
because nothing on the server reports an error:
[07-troubleshooting.md](07-troubleshooting.md#api-returned-an-empty-or-malformed-response-http-200).

### Verify

```sh
# Unauthenticated — always works, by design
curl -fsS https://headroom.dev.example.com/readyz

# Authenticated — 401 without the token
curl -s -o /dev/null -w '%{http_code}\n' https://headroom.dev.example.com/v1/messages
# => 401

curl -s -o /dev/null -w '%{http_code}\n' \
  -H "X-Headroom-Proxy-Token: $HEADROOM_PROXY_TOKEN" \
  https://headroom.dev.example.com/v1/messages
# => 400 (bad body) — but past auth, which is what you are testing
```

### The MCP surface

```sh
headroom mcp install --proxy-url https://headroom.dev.example.com
```

or set `HEADROOM_PROXY_URL` in the environment and let it pick that up.

### `headroom wrap` is local-only

`headroom wrap` launches a command with its traffic routed through a proxy —
but it builds that route as `http://127.0.0.1:<port>`, hardcoded. There is no
flag to give it a remote URL.

Two ways to keep using it:

**Port-forward, then wrap without its own proxy.** `wrap --no-proxy` skips
spawning a local proxy and uses whatever base URL the environment provides:

```sh
kubectl -n workgroup port-forward svc/wg-headroom 8787:8787 &
export ANTHROPIC_BASE_URL=http://127.0.0.1:8787
headroom wrap --no-proxy -- claude
```

Loopback callers are exempt from the proxy token, so no header is needed on
this path.

**Or skip `wrap` entirely.** Setting `ANTHROPIC_BASE_URL` in your shell profile
achieves the same routing for every agent you launch, permanently, and works
against the remote proxy directly. Set `ENABLE_TOOL_SEARCH` alongside it — that
is the one thing `wrap` was doing for you that a bare base URL does not; see
[above](#keep-claude-codes-tool-schemas-deferred).

---

## Ix

### Set the endpoint

```sh
ix config set endpoint https://ix.dev.example.com
```

That writes `~/.ix/config.yaml` (mode 0600). Or override per-shell without
touching the file:

```sh
export IX_ENDPOINT=https://ix.dev.example.com
```

`IX_ENDPOINT` wins over the config file.

### Verify

```sh
ix status
ix doctor
```

`ix status` should report the configured endpoint as reachable.

### The Ix CLI cannot authenticate

There is no way to make `ix` send credentials. Its API client builds every
request as `fetch(\`${endpoint}/v1/...\`)` with a single `Content-Type` header —
no `Authorization`, no token option, no header option, and `~/.ix/config.yaml`
accepts only `endpoint` and `format`. It does not read `.netrc`.

Nor can you smuggle credentials into the endpoint. `https://user:pass@host` is
rejected by the runtime before a packet leaves the machine:

```
Request cannot be constructed from a URL that includes credentials
```

That is the WHATWG fetch specification, not an Ix bug, so it will not be worked
around by a patch here. `install.sh` now rejects an `--ix-url` carrying
credentials for the same reason — note that `IX_ENDPOINT` in the generated
`env.sh` *overrides* `~/.ix/config.yaml`, so a bad endpoint there breaks every
`ix` command for anyone who sources their profile, however correct the config
file looks.

The consequence for deployment: **do not put an authentication layer in front
of the Ix route** — not `auth.mode: basic`, not an Envoy `SecurityPolicy` with
`basicAuth`, not an oauth2-proxy. Any of them turns every `ix` command into a
401, `ix map` as surely as `ix status`.

Protect it by reachability instead. Publish it on an address that is not
routable from the internet, and narrow it further with a source-address rule —
see the `SecurityPolicy` example using `authorization` / `principal.clientCIDRs`
in [02-install-server-k8s.md](02-install-server-k8s.md). That is a perimeter,
not a credential: everyone who can reach the address can read and write the
graph. Deploy Ix accordingly, or not at all.

### Do not start the local backend

```sh
ix docker stop
```

`ix docker start` manages a *local* ArangoDB + memory-layer. Running it while
your endpoint is remote gives you two graphs and a confusing set of results.

### Map a repository

```sh
cd ~/src/my-service
ix map .
ix explain SomeSymbol
```

The parse happens on your machine; what goes over the wire is the extracted
graph patch. Your source is never uploaded as source.

### Auto-map is off against a remote backend — deliberately

Ix normally re-maps in the background as files change. Against a remote
endpoint it disables that, because every client would push a write on every
keystroke-level change. So on a shared backend, `ix map .` is something you run
when you want the graph refreshed.

To opt back in, if you have decided the write volume is acceptable:

```sh
export IX_AUTO_MAP_CLOUD=1
```

### Per-developer scoping

Ix scopes by `workspace_id` and `system_id`, so several developers and several
repositories share one backend without colliding. Per request these are the
`x-ix-workspace` and `x-ix-system` headers; for normal CLI use the defaults
derived from the repository are usually what you want. Set them explicitly if
two people are mapping the same repo and you want separate graphs.

---

## Cluster-internal setup

With the default `expose.mode: none`, both Services are ClusterIP. This is the
recommended starting point.

```sh
kubectl -n workgroup port-forward svc/wg-headroom 8787:8787 &
kubectl -n workgroup port-forward svc/wg-ix       8090:8090 &

export ANTHROPIC_BASE_URL=http://127.0.0.1:8787
export ENABLE_TOOL_SEARCH=true
ix config set endpoint http://127.0.0.1:8090
```

No Headroom token needed — the forward arrives as loopback, which is exempt.

The forwards die when your laptop sleeps or the pod restarts. `kubectl
port-forward` does not reconnect on its own; wrap it in a retry loop or a
supervisor if you rely on it daily.

---

## Copy-paste shell profile

This is the block [`install.sh`](../install.sh) writes to
`~/.config/headroom-workgroup/env.sh` for you (mode 0600), and `install.ps1`
writes to `env.ps1`. Neither touches your shell profile unless you pass
`--write-profile` / `-WriteProfile` — by default they print the one line to add:

```sh
[ -f ~/.config/headroom-workgroup/env.sh ] && . ~/.config/headroom-workgroup/env.sh
```

To do it by hand instead, add the following to `~/.zshrc` / `~/.bashrc`. Fill in
the two hostnames and store the token somewhere real (a password manager,
`pass`, your keychain) rather than inlining it — `install.sh --token-command`
generates exactly that form.

### Exposed servers

```sh
# ---- Headroom (shared proxy) -------------------------------------------
export ANTHROPIC_BASE_URL="https://headroom.dev.example.com"
export OPENAI_BASE_URL="https://headroom.dev.example.com/v1"
export HEADROOM_PROXY_TOKEN="$(pass show workgroup/headroom-token)"
export ANTHROPIC_CUSTOM_HEADERS="X-Headroom-Proxy-Token: $HEADROOM_PROXY_TOKEN"
export ENABLE_TOOL_SEARCH=true   # keeps tool deferral on behind a custom base URL

# Your own provider key — unchanged, and never sent to the server's config.
export ANTHROPIC_API_KEY="$(pass show anthropic/api-key)"

# ---- Ix (shared codebase graph) ----------------------------------------
export IX_ENDPOINT="https://ix.dev.example.com"
```

### Cluster-internal servers

```sh
# ---- port-forwards ------------------------------------------------------
wg-forward() {
  kubectl -n workgroup port-forward svc/wg-headroom 8787:8787 &
  kubectl -n workgroup port-forward svc/wg-ix       8090:8090 &
}

export ANTHROPIC_BASE_URL="http://127.0.0.1:8787"
export OPENAI_BASE_URL="http://127.0.0.1:8787/v1"
export ENABLE_TOOL_SEARCH=true   # loopback is still a custom base URL
export IX_ENDPOINT="http://127.0.0.1:8090"
export ANTHROPIC_API_KEY="$(pass show anthropic/api-key)"
```

### Verify the whole thing

```sh
curl -fsS "${ANTHROPIC_BASE_URL}/readyz"      && echo "headroom ok"
curl -fsS "${IX_ENDPOINT}/v1/health"          && echo "ix ok"
ix status
```

---

## Tuning for a shared backend

Ix's commit path has knobs that matter more when several people map at once:

| Variable | Default | Raise / lower when |
| --- | --- | --- |
| `IX_COMMIT_HTTP_MAX_FILES` | 1000 | huge repos hitting request size limits — lower it |
| `IX_COMMIT_CONCURRENCY` | 8 | the backend is saturated — lower it |
| `IX_COMMIT_CONFLICT_RETRIES` | 6 | frequent ArangoDB write conflicts — raise it |
| `IX_MAP_DEADLINE_MS` | 900000 | very large first-time maps time out — raise it |

`IX_COMMIT_CONFLICT_RETRIES` is the one that usually needs attention:
concurrent `ix map` runs against one ArangoDB produce lock conflicts, and the
retry is how they resolve. See [06-operations.md](06-operations.md).

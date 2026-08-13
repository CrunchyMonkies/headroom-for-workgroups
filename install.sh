#!/usr/bin/env bash
#
# headroom-for-workgroups — client bootstrap for Linux and macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/CrunchyMonkies/headroom-for-workgroups/main/install.sh \
#     | bash -s -- --headroom-url https://headroom.example.com \
#                  --ix-url https://ix.example.com --token-file ./token
#
# Installs the Headroom and Ix CLIs, stops the local Ix Docker backend (which
# would otherwise give you a second, divergent graph), and writes the endpoint
# and token configuration. Re-running it is safe.
#
# See docs/03-install-cli.md and docs/04-connect-cli-to-server.md for what this
# does by hand.
#
# The whole body lives in functions and the file ends with `main "$@"`, so a
# truncated download cannot execute half an installation.

set -euo pipefail

# ── globals ──────────────────────────────────────────────────────────────────

HEADROOM_URL=${HEADROOM_URL:-}
IX_URL=${IX_URL:-}
TOKEN=${HEADROOM_PROXY_TOKEN:-}
TOKEN_COMMAND=""
SKIP_HEADROOM=0
SKIP_IX=0
WRITE_PROFILE=0
NO_VERIFY=0
DRY_RUN=0

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/headroom-workgroup"
ENV_FILE="$CONFIG_DIR/env.sh"
PROFILE_MARKER="# >>> headroom-for-workgroups >>>"
PROFILE_MARKER_END="# <<< headroom-for-workgroups <<<"

warnings=0

# ── output ───────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

head_() { printf '\n%s── %s%s\n' "$C_B" "$*" "$C_0"; }
ok()    { printf '  %s[ok]%s   %s\n' "$C_G" "$C_0" "$*"; }
info()  { printf '         %s\n' "$*"; }
warn()  { printf '  %s[warn]%s %s\n' "$C_Y" "$C_0" "$*"; warnings=$((warnings + 1)); }
die()   { printf '\n  %s[error]%s %s\n\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# run <command...> — the single place dry-run is honoured.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry]%s  %s\n' "$C_Y" "$C_0" "$*"
    return 0
  fi
  "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
headroom-for-workgroups client installer

USAGE
  install.sh [options]

CONNECTION
  --headroom-url URL     Base URL of the Headroom proxy (env: HEADROOM_URL)
  --ix-url URL           Base URL of the Ix memory-layer  (env: IX_URL)

  --token TOKEN          Headroom proxy token, if the proxy has a token gate.
                         Omit it for one that does not, and every client is
                         routed — including a subscription/OAuth Claude Code,
                         which a gated proxy cannot admit at all. Lands in
                         your shell history — prefer one of the two below.
  --token-file PATH      Read the token from a file.
  --token-stdin          Read the token from stdin. Not usable in the
                         `curl … | bash` form, which already owns stdin.
  --token-command CMD    Do not store the token at all: the config file will
                         run CMD to fetch it, e.g.
                           --token-command 'pass show workgroup/headroom-token'

COMPONENTS
  --skip-headroom        Do not install the Headroom CLI
  --skip-ix              Do not install the Ix CLI

BEHAVIOUR
  --write-profile        Append a source line to ~/.bashrc and ~/.zshrc.
                         Off by default; the line is printed instead.
  --no-verify            Skip the post-install reachability checks
  --dry-run              Print every action, change nothing
  -h, --help             This text

ENVIRONMENT
  INSTALL_DIR            Passed through to the upstream Ix installer
  XDG_CONFIG_HOME        Config location (default ~/.config)

Cluster-internal servers (the chart default, expose.mode=none) are reached with
kubectl port-forward, so pass the loopback URLs:

  install.sh --headroom-url http://127.0.0.1:8787 --ix-url http://127.0.0.1:8090

Loopback callers are exempt from the Headroom token, so no --token is needed
on that path either.
EOF
}

# ── argument parsing ─────────────────────────────────────────────────────────

parse_args() {
  local token_sources=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --headroom-url)   HEADROOM_URL=${2:?--headroom-url needs a value}; shift 2 ;;
      --ix-url)         IX_URL=${2:?--ix-url needs a value}; shift 2 ;;
      --token)
        TOKEN=${2:?--token needs a value}; token_sources=$((token_sources + 1)); shift 2
        warn "--token puts the token in your shell history; --token-file or --token-command avoid that"
        ;;
      --token-file)
        local f=${2:?--token-file needs a path}
        [ -r "$f" ] || die "cannot read token file: $f"
        # Trim whitespace/newline; `kubectl get secret -o jsonpath | base64 -d`
        # output usually has none, but a hand-edited file will.
        TOKEN=$(tr -d '[:space:]' <"$f")
        token_sources=$((token_sources + 1)); shift 2
        ;;
      --token-stdin)
        TOKEN=$(tr -d '[:space:]')
        token_sources=$((token_sources + 1)); shift
        ;;
      --token-command)
        TOKEN_COMMAND=${2:?--token-command needs a command}
        token_sources=$((token_sources + 1)); shift 2
        ;;
      --skip-headroom)  SKIP_HEADROOM=1; shift ;;
      --skip-ix)        SKIP_IX=1; shift ;;
      --write-profile)  WRITE_PROFILE=1; shift ;;
      --no-verify)      NO_VERIFY=1; shift ;;
      --dry-run)        DRY_RUN=1; shift ;;
      -h|--help)        usage; exit 0 ;;
      *)                usage >&2; die "unknown option: $1" ;;
    esac
  done

  [ "$token_sources" -gt 1 ] && die "give the token exactly one way"

  if [ "$SKIP_HEADROOM" -eq 1 ] && [ "$SKIP_IX" -eq 1 ]; then
    die "--skip-headroom and --skip-ix together leave nothing to do"
  fi

  # A URL is only required for a component we are actually configuring.
  [ "$SKIP_HEADROOM" -eq 0 ] && [ -z "$HEADROOM_URL" ] && die "--headroom-url is required (or --skip-headroom)"
  [ "$SKIP_IX" -eq 0 ] && [ -z "$IX_URL" ] && die "--ix-url is required (or --skip-ix)"

  HEADROOM_URL=${HEADROOM_URL%/}
  IX_URL=${IX_URL%/}

  # Reject credentials in the Ix URL rather than writing a config that cannot
  # work. The ix CLI issues every request through fetch(), and the WHATWG spec
  # makes fetch() throw on a URL carrying userinfo —
  #   Request cannot be constructed from a URL that includes credentials
  # — before a packet is sent. Worse, this fails silently at install time and
  # loudly later: IX_ENDPOINT in env.sh overrides ~/.ix/config.yaml, so a
  # developer who sources the profile gets a CLI that is broken for every
  # command, having watched the installer report success.
  case ${IX_URL#*://} in
    *@*) die "--ix-url must not contain credentials.

  The ix CLI cannot send them: it has no Authorization header, no token
  option, and no .netrc support, and its HTTP client rejects a URL with
  credentials outright. Putting them here produces a config that fails on
  every command.

  Pass the bare URL and protect the endpoint at the network layer instead —
  see docs/04-connect-cli-to-server.md." ;;
  esac
  return 0
}

# ── preflight ────────────────────────────────────────────────────────────────
#
# Everything is checked before anything is installed. Failing halfway through
# leaves a machine that is neither the old state nor the new one, and this
# script is most often run by someone who did not write it.

preflight() {
  head_ "preflight"

  local os arch
  os=$(uname -s); arch=$(uname -m)
  info "$os/$arch"
  case "$os" in
    Linux|Darwin) ;;
    *) die "unsupported platform: $os (use install.ps1 on Windows)" ;;
  esac

  have curl || die "curl is required"
  ok "curl"

  local missing=0

  if [ "$SKIP_HEADROOM" -eq 0 ]; then
    if have uv; then
      ok "uv (preferred installer for headroom)"
    elif have pipx; then
      ok "pipx (headroom fallback)"
    elif have python3 && python3 -m pip --version >/dev/null 2>&1; then
      warn "no uv or pipx — falling back to 'pip install --user'"
    else
      printf '  %s[FAIL]%s no uv, pipx, or python3+pip for the Headroom CLI\n' "$C_R" "$C_0"
      info "install uv:  curl -LsSf https://astral.sh/uv/install.sh | sh"
      missing=1
    fi
  fi

  if [ "$SKIP_IX" -eq 0 ]; then
    if have node; then
      local major
      major=$(node -v 2>/dev/null | sed -e 's/^v//' -e 's/\..*//')
      if [ -n "$major" ] && [ "$major" -ge 22 ] 2>/dev/null; then
        ok "node $(node -v)"
      else
        printf '  %s[FAIL]%s node %s is too old — Ix needs 22+\n' "$C_R" "$C_0" "$(node -v)"
        missing=1
      fi
    else
      printf '  %s[FAIL]%s node not found — Ix needs 22+\n' "$C_R" "$C_0"
      missing=1
    fi

    if have rg; then
      ok "ripgrep"
    else
      printf '  %s[FAIL]%s ripgrep (rg) not found — Ix needs it to walk repositories\n' "$C_R" "$C_0"
      missing=1
    fi
  fi

  if [ "$missing" -ne 0 ]; then
    # A dry run changes nothing, so there is nothing to protect by aborting —
    # and reporting the whole picture is more useful than stopping at the first
    # gap. A real run stops here.
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "prerequisites missing — a real run would stop here"
    else
      die "install the missing prerequisites and re-run"
    fi
  fi
}

# ── the Headroom CLI ─────────────────────────────────────────────────────────

install_headroom() {
  head_ "headroom CLI"

  if have headroom; then
    info "already installed: $(headroom --version 2>/dev/null || echo 'version unknown')"
  fi

  # The `[all]` extra pulls the local compression models. It costs little and
  # keeps `headroom wrap --no-proxy` and offline use working.
  if have uv; then
    run uv tool install --python 3.13 --force "headroom-ai[all]"
  elif have pipx; then
    run pipx install --force "headroom-ai[all]"
  else
    # --user, never sudo: a root-owned site-packages is a worse problem than
    # a PATH warning.
    run python3 -m pip install --user --upgrade "headroom-ai[all]"
  fi

  ensure_path
  if [ "$DRY_RUN" -eq 0 ]; then
    if have headroom; then
      ok "headroom $(headroom --version 2>/dev/null || echo installed)"
    else
      warn "headroom installed but not on PATH — see the note at the end"
    fi
  fi
}

# ── the Ix CLI ───────────────────────────────────────────────────────────────

install_ix() {
  head_ "ix CLI"

  if have ix; then
    info "already installed: $(ix --version 2>/dev/null || echo 'version unknown')"
  fi

  # Delegate to upstream rather than reimplementing their release layout
  # (ix-<version>-<os>-<arch>.tar.gz, the /usr/local/bin then ~/.local/bin
  # preference, $IX_HOME). It would rot the first time they change any of it.
  # Their installer already honours INSTALL_DIR, which we pass straight through.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry]%s  curl -fsSL https://ix-infra.com/install.sh | sh\n' "$C_Y" "$C_0"
  else
    curl -fsSL https://ix-infra.com/install.sh | sh
  fi

  ensure_path

  # The upstream installer sets up a local Docker ArangoDB + memory-layer. On a
  # shared backend that is actively harmful: two graphs, divergent results. This
  # is the step hand-installers forget (docs/03-install-cli.md).
  head_ "local Ix backend"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry]%s  ix docker stop\n' "$C_Y" "$C_0"
  elif have ix; then
    if ix docker stop >/dev/null 2>&1; then
      ok "local backend stopped — the shared one is the only graph"
    else
      ok "no local backend running"
    fi
  else
    warn "ix not on PATH yet; run 'ix docker stop' once it is"
  fi
}

# Installers drop binaries in places that may not be on this shell's PATH yet.
# Add the usual suspects for the rest of this run so the config steps below can
# actually call `ix` and `headroom`.
ensure_path() {
  local d
  for d in "$HOME/.local/bin" "/usr/local/bin" "$HOME/.ix/bin"; do
    case ":$PATH:" in
      *":$d:"*) ;;
      *) [ -d "$d" ] && PATH="$d:$PATH" ;;
    esac
  done
  export PATH
}

# ── configuration ────────────────────────────────────────────────────────────

configure() {
  head_ "configuration"

  if [ "$SKIP_IX" -eq 0 ]; then
    # IX_ENDPOINT in env.sh wins over this at runtime, but writing the config
    # file too means `ix` works in a shell that never sourced env.sh.
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  %s[dry]%s  ix config set endpoint %s\n' "$C_Y" "$C_0" "$IX_URL"
    elif have ix; then
      ix config set endpoint "$IX_URL" >/dev/null
      ok "ix endpoint → $IX_URL  (~/.ix/config.yaml)"
    else
      warn "ix not on PATH; run: ix config set endpoint $IX_URL"
    fi
  fi

  write_env_file
}

# The token line, chosen by how the caller supplied the credential.
# The single quotes below are deliberate: these strings are shell source being
# written into a file, and must not expand here.
# shellcheck disable=SC2016
token_line() {
  if [ -n "$TOKEN_COMMAND" ]; then
    printf 'export HEADROOM_PROXY_TOKEN="$(%s)"\n' "$TOKEN_COMMAND"
  elif [ -n "$TOKEN" ]; then
    printf 'export HEADROOM_PROXY_TOKEN=%s\n' "$TOKEN"
  else
    printf '# export HEADROOM_PROXY_TOKEN="$(pass show workgroup/headroom-token)"\n'
  fi
}

# shellcheck disable=SC2016  # writing shell source, expansion is the reader's job
write_env_file() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s[dry]%s  write %s (mode 0600)\n' "$C_Y" "$C_0" "$ENV_FILE"
    return 0
  fi

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  # umask before creation, not chmod after: never let the file exist,
  # even briefly, with the token in it and group/other read bits set.
  local old_umask
  old_umask=$(umask)
  umask 077

  {
    echo "# Written by headroom-for-workgroups install.sh. Safe to edit."
    echo "# Source it from your shell profile:"
    echo "#   [ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
    echo

    if [ "$SKIP_HEADROOM" -eq 0 ]; then
      echo "# ---- Headroom (shared compression proxy) ----"
      echo
      echo "# Your own provider key is NOT set here and does not change. The proxy"
      echo "# holds no provider credentials — it forwards whatever key your client"
      echo "# sends. Keep ANTHROPIC_API_KEY / OPENAI_API_KEY exactly as they were."
      echo

      if [ -n "$TOKEN" ] || [ -n "$TOKEN_COMMAND" ]; then
        token_line
        echo
        echo "# Routing is enabled only for an API-key client, because on a proxy"
        echo "# with a token gate that is the only kind it can admit. The gate"
        echo "# reads Authorization first and ignores X-Headroom-Proxy-Token"
        echo "# whenever Authorization is present — so a client sending its own"
        echo "# bearer credential is rejected with 'unauthorized' even though it"
        echo "# supplied a perfectly valid proxy token. A subscription/OAuth login"
        echo "# to Claude Code is exactly that case, and there is no header left"
        echo "# to move either credential into."
        echo "#"
        echo "# Exporting ANTHROPIC_BASE_URL unconditionally would therefore break"
        echo "# such a client on its next launch, having worked before. Clients"
        echo "# that authenticate with x-api-key are unaffected and route normally."
        echo "#"
        echo "# ANTHROPIC_CUSTOM_HEADERS is set inside the same guard on purpose."
        echo "# The client attaches it to whatever host it talks to, so setting it"
        echo "# while nothing routes to the proxy would send the proxy token to the"
        echo "# provider on every request — a credential handed to a party that has"
        echo "# no use for it, and one more place it can be logged."
        echo "if [ -n \"\${ANTHROPIC_API_KEY:-}\" ]; then"
        echo "  export ANTHROPIC_BASE_URL=$HEADROOM_URL"
        echo '  export ANTHROPIC_CUSTOM_HEADERS="X-Headroom-Proxy-Token: $HEADROOM_PROXY_TOKEN"'
        echo "fi"
        echo "if [ -n \"\${OPENAI_API_KEY:-}\" ]; then"
        echo "  export OPENAI_BASE_URL=$HEADROOM_URL/v1"
        echo "fi"
        echo
        echo "# Force it on regardless (an API-key client the variables above"
        echo "# cannot see, for instance) — both lines, or the proxy rejects you:"
        echo "#   export ANTHROPIC_BASE_URL=$HEADROOM_URL"
        echo "#   export ANTHROPIC_CUSTOM_HEADERS=\"X-Headroom-Proxy-Token: \$HEADROOM_PROXY_TOKEN\""
      else
        echo "# No proxy token was given, so this routes every client"
        echo "# unconditionally — including a subscription/OAuth login to Claude"
        echo "# Code, which a token-gated proxy cannot admit at all."
        echo "#"
        echo "# Why that is safe to assume: the gate is skipped entirely when the"
        echo "# proxy has no token configured, and the caller's Authorization"
        echo "# header then passes straight through to the provider untouched."
        echo "# Such a deployment is protected by reachability instead — a source"
        echo "# CIDR rule at its gateway, or a private network."
        echo "#"
        echo "# ANTHROPIC_CUSTOM_HEADERS is deliberately NOT set. There is no"
        echo "# token to send, and setting one would only leak it to the provider."
        echo "#"
        echo "# If you point these at a proxy that DOES have a token gate, an"
        echo "# API-key client will get 401 {\"error\":\"unauthorized\"} on every"
        echo "# request. Re-run install.sh with --token-file/--token-command and"
        echo "# it will write the guarded form instead."
        echo "export ANTHROPIC_BASE_URL=$HEADROOM_URL"
        echo "export OPENAI_BASE_URL=$HEADROOM_URL/v1"
        echo
        echo "# Opt back out for one shell without editing this file:"
        echo "#   unset ANTHROPIC_BASE_URL OPENAI_BASE_URL"
      fi
      echo
    fi

    if [ "$SKIP_IX" -eq 0 ]; then
      echo "# ---- Ix (shared codebase graph) ----"
      echo "export IX_ENDPOINT=$IX_URL"
      echo
      echo "# Auto-map is off against a remote backend on purpose: every client"
      echo "# would push a write on every file change. Run 'ix map .' when you"
      echo "# want the graph refreshed. IX_AUTO_MAP_CLOUD=1 opts back in."
    fi
  } >"$ENV_FILE"

  umask "$old_umask"
  chmod 600 "$ENV_FILE"

  ok "wrote $ENV_FILE (0600)"
  if [ -n "$TOKEN" ] && [ -z "$TOKEN_COMMAND" ]; then
    info "the token is stored in that file in clear text; --token-command keeps it in a secret manager instead"
  elif [ -z "$TOKEN" ] && [ -z "$TOKEN_COMMAND" ] && [ "$SKIP_HEADROOM" -eq 0 ]; then
    info "no token given — every client routes through the proxy, which is right"
    info "  for a proxy with no token gate. If it has one, /v1/* will 401; re-run"
    info "  with --token-file or --token-command."
  fi
}

# ── shell profile ────────────────────────────────────────────────────────────

profile_snippet() {
  printf '%s\n[ -f "%s" ] && . "%s"\n%s\n' \
    "$PROFILE_MARKER" "$ENV_FILE" "$ENV_FILE" "$PROFILE_MARKER_END"
}

write_profile() {
  head_ "shell profile"

  # Default to printing. The upstream Ix installer deliberately does not edit
  # shell profiles, and a bootstrap script rewriting someone's rc file
  # unasked is worse than one extra copy-paste.
  if [ "$WRITE_PROFILE" -eq 0 ]; then
    info "add this to ~/.bashrc or ~/.zshrc (or re-run with --write-profile):"
    printf '\n'
    printf '    [ -f "%s" ] && . "%s"\n' "$ENV_FILE" "$ENV_FILE"
    printf '\n'
    return 0
  fi

  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    if grep -qF "$PROFILE_MARKER" "$rc" 2>/dev/null; then
      ok "$rc already sources it"
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  %s[dry]%s  append the source block to %s\n' "$C_Y" "$C_0" "$rc"
    else
      { printf '\n'; profile_snippet; } >>"$rc"
      ok "appended to $rc"
    fi
  done
}

# ── verification ─────────────────────────────────────────────────────────────

verify() {
  [ "$NO_VERIFY" -eq 1 ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0

  head_ "verify"

  if [ "$SKIP_HEADROOM" -eq 0 ]; then
    # /readyz is auth-exempt by design, so this tests reachability without
    # needing the token to be right.
    if curl -fsS --max-time 10 "$HEADROOM_URL/readyz" >/dev/null 2>&1; then
      ok "$HEADROOM_URL/readyz"
    else
      warn "$HEADROOM_URL/readyz unreachable — fine if the cluster is not up or the port-forward is not running"
    fi
  fi

  if [ "$SKIP_IX" -eq 0 ] && have ix; then
    if ix status >/dev/null 2>&1; then
      ok "ix status against $IX_URL"
    else
      warn "'ix status' did not succeed — check the endpoint and any auth layer in front of it"
    fi
  fi
}

# ── summary ──────────────────────────────────────────────────────────────────

# shellcheck disable=SC2016  # the printf below quotes a command for the reader
summary() {
  head_ "done"

  [ "$SKIP_HEADROOM" -eq 0 ] && info "headroom  → $HEADROOM_URL"
  [ "$SKIP_IX" -eq 0 ]       && info "ix        → $IX_URL"
  info "config    → $ENV_FILE"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n  %sdry run — nothing was installed or written%s\n\n' "$C_Y" "$C_0"
    return 0
  fi

  printf '\n  Start a new shell (or source the file), then:\n\n'
  printf '    . "%s"\n' "$ENV_FILE"
  [ "$SKIP_IX" -eq 0 ] && printf '    ix status\n'
  [ "$SKIP_HEADROOM" -eq 0 ] && printf '    curl -fsS "$ANTHROPIC_BASE_URL/readyz"\n'
  printf '\n'

  if [ "$warnings" -gt 0 ]; then
    printf '  %s%d warning(s) above%s\n\n' "$C_Y" "$warnings" "$C_0"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  preflight
  if [ "$SKIP_HEADROOM" -eq 0 ]; then install_headroom; fi
  if [ "$SKIP_IX" -eq 0 ]; then install_ix; fi
  configure
  write_profile
  verify
  summary
}

main "$@"

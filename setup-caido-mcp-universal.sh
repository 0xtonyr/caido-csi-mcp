#!/usr/bin/env bash
# setup-caido-mcp-universal.sh — Caido <-> CSI/CAI integration via MCP (plug and play)
#
# Supports: Linux (Kali/Debian/Ubuntu...) and macOS, on amd64 (x86_64) and arm64 (aarch64/Apple Silicon).
# Detects OS, architecture and shell, installs whatever is missing (Go, uv), starts the bridge,
# generates ~/.csi/start-redteam.sh and registers the `csi-redteam` alias in ~/.zshrc or
# ~/.bashrc (depending on the shell). After that, just open a new terminal and
# type `csi-redteam`.
#
# ASSUMED prerequisites: git, docker, csi (with the `cai` framework) and a running Caido instance.
#
# Usage:
#   ./setup-caido-mcp-universal.sh [--shell zsh|bash] [--no-alias] [--yes]
#
# Optional variables: CAIDO_URL, BRIDGE_HOST, BRIDGE_PORT, CSI_ASSUME_YES=1
# Idempotent: safe to run as many times as you want.

set -euo pipefail

CAIDO_DIR="$HOME/.csi/caido"
START_SCRIPT="$HOME/.csi/start-redteam.sh"
# Outside the repo clone, so the git tree is not left "dirty" (v4.3.0+dirty).
BRIDGE_SH="$HOME/.csi/caido-bridge.sh"
BRIDGE_LOG="$HOME/.csi/caido-bridge.log"
REPO_URL="https://github.com/c0tton-fluff/caido-mcp-server"
REPO_TAG="v4.3.0"   # Do NOT use v1.1.0: incompatible with Caido 0.57+
GO_MIN="1.25"       # required by v4.3.0
BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${BRIDGE_PORT:-9879}"
TARGET_SHELL=""
DO_ALIAS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --shell)    TARGET_SHELL="${2:-}"; shift 2 ;;
    --no-alias) DO_ALIAS=0; shift ;;
    --yes|-y)   export CSI_ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;36m[setup]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Platform: OS, architecture, shell
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "Unsupported OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

if [ -z "$TARGET_SHELL" ]; then
  TARGET_SHELL="$(basename "${SHELL:-}")"
fi
case "$TARGET_SHELL" in
  zsh)  RC_FILE="$HOME/.zshrc" ;;
  bash)
    # macOS opens login shells: Terminal.app reads ~/.bash_profile, not ~/.bashrc.
    if [ "$OS" = darwin ] && { [ -f "$HOME/.bash_profile" ] || [ ! -f "$HOME/.bashrc" ]; }; then
      RC_FILE="$HOME/.bash_profile"
    else
      RC_FILE="$HOME/.bashrc"
    fi ;;
  *) warn "Unrecognized shell '$TARGET_SHELL' — using ~/.bashrc (override with --shell zsh|bash)."
     RC_FILE="$HOME/.bashrc" ;;
esac

export PATH="$HOME/.local/bin:$HOME/.local/go/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
log "Platform: $OS/$ARCH, target shell: $TARGET_SHELL ($RC_FILE)"

# --- portable helpers (ss/grep -P/setsid do not exist on macOS) -------------
# Lists the PORT of each TCP listener; optionally filters by process name.
listen_ports() {  # $1 = process regex (optional)
  if command -v ss >/dev/null 2>&1; then
    ss -tlnpH 2>/dev/null | awk -v re="${1:-.}" '$0 ~ re {n=split($4,a,":"); print a[n]}'
  else
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
      | awk -v re="${1:-.}" 'NR>1 && $1 ~ re {n=split($9,a,":"); print a[n]}'
  fi | sort -un
}
pids_on_port() {  # $1 = port
  if command -v lsof >/dev/null 2>&1; then
    lsof -t -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
  else
    ss -tlnpH 2>/dev/null | awk -v p=":$1\$" '$4 ~ p' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
  fi
}
port_up() { [ -n "$(listen_ports | awk -v p="$1" '$1==p')" ]; }
detach() {  # runs in the background, detached from the terminal
  if command -v setsid >/dev/null 2>&1; then setsid nohup "$@"; else nohup "$@"; fi
}
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }  # $1 >= $2

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
log "1/10 — Checking prerequisites..."
command -v git    >/dev/null || die "git not found."
command -v docker >/dev/null || die "docker not found."
command -v curl   >/dev/null || die "curl not found."
command -v csi    >/dev/null || die "csi not found in PATH (expected at ~/.local/bin/csi)."
if [ "$OS" = linux ]; then
  command -v ss >/dev/null || command -v lsof >/dev/null || die "install iproute2 (ss) or lsof."
else
  command -v lsof >/dev/null || die "lsof not found."
fi

# --- Go >= $GO_MIN -----------------------------------------------------------
go_ok() { command -v go >/dev/null 2>&1 && ver_ge "$(go version | awk '{print $3}' | sed 's/^go//')" "$GO_MIN"; }
if ! go_ok; then
  log "Go >= $GO_MIN missing or outdated — installing..."
  if [ "$OS" = darwin ]; then
    command -v brew >/dev/null || die "Homebrew not found (https://brew.sh) — install it, or install Go >= $GO_MIN manually."
    brew install go || brew upgrade go
  else
    # Official tarball for the detected architecture, no sudo, into ~/.local/go.
    GO_VER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
    [ -n "$GO_VER" ] || die "could not fetch the current Go version."
    TMP="$(mktemp -d)"
    curl -fsSL "https://go.dev/dl/${GO_VER}.linux-${ARCH}.tar.gz" -o "$TMP/go.tgz"
    rm -rf "$HOME/.local/go"; mkdir -p "$HOME/.local"
    tar -C "$HOME/.local" -xzf "$TMP/go.tgz"
    rm -rf "$TMP"
  fi
  hash -r
  go_ok || die "Go >= $GO_MIN still not available in PATH."
fi

# --- uv / uvx ----------------------------------------------------------------
if ! command -v uvx >/dev/null 2>&1; then
  log "uv/uvx missing — installing..."
  if command -v brew >/dev/null 2>&1 && [ "$OS" = darwin ]; then
    brew install uv
  elif command -v pipx >/dev/null 2>&1; then
    pipx install uv
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh   # installs into ~/.local/bin
  fi
  hash -r
  command -v uvx >/dev/null || die "uvx not found in PATH after installing uv."
fi
log "OK: go=$(go version | awk '{print $3}'), docker=$(docker --version | awk '{print $3}' | tr -d ','), uv=$(uv --version | awk '{print $2}')"

# ---------------------------------------------------------------------------
# 2. Clone / update caido-mcp-server
# ---------------------------------------------------------------------------
log "2/10 — Preparing $CAIDO_DIR (tag $REPO_TAG)..."
if [ -d "$CAIDO_DIR/.git" ]; then
  git -C "$CAIDO_DIR" fetch --tags origin
  git -C "$CAIDO_DIR" checkout "$REPO_TAG"
else
  mkdir -p "$(dirname "$CAIDO_DIR")"
  git clone --branch "$REPO_TAG" "$REPO_URL" "$CAIDO_DIR"
fi
# Older versions of this setup wrote the bridge inside the clone; remove it
# before building, otherwise the binary is tagged "+dirty".
rm -f "$CAIDO_DIR/bridge.sh" "$CAIDO_DIR/bridge.log"

# ---------------------------------------------------------------------------
# 3. Build (native for the machine's architecture)
# ---------------------------------------------------------------------------
log "3/10 — Building caido-mcp-server ($REPO_TAG) for $OS/$ARCH..."
cd "$CAIDO_DIR"
go mod download
go mod verify
go build -o caido-mcp-server ./cmd/caido-mcp-server
log "Binary: $("$CAIDO_DIR/caido-mcp-server" --version)"

# ---------------------------------------------------------------------------
# 4. Discover CAIDO_URL
# ---------------------------------------------------------------------------
log "4/10 — Discovering CAIDO_URL..."
caido_ok() {
  curl -sf -m 10 -X POST "$1/graphql" -H 'Content-Type: application/json' \
    -d '{"query":"{__typename}"}' >/dev/null
}
CAIDO_URL="${CAIDO_URL:-}"
if [ -z "$CAIDO_URL" ]; then
  # Kali: the backend is the caido-cli bundled with the Electron app. macOS: "caido-cli"/"Caido" process.
  # There may be more than one listener (UI/GraphQL and proxy): probe each port.
  for p in $(listen_ports '[Cc]aido'); do
    if caido_ok "http://127.0.0.1:${p}"; then CAIDO_URL="http://127.0.0.1:${p}"; break; fi
  done
fi
if [ -z "$CAIDO_URL" ]; then
  warn "Could not detect a listening Caido instance (is it open?)."
  read -rp "Enter the Caido port (e.g. 8080): " CAIDO_PORT
  CAIDO_URL="http://127.0.0.1:${CAIDO_PORT}"
fi
caido_ok "$CAIDO_URL" || die "Caido did not respond at $CAIDO_URL/graphql — make sure it is open and running."
log "CAIDO_URL = $CAIDO_URL (confirmed via GraphQL)"

# ---------------------------------------------------------------------------
# 5. OAuth login
# ---------------------------------------------------------------------------
log "5/10 — Authentication..."
if [ -f "$HOME/.caido-mcp/token.json" ]; then
  log "Token already exists at ~/.caido-mcp/token.json — skipping login."
else
  log "A consent URL will appear below. Open it in your browser and click Allow in Caido."
  "$CAIDO_DIR/caido-mcp-server" login -u "$CAIDO_URL"
fi

# ---------------------------------------------------------------------------
# 6. caido-bridge.sh
# ---------------------------------------------------------------------------
log "6/10 — Writing $BRIDGE_SH..."
cat > "$BRIDGE_SH" <<BRIDGE_EOF
#!/usr/bin/env bash
# Bridge: caido-mcp-server (stdio) -> mcp-proxy (SSE) -> CSI/CAI
set -euo pipefail
CAIDO_URL="\${CAIDO_URL:-$CAIDO_URL}"
BRIDGE_HOST="\${BRIDGE_HOST:-127.0.0.1}"   # never 0.0.0.0 by default (would expose it on the LAN)
BRIDGE_PORT="\${BRIDGE_PORT:-9879}"
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"

SERVER="\$HOME/.csi/caido/caido-mcp-server"
[ -x "\$SERVER" ] || { echo "missing binary: \$SERVER" >&2; exit 1; }
[ -f "\$HOME/.caido-mcp/token.json" ] || { echo "not authenticated: run '\$SERVER login -u \$CAIDO_URL'" >&2; exit 1; }

echo "Caido:  \$CAIDO_URL" >&2
echo "Bridge: http://\${BRIDGE_HOST}:\${BRIDGE_PORT}/sse" >&2

# Pin "mcp<2": mcp-proxy 0.12.0 breaks against mcp>=2.0 (ImportError: request_ctx).
exec uvx --with "mcp<2" mcp-proxy \\
    --host "\$BRIDGE_HOST" \\
    --port "\$BRIDGE_PORT" \\
    -e CAIDO_URL "\$CAIDO_URL" \\
    -- "\$SERVER" serve
BRIDGE_EOF
chmod +x "$BRIDGE_SH"

# ---------------------------------------------------------------------------
# 7. Start the bridge
# ---------------------------------------------------------------------------
log "7/10 — Starting the bridge on ${BRIDGE_HOST}:${BRIDGE_PORT}..."
OLD_PID="$(pids_on_port "$BRIDGE_PORT" | head -1)"
if [ -n "$OLD_PID" ]; then kill "$OLD_PID" 2>/dev/null || true; sleep 2; fi

rm -f "$BRIDGE_LOG"
CAIDO_URL="$CAIDO_URL" BRIDGE_HOST="$BRIDGE_HOST" BRIDGE_PORT="$BRIDGE_PORT" \
  detach "$BRIDGE_SH" > "$BRIDGE_LOG" 2>&1 < /dev/null &
disown 2>/dev/null || true

# First run: uvx downloads mcp-proxy + mcp<2 (may take >8s) — poll for up to 90s.
UP=0
for _ in $(seq 1 45); do
  if port_up "$BRIDGE_PORT"; then UP=1; break; fi
  sleep 2
done
if [ "$UP" = 1 ]; then
  log "Bridge is up (${BRIDGE_HOST}:${BRIDGE_PORT})."
else
  cat "$BRIDGE_LOG" >&2
  die "Bridge failed to start — see log above."
fi

# ---------------------------------------------------------------------------
# 8. CSI container in --network host
# ---------------------------------------------------------------------------
# 127.0.0.1 inside the container is only the host's loopback in NetworkMode=host.
log "8/10 — Checking the CSI container network mode..."
if [ "$OS" = darwin ]; then
  warn "macOS: Docker Desktop runs containers in a Linux VM. --network host only reaches the Mac's 127.0.0.1"
  warn "when 'Enable host networking' is on (Docker Desktop >= 4.34, Settings > Resources > Network)."
fi
CID="$(docker ps -aq --filter 'name=csi-agents-' | head -1)"
CUR_NET=""
[ -n "$CID" ] && CUR_NET="$(docker inspect "$CID" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"

if [ "$CUR_NET" = "host" ]; then
  log "Container already in host mode — nothing to do."
else
  if [ -n "$CID" ]; then log "Container in '$CUR_NET' mode — recreating in host mode..."; else log "No container yet — creating in host mode..."; fi
  # --stop-agents removes the container and KILLS any running CSI sessions/agents.
  if [ -n "$CID" ] && [ "${CSI_ASSUME_YES:-0}" != "1" ]; then
    read -rp "This will tear down the current CSI container (active sessions/agents will be lost). Continue? [y/N] " _ans
    case "$_ans" in y|Y|yes|YES) ;; *) die "Aborted. Close your CSI sessions and run again (or use --yes)." ;; esac
  fi
  CSI_ASSUME_YES=1 csi --stop-agents || true
  csi --network host mcp list >/dev/null 2>&1 || true   # forces creation in host mode (needs a TTY)
  NEW_CID="$(docker ps -aq --filter 'name=csi-agents-' | head -1)"
  NEW_NET="$(docker inspect "$NEW_CID" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo '?')"
  if [ "$NEW_NET" = "host" ]; then log "Container recreated in host mode."; else warn "Could not confirm host mode (got '$NEW_NET') — check manually."; fi
fi

# ---------------------------------------------------------------------------
# 9. Bridge smoke test
# ---------------------------------------------------------------------------
log "9/10 — Bridge smoke test (send_request -> example.com)..."
BRIDGE_URL="http://${BRIDGE_HOST}:${BRIDGE_PORT}/sse" uv run --quiet --with "mcp<2" python3 - <<'PYEOF' || warn "Smoke test failed — the bridge may still be fine; check with /mcp inside CAI."
import anyio, json, os
from mcp import ClientSession
from mcp.client.sse import sse_client

async def main():
    async with sse_client(os.environ["BRIDGE_URL"]) as (read, write):
        async with ClientSession(read, write) as s:
            await s.initialize()
            r = await s.call_tool("caido_send_request", {
                "raw": "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
                "host": "example.com", "port": 443, "tls": True})
            out = r.structuredContent or {}
            if r.isError or out.get("statusCode") != 200:
                print("FAILED:", out or (r.content[0].text if r.content else "?"))
                raise SystemExit(1)
            print("OK — status %s, sessionId %s, roundtrip %sms" % (
                out.get("statusCode"), out.get("sessionId"), out.get("roundtripMs")))
anyio.run(main)
PYEOF

# ---------------------------------------------------------------------------
# 10. start-redteam.sh + alias in the shell rc file
# ---------------------------------------------------------------------------
log "10/10 — Writing $START_SCRIPT..."
cat > "$START_SCRIPT" <<START_EOF
#!/usr/bin/env bash
# Starts the CSI session (cai backend) with the Caido MCP loaded and redteam_agent
# selected, making sure the bridge is up. Generated by setup-caido-mcp-universal.sh.
set -euo pipefail
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH"
BRIDGE_HOST="\${BRIDGE_HOST:-${BRIDGE_HOST}}"
BRIDGE_PORT="\${BRIDGE_PORT:-${BRIDGE_PORT}}"
BRIDGE_URL="\${BRIDGE_URL:-http://\${BRIDGE_HOST}:\${BRIDGE_PORT}/sse}"

# Bridge down (reboot, etc.)? Start it again.
if ! (exec 3<>"/dev/tcp/\${BRIDGE_HOST}/\${BRIDGE_PORT}") 2>/dev/null; then
  echo "[csi-redteam] bridge is down — starting it..." >&2
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "\$HOME/.csi/caido-bridge.sh" >"\$HOME/.csi/caido-bridge.log" 2>&1 </dev/null &
  else
    nohup "\$HOME/.csi/caido-bridge.sh" >"\$HOME/.csi/caido-bridge.log" 2>&1 </dev/null &
  fi
  for _ in \$(seq 1 30); do
    (exec 3<>"/dev/tcp/\${BRIDGE_HOST}/\${BRIDGE_PORT}") 2>/dev/null && break
    sleep 2
  done
fi

CSI_BACKEND=cai exec csi --network host --model alias1 --yolo \\
  --prompt "/mcp load \${BRIDGE_URL} caido;/mcp add caido redteam_agent;/agent redteam_agent"
START_EOF
chmod +x "$START_SCRIPT"

if [ "$DO_ALIAS" = 1 ]; then
  MARK_BEGIN="# >>> csi-caido (setup-caido-mcp-universal) >>>"
  MARK_END="# <<< csi-caido <<<"
  touch "$RC_FILE"
  if grep -qF "$MARK_BEGIN" "$RC_FILE"; then
    # Rewrite only the managed block (no sed -i, which differs between GNU and BSD).
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$RC_FILE" > "$RC_FILE.tmp" \
      && mv "$RC_FILE.tmp" "$RC_FILE"
  elif grep -qE '^[[:space:]]*alias[[:space:]]+csi-redteam=' "$RC_FILE"; then
    warn "An 'alias csi-redteam' already exists outside the managed block in $RC_FILE — not duplicating it. Remove it manually if you want this script to manage it."
    DO_ALIAS=0
  fi
  if [ "$DO_ALIAS" = 1 ]; then
    {
      [ -n "$(tail -c1 "$RC_FILE")" ] && echo            # file without trailing newline
      [ -n "$(tail -n1 "$RC_FILE")" ] && echo            # separate from previous content
      printf '%s\n' "$MARK_BEGIN"
      printf 'alias csi-redteam="%s"\n' '$HOME/.csi/start-redteam.sh'
      printf '%s\n' "$MARK_END"
    } >> "$RC_FILE"
    log "Alias 'csi-redteam' registered in $RC_FILE."
  fi
fi

cat <<FINAL_EOF

======================================================================
 Done. Open a NEW terminal (or: source $RC_FILE) and run:

     csi-redteam

 This starts the CAI session with the Caido MCP already loaded and
 redteam_agent active (no manual /mcp load needed). In the Caido UI,
 Replay tab, you should see the smoke-test session against example.com.
======================================================================
FINAL_EOF

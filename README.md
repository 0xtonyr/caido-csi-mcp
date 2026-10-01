# caido-csi-mcp

**Plug-and-play** integration of [Caido](https://caido.io) with
[Alias Robotics](https://aliasrobotics.com)' **CSI / CAI** via MCP.

CSI does not yet ship native configuration for Caido. This script fills that gap:
it builds [caido-mcp-server](https://github.com/c0tton-fluff/caido-mcp-server),
exposes it to the CSI container through an SSE bridge (`mcp-proxy`), and creates
an alias that opens the CAI session with the Caido MCP already loaded and
`redteam_agent` selected.

## Architecture

```
CAI (CSI container, --network host)
   │  SSE  http://127.0.0.1:9879/sse
   ▼
mcp-proxy (uvx, on the host)
   │  stdio
   ▼
caido-mcp-server serve  ──GraphQL──▶  Caido (127.0.0.1:<port>)
```

## Supported platforms

- **Linux** (Kali, Debian, Ubuntu) and **macOS**
- **amd64** (x86_64) and **arm64** (aarch64 / Apple Silicon)

The script detects OS, architecture and shell automatically and relies only on
portable tooling (`ss` or `lsof`; no GNU-only `grep -P`, `setsid` or `sed -i`).

## Prerequisites

- `git`, `curl`, `docker`
- `csi` in `PATH` (with a working `cai` backend)
- Caido **open and running**

Installed automatically if missing:

- **Go ≥ 1.25**: on Linux, the official tarball for the detected architecture into
  `~/.local/go` (no sudo); on macOS, via Homebrew
- **uv/uvx**: via Homebrew (macOS), `pipx`, or the official installer

## Usage

```bash
chmod +x setup-caido-mcp-universal.sh
./setup-caido-mcp-universal.sh
```

Then open a new terminal and run:

```bash
csi-redteam
```

### Options

| Flag | Effect |
|------|--------|
| `--shell zsh\|bash` | Force the target shell for the alias (default: detected from `$SHELL`) |
| `--no-alias` | Do not modify the shell rc file |
| `--yes`, `-y` | Do not ask for confirmation before recreating the CSI container |

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CAIDO_URL` | auto-detected | Caido URL (skips auto-detection) |
| `BRIDGE_HOST` | `127.0.0.1` | Bridge interface. Do not use `0.0.0.0`: it would expose the MCP on the network |
| `BRIDGE_PORT` | `9879` | Bridge port |
| `CSI_ASSUME_YES` | `0` | Same as `--yes` |

## What the script does

1. Detects OS, architecture and shell; checks and installs dependencies
2. Clones `caido-mcp-server` at tag `v4.3.0` into `~/.csi/caido` (v1.1.0 is incompatible with Caido 0.57+)
3. Builds the native binary
4. Discovers the Caido port by probing each listener via GraphQL
5. Performs the Caido OAuth login (first run only; token stored in `~/.caido-mcp/token.json`)
6. Generates `~/.csi/caido-bridge.sh`
7. Starts the bridge in the background (log at `~/.csi/caido-bridge.log`)
8. Ensures the CSI container runs with `--network host` (recreates it if needed, **with confirmation**, since this ends active sessions)
9. Runs a smoke test: sends `GET https://example.com/` through Caido via MCP (shows up in the Replay tab)
10. Generates `~/.csi/start-redteam.sh` and registers the `csi-redteam` alias in `~/.zshrc`, `~/.bashrc`, or `~/.bash_profile` (macOS with bash)

The script is **idempotent**: you can run it again at any time. The alias lives
in a marker-delimited block and is rewritten without duplication.

`csi-redteam` also restarts the bridge automatically if it is down (e.g. after
a reboot).

## Notes

- **macOS / Docker Desktop:** containers run inside a Linux VM. `--network host`
  only reaches the Mac's `127.0.0.1` with **Enable host networking** turned on
  (Docker Desktop ≥ 4.34, *Settings → Resources → Network*).
- **`mcp<2`:** `mcp-proxy` 0.12.0 breaks against `mcp>=2.0`
  (`ImportError: request_ctx`), so the version is pinned.
- **Existing alias:** if an `alias csi-redteam` already exists outside the managed
  block, the script warns and leaves it untouched.

## Generated files

| Path | Contents |
|------|----------|
| `~/.csi/caido/` | `caido-mcp-server` clone and binary |
| `~/.csi/caido-bridge.sh` / `.log` | MCP bridge (stdio → SSE) and its log |
| `~/.csi/start-redteam.sh` | Starts the CAI session with the Caido MCP |
| `~/.caido-mcp/token.json` | Caido OAuth token |

## License

[MIT](LICENSE)

# Setup Guide

This guide walks through starting the zero-dependency Python companion bridge on **Windows**, **macOS**, or **Linux**, installing **Official Antigravity Hooks**, building the native **iOS 17+** SwiftUI app in Xcode, and configuring encrypted remote access via **Tailscale** or **Cloudflare Tunnel**.

---

## Prerequisites

| Component | Requirement |
| --- | --- |
| **Workstation (Host)** | Windows 10/11, macOS 13+, or Linux with **Python 3.10+** and Google Antigravity 2.0 installed |
| **Bridge dependencies** | **None** (100% Python stdlib). Optional: `zeroconf` for Bonjour LAN auto-discovery |
| **iOS Build Machine** | macOS 14/15 with **Xcode 16+** and **XcodeGen** (`brew install xcodegen`) |
| **iPhone / iPad** | **iOS 17.0+** (or iOS 17+ Simulator in Xcode) |

---

## 1. Start the Companion Bridge

Clone the repository onto the workstation running Antigravity:

```bash
git clone https://github.com/npolarski1/native_agy_ios.git
cd native_agy_ios
```

### Option A: Run Directly with Zero `pip install`

**Windows (PowerShell):**

```powershell
$env:PYTHONPATH = "bridge"
python -m antigravity_bridge serve
```

**macOS / Linux:**

```bash
PYTHONPATH=bridge python3 -m antigravity_bridge serve
```

### Option B: Editable Install (Adds `antigravity-bridge` Command)

```bash
# Core bridge only (zero external packages)
pip install --no-deps --no-build-isolation -e ./bridge

# Optional: include `zeroconf` for automatic Bonjour LAN discovery (_antigravity-mon._tcp)
pip install -e "./bridge[bonjour]"
```

Then start the server:

```bash
antigravity-bridge serve
```

### Useful Bridge Subcommands

Run `--help` on the CLI or any subcommand to see all flags and defaults:

```bash
python -m antigravity_bridge --help
python -m antigravity_bridge serve --help
python -m antigravity_bridge pair-qr --help
python -m antigravity_bridge install-hooks --help
python -m antigravity_bridge status --help
```

- `serve`: Starts the `asyncio` HTTP/1.1 + RFC 6455 WebSocket server (default `0.0.0.0:8765`), persists generated config/token to `~/.antigravity-bridge/config.json`, monitors `~/.gemini/antigravity/brain`, and prints your bearer token and pairing QR code.
- `pair-qr`: Prints a scannable Unicode QR code (or `--ascii` / `--light-terminal`) and `agymon://pair?...` URI in your terminal. Pass `--advertise-url https://...` (or set `ANTIGRAVITY_BRIDGE_ADVERTISE_URL`) for Tailscale or Cloudflare Tunnel URLs, or `--rotate-token` to rotate credentials.
- `install-hooks`: Installs or removes Official Antigravity Hooks (`--scope global` for `~/.gemini/config/hooks.json`, `--scope workspace` for `./.agents/hooks.json`, `--matcher` for gated `PreToolUse` tools, `--dry-run` to preview, `--uninstall` to remove).
- `status`: Prints current bridge configuration, brain directory status, and local health details.

### Configuration Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANTIGRAVITY_BRAIN_DIR` | `~/.gemini/antigravity/brain` | Antigravity 2.0 brain directory containing conversation transcripts, artifacts, and task logs |
| `ANTIGRAVITY_BRIDGE_CONFIG_DIR` | `~/.antigravity-bridge` | Directory storing persisted `config.json` (created with `0600` permissions on macOS/Linux) |
| `ANTIGRAVITY_BRIDGE_HOST` | `0.0.0.0` | Interface address to bind |
| `ANTIGRAVITY_BRIDGE_PORT` | `8765` | TCP port for HTTP/1.1 & WebSocket server |
| `ANTIGRAVITY_BRIDGE_TOKEN` | Auto-generated (`secrets.token_urlsafe(32)`) | Explicit bearer token override |
| `ANTIGRAVITY_BRIDGE_NAME` | System hostname | Friendly workstation name displayed in the iOS app |
| `ANTIGRAVITY_BRIDGE_ADVERTISE_URL` | Auto-detected `http://<lan-ip>:8765` | Base URL embedded in QR pairing links (set to your Tailscale or Cloudflare Tunnel HTTPS URL for remote access) |

---

## 2. Install Official Antigravity Hooks

Reading `~/.gemini/antigravity/brain/` gives you full live transcripts, artifacts, token counts, and task logs out of the box. Installing **Official Antigravity Hooks** unlocks:

- Instant lifecycle notifications (`PreInvocation`, `PostInvocation`, `PostToolUse`, `Stop`)
- Interactive **`PreToolUse` Allow / Deny** tool approval prompts directly on your iPhone (including from the iOS notification banner)

### Automatic Installation (Recommended)

**Windows (PowerShell):**

```powershell
$env:PYTHONPATH = "bridge"
python -m antigravity_bridge install-hooks
```

**macOS / Linux:**

```bash
PYTHONPATH=bridge python3 -m antigravity_bridge install-hooks
```

Inspect `python -m antigravity_bridge install-hooks --help` to customize `--scope global|workspace`, `--matcher` (for example, `"run_command|write_file|edit_file"`), `--dry-run`, or `--uninstall`.

### Manual Hook Reference

See [`bridge/hooks/hooks.example.json`](../bridge/hooks/hooks.example.json) for a complete template. Under a named hook entry (such as `"antigravity-monitor"`), Antigravity 2.0 expects two hook shapes:

- **Lifecycle hooks** (`PreInvocation`, `PostInvocation`, `Stop`) take a flat array of command entries:
  ```json
  {
    "antigravity-monitor": {
      "enabled": true,
      "Stop": [
        { "type": "command", "command": "python3 /path/to/bridge/hooks/antigravity_hook.py --event Stop", "timeout": 30 }
      ]
    }
  }
  ```
- **Tool hooks** (`PreToolUse`, `PostToolUse`) take matcher objects:
  ```json
  {
    "antigravity-monitor": {
      "enabled": true,
      "PreToolUse": [
        {
          "matcher": "run_command|write_file|edit_file",
          "hooks": [
            { "type": "command", "command": "python3 /path/to/bridge/hooks/antigravity_hook.py --event PreToolUse --timeout 55", "timeout": 60 }
          ]
        }
      ]
    }
  }
  ```

> **Fail-safe design:** `antigravity_hook.py` always exits `0` and never crashes an Antigravity turn. For `PreToolUse`, if a remote approval request times out before you respond, `--timeout-decision` (`ANTIGRAVITY_BRIDGE_TIMEOUT_DECISION`) defaults to **`deny`**. If the bridge server is offline or unreachable, `--offline-decision` (`ANTIGRAVITY_BRIDGE_OFFLINE_DECISION`) defaults to **`allow`** so local workstation usage is not blocked when the bridge isn't running (set it to `deny` if you want strict fail-closed gating).

---

## 3. Build & Install the Native iOS App

### Generate the Xcode Project

On a Mac with Xcode 16+ installed:

```bash
brew install xcodegen
cd ios
xcodegen generate
open AntigravityMonitor.xcodeproj
```

### Run on iOS Simulator (Quick Preview / Demo Mode)

1. In Xcode, select the **AntigravityMonitor** scheme and any **iOS 17+ iPhone Simulator**.
2. Press **Cmd + R** to build and launch.
3. When no workstation is paired yet, the app opens with **Demo Mode** available so you can immediately explore Sessions, Transcripts, Artifacts, Tasks/Swarms, Approvals, and Telemetry.

### Install on Your Physical iPhone (iOS 17+)

1. Open `ios/AntigravityMonitor.xcodeproj` in Xcode.
2. Select the **AntigravityMonitor** target → **Signing & Capabilities**:
   - Choose your **Team** (free Apple ID personal team or paid Apple Developer team).
   - Change the Bundle Identifier (`com.antigravity.monitor`) to a unique identifier if Xcode reports it is already taken (e.g., `com.yourname.antigravity.monitor`).
3. Repeat for the **AntigravityMonitorWidgets** target (e.g., `com.yourname.antigravity.monitor.widgets`).
4. *(Optional for WidgetKit shared timeline on device)* Add matching **App Groups** capability to both targets if you want Home Screen widget snapshots synced via App Group `UserDefaults` on a signed device.
5. Connect your iPhone, select it as the run destination, and press **Cmd + R**.
6. On first launch on a free Apple ID profile, trust your developer certificate in **Settings → General → VPN & Device Management**.

### Run Unit Tests via CLI

```bash
# Swift core package tests (macOS)
swift test --package-path ios/Packages/AntigravityCore

# Python companion bridge tests (Windows / macOS / Linux)
PYTHONPATH=bridge python -m unittest discover -s bridge/tests -v
```

---

## 4. Pair Your iPhone with Your Workstation

Open **Antigravity Monitor** on your iPhone and tap **Pair Host**. Three pairing workflows are supported:

1. **Scan QR Code (Fastest)**:
   - Run `python -m antigravity_bridge pair-qr` on your workstation (or use the QR printed when `serve` starts).
   - Point the iPhone camera at the terminal QR code (encodes `agymon://pair?url=...&token=...&name=...`).
   - You can also tap an `agymon://pair?...` link directly on iOS to deep-link into the app.
2. **Bonjour LAN Discovery**:
   - Ensure your iPhone and workstation are on the same Wi-Fi/LAN and `zeroconf` is installed on the workstation.
   - Allow iOS **Local Network** permission when prompted.
   - Select your workstation under **Nearby LAN** (**Discovered Bridges**, `_antigravity-mon._tcp`) and enter the bearer token.
3. **Manual Entry**:
   - Enter the bridge Base URL (e.g., `http://192.168.1.42:8765` or `https://workstation.tailnet.ts.net`), paste your Bearer token, and tap **Test Connection**.

---

## 5. Remote Access Outside Your Home/Office LAN

Never expose an unencrypted HTTP bridge directly to the public internet. Use one of these zero-cost encrypted remote transport options:

### Option A: Tailscale (Recommended — Private WireGuard Mesh)

1. Install [Tailscale](https://tailscale.com) on both your workstation and your iPhone and sign in to the same tailnet.
2. Start the bridge on your workstation (default port `8765`).
3. *(Optional, for TLS `https://` + `wss://`)* Proxy the local bridge through Tailscale Serve:
   ```bash
   tailscale serve --bg http://127.0.0.1:8765
   ```
   This gives you an automatic trusted HTTPS endpoint like `https://<machine>.<tailnet>.ts.net` reachable only by your own tailnet devices.
4. Generate a pairing QR code pointing at your Tailscale URL and scan it from your iPhone:
   ```bash
   PYTHONPATH=bridge python3 -m antigravity_bridge pair-qr --advertise-url https://<machine>.<tailnet>.ts.net
   ```

### Option B: Cloudflare Tunnel (`cloudflared`)

1. Install [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) on your workstation.
2. Start the bridge bound to `127.0.0.1` (`ANTIGRAVITY_BRIDGE_HOST=127.0.0.1`), then open a TLS-terminated quick tunnel:
   ```bash
   cloudflared tunnel --url http://127.0.0.1:8765
   ```
   Cloudflare prints a temporary `https://<random>.trycloudflare.com` URL (or configure a named tunnel for a persistent custom domain).
3. Generate a pairing QR code using `--advertise-url https://<random>.trycloudflare.com` and scan it on your iPhone. The iOS client automatically uses `wss://` for `/api/v1/ws`.

---

## 6. Verification & Troubleshooting

### Verify the Bridge Locally

```bash
# Unauthenticated liveness check
curl http://127.0.0.1:8765/api/v1/ping

# Authenticated health telemetry check
curl -H "Authorization: Bearer <your-token>" http://127.0.0.1:8765/api/v1/health
```

### Common Issues

- **iPhone cannot reach LAN IP on Windows**: Windows Defender Firewall may block inbound LAN connections to `python.exe`. Allow private-network inbound access on the bridge port, or use **Tailscale** / **Cloudflare Tunnel**.
- **Bonjour workstation does not appear**: Verify `zeroconf` is installed on the host (`pip install zeroconf`), both devices are on the same subnet without Wi-Fi client isolation, and **Settings → Privacy & Security → Local Network → AntigravityMonitor** is enabled on iOS.
- **`brain_dir_exists: false` in `/api/v1/health`**: Confirm Antigravity 2.0 has run at least one conversation, or pass `--brain-dir /path/to/brain` (or set `ANTIGRAVITY_BRAIN_DIR`) if your Antigravity data directory is non-standard.
- **No `PreToolUse` approvals appearing**: Verify `~/.gemini/config/hooks.json` (or `.agents/hooks.json`) contains the hook entries, confirm `antigravity_bridge` is running, and ensure the bridge URL/token environment or config used by `antigravity_hook.py` matches the running server.

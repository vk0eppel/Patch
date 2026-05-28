# Patch

**Operational communication for live production teams.**

Patch is a lightweight, cross-platform real-time messaging system built for AV, broadcast, theatre, and touring crews. It uses OSC (Open Sound Control) over UDP as its primary transport — the same protocol your show-control gear already speaks.

It is not a chat app. It is a coordination layer for live environments.

---

## Why Patch

Existing options (Slack, WhatsApp, walkie-talkie apps) are either too slow, too noisy, or don't integrate with the show network. Patch is designed to sit alongside QLab, Companion, and your console, receive OSC triggers, and get the right message to the right department in under a second.

Inspired by [Wavetool](https://wavetool.fi/) chat and [SideChain's TheaterChat](https://sidechainsoftware.com).

---

## Features

- **Single binary, all platforms** — Rust engine is linked into the Flutter app as a `cdylib`/`staticlib` via `flutter_rust_bridge`. One process, one icon, no sidecar
- **OSC-native transport** — messages travel as OSC packets; unicast to known peers, broadcast only for presence/discovery
- **Logical channels** — FOH, MON, RF, LIGHTING, VIDEO, STAGE, PRODUCTION — create and delete at runtime
- **Multi-channel view** — tap to focus a channel, long-press to add it to the view; combined feed sorted by timestamp with per-message channel colour dots
- **Flash / page** — one-button high-priority alert per channel; channel tab pulses + message box border lights up in the channel colour; auto-flash configurable globally (Settings → Behavior) and per-channel (Settings → channel editor)
- **Configurable flash count** — set how many times the channel pulses per flash event (1–5 in Settings → Behavior; per-channel override in channel editor; default 4)
- **Shortcut messages** — per-channel one-tap buttons for common callouts (HOLD, CLEAR, BATTERY LOW…), optionally bound to F-keys
- **Session presets** — save and restore named channel layouts; accessible from the folder icon in the sidebar; import/export `.toml` files to share layouts across machines
- **Hybrid discovery** — mDNS/Bonjour auto-discovery + OSC beacon broadcast every 7s + manual static IP for AP-isolated or VLAN-segmented show networks
- **Static peer management** — add/remove known peers by IP from the Settings screen; static peers are always contacted regardless of discovery state, bypassing AP isolation
- **Configurable identity** — set your display name and network interface from the settings screen; NIC picker filters out virtual/tunnel interfaces and shows only real NICs with IPv4 addresses; changes persist immediately
- **Priority levels** — info / warning / critical; critical messages are visually distinct and require ACK
- **Message deduplication** — UUID per message; never see the same message twice
- **Dark, high-contrast UI** — readable from a stage desk at 2m
- **Keyboard-first** — Enter to send, F1–F12 for shortcuts (binding configurable per shortcut; fires from any focus state)
- **Cross-platform** — macOS, Windows, Linux, iOS, iPad (Flutter UI + Rust engine, single binary)

---

## Stack

| Layer | Technology |
|---|---|
| UI | Flutter |
| Engine | Rust (tokio) |
| UI ↔ engine | `flutter_rust_bridge` v2 (typed FFI, in-process) |
| Build glue | `cargokit` (Flutter FFI plugin in `patch_app/rust_builder/`) |
| OSC transport | UDP via `rosc` |
| Discovery | `mdns-sd` + OSC beacon + static IP |

The Rust engine compiles into a static/dynamic library and is linked directly into the Flutter app at build time. There is no IPC layer — Dart calls Rust functions via FRB-generated bindings. `cargokit` runs `cargo` automatically during `flutter build` for each target platform.

---

## Getting Started

### Prerequisites

- **Rust via `rustup`** (not Homebrew Rust). Cargokit needs rustup to manage cross-compile targets.
  ```bash
  # If brew rust is installed, unlink it first so rustup wins on PATH:
  brew unlink rust
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```
- **Flutter 3.x**
- **CocoaPods** for macOS/iOS builds: `brew install cocoapods`

### Run

```bash
git clone https://github.com/vk0eppel/Patch.git
cd Patch/patch_app

# macOS
flutter run -d macos

# iOS / iPad (device or simulator)
flutter run -d <device-id>

# Windows / Linux — generate the platform folder first if missing
flutter create --platforms=windows .   # or linux
flutter run -d windows                 # or linux
```

The first build is slow because Cargokit cross-compiles the Rust engine for the target. Subsequent runs are fast.

The engine generates a `patch.toml` config file on first run in the platform data directory:
- macOS: `~/Library/Application Support/Patch/` (sandboxed under `~/Library/Containers/<bundle-id>/…` for the Flutter app)
- Windows: `%APPDATA%\Patch\`
- Linux: `~/.local/share/Patch/`
- iOS: app sandbox

Sensible defaults are written (OSC port 9000, all interfaces, 7s heartbeat). Edit `patch.toml` to set a static NIC, add known peers, or change your display name — or use the Settings screen inside the app.

---

## Project Layout

```
patch/
├── patch-core/        Rust engine — OSC, transport, discovery, reliability, FFI API (api.rs)
├── patch_app/         Flutter UI — channels, messages, peers, settings, session management
│   ├── lib/src/rust/  Generated Dart bindings (do not edit; regenerated by codegen)
│   └── rust_builder/  Local FFI plugin that builds/links patch-core via cargokit
└── flutter_rust_bridge.yaml   Codegen config
```

After editing `patch-core/src/api.rs`, regenerate the bindings:

```bash
flutter_rust_bridge_codegen generate
# Then, if any freezed type changed:
cd patch_app && dart run build_runner build
```

See [CLAUDE.md](CLAUDE.md) for the full architecture, FFI API reference, OSC namespace, and development notes.

For end-user documentation (getting started, networking, OSC integration, troubleshooting), see the **[docs/](docs/README.md)** folder.

---

## OSC Integration

Patch listens on UDP port 9000 (configurable). Send a standard OSC message to it from any device on the LAN:

```
/patch/channel/rf/message  <sender_id> <sender_name> <message_id> <timestamp_ms> <priority> <payload>
```

The channel is identified by the address path — no need to repeat it in the args. `priority` is an integer: 0=info, 1=warning, 2=critical.

Flash/page a channel from any OSC source:

```
/patch/channel/rf/flash  <sender_id> <sender_name>
```

---

## Configuration (`patch.toml`)

```toml
client_id = "..."              # UUID — generated once, stable across sessions
client_name = "FOH Engineer"   # Editable from the Settings screen
osc_port = 9000
network_interface = "en0"      # Omit to bind all interfaces
flash_on_critical = true       # Auto-flash on priority-3 messages (Settings → Behavior)
flash_on_message = false       # Auto-flash on every message (Settings → Behavior)
flash_count = 4                # Flash pulse count per event, 1–10 (Settings → Behavior)

heartbeat_interval_secs = 7
peer_timeout_secs = 30

[[static_peers]]
address = "192.168.1.50"
port = 9000
label = "Monitor World"
```

---

## Roadmap

- [x] OSC transport — unicast to known peers, broadcast for presence/discovery
- [x] Hybrid peer discovery (mDNS + OSC beacon + static IP)
- [x] Peer address resolution from UDP source + mDNS
- [x] Channel model with per-channel shortcuts — create, edit, delete at runtime
- [x] Flash / page per channel (local + remote)
- [x] Priority levels with visual differentiation
- [x] Message deduplication by UUID
- [x] Single-binary build via `flutter_rust_bridge` + cargokit (no more TCP bridge)
- [x] Settings screen — display name, NIC picker, shortcuts, channel management
- [x] Session presets — save / load / delete named channel layouts; sidebar folder icon (not Settings); import/export `.toml` files
- [x] Multi-channel view — combined feed, long-press to add channels
- [x] Flash animation — channel tab pulse + message box border/tint (configurable pulse count)
- [x] Auto-flash on critical messages — global default in Settings → Behavior
- [x] Per-channel flash settings — override "flash on message", "flash on critical", and pulse count per channel
- [x] Configurable flash pulse count — 1–10 globally (default 4), per-channel override
- [x] F-key bindings for shortcuts (F1–F12, fires from any focus state)
- [x] Platform data directory (`~/Library/Application Support/Patch/`, `%APPDATA%\Patch\`, etc.) with legacy `./patch.toml` migration
- [x] iOS / macOS Local Network permission strings in Info.plist (`NSLocalNetworkUsageDescription` + `NSBonjourServices`)
- [x] Settings screen — static peer management via UI (add/remove peers by address + port + label)
- [x] Heartbeat broadcast wired through transport (presence sent every 7s)
- [x] Peer display — correct name from mDNS TXT record, transport-resolved IP preserved across heartbeats, self-discovery filtered out
See [TODO.md](TODO.md) for pending work and known issues.

---

## License

TBD — private for now.

# Patch

**Operational communication for live production teams.**

Patch is a lightweight, cross-platform real-time messaging system built for AV, broadcast, theatre, and touring crews. It uses OSC (Open Sound Control) over UDP as its primary transport — the same protocol your show-control gear already speaks.

It is not a chat app. It is a coordination layer for live environments.

---

## Why Patch

Existing options (Slack, WhatsApp, walkie-talkie apps) are either too slow, too noisy, or don't integrate with the show network. Patch is designed to sit alongside QLab, Companion, and your console, receive OSC triggers, and get the right message to the right department in under a second.

Inspired by [Shure Wireless Workbench](https://www.shure.com/en-US/products/software/wireless-workbench) chat and [SideChain's TheaterChat](https://sidechainsoftware.com).

---

## Features

- **OSC-native transport** — messages travel as OSC packets; unicast to known peers, broadcast only for presence/discovery
- **Logical channels** — FOH, MON, RF, LIGHTING, VIDEO, STAGE, PRODUCTION — create and delete at runtime
- **Multi-channel view** — tap to focus a channel, long-press to add it to the view; combined feed sorted by timestamp with per-message channel colour dots
- **Flash / page** — one-button high-priority alert per channel; channel tab pulses + message box border lights up in the channel colour × 3
- **Shortcut messages** — per-channel one-tap buttons for common callouts (HOLD, CLEAR, BATTERY LOW…), optionally bound to F-keys
- **Session presets** — save and restore named channel layouts; portable across machines
- **Hybrid discovery** — mDNS/Bonjour auto-discovery + OSC beacon + manual static IP for locked-down show networks
- **Configurable identity** — set your display name and network interface from the settings screen; changes persist immediately
- **Priority levels** — info / warning / critical; critical messages are visually distinct and require ACK
- **Message deduplication** — UUID per message; never see the same message twice
- **Dark, high-contrast UI** — readable from a stage desk at 2m
- **Keyboard-first** — Enter to send, F1–F8 for shortcuts (bindings configurable per shortcut)
- **Cross-platform** — macOS, Windows, iOS/iPad (Flutter + Rust)

---

## Stack

| Layer | Technology |
|---|---|
| UI | Flutter |
| Core engine | Rust (tokio) |
| OSC transport | UDP via `rosc` |
| Discovery | `mdns-sd` + OSC beacon + static IP |
| IPC (UI ↔ engine) | Local TCP JSON socket (`127.0.0.1:9001`) |

The Rust engine (`patch-core`) runs as a sidecar. The Flutter app connects to it over `127.0.0.1:9001`. All OSC encoding/decoding, peer management, and state happen in Rust; Flutter owns the UI only.

---

## Getting Started

### Prerequisites

- [Rust](https://rustup.rs/) 1.75+
- [Flutter](https://flutter.dev/docs/get-started/install) 3.x

### Run

```bash
# Clone
git clone https://github.com/vk0eppel/Patch.git
cd Patch

# Start the engine (generates patch.toml on first run)
cd patch-core
cargo run

# Start the UI (new terminal)
cd patch_app
flutter run -d macos   # or -d windows
```

The engine generates a `patch.toml` config file on first run with sane defaults (OSC port 9000, all interfaces, 7s heartbeat). Edit it to set a static NIC, add known peers, or change your display name — or use the Settings screen inside the app.

### iOS / iPad

```bash
cd patch_app
flutter run -d <your-device-id>
```

---

## Project Layout

```
patch/
├── patch-core/        Rust engine — OSC, transport, discovery, reliability, bridge, sessions
└── patch_app/         Flutter UI — channels, messages, peers, settings, session management
```

See [CLAUDE.md](CLAUDE.md) for the full architecture, bridge protocol reference, OSC namespace, and development notes.

---

## OSC Integration

Patch listens on UDP port 9000 (configurable). Send a standard OSC message to it from any device on the LAN:

```
/patch/channel/rf/message  <sender_id> <sender_name> <channel_id> <message_id> <timestamp_ms> <priority> <payload>
```

Flash/page a channel from any OSC source:

```
/patch/channel/rf/flash  <sender_id> <sender_name>
```

The legacy address `/patch/message` is also decoded for backwards compatibility with older integrations.

---

## Configuration (`patch.toml`)

```toml
client_id = "..."              # UUID — generated once, stable across sessions
client_name = "FOH Engineer"   # Editable from the Settings screen
osc_port = 9000
bridge_port = 9001
network_interface = "en0"      # Omit to bind all interfaces

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
- [x] Flutter bridge protocol
- [x] Settings screen — display name, NIC picker, shortcuts, channel management
- [x] Session presets — save / load / delete named channel layouts
- [x] Multi-channel view — combined feed, long-press to add channels
- [x] Flash animation — channel tab pulse + message box border/tint × 3
- [ ] Settings screen — static peer management via UI
- [ ] F-key bindings for shortcuts
- [ ] Reliability layer wired for critical messages (ACK + retransmit)
- [ ] External OSC trigger → Patch message mapping
- [ ] OSCQuery support for zero-config integration
- [ ] Optional WAN relay server

---

## License

TBD — private for now.

# CLAUDE.md

## Overview
Patch is a lightweight, cross-platform real-time communication system designed for live production teams (AV, broadcast, theatre, touring). It is optimized for low-latency operational messaging over local networks using OSC (Open Sound Control) as a primary transport layer.

The system is not a generic chat app. It is an operational coordination layer for live environments.

---

## Core Philosophy

Patch is built around three principles:

### 1. Operational-first communication
Messages are functional, not social. Every message should support live production execution.

### 2. Network-native design
Designed for unreliable, heterogeneous show networks (wired + Wi-Fi, multicast, segmented VLANs).

### 3. OSC-native interoperability
Patch is designed to integrate into existing show-control ecosystems (QLab, Companion, TouchDesigner, vMix, etc.) using OSC as a first-class transport.

---

## Stack

| Layer | Technology |
|---|---|
| UI | Flutter (macOS, Windows, iOS) |
| IPC bridge | TCP JSON socket — `patch-core` listens on `127.0.0.1:9001` |
| Core engine | Rust (tokio async runtime) |
| OSC transport | UDP unicast (messages/flash) + broadcast (presence/discovery) via `rosc` |
| Discovery | mDNS (`mdns-sd` crate) + OSC broadcast beacon + manual static IP |
| Config | `patch.toml` (TOML, auto-created on first run) |

The Flutter app connects to `patch-core` as a sidecar process over a local TCP socket. All OSC encoding/decoding, network I/O, and state management happen in Rust. Flutter owns rendering only.

---

## Project Structure

```
patch/
├── Cargo.toml                  # Workspace root
├── patch.toml                  # Runtime config (gitignored — auto-generated)
│
├── patch-core/                 # Rust engine
│   └── src/
│       ├── main.rs             # Entry point — loads config, wires subsystems
│       ├── osc/
│       │   ├── addresses.rs    # Canonical /patch/* OSC address constants + helpers
│       │   ├── types.rs        # PatchMessage, PeerPresence, ChannelFlash, Priority
│       │   └── codec.rs        # encode/decode → PatchEvent enum
│       ├── transport/mod.rs    # UDP socket, unicast send_to_peers, broadcast for presence
│       ├── discovery/mod.rs    # mDNS registration/browsing + heartbeat loop
│       ├── reliability/mod.rs  # ACK tracking, exponential-backoff retransmit
│       ├── state/
│       │   ├── mod.rs          # AppState (Arc), broadcast event bus, message buffer
│       │   ├── channel.rs      # Channel + ShortcutMessage
│       │   ├── peer.rs         # Peer + DiscoveryMode + has_address()
│       │   ├── config.rs       # Config struct, patch.toml load/save
│       │   └── session.rs      # SessionConfig, save/load/list/delete session files
│       └── bridge/
│           ├── mod.rs          # TCP server (one task per Flutter client)
│           ├── commands.rs     # Flutter→Rust command handlers
│           └── events.rs       # Rust→Flutter event serialiser
│
└── patch_app/                  # Flutter UI
    └── lib/
        ├── main.dart           # App root, bridge connect + loading state
        ├── bridge/
        │   └── bridge_client.dart  # TCP client, auto-reconnect, typed API
        ├── models/
        │   ├── channel.dart    # PatchChannel + ShortcutMessage
        │   └── message.dart    # PatchMessage + PeerInfo + SessionMeta
        ├── theme/
        │   └── patch_theme.dart    # Dark palette, typography, component themes
        ├── screens/
        │   ├── home_screen.dart    # Channel strip + multi-channel view + peers panel + flash layer
        │   └── settings_screen.dart # Identity, NIC picker, sessions, channels & shortcuts
        └── widgets/
            ├── channel_tab.dart    # Sidebar tab with color dot
            ├── flash_button.dart   # Animated FLASH/page button
            ├── message_list.dart   # Auto-scrolling, priority-colored message rows
            ├── message_input.dart  # Enter-to-send text field
            ├── shortcut_bar.dart   # One-tap shortcut chip strip
            └── peers_panel.dart    # Right panel — online peers, discovery mode
```

---

## Bridge Protocol

All IPC between Flutter and Rust is newline-delimited JSON over `127.0.0.1:9001`.

### Flutter → Rust (commands)
```json
{ "cmd": "send_message", "channel_id": "rf", "payload": "Battery low", "priority": 3 }
{ "cmd": "send_flash", "channel_id": "rf" }
{ "cmd": "get_channels" }
{ "cmd": "get_peers" }
{ "cmd": "get_messages", "channel_id": "rf", "limit": 50 }
{ "cmd": "get_interfaces" }
{ "cmd": "get_config" }
{ "cmd": "set_client_name", "name": "FOH Engineer" }
{ "cmd": "set_interface", "name": "en0" }
{ "cmd": "set_flash_on_critical", "enabled": true }
{ "cmd": "add_static_peer", "address": "192.168.1.50", "port": 9000, "label": "FOH Desk" }
{ "cmd": "upsert_channel", "id": "rf", "display_name": "RF", "color": "#1E88E5" }
{ "cmd": "delete_channel", "id": "rf" }
{ "cmd": "upsert_shortcut", "channel_id": "rf", "label": "HOLD", "payload": "HOLD — do not transmit", "priority": 2, "key_binding": "F1" }
{ "cmd": "delete_shortcut", "channel_id": "rf", "label": "HOLD" }
{ "cmd": "save_session", "name": "Festival Day 1" }
{ "cmd": "load_session", "slug": "festival-day-1" }
{ "cmd": "list_sessions" }
{ "cmd": "delete_session", "slug": "festival-day-1" }
```

### Rust → Flutter (events, streamed)
```json
{ "event": "message",             "data": { ...PatchMessage } }
{ "event": "message_acked",       "message_id": "...", "peer_id": "..." }
{ "event": "ack_send",            "message_id": "..." }
{ "event": "peer_updated",        "data": { ...Peer } }
{ "event": "peer_expired",        "data": { "peer_id": "..." } }
{ "event": "channel_flash",       "data": { "channel_id": "rf", ... } }
{ "event": "channel_list_updated" }
{ "event": "channels",            "data": [ ...Channel ] }
{ "event": "peers",               "data": [ ...Peer ] }
{ "event": "messages",            "channel_id": "rf", "data": [ ...PatchMessage ] }
{ "event": "interfaces",          "data": [ { "name": "en0", "ip": "..." } ] }
{ "event": "config",              "data": { "client_name": "...", "osc_port": 9000, "flash_on_critical": true, ... } }
{ "event": "client_name_changed", "name": "..." }
{ "event": "sessions",            "data": [ ...SessionMeta ] }
{ "event": "session_saved",       "slug": "...", "name": "..." }
{ "event": "session_loaded",      "slug": "...", "name": "...", "channel_count": 5 }
{ "event": "error",               "message": "..." }
```

---

## OSC Namespace

```
/patch/channel/{id}/message     # Core message — primary address (channel-scoped)
/patch/message                  # Legacy fallback — decoded only, for interop
/patch/ack                      # ACK for a message_id
/patch/presence                 # Heartbeat / presence announcement
/patch/system/heartbeat         # Standalone heartbeat ping
/patch/discovery                # Peer discovery beacon
/patch/channel/{id}/flash       # Flash/page a specific channel
```

### Send strategy

| Packet type | Transport |
|---|---|
| `/patch/channel/{id}/message` | Unicast to each known peer |
| `/patch/channel/{id}/flash` | Unicast to each known peer + local publish |
| `/patch/presence` heartbeat | Broadcast (must reach undiscovered peers) |
| `/patch/discovery` beacon | Broadcast (same) |

Messages and flash are **not** broadcast. If no peers are known yet, packets are silently dropped. Peer addresses are learned from UDP `from` fields on receive and from mDNS resolution.

### /patch/channel/{id}/message arguments
| # | Type | Field |
|---|---|---|
| 0 | string | sender_id (UUID) |
| 1 | string | sender_name |
| 2 | string | channel_id |
| 3 | string | message_id (UUID) |
| 4 | int64 | timestamp (ms since epoch) |
| 5 | int32 | priority (0=debug 1=info 2=warning 3=critical) |
| 6 | string | payload |

---

## Channels

Channels are dynamic and identified by a stable slug (e.g. `"rf"`, `"foh"`).

Default channels seeded on first run:
`FOH` · `MON` · `RF` · `LIGHTING` · `VIDEO` · `STAGE` · `PRODUCTION`

Each channel has:
- stable `id` (slug used in OSC addresses)
- `display_name` (shown in UI)
- `color` (hex, for visual differentiation)
- `shortcuts` (list of one-tap/keyboard shortcut messages)

Channels can be created and deleted at runtime. Changes are persisted to `patch.toml` immediately.

### Shortcut messages
Per-channel shortcut buttons appear in a strip above the input field.
Each shortcut has a `label`, `payload`, optional `key_binding` (e.g. `"F1"`), and `priority`.
Shortcuts can be created, edited, and deleted in the settings screen.

---

## Sessions

A session is a named snapshot of the current channel layout (channels + shortcuts + static peers). Sessions are saved as TOML files under `./sessions/{slug}.toml`.

- **Save** — captures current channels and static peers under a user-chosen name
- **Load** — replaces all current channels with those from the session (persisted immediately)
- **Delete** — removes the session file

Sessions are managed from the Settings screen and are designed to be portable across machines running Patch.

---

## Discovery

Patch uses three discovery modes, shown in the peers panel:

| Mode | How | Icon |
|---|---|---|
| mDNS / Bonjour | `_patch._udp.local.` service registration | 🔍 |
| OSC beacon | `/patch/presence` broadcast every 7s | 📡 |
| Manual IP | Static entries in `patch.toml` | 📌 |

Peers expire after 30s of missed heartbeats (configurable in `patch.toml`).

Peer addresses (IP + OSC port) are populated from two sources:
1. The UDP `from` address on any received packet
2. mDNS `ServiceResolved` events (address + port from the TXT/SRV record)

---

## Config (`patch.toml`)

Auto-generated on first run. Key fields:

```toml
client_id = "..."           # UUID — stable across sessions
client_name = "FOH Engineer"
osc_port = 9000             # UDP port for OSC
bridge_port = 9001          # TCP port for Flutter bridge
network_interface = "en0"   # Optional — bind to specific NIC
heartbeat_interval_secs = 7
peer_timeout_secs = 30
flash_on_critical = true    # Auto-flash channel when priority-3 message arrives

[[static_peers]]
address = "192.168.1.50"
port = 9000
label = "Monitor World"
```

`client_name` can be changed at runtime from the Settings screen and is persisted immediately.

---

## Running

```bash
# 1. Start the Rust engine
cd patch-core
cargo run

# 2. Start the Flutter app (new terminal)
cd patch_app
flutter run -d macos
```

The engine must be running before the Flutter app launches. The app retries the bridge connection automatically.

---

## Development Notes

- Run `cargo check` from the workspace root to type-check the engine without building.
- Run `flutter analyze` in `patch_app/` to lint the Dart code.
- `patch.toml` is gitignored — a fresh one is generated on each new machine.
- All OSC encoding/decoding lives in `patch-core/src/osc/codec.rs`. Add and test new packet types there first.
- The bridge protocol is the contract between the two halves. Both sides must agree on field names and event types — update both `bridge/commands.rs` and `bridge_client.dart` together.
- Adding a new command: (1) add `cmd_*` handler in `commands.rs`, (2) add a method to `BridgeClient`, (3) add a case to `_handleEvent` in `home_screen.dart` or the relevant screen.
- `Priority` uses manual `Serialize`/`Deserialize` impls to emit integers (not variant name strings). Always use `(j['priority'] as num).toInt()` on the Dart side.
- Flash fires `AppEvent::ChannelFlash` locally after sending, so the sender always sees their own flash without needing to receive it back over the network.
- Flash animation uses timer-based `setState` + `Future.delayed` (not `AnimationController`/`TweenSequence`) in `_FlashLayer` — the `TweenSequence` approach proved visually unreliable on macOS. Don't revert to it.
- Auto-flash on critical: when a `message` event with `priority == 3` arrives, `_dispatch` calls `_triggerFlash` if `_flashOnCritical` is true. The flag is read from `get_config` on startup and persisted to `patch.toml` via `set_flash_on_critical`. Toggle is in Settings → Behavior.
- F-key bindings: `HardwareKeyboard.instance.addHandler` is registered in `_HomeScreenState.initState` and removed in `dispose`. It intercepts `KeyDownEvent` before the `TextField` sees it, maps `LogicalKeyboardKey.f1`–`f12` → `"F1"`–`"F12"`, and fires the first matching shortcut across all selected channels. Keys not bound to a shortcut are not consumed.
- Multi-channel selection: tap = exclusive select, long press = toggle into multi-select. The combined message feed and `_FlashLayer` both scope to the `_ChannelView` area.

---

## Known Incomplete (next tasks)

- [ ] Settings screen — add static peer via UI
- [x] Keyboard shortcut binding in Flutter (F1–F12 wired to shortcut bar)
- [ ] Reliability manager wired into the send path for critical messages
- [ ] Wire heartbeat send through transport (discovery module encodes presence but needs the send handle)

---

## Reliability Model

Patch assumes:
- Packet loss can occur
- Networks can be segmented
- Devices may appear/disappear dynamically

To compensate:
- All messages carry a UUID `message_id` for dedup and ACK
- Message dedup is enforced in `store_message` (same `message_id` is never stored twice)
- ACK required for `priority=3` (critical) messages
- Retransmit uses exponential backoff: 100ms → 200ms → 400ms → … (max 5 retries)
- Client maintains a 500-message local buffer per session

---

## UI Principles

Patch UI is designed for live environments:

- dark mode always
- high contrast typography — readable at 2m from a stage desk
- large `HH:MM:SS` timestamps on every message
- channel color-coded throughout
- critical messages visually distinct (red left border + background tint)
- keyboard-first on desktop (Enter to send, F1–F12 fire bound shortcuts from any focus state)
- touch-first on iPad
- **multi-channel view**: tap to select exclusively, long-press to toggle into multi-select; combined feed sorted by timestamp; channel colour dot on each message row
- **flash**: channel tab pulses (3× scale animation); message box border + background tint pulses 3× in the channel colour (`_FlashLayer` inside `_ChannelView` Stack); fires automatically on priority-3 messages when enabled
- **NIC picker**: Settings → Network Interface; dropdown shows all interfaces with name + IP; "Auto" binds all; change persists to `patch.toml`, takes effect on next restart
- **Behavior settings**: Settings → Behavior; currently: "Flash on critical messages" toggle (default on)

---

## Integration Philosophy

Patch is a node in a larger OSC ecosystem. It can receive external OSC events and translate them into Patch messages or system alerts.

Example:
```
/rf/battery_low → /patch/channel/rf/message (priority=3, payload="Battery low — swap now")
```

Designed to interoperate with: QLab, Companion, TouchDesigner, vMix, custom scripts.

---

## Security Model

Initial deployments assume trusted LAN environments. No authentication.

Future:
- encrypted OSC layer
- authenticated relay mode
- role-based access control

---

## Non-goals

Patch is NOT:
- a social messaging platform
- a cloud-first SaaS product
- a consumer chat app
- a general-purpose Slack alternative

---

## Key Design Constraint

Every feature must answer:

> "Does this help a crew execute a live show more reliably?"

If not, it is out of scope.

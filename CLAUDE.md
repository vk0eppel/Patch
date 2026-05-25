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
| UI | Flutter (macOS, Windows, Linux, iOS, iPad) |
| Engine | Rust (tokio), linked as `cdylib`/`staticlib` into the Flutter app |
| UI ↔ engine | `flutter_rust_bridge` v2 — typed FFI, no IPC |
| OSC transport | UDP unicast (messages/flash) + broadcast (presence/discovery) via `rosc` |
| Discovery | mDNS (`mdns-sd` crate) + OSC broadcast beacon + manual static IP |
| Config | `patch.toml` (TOML, auto-created on first run) |

**Single process, single binary.** The Rust engine is compiled into a static/dynamic library and linked directly into the Flutter app via `flutter_rust_bridge`. There is no IPC layer, no sidecar process, no TCP socket. The build is driven by `cargokit` (a Flutter FFI plugin under `patch_app/rust_builder/`) which runs `cargo` during the native build phase for each target platform.

---

## Project Structure

```
patch/
├── Cargo.toml                       # Workspace root
├── flutter_rust_bridge.yaml         # Codegen config (regenerate on api.rs changes)
│
├── patch-core/                      # Rust engine (cdylib + staticlib + rlib)
│   └── src/
│       ├── lib.rs                   # Module declarations + injects frb_generated
│       ├── api.rs                   # Public FFI surface — scanned by FRB codegen
│       ├── frb_generated.rs         # FRB-generated FFI glue (regenerated)
│       ├── osc/
│       │   ├── addresses.rs         # Canonical /patch/* OSC address constants
│       │   ├── types.rs             # PatchMessage, PeerPresence, ChannelFlash, Priority
│       │   └── codec.rs             # encode/decode → PatchEvent enum
│       ├── transport/mod.rs         # UDP socket, unicast send_to_peers, broadcast for presence
│       ├── discovery/mod.rs         # mDNS registration/browsing + heartbeat loop
│       ├── reliability/mod.rs       # ACK tracking, exponential-backoff retransmit
│       └── state/
│           ├── mod.rs               # AppState (Arc), broadcast event bus, message buffer
│           ├── channel.rs           # Channel + ShortcutMessage
│           ├── peer.rs              # Peer + DiscoveryMode + has_address()
│           ├── config.rs            # Config struct, patch.toml load/save, data_dir()
│           └── session.rs           # SessionConfig, save/load/list/delete session files
│
└── patch_app/                       # Flutter UI
    ├── pubspec.yaml                 # Depends on flutter_rust_bridge + path-dep on rust_builder
    ├── rust_builder/                # Local FFI plugin — cargokit-driven Rust build
    │   ├── pubspec.yaml             # Declares plugin platforms (android/ios/macos/linux/windows)
    │   ├── cargokit/                # Vendored build tool (excluded from analysis)
    │   ├── macos/patch_core.podspec # Script-phase invokes cargokit/build_pod.sh
    │   ├── ios/patch_core.podspec   # Same, for iOS device + simulator XCFramework
    │   ├── windows/CMakeLists.txt   # apply_cargokit() → patch_core.dll
    │   ├── linux/CMakeLists.txt     # apply_cargokit() → libpatch_core.so
    │   └── android/build.gradle     # apply cargokit plugin → libpatch_core.so per ABI
    └── lib/
        ├── main.dart                # App root, BridgeClient.connect → render
        ├── bridge/
        │   └── bridge_client.dart   # Façade over generated FRB bindings (see below)
        ├── src/rust/                # Generated Dart bindings (excluded from analysis)
        │   ├── api.dart             # Typed function bindings + ConfigSnapshot, PatchAppEvent
        │   ├── api.freezed.dart     # freezed-generated PatchAppEvent sealed union
        │   ├── frb_generated*.dart  # FRB runtime glue
        │   ├── osc/types.dart       # PatchMessage, ChannelFlash, PeerPresence, Priority
        │   ├── state/{channel,peer,config,session}.dart
        │   └── transport.dart       # InterfaceInfo
        ├── models/
        │   ├── channel.dart         # PatchChannel + ShortcutMessage (UI-side models)
        │   └── message.dart         # PatchMessage + PeerInfo + SessionMeta (UI-side models)
        ├── theme/
        │   └── patch_theme.dart     # Dark palette, typography, component themes
        ├── screens/
        │   ├── home_screen.dart     # Channel strip + multi-channel view + peers panel + flash layer
        │   └── settings_screen.dart # Identity, NIC picker, sessions, channels & shortcuts
        └── widgets/
            ├── channel_tab.dart     # Sidebar tab with color dot
            ├── flash_button.dart    # Animated FLASH/page button
            ├── message_list.dart    # Auto-scrolling, priority-colored message rows
            ├── message_input.dart   # Enter-to-send text field
            ├── shortcut_bar.dart    # One-tap shortcut chip strip
            └── peers_panel.dart     # Right panel — online peers, discovery mode
```

---

## FFI API (Rust ↔ Dart)

The Rust public surface lives in `patch-core/src/api.rs`. `flutter_rust_bridge_codegen` scans it and emits typed Dart bindings into `patch_app/lib/src/rust/`. The bindings are consumed via the `BridgeClient` façade in `patch_app/lib/bridge/bridge_client.dart`, which:

1. Calls `RustLib.init()` then `api.init()` once on app start (from `BridgeClient.connect()`).
2. Subscribes to `api.subscribeEvents()` and forwards each typed `PatchAppEvent` into a legacy `Stream<Map<String, dynamic>>` that the screens already consume.
3. Wraps each command function so a fire-and-forget call still emits a response event (e.g. `getChannels()` calls `api.getChannels()`, awaits, then pushes `{event: 'channels', data: […]}` so screens' `_handleEvent` keeps working without restructuring).

### Public functions (mirror calls on the Dart side via `rust.<name>` after codegen)

```rust
init(config_dir: Option<String>) -> Result<()>
send_message(channel_id, payload, priority) -> Result<String>   // returns message_id
send_flash(channel_id) -> Result<()>
get_channels() -> Vec<Channel>
get_peers() -> Vec<Peer>
get_messages(channel_id, limit) -> Vec<PatchMessage>
get_interfaces() -> Result<Vec<InterfaceInfo>>
get_config() -> ConfigSnapshot
set_client_name(name)
set_interface(name: Option<String>)
set_flash_on_critical(enabled) / set_flash_on_message(enabled)
set_channel_flash(channel_id, flash_on_critical: Option<bool>, flash_on_message: Option<bool>)
add_static_peer(address, port, label)
upsert_channel(id, display_name, color) / delete_channel(id)
upsert_shortcut(channel_id, label, payload, priority, key_binding) / delete_shortcut(channel_id, label)
save_session(name) -> SessionSaved
load_session(slug) -> SessionLoaded
list_sessions() -> Vec<SessionMeta>
delete_session(slug)
subscribe_events(sink: StreamSink<PatchAppEvent>) -> Result<()>   // long-lived stream
```

### `PatchAppEvent` variants (delivered via `subscribe_events`)

```rust
Message(PatchMessage)
MessageAcked { message_id, peer_id }
PeerUpdated(PeerPresence)
PeerExpired { peer_id }
ChannelFlash(ChannelFlash)
ChannelListUpdated
ClientNameChanged { name }
```

### Regenerating bindings

```bash
# From repo root, whenever api.rs changes
flutter_rust_bridge_codegen generate
```

This rewrites:
- `patch-core/src/frb_generated.rs` — Rust FFI glue
- `patch_app/lib/src/rust/*` — typed Dart bindings

After regeneration, run `dart run build_runner build` from `patch_app/` if `PatchAppEvent` (or any other freezed type) changed.

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

### `/patch/channel/{id}/message` arguments
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

A session is a named snapshot of the current channel layout (channels + shortcuts + static peers). Sessions are saved as TOML files under `<data_dir>/sessions/{slug}.toml`.

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

### iOS / macOS Local Network permission
On iOS 14+ and macOS 15+, the OS prompts on first OSC send/receive. Required Info.plist keys (both already in this repo):

- `NSLocalNetworkUsageDescription` — user-facing string
- `NSBonjourServices` — array containing `_patch._udp` (Apple's format omits the trailing `.local.`)

If the user denies, OSC traffic silently fails. Future work: surface a permission-denied UI hint via the FRB event stream.

---

## Config (`patch.toml`)

Auto-generated on first run in the platform data directory:

| OS | Path |
|---|---|
| macOS (non-sandboxed) | `~/Library/Application Support/Patch/patch.toml` |
| macOS (sandboxed Flutter app) | `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Patch/patch.toml` |
| Windows | `%APPDATA%\Patch\patch.toml` |
| Linux | `~/.local/share/Patch/patch.toml` |
| iOS | App sandbox via `dirs::data_dir()` |

Resolution is via `crate::state::config::data_dir()`. On first run, a legacy `./patch.toml` in the CWD (left from the pre-FFI dev binary era) is migrated automatically into the new location.

Key fields:

```toml
client_id = "..."           # UUID — stable across sessions
client_name = "FOH Engineer"
osc_port = 9000             # UDP port for OSC
network_interface = "en0"   # Optional — bind to specific NIC
heartbeat_interval_secs = 7
peer_timeout_secs = 30
flash_on_critical = true    # Auto-flash channel when priority-3 message arrives
flash_on_message = false    # Auto-flash on every incoming message

[[static_peers]]
address = "192.168.1.50"
port = 9000
label = "Monitor World"
```

`client_name` can be changed at runtime from the Settings screen and is persisted immediately.

---

## Running

```bash
# macOS / iPad / iPhone
cd patch_app
flutter run -d macos          # or -d <iphone-id>

# Windows / Linux (generate the platform folder on first use)
flutter create --platforms=windows .   # or linux
flutter run -d windows                 # or linux
```

A single `flutter run` builds and links the Rust engine into the host binary via `cargokit`. There is no second process to start.

### Prerequisites
- **Rust via `rustup`** (NOT Homebrew Rust). Cargokit requires `rustup` to manage cross-compilation targets (e.g. `aarch64-apple-darwin` + `x86_64-apple-darwin` for universal macOS, plus iOS/Android targets as needed). Install with `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`. If Homebrew Rust is present, `brew unlink rust` first so `rustup`'s `cargo` wins on PATH.
- **Flutter 3.x** with the desktop/iOS toolchains for whichever target you build.
- **CocoaPods** for macOS / iOS (`brew install cocoapods`). Plugins are wired through `Podfile`s under `patch_app/macos/` and `patch_app/ios/`.

---

## Development Notes

- `cargo check -p patch_core` type-checks the engine quickly. The package name uses an underscore (`patch_core`, not `patch-core`) because cargokit's `build_pod.dart` resolves the static-library file as `lib${packageName}.a`; the on-disk crate directory is still `patch-core/`.
- `flutter analyze` lints the Dart side. `analysis_options.yaml` excludes `lib/src/rust/**` (generated) and `rust_builder/cargokit/**` (vendored).
- After editing `patch-core/src/api.rs`, regenerate bindings (`flutter_rust_bridge_codegen generate` from repo root) and rerun `dart run build_runner build` in `patch_app/` if any freezed type changed.
- The FRB build requires `flutter_rust_bridge` v2.12.0 with the `chrono`, `uuid`, and `rust-async` features. The `rust-async` feature is load-bearing: without it, async functions in `api.rs` have no Tokio reactor and `tokio::spawn` panics with *"there is no reactor running"*.
- `api::subscribe_events` is `async` specifically so FRB calls it inside its managed Tokio runtime — the `tokio::spawn` inside relies on that ambient runtime.
- All OSC encoding/decoding lives in `patch-core/src/osc/codec.rs`. Add and test new packet types there first.
- Network interface filtering: `list_interfaces()` and `bind_address()` in `transport/mod.rs` both use `is_usable_ip()` to skip loopback (`127.x`, `::1`), link-local IPv6 (`fe80::`), and virtual interface prefixes (`utun`, `awdl`, `llw`, `stf`, `gif`, `p2p`, `XHC`, `anpi`, `bridge`, `vmnet`, `veth`, `docker`). Both prefer IPv4 over IPv6. This prevents bind errors when a saved interface has a `fe80::` address as its first entry.
- `Priority` uses manual `Serialize`/`Deserialize` impls to emit integers (not variant name strings). The Dart-side façade reads `priority.index` from the FRB-generated `Priority` enum when converting back to the legacy event Map shape.
- Flash fires `AppEvent::ChannelFlash` locally after sending, so the sender always sees their own flash without needing to receive it back over the network.
- Flash animation uses timer-based `setState` + `Future.delayed` (not `AnimationController`/`TweenSequence`) in `_FlashLayer` — the `TweenSequence` approach proved visually unreliable on macOS. Don't revert to it.
- Auto-flash on message/critical: `_dispatch` ORs global flags (`_flashOnMessage`, `_flashOnCritical`) with per-channel flags (`ch.flashOnMessage`, `ch.flashOnCritical`). Global flags are read via `get_config` on startup; `config_updated` events trigger a `getConfig()` refresh so changes in Settings take effect immediately without restart. Per-channel flags are stored on `Channel` (serde defaults: `flash_on_critical=true`, `flash_on_message=false`) and updated via `set_channel_flash`.
- F-key bindings: `HardwareKeyboard.instance.addHandler` is registered in `_HomeScreenState.initState` and removed in `dispose`. It intercepts `KeyDownEvent` before the `TextField` sees it, maps `LogicalKeyboardKey.f1`–`f12` → `"F1"`–`"F12"`, and fires the first matching shortcut across all selected channels. Keys not bound to a shortcut are not consumed.
- Multi-channel selection: tap = exclusive select, long press = toggle into multi-select. The combined message feed and `_FlashLayer` both scope to the `_ChannelView` area.
- The TCP bridge that used to live at `patch-core/src/bridge/` is **gone**. If you find yourself needing inter-process communication for a debug tool, build it as a separate small binary that links `patch_core` as an rlib — don't reintroduce the bridge.

---

## Known Incomplete (next tasks)

- [ ] Settings screen — add static peer via UI (the `add_static_peer` API exists but is a no-op stub)
- [x] Keyboard shortcut binding in Flutter (F1–F12 wired to shortcut bar)
- [ ] Reliability manager wired into the send path for critical messages
- [ ] Wire heartbeat send through transport (discovery module encodes presence but needs the send handle)
- [ ] Surface iOS/macOS Local Network permission-denied via the FRB event stream (currently logged-only)

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
- **flash**: channel tab pulses (3× scale animation); message box border + background tint pulses 3× in the channel colour (`_FlashLayer` inside `_ChannelView` Stack); triggers determined by OR of global + per-channel flags
- **NIC picker**: Settings → Network Interface; dropdown shows only real NICs (loopback, virtual/tunnel, and link-local IPv6 interfaces filtered out); "Auto" binds all; change persists to `patch.toml`, takes effect on next restart
- **Behavior settings**: Settings → Behavior — global flash defaults ("Flash on every message", "Flash on critical messages"); Settings → channel editor footer — per-channel overrides for the same two flags (either global or channel flag being on is sufficient to trigger)

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

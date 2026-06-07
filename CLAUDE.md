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
├── docs/                            # End-user documentation (quick-start, networking, OSC integration)
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
│       ├── midi/mod.rs              # MIDI input listener (desktop) — fire per-channel macros from Note/CC
│       ├── reliability/mod.rs       # ACK tracking, exponential-backoff retransmit
│       └── state/
│           ├── mod.rs               # AppState (Arc), broadcast event bus, message buffer
│           ├── channel.rs           # Channel + MacroMessage
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
        │   ├── channel.dart         # PatchChannel + MacroMessage (UI-side models)
        │   └── message.dart         # PatchMessage + PeerInfo + SessionMeta (UI-side models)
        ├── theme/
        │   └── patch_theme.dart     # Dark palette, typography, component themes
        ├── screens/
        │   ├── home_screen.dart     # Channel strip + multi-channel view + peers panel + flash layer
        │   └── settings_screen.dart # Identity, NIC picker, behavior, channels & macros
        └── widgets/
            ├── channel_tab.dart     # Sidebar tab with color dot
            ├── flash_button.dart    # Animated FLASH/page button
            ├── message_list.dart    # Auto-scrolling, priority-colored message rows
            ├── message_input.dart   # Enter-to-send text field
            ├── sessions_dialog.dart # Sessions panel — save/load named presets, import/export .toml
            ├── macros_panel.dart    # Toggleable right panel — macros as fixed-height buttons; also exports ChannelMacro
            └── peers_panel.dart     # Right panel — online peers, discovery mode
```

> End-user documentation lives in [`docs/`](docs/README.md) — quick-start, channels & sessions, networking, OSC integration, troubleshooting. This file (`CLAUDE.md`) is developer/architecture reference only.

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
get_midi_ports() -> Vec<String>                                   // available MIDI input port names (desktop; empty on iOS/Android)
get_config() -> ConfigSnapshot
set_client_name(name)
set_role(role: Option<String>)                                     // self-assigned role (free text; empty → None), broadcast in presence
set_interface(name: Option<String>)
set_flash_on_critical(enabled) / set_flash_on_message(enabled)
set_flash_count(count: u8)                                        // global pulse count (3–7, default 4)
set_audible_alert(enabled: bool)                                  // play a sound on flash (default off)
set_macros_columns(columns: u8)                                   // macros panel column count (1–3, default 1)
set_channel_flash(channel_id, flash_on_critical: Option<bool>, flash_on_message: Option<bool>, flash_count: Option<u8>)
add_static_peer(address, port, label)
remove_static_peer(address, port)
upsert_channel(id, display_name, color) / delete_channel(id)
reset_channels()                                                  // delete all channels, re-seed factory defaults
request_channels(peer_id: String) -> Result<()>                   // ask a peer for its channel layout (reply → ChannelsOffered)
adopt_channels(channels: Vec<Channel>) -> Result<u32>             // merge offered channels (adds only missing); returns count added
upsert_macro(channel_id, label, payload, priority, key_binding, midi_note: Option<u8>, midi_cc: Option<u8>) / delete_macro(channel_id, label)
reorder_macros(channel_id, ordered_labels)                       // drag-to-reorder; unlisted labels kept, unknown ignored
upsert_global_macro(label, payload, priority, key_binding) / delete_global_macro(label)  // shown on every channel
reorder_global_macros(ordered_labels)                            // drag-to-reorder global macros
save_session(name) -> SessionSaved
load_session(slug) -> SessionLoaded
list_sessions() -> Vec<SessionMeta>
delete_session(slug)
export_layout(path: String, name: String) -> Result<()>           // write current layout to arbitrary path
import_layout(path: String) -> Result<SessionLoaded>              // load + apply layout from arbitrary path
clear_messages(channel_id: Option<String>) -> Result<()>          // clear buffer for one channel or all (None)
export_messages(channel_id: Option<String>, path: String) -> Result<()>  // write CSV to path; None = all channels
clear_stale_peers(max_age_secs: u64) -> Result<()>                // remove OscBeacon/Mdns peers not heard from recently
shutdown() -> Result<()>                                          // broadcast /patch/bye so peers drop us promptly (call on app close)
subscribe_events(sink: StreamSink<PatchAppEvent>) -> Result<()>   // long-lived stream
```

### `PatchAppEvent` variants (delivered via `subscribe_events`)

```rust
Message(PatchMessage)
MessageAcked { message_id, peer_id }
MessageDelivery { message_id, delivered, total, failed, failed_peers }  // per-critical delivery progress/result (sender side)
PeerUpdated(PeerPresence)
PeerExpired { peer_id }
ChannelFlash(ChannelFlash)
ChannelListUpdated
ChannelsOffered { from_peer_id, from_name, channels }  // a peer's layout in reply to request_channels — UI previews/merges, never auto-applied
ClientNameChanged { name }
PermissionDenied { context }
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
/patch/ack                      # ACK for a message_id
/patch/presence                 # Heartbeat / presence / discovery — the single announce address (arg 4 = optional role)
/patch/bye                      # Departure announcement (graceful shutdown) — arg: peer_id
/patch/channel/{id}/flash       # Flash/page a specific channel
/patch/channels/request         # Ask a peer for its channel layout — arg: requester peer_id (unicast)
/patch/channels/announce        # Reply with the layout — args: peer_id, peer_name, channels JSON (unicast back)
```

`/patch/presence` is the **only** discovery+heartbeat address: it is broadcast and unicast every
heartbeat, and an external OSC tool can announce itself simply by sending one (the receiver registers
the sender as a peer). Earlier vestigial `/patch/discovery` and `/patch/system/heartbeat` addresses (plus
unused `/patch/typing`, `/patch/system/alert`, `/patch/system/status` constants) were removed — they were
decoded-but-inert and never sent, and presence subsumes them.

### Send strategy

| Packet type | Transport |
|---|---|
| `/patch/channel/{id}/message` | Unicast to each known peer |
| `/patch/channel/{id}/flash` | Unicast to each known peer + local publish |
| `/patch/presence` heartbeat | Broadcast (`255.255.255.255` + per-interface subnet, for undiscovered peers) **and** unicast to every known peer (bootstraps two-way discovery + sustains liveness) |
| `/patch/bye` departure | Direct unicast to known/static peers + broadcast, on shutdown |

Messages and flash are **not** broadcast. If no peers are known yet, packets are silently dropped. Peer addresses are learned from UDP `from` fields on receive and from mDNS resolution.

### `/patch/channel/{id}/message` arguments
`channel_id` is encoded in the OSC address path, not in the args.

| # | Type | Field |
|---|---|---|
| 0 | string | sender_id (UUID) |
| 1 | string | sender_name |
| 2 | string | message_id (UUID) |
| 3 | int64 | timestamp (ms since epoch) |
| 4 | int32 | priority (0=debug 1=info 2=warning 3=critical) |
| 5 | string | payload |

---

## Channels

Channels are dynamic and identified by a stable slug (e.g. `"rf"`, `"foh"`).

Default channels seeded on first run:
`AUDIO` · `RF` · `LIGHTING` · `VIDEO` · `STAGE`

Each default channel is seeded with macros (in `state/config.rs::default_channels`) — channel-specific
status/problem callouts (info → warning → critical), **not** show-calling cues. Generic cross-channel acks
(YES/NO/COPY) are intentionally **not** duplicated per channel — they're reserved for the future "global
shortcuts" feature. Seeded sets (all on F1–F…):

- `AUDIO`: **ONE** (info, F1), **TWO** (info, F2), **CHECK** (warning, F3), **PROBLEM W/** (critical, F4)
- `RF`: **CLEAR** (info, F1), **HOLD** (warning, F2), **LOW BATT** (critical, F3)
- `LIGHTING`: **READY** (info, F1), **FIXTURE DOWN** (warning, F2), **DMX FAULT** (critical, F3)
- `VIDEO`: **READY** (info, F1), **GLITCH** (warning, F2), **NO SIGNAL** (critical, F3)
- `STAGE`: **CLEAR** (info, F1), **HAZARD** (warning, F2), **MEDICAL** (critical, F3)

The seed is locked by `state::config::tests::default_channels_seed_macros`.

Each channel has:
- stable `id` (slug used in OSC addresses)
- `display_name` (shown in UI)
- `color` (hex, for visual differentiation)
- `shortcuts` (list of one-tap/keyboard shortcut messages)
- `flash_count` (optional `u8`; `None` = use global setting, `Some(n)` = override pulse count for this channel)

Channels can be created and deleted at runtime. Changes are persisted to `patch.toml` immediately.

### Macros (MacroMessage)
Per-channel macro buttons appear in a **vertical side panel** on the right side of the message area (toggled with the keyboard icon in the `_ChannelView` header). The panel shows all macros simultaneously with no scroll — buttons share the panel height equally. Users configure 1, 2, or 3 columns (`macros_columns` in `patch.toml`, set in **Settings → Behavior → Macros panel columns**); each column is 160 px wide so the panel grows from 160 px (1 column) to 480 px (3 columns). The panel is implemented in `macros_panel.dart`, which also exports the `ChannelMacro` type used by `home_screen.dart`.
Each macro has a `label`, `payload`, optional `key_binding` (e.g. `"F1"`), `priority`, and optional
**MIDI bindings** (`midi_note` / `midi_cc`, 0–127). Macros can be created, edited, deleted, and
**drag-reordered** in the Settings screen (Channels & Macros section).

**MIDI triggers** (per-channel macros only): the engine's `midi` module (desktop-only — CoreMIDI/WinMM/ALSA
via `midir`; no-op on iOS/Android) opens every input port at startup and fires a macro **on its own channel**
when a bound Note On (velocity > 0) or CC (value ≥ 64) arrives — engine-side and *absolute*, unlike F-keys
which fire on the UI-selected channel via Flutter, so a footswitch works without focus. See the dev note
below for the threading model. Global macros don't take a MIDI binding (they have no fixed channel for the
engine to fire on).

**Global macros** (`Config.global_macros`, surfaced via `ConfigSnapshot.global_macros`) are a top-level list shown in their own **GLOBAL** group at the bottom of the macros panel on *every* channel. Firing one (tap or F-key) sends on the **currently-selected channel(s)** — identical dispatch to a per-channel macro, just configured once instead of duplicated per channel (it is **not** a crew-wide broadcast — that's the separate "ALL channel" item). Per-channel macros take F-key precedence over a global on the same key. Edited in **Settings → Global Macros** via `upsert_global_macro`/`delete_global_macro`/`reorder_global_macros`. In `home_screen.dart`, global macros are wrapped as `ChannelMacro` with an **empty `channelId` sentinel**; `_fireMacro` routes empty-id macros to every selected channel. The shared macro create/edit dialog (`_ChannelMacroEditor._showMacroEditDialog`, callback-driven) and `_MacroRow` (now `onDelete`-callback driven) are reused by both the per-channel and global editors. For a **new** macro the dialog autofills "Message text" from the "Button label" as you type — `_capitalizeFirst` (lowercase + capitalize first letter, e.g. `LOW BATT` → `Low batt`) — and stops the moment the user edits the message field (`autofillPayload` flag); editing an existing macro never auto-overwrites its saved message. Reordering goes through `reorder_macros` (a `ReorderableListView` in `_ChannelMacroEditor`, each `_MacroRow` carrying its own `ReorderableDragStartListener` handle); the panel and sidebar render in `Vec` order, so the new order flows through automatically and persists to `patch.toml`.

---

## Sessions

A session is a named snapshot of the current channel layout (channels + shortcuts + static peers). Sessions are saved as TOML files under `<data_dir>/sessions/{slug}.toml`.

- **Save** — captures current channels and static peers under a user-chosen name
- **Load** — replaces all current channels **and static peers** with those from the session (persisted immediately). Load/import go through `AppState::apply_session_full` (not `apply_session`, which is channels-only and is what `reset_channels` uses so a factory reset never wipes configured peers). Channel ids are validated up front (whole session rejected atomically on a bad id); session static peers with an invalid address or port 0 are skipped with a warning and de-duped by `address:port`. The Flutter `session_loaded` handler refreshes both channels **and** peers.
- **Delete** — removes the session file
- **Export to file** — writes the current layout as a `SessionConfig` TOML to a user-chosen path (`export_layout` in `api.rs`)
- **Import from file** — parses a `SessionConfig` TOML from a user-chosen path and applies it (`import_layout` in `api.rs`)

Sessions are accessed via the **folder icon** in the left sidebar (not the Settings screen). The `SessionsDialog` widget handles the UI; `file_picker` is used for the file dialogs. On macOS the sandbox entitlements include `com.apple.security.files.user-selected.read-write`.

---

## Discovery

Patch uses three discovery modes, shown in the peers panel:

| Mode | How | Icon |
|---|---|---|
| mDNS / Bonjour | `_patch._udp.local.` service registration | 🔍 |
| OSC beacon | `/patch/presence` broadcast every 7s | 📡 |
| Manual IP | Static entries in `patch.toml` | 📌 |

Peers never auto-expire — they stay in the list for the whole session. The Flutter peers panel derives a 3-state dot from `last_seen` (green ≤ 14 s, amber ≤ 35 s, grey beyond — ~2×/5× the 7 s heartbeat); a graceful `/patch/bye` or mDNS departure greys a peer immediately but keeps it. Removal is manual only (the "clear inactive peers" button → `clear_stale_peers`).

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
role = "FOH"                # Optional self-assigned role (free text); broadcast in presence, shown by peers
osc_port = 9000             # UDP port for OSC
network_interface = "en0"   # Optional — scopes the discovery beacon to one NIC (socket always binds 0.0.0.0)
heartbeat_interval_secs = 7
flash_on_critical = true    # Auto-flash channel when priority-3 message arrives
flash_on_message = false    # Auto-flash on every incoming message
flash_count = 4             # Flash pulse count per event (3–7, default 4)
macros_columns = 1          # Macros panel column count (1–3, default 1)
audible_alert = false       # Play a sound on flash — critical / page / broadcast (default off)

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
- The engine is rustfmt- and clippy-clean: `cargo fmt -p patch_core --check` and `cargo clippy -p patch_core --all-targets` should both pass with no output. Formatting policy is `rustfmt.toml` (edition 2021, max_width 100); keep new code `cargo fmt`-formatted rather than hand-aligning. **CI enforces this** — `.github/workflows/ci.yml` runs `fmt --check`, `clippy -- -D warnings`, `cargo test`, `flutter analyze`, and `flutter test` on every PR + push to main, with pinned toolchains (Rust 1.95.0, Flutter 3.44.1). Dart tests live in `patch_app/test/` (`models_test.dart`, `message_list_test.dart`) and cover pure model parsing + a bridge-free widget; the private FRB-typed bridge converters aren't unit-tested directly. The `frb_expand` unknown-cfg lint is declared in `[lints.rust]` in `Cargo.toml` (set by the FRB macro). Tests that touch disk hold `config::test_data_dir_guard()` — a **`tokio::sync::Mutex`** (not std) so the guard can be held across `.await` without tripping `await_holding_lock`.
- After editing `patch-core/src/api.rs`, regenerate bindings (`flutter_rust_bridge_codegen generate` from repo root) and rerun `dart run build_runner build` in `patch_app/` if any freezed type changed.
- The FRB build requires `flutter_rust_bridge` v2.12.0 with the `chrono`, `uuid`, and `rust-async` features. The `rust-async` feature is load-bearing: without it, async functions in `api.rs` have no Tokio reactor and `tokio::spawn` panics with *"there is no reactor running"*.
- `api::subscribe_events` is `async` specifically so FRB calls it inside its managed Tokio runtime — the `tokio::spawn` inside relies on that ambient runtime.
- All OSC encoding/decoding lives in `patch-core/src/osc/codec.rs`. Add and test new packet types there first.
- The OSC socket **always binds `0.0.0.0`** (`bind_address` in `transport/mod.rs`) so it receives on every interface, including broadcasts — a socket bound to a specific NIC IP can't get `255.255.255.255`. `network_interface` is **not** used for binding; it only scopes the discovery broadcast (`broadcast_targets`), which the heartbeat re-reads each tick, so **changing the NIC is live (no restart)**. `is_usable_ip()` (skips loopback `127.x`/`::1`, link-local IPv6 `fe80::`, and virtual prefixes `utun`/`awdl`/`llw`/`stf`/`gif`/`p2p`/`XHC`/`anpi`/`bridge`/`vmnet`/`veth`/`docker`) is still used by `list_interfaces()` (the UI picker) and `broadcast_targets()`.
- Presence/discovery broadcast (`Transport::broadcast`/`broadcast_now` → `broadcast_targets()`) sends to `255.255.255.255` **plus** each usable IPv4 NIC's subnet-directed broadcast (e.g. `192.168.1.255`, via the `network-interface` crate's `Addr::broadcast()`, reusing the `SKIP_PREFIXES`/`is_usable_ip` filters), deduped, recomputed each heartbeat. **Important:** `255.255.255.255` is load-bearing — it's the only address **macOS delivers to apps**; macOS ignores subnet-directed broadcasts entirely. The subnet copies only help on Linux/Windows, where they let the routing table push a copy out every interface (e.g. with a VPN/`utun` or Ethernet alongside Wi-Fi). **Do not remove the `255.255.255.255` target** — an earlier attempt to send *only* subnet-directed addresses broke discovery completely on macOS (zero-way). For macOS multi-interface (where `255.255.255.255` only exits the primary/default-route NIC), `Transport::broadcast_per_interface` (called each heartbeat in `discovery/mod.rs`, **macOS-only, no-op elsewhere**) additionally pushes `255.255.255.255` out of **every** usable interface: it routes through the single `send_loop` task as an `Outgoing::PerIfaceBroadcast`, and for each interface (enumerated by `usable_iface_indices`, reusing `SKIP_PREFIXES`/`is_usable_ip`, so `utun`/VPN are skipped) sets `IP_BOUND_IF` (via `libc::setsockopt` on the main socket fd) immediately before the send and clears it (`idx 0`) immediately after — so the receive loop's interface scope is constrained only for the microsecond of each send. Source port stays 9000 (the main socket), so receivers learn the correct unicast port. This is **additive** on top of `broadcast` (the default-route + subnet copies still go out), so it can't regress the working path. The environmental workaround (disconnect the VPN) and **static peers** remain valid fallbacks. Diagnostics: `cargo test -p patch_core print_broadcast_targets -- --ignored --nocapture` and `... print_iface_indices -- --ignored --nocapture` (shows the per-NIC egress list). **Do not remove the `255.255.255.255` target** from `broadcast_targets` — an earlier attempt to send *only* subnet-directed addresses broke discovery completely on macOS (zero-way). Multicast remains a separate, larger TODO (blocked by AP filtering + Apple's multicast entitlement). Broadcast sends are best-effort: `broadcast()` enqueues each target as `Outgoing::Broadcast`, and `send_loop` logs a failed broadcast send at **`debug`** (not `error`) — iOS routinely returns `EHOSTUNREACH`/"No route to host" for `255.255.255.255` (cellular / Wi-Fi transitions) and that's harmless (discovery falls back to mDNS + unicast + static peers). Unicast (`Outgoing::To`) send failures log at `warn` (a peer that just left).
- `Priority` uses manual `Serialize`/`Deserialize` impls to emit integers (not variant name strings). The Dart-side façade reads `priority.index` from the FRB-generated `Priority` enum when converting back to the legacy event Map shape.
- Flash fires `AppEvent::ChannelFlash` locally after sending, so the sender always sees their own flash without needing to receive it back over the network.
- Flash animation uses timer-based `setState` + `Future.delayed` (not `AnimationController`/`TweenSequence`) in `_FlashLayer` — the `TweenSequence` approach proved visually unreliable on macOS. Don't revert to it.
- Flash pulse count is configurable (default 4, range 3–7). `_FlashLayer` accepts a `pulseCount` param and loops that many times; `ChannelTab` accepts a `pulseCount` param and sets `_remainingPulses = pulseCount - 1`. The resolved count at flash time is stored in `_flashPulseCount` on `_HomeScreenState` and passes through `_ChannelView`. Per-channel override (`ch.flashCount`) takes priority over the global `_globalFlashCount`.
- Auto-flash on message/critical: `_dispatch` ORs global flags (`_flashOnMessage`, `_flashOnCritical`) with per-channel flags (`ch.flashOnMessage`, `ch.flashOnCritical`). Global flags are read via `get_config` on startup; `config_updated` events trigger a `getConfig()` refresh so changes in Settings take effect immediately without restart. Per-channel flags are stored on `Channel` (serde defaults: `flash_on_critical=true`, `flash_on_message=false`) and updated via `set_channel_flash`.
- Sessions panel: `SessionsDialog` is opened from the folder icon in `_ChannelStrip` (not Settings). It subscribes to bridge events directly and calls `listSessions()` on open. File import/export uses the `file_picker` package (`pubspec.yaml`). `export_layout` / `import_layout` in `api.rs` serialize/deserialize `SessionConfig` TOML to/from arbitrary paths.
- F-key bindings: `HardwareKeyboard.instance.addHandler` is registered in `_HomeScreenState.initState` and removed in `dispose`. It intercepts `KeyDownEvent` before the `TextField` sees it, maps `LogicalKeyboardKey.f1`–`f12` → `"F1"`–`"F12"`, and fires the first matching shortcut across all selected channels. Keys not bound to a shortcut are not consumed.
- Multi-channel selection: every tap toggles a channel in/out of the selection; at least one channel always remains selected (the last one cannot be deselected). The combined message feed and `_FlashLayer` both scope to the `_ChannelView` area.
- The TCP bridge that used to live at `patch-core/src/bridge/` is **gone**. If you find yourself needing inter-process communication for a debug tool, build it as a separate small binary that links `patch_core` as an rlib — don't reintroduce the bridge.
- `upsert_peer` preserves the transport-resolved address: `Peer::from_presence()` zeroes `address` and `osc_port`, so `upsert_peer` checks whether the existing peer record already has a non-empty address and copies it onto the new entry before inserting. This prevents the heartbeat `PeerUpdated` event from clearing an IP that `touch_peer_address` just set.
- Self-discovery is filtered in two places: (1) `discovery/mod.rs` mDNS `ServiceResolved` checks `if peer_id == client_id { continue; }` after extracting the TXT `peer_id` property; (2) `transport/mod.rs` `handle_event` checks `if p.peer_id == client_id { return; }` in the `Presence` arm, because the Mac receives its own UDP broadcast on the same socket. Both guards are necessary — removing either one causes the local device to appear in its own peers panel.
- mDNS `peer_name` TXT record: at registration, `"peer_name"` is added to the TXT props so `ServiceResolved` on other devices can read a clean display name. The fallback strips `._patch._udp` and everything after it from `info.get_fullname()`, which otherwise returns the full DNS label (e.g. `"FOH Engineer._patch._udp.local."`).
- `peer_updated` event → **debounced** `getPeers()`: `PeerPresence` (what `PeerUpdated` carries) has no address/port, so `home_screen.dart` must fetch the full `Peer` snapshot. Because `touch_peer_address` emits `PeerUpdated` on *every* received packet, the handler routes through `_schedulePeersRefresh()` — a trailing-edge ~800 ms debounce — so a busy channel does ~1 `getPeers()` fetch/window instead of one per message. Never try to update the in-memory peer list directly from a `PeerPresence` event — the address will always be blank.
- Static peers in `patch.toml`: `add_static_peer` / `remove_static_peer` in `api.rs` delegate to `AppState::add_static_peer` / `remove_static_peer`, which persist immediately via `cfg.save()`. Settings screen shows the current list, a "this device" IP hint, and an "Add peer" dialog using `TextInputType.url` for the IP field (avoids locale-specific decimal separators on iOS, e.g. "," instead of "."). Static peers are always contacted in `send_to_peers()` regardless of discovery state.
- Static peers always appear in the peers panel: `get_peers()` in `state/mod.rs` merges `config.static_peers` into the returned list. For each static peer whose `address:port` is not already represented by a dynamic entry, a synthetic `Peer` is created with `DiscoveryMode::ManualIp`, label (or raw address) as name, and a UUID v5 derived from `"static:{address}:{port}"` for stability across calls. The synthetic entry disappears automatically once a real packet arrives from that address and a dynamic entry is inserted for the same address.
- Auto-register peer on first received packet: in `transport/mod.rs` `handle_event`, when a `Message` or `Flash` arrives from a sender not yet in the peer registry (`has_peer` returns false), a minimal `PeerPresence` is synthesised from `sender_id` + `sender_name` and passed to `upsert_peer`. `touch_peer_address` is then called a second time (the first call at the top of `handle_event` was a no-op before the entry existed). This makes the sender appear in the peers panel immediately, even on AP-isolated networks where their broadcast heartbeats never arrive.
- Heartbeat is broadcast **and unicast to known peers** (`discovery/mod.rs` heartbeat loop calls both `Transport::broadcast` and `Transport::send_to_peers` with the presence bytes). The unicast leg bootstraps **two-way** discovery from one-way contact: if A received B's beacon (so A knows B's address) but A's own broadcast can't reach B (asymmetric routing — VPN/default-route on the wrong NIC — or AP isolation), A's unicast presence still reaches B (unicast follows the per-subnet route, not the default route), so B learns about A within one heartbeat. It also keeps known/static peers green via unicast where broadcast is blocked. Liveness stays honest because unicast presence is a *real received packet* (unlike the stale-mDNS-cache case). Bootstrap needs one initial contact in either direction (a beacon that gets through, an mDNS resolve, or a static-peer entry).
- Heartbeat name stays fresh: the heartbeat loop in `discovery/mod.rs` reads `hb_state.config().await.client_name` on every tick instead of using the `client_name` value captured at startup. This ensures a rename propagates to remote peers within one heartbeat interval (≤7s) without restarting the app.
- Peers never *time out* and are never auto-*removed*: the periodic expiry loop is gone, so peers stay in the registry for the full session (prevents them vanishing on AP-isolated networks where broadcast heartbeats are blocked). **Explicit departure signals** — an inbound `/patch/bye` (`transport::handle_event`) and an mDNS `ServiceRemoved` (`discovery/mod.rs`) — call `mark_peer_offline` (grey, *kept* in the list), **not** `expire_peer`. Actual removal happens only via the manual "clear inactive peers" button (`clear_stale_peers`). Status is computed on the Flutter side from `peer.lastSeen` as a 3-state dot (`_PeerTile._dotColor`): `ManualIp` entries are always gray; dynamic entries are **green** when `lastSeen` ≤ **2×** the heartbeat (healthy), **amber** when ≤ **5×** (a heartbeat or more missed — going quiet), **gray** beyond. The thresholds derive from `heartbeat_interval_secs` (exposed on `ConfigSnapshot`, passed `PeersPanel` → `_PeerTile`), so with the default 7 s heartbeat that's 14 s / 35 s but it tracks the configured interval. Each row also carries a relative "last seen" subtitle.
- `touch_peer_address` refreshes `last_seen`: every call (triggered by any received **OSC packet** — message, flash, heartbeat, presence) now writes `peer.last_seen = Utc::now()` and emits `PeerUpdated`, so the Flutter side calls `getPeers()` and the dot turns green immediately. Previously only `upsert_peer` (called on the first-ever packet from a peer) updated `last_seen`; subsequent packets from a known peer never refreshed it, leaving the dot grey after inactivity even when messages were flowing.
- **mDNS resolution must NOT touch `last_seen`** (liveness ≠ address). mDNS `ServiceResolved` goes through `AppState::resolve_peer_address` (not `touch_peer_address`/`upsert_peer_with_mode`): it updates the peer's address+port for unicast and sets the `Mdns` discovery mode, but leaves `last_seen` alone for a known peer and inserts a *brand-new* mDNS-only peer as already-stale (backdated 60 s → grey) until a real OSC packet greens it. Reason: `mdns-sd` replays `ServiceResolved` from its cache for the full record TTL (~1–2 min) after a peer quits, so bumping `last_seen` there kept departed peers green long past the 35 s heartbeat window and even un-did `/patch/bye` expiry. Liveness comes only from received OSC traffic; mDNS only supplies the address.
- `peer_expired` and `peer_updated` both call `getPeers()`: the `peer_expired` handler in `home_screen.dart` was changed from `removeWhere` to `getPeers()` so that a static-peer-backed entry immediately reappears as ManualIp (gray) rather than vanishing from the panel.
- `config_updated` also calls `getPeers()`: since adding or removing a static peer emits `config_updated`, the peers panel is refreshed in the same handler so changes are reflected immediately without a separate event.
- Macros panel layout constants: `_kMacroColumnWidth = 160.0` (per column); the `SizedBox` wrapping `MacrosPanel` in `home_screen.dart` is `width: _kMacroColumnWidth * _macrosColumns`, so the panel scales from 160 px (1 column) to 480 px (3 columns) and each button always gets a full 160 px — no overflow regardless of label length.
- `PatchTheme.headerHeight = 80.0`: single constant under `// ── Layout` in `patch_theme.dart`; applied as a fixed `Container(height: ...)` to all four top areas so their bottom dividers land on the same line.
- `bridge_client.dart::getConfig()` builds the config map manually from `ConfigSnapshot` fields. **Every new field added to `ConfigSnapshot` in Rust must also be added to this map.** Missing a field silently resets the Dart state variable to its `?? default` every time `getConfig()` fires.
- `macros_panel.dart` exports both `MacrosPanel` and `ChannelMacro`; `home_screen.dart` imports it with `show MacrosPanel, ChannelMacro`.
- Reliability is wired: `api::init` holds a shared `Arc<Mutex<ReliabilityManager>>`. `send_message` calls `reliability.track(...)` for `Priority::Critical` (targets come from `send_to_peers`, which returns the contacted `SocketAddr`s). Receivers ACK criticals in `transport::handle_event` (the `Message` arm encodes `/patch/ack` back to `from`), the `Ack` arm calls `reliability.ack(message_id, from)` — **acks are matched by the ACK packet's source `SocketAddr`, not the `peer_id` it carries**, because targets are addresses and a synthetic static-peer entry's `peer_id` is a derived UUID that wouldn't match the real sender (everyone binds/sends on the same OSC port, so the ACK's source addr == the target addr). A poller in `init` ticks every `reliability::POLL_INTERVAL_MS` (100ms); each in-flight entry retransmits on its own **exponential backoff** — `InFlight.ticks_until_retry` counts down and is reset to `2^retries` (2→4→8→16→32 ticks ≈ 200ms→3.2s) after each attempt — bounded by `MAX_RETRIES`. `drain_retransmits` (returns a `DrainResult { retransmits, failures }`) re-sends **only to targets that haven't ACKed yet** (a critical to 5 peers where 4 acked re-sends just to the 5th); a stray ACK from a non-target address is ignored so it can't trip early completion. `reliability/mod.rs` has unit tests covering the ack/retransmit/backoff/failure logic.
- **Critical-delivery status surfaced to the UI** (sender side only — only the sender tracks ACKs): `ack` returns `Some((delivered, total))` progress, emitted from the `Ack` arm as `AppEvent::MessageDelivery { message_id, delivered, total, failed:false, .. }`. When `drain_retransmits` reports a `failure` (entry exhausted `MAX_RETRIES`), the `init` poller emits a **failed** `MessageDelivery`, mapping the unacked `SocketAddr`s back to peer names via `api::resolve_peer_names` (`get_peers`). A critical sent with **no peers** online emits an immediate failure from `send_message` (it's never tracked, since `track` is gated on `!targets.is_empty()`). Dart side: `home_screen` keeps a `messageId → MessageDeliveryStatus` map, shows a per-row badge in `message_list.dart` (amber `N/M` → green ✓ `done_all` → red ⚠ `error_outline` with the failed peer names) and a red SnackBar on failure. `MessageAcked` is still emitted but unused by the UI.
- `send_to_peers` iterates `get_peers()` once (which already merges static peers as synthetic `ManualIp` entries) and dedups by `SocketAddr` — do **not** re-add a separate `config.static_peers` loop or static peers get every packet twice (flashes have no dedup, so they'd double-fire). Peer/static addresses are parsed as `IpAddr` then `SocketAddr::new(ip, port)` so IPv6 gets correct `[..]:port` form.
- Blocking file I/O is offloaded off the tokio runtime: `AppState::save_config(&self)` wraps `Config::save` in `spawn_blocking`. Config mutators just mutate under the write lock, drop the guard, then call `self.save_config().await`. `save_config` acquires a dedicated `Inner::save_lock` (`Mutex<()>`), **then** clones the *current* config and writes it — so concurrent fire-and-forget mutators (UI handlers don't await) can't reorder their whole-file writes and clobber each other; whichever write runs last persists the latest committed state. The `save_lock` is separate from the config `RwLock`, so it never blocks `config()` readers on the send path. **Do not** revert to passing a snapshot into `save_config` or saving directly under the config write lock — the former reintroduces the reorder race, the latter stalls OSC traffic during disk I/O. `api::init`'s `Config::load_or_default`, `export_messages`, `export_layout`, `import_layout`, `save_session`, and `load_session` are likewise `spawn_blocking`-wrapped. Plain (non-`async`) FRB fns like `list_sessions`/`delete_session` run on FRB's own pool, so they're left as direct `std::fs`.
- mDNS peers are classified correctly via `AppState::upsert_peer_with_mode(presence, DiscoveryMode::Mdns)` (the `ServiceResolved` handler); `upsert_peer` keeps the `OscBeacon` default, and an already-`Mdns` peer is never downgraded by a later OSC heartbeat, so the 🔍 icon stays.
- Inbound OSC is validated defensively in `osc/codec.rs`: `valid_channel_id` (the `[a-z0-9_-]`, ≤64 slug rule) gates both `decode_patch_message` and `decode_flash`, and payloads over `MAX_PAYLOAD_LEN` (4096) are rejected — malformed packets `bail!` and the receive loop drops them. `valid_channel_id` is `pub(crate)` and is the single source of truth for the slug rule: `api::upsert_channel` and `AppState::apply_session` (loaded/imported sessions) both call it, so a hand-edited/shared session file can't inject an OSC-unsafe channel id either — `apply_session` validates every id up front and rejects the whole session atomically (before clearing/persisting) if any is bad.
- `api::csv_escape` neutralises spreadsheet formula injection in `export_messages` (cells starting with `= + - @` tab/CR are prefixed with `'`) on top of RFC 4180 quote-doubling, because payload/sender/channel are network-sourced.
- `gethostname` (mDNS host record) is looked up in-process — `libc::gethostname` on Unix (declared under `[target.'cfg(unix)'.dependencies]`), `COMPUTERNAME` env on Windows — instead of forking the `hostname` binary.
- `main.dart` `_connect()` catches engine-boot failures and shows an error panel with **Retry**; `BridgeClient.connect` guards `RustLib.init()` with a static flag so a retry doesn't trip FRB's init-once throw. The `error` bridge event surfaces a red SnackBar in `home_screen.dart`; the Settings channel dialog (`_showChannelDialog`) validates the slug client-side before closing. (There is no separate quick-add `+` in the channel strip — channels are created/edited/deleted only in **Settings → Channels & Macros**, which is also where colour is set.)
- Per-channel message lists are capped at `_kMaxMessagesPerChannel` (500, mirrors `MAX_BUFFER`) in `home_screen.dart`'s `message` handler. Because of that cap, `message_list.dart` auto-scrolls on the **tail `messageId` changing**, not on list length — once the list is pinned at 500 the length stops changing, so a length-based trigger would silently stop following new messages. Don't revert it to a length comparison.
- Engine tests live in `osc/codec.rs`, `state/mod.rs`, `state/config.rs`, and `api.rs` (`#[cfg(test)]`, `#[tokio::test]` for the async state cases). `cargo test -p patch_core` runs them.
- Logging: `api::init_tracing()` installs a `tracing-subscriber` stderr `fmt` layer at the top of `init()` via `try_init()` (idempotent — safe across repeated `init()` and tests). Without it every engine `warn!/error!/debug!` is dropped. Control verbosity with `RUST_LOG` (default `info`); output shows under `flutter run`. The default filter adds **`mdns_sd=off`** — the `mdns-sd` crate (whose `log` records are captured via the `tracing-log` bridge) emits a per-interface "No route to host" ERROR for every tunnel/cellular/virtual NIC on each query (it multicasts out them all), which is dozens of benign lines per query on iOS-with-VPN; our own mDNS diagnostics come from `discovery::` and are unaffected. (Best-effort *broadcast* send failures in `transport::send_loop` are likewise logged at `debug`, not `error` — see the transport note above.)
- Graceful shutdown: `api::shutdown()` sends `/patch/bye` (peer_id) via `Transport::send_now` — a **direct** `socket.send_to` that bypasses the mpsc send queue, so the packet flushes before the process exits (a queued send may never drain). Receivers' `handle_event` `Bye` arm calls `mark_peer_offline` (backdates `last_seen` 60 s → dot goes **grey immediately**) — the peer **stays in the list** rather than vanishing, so the operator still sees who was connected; a reconnect greens it again. (mDNS `ServiceRemoved` does the same.) Full removal happens only via the manual "clear inactive peers" button (`clear_stale_peers`); `expire_peer` is retained as a utility with no current caller. Dart drives it from **`AppLifecycleListener.onExitRequested`** in `main.dart` — the framework *awaits* that callback before the app terminates (Cmd-Q / last-window-close on desktop), so the UDP send actually flushes; it's bounded by a 1 s timeout so a slow goodbye never hangs quit. `onDetach` (and `BridgeClient.dispose`) remain best-effort fallbacks. Do **not** rely on the `detached` lifecycle event alone — it's fire-and-forget and usually loses the race with process teardown on desktop. `api::shutdown` logs `Shutdown — broadcasting /patch/bye` and the receiver's `Bye` arm logs `Received /patch/bye …` (both `info`), so the round-trip is visible under `RUST_LOG=info`. `Bye` is intentionally excluded from the top-of-`handle_event` `touch_peer_address` block so it doesn't refresh `last_seen` right before expiring.
- Peer **role** (`Config.role`, surfaced via `ConfigSnapshot.role`): an optional self-assigned free-text label (no colour) set in **Settings → Identity** (`set_role`, empty → `None`). Broadcast as **OSC arg #4** of `/patch/presence` — appended last so it's backward-compatible: `decode_presence` keeps the `args.len() < 4` minimum and reads role only when `args.len() >= 5` (older 4-arg peers → `None`; empty string also → `None`). The heartbeat re-reads `cfg.role` each tick (like `client_name`), so a change propagates ≤1 interval. Authoritative per-peer (presence carries the current value); the auto-register (message/flash) and mDNS paths set `None` until a presence lands, but they only run for *new* peers (a known peer's role is never clobbered by a non-presence packet). Rendered as a neutral `_RoleBadge` in the peers panel.
- **Channel sharing over the network** (`/patch/channels/request` + `/patch/channels/announce`): "Import channels from a peer" in **Settings → Channels & Macros** → `api::request_channels(peer_id)` resolves the peer's `SocketAddr` and unicasts a request; the peer's `handle_event` `ChannelsRequest` arm replies with its current channels serialized as JSON (`encode_channels_announce`, unicast back to `from`). The requester's `ChannelsAnnounce` arm parses the JSON to `Vec<Channel>` (caps `MAX_OFFERED_CHANNELS = 64`; the codec also caps the JSON at `MAX_CHANNELS_JSON = 64 KiB`), then emits `AppEvent::ChannelsOffered { from_peer_id, from_name, channels }` — **never auto-applied**. The UI previews (new vs. already-have) and calls `api::adopt_channels(channels)` → `AppState::merge_channels`, which **adds only ids not already present** (validates each via `valid_channel_id`, skips the reserved `__all__`, never overwrites/deletes), persists, and returns the count added. **Structure-only adopt:** a merged channel keeps id/display name/colour/macros but its per-channel flash flags are reset to *this* machine's defaults (`config.flash_on_critical`/`flash_on_message`, `flash_count = None`) — mirroring `api::upsert_channel` — so an imported layout can't silently impose the source peer's "flash on every message" (a per-channel preference, not part of the shared structure). The codec stays decoupled: `ChannelsAnnounce` carries the raw `channels_json` string (no `state::channel` dependency in `osc/`); the transport/state layer serialises + parses. Settings gates the offer dialog behind an `_awaitingOffer` flag (cleared after 6 s) so an unsolicited announce can't pop a dialog. Makes the peer channel dots gain consistent colour across machines.
- **MIDI input** (`patch-core/src/midi/mod.rs`, `crate::midi::start` called from `api::init`): desktop-only via `midir` (declared under `[target.'cfg(any(macos, windows, linux))'.dependencies]`; the module has a `#[cfg(...)]` real `backend` and a `#[cfg(not(...))]` no-op `backend`, so iOS/Android build with **no** midir dep). Opens **every** input port at startup; the OS callback parses Note On (vel > 0) / CC (value ≥ 64) and forwards a `MidiTrigger` over a tokio `unbounded_channel` to a task that fires **every per-channel macro whose `midi_note`/`midi_cc` matches, each on its own channel**. The `MidiInputConnection`s are kept alive for the process lifetime by a dedicated parked `std::thread` (dropping a connection closes its callback — same pattern as the mDNS daemon handle), so nothing is stored on `EngineHandle`. Firing goes through `api::dispatch_message` — the send path **extracted** from `send_message` (takes `&AppState`, `&Arc<Transport>`, `&Arc<Mutex<ReliabilityManager>>`) so MIDI-fired criticals are ACK-tracked and the local flash/alert fires exactly like a hand-sent message. MIDI is **absolute/engine-side** (fires regardless of UI selection or focus) — deliberately different from F-keys (`home_screen._handleHardwareKey`, selected-channel, Flutter-side). CC fires on ≥ 64 with no edge-tracking, so a momentary footswitch (127→0) fires once; an expression pedal would spam (don't bind one). Ports are enumerated once at startup — hot-plug needs a restart (rescan is a possible follow-up). `api::get_midi_ports()` exposes the port names for a future selector UI (no UI yet). CI installs `libasound2-dev` (the ALSA `-sys` headers) for the Linux build.

---

## Known Incomplete

See [TODO.md](TODO.md) for the full list of known issues and pending work.

---

## Reliability Model

Patch assumes:
- Packet loss can occur
- Networks can be segmented
- Devices may appear/disappear dynamically

To compensate:
- All messages carry a UUID `message_id` for dedup and ACK
- Message dedup is enforced in `store_message` — O(1) via a `HashSet<Uuid>` companion to the `VecDeque` buffer; the same `message_id` is never stored twice
- Critical messages (`priority=3`) require ACKs: the sender registers them with `ReliabilityManager`, receivers emit `/patch/ack` on receipt, and a poller in `api::init` retransmits unacked criticals to their original targets until acked or `MAX_RETRIES` (5) is exceeded
- Retransmit uses **per-message exponential backoff** (`InFlight.ticks_until_retry`, reset to `2^retries` ticks of `POLL_INTERVAL_MS` after each attempt — ≈200ms→3.2s), bounded by `MAX_RETRIES`, so a lossy link isn't hammered while the first retransmit still fires within ~one tick
- Client maintains a 500-message local buffer per session (mirrored on the Dart side — `_kMaxMessagesPerChannel` in `home_screen.dart`)

---

## UI Principles

Patch UI is designed for live environments:

- dark mode always
- high contrast typography — readable at 2m from a stage desk
- large `HH:MM:SS` timestamps on every message
- channel color-coded throughout
- critical messages visually distinct (red left border + background tint)
- **critical-delivery indicator**: on the sender's own critical rows, a trailing badge shows delivery — amber `N/M` while being delivered/retried, green ✓ when every peer has ACKed, red ⚠ (tooltip names the peer(s), or "no peers online") if it failed; a red SnackBar also fires on failure. Driven by the `MessageDelivery` event; receivers see no badge (only the sender tracks ACKs)
- keyboard-first on desktop (Enter to send, F1–F12 fire bound macros from any focus state)
- touch-first on iPad
- **multi-channel view**: tap any channel tab to toggle it in/out of the selection; at least one channel always remains selected; combined feed sorted by timestamp; channel colour dot on each message row
- **ALL channel (crew-wide broadcast)**: a pinned **ALL** tab at the top of the channel strip (reuses `ChannelTab` with a synthetic accent channel, id `kAllChannelId = '__all__'`, defined in `models/message.dart`). It's an **exclusive** selection — tapping ALL sets `_selectedIds = {'__all__'}`; tapping a normal channel exits ALL mode (`_toggleChannel`). Sending in ALL mode emits **one** message on `__all__` (`send_message('__all__', …)` — no new OSC address, no FRB regen); because a channel id is just a routing label (every peer receives every packet) and the UI shows `__all__` messages in **every** feed, it reaches every peer regardless of their channels, *including channels the sender doesn't have*. Read side: ALL mode merges all `_messages` keys; normal mode folds `_messages['__all__']` into each channel feed so a broadcast shows wherever you're looking. Broadcast rows render a 📢 marker (`message_list.dart`), the input shows a broadcast hint, and `_triggerBroadcastFlash` pulses the ALL tab + message area in accent. Delivery badge / critical retransmit / global macros work unchanged (a broadcast critical is just a critical). The engine reserves `__all__` (`api::upsert_channel` rejects it). Two gotchas handled: the channel-reload stale-id prune keeps `__all__` (else a reload kicks you out of ALL mode), and `_fireMacro`/header/send/clear/export all special-case ALL since `selectedChannels` is empty in that mode.
- **flash**: channel tab pulses N× scale animation (default 4, configurable 3–7); message box border + background tint pulses N× in the channel colour (`_FlashLayer` inside `_ChannelView` Stack, receives `pulseCount`); triggers determined by OR of global + per-channel flags
- **NIC picker**: Settings → Network Interface; dropdown shows only real NICs (loopback, virtual/tunnel, and link-local IPv6 interfaces filtered out). Patch **always listens on all interfaces** (`0.0.0.0`); the picker only chooses which network the discovery beacon is **announced** on. Change persists to `patch.toml` and applies **within a few seconds — no restart** (shows an "Applied" confirmation, not a restart banner)
- **Behavior settings**: Settings → Behavior — global flash defaults ("Flash on every message", "Flash on critical messages", "Flash pulses" 3–7 picker), **"Audible alert"** toggle; Settings → channel editor footer — per-channel overrides for the same flash flags (either global or channel flag being on is sufficient to trigger; "–" in the pulse picker = use global)
- **audible alert**: when `audible_alert` (config, default off — opt-in) is set, `_playAlert()` plays the bundled `assets/sounds/alert.wav` via **`audioplayers`** (a single reusable `AudioPlayer` on `_HomeScreenState`, disposed in `dispose`; **preloaded in `initState` via `setSource` + `ReleaseMode.stop`** and replayed with `seek(0)`+`resume` in `_emitAlert`, so even the first alert after launch is instant — a fresh `play` is only the fallback), called from inside `_triggerFlash`/`_triggerBroadcastFlash` — so it fires on exactly the same events as the visual flash (critical message / page / broadcast, per the flash flags), even on a channel you're not viewing. Bypassable via Settings → Behavior → "Audible alert". **`SystemSound.play(SystemSoundType.alert)` was tried first but is a no-op on macOS *and* iOS** — hence the bundled asset (a short two-tone WAV generated with a Python script; regenerate by editing the asset). `audioplayers` is in `pubspec.yaml` deps; the asset is declared under `flutter: assets:`
- **reset to defaults**: each Settings section has a `↺` icon button that shows a confirm dialog then restores factory defaults for that section only — Identity resets name to system username (`Platform.environment['USER']`); Behavior resets flash flags to `flash_on_critical=true / flash_on_message=false / flash_count=4`; Static Peers removes all entries; Channels & Macros calls `reset_channels()` which replaces all channels with the seeded defaults. `reset_channels()` in `state/mod.rs` delegates to `apply_session(default_channels())` and emits `ChannelListUpdated`. `state/config.rs::default_channels()` is `pub` so it can be called from `mod.rs`.
- **sessions**: folder icon in the left sidebar opens `SessionsDialog` — load/save named presets or import/export `.toml` files; Settings screen no longer contains a Sessions section
- **macros panel**: `macros_panel.dart` — toggleable via keyboard icon (`Icons.keyboard_outlined`) in `_ChannelView` header (button moves into the panel's own header when panel is open, aligned above its column); vertical layout, all macros always visible, no scroll; 1, 2, or 3 columns (`_kMacroColumnWidth = 160.0` per column, so panel is 160/320/480 px); column count set in **Settings → Behavior → Macros panel columns** (SegmentedButton 1/2/3), persisted to `patch.toml` as `macros_columns`; multi-channel mode groups macros by channel with a colored divider; when single channel, no channel bar on buttons; `Material(clipBehavior: Clip.hardEdge)` prevents overflow errors when many macros are squeezed into a small window; `ConstrainedBox(minHeight: 40)` sets a floor on row height
- **header alignment**: `PatchTheme.headerHeight = 80.0` is applied to all four top-section headers (channel strip image, `_ChannelView` header container, `MacrosPanel` header, `PeersPanel` header) so their dividers land on the same horizontal line
- **peers panel**: 160 px wide (`_kPeersPanelWidth`); header is "PEERS" (not "ONLINE"); 3-state dot — green ≤ 2× heartbeat, amber ≤ 5× (heartbeat missed / going quiet), gray beyond or ManualIp (configured-only); thresholds derive from `heartbeat_interval_secs` (default 7 s → 14 s / 35 s); each row shows a per-peer "last seen" subtitle ("now" / "30s ago" / "3m ago" …) for dynamic peers, or the address for ManualIp; each row also shows **channel-membership dots** (one per channel the peer announces in `PeerInfo.channels`, coloured from the viewer's own channel map — grey for a channel the viewer lacks — capped at 5 then "+N"; `home_screen` passes `PeersPanel.channelColors`) and, when set, a **neutral role chip** (`_RoleBadge`, plain text, no colour) after the name; peers persist for the full session and never auto-expire; static peers always appear even before first contact (gray dot with 📌 icon); `PeersPanel` is a `StatefulWidget` with a `Timer.periodic(3s)` that calls `setState` to keep dot colours and the relative-time counter current without waiting for an external event; `person_remove_outlined` button in the panel header calls `onClearStale` → `clearStalePeers(maxAgeSecs: 60)` — removes OscBeacon/Mdns peers not heard from in 60 s; ManualIp/static peers are never removed; `PeerExpired` is emitted per removed peer so the panel refreshes automatically
- **clear messages**: `delete_sweep_outlined` icon button positioned at top-right of the message area (`Stack` + `Positioned`) — always visible regardless of which side panels are open. Shows a confirm dialog scoped to the selected channel(s). Clears Rust buffer via `clear_messages(channel_id)` and updates the local `_messages` map via the `messages_cleared` bridge event. The button is intentionally in the message frame, not the header toolbar, to separate it from the macros/peers panel toggles.
- **export messages**: `download_outlined` icon button at top-right of the message area (at `right: 40`, left of the clear button). Opens `FilePicker.saveFile` pre-named `patch_<channel>.csv`. Calls `export_messages(channel_id, path)` in `api.rs` which writes RFC 4180 CSV. Single-channel export: columns are `timestamp, sender, priority, message`. Multi-channel (all selected channels → `channel_id = None`): columns are `timestamp, channel, sender, priority, message`. Double-quotes in payload/sender are escaped by doubling (RFC 4180).
- **iPhone layout**: dialog `AlertDialog` content uses `SizedBox(width: double.infinity)` — never a hardcoded pixel width. The `AlertDialog` widget constrains its content to `screenWidth - margins` automatically; fixed widths (360–380 px) exceeded iPhone SE's available space and caused right-overflow errors. The channel-name `Text` in the `_ChannelView` header is wrapped in `Expanded` with `overflow: TextOverflow.ellipsis`; the `Spacer` lives only in the multi-channel branch so buttons always sit at the right edge of the header (`Flexible` was previously used but split remaining space 50/50 with the `Spacer`, pushing buttons toward center). Key `Text` nodes in tight layouts (`channel_tab.dart`, `peers_panel.dart` IP line) carry `overflow: TextOverflow.ellipsis` to truncate gracefully instead of clipping silently.

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

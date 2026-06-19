# ARCHITECTURE.md

## Project Structure

```
patch/
├── patch-core/src/
│   ├── api.rs              # Public FFI surface — scanned by FRB codegen
│   ├── osc/codec.rs        # All OSC encode/decode → PatchEvent enum
│   ├── osc/addresses.rs    # Canonical /patch/* OSC address constants
│   ├── transport/mod.rs    # UDP socket, unicast send_to_peers, broadcast
│   ├── discovery/mod.rs    # mDNS + heartbeat loop
│   ├── midi/mod.rs         # MIDI input (desktop only)
│   ├── reliability/mod.rs  # ACK tracking, exponential-backoff retransmit
│   └── state/              # AppState, Config, Channel, Peer, ShowFile
└── patch_app/lib/
    ├── bridge/bridge_client.dart  # Façade over FRB bindings
    ├── screens/home_screen.dart   # Main UI
    ├── screens/settings_screen.dart
    └── widgets/                   # channel_tab, flash_button, message_list,
                                   # macros_panel, peers_panel, show_files_dialog
```

Generated Dart bindings live in `patch_app/lib/src/rust/` — excluded from analysis, never hand-edited.

## FFI Bridge

`api.rs` is the public Rust surface. `flutter_rust_bridge_codegen generate` (from repo root) rewrites `frb_generated.rs` and `patch_app/lib/src/rust/*`. After regenerating, run `dart run build_runner build` in `patch_app/` if any `freezed` type changed.

`BridgeClient` (`bridge/bridge_client.dart`) wraps the generated bindings:
1. Calls `RustLib.init()` then `api.init()` once on startup.
2. Subscribes to `api.subscribeEvents()`, forwards typed `PatchAppEvent` into a legacy `Stream<Map<String, dynamic>>` the screens consume.
3. Wraps command functions to emit response events (e.g. `getChannels()` → `{event: 'channels', data: […]}`).

`subscribe_events` is `async` so FRB calls it inside its Tokio runtime — the `tokio::spawn` inside requires that ambient runtime. The `rust-async` FRB feature enables this; without it `tokio::spawn` panics with "there is no reactor running".

## OSC Namespace

```
/patch/channel/{id}/message     channel message (unicast to peers)
/patch/channel/{id}/flash       flash/page (unicast + local publish)
/patch/channel/{id}/say         external OSC injection; receiver originates + relays
/patch/presence                 heartbeat/discovery (broadcast + unicast to known peers)
/patch/bye                      graceful departure
/patch/ack                      ACK for critical message_id
/patch/dm                       direct 1:1 message (unicast, target_id in args)
/patch/dm/flash                 direct attention ping (unicast)
/patch/channels/request         ask a peer for its channel layout
/patch/channels/announce        reply with layout JSON
```

`/patch/presence` is the only discovery+heartbeat address. An external OSC tool announces itself by sending one — the receiver registers it as a peer. Messages and flash are **not** broadcast — silently dropped if no peers are known yet.

## Discovery & Broadcast

The socket always binds `0.0.0.0` so it receives on all interfaces including broadcasts. `network_interface` only scopes which NIC the discovery beacon is *announced* on. Changing it is live: the heartbeat picks it up on the next tick, and `set_network_interface` immediately clears all dynamically-discovered peers (OscBeacon/Mdns) so the peer list rebuilds cleanly via the new NIC's discovery. ManualIp/static peers are kept.

Presence heartbeats go to:
- `255.255.255.255` — load-bearing on macOS (the only broadcast address macOS delivers to apps)
- Each usable IPv4 NIC's subnet-directed broadcast (helps Linux/Windows routing)
- macOS only: `255.255.255.255` pushed out every usable interface via `IP_BOUND_IF` (`broadcast_per_interface`) to reach peers on non-default-route NICs
- Unicast to every known peer (bootstraps two-way discovery through asymmetric routes/AP isolation)

Peers never auto-expire. Liveness dot is Flutter-side from `last_seen`: green ≤ 2× heartbeat, amber ≤ 5×, gray beyond. `/patch/bye` and mDNS `ServiceRemoved` call `mark_peer_offline` (grey, kept in list) — not removal. Manual removal only via `clear_stale_peers`.

**mDNS liveness rule:** `ServiceResolved` goes through `resolve_peer_address` (not `touch_peer_address`) — it sets address+port but never updates `last_seen`. New mDNS-only peers are inserted already-stale (backdated 60 s). Reason: `mdns-sd` replays cached resolutions for ~1–2 min after a peer quits, so bumping `last_seen` there kept departed peers green past the heartbeat window and undid `/patch/bye` expiry.

Self-discovery is filtered in two places: mDNS `ServiceResolved` checks `peer_id == client_id`; `handle_event` Presence arm does the same. Both guards are necessary (see ERRORS.md).

`peer_updated` events are debounced (~800 ms trailing edge) in Flutter before calling `getPeers()` because `touch_peer_address` fires on every received OSC packet. `PeerPresence` carries no address — never update the peer list directly from it.

Heartbeat re-reads `client_name` and `role` from config on every tick, so renames propagate to peers within one interval without restart.

Static peers always appear in the peers panel: `get_peers()` merges `config.static_peers` as synthetic `ManualIp` entries. A synthetic entry disappears once a real packet arrives and creates a dynamic entry for the same address.

## Show Files

`apply_show_file_full` (load/import) replaces channels **and** static peers. `apply_show_file` (reset_channels) replaces channels only — factory reset never wipes configured peers. Channel IDs are validated atomically upfront; the whole show file is rejected if any ID is invalid.

Show files panel opened from the folder icon in the channel strip (not Settings).

## Direct Messages

DMs use a dedicated `/patch/dm` packet — not a channel message (`dm:` prefixed IDs fail `valid_channel_id`). Thread keying: sender stores under `dm:{target_id}`; receiver stores under `dm:{sender_id}`. Each side keys the thread by the other peer. The `dm:` prefix never goes on the wire.

DMs are excluded from the ALL feed and `set_selected_channels`. Non-critical DMs produce a silent unread dot on the peer row; critical DMs call `_triggerDmFlash`. Firing a macro in DM mode sends its text as a DM. No ACK/retransmit for DMs (best-effort).

**DM navigation lives in the peers panel, not the channel strip.** Tapping a peer row opens their DM thread in the main message area. DM tabs never appear in the channel strip. Threads persist while the app is open — tapping a channel exits the DM view but the thread remains accessible by tapping the peer row again. Unread state is tracked per-peer and shown as a dot on the peer row; when the peers panel is closed, the peers toggle button in the header carries a badge instead. DMs are only available for real (dynamic) peers, not synthetic `ManualIp` entries.

## MIDI

Desktop-only via `midir` (`#[cfg(any(target_os = "macos", ...))]`; no-op backend on iOS/Android). Opens all physical input ports + a virtual "Patch" port on macOS/Linux. Note On (vel > 0) and CC (≥ 64) trigger macros. Routing via pure `resolve_targets`: per-channel macros fire on their own channel (absolute, engine-side); global macros fire on currently-selected channels (Flutter pushes selection via `set_selected_channels`). `MidiInputConnection`s kept alive by a parked `std::thread` (dropping one closes its callback).

macOS requires CoreMIDI + CoreAudio frameworks explicitly in `patch_app/rust_builder/macos/patch_core.podspec` `OTHER_LDFLAGS` — cargokit's static `.a` doesn't carry `cargo:rustc-link-lib` directives. Run `pod install` after editing the podspec.

## Reliability (Critical Messages)

Critical (`priority=3`) messages are tracked by `ReliabilityManager`. Receivers ACK via `/patch/ack`. A 100ms poller retransmits unacked messages per-target with exponential backoff (2^retries ticks × 100ms, up to `MAX_RETRIES = 5`). ACKs are matched by source `SocketAddr`, not `peer_id`. Delivery progress emitted as `MessageDelivery` events to Flutter (amber N/M → green ✓ → red ⚠).

`dispatch_message` (`api.rs`) skips ACK-tracking for any target that `Peer::looks_offline` (`state/peer.rs`) flags — a clean departure, or quiet for 5x the heartbeat interval (the same "grey dot" threshold the peers panel and DM-offline warning use). The best-effort send itself still goes to every contacted peer regardless; only the pointless retransmit/failure-warning cycle against a peer already known to be gone is skipped. `ManualIp` (static) peers are exempt from the staleness half of this check — they never heartbeat, so silence doesn't mean anything for them.

`send_to_peers` deduplicates by `SocketAddr`. Static peers are already merged in via `get_peers()` — never add a separate `config.static_peers` loop.

## Config I/O

`save_config` wraps `Config::save` in `spawn_blocking`. A dedicated `save_lock` (`Mutex<()>`) serialises concurrent whole-file writes — acquired after cloning the current config, so the config `RwLock` is not held during disk I/O. All `std::fs` operations in async paths are `spawn_blocking`-wrapped.

## ALL Mode (Broadcast)

ALL is a one-shot broadcast action, not a persistent channel selection. Tapping the ALL button in the channel strip enters a temporary broadcast compose state — the message area header signals this. Sending a message (or flash) immediately snaps back to whatever channel(s) were selected before ALL was tapped. Tapping any channel tab cancels without sending. ALL never stays selected after a send.

## Peers Panel

The peers panel (`peers_panel.dart`) shows one tile per peer: name, role badge, status dot (green/amber/gray by heartbeat age), an IP:port subtitle, and a "Clear inactive" footer button. Discovery icon and channel dots are intentionally omitted — they're diagnostic details that add clutter without operational value during a show. The IP:port subtitle stays, despite being a diagnostic, because multi-NIC setups (e.g. a wired control/Dante network alongside Wi-Fi) can silently resolve a peer to the wrong interface — seeing the address at a glance is the fastest way to catch that during setup. The panel is the hub for DM navigation (see Direct Messages above).

## UI Layout Constants

- `PatchTheme.headerHeight = 48.0` — applied to all top-area headers (channel strip, message area, peers panel, macros panel) so their top dividers align across columns
- `PatchTheme.footerHeight = headerHeight` — applied to the bottom-of-screen row in each column (channel strip's identity chip, message area's `MessageInput`, peers panel's "Clear inactive" button) so the footer dividers align too, and match the header height
- Every column boundary in the main `Row` (channel strip ↔ peers panel ↔ message area ↔ macros panel) carries the same `Border(left: BorderSide(color: PatchTheme.border))`, applied independently at each boundary so the separator is present regardless of which optional panels (peers/macros) are currently shown
- `_kMacroColumnWidth = 160.0` — macros panel width = `160 × columns` (1–3 columns → 160–480 px)
- `_kPeersPanelWidth = 160.0` — peers panel, sits left of message area
- Message buffer cap: 500 per channel (`_kMaxMessagesPerChannel`, mirrors `MAX_BUFFER`)
- `message_list.dart` auto-scrolls on tail `messageId` changing, not list length (at cap, length stops changing)
- `HomeScreen`'s `Scaffold.body` is wrapped in `SafeArea` — the custom headers/footers are plain `Container`s, not a real `AppBar`, so nothing else insets them from the iOS status bar/notch or bottom home indicator
- The Settings screen's `AppBar` sets `toolbarHeight: PatchTheme.headerHeight` to match the main window's header height instead of Material's default `56.0`

## Channels & Macros

Channel IDs are slugs (`[a-z0-9_-]`, ≤64 chars) — `valid_channel_id` in `codec.rs` is the single source of truth. `__all__` is reserved. Default channels ship macro-less; common callouts are seeded as global macros shown on every channel. Global macros fire on currently-selected channel(s); per-channel macros take F-key precedence over a global on the same key. `macros_panel.dart` exports both `MacrosPanel` and `ChannelMacro`.

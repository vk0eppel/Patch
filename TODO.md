# Patch — TODO / Known Issues

Items are ordered by priority. File paths are relative to the repo root.
Effort: **trivial** < **small** < **medium** < **large**.

---

## 🟢 Peer presence & activity precision

Goal: the user should see *who's online and when*, with good precision, without a rewrite.
**Current model (sound, keep it):** presence broadcast every 7s (`discovery/mod.rs`); `last_seen`
refreshed on **every** received packet (`state/mod.rs::touch_peer_address`); the Flutter dot is green
when `last_seen ≤ 35s`, gray otherwise (`peers_panel.dart`); peers never auto-expire; the panel
re-renders on a 10s `Timer`. The gap is that the UI only shows a binary dot — not *when* a peer was
last heard. Items below are additive and low-risk; ordered by priority.

### [High] Show a per-peer "last seen" relative time
**File:** `patch_app/lib/widgets/peers_panel.dart` (`_PeerTile`) · **Effort:** small
The data already exists (`peer.lastSeen`). Add a relative-time line ("now" / "12 s ago" / "3 m ago")
under each peer so the panel answers *when*, not just online/offline. Tighten the existing
`Timer.periodic` from 10 s → ~3 s so the counter feels live (cheap — just `setState`). This is the
single highest-value, lowest-risk win for the stated goal; pure additive UI, no engine change.

### [Med] Throttle `PeerUpdated` / `getPeers()` churn
**Files:** `patch-core/src/state/mod.rs` (`touch_peer_address`), `patch_app/lib/screens/home_screen.dart`
**Effort:** small
`touch_peer_address` emits `PeerUpdated` on *every* received packet, and `home_screen` answers each
with a full `getPeers()` FFI round-trip — so a busy channel triggers one peer-list fetch per message.
Precision doesn't need that: throttle the emit to ≤1/s per peer (the registry still updates
`last_seen`; the panel timer recomputes the dot), or debounce `getPeers()` on the Dart side. Cuts
event/FFI spam and broadcast-bus lag (the `256`-slot bus can log "lagged") with no loss of precision.

### [Med] Act on mDNS `ServiceRemoved`
**File:** `patch-core/src/discovery/mod.rs` (`ServiceRemoved` arm — currently debug-log only)
**Effort:** small
When a peer cleanly leaves, mDNS reports it immediately. Map `fullname` → peer and mark it offline now
(age `last_seen` + emit `PeerUpdated`, or `PeerExpired`) instead of waiting out the 35 s window.
Improves *offline* precision on graceful exits. (Won't help unicast-only / AP-isolated peers that never
reached us via mDNS — those still rely on the heartbeat timeout.)

### [Low] Derive the online threshold from the heartbeat (or tighten it)
**Files:** `patch_app/lib/widgets/peers_panel.dart` (hardcoded `35`), `state/config.rs` · **Effort:** trivial
35 s = 5× the 7 s heartbeat — conservative (avoids Wi-Fi flapping) but slow to show offline. Consider
~21 s (3 missed) for faster detection, and/or derive it from `heartbeat_interval_secs` (already in
`ConfigSnapshot`) instead of a magic `35` so it tracks the interval if it ever changes.

### [Low] Active liveness probe for static / manual peers
**Files:** `patch-core/src/discovery/mod.rs`, `transport/mod.rs` · **Effort:** medium
Static peers always show gray — their `last_seen` is synthetic (`get_peers` sets it to `now()`); we
never actually hear from them unless they initiate. A light periodic unicast presence ping to each
configured static peer would give them a real online state + real "last seen". Optional (adds a little
traffic); gate it on the static-peer list so it only pings known addresses.

## 🟢 General optimizations (low priority)

### `get_peers()` allocates per call
**File:** `patch-core/src/state/mod.rs` — `get_peers()`
Builds a `HashSet` of known addresses and clones `static_peers` on every call; invoked per send and per
peer event. Minor, and largely mooted once the peer-event churn above is throttled.

### `_combinedMessages` re-sorts every build
**File:** `patch_app/lib/screens/home_screen.dart`
The getter merges + sorts all selected channels' messages (up to 500 each) on every `setState`. Memoize
per (selection, total count) if profiling shows jank on busy multi-channel views.

---

## ~~🔴 Critical — Runtime Panics~~ ✅ Fixed

### ~~OSC codec decoders missing bounds checks~~ ✅ Done
**File:** `patch-core/src/osc/codec.rs`

All five decoders now have `bail!` guards matching the pattern in `decode_patch_message`.
Malformed or truncated OSC packets are logged and discarded instead of panicking.

---

## 🟠 Major — Incomplete Features

### ~~[High] No tracing subscriber — all engine logs are dropped~~ ✅ Done
**Files:** `patch-core/Cargo.toml`, `patch-core/src/api.rs`

Added `tracing-subscriber` (with `env-filter`). `api::init_tracing()` runs at the top of `init()`
and installs a stderr `fmt` subscriber via `try_init()` (no-op if already set — safe for repeated
`init()`/tests). Level is controlled by `RUST_LOG` (defaults to `info`); logs surface under
`flutter run`. Forwarding to a Dart log stream is a possible future nicety but not required.

### ~~Wire ReliabilityManager into the send path for critical messages~~ ✅ Done
**Files:** `patch-core/src/reliability/mod.rs`, `patch-core/src/api.rs`, `patch-core/src/transport/mod.rs`

`ReliabilityManager` is now instantiated in `api::init` (shared `Arc<Mutex<…>>`).
`send_message` calls `reliability.track(message_id, bytes, targets)` for `Priority::Critical`
messages (targets come from `send_to_peers`, which now returns the contacted `SocketAddr`s).
A retransmit poller spawned in `init` drains `drain_retransmits()` every 400 ms and re-sends.
Receivers emit an ACK for every critical message (`handle_event` `Message` arm), and the
`PatchEvent::Ack` arm calls `reliability.ack(message_id, peer_id)` to clear the in-flight entry.

Note: retransmit currently uses a fixed 400 ms tick (bounded by `MAX_RETRIES`) rather than the
`retransmit_delay` exponential-backoff helper, which is still unused.

### Multicast transport option
**Files:** `patch-core/src/transport/mod.rs`, `patch-core/src/discovery/mod.rs`, `patch-core/src/state/config.rs`
**Effort:** large

Currently Patch uses UDP broadcast for presence/discovery (LAN-only, blocked by routers)
and UDP unicast to known peers for messages. Multicast would allow group delivery that
can be routed across VLANs on networks that support multicast routing.

Scope is TBD — options include:
- Multicast for presence/discovery only (replace 255.255.255.255 broadcast with a multicast group, e.g. `239.0.0.1:9000`), keeping unicast for messages
- Multicast for messages too (all receivers in the group get every message, no per-peer send loop)
- A config toggle so users can opt in on complex show networks (VLAN-segmented, multi-subnet)

Considerations: multicast requires `IP_ADD_MEMBERSHIP` socket option; iOS/macOS sandbox may require additional entitlements; many consumer APs still block multicast.

### ~~mDNS init panics instead of gracefully degrading~~ ✅ Done
**File:** `patch-core/src/discovery/mod.rs`

mDNS setup is now wrapped in an async `Result` block. On failure a `warn!` is logged
and the engine continues with OSC beacon + static peer discovery only.

### ~~Surface iOS/macOS Local Network permission-denied to the UI~~ ✅ Done
**Files:** `patch-core/src/transport/mod.rs`, `patch-core/src/api.rs`, `patch_app/lib/bridge/bridge_client.dart`, `patch_app/lib/screens/home_screen.dart`

`AppEvent::PermissionDenied` / `PatchAppEvent::PermissionDenied` added. Detected in
`receive_loop` via `ErrorKind::PermissionDenied`. Shows a red `SnackBar` in Flutter.

---

## 🟡 Medium — Validation & Silent Failures

### [Med] No CI pipeline
**Files:** `.github/workflows/` (new)
**Effort:** small–medium

No CI exists. Add a GitHub Actions workflow running `cargo test -p patch_core`,
`cargo clippy -- -D warnings`, `cargo fmt --check`, and `flutter analyze`. The engine has 25 tests
and analyze is clean — CI locks that in against regressions.

### [Med] Broken default Dart test + no Dart unit coverage
**Files:** `patch_app/test/widget_test.dart`, `patch_app/lib/bridge/bridge_client.dart`, `patch_app/lib/models/message.dart`
**Effort:** small

`widget_test.dart` is still the Flutter counter template — it imports `MyApp` (the real root is
`PatchApp`) and asserts a counter, so `flutter test` fails to compile. Replace it, and add unit
tests for the pure, high-value logic that's currently untested: bridge conversions
(`_messageToMap` priority `.index` mapping, `_peerToMap` discovery-mode strings, `_presenceToPeerMap`)
and model `fromJson` (`PatchMessage` / `PeerInfo` / `SessionMeta`). No engine/FFI needed.

### ~~Channel ID not validated for OSC path safety~~ ✅ Done
**File:** `patch-core/src/api.rs` — `upsert_channel()`

`upsert_channel` now rejects any `id` containing characters outside `[a-z0-9_-]`
or an empty string, returning a descriptive error to the caller.

### ~~Static peer address not validated before storing~~ ✅ Done
**File:** `patch-core/src/state/mod.rs` — `add_static_peer()`

`add_static_peer` now parses the address with `std::net::IpAddr`, rejects port 0,
and rejects duplicate `address:port` pairs.

### ~~`send_to_peers()` always returns `Ok(())` even when all sends failed~~ ✅ Done
**File:** `patch-core/src/transport/mod.rs`

When `sent == 0` and there were known targets, a `warn!` is now emitted so the
failure is visible in logs. The return is still `Ok(())` so the local message store
is not affected.

### ~~`sessions_dialog.dart` — `.single` throws on empty file picker result~~ ✅ Done
**File:** `patch_app/lib/widgets/sessions_dialog.dart`

Fixed: `result.files.single` → `result.files.isEmpty` guard + `result.files.first`.

---

## 🟢 Low — Code Quality & Performance

### [Low] No rustfmt/clippy config; clippy never run
**Files:** `rustfmt.toml` / `clippy.toml` (new), CI
**Effort:** small

No formatter/linter config. ~25 non-test `.unwrap()` in the engine (mostly lock guards — audit for
poison-panic risk, e.g. the `DATA_DIR_OVERRIDE` / `save_lock` paths). Add a clippy pass (wire into
CI) and a minimal `rustfmt.toml`. Also clears the pre-existing `unnecessary_underscores` info-lint
in `flash_button.dart`.

### ~~[Low] No "goodbye" on shutdown — peers linger until timeout~~ ✅ Done
**Files:** `osc/{addresses,codec}.rs`, `transport/mod.rs`, `api.rs`, `bridge_client.dart`, `main.dart`

New `/patch/bye` packet (carries `peer_id`). `api::shutdown()` sends it directly on the socket
(`Transport::send_now`, bypassing the queue so it flushes before exit) to every resolved/static peer
plus a LAN broadcast. Receivers' `handle_event` `Bye` arm calls `expire_peer` → `PeerExpired` → the
UI drops them immediately instead of waiting out the 35 s window. Dart calls `shutdown()` from
`BridgeClient.dispose()` and on `AppLifecycleState.detached`. Explicit mDNS unregister was left out
(the daemon thread dies with the process; the `/patch/bye` broadcast is the prompt signal).

### [Low] `patch.toml` has no schema version
**File:** `patch-core/src/state/config.rs`
**Effort:** trivial

Migrations rely entirely on `#[serde(default)]`. A `config_version` field would enable explicit,
ordered migrations if a field ever needs renaming/removing (the recent `shortcuts`→`macros` churn
is a good example of why).

### [Low] Reliability retransmit doesn't use exponential backoff
**Files:** `patch-core/src/api.rs`, `patch-core/src/reliability/mod.rs`
**Effort:** small

The poller in `api::init` retransmits on a fixed ~400 ms tick; the `retransmit_delay`
(100→200→400…) helper in `reliability/mod.rs` exists but is unused. Track a per-message next-retry
instant and honour the backoff curve so a lossy link isn't hammered.

### ~~Message ring buffer: O(n) dedup scan + O(n) front removal~~ ✅ Done
**File:** `patch-core/src/state/mod.rs` — `store_message()`

The buffer is now a `MessageBuffer { queue: VecDeque<PatchMessage>, seen: HashSet<Uuid> }`.
Dedup is O(1) (`seen.insert` returns false on a repeat); overflow evicts via `pop_front` and
drops the evicted id from `seen`. `clear_messages` rebuilds/clears `seen` so cleared messages
can be received again.

### ~~`DiscoveryMode` not set correctly for mDNS-resolved peers~~ ✅ Done
**File:** `patch-core/src/state/mod.rs`, `patch-core/src/discovery/mod.rs`

`AppState::upsert_peer_with_mode(presence, mode)` now lets the caller classify the peer;
`upsert_peer` keeps the `OscBeacon` default. The `ServiceResolved` handler passes
`DiscoveryMode::Mdns`, and the mode sticks across later OSC heartbeats (a peer already
classified as `Mdns` isn't downgraded), so the 🔍 icon shows.

### ~~Stale `bridge_port` in sample config~~ ✅ Done
**File:** `patch-core/patch.toml`

The sample was rewritten to the current `Config` schema — `bridge_port` removed, placeholder
`client_id`, and the new fields (`flash_count`, `macros_columns`, `hide_keyboard`).

### ~~Sample config channels don't match `default_channels()`~~ ✅ Done
**File:** `patch-core/patch.toml`

Now matches `state/config.rs::default_channels()` (`audio`, `rf`, `lighting`, `video`, `stage`)
and uses the current `macros` field (the old `shortcuts` field is gone). A regression test
(`state::config::tests::sample_patch_toml_deserializes`) keeps it from drifting again.

### ~~`RegExp` compiled on every dialog open in settings~~ ✅ Done
**File:** `patch_app/lib/screens/settings_screen.dart`

The five `RegExp`s are now lazily-compiled file-level `final`s (`_slugInvalidChars`,
`_slugDashRuns`, `_slugEdgeDashes`, `_hex6`, `_channelIdRegex`) instead of being recompiled
per dialog/keystroke.

### ~~`width: 220` peers panel hardcoded~~ ✅ Done
Now `static const double _kPeersPanelWidth = 160.0` and `static const double _kMacroColumnWidth = 160.0` in `home_screen.dart`. Macros panel width scales as `_kMacroColumnWidth * _macrosColumns`.

### ~~Hardcoded channel-strip width~~ ✅ Done
**File:** `patch_app/lib/screens/home_screen.dart`

`width: 80` is now `static const double _kChannelStripWidth = 80.0` on `_ChannelStrip`.

### ~~Stale comment in `message_input.dart`~~ ✅ Done
The "Shift+Enter inserts a newline (future use)" comment is gone; the doc comment now just
describes the Enter-to-send / `hideKeyboard` behaviour.

### Macros panel header may overflow in 1-column mode
**File:** `patch_app/lib/widgets/macros_panel.dart` — header `Container`
**Effort:** trivial

The header `Row` contains `Text('MACROS')` (~50 px at 12 px + letterSpacing 1.5),
a `Spacer`, and `_ColumnToggle` (56 px), inside 12 px horizontal padding → 136 px inner
width in 1-column mode. The rename from "SHORTCUTS" (~80 px) to "MACROS" (~50 px) reduced
pressure significantly (~6 px of breathing room). Verify in a running build — may now be
fine. If overflow persists:
- Wrap `Text` in `Flexible(child: Text(..., overflow: TextOverflow.ellipsis))` — minimal change
- Reduce header horizontal padding from 12 to 6 px — gives 12 px extra breathing room

---

## 🔵 Future Features (from Roadmap)

### ALL channel — broadcast view + all-department send
**Effort:** small

A permanent `ALL` tab at the top of the channel strip. Shows every message from
every channel combined, sorted by timestamp, with per-message channel colour dots.
Also supports **sending to all channels simultaneously** — messages are broadcast
to every channel at once and displayed with a 📢 indicator so recipients know it's
an all-department call. The input bar shows a "Sending to ALL channels" hint.
Auto-updates as channels are added or removed.

Implementation:
- Add `send_broadcast(payload, priority)` to `api.rs` — loops over all channels and calls `send_message` for each
- Add `get_all_messages(limit)` to `api.rs` — same as `get_messages` without the `channel_id` filter
- Add `sendBroadcast()` / `getAllMessages()` to `bridge_client.dart`
- Prepend a synthetic `__all__` entry to the channel sidebar in `home_screen.dart`
- When `__all__` selected: use `getAllMessages()`, populate full `_channelColors` map, show broadcast input with hint text
- Messages sent from ALL get a 📢 icon in place of the channel dot in `message_list.dart`
- No new OSC addresses, no FRB codegen needed

### Direct messages (peer-to-peer, outside channels)
**Effort:** medium

Private messages between two specific peers. Uses the existing `PatchMessage` type
and OSC address — no new wire format. A `dm:` channel_id convention identifies the
conversation: `dm:{sorted_uuid_a}:{sorted_uuid_b}` (UUIDs sorted so A→B and B→A
resolve to the same key). The transport unicasts to the target peer only.

Implementation:
- Add `send_direct_message(peer_id, payload, priority)` to `api.rs`: builds the `dm:` channel_id, calls `transport.send_to()` for that peer only, stores locally
- Add `sendDirectMessage()` to `bridge_client.dart`
- DM button on each peer row in `peers_panel.dart`
- DM conversations appear in the sidebar with a 💬 icon; created on-demand on first message
- `get_messages(channel_id)` already works — `dm:` is just another channel key in the ring buffer
- Flash does not apply to DMs; use a notification badge instead

Limitations: no offline queueing, no read receipts, conversation IDs are UUID-based (not portable across reinstalls).

### OSC macro shortcuts + inbound trigger mapping
**Effort:** medium

Two related features covering both directions of OSC interoperability:

**Outbound — OSC macro**
A macro that fires an arbitrary OSC message to a configured destination (address, port,
OSC path) in addition to the normal Patch channel message sent to peers. Useful for
triggering QLab cues, Companion buttons, vMix overlays, or any other OSC-capable gear
directly from the macros panel.

Infrastructure is mostly in place — `rosc` already encodes/sends OSC; the transport
socket is available; the macro editor UI is already extensible.

Implementation steps:
- Add optional fields to `MacroMessage` in `channel.rs`: `osc_address: Option<String>`, `osc_port: Option<u16>`, `osc_path: Option<String>`, `osc_arg: Option<String>` (single string arg covers ~80% of QLab use cases; typed arg list can come later)
- Add `send_osc_macro(address, port, path, arg: Option<String>)` to `api.rs`; encode via `rosc` and send a raw UDP packet via the existing transport socket
- Regenerate FRB bindings; add `sendOscMacro()` to `bridge_client.dart`
- Extend the macro editor in `settings_screen.dart` with an expandable "OSC Target" section (IP field, port field, OSC path field, optional arg field); show only when enabled via a toggle

Design decision (resolve before starting): when a macro has an OSC target, it should fire **both** the Patch channel message to peers **and** the OSC packet to the target — dual action is the most useful live behaviour (crew gets the message AND QLab gets the trigger simultaneously).

**Inbound — external OSC trigger → Patch message mapping**
Allow an incoming OSC message on any address (e.g. `/rf/battery_low`) to be mapped
to a Patch channel message with a configured priority and payload — bridging external
show-control gear into Patch without custom scripts.

### OSCQuery support for zero-config integration
**Effort:** large

Implement [OSCQuery](https://github.com/Vidvox/OSCQueryProposal) so peers and
external tools can discover Patch's OSC namespace automatically without manual
address configuration.

### Optional WAN relay server
**Effort:** large

A lightweight relay process (separate binary) that bridges two or more Patch
instances across the internet — useful for remote production or multi-venue shows.
Must not compromise the local-first, single-binary design for LAN deployments.

### MIDI-triggered macros
**Effort:** medium

Bind a shortcut to a MIDI Note On or CC event so a pad, keyboard, or MIDI
footswitch can fire it without touching the screen or keyboard.

- Add `midi_note: Option<u8>` and `midi_cc: Option<u8>` to `MacroMessage` in
  `patch-core/src/state/channel.rs` (both `#[serde(default)]` — no migration needed)
- Add `midir` crate to `patch-core/Cargo.toml` (CoreMIDI on macOS/iOS, WinMM on Windows, ALSA on Linux)
- New `patch-core/src/midi/mod.rs`: `spawn_blocking` listener; on Note On or CC, iterate all channel shortcuts and fire matches via the existing `send_message` path
- Wire into `api.rs::init()`, optionally add `get_midi_ports() -> Vec<String>` for a future port-selector UI
- Extend the shortcut dialog in `settings_screen.dart` with MIDI note / CC number fields

Note: OSC-triggered shortcuts are not a separate feature — users can already send `/patch/channel/{id}/message` directly from QLab, Companion, or scripts. Mapping *foreign* OSC addresses (e.g. `/rf/battery_low` from a proprietary device) is covered by the existing "OSC macro shortcuts + inbound trigger mapping" item above.

### Native Stream Deck plugin
**Effort:** large (separate project)

A dedicated Elgato Stream Deck plugin (Node.js, Elgato SDK) that:
- Shows live Patch channel names and colours on LCD buttons
- Displays message count, flash animation, and online peer indicator per channel
- Fires Patch shortcuts/messages directly via OSC when a button is pressed
- Distributed via the Elgato Marketplace, not part of this repo

Note: Stream Deck already works with Patch today via F-key emulation or OSC through
Bitfocus Companion — see `docs/integrations.md`.

### ~~Export chat history~~ ✅ Done
`export_messages(channel_id: Option<String>, path: String)` in `api.rs` writes RFC 4180 CSV (timestamp, [channel,] sender, priority, message). `exportMessages()` in `bridge_client.dart`. `download_outlined` button in message area (top-right, left of the clear button); `FilePicker.saveFile` pre-filled with `patch_<channel>.csv`; single-channel export omits the channel column; multi-channel selection includes it.

### ~~Clear chat history~~ ✅ Done
`clear_messages(channel_id: Option<String>)` in `state/mod.rs` + `api.rs`. `clearMessages()` in `bridge_client.dart` emits `messages_cleared`. 🗑 button (`delete_sweep_outlined`) in `_ChannelView` header shows a confirm dialog scoped to the selected channel(s); home screen clears the local `_messages` map on the event.

### ~~Clear inactive dynamic peers~~ ✅ Done
`clear_stale_peers(max_age_secs: u64)` in `state/mod.rs` + `api.rs`; emits `PeerExpired` for each removed peer. `clearStalePeers({maxAgeSecs = 60})` in `bridge_client.dart`. `person_remove_outlined` icon button in the `PeersPanel` header (via `onClearStale` callback); ManualIp / static peers are never removed.

### Global shortcuts (shown on all channels)
**Effort:** medium

A separate list of shortcuts configured once in Settings that appears at the bottom of
every channel's shortcuts panel regardless of which channel is selected. Useful for
crew-wide callouts ("LUNCH BREAK", "HOLD ALL", "GO") that don't belong to any one
department.

Implementation approaches (TBD):
- A synthetic `__global__` channel whose shortcuts are appended to every panel; messages sent on `__global__` reach all peers regardless of their channel subscriptions
- Or: a top-level `global_shortcuts` field in `Config` (not attached to any channel), with a dedicated send path

### ~~Hide keyboard on iOS / iPad~~ ✅ Done
`hide_keyboard: bool` (serde default: `true`) added to `Config` and `ConfigSnapshot`. Toggle in Settings → Behavior (iOS/Android only). `MessageInput` respects `hideKeyboard` param — no autofocus, hint changes to "Tap to type…". `FocusScope.unfocus()` called on channel tap when enabled.

### In-app help & contextual tooltips
**Effort:** medium

Contextual help for crew members who won't read external docs. Remaining work:

**Passive hints** ✅ Done (2026-06-02):
- Settings → Identity subtitle: "Your display name as seen by other Patch users on the network."
- Settings sections already have subtitles (Network Interface, Static Peers, Behavior, Channels & Macros)
- Empty message list: "No messages yet / Are you on the same network as your crew?"

**Still to do:**
- First-run onboarding: name prompt on first launch if name is still the system default
- Peers panel `?` tooltip or help text explaining discovery modes
- Permission-denied SnackBar could link to a help page
- Consider a `HelpTooltip` widget wrapping `IconButton(icon: Icon(Icons.help_outline))` for reuse

---

## ✅ Verified — No Action Needed

- All Cargo + pubspec dependencies are current; lockfile is consistent.
- FRB generated bindings are up to date (last regenerated 2026-06-01; renamed `shortcuts_columns` → `macros_columns`, `ShortcutMessage` → `MacroMessage`).
- `analysis_options.yaml` correctly excludes `lib/src/rust/**` and `cargokit/**`.
- Flash animation uses timer-based `setState` (not `AnimationController`) — intentional, per CLAUDE.md.
- Self-discovery is filtered in two places (`discovery/mod.rs` + `transport/mod.rs`) — both guards are required.
- `_keepTransportImport` in `bridge_client.dart` is an intentional import-keepalive pattern.

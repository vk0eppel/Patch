# Patch — TODO / Known Issues

Items are ordered by priority. File paths are relative to the repo root.
Effort: **trivial** < **small** < **medium** < **large**.

---

## ~~🔴 Critical — Runtime Panics~~ ✅ Fixed

### ~~OSC codec decoders missing bounds checks~~ ✅ Done
**File:** `patch-core/src/osc/codec.rs`

All five decoders now have `bail!` guards matching the pattern in `decode_patch_message`.
Malformed or truncated OSC packets are logged and discarded instead of panicking.

---

## 🟠 Major — Incomplete Features

### Wire ReliabilityManager into the send path for critical messages
**Files:** `patch-core/src/reliability/mod.rs`, `patch-core/src/api.rs`, `patch-core/src/transport/mod.rs`
**Effort:** large
**Also tracked in:** `CLAUDE.md` → Known Incomplete

`ReliabilityManager` (exponential-backoff retransmit, ACK tracking) is fully implemented
but never instantiated or called. Critical messages (`Priority::Critical`) are currently
fire-and-forget with no retry logic.

- Wire `reliability.track(message_id, bytes, peer_ids)` in `api.rs::send_message` when `priority == Critical`
- Spawn a retransmit loop in `api::init` that calls `reliability.drain_retransmits()` periodically
- In `transport/mod.rs` `PatchEvent::Ack` arm, call `reliability.ack(message_id)`

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

### Message ring buffer: O(n) dedup scan + O(n) front removal
**File:** `patch-core/src/state/mod.rs` — `store_message()` ~lines 169–182
**Effort:** small

- `buf.iter().any(|m| m.message_id == ...)` — linear scan on every incoming message
- `buf.remove(0)` — shifts the entire `Vec` on overflow

Replace `Vec<PatchMessage>` with `VecDeque` (O(1) `pop_front`) and maintain a
companion `HashSet<Uuid>` of seen message IDs for O(1) dedup.

### `DiscoveryMode` not set correctly for mDNS-resolved peers
**File:** `patch-core/src/state/peer.rs` — `from_presence()`
**Effort:** small

`from_presence()` always sets `discovery_mode: DiscoveryMode::OscBeacon`, so peers
discovered via mDNS are misclassified. The 🔍 icon in the peers panel is never shown.

- Add a `from_mdns()` constructor (or pass `DiscoveryMode` explicitly) and use it in
  `discovery/mod.rs` `ServiceResolved` handler.

### Stale `bridge_port` in sample config
**File:** `patch-core/patch.toml` — line 4
**Effort:** trivial

`bridge_port = 9001` is a leftover from the removed TCP bridge. The field does not
exist in the `Config` struct and is silently ignored on deserialisation.

- Delete line 4 from `patch-core/patch.toml`

### Sample config channels don't match `default_channels()`
**File:** `patch-core/patch.toml`
**Effort:** trivial

Shows old channels (`foh`, `mon`, `video`, `rf`) instead of the current defaults
(`audio`, `rf`, `lighting`, `video`, `stage`). Misleading for new developers testing locally.

- Regenerate or manually update the `[[channels]]` section to match `state/config.rs::default_channels()`

### `RegExp` compiled on every dialog open in settings
**File:** `patch_app/lib/screens/settings_screen.dart` — ~lines 947–949, 956, 1088
**Effort:** trivial

`RegExp(r'...')` instances created inside dialog-open callbacks on every invocation.

- Hoist to `static final` constants at the class level (e.g. `static final _slugRegex = RegExp(r'[^a-z0-9-]+')`)

### ~~`width: 220` peers panel hardcoded~~ ✅ Done
Now `static const double _kPeersPanelWidth = 160.0` and `static const double _kShortcutColumnWidth = 160.0` in `home_screen.dart`. Shortcuts panel width scales as `_kShortcutColumnWidth * _shortcutsColumns`.

### Hardcoded channel-strip width
**File:** `patch_app/lib/screens/home_screen.dart` — `_ChannelStrip.build()`
**Effort:** trivial

`width: 80` inside `_ChannelStrip` is still a bare literal. Should be a named constant, e.g. `static const double _kChannelStripWidth = 80.0`.

### Stale comment in `message_input.dart`
**File:** `patch_app/lib/widgets/message_input.dart` — line 6
**Effort:** trivial

Comment says "Shift+Enter inserts a newline (future use)" but `maxLines: 1` makes
this impossible as written. Either remove the comment or implement multi-line input.

### Macros panel header may overflow in 1-column mode
**File:** `patch_app/lib/widgets/shortcuts_panel.dart` — header `Container`
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
- Add optional fields to `ShortcutMessage` in `channel.rs`: `osc_address: Option<String>`, `osc_port: Option<u16>`, `osc_path: Option<String>`, `osc_arg: Option<String>` (single string arg covers ~80% of QLab use cases; typed arg list can come later)
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

### MIDI-triggered shortcuts
**Effort:** medium

Bind a shortcut to a MIDI Note On or CC event so a pad, keyboard, or MIDI
footswitch can fire it without touching the screen or keyboard.

- Add `midi_note: Option<u8>` and `midi_cc: Option<u8>` to `ShortcutMessage` in
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

### Export chat history
**Effort:** small

Serialize the in-memory message buffer to a file (CSV or plain text: timestamp, channel,
sender, priority, payload). Export can be per-channel or full log across all channels.
Uses `file_picker` (already a dependency) for the save dialog, same pattern as session export.

Implementation:
- Add `export_messages(channel_id: Option<String>, path: String)` to `api.rs` — filters ring buffer and writes CSV/text via `std::fs`
- Add `exportMessages()` to `bridge_client.dart`
- Add an export button in the `_ChannelView` header (or via a long-press menu on the channel name)

### Clear chat history
**Effort:** small

Clear the in-memory message buffer for a specific channel, or all channels at once.
No persistence impact — only affects the runtime buffer (messages are not stored to disk).

Implementation:
- Add `clear_messages(channel_id: Option<String>)` to `state/mod.rs` + `api.rs`
- Button in the `_ChannelView` header (destructive action — show confirm dialog first)

### Clear inactive dynamic peers
**Effort:** small

A button in the peers panel to remove stale dynamic peers (OscBeacon / Mdns entries
whose `last_seen` exceeds a threshold, e.g. 60 s). ManualIp / static peers are never
removed. Useful for post-show cleanup or when moving between network environments.

Implementation:
- Add `clear_stale_peers(max_age_secs: u64)` to `state/mod.rs` + `api.rs`
- Add a ↺ or 🗑 button to the peers panel header; confirm dialog optional

### Global shortcuts (shown on all channels)
**Effort:** medium

A separate list of shortcuts configured once in Settings that appears at the bottom of
every channel's shortcuts panel regardless of which channel is selected. Useful for
crew-wide callouts ("LUNCH BREAK", "HOLD ALL", "GO") that don't belong to any one
department.

Implementation approaches (TBD):
- A synthetic `__global__` channel whose shortcuts are appended to every panel; messages sent on `__global__` reach all peers regardless of their channel subscriptions
- Or: a top-level `global_shortcuts` field in `Config` (not attached to any channel), with a dedicated send path

### Hide keyboard on iOS / iPad
**Effort:** small

Option to prevent the message input field from auto-focusing (and raising the iOS software
keyboard) on channel switch or app open. In show mode on iPad, shortcuts are the primary
input method; the keyboard appearing unexpectedly covers part of the UI.

Implementation:
- Add `hide_keyboard_on_switch: bool` to `Config` (serde default: false); expose in Settings → Behavior
- In `_ChannelView`, when this setting is on, call `FocusScope.of(context).unfocus()` after channel selection changes
- `MessageInput` widget should only auto-focus when the user explicitly taps the field

### In-app help & contextual tooltips
**Effort:** medium

Contextual help for crew members who won't read external docs. Target areas:
- First-run onboarding: name prompt, NIC picker explanation, "how to find peers"
- Peers panel `?` tooltip explaining the three discovery modes (mDNS / OSC beacon / static IP) and what the green/gray dots mean
- Settings sections: short description above each section header
- Permission-denied SnackBar (already implemented) could link to a help page
- Empty message list hint: "No messages yet — are you on the same network as your crew?"
- Consider a `HelpTooltip` widget wrapping an `IconButton(icon: Icon(Icons.help_outline))` for reuse across screens

---

## ✅ Verified — No Action Needed

- All Cargo + pubspec dependencies are current; lockfile is consistent.
- FRB generated bindings are up to date (last regenerated 2026-05-28; `shortcuts_columns` added to `ConfigSnapshot`).
- `analysis_options.yaml` correctly excludes `lib/src/rust/**` and `cargokit/**`.
- Flash animation uses timer-based `setState` (not `AnimationController`) — intentional, per CLAUDE.md.
- Self-discovery is filtered in two places (`discovery/mod.rs` + `transport/mod.rs`) — both guards are required.
- `_keepTransportImport` in `bridge_client.dart` is an intentional import-keepalive pattern.

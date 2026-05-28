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

### Hardcoded layout widths should be named constants
**File:** `patch_app/lib/screens/home_screen.dart` — lines ~331, ~364
**Effort:** trivial

- `width: 220` (peers panel) and `width: 80` (channel strip) should be
  `static const double` values so they're easy to find and adjust.

### Stale comment in `message_input.dart`
**File:** `patch_app/lib/widgets/message_input.dart` — line 6
**Effort:** trivial

Comment says "Shift+Enter inserts a newline (future use)" but `maxLines: 1` makes
this impossible as written. Either remove the comment or implement multi-line input.

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

### External OSC trigger → Patch message mapping
**Effort:** medium

Allow an incoming OSC message on any address (e.g. `/rf/battery_low`) to be mapped
to a Patch channel message with a configured priority and payload — bridging
external show-control gear (QLab, Companion, TouchDesigner, vMix) into Patch
without custom scripts.

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
- FRB generated bindings are up to date (last regenerated 2026-05-27).
- `analysis_options.yaml` correctly excludes `lib/src/rust/**` and `cargokit/**`.
- Flash animation uses timer-based `setState` (not `AnimationController`) — intentional, per CLAUDE.md.
- Self-discovery is filtered in two places (`discovery/mod.rs` + `transport/mod.rs`) — both guards are required.
- `_keepTransportImport` in `bridge_client.dart` is an intentional import-keepalive pattern.

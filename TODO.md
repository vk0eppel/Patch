# Patch — TODO / Known Issues

Items are ordered by priority. File paths are relative to the repo root.
Effort: **trivial** < **small** < **medium** < **large**.

---

## 🔴 Critical — Runtime Panics

### OSC codec decoders missing bounds checks
**File:** `patch-core/src/osc/codec.rs`
**Effort:** small

Five decoder functions access `args[N]` without checking `args.len()` first.
A malformed or truncated OSC packet from any peer will **panic the engine**.
`decode_patch_message()` already has the correct guard (`if args.len() < 6 { bail!(...) }`) —
the other five need the same treatment:

| Function | Needs guard |
|---|---|
| `decode_ack()` | `args.len() < 2` |
| `decode_presence()` | `args.len() < 4` |
| `decode_heartbeat()` | `args.len() < 1` |
| `decode_discovery()` | `args.len() < 3` |
| `decode_flash()` | `args.len() < 2` |

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

### mDNS init panics instead of gracefully degrading
**File:** `patch-core/src/discovery/mod.rs` — lines 28, 47, 49, 54
**Effort:** medium

Four `.expect()` calls on mDNS init/register/browse. On networks where mDNS is
unavailable or firewalled the entire engine crashes instead of falling back to
OSC beacon + static peer discovery.

- Change `Discovery::new` to return `Result<Discovery>`
- Wrap each `.expect()` in a match/`?`; on failure log a warning and continue without mDNS

### Surface iOS/macOS Local Network permission-denied to the UI
**File:** `patch-core/src/transport/mod.rs` + Flutter event handler
**Effort:** medium
**Also tracked in:** `CLAUDE.md` → Known Incomplete

When the user denies the Local Network permission, OSC sends/receives silently fail.
The error is logged to the console but no `PatchAppEvent` is emitted and the UI
shows no feedback.

- Detect `EPERM`/`EACCES` errors from socket operations in `transport/mod.rs`
- Add a `PatchAppEvent::PermissionDenied` variant in `api.rs`
- Handle it in `bridge_client.dart` → show a banner or alert in Flutter

---

## 🟡 Medium — Validation & Silent Failures

### Channel ID not validated for OSC path safety
**File:** `patch-core/src/api.rs` — `upsert_channel()` ~line 203
**Effort:** small

`id` is embedded directly into `/patch/channel/{id}/message` without sanitisation.
Forward slashes, spaces, or an empty string will silently corrupt OSC addresses.

- Validate with `^[a-z0-9_-]+$` (reject anything else with a descriptive error)

### Static peer address not validated before storing
**File:** `patch-core/src/state/mod.rs` — `add_static_peer()` ~line 150
**Effort:** small

Accepts malformed IP strings, port 0, and duplicate address:port pairs without error.

- Parse with `std::net::IpAddr::from_str()` before pushing; return `Err` on bad address
- Reject duplicates (same `address:port` already in `config.static_peers`)

### `send_to_peers()` always returns `Ok(())` even when all sends failed
**File:** `patch-core/src/transport/mod.rs` — ~line 127
**Effort:** small

If every unicast send fails, the function still returns `Ok(())`. The caller
(`send_message` in `api.rs`) tells Flutter the send succeeded when zero peers
received the packet.

- Return `Err` (or a partial-success enum) if `sent == 0` and at least one peer was targeted

### `sessions_dialog.dart` — `.single` throws on empty file picker result
**File:** `patch_app/lib/widgets/sessions_dialog.dart` — ~line 63
**Effort:** trivial

`result.files.single.path` will throw a `StateError` if the file picker returns
an empty list (e.g. user selected then immediately closed the dialog).

- Replace with `result.files.isEmpty` guard + `result.files.first.path`

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

---

## ✅ Verified — No Action Needed

- All Cargo + pubspec dependencies are current; lockfile is consistent.
- FRB generated bindings are up to date (last regenerated 2026-05-27).
- `analysis_options.yaml` correctly excludes `lib/src/rust/**` and `cargokit/**`.
- Flash animation uses timer-based `setState` (not `AnimationController`) — intentional, per CLAUDE.md.
- Self-discovery is filtered in two places (`discovery/mod.rs` + `transport/mod.rs`) — both guards are required.
- `_keepTransportImport` in `bridge_client.dart` is an intentional import-keepalive pattern.

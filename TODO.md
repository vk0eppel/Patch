# Patch — TODO / Known Issues

Items are ordered by priority. File paths are relative to the repo root.
Effort: **trivial** < **small** < **medium** < **large**.

---

## 🟢 Peer presence & activity precision

Goal: the user should see *who's online and when*, with good precision, without a rewrite.
**Current model (sound, keep it):** presence broadcast every 7s (`discovery/mod.rs`); `last_seen`
refreshed on **every** received packet (`state/mod.rs::touch_peer_address`); the Flutter dot is green
when `last_seen ≤ 35s`, gray otherwise (`peers_panel.dart`); peers never auto-expire; the panel
re-renders on a 3s `Timer` and shows a per-peer "last seen" relative time. The top three items below
are now **done** (relative time, getPeers debounce, mDNS removal); the remaining two are low-priority
tuning, ordered by priority.

### ~~[High] Show a per-peer "last seen" relative time~~ ✅ Done
**File:** `patch_app/lib/widgets/peers_panel.dart` (`_PeerTile`)
`_PeerTile` now shows a relative-time subtitle ("now" / "30s ago" / "3m ago" / "2h ago" / "1d ago")
for dynamic peers, leading the line ahead of the address; manual/static peers (synthetic `lastSeen`)
show just their address. The panel `Timer.periodic` is tightened 10 s → 3 s so the counter stays
current. Covered by `test/peers_panel_test.dart`. Pure UI, no engine change.

### ~~[Med] Throttle `PeerUpdated` / `getPeers()` churn~~ ✅ Done
**File:** `patch_app/lib/screens/home_screen.dart`
The `peer_updated` handler now coalesces bursts via `_schedulePeersRefresh()` — a trailing-edge
~800 ms debounce — so a busy channel does at most ~1 `getPeers()` fetch/window instead of one per
message. `last_seen` still updates in the registry each packet, and the panel's 3 s timer recomputes
the dot/relative-time, so no precision is lost. Dart-side only (the `PeerUpdated` event itself is
cheap); the Rust emit was left as-is.

### ~~[Med] Act on mDNS `ServiceRemoved`~~ ✅ Done
**File:** `patch-core/src/discovery/mod.rs`
The browse task keeps a `fullname → peer_id` map (populated at `ServiceResolved`); on `ServiceRemoved`
it looks up the peer and calls `expire_peer` → `PeerExpired`, dropping it immediately instead of
waiting out the timeout. A transient mDNS blip self-heals: the peer's next OSC presence re-adds it.
(Doesn't help unicast-only / AP-isolated peers that never reached us via mDNS.)

### ~~[Low] Derive the online threshold from the heartbeat~~ ✅ Done
**Files:** `patch-core/src/api.rs` (`ConfigSnapshot.heartbeat_interval_secs`), `patch_app/lib/bridge/bridge_client.dart`, `patch_app/lib/screens/home_screen.dart`, `patch_app/lib/widgets/peers_panel.dart`
`heartbeat_interval_secs` is now exposed on `ConfigSnapshot` (FRB regen) and flows to `PeersPanel` →
`_PeerTile`, which derives the dot thresholds as **2× / 5×** the interval (healthy / amber) instead of the
hardcoded `14` / `35`. With the default 7 s heartbeat that's the same 14 s / 35 s as before, but it now
tracks the configured interval. Existing `peers_panel_test.dart` still passes (default 7 s).
(Optional future tweak, not done: *tighten* to ~3× for faster offline detection — left at 2×/5× to avoid
Wi-Fi flapping.)

### ~~[Low] Active liveness probe for static / manual peers~~ ✅ Done
**File:** `patch-core/src/discovery/mod.rs` (heartbeat loop)
The heartbeat now **unicasts presence to all known peers** (via `send_to_peers`, which includes
static peers). So a static peer receives our heartbeat every ~7 s, learns us, and — once it sends
its own heartbeat back — shows a real green/grey state and "last seen" instead of always-gray
synthetic. No separate probe needed.

### [Low] Departed peers have no distinct state (and a backdated "last seen")
**Files:** `patch-core/src/state/{mod,peer}.rs`, `transport/mod.rs`, `peers_panel.dart` · **Effort:** medium
On `/patch/bye` (and mDNS `ServiceRemoved`), `mark_peer_offline` backdates `last_seen` 60 s to force
the dot grey while keeping the peer in the list — so a *just-departed* peer reads "1m ago" rather than
"now", and a clean departure looks the same as one that merely went quiet. A proper fix is a `departed`
flag on `Peer` (set on bye, cleared on the next OSC packet): keep the real `last_seen`, drive grey from
the flag, and optionally render departed peers distinctly (e.g. a dimmed/"left" treatment — *not* red,
which is the critical-alert colour). Needs a `Peer` field → FRB regen + `PeerInfo`/`_peerToMap` + a dot case.

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
A retransmit poller spawned in `init` drains `drain_retransmits()` each tick and re-sends, using
per-message exponential backoff (see the dedicated backoff item below — now done).
Receivers emit an ACK for every critical message (`handle_event` `Message` arm), and the
`PatchEvent::Ack` arm calls `reliability.ack(message_id, from)` to record progress / clear the entry.

### ~~[Low] macOS multi-interface *initial* discovery (one-way until first contact)~~ ✅ Done (field-validated)
**Files:** `patch-core/src/transport/mod.rs` (`broadcast_per_interface`, `send_per_interface_broadcast`, `set_bound_if`, `usable_iface_indices`, `Outgoing`), `patch-core/src/discovery/mod.rs` (heartbeat)

Implemented **Option A — per-interface limited broadcast** (macOS-only, `IP_BOUND_IF`). Each heartbeat,
in addition to the existing `broadcast` (default-route `255.255.255.255` + subnet copies — kept as the
baseline, **not** removed), `broadcast_per_interface` pushes `255.255.255.255` out of **every** usable
NIC (VPN/`utun` skipped via `SKIP_PREFIXES`). It runs inside the single `send_loop` task as
`Outgoing::PerIfaceBroadcast`, setting `IP_BOUND_IF` on the main socket fd right before each send and
clearing it right after (microsecond receive-scope window). Source port stays 9000, so receivers learn
the correct unicast port and the existing unicast-bootstrap takes over. Additive → cannot regress the
working path. No-op off macOS (Linux/Windows already egress subnet-directed broadcasts out each NIC,
and those *are* delivered to apps there).

**Field-validated (2026-06-06):** the two machines now discover each other in the *exact* configuration
that previously failed zero-way. (Not captured via `RUST_LOG=debug` per-iface log lines, but the
behavioural outcome — discovery working where it didn't before — confirms the fix.) Interface enumeration
is also covered locally (`usable_iface_indices_are_nonzero_and_pinnable` test; `print_iface_indices`
diagnostic). Static peers remain the guaranteed fallback; multicast stays a separate, larger item (next).

### Multicast transport option
**Files:** `patch-core/src/transport/mod.rs`, `patch-core/src/discovery/mod.rs`, `patch-core/src/state/config.rs`
**Effort:** large

Currently Patch uses UDP broadcast for presence/discovery (`255.255.255.255` + per-interface
subnet-directed — see `transport::broadcast_targets` — LAN-only, stops at routers) and
UDP unicast to known peers for messages. Multicast would allow group delivery that can be routed
across VLANs on networks that support multicast routing.

Scope is TBD — options include:
- Multicast for presence/discovery only (replace the subnet-directed broadcast with a multicast group, e.g. `239.0.0.1:9000`), keeping unicast for messages
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

### ~~[Med] `import_layout` / `apply_session` don't validate channel IDs (OSC-path injection)~~ ✅ Done
**Files:** `patch-core/src/osc/codec.rs`, `patch-core/src/state/mod.rs` (`apply_session`), `patch-core/src/api.rs` (`upsert_channel`)
`valid_channel_id` is now `pub(crate)` — the single source of truth for the `[a-z0-9_-]`, ≤64 slug rule.
`apply_session` (used by `load_session` and `import_layout`) validates every channel id up front and
`bail!`s the **whole** session atomically — before clearing/persisting — if any id is OSC-unsafe, so a
hand-edited or shared `.toml` can't inject an invalid `/patch/channel/{id}/…` segment. `upsert_channel`
now calls the same helper (which also adds the ≤64 cap it was missing). Covered by
`state::tests::apply_session_rejects_invalid_channel_id`.

### ~~[Med] Session static peers are saved but never restored~~ ✅ Done
**Files:** `patch-core/src/state/mod.rs` (`apply_session_full`), `patch-core/src/api.rs` (`load_session`, `import_layout`), `patch_app/lib/screens/home_screen.dart`
Load/import now go through the new `AppState::apply_session_full`, which **replaces** both channels and
static peers (mirrors the wholesale channel replace — distributing a layout brings its device IPs along).
`reset_channels` still uses `apply_session` (channels only) so a factory reset never wipes configured
peers. Both lists are validated as untrusted file input: channel ids rejected atomically on a bad id (as
before), session static peers with an invalid address or port 0 skipped with a warning and de-duped by
`address:port`. The Flutter `session_loaded` handler now refreshes peers as well as channels. Covered by
`state::tests::apply_session_full_restores_static_peers`.

### ~~[Med] Critical-message retransmit re-sends to peers that already ACKed~~ ✅ Done
**Files:** `patch-core/src/reliability/mod.rs`, `patch-core/src/transport/mod.rs` (`Ack` arm)
`drain_retransmits` now re-sends **only to targets that haven't ACKed yet** (a critical to 5 peers where
4 acked re-sends just to the 5th). The fix hinged on a subtlety: ACK packets carry a `peer_id`, but
targets are `SocketAddr`s and a synthetic static-peer entry's `peer_id` is a derived UUID that never
matches the real sender — so acks are now matched by the ACK packet's **source address** (`ack(message_id,
from)` in the transport `Ack` arm), which lines up with the target address (everyone binds/sends on the
same OSC port). A stray ACK from a non-target address is ignored so it can't trip early completion.

### ~~[Med] No CI pipeline~~ ✅ Done
**File:** `.github/workflows/ci.yml`

GitHub Actions workflow (on push-to-main + every PR) with two parallel jobs: **rust** runs
`cargo fmt -p patch_core --check`, `cargo clippy -p patch_core --all-targets -- -D warnings`, and
`cargo test -p patch_core`; **flutter** runs `flutter pub get`, `flutter analyze`, and `flutter test`.
Toolchains are pinned (Rust 1.95.0, Flutter 3.44.1) so rustfmt/clippy version drift can't turn CI red
on unrelated changes.

### ~~[Med] Broken default Dart test + no Dart unit coverage~~ ✅ Done
**Files:** `patch_app/test/models_test.dart`, `patch_app/test/message_list_test.dart`, `.github/workflows/ci.yml`

Removed the broken counter-template `widget_test.dart`. Added `models_test.dart` (PatchMessage —
incl. the `isCritical`/`isWarning` priority contract; PeerInfo defaults + discovery mode; SessionMeta;
PatchChannel colour-hex/flag/macro parsing) and `message_list_test.dart` (a pure widget test:
empty-state hint + message rendering, no bridge/engine). `flutter test` is now wired into the CI
flutter job. 11 tests pass.

Note: the bridge `_messageToMap`/`_peerToMap` helpers are private and take FRB-generated types, so
they aren't unit-tested directly; the model `fromJson` tests cover the consumer side of that same
JSON shape. Exposing the bridge converters (`@visibleForTesting`) to test the emission side is a
possible follow-up.

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

### ~~[Low] Vestigial OSC addresses: `/patch/discovery` + `/patch/system/heartbeat` decoded but never sent~~ ✅ Done
**Files:** `patch-core/src/osc/addresses.rs`, `patch-core/src/osc/codec.rs`, `patch-core/src/transport/mod.rs`, `CLAUDE.md`, `docs/osc-integration.md`
Removed (Option A). Deleted the two decoded-but-inert addresses (`/patch/discovery`, `/patch/system/heartbeat`)
— their `PatchEvent::Discovery`/`Heartbeat` variants, `decode_discovery`/`decode_heartbeat`, the `decode_message`
arms, and the two `handle_event` arms (which only `debug!`-logged and didn't even register the sender) — plus
the three fully-dead constants (`/patch/typing`, `/patch/system/alert`, `/patch/system/status`). `/patch/presence`
is now documented as the single discovery+heartbeat address, and as the external-tool announce path (sending one
registers the sender as a peer — already worked). No FFI/codegen impact (`PatchEvent` is the codec's internal
enum). 40 tests still pass; namespace now matches the implementation.

### ~~[Low] `peer_timeout_secs` config field is dead~~ ✅ Done
**Files:** `patch-core/src/state/config.rs`, `CLAUDE.md`, `README.md`
Removed — peers no longer auto-expire, so the field was written to `patch.toml` and read by nobody.
Dropped from `Config` (struct + `Default`) and the sample configs in the docs. Backward-compatible: serde
ignores unknown fields, so an existing `patch.toml` that still carries `peer_timeout_secs` loads fine (the
`representative_config_deserializes` test keeps the line to prove it). Also fixed the stale CLAUDE.md
"peers expire after 30 s" line — it now describes the real 3-state dot / never-auto-expire behaviour. The
Flutter dot thresholds (14 s / 35 s, ~2×/5× the heartbeat) stay hardcoded with a comment; deriving them
from `heartbeat_interval_secs` remains the separate Low item below.

### ~~[Low] No tests for the reliability layer~~ ✅ Done
**File:** `patch-core/src/reliability/mod.rs`
Added a `#[cfg(test)]` module (6 sync tests): full-ack completion + clear, stray ACK from a non-target
ignored, retransmit excludes already-acked addresses, duplicate-ACK idempotency, drop after
`MAX_RETRIES`, and ACK for an unknown message id. Brought the engine suite from 32 → 39 tests.

### ~~[Low] `EngineHandle._discovery` keepalive is a no-op~~ ✅ Done
**Files:** `patch-core/src/discovery/mod.rs`, `patch-core/src/api.rs`
`Discovery` now **owns** the mDNS `ServiceDaemon` (`_mdns: Option<ServiceDaemon>`, `None` when mDNS init
failed). `Discovery::new` returns the daemon handle from the setup block instead of letting it drop at the
end of the function — so `EngineHandle._discovery` genuinely keeps the daemon thread alive for the engine's
lifetime (dropping the last `ServiceDaemon` handle shuts it down). This makes the keepalive real and closes
a latent risk of the daemon stopping once `new()` returned. Comments on both sides updated.

### ~~[Low] No rustfmt/clippy config; clippy never run~~ ✅ Done
**Files:** `rustfmt.toml` (new), `patch-core/Cargo.toml`, scattered engine sources, `flash_button.dart`

Added `rustfmt.toml` (edition 2021, max_width 100) and ran a full `cargo fmt` over the engine —
`cargo fmt --check` is now clean. Ran clippy and fixed every finding: `is_some_and` over
`map_or(false, …)`, `map(session::slugify)`, `ReliabilityManager: Default`, struct-update syntax in
test helpers, moved the `config.rs` test module to file end, and **switched the test data-dir guard
to a `tokio::sync::Mutex`** (the std `MutexGuard` was held across `.await` — clippy's
`await_holding_lock`). The `frb_expand` unknown-cfg warnings are silenced via
`[lints.rust] unexpected_cfgs` in `Cargo.toml`. `DATA_DIR_OVERRIDE` lock unwraps are now
poison-tolerant. `cargo clippy` is clean (0 warnings); the `flash_button.dart` `(_, __)` lint is
fixed, so `flutter analyze lib` is fully clean. (CI enforcement — `clippy -D warnings`,
`fmt --check`, `flutter analyze` — remains the separate "No CI pipeline" item.)

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

### ~~[Low] Reliability retransmit doesn't use exponential backoff~~ ✅ Done
**Files:** `patch-core/src/reliability/mod.rs`, `patch-core/src/api.rs`

Each `InFlight` now carries a `ticks_until_retry` countdown; the poller ticks every
`POLL_INTERVAL_MS` (100 ms) and `drain_retransmits` only re-sends an entry when its countdown hits 0,
resetting it to `2^retries` ticks after each attempt (≈200 ms → 3.2 s) — a deterministic,
unit-testable exponential backoff (no wall-clock). The first retransmit still fires within ~one tick.
The unused `retransmit_delay` sleep helper was removed. New test
`retransmit_uses_exponential_backoff_spacing`; the max-retries/failure test was reworked to tick
through the backoff. No FFI change.

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

### ~~Stale `bridge_port` / channels in the sample config~~ ✅ Done
**Note:** `patch-core/patch.toml` is **gitignored** (a per-user runtime file, not a shipped sample),
so it was never really a repo artifact. The documented format lives in the README, and schema drift
is now guarded by an inline regression test `state::config::tests::representative_config_deserializes`
(parses a full current-format config — all top-level fields, static peers, channels with/without
macros). Kept inline rather than reading the on-disk `patch.toml`, which is absent on a clean CI
checkout (that earlier broke the Rust CI job).

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

### Editable network settings in the UI (OSC port, heartbeat interval)
**Files:** `patch-core/src/api.rs`, `patch-core/src/state/config.rs`, `patch_app/lib/screens/settings_screen.dart` · **Effort:** small
`osc_port`, `heartbeat_interval_secs`, and `peer_timeout_secs` are config-file-only today. Surface them in
a Settings → Advanced/Network section. The heartbeat interval applies live (the discovery loop re-reads
config each tick — same mechanism as the NIC change). `osc_port` needs a socket rebind, so it's the one
setting that genuinely requires a restart — show a restart banner for that field only.

### Message search / filter within a channel
**Files:** `patch_app/lib/screens/home_screen.dart`, `patch_app/lib/widgets/message_list.dart` · **Effort:** small
A search field that filters the visible feed by substring (sender or payload) and/or priority. Pure
Dart-side filter over the already-loaded `_messages` buffer — no engine change. Useful for finding a
specific call in a busy show log before exporting.

### Audible alert on critical / flash (headset-friendly)
**Files:** `patch_app/lib/screens/home_screen.dart` (+ a sound asset), `patch_app/pubspec.yaml` · **Effort:** small
Live operators have eyes on the stage, not the screen. Optionally play a short system sound on an incoming
Critical message (and/or flash), gated by a Settings → Behavior toggle and a per-channel mute. Use a
lightweight `SystemSound`/`audioplayers` call. Pairs naturally with a Do-Not-Disturb toggle (mute flash +
sound for a set period).

### ~~Alert the sender when a critical message isn't received by every peer~~ ✅ Done
**Files:** `patch-core/src/reliability/mod.rs`, `patch-core/src/state/mod.rs`, `patch-core/src/api.rs`, `patch-core/src/transport/mod.rs`, `patch_app/lib/{bridge/bridge_client,models/message,screens/home_screen,widgets/message_list}.dart`

New `AppEvent::MessageDelivery { message_id, delivered, total, failed, failed_peers }` (+ `PatchAppEvent`
mirror — FRB regen) reports per-message delivery for **criticals we sent** (only criticals are ACK'd, so no
false signals for info/warning). `reliability::ack` now returns `Some((delivered, total))` progress (emitted
from the transport `Ack` arm); `drain_retransmits` returns a `DrainResult { retransmits, failures }`, and the
`api::init` poller publishes a **failed** `MessageDelivery` when an entry exhausts `MAX_RETRIES`, mapping the
unacked `SocketAddr`s back to peer names via `resolve_peer_names`/`get_peers`. A critical sent with **no peers**
online emits an immediate failure too (`send_message`). UI (`message_list.dart`): a trailing badge per critical
row — amber `N/M` while delivering, green ✓ (`done_all`) when all acked, red ⚠ (`error_outline`, tooltip names
the peers / "no peers online") on failure — plus a red SnackBar in `home_screen.dart` on any failure so it
can't be missed. Covered by 3 new widget tests in `message_list_test.dart`; reliability tests updated for the
new return types.

Possible follow-ups (not done): persist/animate the in-progress state (it's already live), and a per-message
"resend" affordance on failure.

### ~~ALL channel — broadcast view + all-department send~~ ✅ Done
**Files:** `patch_app/lib/{screens/home_screen,widgets/message_list,widgets/message_input,models/message}.dart`, `patch-core/src/api.rs`

Implemented as a **single broadcast on a reserved `__all__` channel id** (decided with user, over the
fan-out-to-my-channels alternative) — so it reaches **every peer regardless of their channel config,
including channels the sender doesn't have**. A channel id is just a routing label (every peer receives
every packet), so the broadcast rides the existing `send_message`/`get_messages` path — **no new OSC
address, no FRB regen**. A pinned **ALL** tab (reuses `ChannelTab` with a synthetic accent channel) is
**exclusive** (selecting it replaces the selection; a channel tap exits it). In ALL mode the feed shows
every channel's traffic; in normal mode each channel folds in `__all__` messages so a broadcast appears
in whatever a heads-down operator is viewing. Broadcast rows show a 📢 marker (`message_list.dart`); the
input shows a "📢 Broadcast to ALL channels…" hint; a 📢 flash pulses the ALL tab + message area.
Delivery badge / critical retransmit / global macros all work unchanged. Engine: `upsert_channel` rejects
the reserved `__all__` id (test `upsert_channel_rejects_reserved_all_id`); 📢-marker widget test added.
Backfill of full cross-channel history on first open is out of scope (the event stream carries the
session's traffic; a `get_all_messages` FFI fn would be needed for persisted history).

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

### ~~Global shortcuts (shown on all channels)~~ ✅ Done
**Files:** `state/config.rs` (`global_macros` field), `state/mod.rs` (upsert/delete/reorder), `api.rs` (+ `ConfigSnapshot.global_macros`), `bridge_client.dart`, `home_screen.dart`, `macros_panel.dart`, `settings_screen.dart`
Implemented as a top-level `global_macros: Vec<MacroMessage>` on `Config` (chose this over a synthetic
`__global__` channel). They render in their own **GLOBAL** group at the bottom of the macros panel on
every channel, and firing one (tap or F-key) sends on the **currently-selected channel(s)** — i.e. it
behaves exactly like a per-channel macro, just configured once instead of duplicated per channel (a true
crew-wide broadcast is the separate "ALL channel" item). Per-channel macros take F-key precedence over a
global on the same key. Edited in **Settings → Global Macros** (reuses the generalized macro dialog +
`_MacroRow`, with drag-reorder). Covered by `state::tests::global_macros_upsert_delete_reorder_persist`.
No new OSC wire format. **Note:** required an FRB regen (new `ConfigSnapshot` field + 3 API fns).

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

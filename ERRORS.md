# ERRORS.md

Proven mistakes — these have caused real bugs. Read before touching the relevant code.

## Transport / Discovery

**Do not remove `255.255.255.255` from `broadcast_targets`.** Removing it and sending only subnet-directed addresses broke discovery completely on macOS — macOS ignores subnet-directed broadcasts and only delivers `255.255.255.255` to apps.

**mDNS `ServiceResolved` must not update `last_seen`.** Use `resolve_peer_address`, not `touch_peer_address`. The `mdns-sd` crate replays cached resolutions for ~1–2 min after a peer quits — bumping `last_seen` there kept departed peers green past the heartbeat window and undid `/patch/bye` expiry.

**Both self-discovery guards are necessary.** `discovery/mod.rs` checks `peer_id == client_id` in `ServiceResolved`; `transport/mod.rs` checks the same in the `Presence` arm of `handle_event`. Removing either makes the device appear in its own peers panel.

**Never update the peer list directly from a `PeerPresence` event.** It carries no address. Always call `getPeers()` (debounced via `_schedulePeersRefresh` in Flutter).

**`send_to_peers` already includes static peers.** `get_peers()` merges them as synthetic entries. Never add a separate `config.static_peers` loop — static peers would receive every packet twice (flashes have no dedup, so they'd double-fire).

**Don't rely on the `detached` lifecycle event for shutdown.** It's fire-and-forget and usually loses the race with process teardown on desktop. Use `AppLifecycleListener.onExitRequested` (which the framework awaits before terminating).

## Config / State

**Do not pass a config snapshot into `save_config` or save under the config `RwLock`.** The former reintroduces a write-reorder race (concurrent fire-and-forget mutators clobber each other); the latter stalls OSC traffic during disk I/O. Correct pattern: mutate under the RwLock, drop the guard, call `save_config().await` — which acquires a separate `save_lock` and clones the *current* config before writing.

## FFI Bridge

**Every new `ConfigSnapshot` field in Rust must be added to `bridge_client.dart::getConfig()`'s manual map.** Missing a field silently resets the Dart state variable to its `?? default` on every `getConfig()` call.

**`rust-async` is a load-bearing FRB feature.** Without it, async functions in `api.rs` have no Tokio reactor and `tokio::spawn` panics with "there is no reactor running".

## UI / Flutter

**Flash animation uses timer-based `setState` + `Future.delayed`, not `AnimationController`/`TweenSequence`.** `TweenSequence` proved visually unreliable on macOS. Don't revert.

**`SystemSound.play(SystemSoundType.alert)` is a no-op on macOS and iOS.** Use `audioplayers` with the bundled `assets/sounds/alert.wav` instead.

**`AlertDialog` content must use `SizedBox(width: double.infinity)`, not hardcoded pixel widths.** Fixed widths (360–380 px) overflow on iPhone SE.

**`message_list.dart` auto-scrolls on tail `messageId` changing, not list length.** At the 500-message cap, list length stops changing — a length-based trigger silently stops following new messages.

## Architecture

**Do not reintroduce the TCP bridge.** `patch-core/src/bridge/` is gone. For inter-process comms in a debug tool, build a separate binary that links `patch_core` as an rlib.

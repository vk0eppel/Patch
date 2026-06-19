# ERRORS.md

Proven mistakes — these have caused real bugs. Read before touching the relevant code.

## Transport / Discovery

**Do not remove `255.255.255.255` from `broadcast_targets`.** Removing it and sending only subnet-directed addresses broke discovery completely on macOS — macOS ignores subnet-directed broadcasts and only delivers `255.255.255.255` to apps.

**mDNS `ServiceResolved` must not update `last_seen`.** Use `resolve_peer_address`, not `touch_peer_address`. The `mdns-sd` crate replays cached resolutions for ~1–2 min after a peer quits — bumping `last_seen` there kept departed peers green past the heartbeat window and undid `/patch/bye` expiry.

**mDNS `ServiceResolved` carries one address per active interface a peer has up — never just `.next()` it.** A multi-homed Mac (e.g. wired Dante NIC + Wi-Fi) resolves with both addresses; whichever `mdns-sd` lists first silently overwrote the correct address the OSC presence beacon had already learned, even though presence broadcasting itself correctly respects `network_interface` pinning. Discovery still "worked" (the peer showed up) while unicast traffic — including ACKs — went to the wrong NIC and vanished, which looked like a flaky/architecture-specific bug but wasn't. Fixed via `pick_resolved_address` in `discovery/mod.rs`: when pinned, only accept a resolved address on the pinned interface's own subnet (`transport::pinned_ipv4_subnet` / `in_pinned_subnet`); otherwise leave the existing address alone rather than guess. Don't reject IPv4 link-local (`169.254.x.x`) anywhere in this path — Dante and similar AV networks use it intentionally, and pinning to it is a supported config, not a misconfiguration.

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

**`IconButton`'s own `constraints`/`minimumSize` styling is unreliable for forcing a size smaller than Material's default.** Material 3's default style still supplies a 48×48 `minimumSize` that wins over an explicit `constraints:` param — confirmed via a widget test (`tester.getSize` stayed 48×48 despite `BoxConstraints.tightFor(width: 36, height: 36)`). The same applies to `TextButton`'s `minimumSize`, which additionally gets shrunk by `VisualDensity.adaptivePlatformDensity` on desktop but *not* on iOS — so a button sized this way can look fine on macOS and overflow on iOS (this caused two separate RenderFlex-overflow rounds in the channel strip's header icons and the peers panel's "Clear inactive" footer). The only reliable fix is a tight outer `SizedBox`/`Container` with an explicit size — an external tight constraint always wins over the button's internal style resolution.

**Material's `TextField` reserves vertical space for a floating label even when none is set**, pushing text toward the top of the box instead of centering it — set `isDense: true` on the `InputDecoration` and `textAlignVertical: TextAlignVertical.center` on the field to actually center single-line input bars.

## Architecture

**Do not reintroduce the TCP bridge.** `patch-core/src/bridge/` is gone. For inter-process comms in a debug tool, build a separate binary that links `patch_core` as an rlib.

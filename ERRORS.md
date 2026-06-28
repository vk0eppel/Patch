# ERRORS.md

Proven mistakes — these have caused real bugs. Read before touching the relevant code.

## Transport / Discovery

**Do not remove `255.255.255.255` from `broadcast_targets`.** Removing it and sending only subnet-directed addresses broke discovery completely on macOS — macOS ignores subnet-directed broadcasts and only delivers `255.255.255.255` to apps.

**mDNS `ServiceResolved` must not update `last_seen`.** Call `AppState::record_sighting` with `PeerSighting::Mdns`, never `Presence`/`Heartbeat`. The `mdns-sd` crate replays cached resolutions for ~1–2 min after a peer quits — bumping `last_seen` there kept departed peers green past the heartbeat window and undid `/patch/bye` expiry.

**mDNS `ServiceResolved` carries one address per active interface a peer has up — record all of them.** A multi-homed Mac (e.g. wired Dante NIC + Wi-Fi) resolves with both addresses. `pick_resolved_addresses` (plural, `discovery/mod.rs`) returns all addresses on the pinned subnet, or all addresses when no pin is configured; `ServiceResolved` loops over the result and calls `record_sighting` once per address. When pinned, only addresses on the pinned interface's own subnet are accepted (`transport::pinned_ipv4_subnet` / `in_pinned_subnet`); an empty result records the peer without an address (shows up in panel, unreachable until OSC presence fills it in). Don't reject IPv4 link-local (`169.254.x.x`) anywhere in this path — Dante and similar AV networks use it intentionally, and pinning to it is a supported config, not a misconfiguration.

**Both self-discovery guards are necessary.** `discovery/mod.rs`'s `ServiceResolved` and `protocol::handle` (every arm that registers a sender, not just `Presence`) both call `state::is_self(id, client_id)`. The predicate is shared, but removing either *call site* still makes the device appear in its own peers panel — the helper doesn't make the check optional anywhere it's currently called.

**Never update the peer list directly from a `PeerPresence` event.** It carries no address. Always call `getPeers()` (debounced via `_schedulePeersRefresh` in Flutter).

**`send_to_peers` already includes static peers.** `get_peers()` merges them as synthetic entries. Never add a separate `config.static_peers` loop — static peers would receive every packet twice (flashes have no dedup, so they'd double-fire).

**Don't rely on the `detached` lifecycle event for shutdown.** It's fire-and-forget and usually loses the race with process teardown on desktop. Use `AppLifecycleListener.onExitRequested` (which the framework awaits before terminating).

## Config / State

**All config mutations go through `ConfigStore::mutate_and_persist` — there is no separate `mutate` or `save_config`.** The method applies the closure under the write lock immediately and schedules a debounced disk write. Do not attempt to clone the config and write it directly under the config lock: that reintroduces a write-reorder race (concurrent callers clobber each other) and stalls OSC traffic during disk I/O. In tests, call `AppState::flush_config()` after a mutation before asserting on disk state — the debounce is 0ms in tests but the write still runs on a spawned task.

**An "upsert matched by label/key" mutator silently duplicates instead of renaming if the caller is editing an existing entry and the key changes.** `upsert_macro`/`upsert_global_macro` matched the macro to replace by its *current* label; renaming a macro in the UI saves under the *new* label, which doesn't match anything, so the old entry was never removed — it just appended a second macro. Fixed by threading an `original_label: Option<&str>` through the whole stack (registry → `state/mod.rs` → `api.rs` → Dart) so an edit identifies the entry by its pre-edit key, not its new one; `None` means create. Any other label/id-keyed upsert added later (channels, static peers, etc.) needs the same `original_*` parameter the moment its UI editor allows renaming — matching only by the new value will look correct until the first rename.

## FFI Bridge

**Every new `ConfigSnapshot` field in Rust must be added to `AppConfig.fromRust()` in `lib/models/config.dart`.** `getConfig()` returns `Future<AppConfig>`, and the shared `AppStore` is the single consumer — both `home_screen.dart` and `settings_screen.dart` read config-derived values from `store.config`, so wiring the field through `AppConfig.fromRust` once surfaces it on both screens. Two tests pin it: a Rust test (`api::tests::config_snapshot_field_set_is_pinned`) pins `ConfigSnapshot`'s serialized field set so adding a Rust field without updating the Dart mapping fails `cargo test`; a Dart sentinel (`test/bridge/config_conversion_test.dart`) constructs a `ConfigSnapshot` with every field at a non-default value and asserts every `AppConfig` field matches, so a wiring miss fails `flutter test`. More broadly: all Rust→Dart conversions for channel, message, peer, and config types live as `fromRust()` factory constructors on their respective model classes (`channel.dart`, `message.dart`, `config.dart`) — not in `bridge_client.dart`.

**`rust-async` is a load-bearing FRB feature.** Without it, async functions in `api.rs` have no Tokio reactor and `tokio::spawn` panics with "there is no reactor running".

## UI / Flutter

**Flash animation uses timer-based `setState` + `Future.delayed`, not `AnimationController`/`TweenSequence`.** `TweenSequence` proved visually unreliable on macOS. Don't revert.

**`SystemSound.play(SystemSoundType.alert)` is a no-op on macOS and iOS.** Use `audioplayers` with the bundled `assets/sounds/alert.wav` instead.

**`AlertDialog` content must use `SizedBox(width: double.infinity)`, not hardcoded pixel widths.** Fixed widths (360–380 px) overflow on iPhone SE.

**`message_list.dart` auto-scrolls on tail `messageId` changing, not list length.** At the 500-message cap, list length stops changing — a length-based trigger silently stops following new messages.

**`IconButton`'s own `constraints`/`minimumSize` styling is unreliable for forcing a size smaller than Material's default.** Material 3's default style still supplies a 48×48 `minimumSize` that wins over an explicit `constraints:` param — confirmed via a widget test (`tester.getSize` stayed 48×48 despite `BoxConstraints.tightFor(width: 36, height: 36)`). The same applies to `TextButton`'s `minimumSize`, which additionally gets shrunk by `VisualDensity.adaptivePlatformDensity` on desktop but *not* on iOS — so a button sized this way can look fine on macOS and overflow on iOS (this caused two separate RenderFlex-overflow rounds in the channel strip's header icons and the peers panel's "Clear inactive" footer). The only reliable fix is a tight outer `SizedBox`/`Container` with an explicit size — an external tight constraint always wins over the button's internal style resolution.

**Material's `TextField` reserves vertical space for a floating label even when none is set**, pushing text toward the top of the box instead of centering it — set `isDense: true` on the `InputDecoration` and `textAlignVertical: TextAlignVertical.center` on the field to actually center single-line input bars.

## Build / Release

**Always run `cargo fmt` with the pinned 1.95.0 toolchain — bare `cargo fmt` uses your local toolchain and will silently produce a diff that fails CI.** CI pins Rust 1.95.0 (see `.github/workflows/ci.yml`); different rustfmt versions have slightly different line-wrapping decisions. Use `rustup run 1.95.0 cargo fmt -p patch_core` before committing Rust changes. If 1.95.0 isn't installed: `rustup toolchain install 1.95.0 --component rustfmt`.

**Bumping `patch_app/pubspec.yaml`'s `version:` is not sufficient on its own — verify it actually took.** `macos/Runner.xcodeproj/project.pbxproj` and `ios/Runner.xcodeproj/project.pbxproj` can have a literal `FLUTTER_BUILD_NAME = x.y.z;` baked directly into their build settings (found hardcoded at `0.1.0` long after `pubspec.yaml` had moved past it). A setting written directly in a pbxproj's `buildSettings` wins over the same key coming from the included xcconfig — so the version stayed stuck at `0.1.0` through every subsequent release, *including clean rebuilds*, because `flutter build`/`flutter run` only regenerates `Generated.xcconfig`, never the pbxproj. After any version bump, confirm with `defaults read .../Patch.app/Contents/Info.plist CFBundleShortVersionString` rather than trusting "About Patch" or assuming a clean build fixes staleness — and if it doesn't match, grep the two `project.pbxproj` files for a hardcoded `FLUTTER_BUILD_NAME` before suspecting anything else.

## Architecture

**Do not reintroduce the TCP bridge.** `patch-core/src/bridge/` is gone. For inter-process comms in a debug tool, build a separate binary that links `patch_core` as an rlib.

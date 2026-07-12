# CONVENTION.md

## Rust

- Quick type-check: `cargo check -p patch_core` (package uses underscore — cargokit resolves `libpatch_core.a`)
- Format: `cargo fmt -p patch_core` — policy in `rustfmt.toml` (edition 2021, max_width 100)
- Lint: `cargo clippy -p patch_core --all-targets -- -D warnings`
- CI enforces fmt + clippy + `cargo test` + `dart format` + `flutter analyze` + `flutter test` + a macOS native build on every PR (pinned: Rust 1.95.0, Flutter 3.44.1)

## Dart formatting

- Format: `dart format lib test` (run from `patch_app/`) — CI gates it with `dart format --output=none --set-exit-if-changed lib test`. Scoped to first-party dirs; generated bindings (`lib/src/rust`) and vendored `cargokit` are excluded (they're also excluded from the analyzer, and `dart format` has no `--exclude` flag).
- The formatter splits a braceless `if (cond) stmt;` onto two lines when the body is long, which trips `curly_braces_in_flow_control_structures` — always brace flow-control bodies rather than relying on the single-line exemption.

## FFI Codegen

After editing `patch-core/src/api.rs`:
1. `flutter_rust_bridge_codegen generate` (repo root) — rewrites `frb_generated.rs` and `patch_app/lib/src/rust/*`
2. `dart run build_runner build` in `patch_app/` — only needed if a `freezed` type changed

## OSC

All OSC encoding/decoding belongs in `patch-core/src/osc/codec.rs`. Add and test new packet types there first.

`valid_channel_id` (`pub(crate)` in `codec.rs`) is the single source of truth for the channel slug rule (`[a-z0-9_-]`, ≤64 chars). Call it from `upsert_channel` and `apply_show_file` — never duplicate the check elsewhere.

`validate_osc_target` (`pub(crate)` in `state/channel.rs`) is the single source of truth for "is this macro's OSC target legal" (address/port/path/arg+arg_type). Every caller uses this same check but applies its own policy on top depending on trust level — see ADR-0002. Don't add a fallback/normalize path here; that choice belongs at the call site.

`csv_escape` in `api.rs` neutralises formula injection (cells starting with `= + - @` get a `'` prefix). Apply to any network-sourced export data.

## Async / I/O

All blocking file I/O must be wrapped in `spawn_blocking`. Tests that touch disk use `config::test_data_dir_guard()` — a `tokio::sync::Mutex` (not std) so it can be held across `.await` without tripping `await_holding_lock`.

## Releasing

Bump `patch_app/pubspec.yaml`'s `version:` (keep the `+1` build-number suffix unless you have reason to change it), commit, then `git tag vX.Y.Z && git push origin vX.Y.Z` — `release.yml` builds macOS/Windows and opens a draft release. After the workflow finishes, verify the bundled version actually moved before publishing the draft — see ERRORS.md's Build/Release entry for why a clean build alone doesn't guarantee that.

## Platform (macOS)

If a Rust crate emits `cargo:rustc-link-lib=framework=Foo`, add `-framework Foo` to `OTHER_LDFLAGS` in `patch_app/rust_builder/macos/patch_core.podspec` and run `pod install`. Cargokit's static `.a` doesn't carry those directives — Xcode will fail with undefined symbols.

## Dart

The bridge exposes typed values only — `Future<T>` reads, throwing commands, and a sealed `PatchEvent` push stream (`models/events.dart`); there is no `Map<String, dynamic>` event envelope. Shared domain state (peers, config, channels, messages) lives in the single `AppStore` (`store/app_store.dart`); screens read it through `AppStoreScope.of(context)` rather than holding their own copies — if two screens need the same data, it belongs in the store, not duplicated in both. Screen-local UI state (selection, flash counters, form controllers) stays in the widget. Commands throw on failure and are wrapped in `runGuarded` (`util/run_guarded.dart`) so the error surfaces once. See ADR-0004 (event seam) and ADR-0005 (AppStore).

`macros_panel.dart` exports both `MacrosPanel` and `ChannelMacro`. Import with `show MacrosPanel, ChannelMacro`.

`Priority` serialises to/from integers (not variant name strings) via manual `Serialize`/`Deserialize` impls. The Dart façade reads `priority.index`.

MIDI CC triggers on value ≥ 64 with no edge-tracking — don't bind an expression pedal (it would spam triggers continuously).

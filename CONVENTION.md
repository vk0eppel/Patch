# CONVENTION.md

## Rust

- Quick type-check: `cargo check -p patch_core` (package uses underscore — cargokit resolves `libpatch_core.a`)
- Format: `cargo fmt -p patch_core` — policy in `rustfmt.toml` (edition 2021, max_width 100)
- Lint: `cargo clippy -p patch_core --all-targets -- -D warnings`
- CI enforces fmt + clippy + `cargo test` + `flutter analyze` + `flutter test` on every PR (pinned: Rust 1.95.0, Flutter 3.44.1)

## FFI Codegen

After editing `patch-core/src/api.rs`:
1. `flutter_rust_bridge_codegen generate` (repo root) — rewrites `frb_generated.rs` and `patch_app/lib/src/rust/*`
2. `dart run build_runner build` in `patch_app/` — only needed if a `freezed` type changed

## OSC

All OSC encoding/decoding belongs in `patch-core/src/osc/codec.rs`. Add and test new packet types there first.

`valid_channel_id` (`pub(crate)` in `codec.rs`) is the single source of truth for the channel slug rule (`[a-z0-9_-]`, ≤64 chars). Call it from `upsert_channel` and `apply_show_file` — never duplicate the check elsewhere.

`csv_escape` in `api.rs` neutralises formula injection (cells starting with `= + - @` get a `'` prefix). Apply to any network-sourced export data.

## Async / I/O

All blocking file I/O must be wrapped in `spawn_blocking`. Tests that touch disk use `config::test_data_dir_guard()` — a `tokio::sync::Mutex` (not std) so it can be held across `.await` without tripping `await_holding_lock`.

## Platform (macOS)

If a Rust crate emits `cargo:rustc-link-lib=framework=Foo`, add `-framework Foo` to `OTHER_LDFLAGS` in `patch_app/rust_builder/macos/patch_core.podspec` and run `pod install`. Cargokit's static `.a` doesn't carry those directives — Xcode will fail with undefined symbols.

## Dart

`macros_panel.dart` exports both `MacrosPanel` and `ChannelMacro`. Import with `show MacrosPanel, ChannelMacro`.

`Priority` serialises to/from integers (not variant name strings) via manual `Serialize`/`Deserialize` impls. The Dart façade reads `priority.index`.

MIDI CC triggers on value ≥ 64 with no edge-tracking — don't bind an expression pedal (it would spam triggers continuously).

<!--
Keep PRs scoped to one ticket. Use Patch's domain terms (Operator, Peer,
Channel, Flash, Macro, …) from CONTEXT.md in the description.
-->

## What & why

<!-- What this changes and the operational need it serves. -->

Closes #<!-- issue number -->

## Checks

<!-- CI enforces these (CONVENTION.md). Confirm they pass locally. -->

- [ ] `cargo fmt -p patch_core --check` + `cargo clippy -p patch_core --all-targets -- -D warnings`
- [ ] `cargo test -p patch_core`
- [ ] `dart format --output=none --set-exit-if-changed lib test` (from `patch_app/`)
- [ ] `flutter analyze` + `flutter test`
- [ ] If native/plugin code changed: `flutter build macos` still links (see CONVENTION.md → Platform)
- [ ] If `patch-core/src/api.rs` changed: regenerated FFI glue (`flutter_rust_bridge_codegen generate`)
- [ ] Touched an ADR area or domain term? ADRs/CONTEXT.md updated if the decision or vocabulary moved.

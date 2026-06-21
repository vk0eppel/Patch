# AppState splits into domain registries, but stays the one facade

`AppState` conflated five domains in one `impl` block: message buffering, peer registry, config persistence, channel/macro CRUD, and UI selection state. Behaviour, locking, and persistence orchestration for all of them lived in `state/mod.rs`, even though the domain *types* (`Channel`, `Peer`, `Config`) were already split into their own files.

Splits the behaviour into per-domain registry structs, each owning its own lock(s) and living alongside the type it manages: `PeerRegistry` in `state/peer.rs`, `ChannelRegistry` in `state/channel.rs`, `ConfigStore` in `state/config.rs` (also absorbing `save_lock` — a config-persistence concern, not an `AppState`-level one), and `MessageBuffer` promoted out of `mod.rs` into its own file, `state/message.rs`, with its lock moved inside the struct for consistency with the other three.

Three decisions here are easy to accidentally undo later, so they're recorded:

1. **`AppState` keeps every current public method and signature.** Callers (`api.rs`, `protocol::handle`, `transport`, `midi`) don't change at all — only `AppState`'s internals reorganize. Each method becomes a thin orchestration: call into the relevant registry/registries, decide what (if anything) to publish. Don't "finish the job" later by exposing the registries directly to callers — that's a much larger, separately-considered change, not an oversight.

2. **Registries never touch `AppEvent` or the broadcast channel.** `PeerRegistry`/`ChannelRegistry`/`ConfigStore`/`MessageBuffer` are pure domain logic — mutate data, return what changed, nothing more. `AppState` is the only thing that holds the event sender and decides what to publish. Don't add event-publishing to a registry to save a line in `AppState` — it makes that one registry's tests need a broadcast channel for no domain reason, and the inconsistency would spread.

3. **Cross-domain orchestration lives in `AppState`, not in either registry.** The clearest example: persisting channels means reading a snapshot from `ChannelRegistry` and writing it into `ConfigStore`. That coordination stays in `AppState` (e.g. `persist_channels`, `apply_show_file_full`) rather than giving `ConfigStore` a dependency on `Channel` or giving `ChannelRegistry` a back-reference to `ConfigStore`.

4. **UI selection state (`selected`, `dm_target`) deliberately stays as plain fields on `AppState`'s inner state, not a registry.** It's two fields with trivial get/set and no invariants — giving it the same treatment as the other four would be symmetry for its own sake, not a fix for an actual shallow module.

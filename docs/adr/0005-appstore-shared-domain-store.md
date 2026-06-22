# A single AppStore owns UI-side domain state; screens read it, never their own copy

Each screen used to fetch and hold its own copy of the shared domain state — peers, config, channels, messages — and keep the copies in sync by listening to a stringly-typed event stream. Removing that stream (ADR-0004) left a gap: where does the fetched state live, and how does a change made on one screen reach the other?

`AppStore` (`patch_app/lib/store/app_store.dart`) is the answer. A single `ChangeNotifier` owns peers, config, channels, and the per-channel message buffers + delivery tracking. It subscribes to `BridgeClient.pushes` and reduces the typed `PatchEvent`s that affect its domains (a `PeersChanged` refetches peers, a `ClientNameChanged` refetches config, a `MessageReceived` appends, …), then `notifyListeners()`. Reads on the bridge return `Future<T>` and are owned by the store; both screens read domain state through it. A change made in one screen updates the store, which notifies both — no event round-trip, no cross-screen staleness.

The store is provided **above the Navigator** via `AppStoreScope` (an `InheritedNotifier`) installed in `MaterialApp.builder`, so a pushed route (the Settings screen) finds it the same as the home route does.

Four decisions here are easy to accidentally undo later, so they're recorded:

1. **One store, not one per screen.** The cross-screen fan-out *is* the point — a flash-setting toggle or a static-peer add in Settings must reflect on Home with no event. Per-screen stores reintroduce exactly the staleness the shared store was built to remove. The narrowing "but Settings only needs config" instinct leads straight back to two diverging copies.

2. **`ChangeNotifier` + `InheritedNotifier`, no state-management dependency.** Deliberate — it matches the single-binary / minimal-deps ethos, and the surface (four domains, one notifier) is small enough that Riverpod/Bloc/Provider wouldn't earn their dependency. And the scope is installed **above the Navigator** (`MaterialApp.builder`), not inside the home route — moving `AppStoreScope` down into `HomeScreen` would make `AppStoreScope.of(context)` throw on the pushed Settings route.

3. **Screen-local UI state stays in the widget.** The store owns *domain* state (what is true); the screen owns *presentation* (how it's shown). Channel selection, flash pulse counters, unread-DM sets, and the Settings form `TextEditingController`s live in the screens. Pushing selection or flash state into the store is symmetry for its own sake and couples unrelated screens.

4. **The store stores; the screen reacts.** `MessageReceived` is split on purpose: the store appends the message to its buffer and tracks delivery, while `home_screen.dart` decides the flash / DM-unread dot and raises the critical-delivery-failure snackbar. Don't move the flash/unread reaction into the store — it's a per-screen presentation decision that depends on the screen's own selection state, not a domain fact.

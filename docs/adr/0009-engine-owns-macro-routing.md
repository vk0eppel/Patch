# The engine owns Macro routing for every trigger source

Macro-fire routing policy — a Channel Macro fires absolute on its own Channel; a Global Macro fires on the currently-selected Channel(s) and sends nothing when nothing is selected; any Macro fired while a Direct Message thread is open goes to that Peer; the OSC dual-action fires exactly once per fired Macro; a Channel Macro on a selected Channel beats a Global Macro on a shared F-key — used to be implemented twice: Rust `macro_router` for MIDI/engine triggers, and Dart (`macro_dispatch.dart` + the home screen's three-bridge-call fan-out and F-key precedence loops) for UI taps and F-keys. Two brains for one policy; every routing change had to be made, and tested, in both languages.

We decided: **`macro_router` is the single routing brain for all trigger sources.** The UI expresses intent through two FFI commands:

- `fire_macro(channel_id?, label)` — a tap on an identified Macro. Implemented as `fire_identified`, which narrows the macro universe to just that Macro and delegates to the same `fire_matching` core every trigger uses, so no routing code is duplicated even engine-side.
- `fire_key_binding(label)` — an F-key press. Precedence (`resolve_key_macro`) is engine-owned and pinned by Rust tests.

`macro_dispatch.dart` and its test are deleted. The Dart F-key handler keeps one non-routing responsibility: it must decide *synchronously* whether to consume the key event, so it performs an existence check ("is any macro bound to this key on a selected Channel or globally") against store data before firing the async command. That predicate mirrors, but does not re-implement, routing.

This refines rather than contradicts ADR-0005: routing is domain policy (what is true about where a Macro goes), not screen presentation. The screen keeps its presentation reactions — the DM-offline warning still fires screen-side off the local Selection.

The trade-off accepted: a UI tap now crosses the FFI before any packet leaves, instead of Dart calling `send_message`/`send_direct_message`/`send_osc_macro` directly. The round-trip is in-process and sub-millisecond — negligible for a one-touch fire — and what it buys is that a routing bug can no longer exist in only one language.

Don't undo this by "optimising" the tap path back to direct bridge send calls, and don't grow the Dart existence check into precedence logic — if the consume decision ever needs more than "is anything bound", move the whole key handler behind a synchronous FFI query instead.

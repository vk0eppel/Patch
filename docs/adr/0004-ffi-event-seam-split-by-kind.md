# The FFI event seam carries only engine pushes — outcomes return, fetches await

`BridgeClient.events` used to be a single `Stream<Map<String, dynamic>>` keyed by an `'event'` string. It mixed three genuinely different kinds of traffic, all flattened into the same untyped map:

- **Engine pushes** — events the engine originates (a Message arrived, a Channel was Flashed, a Peer left, a Peer offered its Channel layout). These are genuinely asynchronous and belong on a stream.
- **Command outcomes** — acknowledgements synthesised on the Dart side after a command returned (`ack_send`, `config_updated`, `interface_changed`, `channels_adopted`, `show_file_*`, a global `error`). These are the *result* of a call the caller already made.
- **Fetches** — request/response reads where a method fired and then emitted its result back as an event (`channels`, `peers`, `config`, `messages`, `show_files`, `interfaces`). A `Future` masquerading as an event.

Collapsing all three into one stringly-typed stream made drift fail silently — a renamed key, a forgotten field, or an engine event the UI never wired up produced no error, just a dropped event or a setting silently reset to default — and made the dispatch untestable except by pumping a whole screen.

The decision: **each kind takes the shape that fits it.** Engine pushes cross the seam as a typed, sealed `PatchEvent` (hand-written in Dart over the app's own model types). Command outcomes become ordinary return values, and a failed command throws. Fetches become awaited returns. The event stream ends up carrying only genuine engine pushes.

This lands in two slices so the riskier half rides with the right owner:

- **Slice 1** (Dart-only, no engine change, no FFI regen): type the pushes, turn command outcomes into return values / throws, delete the redundant command-acknowledgement traffic. Fetch responses sit on a temporary, clearly-labelled legacy stream in the meantime.
- **Slice 2**: convert the fetch methods to awaited returns and delete the legacy stream — sequenced to land with the home/settings store extraction, because that store becomes the single owner of fetched state and the fan-out a broadcast fetch-event used to provide.

See PRD #49 for the slice-1 specification.

Four things here are easy to accidentally undo later, so they're recorded:

1. **Don't re-merge the three kinds back onto one stream to "simplify."** The split *is* the simplification: a stream for what is genuinely pushed, a return value for what a caller awaits, a thrown error for what fails. Putting command outcomes or fetch responses back onto the event stream reintroduces exactly the stringly-typed envelope this removed, and with it the silent-drift failure mode.

2. **Don't reuse the FFI-generated event type directly in the UI.** `PatchEvent` is hand-written in the model layer over the app's own model types, deliberately. Wiring the generated FFI type straight into the screens would pull the bridge layer (raw FFI structs, `BigInt`) up into the UI — a different seam leak in place of the one this fixed. The model layer takes no FFI import.

3. **Don't surface engine events the UI doesn't consume, for completeness' sake.** The per-Peer acknowledgement (`MessageAcked`) is forwarded by the engine but read by no screen; it is intentionally *not* mapped into `PatchEvent`. The seam carries what consumers actually read. The engine-side variant stays — this is only about what crosses into the UI.

4. **Keep the wire→model mapper a pure function with an exhaustive switch.** The mapper is separated from the act of emitting onto the stream, and switches exhaustively over the generated FFI event type, so a new engine event variant is a build break until it is mapped or explicitly dropped. The compiler is the primary guard against drift; the unit tests cover only the field conversions it can't see. Don't fold the mapping back into the stream forwarder — that re-buries the one seam this whole change exists to expose.

# Interface pinning is mandatory — Auto mode is removed

`network_interface` had two states: `Some(name)` pinned Patch to one NIC with ADR-0010's operate-only confinement (inbound sources off that subnet dropped, Static Peers exempt); `None` meant Auto — Patch operated on every interface it could see, with **zero** inbound filtering. Auto was also the default on every fresh install, so most Operators never opted into the confinement ADR-0010 built. A laptop that can see venue Wi-Fi, a neighboring production's show network, or any other reachable subnet exchanged traffic with peers on all of them at once by default — exactly the exposure ADR-0010 was written to close, just gated behind a setting nobody had reason to touch.

We decided: **remove Auto entirely.** Every Patch instance always operates on exactly one deliberately-resolved interface, with ADR-0010's confinement applying unconditionally. `network_interface: None` no longer means "operate everywhere" — it means **unresolved**, and while unresolved, dynamic discovery is fully inert in both directions: no presence beacon sent, no inbound source admitted, no mDNS resolution recorded. Static Peers are unaffected either way, since they were never gated by the pin.

To avoid trading the old surprise (uncontrolled exposure) for a new one (a silently dead app), engine startup resolves an unset `network_interface` before any transport/discovery component starts: if exactly one usable interface is enumerated, it's auto-selected and persisted — the common single-NIC laptop gets zero added friction. If zero or two-or-more candidates exist, Patch stays unresolved rather than guessing; a log line and a prominent Settings → Network banner explain that dynamic discovery is inert and Static Peers still work.

Four sub-decisions, each a real trade-off:

1. **No multi-interface operation.** Auto let Patch operate across every simultaneously-active interface at once (Ethernet + Wi-Fi both up). That's gone — a Patch instance operates on exactly one interface, full stop. A show's traffic path should be a deliberate choice, not whatever the OS happened to have up.
2. **Pinning is one-way.** There is no "forget"/"unpin" action. The only way to change the pin is picking a different interface from the same list. `network_interface` can still be set back to `None` as an internal API call, but no production UI path reaches it — the unresolved state is something engine startup resolves *into* pinned, never something an Operator action resolves *out of* pinned.
3. **Existing installs get no special migration dialog.** An install that was deliberately running Auto will, on next launch, either auto-pin (down to one NIC) or land in the unresolved/blocked state (2+, likely for these Operators specifically, since they're the ones who had a reason to want every network). A log line plus the Settings banner is the whole of the upgrade story — no first-launch-after-upgrade explainer. This is a real, accepted behavior change for existing multi-NIC Auto users, not just new installs.
4. **The config field keeps its `Option<String>` shape.** `None` already had exactly the right cardinality to mean "unresolved" — an enum distinguishing "never resolved" from "pinned" would touch every call site for no behavioral gain, and the FFI-exposed config snapshot is `Option<String>` regardless. Only the *interpretation* of `None` changed, not the type.

This refines ADR-0010 rather than replacing it: the operate-only admission/broadcast/mDNS-filtering logic is unchanged, just applied unconditionally instead of only-when-pinned. It also supersedes ADR-0010's line "Auto mode (`network_interface = None`) is untouched" — Auto no longer exists, so there's nothing left for that sentence to describe.

## Considered options

- **Keep Auto, default to pinned**: rejected — doesn't close the exposure for any install that ever explicitly re-selects Auto, and keeps two admission code paths alive indefinitely for a mode we don't want anyone using.
- **Auto with a one-time consent dialog** ("this app wants to see every network — allow?"): rejected — a click-through consent screen trains Operators to dismiss it, and doesn't produce a better mental model than just not having the option.
- **First-run always forces an explicit choice, even with one candidate**: rejected — the common single-NIC laptop is the overwhelming case; adding a mandatory click for a decision with only one legal answer is friction with no safety benefit.
- **Multi-pin / interface failover** (operate on a primary NIC with automatic fallback to a secondary): rejected as out of scope — a real feature, but a different one; mandatory pinning's goal is confinement to a deliberate, singular path, not redundancy.

A later, separate piece of work may make the current pin more visible on the main window (not just tucked in Settings) — not designed here, just noted as a natural next step.

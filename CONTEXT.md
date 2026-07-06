# Patch

Real-time operational communication tool for live production teams (AV, broadcast, theatre, touring). Every concept maps to what a crew needs to execute a live show reliably.

## Language

**Operator**:
The human running a Patch instance during a production.
_Avoid_: User, crew member, client

**Peer**:
Another Operator's Patch instance as seen from the local instance — the person you're communicating with.
_Avoid_: Node, device, client, remote user

**Role**:
A free-text label an Operator assigns to themselves describing their production position or activity (e.g. "FOH Audio", "Lighting", "Stage Manager").
_Avoid_: Title, job, department

**Channel**:
A named communication lane scoped to a department, team, or topic. All Operators monitoring a channel see the same messages.
_Avoid_: Room, group, topic, thread

**Flash**:
An urgent attention signal on a channel — the digital equivalent of an intercom call. Interrupts the recipient to look at the channel; carries no message content itself.
_Avoid_: Alert, ping, notification, alarm

**Priority**:
The urgency level of a message. Three Operator-facing levels: Info, Warning, Critical. Debug exists as an internal level for testing and troubleshooting — not configurable by Operators. Set on a Macro, not chosen at send time. Only Critical triggers ACK/retransmit.
_Avoid_: Severity, importance, level

**Critical Message**:
A message at Critical priority — delivery must be confirmed via ACK/retransmit.
_Avoid_: Priority message, urgent message, confirmed message

**Macro**:
A one-touch callout with its label, payload, and priority preset. Fired instantly during a production without composing or deciding. May optionally also fire an OSC command alongside the Patch message — this is additive, not an alternative action type.
_Avoid_: Shortcut, template, preset, button

**Channel Macro**:
A Macro permanently bound to a specific Channel. Fires on that Channel regardless of what the Operator currently has selected. Stored inside the Channel definition.
_Avoid_: Local macro, per-channel macro

**Global Macro**:
A Macro with no preset Channel. Fires on whichever Channel(s) the Operator currently has selected at the moment of firing. If nothing is selected, the macro sends nothing. Stored separately from Channels in config.
_Avoid_: Universal macro, floating macro

**Production**:
The live event being executed — a theatre show, broadcast, corporate AV event, touring date, etc. The bounded context within which all Patch communication takes place.
_Avoid_: Show, gig, event, job

**Direct Message**:
A 1:1 message thread between the local Operator and a specific Peer — outside of any Channel. Keyed per peer; persists while the app is open.
_Avoid_: Private message, private line, whisper, DM thread

**DM thread key contract** (cross-language invariant): a Direct Message thread is buffered locally under `dm:{peer_id}` — never sent over the wire, each side derives it locally from the peer id it already knows. Implemented independently on both sides of the FFI boundary since the convention can't be shared code: `DmThreadKey` in `patch-core/src/dm.rs` (Rust) and `DmThread` in `patch_app/lib/models/dm_thread.dart` (Dart). A change to the `dm:` prefix or key shape must update both — there is no compiler check across the boundary, only this documented contract and each side's own test that a DM key is never a valid Channel id.

**ALL**:
A one-shot send to all channels simultaneously — not a persistent selection. Snaps back to the previous channel state after sending.
_Avoid_: All-call, broadcast, global send

**Static Peer**:
A Peer configured manually by IP address rather than discovered automatically. Used for devices at known fixed addresses on the network.
_Avoid_: Manual peer, fixed peer, pinned peer

**Show File**:
A saved configuration for a specific production or venue — channels and optionally static peers. Loaded at the start of a run.
_Avoid_: Session, preset, config, profile

**Pinned Network**:
The single network an Operator confines Patch to via Settings → Network. Pinning is mandatory — dynamic discovery and traffic are always confined to the pinned network; Static Peers are the deliberate exception. No pin means unresolved: dynamic discovery is fully inert (nothing sent or received) until one is chosen, either automatically on first run (when only one network is usable) or manually in Settings.
_Avoid_: Interface filter, network lock, bound interface, Auto


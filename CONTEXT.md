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
A one-touch callout with its content, channel, priority, and action type (text message, OSC message, etc.) preset. Fired instantly during a production without composing or deciding.
_Avoid_: Shortcut, template, preset, button

**Production**:
The live event being executed — a theatre show, broadcast, corporate AV event, touring date, etc. The bounded context within which all Patch communication takes place.
_Avoid_: Show, gig, event, job

**Direct Message**:
A 1:1 message thread between the local Operator and a specific Peer — outside of any Channel. Keyed per peer; persists while the app is open.
_Avoid_: Private message, private line, whisper, DM thread

**ALL**:
A one-shot send to all channels simultaneously — not a persistent selection. Snaps back to the previous channel state after sending.
_Avoid_: All-call, broadcast, global send

**Static Peer**:
A Peer configured manually by IP address rather than discovered automatically. Used for devices at known fixed addresses on the network.
_Avoid_: Manual peer, fixed peer, pinned peer

**Show File**:
A saved configuration for a specific production or venue — channels and optionally static peers. Loaded at the start of a run.
_Avoid_: Session, preset, config, profile


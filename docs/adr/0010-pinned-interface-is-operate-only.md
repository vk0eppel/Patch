# A pinned interface is operate-only, not announce-only

Pinning the network interface (Settings → Network, config `network_interface`) originally scoped **outbound discovery only**: the beacon went out on the pinned interface, but the socket stayed bound to `0.0.0.0`, inbound presence from any network was accepted with its foreign source address recorded, and unicast then fanned out to every recorded address (ADR-0007). The docs promised exactly this — "Patch always listens on every interface; this just scopes the beacon." Operators found it surprising: pin to the show VLAN, still see peers from venue Wi-Fi.

We decided pinning now means **operate only here**. While pinned, any inbound packet whose source is neither on the pinned interface's subnet nor a configured Static Peer address is dropped **whole** at the protocol inbound boundary — no peer sighting, no message, no Flash, no DM. Auto mode (`network_interface = None`) is untouched.

Three sub-decisions, each the result of a real trade-off:

1. **Static Peers are exempt.** Show networks are often routed: a Peer on the lighting VLAN is genuinely reachable from the pinned show-control VLAN through a router, and its packets arrive with an off-subnet source. Strict filtering would sever exactly the setups Static Peers exist for. Isolation therefore reads as: *dynamic discovery is confined to the Pinned Network; anything beyond it must be configured deliberately.*

2. **Whole-packet, not sightings-only.** Filtering only address recording would leave message handling running — you'd read Channel messages from a Peer who isn't in your peers panel. One check at the protocol entry keeps peers, messages, DMs, Flashes, and ACKs from off-pin networks ceasing together: one seam, one test surface.

3. **The accepted failure mode is silent invisibility, remedied by log + docs.** A crew laptop on the wrong VLAN simply doesn't appear. A rate-limited engine log line names each ignored source, and troubleshooting.md tells the Operator what to check. A UI counter ("N peers ignored") was considered and deliberately skipped — live UI state fed from the drop path wasn't worth the surface.

This **refines rather than contradicts ADR-0007**: the multi-address Peer model and multi-path delivery stay exactly as designed; the address universe is subnet-scoped while pinned. It also closes an asymmetry ADR-0007 left open — mDNS-resolved addresses were already subnet-filtered while pinned (`pick_resolved_addresses`), but OSC-presence addresses were not; both discovery paths now share one policy.

## Considered options

- **Keep announce-only (status quo)**: a presence packet that arrived proves a working path, and dropping proven paths reduces reliability mid-show. Rejected: the operator's mental model of "pin to this network" is confinement, and the routed-network reliability case is served by the Static Peer exemption.
- **Both, via a separate strict/isolation toggle**: most flexible, rejected — a second setting whose failure mode is invisible peers is hard to debug at 7pm before doors.
- **Sightings-only filtering**: rejected for the ghost-sender state (messages rendering from a Peer the panel doesn't show).

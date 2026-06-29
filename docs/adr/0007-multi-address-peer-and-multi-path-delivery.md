# Multi-address peer model and multi-path delivery

A venue running Patch across multiple L3 segments (show-control VLAN, Dante, crew Wi-Fi) has machines with NICs on several of those segments simultaneously. The previous model stored one `address: String` per Peer — presence heartbeats arriving from different source IPs on different interfaces raced to overwrite each other, and any unicast send could silently use a dead path if the winning address happened to be on a down interface.

We decided: a `Peer` holds `addresses: HashMap<SocketAddr, DateTime<Utc>>` — every reachable path to that peer, each with its own last-seen timestamp. `record_sighting` adds to this map rather than overwriting. Peer-level liveness classification (`Online`/`Stale`/`Offline`, driven by the single per-peer `last_seen`) is unchanged; per-address timestamps serve a different question — "is this path still usable?" — and addresses not seen within 3× the heartbeat interval are pruned silently. Peer status stays green while dead paths are quietly dropped.

Sending to all of a peer's addresses (broadcast + unicast heartbeat, channel messages, Critical messages) replaces single-address unicast. Because the same packet now arrives via multiple paths, a global LRU dedup cache (10-second TTL, keyed by `message_id`) in the protocol handler silently drops duplicates before they reach channel or DM state. For sends that require exactly one target (DM, DM flash, `/patch/channels/request`) the most-recently-seen address is used. `/patch/bye` on shutdown is sent to all known addresses so departure is signalled regardless of which path is active.

ACK matching changed as a consequence: `ReliabilityManager` previously keyed pending ACKs by source `SocketAddr`, which breaks when a receiver ACKs from a different address than the one the Critical message was sent to. `/patch/ack` now carries a `peer_id` field; the reliability manager tracks `(message_id, peer_id)` instead.

Auto mode (`network_interface = None`) no longer calls `clear_dynamic()` on any interface-topology change — the per-address prune window makes that unnecessary and a full clear would discard valid peer state on the other interfaces.

## Considered options

- **Single address, smarter selection** (prefer same-subnet address): simpler model but a dead path isn't detected until the peer itself goes Offline, and routing heuristics are fragile across VPN/VLAN configurations that venues don't document.
- **Per-interface address table** (`HashMap<InterfaceName, SocketAddr>`): more precise routing but makes sends load-bearing on interface name stability, which varies across platforms and during DHCP renewal.
- **ACK match by reverse SocketAddr lookup**: no wire change, but makes the address map load-bearing for ACK correctness — a pruned address would silently drop an in-flight ACK.

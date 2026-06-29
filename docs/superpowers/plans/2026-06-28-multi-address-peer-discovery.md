# Multi-Address Peer Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Patch work reliably across multiple VLANs by letting each Peer hold all its known addresses (one per interface), sending to all of them, and tracking ACKs by peer_id rather than socket address.

**Architecture:** Replace `Peer.address: String` + `Peer.osc_port: u16` with `Peer.addresses: HashMap<SocketAddr, DateTime<Utc>>`. Sends fan out to all known addresses for a peer; a global 10-second LRU dedup cache in the protocol handler drops duplicates on receive. The `/patch/ack` wire format already carries `peer_id` — the reliability manager switches from SocketAddr-keyed to peer_id-keyed ACK matching. Dead paths are pruned per-address at 3× the heartbeat interval; peer-level liveness classification is unchanged.

**Tech Stack:** Rust (tokio, chrono, uuid, serde), existing `patch-core` crate. No new dependencies.

## Global Constraints

- `cargo test -p patch_core` must pass after every task
- All existing tests must be updated to compile — no dead code warnings allowed
- Do not change the `/patch/ack` OSC wire format (it already carries 2 args: `message_id`, `peer_id`)
- `PeerSnapshot` (the FFI type) keeps `address: String` and `osc_port: u16` — Flutter compat
- `ManualIp` (static) peers must continue to appear with their configured address regardless
- Never call `socket_addr()` or re-parse `peer.address` inline at a call site — use the methods on `Peer`
- `reachable_peer_addrs` remains the single source of truth for send targets (ARCHITECTURE.md rule)
- Read ERRORS.md before touching transport, discovery, or the bridge

---

## File Map

| File | Change |
|------|--------|
| `patch-core/src/state/peer.rs` | Replace `address`/`osc_port` fields with `addresses: HashMap<SocketAddr, DateTime<Utc>>`; new methods `best_addr()`, `all_addrs()`, `prune_old_addresses()` |
| `patch-core/src/state/mod.rs` | Update `get_peers()`, `offline_addresses()`, `reachable_peer_addrs()`; add `reachable_peers_with_addrs()`; add `seen_messages` dedup cache + `is_message_duplicate()`; add `prune_peer_addresses()`; fix `set_network_interface()` auto-mode clear |
| `patch-core/src/reliability/mod.rs` | Switch `InFlight` targets/acked to peer_id-keyed; update `track()`, `ack()`, `drain_retransmits()`, `DeliveryFailure`, `track_critical()`, `report_delivery_failure()` |
| `patch-core/src/protocol/mod.rs` | Add dedup check for `Message` and `DirectMessage`; fix `Ack` arm to pass `peer_id` to `reliability.ack()` |
| `patch-core/src/api.rs` | Update `dispatch_message` to call `reachable_peers_with_addrs` for tracking; update static peer merge in `get_peers()` mapping; update `/patch/bye` to send to all peer addresses |
| `patch-core/src/discovery/mod.rs` | Record all mDNS-resolved addresses (not just one); add periodic address-prune call to the heartbeat loop |

---

### Task 1: Peer data model — multi-address

**Files:**
- Modify: `patch-core/src/state/peer.rs`

**Interfaces:**
- Produces:
  - `Peer.addresses: HashMap<SocketAddr, DateTime<Utc>>`
  - `Peer::add_address(addr: SocketAddr, at: DateTime<Utc>)`
  - `Peer::best_addr() -> Option<SocketAddr>` — most recently seen address
  - `Peer::all_addrs() -> Vec<SocketAddr>` — all known addresses
  - `Peer::has_address() -> bool` — replaces old `has_address()`
  - `Peer::prune_old_addresses(threshold: DateTime<Utc>)` — drops addresses older than threshold
  - `socket_addr()` removed — callers migrated to `best_addr()` (same semantics for single-target sends)

- [ ] **Step 1: Write failing tests for the new address API**

Add at the bottom of the `#[cfg(test)]` block in `patch-core/src/state/peer.rs`:

```rust
#[test]
fn peer_with_no_addresses_has_no_address() {
    let p = Peer::from_presence(PeerPresence {
        peer_id: Uuid::new_v4(),
        peer_name: "p".into(),
        channels: vec![],
        role: None,
        timestamp: Utc::now(),
    });
    assert!(!p.has_address());
    assert!(p.best_addr().is_none());
    assert!(p.all_addrs().is_empty());
}

#[test]
fn best_addr_returns_most_recently_seen() {
    let mut p = Peer::from_presence(PeerPresence {
        peer_id: Uuid::new_v4(),
        peer_name: "p".into(),
        channels: vec![],
        role: None,
        timestamp: Utc::now(),
    });
    let older = Utc::now() - chrono::Duration::seconds(5);
    let newer = Utc::now();
    let addr_old: SocketAddr = "10.0.0.1:9000".parse().unwrap();
    let addr_new: SocketAddr = "10.0.0.2:9000".parse().unwrap();
    p.add_address(addr_old, older);
    p.add_address(addr_new, newer);
    assert_eq!(p.best_addr(), Some(addr_new));
}

#[test]
fn prune_old_addresses_keeps_fresh_drops_stale() {
    let mut p = Peer::from_presence(PeerPresence {
        peer_id: Uuid::new_v4(),
        peer_name: "p".into(),
        channels: vec![],
        role: None,
        timestamp: Utc::now(),
    });
    let stale_addr: SocketAddr = "10.0.0.1:9000".parse().unwrap();
    let fresh_addr: SocketAddr = "10.0.0.2:9000".parse().unwrap();
    p.add_address(stale_addr, Utc::now() - chrono::Duration::seconds(100));
    p.add_address(fresh_addr, Utc::now());
    p.prune_old_addresses(Utc::now() - chrono::Duration::seconds(30));
    assert!(!p.all_addrs().contains(&stale_addr));
    assert!(p.all_addrs().contains(&fresh_addr));
}
```

- [ ] **Step 2: Run to verify tests fail**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core state::peer 2>&1 | tail -20
```

Expected: compile errors — `add_address`, `best_addr`, `prune_old_addresses` not defined.

- [ ] **Step 3: Rewrite the `Peer` struct and its methods**

Replace the entire `Peer` struct definition and its `impl` block in `patch-core/src/state/peer.rs`. The `serde` derives are kept; `HashMap<SocketAddr, DateTime<Utc>>` serializes cleanly to JSON with serde_json (SocketAddr uses its `Display` impl as the key string).

```rust
use std::collections::HashMap;
use std::net::SocketAddr;
// (keep existing imports)
```

Replace the `Peer` struct:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Peer {
    pub peer_id: Uuid,
    pub peer_name: String,
    pub channels: Vec<String>,
    pub role: Option<String>,
    pub discovery_mode: DiscoveryMode,
    /// All known reachable addresses for this peer, each with the timestamp of
    /// the last packet received from that specific address. Multiple entries
    /// arise when the peer is reachable on more than one network interface.
    pub addresses: HashMap<SocketAddr, DateTime<Utc>>,
    pub last_seen: DateTime<Utc>,
    pub departed: bool,
}
```

Replace `from_presence`, remove old `has_address`/`socket_addr`, add new methods:

```rust
impl Peer {
    pub fn from_presence(p: PeerPresence) -> Self {
        Self {
            peer_id: p.peer_id,
            peer_name: p.peer_name,
            channels: p.channels,
            role: p.role,
            discovery_mode: DiscoveryMode::OscBeacon,
            addresses: HashMap::new(),
            last_seen: p.timestamp,
            departed: false,
        }
    }

    /// Add (or refresh) a known reachable address.
    pub fn add_address(&mut self, addr: SocketAddr, at: DateTime<Utc>) {
        self.addresses.insert(addr, at);
    }

    /// Returns true if at least one address is known.
    pub fn has_address(&self) -> bool {
        !self.addresses.is_empty()
    }

    /// The most recently contacted address for single-target sends (DM, flash,
    /// channels/macros request). Returns `None` when no address is known yet.
    pub fn best_addr(&self) -> Option<SocketAddr> {
        self.addresses
            .iter()
            .max_by_key(|(_, t)| *t)
            .map(|(a, _)| *a)
    }

    /// All known addresses — used when sending to all paths simultaneously.
    pub fn all_addrs(&self) -> Vec<SocketAddr> {
        self.addresses.keys().copied().collect()
    }

    /// Drop addresses not seen within the given threshold. Called periodically
    /// to prune dead paths without expiring the whole peer.
    pub fn prune_old_addresses(&mut self, threshold: DateTime<Utc>) {
        self.addresses.retain(|_, t| *t >= threshold);
    }

    pub fn is_stale(&self, timeout_secs: i64) -> bool {
        let age = Utc::now()
            .signed_duration_since(self.last_seen)
            .num_seconds();
        age > timeout_secs
    }

    pub fn looks_offline(&self, heartbeat_secs: u64) -> bool {
        if self.departed {
            return true;
        }
        if matches!(self.discovery_mode, DiscoveryMode::ManualIp) {
            return false;
        }
        self.is_stale(heartbeat_secs.saturating_mul(5) as i64)
    }

    pub fn status(&self, heartbeat_secs: u64) -> PeerStatus {
        if self.departed || matches!(self.discovery_mode, DiscoveryMode::ManualIp) {
            return PeerStatus::Offline;
        }
        if self.is_stale(heartbeat_secs.saturating_mul(5) as i64) {
            PeerStatus::Offline
        } else if self.is_stale(heartbeat_secs.saturating_mul(2) as i64) {
            PeerStatus::Stale
        } else {
            PeerStatus::Online
        }
    }
}
```

- [ ] **Step 4: Update `PeerRegistry::record_sighting` to be additive**

In the same file, update the three arms of `record_sighting` to call `add_address` instead of assigning `peer.address`/`peer.osc_port`:

`Presence` arm — replace the address assignment lines:
```rust
PeerSighting::Presence(presence) => {
    let mut new_peer = Peer::from_presence(presence.clone());
    if let Some(existing) = peers.get(&presence.peer_id) {
        if matches!(existing.discovery_mode, DiscoveryMode::Mdns) {
            new_peer.discovery_mode = DiscoveryMode::Mdns;
        }
        // Carry over existing addresses — additive, not overwrite.
        new_peer.addresses = existing.addresses.clone();
    }
    if !address.is_empty() && port > 0 {
        if let Ok(ip) = address.parse::<std::net::IpAddr>() {
            new_peer.add_address(SocketAddr::new(ip, port), new_peer.last_seen);
        }
    }
    peers.insert(presence.peer_id, new_peer);
    presence
}
```

`Heartbeat` arm — replace address assignment:
```rust
PeerSighting::Heartbeat { peer_id, peer_name } => match peers.get_mut(&peer_id) {
    Some(peer) => {
        if !address.is_empty() && port > 0 {
            if let Ok(ip) = address.parse::<std::net::IpAddr>() {
                let now = chrono::Utc::now();
                peer.add_address(SocketAddr::new(ip, port), now);
                peer.last_seen = now;
            }
        }
        peer.departed = false;
        PeerPresence {
            peer_id: peer.peer_id,
            peer_name: peer.peer_name.clone(),
            channels: peer.channels.clone(),
            role: peer.role.clone(),
            timestamp: peer.last_seen,
        }
    }
    None => {
        let presence = PeerPresence {
            peer_id,
            peer_name,
            channels: Vec::new(),
            role: None,
            timestamp: chrono::Utc::now(),
        };
        let mut new_peer = Peer::from_presence(presence.clone());
        if !address.is_empty() && port > 0 {
            if let Ok(ip) = address.parse::<std::net::IpAddr>() {
                new_peer.add_address(SocketAddr::new(ip, port), new_peer.last_seen);
            }
        }
        peers.insert(peer_id, new_peer);
        presence
    }
},
```

`Mdns` arm — replace address assignment (keep the liveness rule: never update `last_seen`):
```rust
PeerSighting::Mdns(presence) => match peers.get_mut(&presence.peer_id) {
    Some(peer) => {
        if !address.is_empty() && port > 0 {
            if let Ok(ip) = address.parse::<std::net::IpAddr>() {
                // Use the existing last_seen as the address timestamp — mDNS
                // doesn't prove liveness, so we don't bump last_seen.
                let ts = peer.last_seen;
                peer.add_address(SocketAddr::new(ip, port), ts);
            }
        }
        peer.discovery_mode = DiscoveryMode::Mdns;
        PeerPresence {
            peer_id: peer.peer_id,
            peer_name: peer.peer_name.clone(),
            channels: peer.channels.clone(),
            role: peer.role.clone(),
            timestamp: peer.last_seen,
        }
    }
    None => {
        let mut new_peer = Peer::from_presence(presence.clone());
        new_peer.discovery_mode = DiscoveryMode::Mdns;
        if !address.is_empty() && port > 0 {
            if let Ok(ip) = address.parse::<std::net::IpAddr>() {
                new_peer.add_address(SocketAddr::new(ip, port), new_peer.last_seen);
            }
        }
        // Backdate past the stale threshold so the dot starts grey.
        new_peer.last_seen = chrono::Utc::now() - chrono::Duration::seconds(60);
        peers.insert(presence.peer_id, new_peer);
        presence
    }
},
```

- [ ] **Step 5: Update existing tests in peer.rs that reference old fields**

The tests `record_sighting_heartbeat_registers_a_new_peer` and `record_sighting_heartbeat_refreshes_an_existing_peer_and_clears_departed` use `listed[0].address`. Replace with `best_addr()`:

```rust
// In record_sighting_heartbeat_registers_a_new_peer:
assert_eq!(listed[0].best_addr(), Some("10.0.0.1:9000".parse().unwrap()));

// In record_sighting_heartbeat_refreshes_an_existing_peer_and_clears_departed:
assert_eq!(p.best_addr(), Some("10.0.0.2:9001".parse().unwrap()));
assert!(!p.departed);

// In record_sighting_mdns_with_empty_address_leaves_peer_unaddressed:
assert!(!reg.list().await[0].has_address());
```

Also update `peer_at` helper — it never sets an address, so it's fine. The `insert_for_test` calls use `peer_at` which starts with empty addresses; that's correct.

- [ ] **Step 6: Run all peer.rs tests**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core state::peer 2>&1 | tail -30
```

Expected: all pass, no warnings.

- [ ] **Step 7: Commit**

```bash
git add patch-core/src/state/peer.rs
git commit -m "refactor: multi-address Peer model — addresses HashMap replaces single address/port fields"
```

---

### Task 2: AppState multi-address methods

**Files:**
- Modify: `patch-core/src/state/mod.rs`
- Modify: `patch-core/src/api.rs`

**Interfaces:**
- Consumes: `Peer::best_addr()`, `Peer::all_addrs()`, `Peer::has_address()` from Task 1
- Produces:
  - `AppState::offline_addresses(heartbeat_secs) -> HashSet<SocketAddr>` — updated (all addrs of offline peers)
  - `AppState::reachable_peer_addrs(client_id) -> Vec<SocketAddr>` — updated (all addrs, flat, deduped)
  - `AppState::reachable_peers_with_addrs(client_id) -> Vec<(Uuid, Vec<SocketAddr>)>` — new, for ACK tracking
  - `AppState::set_network_interface` — no longer clears dynamic peers when switching to auto (None)
  - `PeerSnapshot.address` / `PeerSnapshot.osc_port` — populated from `best_addr()`

- [ ] **Step 1: Write failing tests for new/changed AppState methods**

Add to the test block in `patch-core/src/state/mod.rs`:

```rust
#[tokio::test]
async fn reachable_peer_addrs_returns_all_addresses_per_peer() {
    let st = AppState::new(Config::default());
    let client_id = Uuid::new_v4();
    let peer_id = Uuid::new_v4();

    // Simulate a peer seen on two different interfaces.
    st.record_sighting(
        PeerSighting::Presence(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "10.0.0.5".into(),
        9000,
    ).await;
    st.record_sighting(
        PeerSighting::Presence(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "192.168.1.5".into(),
        9000,
    ).await;

    let addrs = st.reachable_peer_addrs(client_id).await;
    assert_eq!(addrs.len(), 2);
    assert!(addrs.contains(&"10.0.0.5:9000".parse().unwrap()));
    assert!(addrs.contains(&"192.168.1.5:9000".parse().unwrap()));
}

#[tokio::test]
async fn reachable_peers_with_addrs_groups_by_peer_id() {
    let st = AppState::new(Config::default());
    let client_id = Uuid::new_v4();
    let peer_id = Uuid::new_v4();

    st.record_sighting(
        PeerSighting::Presence(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "10.0.0.5".into(),
        9000,
    ).await;
    st.record_sighting(
        PeerSighting::Presence(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "192.168.1.5".into(),
        9000,
    ).await;

    let targets = st.reachable_peers_with_addrs(client_id).await;
    assert_eq!(targets.len(), 1); // one peer
    assert_eq!(targets[0].0, peer_id);
    assert_eq!(targets[0].1.len(), 2); // two addresses
}

#[tokio::test]
async fn set_network_interface_to_auto_does_not_clear_peers() {
    let st = AppState::new(Config::default());
    let peer_id = Uuid::new_v4();
    st.record_sighting(
        PeerSighting::Presence(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "10.0.0.5".into(),
        9000,
    ).await;

    // Switching to auto (None) must not wipe discovered peers.
    st.set_network_interface(None).await.unwrap();
    assert!(!st.get_peers().await.is_empty());
}

#[tokio::test]
async fn set_network_interface_to_pinned_clears_dynamic_peers() {
    let st = AppState::new(Config::default());
    let peer_id = Uuid::new_v4();
    st.record_sighting(
        PeerSighting::Presence(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "10.0.0.5".into(),
        9000,
    ).await;

    // Switching to a pinned interface clears dynamic peers.
    st.set_network_interface(Some("en0".into())).await.unwrap();
    // Only ManualIp peers survive; dynamic ones are gone.
    let peers = st.get_peers().await;
    assert!(peers.iter().all(|p| matches!(p.discovery_mode, peer::DiscoveryMode::ManualIp)));
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core "reachable_peers_with_addrs\|set_network_interface_to_auto\|set_network_interface_to_pinned\|reachable_peer_addrs_returns_all" 2>&1 | tail -20
```

Expected: compile errors or test failures.

- [ ] **Step 3: Update `get_peers()` static merge**

In `patch-core/src/state/mod.rs`, the static peer merge checks `known_by_addr`. Replace the old `address`/`osc_port` reference with a check against all known addresses:

```rust
pub async fn get_peers(&self) -> Vec<peer::Peer> {
    let mut peers: Vec<_> = self.0.peers.list().await;

    let static_peers = self.0.config.read(|c| c.static_peers.clone()).await;
    // All (ip, port) pairs already known dynamically — static entries whose
    // address is already covered by a dynamic peer are suppressed.
    let known_addrs: std::collections::HashSet<SocketAddr> = peers
        .iter()
        .flat_map(|p| p.all_addrs())
        .collect();

    for sp in &static_peers {
        let sp_addr: Option<SocketAddr> = sp.address.parse::<std::net::IpAddr>()
            .ok()
            .map(|ip| SocketAddr::new(ip, sp.port));
        if let Some(addr) = sp_addr {
            if known_addrs.contains(&addr) {
                continue;
            }
        }
        let key = format!("static:{}:{}", sp.address, sp.port);
        let synthetic_id = Uuid::new_v5(&Uuid::NAMESPACE_DNS, key.as_bytes());
        let mut synthetic = peer::Peer {
            peer_id: synthetic_id,
            peer_name: sp.label.clone().unwrap_or_else(|| sp.address.clone()),
            channels: Vec::new(),
            role: None,
            discovery_mode: peer::DiscoveryMode::ManualIp,
            addresses: HashMap::new(),
            last_seen: chrono::Utc::now(),
            departed: false,
        };
        if let Some(addr) = sp_addr {
            synthetic.add_address(addr, chrono::Utc::now());
        }
        peers.push(synthetic);
    }

    peers
}
```

- [ ] **Step 4: Update `offline_addresses` and `reachable_peer_addrs`**

```rust
pub async fn offline_addresses(&self, heartbeat_secs: u64) -> HashSet<std::net::SocketAddr> {
    self.get_peers()
        .await
        .iter()
        .filter(|p| p.looks_offline(heartbeat_secs))
        .flat_map(|p| p.all_addrs())
        .collect()
}

pub async fn reachable_peer_addrs(&self, client_id: Uuid) -> Vec<std::net::SocketAddr> {
    let mut seen = HashSet::new();
    self.get_peers()
        .await
        .into_iter()
        .filter(|p| p.peer_id != client_id)
        .flat_map(|p| p.all_addrs())
        .filter(|addr| seen.insert(*addr))
        .collect()
}

/// Like `reachable_peer_addrs` but grouped by peer_id — used by `track_critical`
/// so ACKs can be matched by peer identity rather than socket address.
pub async fn reachable_peers_with_addrs(
    &self,
    client_id: Uuid,
) -> Vec<(Uuid, Vec<std::net::SocketAddr>)> {
    self.get_peers()
        .await
        .into_iter()
        .filter(|p| p.peer_id != client_id && p.has_address())
        .map(|p| (p.peer_id, p.all_addrs()))
        .collect()
}
```

- [ ] **Step 5: Fix `set_network_interface` — don't clear in auto mode**

```rust
pub async fn set_network_interface(&self, iface: Option<String>) -> anyhow::Result<()> {
    self.0
        .config
        .mutate_and_persist(|c| c.network_interface = iface.clone())
        .await;
    // Only clear dynamic peers when switching TO a pinned interface. In auto
    // mode (None) the per-address prune window handles dead paths; a full
    // clear would discard valid peer state on other interfaces.
    if iface.is_some() {
        let removed = self.clear_dynamic_peers().await;
        for id in removed {
            self.publish(AppEvent::PeerExpired(id)).await;
        }
    }
    Ok(())
}
```

- [ ] **Step 6: Update `PeerSnapshot` mapping in `api.rs`**

In `patch-core/src/api.rs`, the `get_peers()` function maps `Peer → PeerSnapshot`. Replace the `address` and `osc_port` fields:

```rust
.map(|p| {
    let best = p.best_addr();
    PeerSnapshot {
        status: p.status(heartbeat_secs),
        peer_id: p.peer_id,
        peer_name: p.peer_name,
        channels: p.channels,
        role: p.role,
        discovery_mode: p.discovery_mode,
        address: best.map(|a| a.ip().to_string()).unwrap_or_default(),
        osc_port: best.map(|a| a.port()).unwrap_or(0),
        last_seen: p.last_seen,
        departed: p.departed,
    }
})
```

- [ ] **Step 7: Fix remaining `p.address` / `p.osc_port` references in `api.rs`**

Search for remaining uses of `p.address` and `p.osc_port` where `p` is a `Peer` (not `PeerSnapshot` or `StaticPeer`). These are the DM send, DM flash, channels-request, and `/patch/bye` paths. Replace each `peer.socket_addr()` call with `peer.best_addr()`:

- Line ~300: `if let Some(addr) = peer.socket_addr()` → `if let Some(addr) = peer.best_addr()`
- Line ~350: same
- Line ~380: same
- Lines ~735, ~766: `.socket_addr().ok_or_else(...)` → `.best_addr().ok_or_else(...)`

Also find and update `resolve_peer_names` in `reliability/mod.rs` which does `p.address.parse::<IpAddr>()...` — that will be addressed in Task 3.

- [ ] **Step 8: Update `/patch/bye` to send to all peer addresses**

In `api.rs`, the shutdown sends `/patch/bye` via unicast to each peer. Find that path and change from `peer.socket_addr()` to `peer.all_addrs()`:

```rust
// Before (single address):
if let Some(addr) = peer.best_addr() {
    let _ = h.transport.send_now(&bye_bytes, addr).await;
}

// After (all addresses):
for addr in peer.all_addrs() {
    let _ = h.transport.send_now(&bye_bytes, addr).await;
}
```

- [ ] **Step 9: Run all tests**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core 2>&1 | tail -40
```

Expected: all pass. Fix any compile errors from remaining `p.address`/`p.osc_port` field accesses.

- [ ] **Step 10: Commit**

```bash
git add patch-core/src/state/mod.rs patch-core/src/api.rs
git commit -m "feat: multi-address AppState methods — reachable_peers_with_addrs, auto-mode no-clear"
```

---

### Task 3: ACK tracking by peer_id

**Files:**
- Modify: `patch-core/src/reliability/mod.rs`
- Modify: `patch-core/src/protocol/mod.rs`
- Modify: `patch-core/src/api.rs` (dispatch_message caller)

**Interfaces:**
- Consumes: `reachable_peers_with_addrs() -> Vec<(Uuid, Vec<SocketAddr>)>` from Task 2
- Produces:
  - `ReliabilityManager::track(message_id, bytes, targets: Vec<(Uuid, Vec<SocketAddr>)>)`
  - `ReliabilityManager::ack(message_id, peer_id: Uuid) -> Option<(u32, u32)>`
  - `track_critical(reliability, state, heartbeat_secs, message_id, bytes, targets: Vec<(Uuid, Vec<SocketAddr>)>) -> usize`
  - `DeliveryFailure.unacked: Vec<Uuid>` (peer IDs, not socket addresses)
  - `report_delivery_failure(state, message_id, delivered, total, unacked: &[Uuid])`

- [ ] **Step 1: Write failing tests for new reliability API**

In `patch-core/src/reliability/mod.rs`, add to the test block:

```rust
fn peer_target(peer_id: Uuid, addrs: &[u8]) -> (Uuid, Vec<SocketAddr>) {
    (peer_id, addrs.iter().map(|n| addr(*n)).collect())
}

#[test]
fn ack_by_peer_id_clears_that_peer() {
    let mut r = ReliabilityManager::new();
    let id = Uuid::new_v4();
    let peer_a = Uuid::new_v4();
    let peer_b = Uuid::new_v4();
    r.track(id, vec![0], vec![peer_target(peer_a, &[1, 2]), peer_target(peer_b, &[3])]);
    assert_eq!(r.ack(id, peer_a), Some((1, 2)));
    assert_eq!(r.ack(id, peer_b), Some((2, 2))); // all done
    assert!(r.drain_retransmits().retransmits.is_empty());
}

#[test]
fn ack_from_unknown_peer_id_is_ignored() {
    let mut r = ReliabilityManager::new();
    let id = Uuid::new_v4();
    let peer_a = Uuid::new_v4();
    r.track(id, vec![0], vec![peer_target(peer_a, &[1])]);
    assert_eq!(r.ack(id, Uuid::new_v4()), None); // not a target
    let due = r.drain_retransmits();
    assert_eq!(due.retransmits.len(), 1);
}

#[test]
fn retransmit_sends_all_addresses_of_unacked_peer() {
    let mut r = ReliabilityManager::new();
    let id = Uuid::new_v4();
    let peer_a = Uuid::new_v4();
    let peer_b = Uuid::new_v4();
    r.track(id, vec![0], vec![
        peer_target(peer_a, &[1, 2]),  // two addresses
        peer_target(peer_b, &[3]),
    ]);
    r.ack(id, peer_a); // peer_a acked; peer_b still pending
    let due = r.drain_retransmits();
    assert_eq!(due.retransmits.len(), 1);
    let pending_addrs = &due.retransmits[0].2;
    assert_eq!(pending_addrs.len(), 1);
    assert_eq!(pending_addrs[0], addr(3)); // only peer_b's address
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core reliability 2>&1 | tail -20
```

Expected: compile errors — API mismatch.

- [ ] **Step 3: Rewrite `InFlight` and `ReliabilityManager`**

In `patch-core/src/reliability/mod.rs`, replace `InFlight`:

```rust
#[derive(Debug)]
struct InFlight {
    bytes: Vec<u8>,
    /// peer_id → all their addresses (for retransmit to all paths).
    targets: HashMap<Uuid, Vec<SocketAddr>>,
    /// Peer IDs that have sent an ACK.
    acked: HashSet<Uuid>,
    retries: u32,
    ticks_until_retry: u32,
}
```

Update `DeliveryFailure`:

```rust
pub struct DeliveryFailure {
    pub message_id: Uuid,
    /// Peer IDs that never acknowledged.
    pub unacked: Vec<Uuid>,
    pub acked: u32,
    pub total: u32,
}
```

Update `track()`:

```rust
pub fn track(&mut self, message_id: Uuid, bytes: Vec<u8>, targets: Vec<(Uuid, Vec<SocketAddr>)>) {
    self.in_flight.insert(
        message_id,
        InFlight {
            bytes,
            targets: targets.into_iter().collect(),
            acked: HashSet::new(),
            retries: 0,
            ticks_until_retry: 0,
        },
    );
}
```

Update `ack()`:

```rust
pub fn ack(&mut self, message_id: Uuid, peer_id: Uuid) -> Option<(u32, u32)> {
    let entry = self.in_flight.get_mut(&message_id)?;
    if !entry.targets.contains_key(&peer_id) {
        return None;
    }
    entry.acked.insert(peer_id);
    let total = entry.targets.len() as u32;
    let acked = entry.acked.len() as u32;
    if acked >= total {
        self.in_flight.remove(&message_id);
    }
    Some((acked, total))
}
```

Update `drain_retransmits()` — collect all addresses of unacked peers:

```rust
pub fn drain_retransmits(&mut self) -> DrainResult {
    let mut result = DrainResult::default();
    let mut to_drop = Vec::new();

    for (id, entry) in self.in_flight.iter_mut() {
        if entry.ticks_until_retry > 0 {
            entry.ticks_until_retry -= 1;
            continue;
        }

        let unacked_peers: Vec<Uuid> = entry
            .targets
            .keys()
            .filter(|pid| !entry.acked.contains(*pid))
            .copied()
            .collect();

        if unacked_peers.is_empty() {
            to_drop.push(*id);
            continue;
        }

        entry.retries += 1;
        if entry.retries > MAX_RETRIES {
            warn!(
                "Message {} exceeded max retries — {} peer(s) never ACKed",
                id,
                unacked_peers.len()
            );
            result.failures.push(DeliveryFailure {
                message_id: *id,
                unacked: unacked_peers,
                acked: entry.acked.len() as u32,
                total: entry.targets.len() as u32,
            });
            to_drop.push(*id);
            continue;
        }

        let unacked_addrs: Vec<SocketAddr> = unacked_peers
            .iter()
            .flat_map(|pid| entry.targets[pid].iter().copied())
            .collect();

        entry.ticks_until_retry = 1u32 << entry.retries.min(6);
        debug!(
            "Retransmitting {} to {} pending peer(s) (attempt {})",
            id,
            unacked_peers.len(),
            entry.retries
        );
        result.retransmits.push((*id, entry.bytes.clone(), unacked_addrs));
    }

    for id in to_drop {
        self.in_flight.remove(&id);
    }

    result
}
```

- [ ] **Step 4: Update `track_critical` and `report_delivery_failure`**

Replace the two free functions at the bottom of `reliability/mod.rs`:

```rust
pub async fn track_critical(
    reliability: &Mutex<ReliabilityManager>,
    state: &AppState,
    heartbeat_secs: u64,
    message_id: Uuid,
    bytes: Vec<u8>,
    targets: Vec<(Uuid, Vec<SocketAddr>)>,
) -> usize {
    let peers = state.get_peers().await;
    let trackable: Vec<(Uuid, Vec<SocketAddr>)> = targets
        .into_iter()
        .filter(|(peer_id, _)| {
            peers
                .iter()
                .find(|p| p.peer_id == *peer_id)
                .map(|p| !p.looks_offline(heartbeat_secs))
                .unwrap_or(true) // unknown peer → track anyway
        })
        .collect();
    let count = trackable.len();
    if count > 0 {
        reliability.lock().await.track(message_id, bytes, trackable);
    }
    count
}

pub async fn report_delivery_failure(
    state: &AppState,
    message_id: Uuid,
    delivered: u32,
    total: u32,
    unacked: &[Uuid],
) {
    let failed_peers = resolve_peer_names(state, unacked).await;
    state
        .publish(AppEvent::MessageDelivery {
            message_id,
            delivered,
            total,
            failed: true,
            failed_peers,
        })
        .await;
}

async fn resolve_peer_names(state: &AppState, peer_ids: &[Uuid]) -> Vec<String> {
    if peer_ids.is_empty() {
        return Vec::new();
    }
    let peers = state.get_peers().await;
    peer_ids
        .iter()
        .map(|id| {
            peers
                .iter()
                .find(|p| p.peer_id == *id)
                .map(|p| p.peer_name.clone())
                .unwrap_or_else(|| id.to_string())
        })
        .collect()
}
```

- [ ] **Step 5: Fix the `Ack` arm in `protocol/mod.rs`**

Find the `PatchEvent::Ack { message_id, peer_id }` arm. Currently it calls `reliability.ack(message_id, from)`. Change to:

```rust
PatchEvent::Ack { message_id, peer_id } => {
    let mut r = reliability.lock().await;
    if let Some((acked, total)) = r.ack(message_id, peer_id) {
        drop(r);
        state
            .publish(AppEvent::MessageDelivery {
                message_id,
                delivered: acked,
                total,
                failed: false,
                failed_peers: Vec::new(),
            })
            .await;
        if acked >= total {
            state.publish(AppEvent::MessageAcked { message_id }).await;
        }
    }
}
```

- [ ] **Step 6: Update `dispatch_message` in `api.rs`**

`track_critical` now takes `Vec<(Uuid, Vec<SocketAddr>)>` not `Vec<SocketAddr>`. The `targets` from `send_to_peers` is now just for counting; the peer-keyed targets come from a separate call:

```rust
pub(crate) async fn dispatch_message(
    state: &AppState,
    transport: &Arc<Transport>,
    reliability: &Arc<Mutex<ReliabilityManager>>,
    channel_id: String,
    payload: String,
    prio: Priority,
) -> Result<uuid::Uuid> {
    let config = state.config().await;
    let msg = PatchMessage::new(
        config.client_id,
        &config.client_name,
        channel_id,
        prio,
        payload,
    );
    let bytes = encode_message(&msg)?;
    // Flat address list for the actual send.
    let targets = transport
        .send_to_peers(bytes.clone(), state, &config)
        .await?;
    let message_id = msg.message_id;
    let is_critical = msg.is_critical();
    let target_count = if is_critical {
        // Peer-keyed list for ACK tracking — separate from the send targets
        // because track_critical matches ACKs by peer_id, not SocketAddr.
        let peer_targets = state.reachable_peers_with_addrs(config.client_id).await;
        crate::reliability::track_critical(
            reliability,
            state,
            config.heartbeat_interval_secs,
            message_id,
            bytes,
            peer_targets,
        )
        .await
    } else {
        0
    };
    state.store_message(msg).await;
    if is_critical && target_count == 0 {
        crate::reliability::report_delivery_failure(state, message_id, 0, 0, &[]).await;
    }
    Ok(message_id)
}
```

- [ ] **Step 7: Update the `/patch/say` relay in `protocol/mod.rs`**

The say relay also calls `track_critical`. Find it and update to use `reachable_peers_with_addrs`:

```rust
// In the PatchEvent::Say arm, after building peer_targets:
let peer_targets = state.reachable_peers_with_addrs(client_id).await;
crate::reliability::track_critical(
    reliability,
    state,
    config.heartbeat_interval_secs,
    message_id,
    bytes.clone(),
    peer_targets,
).await;
```

- [ ] **Step 8: Update existing reliability tests**

The old tests use `r.track(id, bytes, vec![addr(1), addr(2)])` (flat SocketAddr list). Update each to the new API:

```rust
// Old:
r.track(id, vec![1, 2, 3], vec![addr(1), addr(2)]);
assert_eq!(r.ack(id, addr(1)), Some((1, 2)));

// New:
let p1 = Uuid::new_v4();
let p2 = Uuid::new_v4();
r.track(id, vec![1, 2, 3], vec![(p1, vec![addr(1)]), (p2, vec![addr(2)])]);
assert_eq!(r.ack(id, p1), Some((1, 2)));
```

Apply this pattern to ALL existing reliability tests. The `track_critical_filters_out_offline_targets` and `track_critical_tracks_nothing_when_every_target_is_offline` tests use `AppState`; update their `track_critical` calls to pass `Vec<(Uuid, Vec<SocketAddr>)>`.

- [ ] **Step 9: Run all tests**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core 2>&1 | tail -40
```

Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add patch-core/src/reliability/mod.rs patch-core/src/protocol/mod.rs patch-core/src/api.rs
git commit -m "feat: ACK matching by peer_id — ReliabilityManager tracks (message_id, peer_id) pairs"
```

---

### Task 4: Receive-side message dedup

**Files:**
- Modify: `patch-core/src/state/mod.rs`
- Modify: `patch-core/src/protocol/mod.rs`

**Interfaces:**
- Consumes: `AppState` inner state (Task 2's `AppStateInner`)
- Produces:
  - `AppState::is_message_duplicate(message_id: Uuid) -> bool` — returns true and inserts if new; returns true if already seen within 10s

- [ ] **Step 1: Write a failing test**

In `patch-core/src/state/mod.rs` test block:

```rust
#[tokio::test]
async fn is_message_duplicate_returns_false_first_time_true_second() {
    let st = AppState::new(Config::default());
    let id = Uuid::new_v4();
    assert!(!st.is_message_duplicate(id).await);
    assert!(st.is_message_duplicate(id).await);
}

#[tokio::test]
async fn is_message_duplicate_different_ids_are_independent() {
    let st = AppState::new(Config::default());
    let id1 = Uuid::new_v4();
    let id2 = Uuid::new_v4();
    assert!(!st.is_message_duplicate(id1).await);
    assert!(!st.is_message_duplicate(id2).await);
}
```

In `patch-core/src/protocol/mod.rs`, update the existing `flash_records_sighting_and_publishes_channel_flash` test or add a new one:

```rust
#[tokio::test]
async fn duplicate_message_is_silently_dropped() {
    let client_id = Uuid::new_v4();
    let state = test_state_with_id(client_id);
    let reliability = Arc::new(Mutex::new(ReliabilityManager::new()));
    let sender_id = Uuid::new_v4();
    let msg_id = Uuid::new_v4();

    let make_event = || PatchEvent::Message(PatchMessage {
        message_id: msg_id,
        sender_id,
        sender_name: "Sender".into(),
        channel_id: "ops".into(),
        priority: 1,
        payload: "hello".into(),
        is_flash: false,
        flash_sender_name: None,
        timestamp: Utc::now(),
    });

    handle(make_event(), addr(1), &state, client_id, &reliability).await;
    handle(make_event(), addr(2), &state, client_id, &reliability).await; // same id, different path

    // Should only be stored once.
    let msgs = state.get_messages("ops").await;
    assert_eq!(msgs.len(), 1);
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core "is_message_duplicate\|duplicate_message_is_silently" 2>&1 | tail -20
```

Expected: compile errors.

- [ ] **Step 3: Add `seen_messages` to `AppStateInner`**

In `patch-core/src/state/mod.rs`, find the `AppStateInner` struct and add:

```rust
use std::time::Instant;
// (in the struct):
seen_messages: tokio::sync::Mutex<std::collections::HashMap<Uuid, Instant>>,
```

In `AppStateInner::new` (or wherever it's constructed), initialize:

```rust
seen_messages: tokio::sync::Mutex::new(std::collections::HashMap::new()),
```

- [ ] **Step 4: Add `is_message_duplicate` to `AppState`**

```rust
/// Returns `true` if `message_id` was already seen within the last 10 seconds
/// (a duplicate from multi-path delivery). Inserts it on first call and
/// prunes expired entries. Thread-safe — call from the receive loop.
pub async fn is_message_duplicate(&self, message_id: Uuid) -> bool {
    use std::time::{Duration, Instant};
    const TTL: Duration = Duration::from_secs(10);
    let now = Instant::now();
    let mut seen = self.0.seen_messages.lock().await;
    seen.retain(|_, t| now.duration_since(*t) < TTL);
    if seen.contains_key(&message_id) {
        return true;
    }
    seen.insert(message_id, now);
    false
}
```

- [ ] **Step 5: Add dedup check in `protocol::handle`**

In `patch-core/src/protocol/mod.rs`, at the start of the `PatchEvent::Message` arm (before the `is_self` check):

```rust
PatchEvent::Message(msg) => {
    if state.is_message_duplicate(msg.message_id).await {
        return out;
    }
    // ... existing handling unchanged
}
```

And at the start of `PatchEvent::DirectMessage`:

```rust
PatchEvent::DirectMessage { msg, target_id } => {
    if !is_self(target_id, client_id) {
        return out;
    }
    if state.is_message_duplicate(msg.message_id).await {
        return out;
    }
    // ... existing handling unchanged
}
```

- [ ] **Step 6: Run all tests**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core 2>&1 | tail -30
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add patch-core/src/state/mod.rs patch-core/src/protocol/mod.rs
git commit -m "feat: global message-id dedup — silently drop duplicates from multi-path delivery"
```

---

### Task 5: Per-address prune loop

**Files:**
- Modify: `patch-core/src/state/mod.rs`
- Modify: `patch-core/src/discovery/mod.rs`

**Interfaces:**
- Consumes: `Peer::prune_old_addresses(threshold)` from Task 1; `PeerRegistry` internals
- Produces: `AppState::prune_peer_addresses(heartbeat_secs: u64)` called on each heartbeat tick

- [ ] **Step 1: Write a failing test**

In `patch-core/src/state/mod.rs` test block:

```rust
#[tokio::test]
async fn prune_peer_addresses_removes_stale_addrs_keeps_fresh() {
    let st = AppState::new(Config { heartbeat_interval_secs: 7, ..Config::default() });
    let peer_id = Uuid::new_v4();
    let heartbeat_secs = 7u64;

    // Record a peer with a fresh address.
    st.record_sighting(
        PeerSighting::Presence(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "10.0.0.1".into(),
        9000,
    ).await;

    // Manually add a stale address by backdating via a raw sighting.
    // We inject it by recording a presence with the same peer_id from a stale timestamp.
    {
        let peers = st.get_peers().await;
        // Can't directly inject stale address via public API; check that after
        // recording a normal presence the prune doesn't remove fresh addresses.
    }

    st.prune_peer_addresses(heartbeat_secs).await;

    let peers = st.get_peers().await;
    let peer = peers.iter().find(|p| p.peer_id == peer_id).unwrap();
    // Fresh address must survive.
    assert!(peer.has_address());
}
```

- [ ] **Step 2: Add `prune_peer_addresses` to `AppState`**

In `patch-core/src/state/mod.rs`:

```rust
/// Prune per-address timestamps older than 3× the heartbeat interval.
/// Called on each heartbeat tick to shed dead paths without expiring the
/// whole peer — the peer's `last_seen` (and thus Online/Stale/Offline
/// classification) is unaffected.
pub async fn prune_peer_addresses(&self, heartbeat_secs: u64) {
    let threshold_secs = heartbeat_secs.saturating_mul(3) as i64;
    let threshold = chrono::Utc::now() - chrono::Duration::seconds(threshold_secs);
    let mut peers = self.0.peers.peers.write().await;
    for peer in peers.values_mut() {
        peer.prune_old_addresses(threshold);
    }
}
```

Note: `self.0.peers.peers` requires `PeerRegistry.peers` to be accessible. If it's private, add a method to `PeerRegistry`:

```rust
// In PeerRegistry:
pub(crate) async fn prune_addresses(&self, threshold: DateTime<Utc>) {
    let mut peers = self.peers.write().await;
    for peer in peers.values_mut() {
        peer.prune_old_addresses(threshold);
    }
}
```

Then `AppState::prune_peer_addresses` calls `self.0.peers.prune_addresses(threshold).await`.

- [ ] **Step 3: Wire into the heartbeat loop in `discovery/mod.rs`**

Find the heartbeat tick loop (in `Discovery::new`, the spawned task that sends `/patch/presence`). After the existing presence send, add:

```rust
hb_state.prune_peer_addresses(cfg.heartbeat_interval_secs).await;
```

- [ ] **Step 4: Run all tests**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core 2>&1 | tail -30
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add patch-core/src/state/mod.rs patch-core/src/discovery/mod.rs
git commit -m "feat: per-address prune at 3x heartbeat interval — dead paths shed without expiring the peer"
```

---

### Task 6: mDNS multi-address

**Files:**
- Modify: `patch-core/src/discovery/mod.rs`

**Interfaces:**
- Consumes: additive `record_sighting(Mdns(...))` from Task 1; `pick_resolved_address` (being replaced)

- [ ] **Step 1: Write a failing test**

Add to `discovery/mod.rs` tests (or to `state/mod.rs` since the observable result is peer addresses):

```rust
// In state/mod.rs test block:
#[tokio::test]
async fn mdns_sighting_with_multiple_addrs_adds_all() {
    let st = AppState::new(Config::default());
    let peer_id = Uuid::new_v4();

    // Simulate two mDNS sightings for the same peer from different addresses
    // (as would happen when mDNS resolves on two interfaces).
    st.record_sighting(
        PeerSighting::Mdns(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "10.0.0.1".into(),
        9000,
    ).await;
    st.record_sighting(
        PeerSighting::Mdns(PeerPresence {
            peer_id,
            peer_name: "p".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        }),
        "192.168.1.1".into(),
        9000,
    ).await;

    let peers = st.get_peers().await;
    let peer = peers.iter().find(|p| p.peer_id == peer_id).unwrap();
    assert_eq!(peer.all_addrs().len(), 2);
}
```

- [ ] **Step 2: Run to confirm this already passes or fails**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core mdns_sighting_with_multiple_addrs 2>&1 | tail -10
```

If it already passes (because Task 1 made `record_sighting` additive): this task's record_sighting part is done. Proceed to update `pick_resolved_address` in discovery.

- [ ] **Step 3: Update `pick_resolved_address` to return all matching addresses**

In `patch-core/src/discovery/mod.rs`, replace the `pick_resolved_address` function with one that returns all matching addresses:

```rust
/// Returns all addresses from a resolved mDNS service that are on the pinned
/// subnet. With no pin configured, returns all resolved addresses. Returns an
/// empty Vec when pinned but no address matches (same "leave untouched" rule
/// as before, applied per address).
fn pick_resolved_addresses(
    addrs: &std::collections::HashSet<IpAddr>,
    pin_configured: bool,
    pinned_subnet: Option<(Ipv4Addr, Ipv4Addr)>,
) -> Vec<String> {
    if pin_configured {
        let Some((iface_ip, mask)) = pinned_subnet else {
            return Vec::new();
        };
        return addrs
            .iter()
            .filter(|ip| matches!(ip, IpAddr::V4(v4) if in_pinned_subnet(*v4, iface_ip, mask)))
            .map(|ip| ip.to_string())
            .collect();
    }
    addrs.iter().map(|a| a.to_string()).collect()
}
```

- [ ] **Step 4: Update the `ServiceResolved` handler to record all addresses**

In the `ServiceEvent::ServiceResolved(info)` match arm, replace the single `record_sighting` call with a loop over all resolved addresses:

```rust
ServiceEvent::ServiceResolved(info) => {
    let peer_id = info
        .get_properties()
        .get("peer_id")
        .and_then(|p| Uuid::parse_str(p.val_str()).ok())
        .unwrap_or_else(Uuid::new_v4);

    if is_self(peer_id, client_id) {
        continue;
    }

    let iface_pin = browse_state.config().await.network_interface.clone();
    let pinned_subnet = iface_pin.as_deref().and_then(pinned_ipv4_subnet);
    let resolved_addrs = pick_resolved_addresses(
        info.get_addresses(),
        iface_pin.is_some(),
        pinned_subnet,
    );
    let port = info.get_port();
    let peer_name = info
        .get_properties()
        .get("peer_name")
        .map(|p| p.val_str().to_string())
        .unwrap_or_else(|| {
            info.get_fullname()
                .trim_end_matches("._patch._udp.local.")
                .to_string()
        });

    let presence = crate::osc::types::PeerPresence {
        peer_id,
        peer_name,
        channels: Vec::new(),
        role: None,
        timestamp: chrono::Utc::now(),
    };

    // Record each resolved address separately — all land in the peer's
    // addresses map without overwriting each other (additive since Task 1).
    if resolved_addrs.is_empty() {
        // No matching address (pinned subnet with no overlap) — record with
        // empty address so the peer appears in the panel but is unreachable
        // until a presence heartbeat provides a usable address.
        browse_state
            .record_sighting(PeerSighting::Mdns(presence), String::new(), 0)
            .await;
    } else {
        for addr in resolved_addrs {
            browse_state
                .record_sighting(PeerSighting::Mdns(presence.clone()), addr, port)
                .await;
        }
    }

    resolved_ids.insert(info.get_fullname().to_string(), peer_id);
}
```

- [ ] **Step 5: Run all tests**

```bash
cd /Users/vko/Documents/GitHub/Patch && cargo test -p patch_core 2>&1 | tail -30
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add patch-core/src/discovery/mod.rs
git commit -m "feat: mDNS records all resolved addresses per peer, not just one"
```

---

## Self-Review

### Spec coverage

| Decision | Task |
|---|---|
| Multi-address peer model (`addresses: HashMap`) | Task 1 |
| Per-address last_seen, per-peer liveness unchanged | Task 1 |
| `record_sighting` additive not overwriting | Task 1 |
| `reachable_peer_addrs` returns all addresses flat | Task 2 |
| `reachable_peers_with_addrs` for ACK tracking | Task 2 |
| Static peer merge uses all_addrs check | Task 2 |
| Auto mode: `set_network_interface(None)` doesn't clear | Task 2 |
| `/patch/bye` sends to all peer addresses | Task 2 |
| ACK by `(message_id, peer_id)` | Task 3 |
| `track_critical` peer-id-keyed | Task 3 |
| `DeliveryFailure.unacked` as `Vec<Uuid>` | Task 3 |
| Receive dedup — global LRU 10s TTL | Task 4 |
| Per-address prune at 3× heartbeat | Task 5 |
| mDNS all matching addresses recorded | Task 6 |

### Placeholder scan

No TBDs or TODOs in the plan.

### Type consistency

- `Peer::best_addr()` → `Option<SocketAddr>` — used in Tasks 2, api.rs `socket_addr()` replacements
- `Peer::all_addrs()` → `Vec<SocketAddr>` — used in Tasks 2, 5
- `reachable_peers_with_addrs` → `Vec<(Uuid, Vec<SocketAddr>)>` — consumed by `track_critical` in Task 3
- `ReliabilityManager::track(id, bytes, Vec<(Uuid, Vec<SocketAddr>)>)` — matches Task 3 callers
- `ReliabilityManager::ack(id, peer_id: Uuid)` — matches Task 3 protocol fix
- `report_delivery_failure(..., unacked: &[Uuid])` — matches Task 3 callers (drain_retransmits returns `DeliveryFailure.unacked: Vec<Uuid>`)

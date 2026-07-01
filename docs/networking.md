# Networking Guide

Patch is designed for live show networks — wired + Wi-Fi, multicast-enabled or AP-isolated, flat or VLAN-segmented. This page covers how discovery works and how to handle common show network scenarios.

---

## How peers find each other

Patch uses three discovery methods simultaneously. All three can be active at the same time.

| Method | How it works | Icon |
|---|---|---|
| **mDNS / Bonjour** | Registers a `_patch._udp.local.` service; other devices resolve it automatically | 🔍 |
| **OSC beacon** | Broadcasts a `/patch/presence` packet every 7 seconds on the LAN | 📡 |
| **Static IP** | Manually configured address:port entries that are always contacted | 📌 |

Peers appear in the **PEERS panel** with:
- 🟢 **Green dot** — heard from recently (within ~2× the heartbeat interval, ≈14 s at defaults)
- 🟡 **Amber dot** — going quiet (2–5× the interval, ≈14–35 s) — still remembered, just not answering
- ⚫ **Grey dot** — no recent activity (>35 s), departed cleanly, or manually configured (static IP)

Peers are remembered while the app is open and never auto-expire automatically. If a grey-dot peer sends or receives any message, their dot turns green immediately.

To clean up the list after a show or when moving between networks, tap the **👤 (person remove) button** in the PEERS panel header. This removes all grey-dot dynamic peers (mDNS / OSC beacon) that haven't been heard from in the last 60 seconds. Manually configured static peers are never removed by this action.

---

## Network interface selection

Patch **always listens on every interface**, so on most setups you can leave this on **Auto**. If your device has multiple NICs (e.g. Ethernet + Wi-Fi) and you want the discovery beacon announced on a specific one, go to **Settings → Network Interface** and select it. The change applies **within a few seconds — no restart needed**.

- **Auto** — announces discovery on every interface. Best for almost everything.
- **Named interface** — e.g. `en0` (Ethernet), `en1` (Wi-Fi). Scopes the discovery beacon to that one network (Patch still *listens* on all). Useful if you don't want Patch announcing itself on, say, a corporate VPN.

> **One-way discovery (A sees B, but B doesn't see A)?** This happens when the machine that *can't* be seen has its **default route on the wrong interface** — a VPN (`utun`), iCloud Private Relay, or Ethernet/dock alongside Wi-Fi — so on macOS its broadcast beacon only leaves that interface and never reaches the Wi-Fi.
> Patch now **self-heals** this: once one machine sees the other, it unicasts its heartbeat directly to that peer (unicast routes correctly regardless of the default route), so two-way visibility is restored within one heartbeat (~7 s). If it's still one-way after that, neither side ever made first contact — then:
> 1. **Disconnect the VPN / unplug the extra interface** so Wi-Fi is the default route (no Patch restart needed — it re-checks interfaces each heartbeat). Check with `route -n get default`.
> 2. **Add each machine as a static peer** of the other (Settings → Static Peers) — that gives the bootstrap its first contact, and unicast takes over from there.

> The NIC picker filters out loopback, virtual, and link-local-only interfaces automatically. Only real NICs with routable IPv4 addresses are shown.

---

## AP-isolated networks

Many venue Wi-Fi systems use **AP isolation** (also called "client isolation") — a security setting that prevents devices on the same SSID from talking directly to each other. This blocks both mDNS and OSC broadcast, so automatic discovery fails.

**Symptoms:** peers don't appear even though everyone is on the same Wi-Fi.

**Solution: static peers.** Go to **Settings → Static Peers → + Add peer** and enter the IP address and port (default 9000) of each device you want to reach. Patch will always unicast to static peers regardless of discovery state.

> Ask your network engineer to turn off AP isolation on the show SSID if possible — it's the cleanest fix and allows automatic discovery to work.

### Finding your IP address

- **macOS**: System Settings → Network → select your interface → IP address shown
- **Windows**: `ipconfig` in Terminal → look for your show NIC
- **iOS/iPad**: Settings → Wi-Fi → tap your network → IP Address
- **Patch Settings**: the static peer dialog shows a "This device" IP hint at the bottom

---

## VLAN-segmented networks

On large touring or broadcast setups, different departments may be on separate VLANs. OSC unicast (messages) can cross VLANs if routing is configured; broadcast (discovery beacons) cannot.

**Recommended setup for multi-VLAN environments:**
1. Configure static peers for every device on a different VLAN.
2. Ensure OSC port 9000 (or your configured port) is allowed in inter-VLAN routing rules.
3. mDNS will not cross VLANs without an mDNS proxy (e.g. Avahi, macOS `dns-sd` reflector).

---

## iOS and macOS Local Network permission

On iOS 14+ and macOS 12+, the OS requires explicit permission before an app can send or receive on the local network.

On first run, you'll see a prompt: **"Patch would like to find and connect to devices on your local network."** Tap **Allow**.

If you tapped **Don't Allow** by mistake:
- **iOS**: Settings → Privacy & Security → Local Network → enable Patch
- **macOS**: System Settings → Privacy & Security → Local Network → enable Patch

If Patch is blocked, a red notification banner will appear in the app.

---

## Port configuration

Patch listens on UDP port **9000** by default. All peers must use the same port.

To change the port: go to **Settings → Network → OSC port** and enter the new value — the socket rebinds live, no restart needed. You can also edit `patch.toml` directly:

```toml
osc_port = 9000   # Change here if needed
```

---

## Config file location

Patch stores its config in the platform data directory:

| Platform | Path |
|---|---|
| macOS (app) | `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Patch/patch.toml` |
| macOS (dev build) | `~/Library/Application Support/Patch/patch.toml` |
| Windows | `%APPDATA%\Patch\patch.toml` |
| Linux | `~/.local/share/Patch/patch.toml` |
| iOS | App sandbox (not directly accessible) |

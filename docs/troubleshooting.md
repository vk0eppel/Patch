# Troubleshooting

---

## No peers appearing in the peers panel

**1. Check that everyone is on the same network**
Patch uses UDP multicast/broadcast for discovery — peers must be reachable at the IP layer. Different subnets, VLANs without inter-VLAN routing, or separate Wi-Fi networks will all prevent discovery.

**2. AP isolation is enabled on your Wi-Fi**
Very common in venues. Devices on the same SSID can't talk directly. Fix: add static peers manually (**Settings → Static Peers**) using each device's IP and port 9000. See [Networking](networking.md#ap-isolated-networks).

**3. Check the network interface selection**
Go to **Settings → Network Interface**. If a specific NIC is selected, make sure it's the one connected to the show network. Try switching to **Auto** and restarting.

**4. Firewall blocking UDP port 9000**
Ensure inbound UDP port 9000 is open on each device:
- **macOS**: System Settings → Network → Firewall → allow Patch
- **Windows**: Windows Defender Firewall → Allow an app → add Patch
- **Linux**: `ufw allow 9000/udp`

**5. Wait one heartbeat interval**
Peers announce themselves every 7 seconds. Wait up to 10 seconds after everyone is on the network before concluding something is wrong.

---

## Messages not sending / peers not receiving

**1. No peers in the list**
Messages are unicast — if the peers panel is empty, there's nobody to send to. Resolve discovery first (see above).

**2. Peer has the wrong IP or port**
If a static peer's address changed (e.g. DHCP reassignment), remove the old entry and re-add with the new IP. Dynamic peers update their address automatically when a packet arrives from them.

**3. Check the log**
On desktop, Patch logs to the console. Run from Terminal and look for `warn!` or `error!` lines around send failures.

---

## "Network access denied" banner appears

On iOS or macOS, you tapped **Don't Allow** on the Local Network permission prompt.

- **iOS**: Settings → Privacy & Security → Local Network → enable Patch
- **macOS**: System Settings → Privacy & Security → Local Network → enable Patch

After granting permission, restart Patch.

---

## mDNS / Bonjour not working

mDNS requires multicast to be enabled on the network. Some managed switches and enterprise Wi-Fi controllers filter multicast by default.

Patch gracefully falls back to OSC beacon discovery if mDNS is unavailable — the beacon broadcasts every 7 seconds and does not require multicast. You will see a log warning: `mDNS unavailable, falling back to OSC beacon only`.

If the OSC beacon is also blocked (full broadcast filtering), use static peers.

---

## Peers disappear briefly then reappear

Peers never auto-expire in Patch — they stay in the panel for the full session. If you see a peer disappear, it may be:
- A Patch restart on that device (the peer re-registers within one heartbeat)
- A session load that replaced the channel list (peers are unaffected)

If a peer's dot turns grey, it means no heartbeat has been received in the last 35 seconds — but the peer is still remembered and will turn green again when contact is restored.

---

## Wrong or garbled display name

Your name is set in **Settings → Identity**. Changes propagate to remote peers within one heartbeat interval (≤ 7 seconds) — no restart needed.

If a peer's name looks wrong, it will update on their next heartbeat.

---

## Session won't load from file

- Ensure the file has a `.toml` extension.
- The file must be a valid Patch session exported from Patch itself (or manually written to the [session format](channels-and-sessions.md#session-file-format)).
- On macOS (sandboxed app), you must select the file through the file picker — placing it in an arbitrary folder and typing the path won't work due to sandbox restrictions.
- On iOS, the file must be accessible from the Files app (iCloud Drive, On My iPhone, etc.).

---

## OSC integration not receiving messages

Patch unicasts messages only to known peers. If an external system (QLab, Companion, etc.) isn't receiving messages, add it as a static peer in **Settings → Static Peers** with its IP address and listening port.

See [OSC Integration](osc-integration.md#receiving-messages-from-patch) for details.

---

## Flash animation not triggering

Check the flash settings for the channel:
- **Settings → Behavior**: global "Flash on critical messages" and "Flash on every message" flags
- **Settings → Channels** → tap the channel: per-channel overrides

Either the global flag or the per-channel flag being on is sufficient. If both are off for a channel, flash will not trigger for incoming messages on that channel (but can still be triggered by the FLASH button manually).

---

## App crashes on launch (desktop)

This is most likely a config file issue. Try:

1. Locate `patch.toml` (see [config file location](networking.md#config-file-location))
2. Delete or rename it
3. Relaunch — Patch will generate a fresh config with defaults

If the crash persists, run from Terminal to capture the panic message.

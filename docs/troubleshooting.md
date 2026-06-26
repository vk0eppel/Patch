# Troubleshooting

---

## No peers appearing in the peers panel

**1. Check that everyone is on the same network**
Patch uses UDP multicast/broadcast for discovery — peers must be reachable at the IP layer. Different subnets, VLANs without inter-VLAN routing, or separate Wi-Fi networks will all prevent discovery.

**2. AP isolation is enabled on your Wi-Fi**
Very common in venues. Devices on the same SSID can't talk directly. Fix: add static peers manually (**Settings → Static Peers**) using each device's IP and port 9000. See [Networking](networking.md#ap-isolated-networks).

**3. Check the network interface selection**
Go to **Settings → Network Interface**. If a specific NIC is selected, make sure it's the one connected to the show network — or just switch to **Auto** (applies within a few seconds, no restart). Patch always listens on every interface, so Auto is the safest choice.

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

Peers never auto-expire in Patch — they stay in the panel while the app is open. If you see a peer disappear, it may be:
- A Patch restart on that device (the peer re-registers within one heartbeat)
- A show file load that replaced the channel list (peers are unaffected)

If a peer's dot turns grey, it means no packet (message, flash, or heartbeat) has been received from them in the last 35 seconds — but the peer is still remembered and will turn green again as soon as any packet arrives from them.

---

## Wrong or garbled display name

Your name is set in **Settings → Identity**. Changes propagate to remote peers within one heartbeat interval (≤ 7 seconds) — no restart needed.

If a peer's name looks wrong, it will update on their next heartbeat.

---

## Show file won't load from file

- Ensure the file has a `.toml` extension.
- The file must be a valid Patch show file exported from Patch itself (or manually written to the [show file format](channels-and-show-files.md#show-file-format)).
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

If the in-app pulse is triggering but you can't see it because Patch is in the background, enable **Flash whole screen** in **Settings → Behavior** (macOS/Windows only) — this pulses a full-screen overlay that's visible regardless of which app is focused.

Either the global flag or the per-channel flag being on is sufficient. If both are off for a channel, flash will not trigger for incoming messages on that channel (but can still be triggered by the FLASH button manually).

---

## App crashes on launch (desktop)

This is most likely a config file issue. Try:

1. Locate `patch.toml` (see [config file location](networking.md#config-file-location))
2. Delete or rename it
3. Relaunch — Patch will generate a fresh config with defaults

If the crash persists, run from Terminal to capture the panic message.

---

## "No route to host" lines in the console

If you run Patch from a terminal (or with `RUST_LOG=debug`) you may see occasional
`No route to host` lines for `255.255.255.255` or `ff02::fb` (mDNS) on interfaces
like cellular, VPN tunnels (`utun`), or `awdl`. **These are harmless.** Patch and
the mDNS library try to announce on every interface; the ones that can't carry a
broadcast/multicast simply fail, and discovery still works over the interface that
can (plus unicast and static peers). At the default log level these are suppressed.

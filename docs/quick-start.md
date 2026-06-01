# Quick Start — Patch in 5 Minutes

Patch is a real-time messaging tool for live production crews. It runs over your show network and connects automatically to other Patch users on the same LAN.

---

## 1. First launch

When you open Patch for the first time:

1. **Set your name** — go to **Settings → Identity** and enter your role or name (e.g. "FOH Engineer", "RF Tech", "Stage Manager"). This is how other crew members will see you.
2. **Pick your network interface** — go to **Settings → Network Interface** and select the NIC connected to your show network. Leave it on **Auto** if you're only on one network. Changes take effect on next restart.

---

## 2. Connecting to the crew

Patch finds other devices automatically using two methods:

- **mDNS / Bonjour** — works on most local networks with no setup.
- **OSC beacon** — broadcasts a presence packet every 7 seconds; works as a fallback when mDNS is blocked.

Once a peer is online, they appear in the **PEERS panel** (right side of the screen) with a green dot. A grey dot means no packet has arrived from them in the last 35 seconds — they are still remembered and will turn green as soon as they send any message or heartbeat.

> **On AP-isolated networks** (common in touring venues), devices on the same Wi-Fi AP can't see each other's broadcasts. Ask your PM or network engineer for the IP addresses of other Patch devices and add them under **Settings → Static Peers**.

> **On iOS and macOS**, the OS will ask for Local Network permission on first run. Tap **Allow** — Patch needs this to send and receive OSC packets.

---

## 3. Channels

Channels are your departments: AUDIO, RF, LIGHTING, VIDEO, STAGE, etc. Each channel has its own message feed and colour.

- **Tap** a channel tab to focus it.
- **Tap** a channel tab to toggle it in or out of the view. Multiple channels can be active at once — their feeds are combined and sorted by time. At least one channel is always selected.

The default channels are seeded on first run. Your production manager may load a custom session with show-specific channels before the gig — see [Channels & Sessions](channels-and-sessions.md).

---

## 4. Sending a message

1. Select the channel you want to send on.
2. Type in the input bar at the bottom.
3. Press **Enter** (desktop) or tap **Send** (iOS) to send.

Messages are sent to all connected peers who have the same channel. They appear instantly in the message feed with a large `HH:MM:SS` timestamp.

### Priority levels

| Level | When to use |
|---|---|
| Info (default) | Normal coordination ("Ready when you are") |
| Warning | Heads-up, something needs attention ("Battery at 50%") |
| Critical | Urgent, requires immediate action ("HOLD — power issue") |

Critical messages are displayed with a red left border and background tint so they stand out at a glance.

---

## 5. Flash / page

The **FLASH** button sends an instant page to all peers on a channel. The channel tab pulses and the message box border lights up in the channel colour on every device.

Use flash for "Hey, pay attention" moments — a battery swap warning, a cue hold, a stage-clear call.

Flash is also triggered automatically on incoming Critical messages by default (global setting in **Settings → Behavior**). You can disable this globally, or add per-channel flash triggers in **Settings → Channels** — note that per-channel flags only add triggers; they cannot suppress a global setting that is on.

---

## 6. Macros

Each channel has a panel of one-tap macro buttons for common callouts — for example, **CLEAR**, **HOLD**, **BATTERY LOW** on the RF channel. Toggle the panel with the keyboard icon in the channel header.

On desktop, macros can be bound to **F1–F12** and fire from any focus state (no need to click the button first).

Macros are configured in **Settings → Channels & Macros**.

---

## 7. Sessions

A **session** is a saved snapshot of your channel layout (channels, macros, static peers). Your PM can prepare a session before the show and distribute it as a `.toml` file.

To load a session: tap the **folder icon** in the left sidebar → **Load from file…** or select a named preset.

See [Channels & Sessions](channels-and-sessions.md) for more.

# Integrations

Patch works alongside the tools already on your show network. This page covers
hardware controllers and show-control software.

---

## Stream Deck

Elgato Stream Deck can control Patch shortcuts in several ways — no code changes or
plugins required for the first two options.

### Option A — F-key emulation (works today)

Stream Deck can emulate keyboard keypresses. Map a button to F1–F12 and it fires the
matching Patch shortcut instantly, regardless of which app has focus.

1. Open the **Stream Deck** app.
2. Drag a **Hotkey** action onto a button.
3. Set the hotkey to **F1** (or F2, F3… up to F12).
4. In Patch, bind your shortcut to the matching F-key under **Settings → Channels & Shortcuts → [channel] → [shortcut] → Key binding**.

**Limit:** 12 bindings (F1–F12). Can conflict with other apps using the same F-keys on the same machine.

---

### Option B — OSC via Bitfocus Companion (works today)

[Bitfocus Companion](https://bitfocus.io/companion) is the de-facto show-control
layer for Stream Deck in live production. A Companion button can send any OSC message
directly to Patch — including full messages with priority and payload.

1. Add a **Generic OSC** connection in Companion pointing at your Patch device IP, port 9000.
2. Create a button with an **OSC: Send message** action:
   - Address: `/patch/channel/rf/message`
   - Arguments: see [OSC Integration](osc-integration.md) for the full arg list
3. The message appears in Patch instantly when the button is pressed.

**Advantage:** Unlimited bindings, any channel, any priority, full message control.

---

### Option C — MIDI (requires MIDI trigger feature, planned)

Several Stream Deck plugins (e.g. *MIDI for Stream Deck*) let buttons send MIDI
Note On events. Once MIDI-triggered shortcuts are implemented in Patch, you can
bind any shortcut to a MIDI note number and Stream Deck buttons will fire it
automatically.

See [TODO.md](../TODO.md) — "MIDI-triggered shortcuts" — for status.

---

## Bitfocus Companion

Companion integrates directly with Patch via the **Generic OSC** module. You can:

- Send messages to any channel from a Companion button
- Flash a channel: `/patch/channel/{id}/flash`  
- Trigger any shortcut payload by sending the corresponding `/patch/channel/{id}/message`

See [OSC Integration](osc-integration.md) for the full packet format and argument list.

Companion also works as a **bridge** between Stream Deck and Patch — a single
Companion instance can accept button presses from Stream Deck, Web Buttons, Midi, GPIO,
and other surfaces, and forward them all as OSC to Patch.

---

## QLab

QLab can send OSC cues to Patch directly — no plugin needed.

1. In QLab, add a **Network cue**.
2. Set the destination to your Patch device IP and port 9000.
3. Set the message to `/patch/channel/{id}/message` with the correct arguments.

See [OSC Integration](osc-integration.md) for the complete argument list and a
worked QLab example.

---

## TouchDesigner / vMix / custom scripts

Any software or script that can send OSC over UDP can send messages or flash alerts
to Patch. See [OSC Integration](osc-integration.md) for packet format, Node.js
examples, and a TouchDesigner snippet.

---

## Native Stream Deck plugin *(planned)*

A dedicated Elgato Stream Deck plugin that shows live Patch status on the LCD
buttons — channel names, message counts, flash animations, online peer indicators —
and fires shortcuts directly without middleware. Planned as a future standalone
project. Track status in [TODO.md](../TODO.md).

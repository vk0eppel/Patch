# Channels, Macros & Show Files

---

## Channels

Channels are logical departments — AUDIO, RF, LIGHTING, VIDEO, STAGE, etc. Each has its own message feed, colour, and macro set. Channel IDs are stable slugs (e.g. `rf`, `foh`) used in OSC addresses; display names can be anything.

### Default channels

On first run Patch seeds five channels:

| ID | Display name |
|---|---|
| `audio` | AUDIO |
| `rf` | RF |
| `lighting` | LIGHTING |
| `video` | VIDEO |
| `stage` | STAGE |

The channels start **without** per-channel macros. Instead, a set of generic, cross-channel **global macros** is seeded — they show on every channel and send on whichever channel(s) you have selected:

| Macro | Priority | F-key |
|---|---|---|
| COPY | info | F1 |
| STANDBY | warning | F2 |
| YES | info | F3 |
| NO | info | F4 |
| HOLD | warning | F5 |
| PROBLEM W/ | critical | F6 |
| CH1 · CH2 · CH3 · CH4 | info | — |

This keeps a fresh install simple. Add **channel-specific** macros (e.g. RF "LOW BATT", STAGE "MEDICAL") per channel in **Settings → Channels & Macros** when your show needs them, and edit the global set in **Settings → Global Macros**.

### Creating a channel

1. Go to **Settings → Channels & Macros**.
2. Tap **New channel**.
3. Enter a name and pick a colour.
4. The channel ID (slug) is auto-generated from the name — lowercase, no spaces.

> Channel IDs can only contain lowercase letters, digits, `_` and `-`. They appear in OSC addresses, so keep them short and filesystem-safe.

### Editing a channel

Tap any channel row in **Settings → Channels & Macros** to open the editor. You can change the display name, colour, and per-channel flash settings.

### Deleting a channel

Swipe left on a channel row (iOS) or tap the delete icon. The channel and all its macros are removed. Messages already received are not deleted from the in-memory buffer while the app is open.

### Resetting to defaults

Tap the **↺** icon at the top-right of the Channels & Macros section → confirm. This replaces all channels with the factory defaults (AUDIO, RF, LIGHTING, VIDEO, STAGE).

### Importing channels from a peer

To get a new machine onto the crew's channel set quickly, tap the **cloud-download icon** at the top of **Settings → Channels & Macros**, pick a peer that's already online, and Patch requests their channel layout over the network. You'll see a preview marking each channel **new** or **have**, then tap **Add N** to import. This is a **merge**: only channels you don't already have are added — your existing channels (and their colours and macros) are left untouched. Channels carry their names, colours, and macros across, so a newcomer matches the crew in one tap without retyping anything.

> Flash and alert preferences are **not** imported — they stay local to your machine. Adopted channels start with your own flash defaults (set in **Settings → Behavior**), so importing a layout can never change how your machine flashes or sounds. Adjust per-channel flash in the channel editor afterwards if you want.

### Role label in the peers panel

Set an optional **role** (e.g. "FOH", "Monitors", "PM") in **Settings → Identity** — it shows as a small badge next to your name on every other device's peers panel.

---

## Macros

Macros are one-tap buttons that appear in a side panel on each channel. They're ideal for common callouts you'd otherwise type every time.

### Creating a macro

1. Open **Settings → Channels & Macros** → tap a channel.
2. Scroll to the macros section → tap **+ Add macro**.
3. Fill in:
   - **Label** — the button text (e.g. "BATTERY LOW")
   - **Message** — the payload sent (can be different from the label)
   - **Priority** — Info / Warning / Critical
   - **Key binding** — optional F1–F12 binding (desktop only)
   - **MIDI / OSC** — optional hardware/software triggers and an outbound OSC target (see below)

### Reordering macros

In **Settings → Channels & Macros**, each macro row has a drag handle (**≡**) on the left. Drag it up or down to reorder the macros within that channel. The new order is reflected immediately in the macro side panel (and the column layout follows it) and is saved with your layout.

### F-key bindings

On desktop, F1–F12 fire the first matching macro across all currently selected channels — no need to click the button. Key bindings are shown as a small badge on the macro button.

### MIDI triggers

On desktop you can also bind a macro to a **MIDI note or CC number** (0–127) in the macro editor — connect a footswitch, pad, or keyboard and the macro fires hands-free. A note fires on press (any velocity); a CC fires on a value of 64 or more (a footswitch "down"). Patch listens on all MIDI input ports detected at launch — plug your controller in before starting Patch (or restart after connecting it). Bindings show as a `♪`/`CC` badge next to the macro in Settings.

Where a MIDI-fired macro sends matches what tapping it would do:

- A **per-channel** macro fires **on its own channel, regardless of which channel you're viewing** (or whether Patch is even focused) — so a pedal can fire "RF: LOW BATT" while you're looking at AUDIO.
- A **global** macro fires **on the channel(s) you currently have selected** — exactly like tapping it. If you're in the **ALL** view, it goes out as a crew-wide broadcast.

#### Sending MIDI from other software (no hardware)

On **macOS and Linux**, Patch also creates a **virtual MIDI port named "Patch"**. Other software on the same machine — a DAW, Bitfocus Companion, a software MIDI controller, a Stream Deck MIDI action — can send MIDI straight to it: just pick **"Patch"** as the MIDI output/destination in that app, and notes/CCs trigger your bound macros exactly like a hardware controller would. No cables, no interface. (On **Windows** there's no virtual-port support, so install a loopback driver like [loopMIDI](https://www.tobias-erichsen.de/software/loopmidi.html) and route through that port instead.)

### Triggering external gear (OSC)

A macro can also fire an **OSC message to external gear** when it's pressed — so one button both tells the crew *and* triggers a QLab cue, a Companion button, a vMix overlay, or anything else that speaks OSC. In the macro editor, turn on **"Also send OSC"** and fill in:

- **IP** + **Port** — the gear's OSC listener (e.g. `192.168.1.50` : `53000` for QLab)
- **OSC path** — the address to send, must start with `/` (e.g. `/cue/1/start`)
- **Argument** — an optional single string argument

When the macro fires — by tap, F-key, **or** MIDI — Patch sends its normal crew message *and* the OSC packet, simultaneously. A macro with an OSC target shows a small **OSC** badge in Settings.

---

## Flash settings

Flash fires automatically when messages arrive. There are two levels of control:

**Global flags** (Settings → Behavior) apply to every channel. When a global flag is on,
that channel will always flash — the per-channel setting cannot suppress it.

**Per-channel flags** (Settings → Channels → channel editor footer) let you *add* flash
triggers for specific channels beyond the global defaults. They cannot turn off what a
global setting enables.

**In practice:**
- Leave global "Flash on critical" **on** (default) if you want all departments alerted on
  critical messages. Turn it off in Settings → Behavior if you only want specific channels
  to flash on critical, then enable the flag per channel.
- "Flash on every message" is off globally by default — enable it per channel for
  high-activity departments only (e.g. RF).

| Setting | Default | Where |
|---|---|---|
| Flash on critical messages | ✅ On | Global — Settings → Behavior |
| Flash on every message | ❌ Off | Global — Settings → Behavior |
| Flash pulse count | 4 | Global default; overridable per channel (3–7) |

Flash pulse count shows **–** in the channel editor when the global value is in use; pick a number to set a per-channel override.

---

## Show Files

A **show file** is a named snapshot of your full channel layout: channels, macros, and static peers. Use show files to:

- Save and restore a show-specific configuration
- Share a layout with the rest of the crew (export → send the `.toml` file)
- Quickly switch between different show configurations

### Opening the show files panel

Tap the **folder icon** in the left sidebar (below the channel list).

### Saving a show file

1. Configure channels, macros, and static peers as needed.
2. Open the show files panel → tap **+ Save current layout**.
3. Enter a name (e.g. "Festival Day 1") → Save.

### Loading a show file

Open the show files panel → tap **Load** next to a saved show file. The current channel layout **and static peers** are replaced immediately with the ones the show file captured — so a layout distributed by your PM brings its known device IPs with it.

### Importing from a file

Tap **Load from file…** → select a `.toml` show file. Useful when the PM distributes a pre-built layout.

### Exporting to a file

Tap **Save to file…** → choose a save location. The current layout is written as a `.toml` file you can share or archive.

### Show file format

Show files are plain TOML — human-readable and easily version-controlled:

```toml
name = "Festival Day 1"
created_at = "2026-05-28T09:00:00Z"

[[channels]]
id = "rf"
display_name = "RF"
color = "#F44336"
flash_on_critical = true
flash_on_message = false

  [[channels.macros]]
  label = "CLEAR"
  payload = "CLEAR"
  priority = 1
  key_binding = "F1"

[[static_peers]]
address = "192.168.1.50"
port = 9000
label = "Monitor World"
```

---

## Direct messages

Sometimes you need a quiet word with one person, not the whole channel. Open the **peers panel** (the people icon), find the peer, and tap the **💬** button next to their name. A private thread opens, and a **💬 tab** for that person appears under **DIRECT** at the bottom of the channel sidebar.

- Messages are sent **only** to that peer — never broadcast or shown to anyone else.
- New direct messages show a small **red dot** on the person's DM tab. A normal-priority DM doesn't flash the screen; a **critical** DM does (it plays the alert and flashes the thread, following your global "Flash on critical messages" setting). The dot clears when you open the thread.
- **Direct flash** — need their attention *now*? Press the **flash button** in the DM header. It sends a private attention ping to just that person: their Patch plays the alert sound and their DM thread flashes (or shows the red dot if they're looking elsewhere). Nobody else sees it.
- A DM thread stays in the sidebar while the app is open. You can clear or export it with the same buttons as a channel.

> DMs are best-effort and not stored to disk. There's no offline delivery — if the other person's Patch isn't running, they won't get it. If you send a DM (or a direct flash) to someone who appears **offline**, Patch shows an amber warning so you know it may not have landed — the message still stays in your thread. The 💬 button only appears for live peers (not configured-only static peers).

## Message history

### Exporting messages

Tap the **↓ (download) icon** in the top-right corner of the message area to export the current channel's messages to a CSV file.

- **Single channel selected** — exports that channel's messages; columns: `timestamp, sender, priority, message`
- **Multiple channels selected** — exports messages from all selected channels; columns: `timestamp, channel, sender, priority, message`

The save dialog pre-fills the filename as `patch_<channel>.csv`. Open the file in any spreadsheet app or text editor.

### Clearing messages

Tap the **🗑 (delete sweep) icon** next to the export button to clear the message buffer for the current channel(s). A confirmation dialog appears before anything is deleted. This only affects the in-memory buffer — nothing is stored to disk, so clearing is permanent.

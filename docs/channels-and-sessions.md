# Channels, Macros & Sessions

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

`AUDIO` comes with macros: **Yes** (info), **No** (info), **Problem with:** (critical).  
`RF` comes with macros: **CLEAR** (info, F1), **HOLD** (warning, F2), **BATTERY LOW** (critical, F3).

### Creating a channel

1. Go to **Settings → Channels & Macros**.
2. Tap **+ Add channel**.
3. Enter a name and pick a colour.
4. The channel ID (slug) is auto-generated from the name — lowercase, no spaces.

> Channel IDs can only contain lowercase letters, digits, `_` and `-`. They appear in OSC addresses, so keep them short and filesystem-safe.

### Editing a channel

Tap any channel row in **Settings → Channels & Macros** to open the editor. You can change the display name, colour, and per-channel flash settings.

### Deleting a channel

Swipe left on a channel row (iOS) or tap the delete icon. The channel and all its macros are removed. Messages already received are not deleted from the in-memory buffer for the current session.

### Resetting to defaults

Tap the **↺** icon at the top-right of the Channels & Macros section → confirm. This replaces all channels with the factory defaults (AUDIO, RF, LIGHTING, VIDEO, STAGE).

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

### F-key bindings

On desktop, F1–F12 fire the first matching macro across all currently selected channels — no need to click the button. Key bindings are shown as a small badge on the macro button.

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
| Flash pulse count | 4 | Global default; overridable per channel (1–10) |

Flash pulse count shows **–** in the channel editor when the global value is in use; pick a number to set a per-channel override.

---

## Sessions

A **session** is a named snapshot of your full channel layout: channels, macros, and static peers. Use sessions to:

- Save and restore a show-specific configuration
- Share a layout with the rest of the crew (export → send the `.toml` file)
- Quickly switch between different show configurations

### Opening the sessions panel

Tap the **folder icon** in the left sidebar (below the channel list).

### Saving a session

1. Configure channels, macros, and static peers as needed.
2. Open the sessions panel → tap **+ Save current layout**.
3. Enter a name (e.g. "Festival Day 1") → Save.

### Loading a session

Open the sessions panel → tap **Load** next to a saved session. The current channel layout is replaced immediately.

### Importing from a file

Tap **Load from file…** → select a `.toml` session file. Useful when the PM distributes a pre-built layout.

### Exporting to a file

Tap **Save to file…** → choose a save location. The current layout is written as a `.toml` file you can share or archive.

### Session file format

Sessions are plain TOML — human-readable and easily version-controlled:

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

## Message history

### Exporting messages

Tap the **↓ (download) icon** in the top-right corner of the message area to export the current channel's messages to a CSV file.

- **Single channel selected** — exports that channel's messages; columns: `timestamp, sender, priority, message`
- **Multiple channels selected** — exports messages from all selected channels; columns: `timestamp, channel, sender, priority, message`

The save dialog pre-fills the filename as `patch_<channel>.csv`. Open the file in any spreadsheet app or text editor.

### Clearing messages

Tap the **🗑 (delete sweep) icon** next to the export button to clear the message buffer for the current channel(s). A confirmation dialog appears before anything is deleted. This only affects the in-memory buffer — nothing is stored to disk, so clearing is permanent for that session.

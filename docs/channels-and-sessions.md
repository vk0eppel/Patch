# Channels, Shortcuts & Sessions

---

## Channels

Channels are logical departments — AUDIO, RF, LIGHTING, VIDEO, STAGE, etc. Each has its own message feed, colour, and shortcut set. Channel IDs are stable slugs (e.g. `rf`, `foh`) used in OSC addresses; display names can be anything.

### Default channels

On first run Patch seeds five channels:

| ID | Display name |
|---|---|
| `audio` | AUDIO |
| `rf` | RF |
| `lighting` | LIGHTING |
| `video` | VIDEO |
| `stage` | STAGE |

`AUDIO` comes with shortcuts: **Yes** (info), **No** (info), **Problem with:** (critical).  
`RF` comes with shortcuts: **CLEAR** (info, F1), **HOLD** (warning, F2), **BATTERY LOW** (critical, F3).

### Creating a channel

1. Go to **Settings → Channels & Shortcuts**.
2. Tap **+ Add channel**.
3. Enter a name and pick a colour.
4. The channel ID (slug) is auto-generated from the name — lowercase, no spaces.

> Channel IDs can only contain lowercase letters, digits, `_` and `-`. They appear in OSC addresses, so keep them short and filesystem-safe.

### Editing a channel

Tap any channel row in **Settings → Channels & Shortcuts** to open the editor. You can change the display name, colour, and per-channel flash settings.

### Deleting a channel

Swipe left on a channel row (iOS) or tap the delete icon. The channel and all its shortcuts are removed. Messages already received are not deleted from the in-memory buffer for the current session.

### Resetting to defaults

Tap the **↺** icon at the top-right of the Channels & Shortcuts section → confirm. This replaces all channels with the factory defaults (AUDIO, RF, LIGHTING, VIDEO, STAGE).

---

## Shortcut messages

Shortcuts are one-tap buttons that appear above the message input on each channel. They're ideal for common callouts you'd otherwise type every time.

### Creating a shortcut

1. Open **Settings → Channels & Shortcuts** → tap a channel.
2. Scroll to the shortcuts section → tap **+ Add shortcut**.
3. Fill in:
   - **Label** — the button text (e.g. "BATTERY LOW")
   - **Message** — the payload sent (can be different from the label)
   - **Priority** — Info / Warning / Critical
   - **Key binding** — optional F1–F12 binding (desktop only)

### F-key bindings

On desktop, F1–F12 fire the first matching shortcut across all currently selected channels — no need to click the button. Key bindings are shown as a small badge on the shortcut chip.

---

## Flash settings

Flash can be triggered automatically when messages arrive:

| Setting | Default | Scope |
|---|---|---|
| Flash on critical messages | ✅ On | Global |
| Flash on every message | ❌ Off | Global |
| Flash pulse count | 4 | Global (range 1–10) |

Per-channel overrides are available in the channel editor footer. Either the global flag or the per-channel flag being on is sufficient to trigger a flash.

---

## Sessions

A **session** is a named snapshot of your full channel layout: channels, shortcuts, and static peers. Use sessions to:

- Save and restore a show-specific configuration
- Share a layout with the rest of the crew (export → send the `.toml` file)
- Quickly switch between different show configurations

### Opening the sessions panel

Tap the **folder icon** in the left sidebar (below the channel list).

### Saving a session

1. Configure channels, shortcuts, and static peers as needed.
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

  [[channels.shortcuts]]
  label = "CLEAR"
  payload = "CLEAR"
  priority = 1
  key_binding = "F1"

[[static_peers]]
address = "192.168.1.50"
port = 9000
label = "Monitor World"
```

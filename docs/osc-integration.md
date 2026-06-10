# OSC Integration

Patch speaks OSC natively over UDP. Any show-control system that can send or receive OSC — QLab, Companion, TouchDesigner, vMix, custom scripts — can integrate directly.

---

## OSC namespace

| Address | Direction | Description |
|---|---|---|
| `/patch/channel/{id}/say` | Send | **Simple** message post — payload (+ optional priority); Patch fills in the rest. Best for QLab/Companion/scripts. |
| `/patch/channel/{id}/message` | Send / Receive | Full channel message (6 args incl. UUIDs/timestamp) — used Patch-to-Patch. |
| `/patch/channel/{id}/flash` | Send / Receive | Flash / page a channel |
| `/patch/presence` | Send / Receive | Peer heartbeat / presence / discovery — the single announce address. Send one to make an external tool appear as a peer; Patch emits it every heartbeat. |
| `/patch/bye` | Send / Receive | Departure announcement — marks the sender offline promptly. |
| `/patch/ack` | Receive only | ACK for a critical message |

`{id}` is the channel slug — lowercase, e.g. `rf`, `audio`, `lighting`.

---

## Posting a message — the easy way (`/say`)

For QLab, Companion, or any script, the simplest path is `/patch/channel/{id}/say` on UDP port 9000. You send just the **text** and (optionally) a **priority** — Patch fills in the sender, a fresh message id, and the timestamp, then the receiving node posts the message to the whole crew.

```
/patch/channel/rf/say   "Battery low — swap now"   3
```

| Arg # | Type | Field | Notes |
|---|---|---|---|
| 0 | string | payload (the message text) | required |
| 1 | int (or float) | priority — 0=debug 1=info 2=warning 3=critical | optional; default `1` (info); out-of-range → info |

No UUIDs, no timestamp, no de-duplication bookkeeping — fire the same cue as many times as you want. The message appears to come from the Patch node that receives it.

### Example — QLab OSC (Network) cue

```
Destination: 192.168.1.50 : 9000        (the Patch machine; 127.0.0.1 if same Mac)
Address:     /patch/channel/rf/say
Arguments:
  s  "Battery low on Belt Pack 3 — swap now"
  i  3                                          ← critical (omit for info)
```

> The channel id in the address must exist as a slug (`[a-z0-9_-]`, ≤ 64 chars) on the receiving Patch and the payload must be ≤ 4 KB.

---

## Full message form (Patch-to-Patch / UUID-capable scripts)

The full 6-arg form is what Patch uses between its own nodes; use it from a script that can generate UUIDs and a timestamp. Send to any Patch device on UDP port 9000:

```
/patch/channel/{id}/message  s s s h i s
```

| Arg # | Type | Field | Example |
|---|---|---|---|
| 0 | string | sender_id (UUID) | `"550e8400-e29b-41d4-a716-446655440000"` |
| 1 | string | sender_name | `"QLab"` |
| 2 | string | message_id (UUID, unique per message) | `"6ba7b810-9dad-11d1-80b4-00c04fd430c8"` |
| 3 | int64 (long) | timestamp (ms since epoch) | `1748419200000` |
| 4 | int32 | priority (0=debug 1=info 2=warning 3=critical) | `2` |
| 5 | string | payload | `"Battery low — swap now"` |

> **Tip:** Use a static UUID for `sender_id` so Patch recognises your show-control system as a consistent peer. Generate a message-unique UUID for `message_id` — Patch deduplicates by `message_id`, so reusing it will silently drop the message.

> **Limits:** The channel id in the address must be a slug (`[a-z0-9_-]`, max 64 chars) and the `payload` must be ≤ 4 KB — packets that violate either are dropped on receipt. When you send `priority = 3` (critical), Patch replies with `/patch/ack` to your source address — you can ignore it if your integration doesn't track acknowledgements.

### Example — QLab OSC cue

```
Target: 192.168.1.50:9000
Address: /patch/channel/rf/message
Arguments:
  s  "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"   ← your system's static UUID
  s  "QLab"
  s  "c7def6a0-4dd2-4c5c-9fe7-3f13b5c7d8a2"   ← unique per cue
  h  1748419200000                               ← current time in ms
  i  3                                           ← critical
  s  "Battery low on Belt Pack 3 — swap now"
```

### Example — Node.js script

```js
const osc = require('osc');
const { v4: uuidv4 } = require('uuid');

const udpPort = new osc.UDPPort({ remoteAddress: '192.168.1.50', remotePort: 9000 });
udpPort.open();

udpPort.send({
  address: '/patch/channel/rf/message',
  args: [
    { type: 's', value: 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11' }, // sender_id
    { type: 's', value: 'Custom Script' },                          // sender_name
    { type: 's', value: uuidv4() },                                 // message_id
    { type: 'h', value: BigInt(Date.now()) },                       // timestamp
    { type: 'i', value: 2 },                                        // warning
    { type: 's', value: 'RF dropout on channel 4' },                // payload
  ],
});
```

---

## Flashing a channel from OSC

```
/patch/channel/{id}/flash  s s
```

| Arg # | Type | Field |
|---|---|---|
| 0 | string | sender_id (UUID) |
| 1 | string | sender_name |

```
/patch/channel/rf/flash
  s  "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  s  "QLab"
```

---

## Receiving messages from Patch

Patch sends all messages as unicast to each known peer — it does **not** broadcast messages. To receive Patch messages in an external system, Patch must know about your system as a peer.

**Add your system as a static peer:** in Patch, go to **Settings → Static Peers → + Add peer** and enter the IP address and port of your OSC listener. Patch will then unicast every message to it.

Messages arrive in the same `/patch/channel/{id}/message` format as above.

---

## Companion integration (Bitfocus)

1. Add a **Generic OSC** connection pointing at your Patch device IP, port 9000.
2. For messages: a press action sending `/patch/channel/stage/say` with a string (the text) and optionally an int priority — simplest by far.
3. For flash/page: an OSC action sending `/patch/channel/rf/flash` with the two string args.

---

## TouchDesigner integration

```python
# In a DAT Execute or Script CHOP:
import time, uuid

def send_patch_message(channel_id, payload, priority=1):
    msg = op('oscout1').sendOSC(
        f'/patch/channel/{channel_id}/message',
        [
            'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',  # sender_id
            'TouchDesigner',                            # sender_name
            str(uuid.uuid4()),                          # message_id
            int(time.time() * 1000),                    # timestamp ms
            priority,                                   # 0-3
            payload,
        ]
    )
```

Configure the `oscout1` CHOP with the Patch device IP and port 9000.

---

## OSC trigger → Patch message mapping *(partly available)*

For systems you control (QLab, Companion, scripts), the `/patch/channel/{id}/say` address above already lets you post a message with just text + priority — no scripting, no UUIDs.

Still planned: mapping an **arbitrary foreign** OSC address (e.g. `/rf/battery_low` from a proprietary device whose output address you can't change) to a channel message with a configured priority/payload. Track progress in [TODO.md](../TODO.md).

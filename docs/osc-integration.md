# OSC Integration

Patch speaks OSC natively over UDP. Any show-control system that can send or receive OSC — QLab, Companion, TouchDesigner, vMix, custom scripts — can integrate directly.

---

## OSC namespace

| Address | Direction | Description |
|---|---|---|
| `/patch/channel/{id}/message` | Send / Receive | Channel message |
| `/patch/channel/{id}/flash` | Send / Receive | Flash / page a channel |
| `/patch/presence` | Receive only | Peer heartbeat / presence |
| `/patch/system/heartbeat` | Receive only | Standalone heartbeat ping |
| `/patch/discovery` | Receive only | Peer discovery beacon |
| `/patch/ack` | Receive only | ACK for a critical message |

`{id}` is the channel slug — lowercase, e.g. `rf`, `audio`, `lighting`.

---

## Sending a message to Patch

Send a standard OSC message to any Patch device on UDP port 9000:

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
2. Create a button with an OSC action sending `/patch/channel/rf/flash` with the two string args.
3. For messages: build a press action sending `/patch/channel/stage/message` with the six args — use a static sender UUID, dynamic timestamp via Companion's `$(internal:time_ms)` variable, and a unique message ID.

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

## OSC trigger → Patch message mapping *(planned)*

Future: Patch will support mapping any incoming OSC address to a channel message with a configured priority and payload — no external scripting needed. Track progress in [TODO.md](../TODO.md).

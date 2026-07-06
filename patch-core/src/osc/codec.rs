//! Encode/decode PATCH OSC packets using the `rosc` crate.

use anyhow::{bail, Context, Result};
use chrono::{DateTime, TimeZone, Utc};
use rosc::{OscMessage, OscPacket, OscType};
use uuid::Uuid;

use super::{
    addresses,
    types::{ChannelFlash, OscArgKind, PatchMessage, PeerPresence, Priority},
};

// ── Encode ────────────────────────────────────────────────────────────────────

/// Encode a [`PatchMessage`] into raw OSC bytes.
///
/// Address: `/patch/channel/{channel_id}/message`
/// The channel is encoded in the OSC address (not just the args) so that
/// OSC routers, Companion, and QLab can filter by channel without parsing args.
pub fn encode_message(msg: &PatchMessage) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::channel_message(&msg.channel_id),
        args: vec![
            OscType::String(msg.sender_id.to_string()),
            OscType::String(msg.sender_name.clone()),
            OscType::String(msg.message_id.to_string()),
            OscType::Long(msg.timestamp.timestamp_millis()),
            OscType::Int(msg.priority as i32),
            OscType::String(msg.payload.clone()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode channel message")
}

/// Encode a presence/heartbeat packet.
pub fn encode_presence(p: &PeerPresence) -> Result<Vec<u8>> {
    let channels_json = serde_json::to_string(&p.channels)?;
    let osc = OscMessage {
        addr: addresses::PRESENCE.to_string(),
        args: vec![
            OscType::String(p.peer_id.to_string()),
            OscType::String(p.peer_name.clone()),
            OscType::String(channels_json),
            OscType::Long(p.timestamp.timestamp_millis()),
            // arg 4 (optional): self-assigned role, empty string when unset.
            // Appended last so older 4-arg receivers ignore it and we can decode
            // older 4-arg packets (role = None) — see decode_presence.
            OscType::String(p.role.clone().unwrap_or_default()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode /patch/presence")
}

/// Encode a channel flash packet. `message_id` lets receivers dedup the
/// multi-path copies (ADR-0007); `timestamp` is the sender's clock, so the
/// receiver's Flash log entry aligns with the sender's other messages.
pub fn encode_flash(
    flash: &ChannelFlash,
    message_id: Uuid,
    timestamp: DateTime<Utc>,
) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::channel_flash(&flash.channel_id),
        args: vec![
            OscType::String(flash.sender_id.to_string()),
            OscType::String(flash.sender_name.clone()),
            OscType::String(message_id.to_string()),
            OscType::Long(timestamp.timestamp_millis()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode flash")
}

/// Encode a direct (peer-to-peer) message. `target_id` is the recipient's peer
/// id (so the receiver confirms it's for them); the message's `channel_id` is
/// *not* sent — the receiver derives `dm:{sender_id}` locally.
pub fn encode_dm(msg: &PatchMessage, target_id: Uuid) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::DM.to_string(),
        args: vec![
            OscType::String(msg.sender_id.to_string()),
            OscType::String(msg.sender_name.clone()),
            OscType::String(target_id.to_string()),
            OscType::String(msg.message_id.to_string()),
            OscType::Long(msg.timestamp.timestamp_millis()),
            OscType::Int(msg.priority as i32),
            OscType::String(msg.payload.clone()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode /patch/dm")
}

/// Encode a direct flash (attention ping) to one peer. `target_id` is the
/// recipient's peer id; the flash's `channel_id` is *not* sent — the receiver
/// derives `dm:{sender_id}` locally (mirroring [`encode_dm`]).
pub fn encode_dm_flash(flash: &ChannelFlash, target_id: Uuid) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::DM_FLASH.to_string(),
        args: vec![
            OscType::String(flash.sender_id.to_string()),
            OscType::String(flash.sender_name.clone()),
            OscType::String(target_id.to_string()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode /patch/dm/flash")
}

/// Encode a departure announcement (sent on graceful shutdown).
pub fn encode_bye(peer_id: Uuid) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::BYE.to_string(),
        args: vec![OscType::String(peer_id.to_string())],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode /patch/bye")
}

/// Encode a channel-layout request (sent unicast to a chosen peer).
pub fn encode_channels_request(peer_id: Uuid) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::CHANNELS_REQUEST.to_string(),
        args: vec![OscType::String(peer_id.to_string())],
    };
    rosc::encoder::encode(&OscPacket::Message(osc))
        .context("Failed to encode /patch/channels/request")
}

/// Encode a channel-layout announce (the reply to a request). `channels_json` is
/// the responder's channel list already serialised to JSON — kept as a string
/// here so the codec layer doesn't depend on the higher-level `Channel` type
/// (the transport/state layer serialises and parses it).
pub fn encode_channels_announce(
    peer_id: Uuid,
    peer_name: &str,
    channels_json: &str,
) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::CHANNELS_ANNOUNCE.to_string(),
        args: vec![
            OscType::String(peer_id.to_string()),
            OscType::String(peer_name.to_string()),
            OscType::String(channels_json.to_string()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc))
        .context("Failed to encode /patch/channels/announce")
}

/// Encode a global-macros request (sent unicast to a chosen peer).
pub fn encode_macros_request(peer_id: Uuid) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::MACROS_REQUEST.to_string(),
        args: vec![OscType::String(peer_id.to_string())],
    };
    rosc::encoder::encode(&OscPacket::Message(osc))
        .context("Failed to encode /patch/macros/request")
}

/// Encode a global-macros announce (the reply to a request). `macros_json` is
/// the responder's global macro list already serialised to JSON — kept as a
/// string here so the codec layer doesn't depend on `state::channel::MacroMessage`
/// (the transport/state layer serialises and parses it).
pub fn encode_macros_announce(
    peer_id: Uuid,
    peer_name: &str,
    macros_json: &str,
) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::MACROS_ANNOUNCE.to_string(),
        args: vec![
            OscType::String(peer_id.to_string()),
            OscType::String(peer_name.to_string()),
            OscType::String(macros_json.to_string()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc))
        .context("Failed to encode /patch/macros/announce")
}

/// Parse a macro's stored `arg` string into the `OscType` matching its
/// declared `arg_type`. The single place that converts the wire-agnostic
/// [`OscArgKind`] into a concrete `rosc::OscType` — both `encode_osc` and the
/// save-time/load-time validation callers in `api`/`state` go through this so
/// the parsing rule has one definition.
pub(crate) fn build_osc_arg(kind: OscArgKind, value: &str) -> Result<OscType> {
    match kind {
        OscArgKind::String => Ok(OscType::String(value.to_string())),
        OscArgKind::Int => value
            .trim()
            .parse::<i32>()
            .map(OscType::Int)
            .with_context(|| format!("OSC arg {:?} is not a valid Int", value)),
        OscArgKind::Float => value
            .trim()
            .parse::<f32>()
            .map(OscType::Float)
            .with_context(|| format!("OSC arg {:?} is not a valid Float", value)),
    }
}

/// Encode an arbitrary outbound OSC message for an "OSC macro" → external gear
/// (QLab/Companion/vMix…). `path` must be a valid OSC address (start with '/');
/// `arg`, when present, is parsed per `arg_type` and sent as that single typed
/// OSC argument.
pub fn encode_osc(path: &str, arg_type: OscArgKind, arg: Option<&str>) -> Result<Vec<u8>> {
    if !path.starts_with('/') {
        bail!("OSC path must start with '/': {:?}", path);
    }
    let args = match arg {
        Some(s) => vec![build_osc_arg(arg_type, s)?],
        None => Vec::new(),
    };
    let osc = OscMessage {
        addr: path.to_string(),
        args,
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode OSC macro")
}

/// Encode an ACK for a given message_id.
pub fn encode_ack(message_id: Uuid, peer_id: Uuid) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::ACK.to_string(),
        args: vec![
            OscType::String(message_id.to_string()),
            OscType::String(peer_id.to_string()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode /patch/ack")
}

// ── Decode ────────────────────────────────────────────────────────────────────

/// Top-level decoded PATCH event.
#[derive(Debug)]
pub enum PatchEvent {
    Message(PatchMessage),
    Ack {
        message_id: Uuid,
        peer_id: Uuid,
    },
    Presence(PeerPresence),
    Bye {
        peer_id: Uuid,
    },
    /// A channel Flash. `message_id`/`timestamp` ride the wire so multi-path
    /// copies dedup to one log entry stamped with the sender's clock; both are
    /// synthesized locally when decoding an older peer's 2-arg flash.
    Flash {
        flash: ChannelFlash,
        message_id: Uuid,
        timestamp: DateTime<Utc>,
    },
    /// A direct (peer-to-peer) message addressed to `target_id`. `msg.channel_id`
    /// is already set to `dm:{sender_id}` by the decoder (the receiver's key for
    /// the conversation with the sender).
    DirectMessage {
        msg: PatchMessage,
        target_id: Uuid,
    },
    /// A direct flash/attention ping addressed to `target_id`. The receiver
    /// flashes its `dm:{sender_id}` thread.
    DirectFlash {
        sender_id: Uuid,
        sender_name: String,
        target_id: Uuid,
    },
    /// Simple external-OSC message injection (e.g. from QLab/Companion) — the
    /// receiving node fills in sender/id/timestamp and posts it. Args: payload
    /// (string) + optional priority (int, default info).
    Say {
        channel_id: String,
        payload: String,
        priority: Priority,
    },
    /// A peer asked us for our channel layout. We reply with a ChannelsAnnounce.
    ChannelsRequest {
        peer_id: Uuid,
    },
    /// A peer's channel layout, in reply to our request. `channels_json` is the
    /// raw JSON-serialised `Vec<Channel>`; the transport layer parses + validates.
    ChannelsAnnounce {
        peer_id: Uuid,
        peer_name: String,
        channels_json: String,
    },
    /// A peer asked us for our global macros. We reply with a MacrosAnnounce.
    MacrosRequest {
        peer_id: Uuid,
    },
    /// A peer's global macros, in reply to our request. `macros_json` is the
    /// raw JSON-serialised `Vec<MacroMessage>`; the transport layer parses +
    /// validates.
    MacrosAnnounce {
        peer_id: Uuid,
        peer_name: String,
        macros_json: String,
    },
    Unknown(OscMessage),
}

/// Decode raw UDP bytes into a [`PatchEvent`].
pub fn decode_packet(buf: &[u8]) -> Result<PatchEvent> {
    let (_, packet) = rosc::decoder::decode_udp(buf).context("OSC decode failed")?;
    match packet {
        OscPacket::Message(msg) => decode_message(msg),
        OscPacket::Bundle(_) => bail!("OSC bundles not yet supported"),
    }
}

fn decode_message(msg: OscMessage) -> Result<PatchEvent> {
    match msg.addr.as_str() {
        // New channel-scoped address: /patch/channel/{id}/message
        addr if addr.starts_with("/patch/channel/") && addr.ends_with("/message") => {
            decode_patch_message(msg)
        }
        // Simple external-friendly form: /patch/channel/{id}/say
        addr if addr.starts_with("/patch/channel/") && addr.ends_with("/say") => decode_say(msg),
        addresses::ACK => decode_ack(msg),
        addresses::PRESENCE => decode_presence(msg),
        addresses::BYE => decode_bye(msg),
        addresses::DM => decode_dm(msg),
        // Must precede the generic `.../flash` arm — /patch/dm/flash also ends "/flash".
        addresses::DM_FLASH => decode_dm_flash(msg),
        addresses::CHANNELS_REQUEST => decode_channels_request(msg),
        addresses::CHANNELS_ANNOUNCE => decode_channels_announce(msg),
        addresses::MACROS_REQUEST => decode_macros_request(msg),
        addresses::MACROS_ANNOUNCE => decode_macros_announce(msg),
        addr if addr.ends_with("/flash") => decode_flash(msg),
        _ => Ok(PatchEvent::Unknown(msg)),
    }
}

/// Maximum accepted payload length for an inbound message. Defensive bound —
/// operational messages are short, while a UDP datagram can carry ~64 KB.
const MAX_PAYLOAD_LEN: usize = 4096;

/// Maximum accepted length for an inbound display name (sender/peer) or role.
/// These land in the peer registry, ride every `PeerUpdated` publish, and
/// render in the peers panel — a ~64 KB datagram must not plant a 60 KB name.
const MAX_NAME_LEN: usize = 256;

/// Maximum accepted length for a presence packet's channels JSON. A real
/// subscription list is a few hundred bytes; this bounds a hostile one the
/// same way `MAX_CHANNELS_JSON` bounds an announce.
const MAX_PRESENCE_CHANNELS_JSON: usize = 8 * 1024;

/// Parse an OSC string arg that is a display name or role — same as
/// [`parse_string`] but bounded by [`MAX_NAME_LEN`].
fn parse_name(t: &OscType) -> Result<String> {
    let s = parse_string(t)?;
    if s.len() > MAX_NAME_LEN {
        bail!(
            "Rejected: name/role {} bytes exceeds max {}",
            s.len(),
            MAX_NAME_LEN
        );
    }
    Ok(s)
}

/// Extract the channel id from a channel-scoped address of the **exact**
/// shape `/patch/channel/{id}/{leaf}`. Extra path segments are rejected
/// rather than silently aliasing onto a shorter channel id
/// (`/patch/channel/rf/x/message` must not post to `rf`).
fn channel_id_from_addr(addr: &str) -> Result<String> {
    let parts: Vec<&str> = addr.split('/').collect();
    if parts.len() != 5 {
        bail!("Rejected: malformed channel address {:?}", addr);
    }
    let channel_id = parts[3].to_string();
    if !valid_channel_id(&channel_id) {
        bail!("Rejected: invalid channel id {:?}", channel_id);
    }
    Ok(channel_id)
}

/// Channel ids must match this slug rule everywhere they can reach an OSC
/// address: inbound packets (`decode_*`), the UI (`api::upsert_channel`), and
/// loaded/imported show files (`AppState::apply_show_file`). Keeps a remote sender
/// or a hand-edited show file from injecting arbitrary buffer keys or
/// oversized/unsafe address segments.
pub(crate) fn valid_channel_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .chars()
            .all(|c| matches!(c, 'a'..='z' | '0'..='9' | '_' | '-'))
}

fn decode_patch_message(msg: OscMessage) -> Result<PatchEvent> {
    // Channel id lives in the address: /patch/channel/{id}/message
    let channel_id = channel_id_from_addr(&msg.addr)?;
    let args = msg.args;
    if args.len() < 6 {
        bail!(
            "Expected 6 args for /patch/channel/.../message, got {}",
            args.len()
        );
    }
    let sender_id = parse_uuid(&args[0])?;
    let sender_name = parse_name(&args[1])?;
    let message_id = parse_uuid(&args[2])?;
    let ts_ms = parse_long(&args[3])?;
    let priority = Priority::try_from(parse_int(&args[4])?)?;
    let payload = parse_string(&args[5])?;
    if payload.len() > MAX_PAYLOAD_LEN {
        bail!(
            "Rejected message: payload {} bytes exceeds max {}",
            payload.len(),
            MAX_PAYLOAD_LEN
        );
    }

    Ok(PatchEvent::Message(PatchMessage {
        message_id,
        sender_id,
        sender_name,
        channel_id,
        timestamp: Utc
            .timestamp_millis_opt(ts_ms)
            .single()
            .context("Invalid timestamp")?,
        priority,
        payload,
        is_flash: false,
        flash_sender_name: None,
        flash_sender_role: None,
    }))
}

/// Decode the simple `/patch/channel/{id}/say` injection: arg 0 is the payload
/// (string, required); arg 1 is an optional priority number (int/long/float —
/// QLab can send any). Lenient on priority: missing or out-of-range → Info, so a
/// fat-fingered cue still posts the message rather than being dropped.
fn decode_say(msg: OscMessage) -> Result<PatchEvent> {
    let channel_id = channel_id_from_addr(&msg.addr)?;
    let args = msg.args;
    if args.is_empty() {
        bail!("Expected at least 1 arg (payload) for .../say");
    }
    let payload = parse_string(&args[0])?;
    if payload.len() > MAX_PAYLOAD_LEN {
        bail!(
            "Rejected say: payload {} bytes exceeds max {}",
            payload.len(),
            MAX_PAYLOAD_LEN
        );
    }
    let priority = match args.get(1) {
        Some(OscType::Int(i)) => Priority::try_from(*i).unwrap_or(Priority::Info),
        Some(OscType::Long(l)) => Priority::try_from(*l as i32).unwrap_or(Priority::Info),
        Some(OscType::Float(f)) => Priority::try_from(*f as i32).unwrap_or(Priority::Info),
        Some(OscType::Double(d)) => Priority::try_from(*d as i32).unwrap_or(Priority::Info),
        _ => Priority::Info,
    };
    Ok(PatchEvent::Say {
        channel_id,
        payload,
        priority,
    })
}

fn decode_dm(msg: OscMessage) -> Result<PatchEvent> {
    let args = msg.args;
    if args.len() < 7 {
        bail!("Expected 7 args for /patch/dm, got {}", args.len());
    }
    let sender_id = parse_uuid(&args[0])?;
    let sender_name = parse_name(&args[1])?;
    let target_id = parse_uuid(&args[2])?;
    let message_id = parse_uuid(&args[3])?;
    let ts_ms = parse_long(&args[4])?;
    let priority = Priority::try_from(parse_int(&args[5])?)?;
    let payload = parse_string(&args[6])?;
    if payload.len() > MAX_PAYLOAD_LEN {
        bail!(
            "Rejected DM: payload {} bytes exceeds max {}",
            payload.len(),
            MAX_PAYLOAD_LEN
        );
    }
    let pmsg = PatchMessage {
        message_id,
        sender_id,
        sender_name,
        // The receiver keys the conversation by the *other* peer (the sender).
        channel_id: crate::dm::DmThreadKey::for_peer(sender_id).local_key(),
        timestamp: Utc
            .timestamp_millis_opt(ts_ms)
            .single()
            .context("Invalid timestamp")?,
        priority,
        payload,
        is_flash: false,
        flash_sender_name: None,
        flash_sender_role: None,
    };
    Ok(PatchEvent::DirectMessage {
        msg: pmsg,
        target_id,
    })
}

fn decode_dm_flash(msg: OscMessage) -> Result<PatchEvent> {
    let args = msg.args;
    if args.len() < 3 {
        bail!("Expected 3 args for /patch/dm/flash, got {}", args.len());
    }
    Ok(PatchEvent::DirectFlash {
        sender_id: parse_uuid(&args[0])?,
        sender_name: parse_name(&args[1])?,
        target_id: parse_uuid(&args[2])?,
    })
}

fn decode_ack(msg: OscMessage) -> Result<PatchEvent> {
    let args = msg.args;
    if args.len() < 2 {
        bail!("Expected 2 args for /patch/ack, got {}", args.len());
    }
    Ok(PatchEvent::Ack {
        message_id: parse_uuid(&args[0])?,
        peer_id: parse_uuid(&args[1])?,
    })
}

fn decode_presence(msg: OscMessage) -> Result<PatchEvent> {
    let args = msg.args;
    if args.len() < 4 {
        bail!("Expected 4 args for /patch/presence, got {}", args.len());
    }
    let peer_id = parse_uuid(&args[0])?;
    let peer_name = parse_name(&args[1])?;
    let channels_json = parse_string(&args[2])?;
    if channels_json.len() > MAX_PRESENCE_CHANNELS_JSON {
        bail!(
            "presence channels payload {} bytes exceeds max {}",
            channels_json.len(),
            MAX_PRESENCE_CHANNELS_JSON
        );
    }
    let channels: Vec<String> = serde_json::from_str(&channels_json)?;
    let ts_ms = parse_long(&args[3])?;
    // arg 4 (optional): role. Absent from older 4-arg peers → None; an empty
    // string (role explicitly cleared) also normalises to None. Oversized
    // roles are dropped to None rather than rejecting the whole heartbeat.
    let role = if args.len() >= 5 {
        match parse_name(&args[4]) {
            Ok(s) if !s.is_empty() => Some(s),
            _ => None,
        }
    } else {
        None
    };
    Ok(PatchEvent::Presence(PeerPresence {
        peer_id,
        peer_name,
        channels,
        role,
        timestamp: Utc
            .timestamp_millis_opt(ts_ms)
            .single()
            .context("Invalid timestamp")?,
    }))
}

fn decode_bye(msg: OscMessage) -> Result<PatchEvent> {
    if msg.args.is_empty() {
        bail!("Expected 1 arg for /patch/bye, got 0");
    }
    Ok(PatchEvent::Bye {
        peer_id: parse_uuid(&msg.args[0])?,
    })
}

/// Defensive cap on an announced channel-layout JSON blob (network input). A
/// full layout is a few KB; this bounds a malicious/oversized payload.
const MAX_CHANNELS_JSON: usize = 64 * 1024;

fn decode_channels_request(msg: OscMessage) -> Result<PatchEvent> {
    if msg.args.is_empty() {
        bail!("Expected 1 arg for /patch/channels/request, got 0");
    }
    Ok(PatchEvent::ChannelsRequest {
        peer_id: parse_uuid(&msg.args[0])?,
    })
}

fn decode_channels_announce(msg: OscMessage) -> Result<PatchEvent> {
    let args = msg.args;
    if args.len() < 3 {
        bail!(
            "Expected 3 args for /patch/channels/announce, got {}",
            args.len()
        );
    }
    let peer_id = parse_uuid(&args[0])?;
    let peer_name = parse_name(&args[1])?;
    let channels_json = parse_string(&args[2])?;
    if channels_json.len() > MAX_CHANNELS_JSON {
        bail!(
            "channels announce payload {} bytes exceeds max {}",
            channels_json.len(),
            MAX_CHANNELS_JSON
        );
    }
    Ok(PatchEvent::ChannelsAnnounce {
        peer_id,
        peer_name,
        channels_json,
    })
}

/// Defensive cap on an announced global-macros JSON blob (network input) —
/// mirrors `MAX_CHANNELS_JSON`.
const MAX_MACROS_JSON: usize = 64 * 1024;

fn decode_macros_request(msg: OscMessage) -> Result<PatchEvent> {
    if msg.args.is_empty() {
        bail!("Expected 1 arg for /patch/macros/request, got 0");
    }
    Ok(PatchEvent::MacrosRequest {
        peer_id: parse_uuid(&msg.args[0])?,
    })
}

fn decode_macros_announce(msg: OscMessage) -> Result<PatchEvent> {
    let args = msg.args;
    if args.len() < 3 {
        bail!(
            "Expected 3 args for /patch/macros/announce, got {}",
            args.len()
        );
    }
    let peer_id = parse_uuid(&args[0])?;
    let peer_name = parse_name(&args[1])?;
    let macros_json = parse_string(&args[2])?;
    if macros_json.len() > MAX_MACROS_JSON {
        bail!(
            "macros announce payload {} bytes exceeds max {}",
            macros_json.len(),
            MAX_MACROS_JSON
        );
    }
    Ok(PatchEvent::MacrosAnnounce {
        peer_id,
        peer_name,
        macros_json,
    })
}

fn decode_flash(msg: OscMessage) -> Result<PatchEvent> {
    // addr is /patch/channel/{id}/flash
    let channel_id = channel_id_from_addr(&msg.addr)?;
    let args = msg.args;
    if args.len() < 2 {
        bail!("Expected 2 args for .../flash, got {}", args.len());
    }
    // Older peers send 2 args (no id/timestamp): synthesize both locally.
    // Multi-path copies from such peers can't be deduped — status quo for
    // mixed-version networks.
    let (message_id, timestamp) = if args.len() >= 4 {
        let ts_ms = parse_long(&args[3])?;
        (
            parse_uuid(&args[2])?,
            Utc.timestamp_millis_opt(ts_ms)
                .single()
                .context("Invalid flash timestamp")?,
        )
    } else {
        (Uuid::new_v4(), Utc::now())
    };
    Ok(PatchEvent::Flash {
        flash: ChannelFlash {
            channel_id,
            sender_id: parse_uuid(&args[0])?,
            sender_name: parse_string(&args[1])?,
        },
        message_id,
        timestamp,
    })
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn parse_string(t: &OscType) -> Result<String> {
    if let OscType::String(s) = t {
        Ok(s.clone())
    } else {
        bail!("Expected OSC String, got {:?}", t)
    }
}

fn parse_int(t: &OscType) -> Result<i32> {
    if let OscType::Int(i) = t {
        Ok(*i)
    } else {
        bail!("Expected OSC Int, got {:?}", t)
    }
}

fn parse_long(t: &OscType) -> Result<i64> {
    if let OscType::Long(l) = t {
        Ok(*l)
    } else {
        bail!("Expected OSC Long, got {:?}", t)
    }
}

fn parse_uuid(t: &OscType) -> Result<Uuid> {
    let s = parse_string(t)?;
    Uuid::parse_str(&s).context("Invalid UUID")
}

// ── Tests ───────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::types::Priority;
    use chrono::Utc;

    fn sample_message() -> PatchMessage {
        PatchMessage {
            message_id: Uuid::new_v4(),
            sender_id: Uuid::new_v4(),
            // Quote chars exercise the string round-trip (also relevant to CSV export).
            sender_name: "FOH \"Eng\"".to_string(),
            channel_id: "rf".to_string(),
            timestamp: Utc::now(),
            priority: Priority::Critical,
            payload: "Battery low".to_string(),
            is_flash: false,
            flash_sender_name: None,
            flash_sender_role: None,
        }
    }

    #[test]
    fn message_round_trip() {
        let msg = sample_message();
        let bytes = encode_message(&msg).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Message(d) => {
                assert_eq!(d.message_id, msg.message_id);
                assert_eq!(d.sender_id, msg.sender_id);
                assert_eq!(d.sender_name, msg.sender_name);
                assert_eq!(d.channel_id, "rf"); // channel comes from the address path
                assert_eq!(d.priority, Priority::Critical);
                assert_eq!(d.payload, msg.payload);
                assert_eq!(
                    d.timestamp.timestamp_millis(),
                    msg.timestamp.timestamp_millis()
                );
            }
            other => panic!("expected Message, got {:?}", other),
        }
    }

    #[test]
    fn presence_round_trip() {
        let p = PeerPresence {
            peer_id: Uuid::new_v4(),
            peer_name: "MON".into(),
            channels: vec!["rf".into(), "audio".into()],
            role: Some("FOH".into()),
            timestamp: Utc::now(),
        };
        let bytes = encode_presence(&p).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Presence(d) => {
                assert_eq!(d.peer_id, p.peer_id);
                assert_eq!(d.peer_name, p.peer_name);
                assert_eq!(d.channels, p.channels);
                assert_eq!(d.role, Some("FOH".to_string())); // role round-trips
            }
            other => panic!("expected Presence, got {:?}", other),
        }
    }

    #[test]
    fn presence_without_role_arg_decodes_as_none() {
        // An older peer sends only 4 args (no role) — must still decode, role None.
        let legacy = OscMessage {
            addr: addresses::PRESENCE.to_string(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("MON".into()),
                OscType::String("[]".into()),
                OscType::Long(Utc::now().timestamp_millis()),
            ],
        };
        match decode_message(legacy).unwrap() {
            PatchEvent::Presence(d) => assert_eq!(d.role, None),
            other => panic!("expected Presence, got {:?}", other),
        }
        // An explicitly-empty role string also normalises to None.
        let empty_role = PeerPresence {
            peer_id: Uuid::new_v4(),
            peer_name: "MON".into(),
            channels: vec![],
            role: None,
            timestamp: Utc::now(),
        };
        let bytes = encode_presence(&empty_role).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Presence(d) => assert_eq!(d.role, None),
            other => panic!("expected Presence, got {:?}", other),
        }
    }

    #[test]
    fn flash_round_trip_carries_channel_in_address_and_id_and_timestamp() {
        let f = ChannelFlash {
            channel_id: "lighting".into(),
            sender_id: Uuid::new_v4(),
            sender_name: "LD".into(),
        };
        let id = Uuid::new_v4();
        let ts = Utc.timestamp_millis_opt(1_750_000_000_000).unwrap();
        let bytes = encode_flash(&f, id, ts).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Flash {
                flash: d,
                message_id,
                timestamp,
            } => {
                assert_eq!(d.channel_id, "lighting");
                assert_eq!(d.sender_id, f.sender_id);
                assert_eq!(d.sender_name, f.sender_name);
                // Both dedup key and sender clock survive the wire.
                assert_eq!(message_id, id);
                assert_eq!(timestamp, ts);
            }
            other => panic!("expected Flash, got {:?}", other),
        }
    }

    #[test]
    fn legacy_two_arg_flash_decodes_with_synthesized_id_and_local_time() {
        // An older peer sends only (sender_id, sender_name) — must still
        // decode; id/timestamp are synthesized locally (no dedup possible).
        let legacy = OscMessage {
            addr: addresses::channel_flash("rf"),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("LD".into()),
            ],
        };
        let before = Utc::now();
        match decode_message(legacy).unwrap() {
            PatchEvent::Flash {
                flash, timestamp, ..
            } => {
                assert_eq!(flash.channel_id, "rf");
                assert!(timestamp >= before && timestamp <= Utc::now());
            }
            other => panic!("expected Flash, got {:?}", other),
        }
    }

    #[test]
    fn ack_round_trip() {
        let (mid, pid) = (Uuid::new_v4(), Uuid::new_v4());
        let bytes = encode_ack(mid, pid).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Ack {
                message_id,
                peer_id,
            } => {
                assert_eq!(message_id, mid);
                assert_eq!(peer_id, pid);
            }
            other => panic!("expected Ack, got {:?}", other),
        }
    }

    #[test]
    fn dm_round_trip_sets_receiver_channel_key() {
        let target = Uuid::new_v4();
        let mut m = sample_message();
        m.priority = Priority::Warning;
        // On the wire the message's own channel_id is irrelevant — the receiver
        // derives `dm:{sender}`.
        let bytes = encode_dm(&m, target).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::DirectMessage { msg, target_id } => {
                assert_eq!(target_id, target);
                assert_eq!(msg.sender_id, m.sender_id);
                assert_eq!(msg.message_id, m.message_id);
                assert_eq!(msg.payload, m.payload);
                assert_eq!(msg.priority, Priority::Warning);
                // Receiver keys it by the sender.
                assert_eq!(
                    msg.channel_id,
                    crate::dm::DmThreadKey::for_peer(m.sender_id).local_key()
                );
            }
            other => panic!("expected DirectMessage, got {:?}", other),
        }
    }

    #[test]
    fn dm_flash_round_trip() {
        let f = ChannelFlash {
            channel_id: "ignored-on-the-wire".into(),
            sender_id: Uuid::new_v4(),
            sender_name: "FOH".into(),
        };
        let target = Uuid::new_v4();
        let bytes = encode_dm_flash(&f, target).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::DirectFlash {
                sender_id,
                sender_name,
                target_id,
            } => {
                assert_eq!(sender_id, f.sender_id);
                assert_eq!(sender_name, "FOH");
                assert_eq!(target_id, target);
            }
            other => panic!("expected DirectFlash, got {:?}", other),
        }
        // Too few args must bail, not panic.
        assert!(decode_message(OscMessage {
            addr: addresses::DM_FLASH.to_string(),
            args: vec![OscType::String(Uuid::new_v4().to_string())],
        })
        .is_err());
    }

    #[test]
    fn bye_round_trip() {
        let pid = Uuid::new_v4();
        let bytes = encode_bye(pid).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Bye { peer_id } => assert_eq!(peer_id, pid),
            other => panic!("expected Bye, got {:?}", other),
        }
    }

    #[test]
    fn channels_request_round_trip() {
        let pid = Uuid::new_v4();
        let bytes = encode_channels_request(pid).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::ChannelsRequest { peer_id } => assert_eq!(peer_id, pid),
            other => panic!("expected ChannelsRequest, got {:?}", other),
        }
    }

    #[test]
    fn channels_announce_round_trip_carries_json() {
        let pid = Uuid::new_v4();
        let json = r##"[{"id":"rf","display_name":"RF","color":"#1E88E5"}]"##;
        let bytes = encode_channels_announce(pid, "FOH", json).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::ChannelsAnnounce {
                peer_id,
                peer_name,
                channels_json,
            } => {
                assert_eq!(peer_id, pid);
                assert_eq!(peer_name, "FOH");
                assert_eq!(channels_json, json);
            }
            other => panic!("expected ChannelsAnnounce, got {:?}", other),
        }
    }

    #[test]
    fn oversized_channels_announce_is_rejected() {
        let big = "x".repeat(MAX_CHANNELS_JSON + 1);
        let msg = OscMessage {
            addr: addresses::CHANNELS_ANNOUNCE.to_string(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("FOH".into()),
                OscType::String(big),
            ],
        };
        assert!(decode_message(msg).is_err());
    }

    #[test]
    fn macros_request_round_trip() {
        let pid = Uuid::new_v4();
        let bytes = encode_macros_request(pid).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::MacrosRequest { peer_id } => assert_eq!(peer_id, pid),
            other => panic!("expected MacrosRequest, got {:?}", other),
        }
    }

    #[test]
    fn macros_announce_round_trip_carries_json() {
        let pid = Uuid::new_v4();
        let json = r##"[{"label":"GO","payload":"Go","priority":1}]"##;
        let bytes = encode_macros_announce(pid, "FOH", json).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::MacrosAnnounce {
                peer_id,
                peer_name,
                macros_json,
            } => {
                assert_eq!(peer_id, pid);
                assert_eq!(peer_name, "FOH");
                assert_eq!(macros_json, json);
            }
            other => panic!("expected MacrosAnnounce, got {:?}", other),
        }
    }

    #[test]
    fn oversized_macros_announce_is_rejected() {
        let big = "x".repeat(MAX_MACROS_JSON + 1);
        let msg = OscMessage {
            addr: addresses::MACROS_ANNOUNCE.to_string(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("FOH".into()),
                OscType::String(big),
            ],
        };
        assert!(decode_message(msg).is_err());
    }

    #[test]
    fn say_decodes_payload_and_optional_priority() {
        // Payload only → Info.
        let m = OscMessage {
            addr: "/patch/channel/rf/say".into(),
            args: vec![OscType::String("Battery low".into())],
        };
        match decode_message(m).unwrap() {
            PatchEvent::Say {
                channel_id,
                payload,
                priority,
            } => {
                assert_eq!(channel_id, "rf");
                assert_eq!(payload, "Battery low");
                assert_eq!(priority, Priority::Info);
            }
            other => panic!("expected Say, got {:?}", other),
        }
        // Payload + critical priority (int).
        let m = OscMessage {
            addr: "/patch/channel/stage/say".into(),
            args: vec![OscType::String("Evacuate".into()), OscType::Int(3)],
        };
        match decode_message(m).unwrap() {
            PatchEvent::Say { priority, .. } => assert_eq!(priority, Priority::Critical),
            other => panic!("expected Say, got {:?}", other),
        }
        // Out-of-range / float priority is lenient → Info (message still posts).
        let m = OscMessage {
            addr: "/patch/channel/rf/say".into(),
            args: vec![OscType::String("hi".into()), OscType::Float(9.0)],
        };
        match decode_message(m).unwrap() {
            PatchEvent::Say { priority, .. } => assert_eq!(priority, Priority::Info),
            other => panic!("expected Say, got {:?}", other),
        }
        // Bad channel id is rejected; no payload is rejected.
        assert!(decode_message(OscMessage {
            addr: "/patch/channel/BAD!/say".into(),
            args: vec![OscType::String("x".into())],
        })
        .is_err());
        assert!(decode_message(OscMessage {
            addr: "/patch/channel/rf/say".into(),
            args: vec![],
        })
        .is_err());
    }

    #[test]
    fn encode_osc_rejects_bad_path_and_encodes_good() {
        assert!(encode_osc("no-leading-slash", OscArgKind::String, None).is_err());
        let bytes = encode_osc("/cue/1/start", OscArgKind::String, Some("go")).unwrap();
        // A non-Patch address decodes as a generic (Unknown) OSC message.
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Unknown(m) => {
                assert_eq!(m.addr, "/cue/1/start");
                assert_eq!(m.args.len(), 1);
            }
            other => panic!("expected Unknown, got {:?}", other),
        }
        // No-arg form encodes an empty arg list.
        let bytes = encode_osc("/go", OscArgKind::String, None).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Unknown(m) => assert!(m.args.is_empty()),
            other => panic!("expected Unknown, got {:?}", other),
        }
    }

    #[test]
    fn encode_osc_builds_the_arg_type_matching_osc_type() {
        let bytes = encode_osc("/cue/1/start", OscArgKind::Int, Some("3")).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Unknown(m) => assert_eq!(m.args, vec![OscType::Int(3)]),
            other => panic!("expected Unknown, got {:?}", other),
        }

        let bytes = encode_osc("/fader/1", OscArgKind::Float, Some("0.75")).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Unknown(m) => assert_eq!(m.args, vec![OscType::Float(0.75)]),
            other => panic!("expected Unknown, got {:?}", other),
        }

        let bytes = encode_osc("/scene", OscArgKind::String, Some("blackout")).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Unknown(m) => {
                assert_eq!(m.args, vec![OscType::String("blackout".into())])
            }
            other => panic!("expected Unknown, got {:?}", other),
        }
    }

    #[test]
    fn encode_osc_rejects_a_value_that_does_not_match_arg_type() {
        assert!(encode_osc("/cue/1/start", OscArgKind::Int, Some("abc")).is_err());
        assert!(encode_osc("/fader/1", OscArgKind::Float, Some("loud")).is_err());
        // A String arg_type accepts anything — no parse failure possible.
        assert!(encode_osc("/scene", OscArgKind::String, Some("3")).is_ok());
    }

    #[test]
    fn empty_bye_is_rejected() {
        let msg = OscMessage {
            addr: "/patch/bye".to_string(),
            args: vec![],
        };
        assert!(decode_message(msg).is_err());
    }

    #[test]
    fn priority_integer_mapping_is_the_wire_contract() {
        // 0=debug 1=info 2=warning 3=critical — must match docs/README/OSC integ.
        assert_eq!(Priority::try_from(0).unwrap(), Priority::Debug);
        assert_eq!(Priority::try_from(1).unwrap(), Priority::Info);
        assert_eq!(Priority::try_from(2).unwrap(), Priority::Warning);
        assert_eq!(Priority::try_from(3).unwrap(), Priority::Critical);
        assert!(Priority::try_from(4).is_err());
        assert_eq!(Priority::Critical as i32, 3);
    }

    #[test]
    fn truncated_message_is_rejected_not_panicked() {
        // Too few args must bail (not index-panic) — the codec bounds guard.
        let msg = OscMessage {
            addr: "/patch/channel/rf/message".to_string(),
            args: vec![OscType::String(Uuid::new_v4().to_string())], // 1 of 6
        };
        assert!(decode_message(msg).is_err());
    }

    #[test]
    fn out_of_range_priority_is_rejected() {
        let msg = OscMessage {
            addr: "/patch/channel/rf/message".to_string(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("sender".into()),
                OscType::String(Uuid::new_v4().to_string()),
                OscType::Long(Utc::now().timestamp_millis()),
                OscType::Int(99), // invalid priority
                OscType::String("payload".into()),
            ],
        };
        assert!(decode_message(msg).is_err());
    }

    #[test]
    fn unknown_address_decodes_to_unknown() {
        let msg = OscMessage {
            addr: "/foo/bar".to_string(),
            args: vec![],
        };
        let bytes = rosc::encoder::encode(&OscPacket::Message(msg)).unwrap();
        assert!(matches!(
            decode_packet(&bytes).unwrap(),
            PatchEvent::Unknown(_)
        ));
    }

    fn message_with(addr: &str, payload: &str) -> OscMessage {
        OscMessage {
            addr: addr.to_string(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("sender".into()),
                OscType::String(Uuid::new_v4().to_string()),
                OscType::Long(0),
                OscType::Int(1),
                OscType::String(payload.into()),
            ],
        }
    }

    #[test]
    fn rejects_invalid_inbound_channel_id() {
        // Uppercase + symbol can't be a real channel slug — drop the packet.
        assert!(decode_message(message_with("/patch/channel/RF!/message", "hi")).is_err());
        // Empty channel segment too.
        assert!(decode_message(message_with("/patch/channel//message", "hi")).is_err());
    }

    #[test]
    fn rejects_oversized_inbound_payload() {
        let big = "x".repeat(MAX_PAYLOAD_LEN + 1);
        assert!(decode_message(message_with("/patch/channel/rf/message", &big)).is_err());
        // Exactly at the limit is accepted.
        let ok = "x".repeat(MAX_PAYLOAD_LEN);
        assert!(decode_message(message_with("/patch/channel/rf/message", &ok)).is_ok());
    }

    #[test]
    fn rejects_extra_address_segments_rather_than_aliasing() {
        // `/patch/channel/rf/x/message` must not post to channel "rf".
        assert!(decode_message(message_with("/patch/channel/rf/x/message", "hi")).is_err());
        assert!(decode_message(OscMessage {
            addr: "/patch/channel/rf/x/say".into(),
            args: vec![OscType::String("hi".into())],
        })
        .is_err());
        assert!(decode_message(OscMessage {
            addr: "/patch/channel/rf/x/flash".into(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("LD".into()),
            ],
        })
        .is_err());
    }

    #[test]
    fn rejects_oversized_sender_name() {
        let big = "x".repeat(MAX_NAME_LEN + 1);
        let msg = OscMessage {
            addr: "/patch/channel/rf/message".to_string(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String(big),
                OscType::String(Uuid::new_v4().to_string()),
                OscType::Long(0),
                OscType::Int(1),
                OscType::String("hi".into()),
            ],
        };
        assert!(decode_message(msg).is_err());
    }

    #[test]
    fn presence_rejects_oversized_name_and_channels_but_tolerates_big_role() {
        let peer_id = Uuid::new_v4().to_string();
        // Oversized peer name → rejected.
        assert!(decode_message(OscMessage {
            addr: addresses::PRESENCE.to_string(),
            args: vec![
                OscType::String(peer_id.clone()),
                OscType::String("x".repeat(MAX_NAME_LEN + 1)),
                OscType::String("[]".into()),
                OscType::Long(0),
            ],
        })
        .is_err());
        // Oversized channels JSON → rejected.
        let big_channels = format!("[{}]", r#""rf","#.repeat(2048).trim_end_matches(','));
        assert!(big_channels.len() > MAX_PRESENCE_CHANNELS_JSON);
        assert!(decode_message(OscMessage {
            addr: addresses::PRESENCE.to_string(),
            args: vec![
                OscType::String(peer_id.clone()),
                OscType::String("MON".into()),
                OscType::String(big_channels),
                OscType::Long(0),
            ],
        })
        .is_err());
        // Oversized role (optional garnish) → normalised to None, heartbeat kept.
        match decode_message(OscMessage {
            addr: addresses::PRESENCE.to_string(),
            args: vec![
                OscType::String(peer_id),
                OscType::String("MON".into()),
                OscType::String("[]".into()),
                OscType::Long(0),
                OscType::String("x".repeat(MAX_NAME_LEN + 1)),
            ],
        })
        .unwrap()
        {
            PatchEvent::Presence(p) => assert_eq!(p.role, None),
            other => panic!("expected Presence, got {other:?}"),
        }
    }

    #[test]
    fn rejects_invalid_flash_channel_id() {
        let flash = OscMessage {
            addr: "/patch/channel/BAD!/flash".to_string(),
            args: vec![
                OscType::String(Uuid::new_v4().to_string()),
                OscType::String("sender".into()),
            ],
        };
        assert!(decode_message(flash).is_err());
    }
}

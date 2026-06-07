//! Encode/decode PATCH OSC packets using the `rosc` crate.

use anyhow::{bail, Context, Result};
use chrono::{TimeZone, Utc};
use rosc::{OscMessage, OscPacket, OscType};
use uuid::Uuid;

use super::{
    addresses,
    types::{ChannelFlash, PatchMessage, PeerPresence, Priority},
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

/// Encode a channel flash packet.
pub fn encode_flash(flash: &ChannelFlash) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::channel_flash(&flash.channel_id),
        args: vec![
            OscType::String(flash.sender_id.to_string()),
            OscType::String(flash.sender_name.clone()),
        ],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode flash")
}

/// Encode a departure announcement (sent on graceful shutdown).
pub fn encode_bye(peer_id: Uuid) -> Result<Vec<u8>> {
    let osc = OscMessage {
        addr: addresses::BYE.to_string(),
        args: vec![OscType::String(peer_id.to_string())],
    };
    rosc::encoder::encode(&OscPacket::Message(osc)).context("Failed to encode /patch/bye")
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
    Ack { message_id: Uuid, peer_id: Uuid },
    Presence(PeerPresence),
    Bye { peer_id: Uuid },
    Flash(ChannelFlash),
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
        addresses::ACK => decode_ack(msg),
        addresses::PRESENCE => decode_presence(msg),
        addresses::BYE => decode_bye(msg),
        addr if addr.ends_with("/flash") => decode_flash(msg),
        _ => Ok(PatchEvent::Unknown(msg)),
    }
}

/// Maximum accepted payload length for an inbound message. Defensive bound —
/// operational messages are short, while a UDP datagram can carry ~64 KB.
const MAX_PAYLOAD_LEN: usize = 4096;

/// Channel ids must match this slug rule everywhere they can reach an OSC
/// address: inbound packets (`decode_*`), the UI (`api::upsert_channel`), and
/// loaded/imported sessions (`AppState::apply_session`). Keeps a remote sender
/// or a hand-edited session file from injecting arbitrary buffer keys or
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
    let parts: Vec<&str> = msg.addr.split('/').collect();
    let channel_id = parts.get(3).copied().unwrap_or("unknown").to_string();
    if !valid_channel_id(&channel_id) {
        bail!("Rejected message: invalid channel id {:?}", channel_id);
    }
    let args = msg.args;
    if args.len() < 6 {
        bail!(
            "Expected 6 args for /patch/channel/.../message, got {}",
            args.len()
        );
    }
    let sender_id = parse_uuid(&args[0])?;
    let sender_name = parse_string(&args[1])?;
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
    }))
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
    let peer_name = parse_string(&args[1])?;
    let channels: Vec<String> = serde_json::from_str(&parse_string(&args[2])?)?;
    let ts_ms = parse_long(&args[3])?;
    // arg 4 (optional): role. Absent from older 4-arg peers → None; an empty
    // string (role explicitly cleared) also normalises to None.
    let role = if args.len() >= 5 {
        match parse_string(&args[4]) {
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

fn decode_flash(msg: OscMessage) -> Result<PatchEvent> {
    // addr is /patch/channel/{id}/flash
    let parts: Vec<&str> = msg.addr.split('/').collect();
    let channel_id = parts.get(3).copied().unwrap_or("unknown").to_string();
    if !valid_channel_id(&channel_id) {
        bail!("Rejected flash: invalid channel id {:?}", channel_id);
    }
    let args = msg.args;
    if args.len() < 2 {
        bail!("Expected 2 args for .../flash, got {}", args.len());
    }
    Ok(PatchEvent::Flash(ChannelFlash {
        channel_id,
        sender_id: parse_uuid(&args[0])?,
        sender_name: parse_string(&args[1])?,
    }))
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
    fn flash_round_trip_carries_channel_in_address() {
        let f = ChannelFlash {
            channel_id: "lighting".into(),
            sender_id: Uuid::new_v4(),
            sender_name: "LD".into(),
        };
        let bytes = encode_flash(&f).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Flash(d) => {
                assert_eq!(d.channel_id, "lighting");
                assert_eq!(d.sender_id, f.sender_id);
                assert_eq!(d.sender_name, f.sender_name);
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
    fn bye_round_trip() {
        let pid = Uuid::new_v4();
        let bytes = encode_bye(pid).unwrap();
        match decode_packet(&bytes).unwrap() {
            PatchEvent::Bye { peer_id } => assert_eq!(peer_id, pid),
            other => panic!("expected Bye, got {:?}", other),
        }
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

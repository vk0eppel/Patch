//! Message export to CSV, moved out of `api.rs` (#143) — the one place that
//! file was not a thin FFI facade (ADR-0004). Pure domain logic; no
//! `AppEvent`/broadcast-channel dependency, no file I/O (the caller owns
//! writing the string to disk).

/// Escape a value for a quoted CSV field, neutralising spreadsheet formula
/// injection. Excel/Sheets treat a cell starting with `=`, `+`, `-`, `@`, tab,
/// or CR as a formula; since these values come from arbitrary LAN OSC sources,
/// such cells are prefixed with `'`. Double-quotes are doubled per RFC 4180.
fn csv_escape(s: &str) -> String {
    let needs_guard = s
        .chars()
        .next()
        .is_some_and(|c| matches!(c, '=' | '+' | '-' | '@' | '\t' | '\r'));
    let mut out = String::with_capacity(s.len() + 2);
    if needs_guard {
        out.push('\'');
    }
    out.push_str(&s.replace('"', "\"\""));
    out
}

/// Render `messages` as CSV. When `channel_id` is `Some`, only that channel's
/// messages are included and the `channel` column is omitted; when `None`,
/// every message is included with a `channel` column.
pub(crate) fn messages_to_csv(
    messages: &[crate::osc::types::PatchMessage],
    channel_id: Option<&str>,
) -> String {
    let filtered: Vec<_> = match channel_id {
        Some(id) => messages.iter().filter(|m| m.channel_id == id).collect(),
        None => messages.iter().collect(),
    };

    let include_channel = channel_id.is_none();
    let mut out = String::new();

    if include_channel {
        out.push_str("timestamp,channel,sender,priority,message\n");
    } else {
        out.push_str("timestamp,sender,priority,message\n");
    }

    for m in &filtered {
        let ts = m.timestamp.format("%Y-%m-%dT%H:%M:%S").to_string();
        let priority = match m.priority {
            crate::osc::types::Priority::Debug => "debug",
            crate::osc::types::Priority::Info => "info",
            crate::osc::types::Priority::Warning => "warning",
            crate::osc::types::Priority::Critical => "critical",
        };
        // Payload/sender/channel are network-sourced — neutralise spreadsheet
        // formula injection in addition to RFC 4180 quote-escaping.
        let payload = csv_escape(&m.payload);
        let sender = csv_escape(&m.sender_name);
        if include_channel {
            out.push_str(&format!(
                "{},\"{}\",\"{}\",{},\"{}\"\n",
                ts,
                csv_escape(&m.channel_id),
                sender,
                priority,
                payload
            ));
        } else {
            out.push_str(&format!(
                "{},\"{}\",{},\"{}\"\n",
                ts, sender, priority, payload
            ));
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::types::{PatchMessage, Priority};
    use uuid::Uuid;

    fn msg(channel: &str, sender: &str, payload: &str) -> PatchMessage {
        PatchMessage::new(Uuid::new_v4(), sender, channel, Priority::Info, payload)
    }

    #[test]
    fn csv_escape_prefixes_a_leading_equals_to_neutralise_formula_injection() {
        assert_eq!(csv_escape("=cmd|' /C calc'!A0"), "'=cmd|' /C calc'!A0");
    }

    #[test]
    fn csv_escape_guards_every_formula_trigger_character() {
        for c in ['=', '+', '-', '@', '\t', '\r'] {
            let input = format!("{c}danger");
            assert_eq!(csv_escape(&input), format!("'{c}danger"));
        }
    }

    #[test]
    fn csv_escape_doubles_embedded_quotes_per_rfc4180() {
        assert_eq!(csv_escape(r#"say "hi""#), r#"say ""hi"""#);
    }

    #[test]
    fn csv_escape_leaves_ordinary_text_untouched() {
        assert_eq!(csv_escape("FOH Audio"), "FOH Audio");
    }

    #[test]
    fn messages_to_csv_for_a_single_channel_omits_the_channel_column() {
        let msgs = vec![msg("rf", "FOH", "check 1")];
        let csv = messages_to_csv(&msgs, Some("rf"));
        let mut lines = csv.lines();
        assert_eq!(lines.next().unwrap(), "timestamp,sender,priority,message");
        assert!(lines.next().unwrap().ends_with(r#""FOH",info,"check 1""#));
    }

    #[test]
    fn messages_to_csv_for_all_channels_includes_the_channel_column() {
        let msgs = vec![msg("rf", "FOH", "check 1")];
        let csv = messages_to_csv(&msgs, None);
        let mut lines = csv.lines();
        assert_eq!(
            lines.next().unwrap(),
            "timestamp,channel,sender,priority,message"
        );
        assert!(lines
            .next()
            .unwrap()
            .ends_with(r#""rf","FOH",info,"check 1""#));
    }

    #[test]
    fn messages_to_csv_for_a_single_channel_excludes_other_channels() {
        let msgs = vec![msg("rf", "FOH", "a"), msg("audio", "PM", "b")];
        let csv = messages_to_csv(&msgs, Some("rf"));
        assert_eq!(csv.lines().count(), 2); // header + one row
        assert!(csv.contains('a'));
        assert!(!csv.contains("PM"));
    }
}

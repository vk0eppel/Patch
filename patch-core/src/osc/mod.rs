//! OSC type definitions and helpers for the PATCH namespace.
//!
//! All PATCH OSC addresses follow the pattern `/patch/<type>[/<channel_id>]`.
//! This module owns the canonical address strings and the helpers to
//! build/parse PATCH-specific OSC packets using the `rosc` crate.

pub mod addresses;
pub mod codec;
pub mod types;

pub use codec::{decode_packet, encode_message};
pub use types::PatchMessage;

# OSC macro validation: one check, three policies by trust level

A Macro's OSC target (`OscTarget` — address, port, path, arg/arg_type) is validated by a single function, `validate_osc_target`, but each caller applies a different policy on top of it, deliberately:

- **Live UI edits** (`upsert_macro`, `upsert_global_macro`) reject immediately — the Operator is present and can fix the mistake on the spot.
- **Local show file / `patch.toml` loads** (`apply_show_file_full`, `apply_show_file`) reject the *whole file* atomically, before any mutation — matching the existing `validate_channel_id` precedent for the same functions. A malformed macro should surface as a load failure, not load silently with the wrong behaviour.
- **A peer's network announce** (`merge_channels`) drops just the one bad macro and keeps merging everything else — this is untrusted input from a possibly different/older Patch build, and the existing design for this path is additive/best-effort (an invalid channel id from a peer is already skipped, not treated as a reason to reject the whole announce).

This was previously two functions with accidentally-different behaviour (`api::validate_osc` rejected; `state::channel::normalize_macro_osc` silently downgraded `arg_type` to `String` on mismatch) rather than one check with an intentional, named policy per caller. Don't re-merge these into one universal policy — the three trust levels (Operator-present, local file, untrusted peer) genuinely warrant different failure behaviour, and collapsing them either makes a live UI typo save silently wrong, or makes a malformed show file unloadable as a whole, or makes one peer's broken macro block adopting their entire channel list.

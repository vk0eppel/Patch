# Config-file load validation: a 4th trust level, drop-and-warn

`Config::load_or_default` deserializes `default_channels` (with their macros' `OscTarget`s) and `static_peers` from `patch.toml` without validating them — `validate_osc_target` and `validate_channel_id`/`StaticPeer::new` only ever ran at the moment each entry was originally written. A hand-edited `patch.toml` can load a malformed macro or peer silently; today the only thing that catches it is firing that macro live via `dispatch_osc`.

This is a 4th trust level beyond the three [ADR-0002](0002-osc-macro-validation-policy-by-trust-level.md) names (Operator-present live edit → reject immediately; show-file *import* via `apply_show_file[_full]` → atomic reject-the-whole-file; peer announce → drop-and-continue): **the startup load of `patch.toml` itself**, where no operator is present to immediately fix a rejection.

We decided: validate `default_channels`' macros and `static_peers` at load time, and on failure **drop the offending entry and log a warning**, then continue starting — the same policy as peer-announce, not the atomic-reject-the-whole-file policy `apply_show_file` uses.

Refuse-to-start was rejected even though it matches the "local file" precedent: a single bad field in `patch.toml` would brick a launch with no recovery path if discovered on a live show day, which is worse than starting with one macro silently degraded (and now logged) until someone fixes the file. Show-file *import* is a deliberate, repeatable, operator-present action where atomic rejection is recoverable in the moment; a config load at process start is not.

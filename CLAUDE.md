# CLAUDE.md

Patch is a real-time operational communication tool for live production teams (AV, broadcast, theatre, touring) — not a chat app. Every feature must answer: *"Does this help a crew execute a live show more reliably?"*

## Stack

| Layer | Technology |
|---|---|
| UI | Flutter (macOS, Windows, Linux, iOS, iPad) |
| Engine | Rust (tokio), linked as `cdylib`/`staticlib` |
| UI ↔ engine | `flutter_rust_bridge` v2 — typed FFI, no IPC |
| OSC transport | UDP unicast + broadcast via `rosc` |
| Discovery | mDNS (`mdns-sd`) + OSC broadcast beacon + manual static IP |
| Config | `patch.toml` (TOML, auto-created on first run) |

**Single process, single binary.** No IPC, no sidecar, no TCP socket. Build driven by `cargokit` under `patch_app/rust_builder/`.

## Commands

```bash
cd patch_app && flutter run -d macos   # dev run (see README.md Prerequisites first)
cargo test -p patch_core               # Rust tests
cd patch_app && flutter test           # Flutter tests
```

Full command set (lint, codegen, release) lives in CONVENTION.md; prerequisites/platform setup in README.md.

## Developer docs

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — subsystem design: FFI bridge, OSC namespace, discovery, show files, DMs, MIDI, reliability, config I/O
- **[ERRORS.md](ERRORS.md)** — proven mistakes and traps; read before touching transport, discovery, UI flash, or the bridge
- **[CONVENTION.md](CONVENTION.md)** — coding conventions, CI requirements, patterns to follow
- **[docs/](docs/README.md)** — end-user docs (quick start, channels & show files, networking, OSC integration, troubleshooting); read when a change touches operator-facing behavior

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`vk0eppel/Patch`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.


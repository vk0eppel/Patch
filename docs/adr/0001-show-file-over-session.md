# Show File over Session

The saved channel-layout concept was initially called "Session" in all code and UI. We renamed it to "Show File" everywhere — Rust module, API types, Dart widgets, disk directory, and event names.

"Session" is generic and collides with network sessions, audio sessions (`AVAudioSession`), and general app lifecycle language. "Show File" is the term live-production Operators already use for a saved configuration tied to a specific production or venue. Keeping the code term aligned with the domain language makes the codebase legible to contributors who come from a live-production background.

# Third-party code

- **agent-desktop** (Vercel Labs), Apache-2.0, https://github.com/vercel-labs/agent-desktop at commit
  5261b5287b5208e7c4bf3713df6f66faaaf2c4cc. Fetched and built from source by
  `scripts/build-engine.sh` with `cargo build --locked` (its own `Cargo.lock`). Not vendored into this
  repository's history: `third_party/` and `engine/` are git-ignored build outputs, and the licence is
  copied next to the binary. Supply-chain note from the design: the pinned source's first vetting
  came back `ask` (new to the fleet, no release attestations, three RustSec advisories with unknown
  severity in Linux D-Bus crates); building on it is Donovan's decision.
- **cage** (Hjalmar Fridén et al.), MIT, https://github.com/cage-kiosk/cage v0.3.1. Test-only: `tests/build-host.sh`
  builds it with one changed number (xdg_wm_base v5 to v6) as the headless host for the nested Hyprland.

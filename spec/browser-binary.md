# The browser helper as one executable

Polycarp ships Tabkyra's command (`tabkyra`, `polycarp browser`) as `polycarp-browser`: one Mach-O file, no Node on the
machine. Built by `scripts/build-browser.sh` from `browser/cli` (esbuild bundle, then `scripts/compile.mjs`).

## Choice: `bun build --compile --bytecode`

Measured 2026-11-05 on the build Mac (Apple silicon, Bun 1.3.14, Node 24.15.0), median of 25 cold spawns each, temp HOME,
the same 1.9 MB esbuild bundle. "tools/list" is spawn, `initialize`, `tools/list` answered (43 tools).

| Build | Size | `--version` | `mcp` tools/list |
| --- | --- | --- | --- |
| `node dist/index.js` (what runs today) | Node install | 127 ms | 168 ms |
| Node 24 single-executable application (CJS bundle, no code cache) | 121 MB | 110 ms | 161 ms |
| `bun build --compile` | 65 MB | 89-94 ms | 137-148 ms |
| `bun build --compile --bytecode` (chosen) | 73.5 MB | 56-68 ms | 88-105 ms |

Why Bun: faster on both, 40% smaller, and the other architecture is one flag (`--target=bun-darwin-x64`; Bun fetches that
runtime once). A Node SEA needs a CommonJS bundle, `postject`, a signature strip and re-sign, and a second Node download per
architecture, and its main script cannot be an ES module on Node 24. Both x86_64 (71 MB without bytecode) and arm64 were built.

Costs of Bun: the runtime is Bun's JavaScriptCore, not V8, so the whole `browser/cli` suite also runs the real executable
(`test/compiled.test.mjs`); its licence (MIT, with LGPL JavaScriptCore) ships in the app's `licenses/`.
No hardened runtime or notarization is used by Polycarp's bundle today; if that starts, the helper needs the JIT entitlements
(`com.apple.security.cs.allow-jit`, `allow-unsigned-executable-memory`).

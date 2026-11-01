# Security

Report a vulnerability privately through
[GitHub security advisories](https://github.com/baney75/baneyspaces/security/advisories/new),
not a public issue.

## What BaneySpaces can do

- **Accessibility.** Needed to list, hide, show and move other apps' windows, and to watch the
  Mission Control key and ⌃↑ so the overview can open in their place. It checks each key
  press's code to spot those two and acts on nothing else. Keys are never recorded or stored.
- **Keyboard shortcuts.** Setup's Free Them button changes macOS's own screenshot or desktop
  switching shortcuts, only when you click it.
- **Automation (Apple Events).** The Deck reads Ghostty's, Terminal's, iTerm2's and Chromium
  browsers' windows and tabs through AppleScript, and asks macOS for permission once per app.
  It types into a terminal only when you or an agent run `baneyspaces send`.
- **A local socket.** `deck.sock` in `~/Library/Application Support/BaneySpaces` takes commands
  from the `baneyspaces` tool and agent hooks. Any program running as you can use it, the same
  as any program running as you can already script your apps. Other users can't.
- **Network.** No analytics and no account. The only request it makes on its own is the daily
  update check, which reads GitHub's public release list and can be turned off. Nothing listens
  for connections unless you turn it on: `baneyspaces remote on`
  listens on your Tailscale address only (100.64.0.0/10 on a tunnel interface), needs a 256-bit
  token stored with mode 0600, and allows only looking (ping, list, agent status) and giving the
  agent workspace work (agent open, agent run). A remote caller can't focus, type, move windows
  or change what you see. `remote off` closes it. The `--on HOST` client sends the token only to
  tailnet addresses.
- **Hooks.** `baneyspaces hooks install` adds entries to `~/.claude/settings.json` and a file
  in `~/.grok/hooks`. It backs up the settings file once and removes only its own entries.
- Settings and window positions stay in `~/Library/Application Support/BaneySpaces` and its
  preferences.
- **Signing.** The installer builds the app on your Mac and signs it with a local certificate
  kept in its own keychain, never the login keychain. It is not trusted for anything else.

## Local secret scan

`.githooks/pre-commit` runs `scripts/secret-scan.py` on what you staged. The script
flags token prefixes, PEM headers, basic-auth URLs and a short list of other shapes,
and prints the file, line number and pattern name (never the matched value). Enable it
once per checkout:

```sh
git config core.hooksPath .githooks
```

Remote tokens stay in the 0600 file under Application Support; do not paste one into a
commit. Assemble any test look-alike at runtime, or end the line with
`secret-scan: allow`.

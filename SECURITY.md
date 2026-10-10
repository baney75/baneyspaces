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
- **No network.** BaneySpaces has no network code, no analytics and no account. Its settings and
  window positions stay in `~/Library/Application Support/BaneySpaces` and its preferences.
- **Signing.** The installer builds the app on your Mac and signs it with a local certificate
  kept in its own keychain, never the login keychain. It is not trusted for anything else.

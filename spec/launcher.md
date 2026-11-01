# The launcher: what it finds and in what order

Every platform's launcher (macOS today; Linux in #115; Windows later) finds the same things in the same
order and obeys the same privacy rules. A platform that ranks differently, reads more than is listed here, or
leaves out a source its OS can provide fails review. `sites.json` is the one site list.

## Result sources, in the order their rows appear

A query is matched against each source. A row is shown for every source with a match, in this order
(within a source, best match first). Rows from earlier sources never wait for later ones: apps appear on the
keystroke, from memory, in under 16 ms; files and the rest follow as they are found.

| # | Source | Rows | Matching | Notes |
| --- | --- | --- | --- | --- |
| 1 | **Apps** installed on this machine | up to 8 | Name: prefix, then a word's prefix, initials, then letters in order. Recent and running apps rank a little higher | A running app opens per `behavior.launcher.open` (config.md, "Open here") |
| 2 | **Sites** | up to 3 | See "Sites" below | Above everything from the web |
| 3 | **iPhone apps** via iPhone Mirroring (macOS only) | up to 3 apps and one search row | Provider apps by name like apps; the "Search iPhone for “…”" row for every query while iPhone Mirroring is installed | Below sites |
| 4 | **Windows** and terminal/browser tabs, agent windows | up to 8 | Title and app name | |
| 5 | **Agents** the user can start in a terminal | all matches | Command name | |
| 6 | **Workspaces** | all matches | "3", "ws 3", names, or an app on it | |
| 7 | **Commands and menu** (lock, sleep, settings, install, update…) | all matches | Name | |
| 8 | **Files and folders** | top 5 (60 in the Files menu) | Every typed word starts a word of the file name | See "Files" below |
| 9 | **Web search** | up to 3 | Bangs (`!yt cats`) and the chosen engine | |
| 10 | **Ask an agent** | 1 | A leading `?` | |

A bang or a question takes over the list: it is plainly for the web.

### Sites

Three lists, one ranking. The result is at most three rows.

1. **Built-in sites**, `sites.json`: name, address, aliases, optional native apps, optional iPhone app name.
2. **Bookmarks** of the default browser's current profile. Chromium family (Chrome, Helium, Brave, Edge,
   Arc, Vivaldi, Chromium): the profile's `Bookmarks` JSON; the profile is the one `Local State` names as last
   used. Safari: `Bookmarks.plist`, without the Reading List. Read as the file is, read again when its modification
   time changes (checked each time the launcher opens).
3. **Most visited sites**: the 200 sites with the most visits in the default browser's history, summed over every
   page of a site. A site is a host and its origin (scheme, host, port): never a path or a query.

Matching, in score order (highest first):

1. The typed text is exactly an alias or the name (`x`, `yt`, `twitter`): 2000.
2. It is the start of an alias: 1500. The start of the name: 1400. The start of the domain's name
   (`github` of `github.com`): 1300. The start of a word of the name: 1100.
3. One typed letter matches only an exact alias (so `x` is X, not every name with an x). Nothing matches the
   middle of a word.
4. Then: shorter names first (minus the name's length), a bookmark +40, a most visited site up to +60 by
   visits (4 per doubling).
5. A most visited site that the built-in list already names (same host) is not listed again. Two built-in
   sites on one host (Google Docs and Google Sheets) stay two rows; bookmarks are separate by address.

A site row shows the site's icon, its name and its domain, and "Bookmark" or "Visited often" for those
sources. Return opens it in the default browser; open here (config.md) applies to the browser's window.
The icon is the browser's own favicon for the host, read from its local favicon database, else a tile with the
site's first letter. Nothing is fetched.

**Apps beat sites.** If the machine has a native app for a built-in site (`native` in `sites.json`: Spotify,
Slack…), the app's row is the row and offers the site as its second action (⇥, "Open the site on the web");
the site gets no row of its own. **Phone apps** (macOS): if the iPhone app list has an app with the site's
`iphone` name, the site's row offers ⇥, "Open on iPhone", which asks iPhone Mirroring.

### Files

Spotlight or the platform's index, in the home folder and cloud drives, without Library, hidden folders and
build folders. The platform answers the keystroke from a list of files used or changed lately kept in
memory (macOS: used in 90 days or changed in 30, at most 6,000, read in the background), and the full query
follows after a pause of at most 60 ms; a new keystroke stops the old query. Targets: warm answer under 100 ms
(p90), apps under 16 ms.

## iPhone apps via iPhone Mirroring (macOS only)

The row asks iPhone Mirroring's own Spotlight: it comes up on the launcher's workspace, its Spotlight item is
pressed in its menu bar, and the query is typed into it (a field's value if it exposes one, else keys sent to
its own process only). The answer says what was asked, never that an app opened. When its window says it can't
(Unlock Your iPhone, Unable to Connect to iPhone, Mac Locked, Connecting to…), the row says so in
Mirroring's own words and nothing is typed. The list of the phone's apps comes from a provider, read from
iPhone Mirroring's own data after macOS has asked the user; without it, only the search row exists.

## Privacy rules (every platform)

- **Read only.** Nothing is written to a browser's or another app's data. Databases the app holds locked are
  copied to a temporary file, read, and the copy deleted at once.
- **Only what is listed.** Bookmarks (title, address); history: address and visit count from the URL table;
  favicons: the image for a host shown; `Local State`: the last-used profile's name. Never cookies, saved
  logins (`Login Data`), form or payment data (`Web Data`, autofill), search terms, downloads, visit times,
  sessions or extensions' data.
- **Memory only.** Bookmarks, most visited sites and icons live in memory, rebuilt from the files (history and
  icons every 30 minutes). Only the iPhone app list (names, bundle ids, icons) is kept on disk, in the app's own
  folder.
- **No address in a log.** The trace and the system log get counts and outcomes ("sites: bookmarks=312
  frequent=200 icons=140", "open site: newWindow on workspace 3"), never an address, host, title, file name, app
  name or query.
- **Nothing over the network.** No favicon service, no list download, no telemetry. The built-in list ships with
  the app.
- **A refusal is quiet.** If the OS denies a read, that source is empty and the launcher works with the rest.
  Settings says what is missing and why.

## Conformance

A platform's test reads `sites.json` and checks its generated list against it; checks that `x` ranks X first,
`yt` YouTube first, that one letter matches only an exact alias, that a most visited site named in the list is
not repeated, that the 200-site and 6,000-file bounds hold, and that no log line it writes contains an address.

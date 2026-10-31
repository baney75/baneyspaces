import AppKit
import Carbon
import BaneySpacesCore

/// Runs AppleScript in-process. Every script is compiled once and its handlers are called with
/// arguments through an Apple event, so a click never pays for launching `osascript`.
/// All of it runs on one serial queue, off the main thread; every `tell` carries a timeout.
final class OSA {
    static let queue = DispatchQueue(label: "deck.osa", qos: .userInitiated)
    /// `run`'s error when the script didn't compile, so nothing was sent.
    static let didNotCompile = 1
    private var compiled: NSAppleScript?
    private let source: String
    /// The queue every call runs on: `OSA.queue` unless the script has one of its own.
    let queue: DispatchQueue

    init(_ source: String, queue: DispatchQueue = OSA.queue) { self.source = source; self.queue = queue }

    /// Calls `handler` with string arguments. Must run on `queue`. Nil on any error.
    func call(_ handler: String, _ args: [String] = []) -> String? {
        let r = run(handler, args)
        return r.error == 0 ? r.out : nil
    }

    /// `call`, with the AppleScript error number (0 for none) so a caller can tell a script that
    /// never reached the app from one that failed partway.
    func run(_ handler: String, _ args: [String] = []) -> (out: String?, error: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        if compiled == nil {
            let s = NSAppleScript(source: source)
            var err: NSDictionary?
            guard s?.compileAndReturnError(&err) == true else {
                NSLog("BaneySpaces deck: script didn't compile: %@", err ?? [:])
                return (nil, Self.didNotCompile)
            }
            compiled = s
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: .null(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        event.setParam(list, forKeyword: keyDirectObject)
        var err: NSDictionary?
        let result = compiled?.executeAppleEvent(event, error: &err)
        if let err { return (nil, (err[NSAppleScript.errorNumber] as? Int) ?? -1) }
        return (result?.stringValue ?? "", 0)
    }
}

/// Whether BaneySpaces may script an app, checked without prompting. A script sent while macOS
/// is still asking would block the shared script queue until you answer, stalling every other
/// app's rows, so an undecided app is asked once on a queue of its own and read through
/// Accessibility until you allow it.
enum Automation {
    private static let lock = NSLock()
    private static var asked: Set<String> = []
    private static let askQueue = DispatchQueue(label: "baneyspaces.deck.consent")

    /// A yes, remembered for a while: asking costs a round trip to the system on every read.
    private static var yes: [String: Date] = [:]
    static let remember: TimeInterval = 60

    /// The app quit: ask again next time.
    static func forget(_ bundleID: String) { lock.withLock { yes[bundleID] = nil } }

    static func allowed(_ bundleID: String) -> Bool {
        if let at = lock.withLock({ yes[bundleID] }), Date().timeIntervalSince(at) < remember { return true }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:
            lock.withLock { yes[bundleID] = Date() }
            return true
        case OSStatus(errAEEventWouldRequireUserConsent):
            let first = lock.withLock { asked.insert(bundleID).inserted }
            if first { askQueue.async { _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) } }
            return false
        default:
            // Denied in System Settings, or not running: rows come from Accessibility instead.
            lock.withLock { yes[bundleID] = nil }
            return false
        }
    }
}

/// The scripts each adapter needs. Every one checks the app is running first, because `tell
/// application` would launch it.
enum Scripts {
    static let header = """
    property fs : character id 31
    property rs : character id 30
    """

    static func ghostty() -> OSA {
        OSA(header + """

        on snapshot()
        	if not (application id "com.mitchellh.ghostty" is running) then return ""
        	with timeout of 3 seconds
        		tell application id "com.mitchellh.ghostty"
        			set out to ""
        			try
        				set out to id of front window
        			end try
        			repeat with w in windows
        				set wid to id of w
        				set out to out & rs & "W" & fs & wid & fs & (name of w)
        				set sel to id of selected tab of w
        				repeat with t in tabs of w
        					set tid to id of t
        					set foc to id of focused terminal of t
        					set ti to (index of t) as text
        					set ids to id of every terminal of t
        					set names to name of every terminal of t
        					set dirs to working directory of every terminal of t
        					repeat with i from 1 to count of ids
        						set termID to item i of ids
        						set out to out & rs & wid & fs & tid & fs & ti & fs & ((tid is sel) as text) & fs & ((termID is foc) as text) & fs & termID & fs & (item i of names) & fs & (item i of dirs)
        					end repeat
        				end repeat
        			end repeat
        			return out
        		end tell
        	end timeout
        end snapshot

        on findTerm(target)
        	tell application id "com.mitchellh.ghostty"
        		repeat with w in windows
        			repeat with t in tabs of w
        				repeat with term in terminals of t
        					if (id of term) is target then return {w, t, term}
        				end repeat
        			end repeat
        		end repeat
        	end tell
        	return missing value
        end findTerm

        on focusTerm(target)
        	if not (application id "com.mitchellh.ghostty" is running) then return "missing"
        	with timeout of 3 seconds
        		set found to findTerm(target)
        		if found is missing value then return "missing"
        		tell application id "com.mitchellh.ghostty"
        			activate window (item 1 of found)
        			select tab (item 2 of found)
        			focus (item 3 of found)
        			activate
        		end tell
        	end timeout
        	return "ok"
        end focusTerm

        on closeTerm(target, what)
        	if not (application id "com.mitchellh.ghostty" is running) then return "missing"
        	with timeout of 3 seconds
        		set found to findTerm(target)
        		if found is missing value then return "missing"
        		tell application id "com.mitchellh.ghostty"
        			if what is "terminal" then
        				close (item 3 of found)
        			else if what is "tab" then
        				close tab (item 2 of found)
        			else
        				close window (item 1 of found)
        			end if
        		end tell
        	end timeout
        	return "ok"
        end closeTerm

        on sendText(target, txt)
        	if not (application id "com.mitchellh.ghostty" is running) then return "missing"
        	with timeout of 3 seconds
        		set found to findTerm(target)
        		if found is missing value then return "missing"
        		tell application id "com.mitchellh.ghostty" to input text txt to (item 3 of found)
        	end timeout
        	return "ok"
        end sendText

        on newWindow(dir, cmd)
        	tell application id "com.mitchellh.ghostty"
        		set cfg to new surface configuration
        		if dir is not "" then set initial working directory of cfg to dir
        		if cmd is not "" then set initial input of cfg to cmd & return
        		new window with configuration cfg
        		activate
        	end tell
        	return "ok"
        end newWindow

        """)
    }

    /// `claude-desk`'s tiling (~/.local/bin/claude-desk, which points back here), compiled once so
    /// the Deck's New Claude button skips bash, osascript and the compile. A script of its own on a
    /// queue of its own: Ghostty can take seconds to open a window, which mustn't hold up the rows,
    /// and a compile error here costs only the button, which then runs claude-desk.
    static func claudeDesk() -> OSA {
        OSA(header + """

        -- claude-desk's tiling (~/.local/bin/claude-desk), compiled once here so the Deck's button
        -- skips bash, osascript and the compile. `prior` is its state file: the Claude tab's ID,
        -- then the terminals it made there. Returns the new state.
        --   1st  a screen-filling window   2nd  split right   3rd  left pane down
        --   4th  right pane down           5th  a new tab, and the grid starts again
        --
        -- Progress, for the caller after a timeout. A timed-out call stops the script at the Apple event
        -- that timed out; Ghostty still finishes that one event and nothing after it is sent. These
        -- properties live as long as the compiled script, so `tileProgress` tells which event it was:
        -- "creating" is the one that opens the pane (it may still land), anything before it means no pane
        -- will open. `token` is the caller's own for this press.
        property tileToken : ""
        property tileStep : ""

        on tileProgress()
        	return tileToken & linefeed & tileStep
        end tileProgress

        on claudeTile(workDir, paneCmd, prior, token)
        	set my tileToken to token
        	set my tileStep to "started"
        	set AppleScript's text item delimiters to linefeed
        	set rows to text items of prior
        	set AppleScript's text item delimiters to ""
        	set tabID to ""
        	set known to {}
        	repeat with l in rows
        		if (contents of l) is not "" then
        			if tabID is "" then
        				set tabID to contents of l
        			else
        				set end of known to (contents of l)
        			end if
        		end if
        	end repeat
        	-- Ghostty can take a while to open a window. The pane opens either way, so a timeout is
        	-- handled by the caller (`frontTab`), but a long one keeps that rare.
        	with timeout of 30 seconds
        		tell application id "com.mitchellh.ghostty"
        			activate
        			set cfg to new surface configuration
        			set initial working directory of cfg to workDir
        			set command of cfg to paneCmd
        			set targetTab to missing value
        			set targetWindow to missing value
        			if tabID is not "" then
        				repeat with w in windows
        					repeat with t in tabs of w
        						if (id of t) is tabID then
        							set targetTab to contents of t
        							set targetWindow to contents of w
        						end if
        					end repeat
        				end repeat
        			end if
        			if targetTab is missing value then
        				set my tileStep to "creating"
        				set w to new window with configuration cfg
        				set my tileStep to "done"
        				set t to selected tab of w
        				-- Fill the screen so four tiles stay readable. Once the pane exists, a step
        				-- that fails mustn't lose its ID (or start a second session).
        				try
        					perform action "toggle_maximize" on focused terminal of t
        				end try
        				return my joinLines({id of t, id of focused terminal of t})
        			end if
        			set liveIDs to {}
        			set present to id of every terminal of targetTab
        			repeat with k in known
        				if present contains (contents of k) then set end of liveIDs to (contents of k)
        			end repeat
        			set n to count of liveIDs
        			if n is 0 or n ≥ 4 then
        				set my tileStep to "creating"
        				set t to new tab in targetWindow with configuration cfg
        				set my tileStep to "done"
        				return my joinLines({id of t, id of focused terminal of t})
        			end if
        			if n is 1 then
        				set baseID to item 1 of liveIDs
        				set dir to right
        			else if n is 2 then
        				set baseID to item 1 of liveIDs
        				set dir to down
        			else
        				set baseID to item 2 of liveIDs
        				set dir to down
        			end if
        			set base to first terminal of targetTab whose id is baseID
        			set my tileStep to "creating"
        			set newTerm to split base direction dir with configuration cfg
        			set my tileStep to "done"
        			-- Each step on its own: a failed equalize still focuses the new pane.
        			try
        				perform action "equalize_splits" on newTerm
        			end try
        			try
        				focus newTerm
        			end try
        			return my joinLines({tabID} & liveIDs & {id of newTerm})
        		end tell
        	end timeout
        end claudeTile

        -- After a timeout in `claudeTile`: the tab the state should now name and every terminal in it, one
        -- ID per line, so the pane that opened late is still written to the state file. It follows the
        -- branch `claudeTile` took with the same `prior` state: with the state's tab alive and 1 to 3 of its
        -- terminals still there, a split was made in that tab; with none or 4 or more, a new tab was
        -- opened in that tab's window (it is that window's selected tab); with no state, or its tab gone,
        -- a new window was (the front tab). `ClaudeDesk.recovered` checks the answer against the state.
        -- Known limit: it can't tell a pane `claudeTile` made late from one another app made in that tab
        -- during the wait. Apple events are handled in order, so this answers after the late pane exists,
        -- which is why its timeout is as long as the tile's, and why nothing is asked before it: a
        -- shorter probe would queue behind the same slow event and time out when it's needed.
        on frontTab(prior)
        	set AppleScript's text item delimiters to linefeed
        	set rows to text items of prior
        	set AppleScript's text item delimiters to ""
        	set priorTab to ""
        	set known to {}
        	repeat with l in rows
        		if (contents of l) is not "" then
        			if priorTab is "" then
        				set priorTab to contents of l
        			else
        				set end of known to (contents of l)
        			end if
        		end if
        	end repeat
        	with timeout of 30 seconds
        		tell application id "com.mitchellh.ghostty"
        			if (count of windows) is 0 then return ""
        			set t to missing value
        			set priorRef to missing value
        			set priorWin to missing value
        			if priorTab is not "" then
        				repeat with w in windows
        					repeat with x in tabs of w
        						if (id of x) is priorTab then
        							set priorRef to contents of x
        							set priorWin to contents of w
        						end if
        					end repeat
        				end repeat
        			end if
        			if priorRef is not missing value then
        				set liveCount to 0
        				set present to id of every terminal of priorRef
        				repeat with k in known
        					if present contains (contents of k) then set liveCount to liveCount + 1
        				end repeat
        				if liveCount is 0 or liveCount ≥ 4 then
        					set t to selected tab of priorWin
        					-- The new tab never appeared: nothing to adopt, and the state stays.
        					if (id of t) is priorTab then return ""
        				else
        					set t to priorRef
        				end if
        			end if
        			if t is missing value then set t to selected tab of front window
        			set ids to {id of t}
        			repeat with x in (id of every terminal of t)
        				set end of ids to (contents of x)
        			end repeat
        			return my joinLines(ids)
        		end tell
        	end timeout
        end frontTab

        on joinLines(xs)
        	set AppleScript's text item delimiters to linefeed
        	set s to xs as text
        	set AppleScript's text item delimiters to ""
        	return s
        end joinLines
        """, queue: DispatchQueue(label: "deck.osa.claude", qos: .userInitiated))
    }

    static func chromium(_ bundle: String) -> OSA {
        OSA(header + """

        on snapshot()
        	if not (application id "\(bundle)" is running) then return ""
        	with timeout of 3 seconds
        		tell application id "\(bundle)"
        			set out to ""
        			repeat with w in windows
        				set wid to (id of w) as text
        				set m to "normal"
        				try
        					set m to (mode of w) as text
        				end try
        				set out to out & rs & "W" & fs & wid & fs & (name of w) & fs & ((active tab index of w) as text) & fs & m
        				if m is not "incognito" then
        					set ids to id of every tab of w
        					set ts to title of every tab of w
        					set us to URL of every tab of w
        					repeat with i from 1 to count of ids
        						set out to out & rs & "T" & fs & wid & fs & ((item i of ids) as text) & fs & (i as text) & fs & (item i of ts) & fs & (item i of us)
        					end repeat
        				end if
        			end repeat
        			return out
        		end tell
        	end timeout
        end snapshot

        on focusTab(wid, idx)
        	if not (application id "\(bundle)" is running) then return "missing"
        	with timeout of 3 seconds
        		tell application id "\(bundle)"
        			set w to window id (wid as integer)
        			set active tab index of w to (idx as integer)
        			set index of w to 1
        			activate
        		end tell
        	end timeout
        	return "ok"
        end focusTab

        on closeTab(wid, idx)
        	with timeout of 3 seconds
        		tell application id "\(bundle)" to close tab (idx as integer) of window id (wid as integer)
        	end timeout
        	return "ok"
        end closeTab
        """)
    }

    static func terminalApp() -> OSA {
        OSA(header + """

        on snapshot()
        	if not (application id "com.apple.Terminal" is running) then return ""
        	with timeout of 3 seconds
        		tell application id "com.apple.Terminal"
        			set out to ""
        			repeat with w in windows
        				set wid to (id of w) as text
        				set out to out & rs & "W" & fs & wid & fs & (name of w)
        				set i to 0
        				repeat with t in tabs of w
        					set i to i + 1
        					set ti to custom title of t
        					if ti is "" then
        						try
        							set ps to processes of t
        							set ti to item -1 of ps
        						end try
        					end if
        					set out to out & rs & "S" & fs & wid & fs & (tty of t) & fs & (i as text) & fs & ti & fs & (tty of t) & fs & ((selected of t) as text)
        				end repeat
        			end repeat
        			return out
        		end tell
        	end timeout
        end snapshot

        on focusTab(wid, idx)
        	with timeout of 3 seconds
        		tell application id "com.apple.Terminal"
        			set w to window id (wid as integer)
        			set selected of tab (idx as integer) of w to true
        			set index of w to 1
        			activate
        		end tell
        	end timeout
        	return "ok"
        end focusTab
        """)
    }

    static func iterm() -> OSA {
        OSA(header + """

        on snapshot()
        	if not (application id "com.googlecode.iterm2" is running) then return ""
        	with timeout of 3 seconds
        		tell application id "com.googlecode.iterm2"
        			set out to ""
        			repeat with w in windows
        				set wid to (id of w) as text
        				set out to out & rs & "W" & fs & wid & fs & (name of w)
        				set ct to current tab of w
        				set i to 0
        				repeat with t in tabs of w
        					set i to i + 1
        					set cs to current session of t
        					repeat with s in sessions of t
        						set isSel to (t is ct) and ((id of s) is (id of cs))
        						set out to out & rs & "S" & fs & wid & fs & (id of s) & fs & (i as text) & fs & (name of s) & fs & (tty of s) & fs & (isSel as text)
        					end repeat
        				end repeat
        			end repeat
        			return out
        		end tell
        	end timeout
        end snapshot

        on focusTab(wid, idx, sid)
        	with timeout of 3 seconds
        		tell application id "com.googlecode.iterm2"
        			set w to window id (wid as integer)
        			select w
        			tell tab (idx as integer) of w
        				select
        				repeat with s in sessions
        					if (id of s) is sid then select s
        				end repeat
        			end tell
        			activate
        		end tell
        	end timeout
        	return "ok"
        end focusTab
        """)
    }
}

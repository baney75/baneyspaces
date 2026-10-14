import AppKit
import Carbon
import BaneySpacesCore

/// Runs AppleScript in-process. Every script is compiled once and its handlers are called with
/// arguments through an Apple event, so a click never pays for launching `osascript`.
/// All of it runs on one serial queue, off the main thread; every `tell` carries a timeout.
final class OSA {
    static let queue = DispatchQueue(label: "deck.osa", qos: .userInitiated)
    private var compiled: NSAppleScript?
    private let source: String

    init(_ source: String) { self.source = source }

    /// Calls `handler` with string arguments. Must run on `OSA.queue`. Nil on any error.
    func call(_ handler: String, _ args: [String] = []) -> String? {
        dispatchPrecondition(condition: .onQueue(OSA.queue))
        if compiled == nil {
            let s = NSAppleScript(source: source)
            var err: NSDictionary?
            guard s?.compileAndReturnError(&err) == true else { NSLog("BaneySpaces deck: script didn't compile: %@", err ?? [:]); return nil }
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
        if err != nil { return nil }
        return result?.stringValue ?? ""
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

    static func allowed(_ bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return true
        case OSStatus(errAEEventWouldRequireUserConsent):
            let first = lock.withLock { asked.insert(bundleID).inserted }
            if first { askQueue.async { _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) } }
            return false
        default:
            // Denied in System Settings, or not running: rows come from Accessibility instead.
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

        on newBackgroundWindow(dir, cmd)
        	tell application id "com.mitchellh.ghostty"
        		set cfg to new surface configuration
        		if dir is not "" then set initial working directory of cfg to dir
        		if cmd is not "" then set initial input of cfg to cmd & return
        		new window with configuration cfg
        	end tell
        	return "ok"
        end newBackgroundWindow

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

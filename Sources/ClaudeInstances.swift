import AppKit
import Darwin

enum LaunchError: LocalizedError {
    case appNotFound(String)
    case appleEvent(OSStatus)
    case terminalDidNotStart

    var errorDescription: String? {
        switch self {
        case .appNotFound(let p): return "Claude wasn't found at \(p)."
        case .terminalDidNotStart: return "Terminal didn't start the session. Check Terminal for a dialog and try again."
        case .appleEvent(let s):
            if s == -1743 {
                return "macOS blocked Clauncher from sending the folder to Claude. Allow it in System Settings → Privacy & Security → Automation."
            }
            return "Couldn't hand the folder to the running Claude (error \(s))."
        }
    }
}

/// Finds running Claude Desktop instances and launches/targets them per data directory.
enum ClaudeInstances {
    static let bundleID = "com.anthropic.claudefordesktop"

    static var defaultDataDir: String {
        normalise("~/Library/Application Support/Claude")
    }

    static func normalise(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var s = (expanded as NSString).standardizingPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Running Claude main processes keyed by normalised data directory.
    static func running() -> [String: NSRunningApplication] {
        var result: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID && !app.isTerminated {
            guard let args = processArguments(pid: app.processIdentifier) else { continue }
            let dir = userDataDir(in: args).map(normalise) ?? defaultDataDir
            result[dir] = app
        }
        return result
    }

    static func userDataDir(in args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            if a.hasPrefix("--user-data-dir=") { return String(a.dropFirst("--user-data-dir=".count)) }
            if a == "--user-data-dir", i + 1 < args.count { return args[i + 1] }
        }
        return nil
    }

    /// Reads another process's argv via sysctl(KERN_PROCARGS2). Works for processes of the same user.
    static func processArguments(pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: Int(argMax))
        var bufSize = Int(argMax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &bufSize, nil, 0) == 0, bufSize > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<4]) }

        var i = MemoryLayout<Int32>.size
        while i < bufSize && buf[i] != 0 { i += 1 }   // exec path
        while i < bufSize && buf[i] == 0 { i += 1 }   // padding

        var args: [String] = []
        while args.count < Int(argc) && i < bufSize {
            let start = i
            while i < bufSize && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// claude://code/new?folder=… — the same link Claude's own Finder "New Claude Code Session Here" service uses.
    /// Optional `prompt` becomes `q`, which Claude puts in the new session's prompt box.
    static func codeSessionURL(folder: String, prompt: String? = nil) -> URL {
        var url = "claude://code/new?folder=\(encode(folder))"
        if let prompt, !prompt.isEmpty { url += "&q=\(encode(prompt))" }
        return URL(string: url)!
    }

    /// claude://code/continue?session=last, or a specific Desktop session ("local_…").
    static func continueURL(session: String = "last") -> URL {
        URL(string: "claude://code/continue?session=\(encode(session))")!
    }

    /// Desktop's own "Sessions Waiting for You" view.
    static let needsInputURL = URL(string: "claude://code/needs-input")!

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Opens (or focuses) the Claude instance for `account`; if `workspace` is given, starts a Code session there.
    static func launch(_ account: Account, workspace: Workspace?, prompt: String? = nil, claudeAppPath: String,
                       completion: @escaping (Error?) -> Void) {
        open(account, url: workspace.map { codeSessionURL(folder: $0.expandedPath, prompt: prompt) },
             claudeAppPath: claudeAppPath, completion: completion)
    }

    /// Opens (or focuses) the login's Claude and hands it `url`, if any. A running instance gets the URL
    /// directly by process id, so it never lands in another login's window.
    static func open(_ account: Account, url deepLink: URL?, claudeAppPath: String,
                     completion: @escaping (Error?) -> Void) {
        let appURL = URL(fileURLWithPath: (claudeAppPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            completion(LaunchError.appNotFound(appURL.path)); return
        }

        if let app = running()[account.resolvedDataDir] {
            // Already running: send the link to that exact process so it doesn't land in another login.
            if let deepLink {
                let status = sendOpenURL(deepLink, to: app.processIdentifier)
                if status != noErr { completion(LaunchError.appleEvent(status)); return }
            }
            app.unhide()
            app.activate()
            completion(nil)
            return
        }

        if !account.isDefaultProfile {
            try? FileManager.default.createDirectory(atPath: account.resolvedDataDir,
                                                     withIntermediateDirectories: true)
        }

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true   // same as `open -n`
        cfg.activates = true
        cfg.arguments = account.isDefaultProfile ? [] : ["--user-data-dir=\(account.resolvedDataDir)"]

        let done: (NSRunningApplication?, Error?) -> Void = { _, err in
            DispatchQueue.main.async { completion(err) }
        }
        if let deepLink {
            NSWorkspace.shared.open([deepLink], withApplicationAt: appURL, configuration: cfg, completionHandler: done)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: done)
        }
    }

    static func quit(_ account: Account) {
        running()[account.resolvedDataDir]?.terminate()
    }

    /// Sends a kAEGetURL ("GURL") Apple Event to one specific process.
    private static func sendOpenURL(_ url: URL, to pid: pid_t) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                           eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: keyDirectObject)
        guard let aeDesc = event.aeDesc else { return OSStatus(paramErr) }
        return AESendMessage(aeDesc, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
    }
}

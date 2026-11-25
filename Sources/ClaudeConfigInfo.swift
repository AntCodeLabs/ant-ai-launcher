import Foundation

/// Read-only facts about a login gathered from Claude's own files. Never reads tokens or chat content.
enum ClaudeConfigInfo {

    // MARK: Sign-in

    struct CLIIdentity: Equatable {
        let email: String?
        let organization: String?
        let plan: String?
    }

    enum DesktopState: Equatable { case missing, signedOut, signedIn }

    /// Claude Code's global config (`.claude.json`): inside CLAUDE_CONFIG_DIR, or ~/.claude.json by default.
    static func globalConfigURL(_ account: Account) -> URL {
        if let dir = account.resolvedCLIConfigDir {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// The account Claude Code is signed in to for this login (from `oauthAccount` in .claude.json).
    static func cliIdentity(_ account: Account) -> CLIIdentity? {
        guard let j = cachedJSON(globalConfigURL(account)),
              let o = j["oauthAccount"] as? [String: Any] else { return nil }
        return CLIIdentity(email: o["emailAddress"] as? String,
                           organization: o["organizationName"] as? String,
                           plan: (o["planDisplayName"] as? String) ?? (o["seatTier"] as? String))
    }

    /// Whether the Desktop profile exists and holds a sign-in (checks only that the token key is present).
    static func desktopState(_ account: Account) -> DesktopState {
        let cfg = URL(fileURLWithPath: account.resolvedDataDir).appendingPathComponent("config.json")
        guard let j = cachedJSON(cfg) else { return .missing }
        return (j["oauth:tokenCacheV2"] != nil || j["oauth:tokenCache"] != nil) ? .signedIn : .signedOut
    }

    // MARK: Desktop session index

    struct DesktopSession {
        let cliSessionId: String
        let cwd: String
        let title: String?
        let lastActivity: Date?
    }

    /// Code sessions this Desktop login knows about (`<data dir>/claude-code-sessions/**/local_*.json`),
    /// limited to ones touched in the last `days` days.
    static func desktopSessions(_ account: Account, days: Int = 30) -> [DesktopSession] {
        let root = URL(fileURLWithPath: account.resolvedDataDir).appendingPathComponent("claude-code-sessions")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [DesktopSession] = []
        for case let url as URL in en where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard mtime >= cutoff else { continue }
            lock.lock()
            let hit = sessionCache[url.path]
            lock.unlock()
            if let hit, hit.0 == mtime { if let s = hit.1 { out.append(s) }; continue }
            var parsed: DesktopSession?
            if let data = try? Data(contentsOf: url),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = j["cliSessionId"] as? String {
                let cwd = (j["originCwd"] as? String) ?? (j["cwd"] as? String) ?? ""
                let last = (j["lastActivityAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? mtime
                parsed = DesktopSession(cliSessionId: id, cwd: cwd, title: j["title"] as? String, lastActivity: last)
            }
            lock.lock(); sessionCache[url.path] = (mtime, parsed); lock.unlock()
            if let parsed { out.append(parsed) }
        }
        return out
    }

    /// Only the few fields we need, so large session files aren't kept in memory.
    private static var sessionCache: [String: (Date, DesktopSession?)] = [:]

    // MARK: Recent folders

    struct RecentFolder: Hashable {
        let path: String
        let lastUsed: Date
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    /// Folders this login used recently in Claude Code (terminal) or Claude Desktop, newest first.
    /// Skips worktrees, missing folders and folders already saved.
    static func recentFolders(_ account: Account, limit: Int = 10) -> [RecentFolder] {
        let fm = FileManager.default
        var best: [String: Date] = [:]
        func note(_ path: String, _ date: Date) {
            guard !path.isEmpty else { return }
            if let d = best[path], d >= date { return }
            best[path] = date
        }

        // Terminal: projects listed in .claude.json, dated by their transcript folder.
        let projectsDir = URL(fileURLWithPath: account.effectiveCLIConfigDir).appendingPathComponent("projects")
        if let j = cachedJSON(globalConfigURL(account)), let projects = j["projects"] as? [String: Any] {
            for path in projects.keys {
                let enc = path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
                let dir = projectsDir.appendingPathComponent(enc)
                if let d = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date { note(path, d) }
            }
        }
        // Desktop: the sessions this login's Claude Desktop ran.
        for s in desktopSessions(account) { note(s.cwd, s.lastActivity ?? .distantPast) }

        let saved = Set(account.workspaces.map { ClaudeInstances.normalise($0.expandedPath) })
        let home = fm.homeDirectoryForCurrentUser.path
        return best
            .filter { path, _ in
                !path.contains("/.claude/worktrees/") && !path.contains("/.claude-worktrees/")
                    && path != home && !saved.contains(ClaudeInstances.normalise(path))
                    && fm.fileExists(atPath: path)
            }
            .map { RecentFolder(path: $0.key, lastUsed: $0.value) }
            .sorted { $0.lastUsed > $1.lastUsed }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Config files

    struct ConfigFile { let title: String; let url: URL; let exists: Bool }

    static func configFiles(_ account: Account) -> [ConfigFile] {
        let cli = URL(fileURLWithPath: account.effectiveCLIConfigDir)
        let data = URL(fileURLWithPath: account.resolvedDataDir)
        let items: [(String, URL)] = [
            ("Claude Code settings.json", cli.appendingPathComponent("settings.json")),
            ("Claude Code CLAUDE.md (memory)", cli.appendingPathComponent("CLAUDE.md")),
            ("Claude Code .claude.json (MCP servers, projects)", globalConfigURL(account)),
            ("Claude Desktop MCP config", data.appendingPathComponent("claude_desktop_config.json")),
        ]
        return items.map { ConfigFile(title: $0.0, url: $0.1, exists: FileManager.default.fileExists(atPath: $0.1.path)) }
    }

    // MARK: Cache

    private static var cache: [String: (Date, [String: Any])] = [:]
    private static let lock = NSLock()

    /// Parses a JSON file, reusing the last parse while its modification date is unchanged.
    static func cachedJSON(_ url: URL) -> [String: Any]? {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let (d, j) = cache[url.path], d == mtime { return j }
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        cache[url.path] = (mtime, j)
        return j
    }
}

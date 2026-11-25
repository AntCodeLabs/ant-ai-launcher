import Foundation
import Combine

struct DayTotals: Codable, Equatable {
    var input = 0          // uncached input tokens
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0
    var messages = 0

    var allInput: Int { input + cacheWrite + cacheRead }
    var total: Int { allInput + output }

    mutating func add(_ o: DayTotals) {
        input += o.input; cacheWrite += o.cacheWrite; cacheRead += o.cacheRead
        output += o.output; messages += o.messages
    }
}

struct UsageSummary: Equatable {
    var today = DayTotals()
    var sessionsToday = 0
    /// Last 7 days, oldest first ("yyyy-MM-dd", totals).
    var days: [(String, DayTotals)] = []

    static func == (a: Self, b: Self) -> Bool {
        a.today == b.today && a.sessionsToday == b.sessionsToday
            && a.days.map(\.0) == b.days.map(\.0) && a.days.map(\.1) == b.days.map(\.1)
    }
}

/// Token usage per login, read from Claude Code's session logs (`<config dir>/projects/**.jsonl`).
/// Only the `usage` numbers of assistant messages are read; each file is parsed incrementally and
/// the per-day totals are cached on disk, so refreshes after the first are quick.
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var summaries: [UUID: UsageSummary] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    private struct FileEntry: Codable {
        var size: UInt64
        var mtime: Double
        var offset: UInt64
        var lastMessageID: String?
        var sessionID: String
        var entrypoint: String?
        var configDir: String
        var days: [String: DayTotals]
    }

    private var files: [String: FileEntry] = [:]
    private let queue = DispatchQueue(label: "ai.antcodelabs.usage", qos: .utility)
    private var timer: Timer?
    private let lookbackDays = 8

    private var cacheURL: URL {
        ConfigStore.shared.fileURL.deletingLastPathComponent().appendingPathComponent("usage-cache.json")
    }

    func start() {
        queue.async { [weak self] in self?.loadCache() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Refreshes unless the last refresh was under `maxAge` seconds ago.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        if let last = lastUpdated, Date().timeIntervalSince(last) < maxAge { return }
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let accounts = ConfigStore.shared.config.accounts
        queue.async { [weak self] in
            guard let self else { return }
            self.scan(accounts: accounts)
            let result = self.summarise(accounts: accounts)
            self.saveCache()
            DispatchQueue.main.async {
                self.summaries = result
                self.lastUpdated = Date()
                self.isRefreshing = false
            }
        }
    }

    // MARK: Scanning

    private func scan(accounts: [Account]) {
        let fm = FileManager.default
        var dirs = Set(accounts.map(\.effectiveCLIConfigDir))
        dirs.insert(ClaudeInstances.normalise("~/.claude"))   // Desktop sessions log here
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        var seen = Set<String>()

        for dir in dirs {
            let root = URL(fileURLWithPath: dir).appendingPathComponent("projects")
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = rv.contentModificationDate, mtime >= cutoff,
                      let size = rv.fileSize.map(UInt64.init) else { continue }
                seen.insert(url.path)
                var entry = files[url.path] ?? FileEntry(
                    size: 0, mtime: 0, offset: 0, lastMessageID: nil,
                    sessionID: url.deletingPathExtension().lastPathComponent,
                    entrypoint: nil, configDir: dir, days: [:])
                if entry.size == size && entry.mtime == mtime.timeIntervalSince1970 { continue }
                if size < entry.offset {   // rewritten: start over
                    entry.offset = 0; entry.days = [:]; entry.lastMessageID = nil
                }
                parse(url: url, into: &entry)
                entry.size = size
                entry.mtime = mtime.timeIntervalSince1970
                files[url.path] = entry
            }
        }
        // Forget files that are gone or older than the window.
        files = files.filter { seen.contains($0.key) }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private func parse(url: URL, into entry: inout FileEntry) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: entry.offset)

        let assistantTag = Data("\"type\":\"assistant\"".utf8)
        let usageTag = Data("\"usage\"".utf8)
        var pending = Data()
        var consumed = entry.offset

        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let nl = pending[lineStart...].firstIndex(of: 0x0A) {
                let line = pending[lineStart..<nl]
                consumed += UInt64(nl - lineStart + 1)
                lineStart = pending.index(after: nl)
                guard line.range(of: assistantTag) != nil, line.range(of: usageTag) != nil,
                      let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let msg = j["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }

                if entry.entrypoint == nil { entry.entrypoint = j["entrypoint"] as? String }
                if let sid = j["sessionId"] as? String, url.path.contains("/subagents/") { entry.sessionID = sid }

                // A response split over several lines repeats the same message id and usage: count once.
                let mid = msg["id"] as? String
                if let mid, mid == entry.lastMessageID { continue }
                entry.lastMessageID = mid

                guard let ts = j["timestamp"] as? String,
                      let date = Self.isoFrac.date(from: ts) ?? Self.iso.date(from: ts) else { continue }
                let day = Self.dayFormatter.string(from: date)
                var t = entry.days[day] ?? DayTotals()
                t.input += usage["input_tokens"] as? Int ?? 0
                t.cacheWrite += usage["cache_creation_input_tokens"] as? Int ?? 0
                t.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
                t.output += usage["output_tokens"] as? Int ?? 0
                t.messages += 1
                entry.days[day] = t
            }
            pending = Data(pending[lineStart...])   // keep the unfinished last line for the next chunk
        }
        entry.offset = consumed
    }

    // MARK: Attribution

    private func summarise(accounts: [Account]) -> [UUID: UsageSummary] {
        // Desktop sessions all log under ~/.claude; each Desktop login's own session list says which are its.
        var desktopOwner: [String: UUID] = [:]
        for a in accounts {
            for s in ClaudeConfigInfo.desktopSessions(a, days: lookbackDays + 1) { desktopOwner[s.cliSessionId] = a.id }
        }

        let today = Self.dayFormatter.string(from: Date())
        let last7 = (0..<7).reversed().map {
            Self.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: -$0, to: Date())!)
        }
        var result: [UUID: UsageSummary] = [:]
        var sessionsToday: [UUID: Set<String>] = [:]
        var perDay: [UUID: [String: DayTotals]] = [:]

        for entry in files.values {
            let owner: UUID?
            if let o = desktopOwner[entry.sessionID] {
                owner = o
            } else if entry.entrypoint == "claude-desktop" {
                owner = nil    // a Desktop session we can't place (e.g. archived long ago)
            } else {
                owner = accounts.first { $0.effectiveCLIConfigDir == entry.configDir }?.id
            }
            guard let owner else { continue }
            for (day, t) in entry.days where last7.contains(day) {
                perDay[owner, default: [:]][day, default: DayTotals()].add(t)
                if day == today && t.messages > 0 { sessionsToday[owner, default: []].insert(entry.sessionID) }
            }
        }
        for a in accounts {
            let d = perDay[a.id] ?? [:]
            result[a.id] = UsageSummary(today: d[today] ?? DayTotals(),
                                        sessionsToday: sessionsToday[a.id]?.count ?? 0,
                                        days: last7.map { ($0, d[$0] ?? DayTotals()) })
        }
        return result
    }

    // MARK: Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: FileEntry].self, from: data) else { return }
        files = decoded
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: Formatting

    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }
}

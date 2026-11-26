import Foundation
import Combine

/// Where a folder opens by default (its hotkey and "Start My Day" use this).
enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    case desktop, terminal
    var id: String { rawValue }
    var label: String { self == .desktop ? "Claude Desktop" : "Terminal" }
}

/// A prompt saved against a folder, started as a new session with one click.
struct SavedPrompt: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var text: String

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id; self.name = name; self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? String(text.prefix(30))
    }
}

/// A working folder that a Claude Code session should open in.
struct Workspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var mode: LaunchMode = .desktop
    /// 1–9 → ⌃⌥⌘<digit> opens this folder from anywhere.
    var hotkey: Int?
    /// Opened by the login's "Start My Day".
    var startOfDay: Bool = false
    var prompts: [SavedPrompt] = []

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id; self.name = name; self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent
        mode = try c.decodeIfPresent(LaunchMode.self, forKey: .mode) ?? .desktop
        hotkey = try c.decodeIfPresent(Int.self, forKey: .hotkey)
        startOfDay = try c.decodeIfPresent(Bool.self, forKey: .startOfDay) ?? false
        prompts = try c.decodeIfPresent([SavedPrompt].self, forKey: .prompts) ?? []
    }

    var expandedPath: String { (path as NSString).expandingTildeInPath }
}

/// One Claude Desktop login, kept apart from the others by its own --user-data-dir.
struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Empty means Claude's normal profile (~/Library/Application Support/Claude).
    var dataDir: String
    /// CLAUDE_CONFIG_DIR for terminal sessions. Empty means Claude Code's default (~/.claude).
    var cliConfigDir: String
    var workspaces: [Workspace]

    init(id: UUID = UUID(), name: String, dataDir: String, cliConfigDir: String = "", workspaces: [Workspace] = []) {
        self.id = id; self.name = name; self.dataDir = dataDir; self.cliConfigDir = cliConfigDir; self.workspaces = workspaces
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        dataDir = try c.decodeIfPresent(String.self, forKey: .dataDir) ?? ""
        cliConfigDir = try c.decodeIfPresent(String.self, forKey: .cliConfigDir) ?? ""
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
    }

    var isDefaultProfile: Bool { dataDir.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Absolute, normalised data directory used to match running instances.
    var resolvedDataDir: String {
        isDefaultProfile ? ClaudeInstances.defaultDataDir : ClaudeInstances.normalise(dataDir)
    }

    var resolvedCLIConfigDir: String? {
        let t = cliConfigDir.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : ClaudeInstances.normalise(t)
    }

    /// Folder-name part derived from a login name: "Client Work" → "Client-Work".
    static func folderStem(_ name: String) -> String {
        let plain = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX"))
        let parts = plain.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        return parts.isEmpty ? "Login" : parts.joined(separator: "-")
    }
    /// Default folders for a login called `name`: its own Claude Desktop profile and Claude Code config.
    static func defaultDataDir(for name: String) -> String { "~/Library/Application Support/Claude-\(folderStem(name))" }
    static func defaultCLIConfigDir(for name: String) -> String { "~/.claude-\(folderStem(name).lowercased())" }

    /// The Claude Code config folder this login's terminal sessions actually use (~/.claude when unset).
    var effectiveCLIConfigDir: String {
        resolvedCLIConfigDir ?? ClaudeInstances.normalise("~/.claude")
    }
}

struct LauncherConfig: Codable, Equatable {
    static let defaultTerminal = "/System/Applications/Utilities/Terminal.app"

    var claudeAppPath: String = "/Applications/Claude.app"
    /// App that opens the generated .command file (Terminal or iTerm).
    var terminalAppPath: String = LauncherConfig.defaultTerminal
    /// What to run in the terminal; `command` is prefixed so shell aliases can't override CLAUDE_CONFIG_DIR.
    var claudeCommand: String = "claude"
    var accounts: [Account]

    init(accounts: [Account]) { self.accounts = accounts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeAppPath = try c.decodeIfPresent(String.self, forKey: .claudeAppPath) ?? "/Applications/Claude.app"
        terminalAppPath = try c.decodeIfPresent(String.self, forKey: .terminalAppPath) ?? LauncherConfig.defaultTerminal
        claudeCommand = try c.decodeIfPresent(String.self, forKey: .claudeCommand) ?? "claude"
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
    }

    /// First run: Claude's normal profile, plus any other Claude Desktop profiles (`Claude-<name>` folders
    /// in Application Support) and Claude Code config folders (`~/.claude-<name>`) already on this Mac.
    static var seed: LauncherConfig {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        var accounts = [Account(name: "Personal", dataDir: "", cliConfigDir: "")]

        let desktop = ((try? fm.contentsOfDirectory(atPath: support.path)) ?? [])
            .filter { $0.hasPrefix("Claude-") && fm.fileExists(atPath: support.appendingPathComponent($0).appendingPathComponent("config.json").path) }
            .sorted()
        var cli = Set(((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".claude-") && $0 != ".claude-worktrees" })

        for folder in desktop {
            let suffix = String(folder.dropFirst("Claude-".count))
            let match = cli.first { $0.dropFirst(".claude-".count).lowercased() == suffix.lowercased() }
            if let match { cli.remove(match) }
            accounts.append(Account(name: suffix, dataDir: "~/Library/Application Support/\(folder)",
                                    cliConfigDir: match.map { "~/\($0)" } ?? ""))
        }
        // Claude Code-only logins get their own entry, with a Desktop profile name ready for when it's opened.
        for folder in cli.sorted() {
            let suffix = String(folder.dropFirst(".claude-".count))
            let name = suffix.prefix(1).uppercased() + suffix.dropFirst()
            accounts.append(Account(name: name, dataDir: "~/Library/Application Support/Claude-\(name)",
                                    cliConfigDir: "~/\(folder)"))
        }
        return LauncherConfig(accounts: accounts)
    }
}

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    let fileURL: URL = {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = support.appendingPathComponent("Clauncher", isDirectory: true)
        // Carry settings over from the app's earlier names, once.
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            for legacy in ["Ant AI Launcher", "Ant Claude Launcher", "Claude Launcher"] {
                let old = support.appendingPathComponent(legacy, isDirectory: true)
                if fm.fileExists(atPath: old.appendingPathComponent("config.json").path) {
                    try? fm.moveItem(at: old, to: dir)
                    break
                }
            }
        }
        return dir.appendingPathComponent("config.json")
    }()

    @Published var config: LauncherConfig {
        didSet { save() }
    }
    @Published private(set) var loadError: String?

    private init() {
        config = LauncherConfig.seed
        reload()
    }

    func reload() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            save()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(LauncherConfig.self, from: data)
            loadError = nil
            // Assign without echoing a save of identical content.
            if decoded != config {
                config = decoded
            }
        } catch {
            loadError = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Clauncher: failed to save config: \(error)")
        }
    }
}

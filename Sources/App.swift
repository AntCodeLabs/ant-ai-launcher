import AppKit
import SwiftUI
import ServiceManagement
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let store = ConfigStore.shared
    private let monitor = SessionMonitor.shared
    private let usage = UsageStore.shared
    private var subscriptions = Set<AnyCancellable>()
    private var folderHotKeyIDs: [UInt32] = []
    static let autosaveName = "ClaudeLauncher"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // New icons appear at the far left of the status area, which on a full menu bar is behind the notch.
        // Ask for a slot near the right edge (just left of Sound/Wi-Fi) unless the user has ⌘-dragged it elsewhere.
        let posKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: posKey) == nil {
            UserDefaults.standard.set(340.0, forKey: posKey)
        }
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(Self.autosaveName)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = []
        if let button = statusItem.button {
            button.image = Brand.menuBarIcon
            button.imagePosition = .imageLeft
            button.toolTip = "Ant AI Launcher · \(Brand.company)"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        // ⌃⌥⌘C pops the same menu up at the mouse pointer, so it's usable even if the icon is hidden.
        HotKeyCenter.shared.register(keyCode: HotKeyCenter.keyC, modifiers: HotKeyCenter.controlOptionCommand) { [weak self] in
            self?.popUpMenuAtPointer()
        }
        store.$config
            .map { $0.accounts.flatMap { a in a.workspaces.map { "\(a.id)\($0.id)\($0.hotkey ?? 0)\($0.mode)" } } }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerFolderHotKeys() } }
            .store(in: &subscriptions)

        monitor.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &subscriptions)
        monitor.start()
        usage.start()
        UpdateChecker.shared.checkIfDue()

        if CommandLine.arguments.contains("--settings") || store.config.accounts.allSatisfy({ $0.workspaces.isEmpty }) {
            openSettings()   // first run: nothing to launch yet, so show where to add folders
        }
    }

    /// Launching the app again (Spotlight, Finder, Launchpad) while it's running opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func popUpMenuAtPointer() {
        guard let menu = statusItem.menu else { return }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The ant gets a count when sessions need you or have finished since you last looked.
    private func updateBadge() {
        guard let button = statusItem.button else { return }
        let n = monitor.attentionCount
        let needsYou = monitor.sessions.contains { $0.status == .needsYou }
        if n == 0 {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.attributedTitle = NSAttributedString(string: " \(n)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: needsYou ? NSColor.systemOrange : NSColor.labelColor,
            ])
        }
        let working = monitor.sessions.filter { $0.status == .working }.count
        button.toolTip = "Ant AI Launcher · \(monitor.sessions.count) sessions, \(working) working, \(n) need a look"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.reload()   // pick up hand edits to config.json
        menu.removeAllItems()
        let config = store.config
        let running = ClaudeInstances.running()

        if let err = store.loadError {
            menu.addItem(info("⚠︎ \(err)"))
            menu.addItem(.separator())
        }

        addSessionsSection(to: menu, config: config)

        for account in config.accounts {
            menu.addItem(.separator())
            addAccountSection(account, to: menu, isRunning: running[account.resolvedDataDir] != nil, config: config)
        }
        if config.accounts.isEmpty { menu.addItem(info("No logins configured")) }

        menu.addItem(.separator())
        menu.addItem(info("⌥ Terminal · ⇧ continue · ⌃ quit or stop"))
        menu.addItem(info("Open this menu anywhere: ⌃⌥⌘C"))
        let updates = UpdateChecker.shared
        if updates.updateAvailable, let v = updates.latestVersion {
            menu.addItem(action("Update Available: v\(v) — Download…", symbol: "arrow.down.circle") {
                NSWorkspace.shared.open(updates.latestURL ?? UpdateChecker.releasesPage)
            })
        } else {
            menu.addItem(action("Check for Updates…") { [weak self] in self?.checkForUpdates() })
        }
        menu.addItem(action("About Ant AI Launcher") { [weak self] in self?.showAbout() })
        menu.addItem(action("\(Brand.company) · \(Brand.websiteLabel)", symbol: "arrow.up.right.square") {
            NSWorkspace.shared.open(Brand.website)
        })
        let settings = action("Settings…") { [weak self] in self?.openSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let login = action("Open at Login") { [weak self] in self?.toggleLoginItem() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Ant AI Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ menu: NSMenu) {
        UpdateChecker.shared.checkIfDue()
        monitor.refresh()
        usage.refreshIfStale()
        // You've now seen the "done" sessions; clear them from the badge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.monitor.markFinishedSeen() }
    }

    // MARK: Sessions section

    private func addSessionsSection(to menu: NSMenu, config: LauncherConfig) {
        let sessions = monitor.sessions
        let needs = sessions.filter { $0.status == .needsYou }.count
        let working = sessions.filter { $0.status == .working }.count
        var header = "Sessions"
        if sessions.isEmpty { header += " — none running" }
        else {
            var bits: [String] = []
            if needs > 0 { bits.append("\(needs) need you") }
            if working > 0 { bits.append("\(working) working") }
            bits.append("\(sessions.count) open")
            header += " — " + bits.joined(separator: " · ")
        }
        menu.addItem(NSMenuItem.sectionHeader(title: header))

        let shown = 10
        for s in sessions.prefix(shown) { addSession(s, to: menu, config: config) }
        if sessions.count > shown {
            let more = NSMenuItem(title: "\(sessions.count - shown) More…", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in sessions.dropFirst(shown) { addSession(s, to: sub, config: config) }
            more.submenu = sub
            menu.addItem(more)
        }
    }

    private func addSession(_ s: LiveSession, to menu: NSMenu, config: LauncherConfig) {
        let login = config.accounts.first { $0.id == s.accountID }?.name ?? "Unknown login"
        let since = s.statusSince.map { Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? ""
        let status = s.status == .needsYou ? (s.waitingFor.map { "needs you: \($0)" } ?? "needs you") : s.status.label
        let detail = "\(s.folderName) · \(login) · \(s.isDesktop ? "Desktop" : "Terminal") · \(status)\(since.isEmpty ? "" : " \(since)")"

        let item = action(s.name) { [weak self] in self?.monitor.focus(s) }
        item.image = statusSymbol(s.status)
        if #available(macOS 14.4, *) { item.subtitle = detail } else { item.title = "\(s.name) — \(detail)" }
        item.toolTip = "\(s.cwd)\nClick to bring it to the front"
        menu.addItem(item)

        if !s.isDesktop {
            let stop = action("Stop “\(s.name)”", symbol: "stop.circle", alternate: .control) { [weak self] in
                self?.confirmStop(s)
            }
            menu.addItem(stop)
        }
    }

    private func confirmStop(_ s: LiveSession) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Stop “\(s.name)”?"
        alert.informativeText = "This ends the Claude Code process in \(s.cwd). Anything it was doing is interrupted."
        alert.addButton(withTitle: "Stop Session")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { monitor.stop(s) }
    }

    // MARK: Login section

    private func addAccountSection(_ account: Account, to menu: NSMenu, isRunning: Bool, config: LauncherConfig) {
        menu.addItem(NSMenuItem.sectionHeader(title: account.name))
        let cliNote = " · CLAUDE_CONFIG_DIR=\(abbreviate(account.effectiveCLIConfigDir))"

        // Open / Show Claude  (⌥ Terminal, ⌃ Quit)
        let open = action(isRunning ? "Show Claude" : "Open Claude") { [weak self] in
            self?.launch(account, nil, terminal: false)
        }
        open.image = statusDot(running: isRunning)
        if isRunning, let st = monitor.stats[account.id] { open.badge = NSMenuItemBadge(string: st.summary) }
        open.toolTip = isRunning ? "Running · \(account.resolvedDataDir)" : account.resolvedDataDir
        menu.addItem(open)
        let openTerm = action("Claude Code in Terminal", symbol: "terminal", alternate: .option) { [weak self] in
            self?.launch(account, nil, terminal: true)
        }
        openTerm.toolTip = "claude in your home folder\(cliNote)"
        menu.addItem(openTerm)
        if isRunning {
            menu.addItem(action("Quit Claude (\(account.name))", symbol: "xmark.circle", alternate: .control) {
                ClaudeInstances.quit(account)
            })
        }

        // Who's signed in + today's usage, and a warning if a sign-in is missing.
        for line in statusLines(account, isRunning: isRunning) { menu.addItem(info(line)) }

        // Saved folders  (⌥ Terminal, ⇧ continue in Terminal)
        for ws in account.workspaces {
            let exists = FileManager.default.fileExists(atPath: ws.expandedPath)
            let primary = action(ws.name, symbol: ws.mode == .terminal ? "terminal" : "folder") { [weak self] in
                self?.launch(account, ws, terminal: ws.mode == .terminal)
            }
            if ws.mode == .terminal { primary.title = "\(ws.name) — Terminal" }
            primary.toolTip = exists ? ws.expandedPath : "Folder not found: \(ws.expandedPath)"
            if let hk = ws.hotkey { primary.badge = NSMenuItemBadge(string: "⌃⌥⌘\(hk)") }
            let live = monitor.sessions.filter { $0.accountID == account.id && $0.cwd == ws.expandedPath }.count
            if live > 0 { primary.toolTip! += "\n\(live) session\(live == 1 ? "" : "s") open here" }
            primary.isEnabled = exists
            menu.addItem(primary)

            let other = ws.mode == .terminal
                ? action("\(ws.name) — Claude Desktop", symbol: "folder", alternate: .option) { [weak self] in
                    self?.launch(account, ws, terminal: false) }
                : action("\(ws.name) — Terminal", symbol: "terminal", alternate: .option) { [weak self] in
                    self?.launch(account, ws, terminal: true) }
            other.toolTip = "claude in \(ws.expandedPath)\(cliNote)"
            other.isEnabled = exists
            menu.addItem(other)

            let cont = action("\(ws.name) — Continue Last (Terminal)", symbol: "arrow.uturn.forward", alternate: .shift) { [weak self] in
                self?.launch(account, ws, terminal: true, extraArgs: ["--continue"])
            }
            cont.toolTip = "claude --continue in \(ws.expandedPath)"
            cont.isEnabled = exists
            menu.addItem(cont)
        }

        menu.addItem(action("Open Folder…", symbol: "folder.badge.plus") { [weak self] in
            self?.chooseFolderAndLaunch(account, terminal: false)
        })
        menu.addItem(action("Open Folder in Terminal…", symbol: "terminal", alternate: .option) { [weak self] in
            self?.chooseFolderAndLaunch(account, terminal: true)
        })

        // Recent ▸
        let recent = ClaudeConfigInfo.recentFolders(account, limit: 10)
        if !recent.isEmpty {
            let item = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            let sub = NSMenu(); sub.autoenablesItems = false
            for r in recent {
                let ws = Workspace(name: r.name, path: r.path)
                let row = action(r.name, symbol: "folder") { [weak self] in self?.launch(account, ws, terminal: false) }
                row.toolTip = "\(abbreviate(r.path)) · last used \(Self.relative.localizedString(for: r.lastUsed, relativeTo: Date()))"
                sub.addItem(row)
                sub.addItem(action("\(r.name) — Terminal", symbol: "terminal", alternate: .option) { [weak self] in
                    self?.launch(account, ws, terminal: true) })
                sub.addItem(action("Save “\(r.name)” to \(account.name)", symbol: "plus.circle", alternate: .shift) { [weak self] in
                    self?.saveFolder(r.path, to: account.id) })
            }
            sub.addItem(.separator())
            sub.addItem(info("⌥ Terminal · ⇧ save to folders"))
            item.submenu = sub
            menu.addItem(item)
        }

        // Prompts
        menu.addItem(action("New Session with Prompt…", symbol: "text.bubble") { [weak self] in
            self?.promptAndLaunch(account, terminal: false)
        })
        menu.addItem(action("New Terminal Session with Prompt…", symbol: "terminal", alternate: .option) { [weak self] in
            self?.promptAndLaunch(account, terminal: true)
        })
        let saved = account.workspaces.flatMap { ws in ws.prompts.map { (ws, $0) } }
        if !saved.isEmpty {
            let item = NSMenuItem(title: "Saved Prompts", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
            let sub = NSMenu(); sub.autoenablesItems = false
            for (ws, p) in saved {
                let row = action("\(ws.name): \(p.name)", symbol: "text.bubble") { [weak self] in
                    self?.launch(account, ws, terminal: ws.mode == .terminal, prompt: p.text) }
                row.toolTip = p.text
                sub.addItem(row)
                sub.addItem(action("\(ws.name): \(p.name) — \(ws.mode == .terminal ? "Claude Desktop" : "Terminal")",
                                   symbol: ws.mode == .terminal ? "folder" : "terminal", alternate: .option) { [weak self] in
                    self?.launch(account, ws, terminal: ws.mode != .terminal, prompt: p.text) })
            }
            item.submenu = sub
            menu.addItem(item)
        }

        // Start My Day
        let day = account.workspaces.filter(\.startOfDay)
        if !day.isEmpty {
            let item = action("Start My Day (\(day.count) folder\(day.count == 1 ? "" : "s"))", symbol: "sunrise") { [weak self] in
                self?.startMyDay(account)
            }
            item.toolTip = day.map { "\($0.name) — \($0.mode.label)" }.joined(separator: "\n")
            menu.addItem(item)
        }

        // More ▸ (Desktop shortcuts, usage, config files)
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        more.submenu = moreMenu(account, config: config)
        menu.addItem(more)
    }

    private func statusLines(_ account: Account, isRunning: Bool) -> [String] {
        var lines: [String] = []
        var first: [String] = []
        if let id = ClaudeConfigInfo.cliIdentity(account), let email = id.email { first.append(email) }
        if let u = usage.summaries[account.id], u.today.messages > 0 {
            first.append("today \(UsageStore.tokens(u.today.total)) tokens ≈ \(Pricing.usd(u.today.cost)) at API prices · \(u.sessionsToday) session\(u.sessionsToday == 1 ? "" : "s")")
        }
        if !first.isEmpty { lines.append(first.joined(separator: " · ")) }
        if ClaudeConfigInfo.cliIdentity(account) == nil { lines.append("⚠︎ Claude Code (Terminal) isn't signed in") }
        switch ClaudeConfigInfo.desktopState(account) {
        case .signedOut: lines.append("⚠︎ Claude Desktop isn't signed in")
        case .missing where !isRunning: lines.append("Claude Desktop not set up yet — Open Claude to sign in")
        default: break
        }
        return lines
    }

    private func moreMenu(_ account: Account, config: LauncherConfig) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        m.addItem(NSMenuItem.sectionHeader(title: "Claude Desktop"))
        m.addItem(action("Continue Last Session", symbol: "arrow.uturn.forward") {
            ClaudeInstances.open(account, url: ClaudeInstances.continueURL(), claudeAppPath: config.claudeAppPath) { e in
                if let e { AppDelegate.showError(e) } }
        })
        m.addItem(action("Sessions Waiting for You", symbol: "exclamationmark.bubble") {
            ClaudeInstances.open(account, url: ClaudeInstances.needsInputURL, claudeAppPath: config.claudeAppPath) { e in
                if let e { AppDelegate.showError(e) } }
        })

        m.addItem(.separator())
        m.addItem(NSMenuItem.sectionHeader(title: "Usage at API pay-as-you-go prices"))
        if let u = usage.summaries[account.id] {
            func line(_ label: String, _ t: DayTotals) -> String {
                "\(label): \(Pricing.usd(t.cost)) · \(UsageStore.tokens(t.total)) tokens · \(t.messages) replies"
            }
            m.addItem(info(line("Today", u.today)))
            m.addItem(info(line("7 days", u.week)))
            m.addItem(info(line("30 days", u.month)))
            if let peak = u.days.max(by: { $0.1.cost < $1.1.cost }), peak.1.cost > 0 {
                m.addItem(info("Busiest day: \(Self.weekday(peak.0)) · \(Pricing.usd(peak.1.cost))"))
            }
            if !u.monthByModel.isEmpty {
                let models = NSMenuItem(title: "By Model (30 days)", action: nil, keyEquivalent: "")
                models.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
                let sub = NSMenu(); sub.autoenablesItems = false
                for (model, t) in u.monthByModel {
                    let share = u.month.cost > 0 ? Int((t.cost / u.month.cost * 100).rounded()) : 0
                    sub.addItem(info("\(Pricing.displayName(model)): \(Pricing.usd(t.cost)) (\(share)%) · \(t.messages) replies"))
                }
                sub.addItem(.separator())
                let mo = u.month
                sub.addItem(info("Where it goes: cache writes \(Pricing.usd(mo.costCacheWrite)) · cache reads \(Pricing.usd(mo.costCacheRead)) · output \(Pricing.usd(mo.costOutput)) · input \(Pricing.usd(mo.costInput))"))
                sub.addItem(info("List prices as of \(Pricing.asOf); a subscription isn't billed this way"))
                models.submenu = sub
                m.addItem(models)
            }
        } else {
            m.addItem(info(usage.isRefreshing ? "Counting…" : "No usage yet"))
        }
        if let st = monitor.stats[account.id] {
            m.addItem(info("Claude Desktop: \(st.summary) · \(st.sessionCount) Code session\(st.sessionCount == 1 ? "" : "s")"))
        }
        m.addItem(action("Usage Details…", symbol: "chart.bar") { [weak self] in self?.openSettings(selecting: account.id) })

        m.addItem(.separator())
        m.addItem(NSMenuItem.sectionHeader(title: "Configuration"))
        for f in ClaudeConfigInfo.configFiles(account) {
            let item = action(f.title, symbol: "doc.text") { Self.openTextFile(f.url) }
            item.isEnabled = f.exists
            item.toolTip = abbreviate(f.url.path) + (f.exists ? "" : " (doesn't exist yet)")
            m.addItem(item)
        }
        m.addItem(action("Show Claude Code Config Folder", symbol: "folder") {
            NSWorkspace.shared.open(URL(fileURLWithPath: account.effectiveCLIConfigDir))
        })
        m.addItem(action("Show Claude Desktop Data Folder", symbol: "folder") {
            NSWorkspace.shared.open(URL(fileURLWithPath: account.resolvedDataDir))
        })
        return m
    }

    // MARK: Menu helpers

    /// A menu row that runs `run` when chosen; `alternate` makes it the modifier-key twin of the row before it.
    private func action(_ title: String, symbol: String? = nil, alternate: NSEvent.ModifierFlags? = nil,
                        _ run: @escaping () -> Void) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = MenuAction(run)
        mi.keyEquivalentModifierMask = alternate ?? []
        mi.isAlternate = alternate != nil
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return mi
    }

    private func info(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private func statusDot(running: Bool) -> NSImage? {
        let name = running ? "circle.fill" : "circle"
        let color: NSColor = running ? .systemGreen : .tertiaryLabelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: running ? "Running" : "Not running")?
            .withSymbolConfiguration(cfg)
    }

    private func statusSymbol(_ s: SessionStatus) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular).applying(.init(paletteColors: [s.color]))
        return NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.label)?.withSymbolConfiguration(cfg)
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    private static func weekday(_ day: String) -> String {
        guard let d = UsageStore.dayFormatter.date(from: day) else { return day }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: d)
    }

    static func openTextFile(_ url: URL) {
        // JSON and Markdown may have no default app; fall back to TextEdit.
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Launching

    func launch(_ account: Account, _ ws: Workspace?, terminal: Bool, prompt: String? = nil, extraArgs: [String] = []) {
        let done: (Error?) -> Void = { error in if let error { Self.showError(error) } }
        if terminal {
            var args = extraArgs
            if let prompt, !prompt.isEmpty { args.append(prompt) }
            TerminalLauncher.launch(account, workspace: ws, config: store.config, extraArgs: args, completion: done)
        } else {
            ClaudeInstances.launch(account, workspace: ws, prompt: prompt, claudeAppPath: store.config.claudeAppPath, completion: done)
        }
    }

    private func chooseFolderAndLaunch(_ account: Account, terminal: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = terminal ? "Open in Terminal" : "Open in Claude"
        panel.message = "Start a Claude Code session for \(account.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launch(account, Workspace(name: url.lastPathComponent, path: url.path), terminal: terminal)
    }

    private func saveFolder(_ path: String, to accountID: UUID) {
        guard let i = store.config.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let url = URL(fileURLWithPath: path)
        guard !store.config.accounts[i].workspaces.contains(where: { $0.expandedPath == path }) else { return }
        store.config.accounts[i].workspaces.append(Workspace(name: url.lastPathComponent, path: abbreviate(path)))
    }

    /// Asks for a folder and a prompt, then starts a session with that prompt.
    private func promptAndLaunch(_ account: Account, terminal: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        var choices: [(String, String)] = account.workspaces.map { ($0.name, $0.expandedPath) }
        for r in ClaudeConfigInfo.recentFolders(account, limit: 8) { choices.append(("\(r.name) (recent)", r.path)) }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 150, width: 420, height: 26))
        for (title, path) in choices { popup.addItem(withTitle: title); popup.lastItem?.representedObject = path }
        popup.addItem(withTitle: "Choose Folder…")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 28, width: 420, height: 114)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 13)
        text.isRichText = false
        let save = NSButton(checkboxWithTitle: "Save this prompt to the folder", target: nil, action: nil)
        save.frame = NSRect(x: 0, y: 0, width: 420, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        [popup, scroll, save].forEach(box.addSubview)

        let alert = NSAlert()
        alert.messageText = "New \(terminal ? "Terminal" : "Claude Desktop") session for \(account.name)"
        alert.informativeText = terminal
            ? "Claude Code starts in the folder and runs the prompt straight away."
            : "Claude Desktop opens a new Code session in the folder with the prompt filled in."
        alert.accessoryView = box
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let prompt = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = popup.selectedItem?.representedObject as? String
        if path == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            path = url.path
        }
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        var ws = account.workspaces.first { $0.expandedPath == path } ?? Workspace(name: url.lastPathComponent, path: path)

        if save.state == .on, !prompt.isEmpty {
            if let ai = store.config.accounts.firstIndex(where: { $0.id == account.id }) {
                if let wi = store.config.accounts[ai].workspaces.firstIndex(where: { $0.expandedPath == path }) {
                    store.config.accounts[ai].workspaces[wi].prompts.append(SavedPrompt(name: String(prompt.prefix(30)), text: prompt))
                } else {
                    ws.path = abbreviate(path)
                    ws.prompts = [SavedPrompt(name: String(prompt.prefix(30)), text: prompt)]
                    store.config.accounts[ai].workspaces.append(ws)
                }
            }
        }
        launch(account, ws, terminal: terminal, prompt: prompt)
    }

    /// Opens Claude for the login and every folder marked "Start My Day", each in its own mode.
    private func startMyDay(_ account: Account) {
        let folders = account.workspaces.filter(\.startOfDay)
        for ws in folders where ws.mode == .terminal { launch(account, ws, terminal: true) }
        let desktop = folders.filter { $0.mode == .desktop }
        guard !desktop.isEmpty else { return }

        let config = store.config
        func sendRest(_ rest: ArraySlice<Workspace>) {
            guard let next = rest.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ClaudeInstances.launch(account, workspace: next, claudeAppPath: config.claudeAppPath) { _ in }
                sendRest(rest.dropFirst())
            }
        }
        if ClaudeInstances.running()[account.resolvedDataDir] != nil {
            ClaudeInstances.launch(account, workspace: desktop[0], claudeAppPath: config.claudeAppPath) { e in
                if let e { Self.showError(e) } }
            sendRest(desktop.dropFirst())
            return
        }
        // Cold start: launch with the first folder, wait until Claude is up, then send the others.
        ClaudeInstances.launch(account, workspace: desktop[0], claudeAppPath: config.claudeAppPath) { e in
            if let e { Self.showError(e) } }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            waited += 1
            if ClaudeInstances.running()[account.resolvedDataDir] != nil || waited > 30 {
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { sendRest(desktop.dropFirst()) }
            }
        }
    }

    private func registerFolderHotKeys() {
        folderHotKeyIDs.forEach(HotKeyCenter.shared.unregister)
        folderHotKeyIDs = []
        var used = Set<Int>()
        for account in store.config.accounts {
            for ws in account.workspaces {
                guard let digit = ws.hotkey, let key = HotKeyCenter.digitKeys[digit], !used.contains(digit) else { continue }
                used.insert(digit)
                let accountID = account.id, wsID = ws.id
                if let id = HotKeyCenter.shared.register(keyCode: key, modifiers: HotKeyCenter.controlOptionCommand, action: { [weak self] in
                    guard let self,
                          let a = self.store.config.accounts.first(where: { $0.id == accountID }),
                          let w = a.workspaces.first(where: { $0.id == wsID }) else { return }
                    self.launch(a, w, terminal: w.mode == .terminal)
                }) {
                    folderHotKeyIDs.append(id)
                }
            }
        }
    }

    // MARK: Windows

    private func checkForUpdates() {
        let updates = UpdateChecker.shared
        updates.check { found in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            if updates.updateAvailable, let v = updates.latestVersion {
                alert.messageText = "Ant AI Launcher \(v) is available"
                alert.informativeText = "You have \(updates.currentVersion). Download the new version and replace the app in Applications."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(updates.latestURL ?? UpdateChecker.releasesPage)
                }
            } else {
                alert.messageText = found ? "You're up to date" : "Couldn't check for updates"
                alert.informativeText = found
                    ? "Ant AI Launcher \(updates.currentVersion) is the latest version."
                    : "GitHub couldn't be reached. Releases are at \(UpdateChecker.releasesPage.absoluteString)."
                alert.runModal()
            }
        }
    }

    private func showAbout() {
        let credits = NSMutableAttributedString(string: "Made by \(Brand.company)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: Brand.websiteLabel, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: Brand.website]))
        let para = NSMutableParagraphStyle(); para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Ant AI Launcher",
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 \(Brand.company)",
        ])
    }

    @objc func openSettings() { openSettings(selecting: nil) }

    func openSettings(selecting accountID: UUID?) {
        if let accountID { SettingsSelection.shared.selection = accountID }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(store: store))
            let win = NSWindow(contentViewController: host)
            // A plain titled window (no toolbar) so AppKit centres the title.
            win.title = "Ant AI Launcher — \(Brand.company)"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.titleVisibility = .visible
            win.toolbar = nil
            win.setContentSize(NSSize(width: 880, height: 620))
            win.isReleasedWhenClosed = false
            win.center()
            win.setFrameAutosaveName("ClaudeLauncherSettings")
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()   // macOS 14+ may refuse activation for background launches
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Self.showError(error)
        }
    }

    static func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ant AI Launcher"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Wraps a closure so it can ride on an NSMenuItem's representedObject.
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

@main
enum Main {
    static func main() {
        // `AntAILauncher --status` prints each login and whether Claude is running for it, then exits.
        if CommandLine.arguments.contains("--status") {
            printStatus()
            exit(0)
        }
        // Used by build.sh to render the app icon from the same drawing code.
        if let i = CommandLine.arguments.firstIndex(of: "--write-iconset"), i + 1 < CommandLine.arguments.count {
            do { try Brand.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
            catch { print(error); exit(1) }
        }
        // `AntAILauncher --launch <login> [--folder <name or path>] [--terminal]` launches and exits, for scripts.
        if let i = CommandLine.arguments.firstIndex(of: "--launch") {
            exit(runCommandLineLaunch(Array(CommandLine.arguments[(i + 1)...])))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu()
        app.run()
    }

    /// `AntAILauncher --status`: logins, sign-ins, live sessions, recent folders and usage.
    private static func printStatus() {
        func spin(until done: () -> Bool, timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(timeout)
            while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        }
        let config = ConfigStore.shared.config
        let running = ClaudeInstances.running()
        let monitor = SessionMonitor.shared
        monitor.refresh()
        spin(until: { false }, timeout: 1.5)
        monitor.refresh()                        // second sample gives CPU %
        spin(until: { false }, timeout: 1.5)
        let usage = UsageStore.shared
        let t0 = Date()
        usage.start()
        spin(until: { usage.lastUpdated != nil }, timeout: 300)
        let usageSecs = Date().timeIntervalSince(t0)

        for a in config.accounts {
            let pid = running[a.resolvedDataDir].map { "running (pid \($0.processIdentifier))" } ?? "not running"
            print("\(a.name): Desktop \(pid), \(ClaudeConfigInfo.desktopState(a)) — \(abbreviate(a.resolvedDataDir))")
            if let st = monitor.stats[a.id] { print("   Desktop resources: \(st.summary), \(st.sessionCount) Code sessions") }
            let who = ClaudeConfigInfo.cliIdentity(a)
            print("   Claude Code: \(who?.email ?? "NOT signed in") \(who?.organization.map { "(\($0))" } ?? "") — \(abbreviate(a.effectiveCLIConfigDir))")
            if let u = usage.summaries[a.id] {
                print("   Usage today: \(UsageStore.tokens(u.today.total)) tokens (\(UsageStore.tokens(u.today.output)) out), \(u.today.messages) replies, \(u.sessionsToday) sessions")
                print("   At API prices: today \(Pricing.usd(u.today.cost)), 7 days \(Pricing.usd(u.week.cost)), 30 days \(Pricing.usd(u.month.cost))")
                print("   Last 7 days: " + u.days.map { "\($0.0.suffix(5)) \(Pricing.usd($0.1.cost))" }.joined(separator: ", "))
                for (model, t) in u.monthByModel {
                    print("     \(Pricing.displayName(model).padding(toLength: 11, withPad: " ", startingAt: 0)) \(Pricing.usd(t.cost).padding(toLength: 9, withPad: " ", startingAt: 0)) \(t.messages) replies · in \(UsageStore.tokens(t.input)) · write 5m \(UsageStore.tokens(t.cacheWrite5m)) / 1h \(UsageStore.tokens(t.cacheWrite1h)) · read \(UsageStore.tokens(t.cacheRead)) · out \(UsageStore.tokens(t.output))\(t.unpriced > 0 ? " · \(t.unpriced) unpriced" : "")")
                }
            }
            let recent = ClaudeConfigInfo.recentFolders(a, limit: 5)
            print("   Recent: " + (recent.isEmpty ? "none" : recent.map(\.name).joined(separator: ", ")))
            for w in a.workspaces { print("   Folder \(w.name) [\(w.mode.rawValue)\(w.hotkey.map { ", ⌃⌥⌘\($0)" } ?? "")] → \(ClaudeInstances.codeSessionURL(folder: w.expandedPath))") }
        }
        print("Sessions (\(monitor.sessions.count)):")
        for s in monitor.sessions {
            let login = config.accounts.first { $0.id == s.accountID }?.name ?? "?"
            print("   [\(s.status.label)] \(s.name) — \(s.folderName) · \(login) · \(s.isDesktop ? "Desktop" : "Terminal \(s.tty ?? "")")\(s.waitingFor.map { " · waiting for \($0)" } ?? "")")
        }
        print(String(format: "(usage scan took %.1fs)", usageSecs))
    }

    private static func runCommandLineLaunch(_ args: [String]) -> Int32 {
        let config = ConfigStore.shared.config
        guard let loginName = args.first,
              let account = config.accounts.first(where: { $0.name.caseInsensitiveCompare(loginName) == .orderedSame }) else {
            let names = config.accounts.map(\.name).joined(separator: ", ")
            FileHandle.standardError.write("usage: AntAILauncher --launch <login> [--folder <name|path>] [--terminal]\nlogins: \(names)\n".data(using: .utf8)!)
            return 2
        }
        var workspace: Workspace?
        if let f = args.firstIndex(of: "--folder"), f + 1 < args.count {
            let q = args[f + 1]
            workspace = account.workspaces.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
                ?? Workspace(name: URL(fileURLWithPath: (q as NSString).expandingTildeInPath).lastPathComponent,
                             path: (q as NSString).expandingTildeInPath)
        }
        var status: Int32 = 0
        var finished = false
        let done: (Error?) -> Void = { error in
            if let error {
                FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
                status = 1
            }
            finished = true
        }
        if args.contains("--terminal") {
            TerminalLauncher.launch(account, workspace: workspace, config: config, completion: done)
        } else {
            ClaudeInstances.launch(account, workspace: workspace, claudeAppPath: config.claudeAppPath, completion: done)
        }
        let deadline = Date().addingTimeInterval(30)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return status
    }

    /// Accessory apps still need a main menu for ⌘C/⌘V/⌘A/⌘W to work in the Settings window.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Ant AI Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        return main
    }
}

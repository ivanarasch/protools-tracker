import AppKit
import ApplicationServices
import ServiceManagement

let dayFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func isProTools(_ app: NSRunningApplication) -> Bool {
    isProToolsProcess(name: app.localizedName, bundleID: app.bundleIdentifier, isRegular: app.activationPolicy == .regular)
}

private func title(of window: AXUIElement) -> String? {
    var t: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t) == .success,
          let s = t as? String, !s.isEmpty else { return nil }
    return s
}

/// The .ptx a session window has open. Pro Tools reports it as the window's document.
private func documentPath(of window: AXUIElement) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &v) == .success,
          let value = v else { return nil }
    if let s = value as? String { return pathFromDocumentValue(s) }
    if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL as URL).path }
    return nil
}

enum WindowRead {
    case session(title: String, document: String?)   // found an Edit/Mix/… window, and the .ptx it has open
    case noSession         // windows were readable, but none is a session (Dashboard, Open dialog, between sessions)
    case unreadable        // Accessibility call failed — says nothing about what's open
}

/// Title of whichever Pro Tools window has focus right now. A plug-in window is "Plug-in: <name>".
func focusedWindowTitle(of app: NSRunningApplication) -> String? {
    var win: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                        kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return nil }
    return title(of: w as! AXUIElement)
}

func readWindow(of app: NSRunningApplication) -> WindowRead {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    // Main window first, then focused: the Edit/Mix window, not a dialog or plug-in
    // window that happens to be reported as main/focused (e.g. a "Missing AAX
    // Plugins" alert or the Open dialog) — those must never become a project name.
    for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, attr as CFString, &win) == .success, let w = win,
           let s = title(of: w as! AXUIElement), looksLikeSessionWindow(s) {
            return .session(title: s, document: documentPath(of: w as! AXUIElement))
        }
    }
    // Neither resolved — scan every window, but still only accept one that looks like a real session window.
    var winsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &winsRef) == .success,
          let wins = winsRef as? [AXUIElement] else { return .unreadable }
    for w in wins {
        if let s = title(of: w), looksLikeSessionWindow(s) { return .session(title: s, document: documentPath(of: w)) }
    }
    return .noSession
}

final class Store {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ProToolsTimeTracker")
    var log: [String: [String: Int]] = [:]                  // project -> day -> seconds
    var acts: [String: [String: [String: Int]]] = [:]       // project -> day -> activity -> seconds
    var links: [String: String] = [:]                       // project -> session folder
    var breaks: [String: [String: Int]] = [:]               // project -> day -> idle seconds (not worked time)
    var plugins: [String: [String: [String: [String: Int]]]] = [:]   // project -> day -> activity -> plug-in -> seconds in front (a split of that activity's time)

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Pick up data from the earlier Python script, once.
        let old = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".protools-tracker")
        for name in ["log.json", "links.json"] {
            let new = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: new.path) {
                try? FileManager.default.copyItem(at: old.appendingPathComponent(name), to: new)
            }
        }
        log = read("log.json") ?? [:]
        acts = read("activities.json") ?? [:]
        links = read("links.json") ?? [:]
        breaks = read("breaks.json") ?? [:]
        if let now: [String: [String: [String: [String: Int]]]] = read("plugins.json") {
            plugins = now
        } else if let old: [String: [String: [String: Int]]] = read("plugins.json") {
            // First version kept plug-in time without saying which activity it was part of. Credit each day's
            // plug-in time to that day's busiest activity, the most likely home for it.
            for (project, days) in old {
                for (day, byPlugin) in days {
                    let busiest = (acts[project]?[day] ?? [:]).max { $0.value < $1.value }?.key ?? unspecified
                    plugins[project, default: [:]][day, default: [:]][busiest] = byPlugin
                }
            }
        }
        // Earlier versions sometimes logged Pro Tools' own window title, or a dialog/
        // alert title, as if it were a session name. Clean those out.
        let dialogTitles: Set<String> = ["Open", "Save", "Save As", "Save Session Copy In",
            "Import Audio", "Import Session Data", "Missing AAX Plugins", "Missing Fonts",
            "Warning", "Alert", "New Session", "New Tracks", "Bounce", "Bounce to Disk",
            "Consolidate", "Relink"]
        for k in log.keys where k.hasPrefix("Pro Tools") || dialogTitles.contains(k) {
            log.removeValue(forKey: k); acts.removeValue(forKey: k); breaks.removeValue(forKey: k); plugins.removeValue(forKey: k)
        }
    }

    func read<T: Decodable>(_ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func write<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(value) { try? d.write(to: dir.appendingPathComponent(name)) }
    }

    func save() {
        write(log, "log.json")
        write(acts, "activities.json")
        write(links, "links.json")
        write(breaks, "breaks.json")
        write(plugins, "plugins.json")
    }

    func remove(project: String) {
        log.removeValue(forKey: project)
        acts.removeValue(forKey: project)
        links.removeValue(forKey: project)
        breaks.removeValue(forKey: project)
        plugins.removeValue(forKey: project)
        save()
    }

    func fullCSV() -> String { buildFullCSV(log: log, acts: acts, breaks: breaks, plugins: plugins) }

    func projectCSV(_ project: String) -> String {
        buildProjectCSV(project: project, log: log, acts: acts, breaks: breaks, plugins: plugins)
    }

    func addPlugin(project: String, activity: String, plugin: String, seconds: Int) {
        plugins[project, default: [:]][dayFmt.string(from: Date()), default: [:]][activity, default: [:]][plugin, default: 0] += seconds
    }

    /// Plug-in -> total seconds in front, across all days.
    func pluginTotals(_ project: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for (_, day) in plugins[project] ?? [:] { for (_, byPlugin) in day { for (p, s) in byPlugin { out[p, default: 0] += s } } }
        return out
    }

    /// Whether to keep a "<project> - Pro Tools Hours.csv" inside each session folder.
    var writeCSVs = UserDefaults.standard.object(forKey: "writeSessionCSV") as? Bool ?? true

    /// Keeps this project's hours CSV up to date inside its session folder, so the hours
    /// travel with the session without any manual export step.
    func writeProjectCSV(_ project: String) {
        guard writeCSVs, let folder = links[project] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(project) - Pro Tools Hours.csv")
        try? projectCSV(project).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Two different session folders can share a name ("Session", "Final Mix"). The second one
    /// gets its parent folder added, so their hours don't get merged into one project.
    func uniqueProject(_ name: String, folder: String) -> String {
        if let existing = links[name], existing != folder, FileManager.default.fileExists(atPath: existing) {
            let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().lastPathComponent
            return "\(name) (\(parent))"
        }
        return name
    }

    /// Ties a project to its session folder, and folds in time already logged under the
    /// session names of the .ptx files in that folder. Does nothing if it's already linked.
    func link(project: String, folder: String) {
        guard links[project] != folder else { return }
        links[project] = folder
        for session in sessionFiles(in: folder) where session != project {
            if let days = log.removeValue(forKey: session) {
                for (d, s) in days { log[project, default: [:]][d, default: 0] += s }
            }
            if let days = acts.removeValue(forKey: session) {
                for (d, byAct) in days { for (a, s) in byAct { acts[project, default: [:]][d, default: [:]][a, default: 0] += s } }
            }
        }
        save()
        writeProjectCSV(project)
    }

    func sessionFiles(in folder: String) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return items.filter { $0.hasSuffix(".ptx") || $0.hasSuffix(".ptf") }
            .map { ($0 as NSString).deletingPathExtension }
    }

    /// Map a session name to its linked project, else keep the session name.
    func resolve(_ session: String) -> String {
        for (project, folder) in links where sessionFiles(in: folder).contains(session) { return project }
        return session
    }

    func addTime(project: String, activity: String, seconds: Int) {
        let day = dayFmt.string(from: Date())
        log[project, default: [:]][day, default: 0] += seconds
        acts[project, default: [:]][day, default: [:]][activity, default: 0] += seconds
    }

    func addBreak(project: String, seconds: Int) {
        breaks[project, default: [:]][dayFmt.string(from: Date()), default: 0] += seconds
    }

    func total(_ project: String) -> Int { log[project]?.values.reduce(0, +) ?? 0 }

    func breakTotal(_ project: String) -> Int { breaks[project]?.values.reduce(0, +) ?? 0 }

    func activityTotals(_ project: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for (_, day) in acts[project] ?? [:] { for (a, s) in day { out[a, default: 0] += s } }
        return out
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let watcher = RecordingWatcher()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var current: String?         // project currently being worked on
    var lastSession: String?
    var lastTitle: String?       // last Pro Tools window title seen (shown in the menu for troubleshooting)
    var guess: String?           // activity guessed from the Edit/Mix window
    var focusedPlugin: String?   // plug-in whose window is in front right now, if any
    var noSessionOpen = false    // Pro Tools is in front but has no session window open
    var openProject: String?     // project and folder found from the open session file's own path
    var openFolder: String?
    var docSession: String?      // the session name those were read for
    var nowActivity: String?
    var nowSource = ""
    var notCounting = ""          // why the current tick isn't adding time, if it isn't
    var paused = false
    var manual: String? = UserDefaults.standard.string(forKey: "manualActivity")

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        // macOS moves this item whenever another menu bar item appears or goes; re-fit right away
        // instead of waiting up to a poll, which is long enough for it to sit hidden under the notch.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] n in
            if let self, let w = n.object as? NSWindow, w === self.item.button?.window { self.refreshTitle() }
        }
        if !AXIsProcessTrusted() { requestAccessibility() }
        // .common keeps ticking while a menu is open (a default-mode timer pauses during menu
        // tracking, so time was silently lost whenever the menu was showing).
        let timer = Timer(timeInterval: poll, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        _ = observe()   // show the open session straight away instead of after the first tick
    }

    /// How wide the menu bar item can be before macOS hides it. The item grows leftwards from its
    /// right edge, and on a notched MacBook the room ends where the notch's right-hand area starts.
    /// Other menu bar items (the orange microphone dot, other apps' icons) come and go and each one
    /// pushes this item left by its own width, so the room is the tightest seen over the last two
    /// minutes. Using only the current room made the title grow back whenever one of them left,
    /// then slide under the notch as soon as it returned.
    var roomSeen: [(at: Date, room: CGFloat)] = []

    func titleRoom() -> CGFloat {
        let now = Date()
        roomSeen.removeAll { now.timeIntervalSince($0.at) > 120 }
        // Just after launch, macOS reports the item at the far left of the screen before it has been placed.
        // That reading says nothing about the room, and remembering it kept the title bare for two minutes.
        guard let win = item.button?.window, win.frame.width > 0, let screen = win.screen ?? NSScreen.main else {
            return roomSeen.map(\.room).min() ?? 110   // not laid out yet: stay small
        }
        let leftLimit = screen.auxiliaryTopRightArea?.minX ?? (win.frame.maxX - 240)
        if win.frame.maxX > leftLimit + 60 {   // placed: its right edge doesn't move with the title's own width
            roomSeen.append((now, win.frame.maxX - leftLimit - 12))
        }
        return roomSeen.map(\.room).min() ?? 110
    }

    func refreshTitle() {
        let icon = paused ? "⏸" : "⏱"
        let font = item.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        let title = fitTitle(icon: icon, name: current, time: current.map { fmt(store.total($0)) },
                             maxWidth: titleRoom()) {
            NSAttributedString(string: $0, attributes: [.font: font]).size().width + 23   // 23 = the button's own padding
        }
        if item.button?.title != title { item.button?.title = title }
    }

    /// Forget the previous session so it can't be credited with time once it's closed.
    func forgetSession() {
        lastSession = nil; lastTitle = nil; guess = nil
        openProject = nil; openFolder = nil; docSession = nil
        current = nil; nowActivity = nil; focusedPlugin = nil
    }

    /// The project for the open session: the one found from its file path, else matched by name.
    var projectNow: String {
        if let p = openProject, lastSession == docSession { return p }
        return store.resolve(lastSession ?? "Unknown session")
    }

    /// Works out which session is open and updates the menu bar and menu to match.
    /// Never counts time, so it's safe to call whenever the display should be fresh.
    /// Returns nil when Pro Tools isn't running.
    func observe() -> (pt: NSRunningApplication, front: Bool)? {
        guard let pt = NSWorkspace.shared.runningApplications.first(where: isProTools) else {
            // Pro Tools isn't running: a fresh launch must not inherit the last session.
            forgetSession(); noSessionOpen = false; refreshTitle()
            return nil
        }
        let front = NSWorkspace.shared.frontmostApplication.map(isProTools) ?? false
        noSessionOpen = false
        switch readWindow(of: pt) {
        case .session(let title, let document):
            lastTitle = title
            if let name = sessionName(title), !name.hasPrefix("Pro Tools") {
                lastSession = name
                if let document {
                    // Pro Tools says exactly where this session lives, so there's nothing to link by hand.
                    let id = sessionIdentity(documentPath: document,
                                             hasAudioFolder: { FileManager.default.fileExists(atPath: $0 + "/Audio Files") })
                    if let folder = id.folder {
                        let project = store.uniqueProject(id.project, folder: folder)
                        store.link(project: project, folder: folder)
                        openProject = project; openFolder = folder
                    } else {
                        openProject = id.project; openFolder = nil
                    }
                    docSession = name
                } else if name != docSession {
                    // A session whose file we couldn't locate: don't keep crediting the last one's folder.
                    openProject = nil; openFolder = nil; docSession = nil
                }
                current = projectNow   // known as soon as the window is read, not only once time is counted
            }
            if let a = windowActivity(title) { guess = a }
        case .noSession:
            // Dashboard, Open dialog, or between sessions. Only trust this while Pro Tools is
            // in front — a window on another Space can be hidden from Accessibility.
            if front { forgetSession(); noSessionOpen = true }
        case .unreadable:
            break   // keep what we had; a failed read isn't evidence the session changed
        }
        // Which plug-in (if any) you're working in: its window has focus. The Edit/Mix window stays
        // the session's main window while a plug-in window floats above it, so this doesn't disturb the above.
        focusedPlugin = (front && !noSessionOpen) ? focusedWindowTitle(of: pt).flatMap { pluginName(fromWindowTitle: $0) } : nil
        refreshTitle()
        return (pt, front)
    }

    @objc func tick() {
        guard !paused, let seen = observe() else { return }
        let front = seen.front
        // Watch the open session's own Audio Files folder for growing files. If we couldn't
        // work out which session that is (e.g. Accessibility access not granted), fall back to
        // watching every known folder, so recording is never missed just because the name didn't resolve.
        var recordingProject: String?
        if let p = openProject, let f = openFolder, lastSession == docSession {
            if watcher.check(folder: f) { recordingProject = p }
        } else {
            for (linkedProject, folder) in store.links where watcher.check(folder: folder) {
                recordingProject = linkedProject
            }
        }

        // No session open (and nothing being recorded): there's no project to credit this time to.
        if noSessionOpen && recordingProject == nil { refreshTitle(); return }

        let project = recordingProject ?? projectNow
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        // Recording counts even when Pro Tools is in the background or you're away from the keyboard,
        // so a long take with no input is never mistaken for a break.
        if recordingProject == nil, front, idle >= idleLimit {
            // In front but untouched: not work. Log it as break time against the open session instead.
            nowActivity = nil
            notCounting = "On break — no keyboard or mouse activity for \(Int(idleLimit / 60))+ minutes"
            if lastSession != nil {
                store.addBreak(project: project, seconds: Int(poll))
                store.save()
                store.writeProjectCSV(project)
            }
            return
        }
        guard front || recordingProject != nil else {
            nowActivity = nil
            notCounting = "Not counting — Pro Tools isn't the front app"
            return
        }
        notCounting = ""

        // Detected recording beats a manual tag, which beats the Edit/Mix window guess.
        if recordingProject != nil { nowActivity = "Recording"; nowSource = "detected" }
        else if let m = manual { nowActivity = m; nowSource = "manual" }
        else if let g = guess { nowActivity = g; nowSource = "from window" }
        else { nowActivity = unspecified; nowSource = "" }

        current = project
        store.addTime(project: project, activity: nowActivity!, seconds: Int(poll))
        if let plugin = focusedPlugin { store.addPlugin(project: project, activity: nowActivity!, plugin: plugin, seconds: Int(poll)) }
        store.save()
        store.writeProjectCSV(project)
        refreshTitle()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
            return i
        }

        if !AXIsProcessTrusted() {
            _ = add("⚠︎ Allow Accessibility access (needed to read session names)…", #selector(requestAccessibility))
            menu.addItem(.separator())
        }

        let seen = observe()   // refresh now, so this never shows a stale or empty project
        if seen == nil {
            _ = add("Pro Tools isn't running", nil)
        } else if noSessionOpen {
            _ = add("No session open in Pro Tools", nil)
        } else if let c = current {
            _ = add("Project: \(c)", nil)
        }
        if paused {
            _ = add("Paused", nil)
        } else if let a = nowActivity {
            _ = add("Now: \(a)" + (nowSource.isEmpty ? "" : " (\(nowSource))"), nil)
        } else if seen != nil, !noSessionOpen, !notCounting.isEmpty {
            _ = add(notCounting, nil)
        }
        if let p = focusedPlugin, !paused { _ = add("Plug-in: \(p)", nil) }
        if let c = current, store.links[c] == nil {
            _ = add("Couldn't find this session's folder — use Link Session Folder… to detect recording", nil)
        }
        if let t = lastTitle { _ = add("Window: \(t)", nil) }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }

        func projectItem(_ p: String) -> NSMenuItem {
            let mark = (p == current && !paused) ? "● " : ""
            let parent = NSMenuItem(title: "\(mark)\(p) — \(fmt(store.total(p)))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let by = store.activityTotals(p)
            for name in activities + [unspecified] where (by[name] ?? 0) > 0 {
                sub.addItem(NSMenuItem(title: "\(name) — \(fmt(by[name]!))", action: nil, keyEquivalent: ""))
            }
            let rest = store.total(p) - by.values.reduce(0, +)
            if rest >= 60 {
                sub.addItem(NSMenuItem(title: "Before activity tracking — \(fmt(rest))", action: nil, keyEquivalent: ""))
            }
            if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "No breakdown yet", action: nil, keyEquivalent: "")) }
            let used = store.pluginTotals(p).filter { $0.value >= 60 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            if !used.isEmpty {
                sub.addItem(.separator())
                let plug = NSMenuItem(title: "Plug-ins", action: nil, keyEquivalent: "")
                let plugMenu = NSMenu()
                for (name, secs) in used.prefix(15) {
                    plugMenu.addItem(NSMenuItem(title: "\(name) — \(fmt(secs))", action: nil, keyEquivalent: ""))
                }
                plugMenu.addItem(.separator())
                plugMenu.addItem(NSMenuItem(title: "Time with the plug-in window in front", action: nil, keyEquivalent: ""))
                plug.submenu = plugMenu
                sub.addItem(plug)
            }
            if store.breakTotal(p) >= 60 {
                sub.addItem(.separator())
                sub.addItem(NSMenuItem(title: "\(breakLabel) (not counted) — \(fmt(store.breakTotal(p)))", action: nil, keyEquivalent: ""))
            }
            if store.links[p] != nil, store.writeCSVs {
                sub.addItem(.separator())
                sub.addItem(NSMenuItem(title: "CSV kept up to date in session folder", action: nil, keyEquivalent: ""))
            }
            parent.submenu = sub
            return parent
        }

        let shown = groupProjects(lastDay: store.log.mapValues { $0.keys.max() ?? "" },
                                  total: store.log.mapValues { $0.values.reduce(0, +) },
                                  current: current, limit: 6)
        if shown.recent.isEmpty {
            _ = add("No time logged yet — open a session in Pro Tools", nil)
        }
        for p in shown.recent { menu.addItem(projectItem(p)) }
        if !shown.older.isEmpty {
            let older = NSMenuItem(title: "Older Projects (\(shown.older.count))", action: nil, keyEquivalent: "")
            let olderMenu = NSMenu()
            for p in shown.older { olderMenu.addItem(projectItem(p)) }
            older.submenu = olderMenu
            menu.addItem(older)
        }
        menu.addItem(.separator())

        let actParent = NSMenuItem(title: "Activity: " + (manual ?? "Auto"), action: nil, keyEquivalent: "")
        let actMenu = NSMenu()
        let auto = NSMenuItem(title: "Auto (from Edit/Mix window)", action: #selector(setActivity(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = manual == nil ? .on : .off
        actMenu.addItem(auto)
        actMenu.addItem(.separator())
        for name in activities {
            let i = NSMenuItem(title: name, action: #selector(setActivity(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = name
            i.state = manual == name ? .on : .off
            actMenu.addItem(i)
        }
        actParent.submenu = actMenu
        menu.addItem(actParent)
        menu.addItem(.separator())

        _ = add("Link Session Folder…", #selector(linkFolder))
        if !store.links.isEmpty {
            let sub = NSMenu()
            for name in store.links.keys.sorted() {
                let i = NSMenuItem(title: name, action: #selector(unlink(_:)), keyEquivalent: "")
                i.target = self
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: "Unlink Folder", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        if !store.log.isEmpty {
            let sub = NSMenu()
            let all = groupProjects(lastDay: store.log.mapValues { $0.keys.max() ?? "" },
                                    total: store.log.mapValues { $0.values.reduce(0, +) },
                                    current: current, limit: .max).recent
            for p in all {
                let i = NSMenuItem(title: "\(p) — \(fmt(store.total(p)))", action: #selector(removeProject(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = p
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: "Remove Project…", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        _ = add("Export All Projects CSV…", #selector(exportAllCSV))
        let csvItem = add("Save Hours CSV in Session Folders", #selector(toggleSessionCSV))
        csvItem.state = store.writeCSVs ? .on : .off
        menu.addItem(.separator())

        _ = add(paused ? "Resume Tracking" : "Pause Tracking", #selector(togglePause))
        let status = SMAppService.mainApp.status
        let login = add(status == .requiresApproval ? "Launch at Login — needs your approval…" : "Launch at Login", #selector(toggleLogin))
        login.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        menu.addItem(.separator())
        _ = add("Quit", #selector(quit))
    }

    @objc func setActivity(_ sender: NSMenuItem) {
        let v = sender.representedObject as? String ?? ""
        manual = v.isEmpty ? nil : v
        UserDefaults.standard.set(manual, forKey: "manualActivity")
    }

    @objc func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @objc func linkFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Pro Tools session folder (the one containing the .ptx file)"
        panel.prompt = "Link"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if store.sessionFiles(in: url.path).isEmpty {
            let a = NSAlert()
            a.messageText = "No session file found"
            a.informativeText = "There's no .ptx or .ptf file directly inside “\(url.lastPathComponent)”. Choose the folder that contains the session file."
            a.runModal()
            return
        }
        store.link(project: store.uniqueProject(url.lastPathComponent, folder: url.path), folder: url.path)
        refreshTitle()
    }

    @objc func unlink(_ sender: NSMenuItem) {
        store.links.removeValue(forKey: sender.title)
        store.save()
    }

    /// Deletes a project's logged hours (and its folder link) after confirming. Used to clear out
    /// leftovers like "Unknown session" or a misnamed project. CSVs already written into a session
    /// folder are not touched.
    @objc func removeProject(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Remove “\(p)”?"
        var detail = "This deletes its \(fmt(store.total(p))) of logged time. It can't be undone. A CSV already saved in the session folder is left alone."
        if p == current { detail += " It's open in Pro Tools right now, so tracking will start it again from zero." }
        a.informativeText = detail
        a.addButton(withTitle: "Cancel")           // first button is the default, so Return doesn't delete
        a.addButton(withTitle: "Remove")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        store.remove(project: p)
        refreshTitle()
    }

    @objc func exportAllCSV() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "protools-hours-all-projects.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.fullCSV().write(to: url, atomically: true, encoding: .utf8)
    }

    @objc func toggleSessionCSV() {
        store.writeCSVs.toggle()
        UserDefaults.standard.set(store.writeCSVs, forKey: "writeSessionCSV")
    }

    @objc func togglePause() { paused.toggle(); refreshTitle() }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        NSApp.activate(ignoringOtherApps: true)
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        if svc.status == .enabled {
            do { try svc.unregister() } catch { loginAlert("Couldn't turn off Launch at Login", error.localizedDescription) }
            return
        }
        if let problem = launchAtLoginProblem(appPath: Bundle.main.bundlePath) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Launch at Login may not work from here"
            a.informativeText = problem
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Turn On Anyway")
            guard a.runModal() == .alertSecondButtonReturn else { return }
        }
        do { try svc.register() } catch { loginAlert("Couldn't turn on Launch at Login", error.localizedDescription); return }
        if svc.status == .requiresApproval {
            // macOS asks before letting a new login item run. Until it's approved, nothing starts at login.
            loginAlert("One more step", "Turn on “Pro Tools Time Tracker” in System Settings → General → Login Items & Extensions, "
                       + "or Launch at Login won't work.", openSettings: true)
        }
    }

    private func loginAlert(_ title: String, _ detail: String, openSettings: Bool = false) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        if openSettings { a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Later") }
        if a.runModal() == .alertFirstButtonReturn, openSettings { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

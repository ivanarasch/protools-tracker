import Foundation

let poll: TimeInterval = 10
/// With Pro Tools in front, this long without keyboard or mouse input stops the work clock and
/// starts the break clock instead.
let idleLimit: TimeInterval = 5 * 60

let activities = ["Recording", "Editing", "Mixing", "Mastering", "Other"]
let unspecified = "Unspecified"
/// Idle time is logged under this name in the reports. It is never part of a project's worked time.
let breakLabel = "Break"

func fmt(_ s: Int) -> String { String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }

/// Menu order for the project list: the project you're in right now first, then most recently
/// worked-on (ties: more total hours first). Only the first `limit` go in the menu itself and the
/// rest are tucked into an "Older Projects" submenu, so the menu stays short however many sessions pile up.
func groupProjects(lastDay: [String: String], total: [String: Int], current: String?, limit: Int)
    -> (recent: [String], older: [String]) {
    var order = lastDay.keys.sorted { a, b in
        let (da, db) = (lastDay[a] ?? "", lastDay[b] ?? "")
        return da != db ? da > db : (total[a] ?? 0, a) > (total[b] ?? 0, b)
    }
    if let c = current, let i = order.firstIndex(of: c) { order.remove(at: i); order.insert(c, at: 0) }
    return (Array(order.prefix(limit)), Array(order.dropFirst(limit)))
}

/// "11. La Mujer Sin Corazon 6" -> "La Mujer Sin Corazon 6". A leading track/album number ("11. ", "13) ")
/// says little in the menu bar and takes room the real name needs. Names like "Untitled-2" are left alone.
func menuBarName(_ name: String) -> String {
    let rest = name.replacingOccurrences(of: "^\\d+[.)]\\s+", with: "", options: .regularExpression)
    return rest.isEmpty ? name : rest
}

/// The menu bar title: "⏱ La Mujer Sin Corazon 6 · 0h 31m" if that fits in `maxWidth`, else the name cut back
/// to whole words ("⏱ La Mujer… · 0h 31m"), else the first word cut short, else just "⏱ 0h 31m", else just "⏱".
/// macOS silently hides a menu bar item that doesn't fit beside the notch, so the title has to be sized to
/// the room it really has.
func fitTitle(icon: String, name: String?, time: String?, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
    guard let name, let time else { return icon }
    func make(_ n: String) -> String { "\(icon) \(n) · \(time)" }
    let shown = menuBarName(name)
    if measure(make(shown)) <= maxWidth { return make(shown) }
    let words = shown.split(separator: " ").map(String.init)
    for count in stride(from: words.count - 1, through: 1, by: -1) {
        let candidate = make(words[..<count].joined(separator: " ") + "…")
        if measure(candidate) <= maxWidth { return candidate }
    }
    var n = words.first ?? shown
    while n.count > 3 {
        n = String(n.dropLast())
        let candidate = make(n + "…")
        if measure(candidate) <= maxWidth { return candidate }
    }
    let bare = "\(icon) \(time)"
    return measure(bare) <= maxWidth ? bare : icon
}

/// "Edit: My Song", "Mix: My Song", "My Song.ptx - Edit" -> "My Song"
func sessionName(_ title: String) -> String? {
    var t = title.trimmingCharacters(in: .whitespaces)
    for pattern in ["^(Edit|Mix|Transport|MIDI Editor)\\s*:\\s*", "\\s*[-–]\\s*(Edit|Mix)$", "\\.(ptx|ptf)$"] {
        t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return t.isEmpty ? nil : t
}

/// Which Pro Tools window a title belongs to: the Edit window counts as Editing, the Mix window as Mixing.
func windowActivity(_ title: String) -> String? {
    let t = title.trimmingCharacters(in: .whitespaces)
    if t.range(of: "^Edit\\s*:|[-–]\\s*Edit$", options: .regularExpression) != nil { return "Editing" }
    if t.range(of: "^Mix\\s*:|[-–]\\s*Mix$", options: .regularExpression) != nil { return "Mixing" }
    return nil
}

/// Why "Launch at Login" won't survive from where the app is running, or nil if the location is fine.
/// An app opened straight from Downloads or a disk image is run by macOS from a temporary copy that is gone
/// by the next login, so the login item would point at nothing.
func launchAtLoginProblem(appPath: String) -> String? {
    let temporary = appPath.contains("/AppTranslocation/") || appPath.hasPrefix("/Volumes/") || appPath.contains("/Downloads/")
    return temporary ? "The app is running from Downloads or a disk image, so it won't be found at your next login. "
        + "Move “Pro Tools Time Tracker” to your Applications folder, open it from there, then turn Launch at Login on." : nil
}

/// "Plug-in: FabFilter Pro-C 2" -> "FabFilter Pro-C 2". Pro Tools titles an open plug-in window this way,
/// and it is the front window while you work in the plug-in. Anything else (the Edit window, the
/// "Search Inserts" picker, a "DEMO MODE" nag) is nil, and so is a plug-in window with no name.
func pluginName(fromWindowTitle title: String) -> String? {
    let t = title.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("Plug-in:") else { return nil }
    let name = t.dropFirst("Plug-in:".count).trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}

/// The window's document as Pro Tools reports it ("file:///Users/me/My%20Song/My%20Song.ptx")
/// -> a plain path ("/Users/me/My Song/My Song.ptx").
func pathFromDocumentValue(_ s: String) -> String? {
    if s.hasPrefix("file:") { return URL(string: s)?.path }
    return s.hasPrefix("/") ? s : nil
}

/// Which project and folder an open session belongs to, from the session file's own path, so
/// nobody has to link folders by hand. Every .ptx in one folder (e.g. "Save As" versions) is the
/// same project, named after the folder. A .ptx with no "Audio Files" folder beside it isn't in a
/// normal session folder, so it's just its own project, with no folder to watch.
func sessionIdentity(documentPath: String, hasAudioFolder: (String) -> Bool) -> (project: String, folder: String?) {
    let file = URL(fileURLWithPath: documentPath)
    let folder = file.deletingLastPathComponent().path
    if hasAudioFolder(folder) { return (URL(fileURLWithPath: folder).lastPathComponent, folder) }
    return (file.deletingPathExtension().lastPathComponent, nil)
}

/// True only for the real Pro Tools app. Matching on the name prefix alone also matched this
/// tracker ("Pro Tools Time Tracker") and WebKit's "Pro Tools Networking" helper, so whenever
/// the tracker had launched before Pro Tools it picked itself, read no window, and stayed
/// stuck on the previous session until it was relaunched.
func isProToolsProcess(name: String?, bundleID: String?, isRegular: Bool) -> Bool {
    guard isRegular else { return false }   // helpers and menu-bar apps (like this one) aren't regular apps
    return (bundleID ?? "").hasPrefix("com.avid.ProTools") || name == "Pro Tools"
}

/// True only for a title that actually looks like a session document window (Edit/Mix/
/// Transport/MIDI Editor, or a bare .ptx/.ptf title) — never an alert, dialog, or file
/// browser ("Missing AAX Plugins", "Open", "Save", …), which must never become a project name.
func looksLikeSessionWindow(_ title: String) -> Bool {
    let t = title.trimmingCharacters(in: .whitespaces)
    if windowActivity(t) != nil { return true }
    return t.range(of: "^(Transport|MIDI Editor)\\s*:|\\.(ptx|ptf)$", options: .regularExpression) != nil
}

/// One report row. `type` is "Activity" (worked time) or "Break" (idle time), so adding up the hours of the
/// Activity rows gives the worked time exactly. `plugin` says which plug-in's window was in front for that
/// slice of the activity, and is blank for time spent in no plug-in.
func csvRow(project: String?, date: String, type: String, activity: String, plugin: String, seconds: Int) -> String {
    func field(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
    }
    let p = project.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"," } ?? ""
    return "\(p)\(date),\(type),\(field(activity)),\(field(plugin)),\(String(format: "%.2f", Double(seconds) / 3600))\n"
}

/// One project's rows, day by day. `label` is the project column value, or nil to omit it.
/// `breaks` is day -> idle seconds. `plugins` is day -> activity -> plug-in -> seconds, a split of that
/// activity's own time, so it never adds anything on top.
func csvRows(log: [String: Int], acts: [String: [String: Int]], label: String?,
             breaks: [String: Int] = [:], plugins: [String: [String: [String: Int]]] = [:]) -> String {
    var out = ""
    for day in Set(log.keys).union(breaks.keys).sorted() {
        let by = acts[day] ?? [:]
        for (a, s) in by.sorted(by: { $0.key < $1.key }) {
            let split = (plugins[day]?[a] ?? [:]).filter { $0.value > 0 }.sorted { $0.key < $1.key }
            for (plugin, secs) in split { out += csvRow(project: label, date: day, type: "Activity", activity: a, plugin: plugin, seconds: secs) }
            let rest = s - split.reduce(0) { $0 + $1.value }
            if rest > 0 { out += csvRow(project: label, date: day, type: "Activity", activity: a, plugin: "", seconds: rest) }
        }
        let untagged = (log[day] ?? 0) - by.values.reduce(0, +)
        if untagged > 0 { out += csvRow(project: label, date: day, type: "Activity", activity: "Untagged", plugin: "", seconds: untagged) }
        if let b = breaks[day], b > 0 { out += csvRow(project: label, date: day, type: breakLabel, activity: "", plugin: "", seconds: b) }
    }
    return out
}

/// Every project, one CSV, for exporting wherever you like.
func buildFullCSV(log: [String: [String: Int]], acts: [String: [String: [String: Int]]],
                  breaks: [String: [String: Int]] = [:],
                  plugins: [String: [String: [String: [String: Int]]]] = [:]) -> String {
    var csv = "project,date,type,activity,plugin,hours\n"
    for p in Set(log.keys).union(breaks.keys).sorted() {
        csv += csvRows(log: log[p] ?? [:], acts: acts[p] ?? [:], label: p, breaks: breaks[p] ?? [:], plugins: plugins[p] ?? [:])
    }
    return csv
}

/// One project only, no project column — meant to live inside that project's own session folder.
/// TOTAL is worked time: the sum of the Activity rows. Break rows are not part of it.
func buildProjectCSV(project: String, log: [String: [String: Int]], acts: [String: [String: [String: Int]]],
                     breaks: [String: [String: Int]] = [:],
                     plugins: [String: [String: [String: [String: Int]]]] = [:]) -> String {
    let total = (log[project] ?? [:]).values.reduce(0, +)
    var csv = "date,type,activity,plugin,hours\n" + csvRows(log: log[project] ?? [:], acts: acts[project] ?? [:], label: nil,
                                                           breaks: breaks[project] ?? [:], plugins: plugins[project] ?? [:])
    csv += "TOTAL,Activity,,,\(String(format: "%.2f", Double(total) / 3600))\n"
    return csv
}

/// Bytes of audio per second of real time, read from a WAV file's header (sample rate x channels x
/// bytes per sample), e.g. 144000 for mono 48 kHz 24-bit. nil if it isn't a WAV or the header is unreadable.
func wavByteRate(_ header: Data) -> Int? {
    let b = [UInt8](header)
    func tag(_ at: Int) -> String { String(decoding: b[at..<at + 4], as: UTF8.self) }
    func le32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
    func le16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
    guard b.count >= 12, ["RIFF", "RF64", "BW64"].contains(tag(0)), tag(8) == "WAVE" else { return nil }
    var i = 12
    while i + 8 <= b.count {
        let size = le32(i + 4)
        if tag(i) == "fmt " {
            guard i + 8 + 16 <= b.count else { return nil }
            let (channels, rate, bits) = (le16(i + 10), le32(i + 12), le16(i + 22))
            return channels > 0 && rate > 0 && bits > 0 ? rate * channels * ((bits + 7) / 8) : nil
        }
        i += 8 + size + (size & 1)
    }
    return nil
}

/// Watches a session's "Audio Files" folder. A file that keeps growing across consecutive checks, at about
/// the speed of real time, means audio is being recorded. Imports, consolidating clips and AudioSuite
/// renders also write into that folder, but many times faster than real time, so they don't count.
final class RecordingWatcher {
    private struct Snap {
        var size: Int
        var streak: Int          // consecutive checks in which the file grew
        var at: Date             // when this was measured
        var runStart: Date       // where the current run of growth began...
        var runStartSize: Int    // ...and how big the file was then
    }

    /// A recording writes between this and that many times real time (buffered writes make a single
    /// interval uneven, so it is measured over the whole run of growth).
    static let realtimeRange = 0.3...3.0

    // Keyed by folder first, so checking one linked project's folder never wipes
    // out another linked project's in-progress growth streak (each call used to
    // replace one shared dictionary, discarding every other folder's state).
    private var snapshots: [String: [String: Snap]] = [:]
    private var scanned = Set<String>()
    private var byteRates: [String: Int?] = [:]     // per file; nil = couldn't be read, so growth alone decides

    private func byteRate(of url: URL) -> Int? {
        if let known = byteRates[url.path] { return known }
        let rate = (try? FileHandle(forReadingFrom: url)).flatMap { h -> Int? in
            defer { try? h.close() }
            return (try? h.read(upToCount: 4096)).flatMap(wavByteRate)
        }
        byteRates[url.path] = .some(rate)
        return rate
    }

    func check(folder: String, now: Date = Date()) -> Bool {
        let dir = URL(fileURLWithPath: folder).appendingPathComponent("Audio Files")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return false }
        let firstScan = !scanned.contains(folder)
        scanned.insert(folder)

        let previous = snapshots[folder] ?? [:]
        var next: [String: Snap] = [:]
        var recording = false
        for case let url as URL in files {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize else { continue }
            var snap = Snap(size: size, streak: 0, at: now, runStart: now, runStartSize: size)
            if let prev = previous[url.path] {
                if size > prev.size {
                    snap.streak = prev.streak + 1
                    (snap.runStart, snap.runStartSize) = prev.streak > 0 ? (prev.runStart, prev.runStartSize) : (prev.at, prev.size)
                }
            } else if !firstScan, let m = v.contentModificationDate, now.timeIntervalSince(m) < poll * 2 {
                snap.streak = 1   // a brand-new file that is being written right now
                (snap.runStart, snap.runStartSize) = (v.creationDate ?? now.addingTimeInterval(-poll), 0)
            }
            next[url.path] = snap
            guard snap.streak >= 2 else { continue }
            if let expected = byteRate(of: url) {
                let seconds = max(now.timeIntervalSince(snap.runStart), 1)
                let speed = Double(snap.size - snap.runStartSize) / seconds / Double(expected)   // 1.0 = real time
                if RecordingWatcher.realtimeRange.contains(speed) { recording = true }
            } else {
                recording = true   // not a WAV we can read: growth alone is all there is to go on
            }
        }
        snapshots[folder] = next
        return recording
    }
}

import Foundation

let poll: TimeInterval = 10
let idleLimit: TimeInterval = 10 * 60

let activities = ["Recording", "Editing", "Mixing", "Mastering", "Other"]
let unspecified = "Unspecified"

func fmt(_ s: Int) -> String { String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }

/// The menu bar title: "⏱ 15. REDENCION 6 · 0h 31m" if that fits in `maxWidth`, else the same with the
/// name cut short, else just "⏱ 0h 31m", else just "⏱". macOS silently hides a menu bar item that
/// doesn't fit beside the notch, so the title has to be sized to the room it really has.
func fitTitle(icon: String, name: String?, time: String?, maxWidth: CGFloat, measure: (String) -> CGFloat) -> String {
    guard let name, let time else { return icon }
    func make(_ n: String) -> String { "\(icon) \(n) · \(time)" }
    if measure(make(name)) <= maxWidth { return make(name) }
    var n = name
    while n.count > 3 {
        n = String(n.dropLast())
        let candidate = make(n.trimmingCharacters(in: .whitespaces) + "…")
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

func csvRow(project: String?, date: String, activity: String, seconds: Int) -> String {
    let p = project.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"," } ?? ""
    return "\(p)\(date),\(activity),\(String(format: "%.2f", Double(seconds) / 3600))\n"
}

/// One project's date/activity rows. `label` is the project column value, or nil to omit it.
func csvRows(log: [String: Int], acts: [String: [String: Int]], label: String?) -> String {
    var out = ""
    for (day, secs) in log.sorted(by: { $0.key < $1.key }) {
        let by = acts[day] ?? [:]
        for (a, s) in by.sorted(by: { $0.key < $1.key }) { out += csvRow(project: label, date: day, activity: a, seconds: s) }
        let rest = secs - by.values.reduce(0, +)
        if rest > 0 { out += csvRow(project: label, date: day, activity: "Untagged", seconds: rest) }
    }
    return out
}

/// Every project, one CSV, for exporting wherever you like.
func buildFullCSV(log: [String: [String: Int]], acts: [String: [String: [String: Int]]]) -> String {
    var csv = "project,date,activity,hours\n"
    for p in log.keys.sorted() { csv += csvRows(log: log[p] ?? [:], acts: acts[p] ?? [:], label: p) }
    return csv
}

/// One project only, no project column — meant to live inside that project's own session folder.
func buildProjectCSV(project: String, log: [String: [String: Int]], acts: [String: [String: [String: Int]]]) -> String {
    let total = (log[project] ?? [:]).values.reduce(0, +)
    var csv = "date,activity,hours\n" + csvRows(log: log[project] ?? [:], acts: acts[project] ?? [:], label: nil)
    csv += "TOTAL,,\(String(format: "%.2f", Double(total) / 3600))\n"
    return csv
}

/// Watches a session's "Audio Files" folder. A file that keeps growing across
/// consecutive checks means audio is being recorded (a quick import stops growing sooner).
final class RecordingWatcher {
    // Keyed by folder first, so checking one linked project's folder never wipes
    // out another linked project's in-progress growth streak (each call used to
    // replace one shared dictionary, discarding every other folder's state).
    private var snapshots: [String: [String: (size: Int, streak: Int)]] = [:]
    private var scanned = Set<String>()

    func check(folder: String, now: Date = Date()) -> Bool {
        let dir = URL(fileURLWithPath: folder).appendingPathComponent("Audio Files")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return false }
        let firstScan = !scanned.contains(folder)
        scanned.insert(folder)

        let previous = snapshots[folder] ?? [:]
        var next: [String: (size: Int, streak: Int)] = [:]
        var recording = false
        for case let url as URL in files {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize else { continue }
            var streak = 0
            if let prev = previous[url.path] {
                streak = size > prev.size ? prev.streak + 1 : 0
            } else if !firstScan, let m = v.contentModificationDate, now.timeIntervalSince(m) < poll * 2 {
                streak = 1   // a brand-new file that is being written right now
            }
            next[url.path] = (size, streak)
            if streak >= 2 { recording = true }
        }
        snapshots[folder] = next
        return recording
    }
}

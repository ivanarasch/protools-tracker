// Tests for TimeTracker/Logic.swift. Run with ./test.sh
import Foundation

var failures = 0
var count = 0

func check<T: Equatable>(_ got: T, _ want: T, _ label: String, line: Int = #line) {
    count += 1
    if got != want {
        failures += 1
        print("FAIL (line \(line)) \(label): got \(got), want \(want)")
    }
}

// fmt
check(fmt(0), "0h 00m", "fmt zero")
check(fmt(3600 + 31 * 60), "1h 31m", "fmt hours and minutes")
check(fmt(59), "0h 00m", "fmt drops seconds")

// sessionName
check(sessionName("Edit: My Song"), "My Song", "sessionName Edit prefix")
check(sessionName("Mix: My Song"), "My Song", "sessionName Mix prefix")
check(sessionName("My Song.ptx - Edit"), "My Song", "sessionName suffix and extension")
check(sessionName("   "), nil, "sessionName blank")

// windowActivity
check(windowActivity("Edit: Song"), "Editing", "Edit window")
check(windowActivity("Song - Mix"), "Mixing", "Mix window")
check(windowActivity("Missing AAX Plugins"), nil, "alert is not an activity")

// looksLikeSessionWindow
check(looksLikeSessionWindow("Edit: Song"), true, "Edit window is a session")
check(looksLikeSessionWindow("MIDI Editor: Song"), true, "MIDI Editor is a session")
check(looksLikeSessionWindow("Song.ptx"), true, "bare .ptx title is a session")
check(looksLikeSessionWindow("Open"), false, "Open dialog is not a session")
check(looksLikeSessionWindow("Missing AAX Plugins"), false, "alert is not a session")

// isProToolsProcess
check(isProToolsProcess(name: "Pro Tools", bundleID: "com.avid.ProTools", isRegular: true), true, "real Pro Tools")
check(isProToolsProcess(name: "Pro Tools Time Tracker", bundleID: "com.ivanarasch.protools-time-tracker", isRegular: false),
      false, "the tracker itself")
check(isProToolsProcess(name: "Pro Tools Networking", bundleID: "com.apple.WebKit.Networking", isRegular: true),
      false, "WebKit helper")

// pathFromDocumentValue
check(pathFromDocumentValue("file:///Users/me/My%20Song/My%20Song.ptx"), "/Users/me/My Song/My Song.ptx", "file URL")
check(pathFromDocumentValue("/Users/me/a.ptx"), "/Users/me/a.ptx", "plain path")
check(pathFromDocumentValue("not a path"), nil, "garbage")

// sessionIdentity
let inFolder = sessionIdentity(documentPath: "/s/My Song/My Song v2.ptx", hasAudioFolder: { _ in true })
check(inFolder.project, "My Song", "project named after session folder")
check(inFolder.folder, "/s/My Song", "folder kept when it has Audio Files")
let loose = sessionIdentity(documentPath: "/s/Loose.ptx", hasAudioFolder: { _ in false })
check(loose.project, "Loose", "loose .ptx is its own project")
check(loose.folder, nil, "loose .ptx has no folder")

// fitTitle (measure = character count, so widths are easy to reason about)
let measure: (String) -> CGFloat = { CGFloat($0.count) }
check(fitTitle(icon: "⏱", name: "Song", time: "0h 31m", maxWidth: 100, measure: measure), "⏱ Song · 0h 31m", "fits")
check(fitTitle(icon: "⏱", name: "A Very Long Song Name", time: "0h 31m", maxWidth: 20, measure: measure).hasSuffix("… · 0h 31m"),
      true, "long name gets cut")
check(fitTitle(icon: "⏱", name: "A Very Long Song Name", time: "0h 31m", maxWidth: 9, measure: measure), "⏱ 0h 31m", "time only")
check(fitTitle(icon: "⏱", name: "Song", time: "0h 31m", maxWidth: 2, measure: measure), "⏱", "icon only")
check(fitTitle(icon: "⏱", name: nil, time: nil, maxWidth: 100, measure: measure), "⏱", "nothing tracked")

// CSV export
check(csvRow(project: "Say \"Hi\"", date: "2026-01-01", type: "Activity", activity: "Mixing", plugin: "", seconds: 5400),
      "\"Say \"\"Hi\"\"\",2026-01-01,Activity,Mixing,,1.50\n", "quotes are escaped")
check(csvRow(project: nil, date: "2026-01-01", type: "Activity", activity: "Mixing", plugin: "Fab, Filter \"X\"", seconds: 3600),
      "2026-01-01,Activity,Mixing,\"Fab, Filter \"\"X\"\"\",1.00\n", "commas and quotes in a plug-in name are escaped")
let log = ["Song": ["2026-01-01": 7200]]
let acts = ["Song": ["2026-01-01": ["Mixing": 3600]]]
check(buildProjectCSV(project: "Song", log: log, acts: acts),
      "date,type,activity,plugin,hours\n2026-01-01,Activity,Mixing,,1.00\n2026-01-01,Activity,Untagged,,1.00\nTOTAL,Activity,,,2.00\n",
      "untagged time fills the rest of the day")
check(buildFullCSV(log: log, acts: acts).hasPrefix("project,date,type,activity,plugin,hours\n\"Song\",2026-01-01,Activity,Mixing,,1.00\n"),
      true, "full CSV has project column")

// groupProjects: the menu shows the most recent few, the rest go under "Older Projects"
let days = ["Old": "2026-09-30", "Mid": "2026-10-02", "New": "2026-10-12", "Newest": "2026-11-02"]
let hours = ["Old": 100, "Mid": 5000, "New": 200, "Newest": 50]
let groups = groupProjects(lastDay: days, total: hours, current: nil, limit: 2)
check(groups.recent, ["Newest", "New"], "most recently worked come first")
check(groups.older, ["Mid", "Old"], "the rest are older, still most recent first")
check(groupProjects(lastDay: days, total: hours, current: "Old", limit: 2).recent, ["Old", "Newest"],
      "the open project jumps to the top")
check(groupProjects(lastDay: ["A": "2026-10-01", "B": "2026-10-01"], total: ["A": 10, "B": 99], current: nil, limit: 5).recent,
      ["B", "A"], "same day: more hours first")
check(groupProjects(lastDay: days, total: hours, current: nil, limit: 10).older, [], "few projects: nothing is tucked away")
check(groupProjects(lastDay: [:], total: [:], current: nil, limit: 6).recent, [], "no projects")

// Break time: idle time is reported on its own row and never counted in TOTAL
let withBreak = buildProjectCSV(project: "Song", log: log, acts: acts, breaks: ["Song": ["2026-01-01": 1800]])
check(withBreak, "date,type,activity,plugin,hours\n2026-01-01,Activity,Mixing,,1.00\n2026-01-01,Activity,Untagged,,1.00\n2026-01-01,Break,,,0.50\nTOTAL,Activity,,,2.00\n",
      "break row is listed but not in the total")
check(buildProjectCSV(project: "Song", log: log, acts: acts, breaks: [:]), buildProjectCSV(project: "Song", log: log, acts: acts),
      "no breaks: report unchanged")
check(buildFullCSV(log: log, acts: acts, breaks: ["Song": ["2026-01-02": 600]]).hasSuffix("\"Song\",2026-01-02,Break,,,0.17\n"),
      true, "a break on a day with no work still shows")
check(buildFullCSV(log: [:], acts: [:], breaks: ["Idle": ["2026-01-01": 3600]]),
      "project,date,type,activity,plugin,hours\n\"Idle\",2026-01-01,Break,,,1.00\n", "break-only project is exported")
check(idleLimit, 300, "idle limit is five minutes")

// Plug-in windows, using titles seen on a real Pro Tools 2026 session
check(pluginName(fromWindowTitle: "Plug-in: FabFilter Pro-C 2"), "FabFilter Pro-C 2", "plug-in window names the plug-in")
check(pluginName(fromWindowTitle: "Plug-in: CLA-2A"), "CLA-2A", "short plug-in name")
check(pluginName(fromWindowTitle: "Plug-in: Abbey Road TG Mastering"), "Abbey Road TG Mastering", "name with spaces")
check(pluginName(fromWindowTitle: "Edit: 11. La Mujer Sin Corazon ORG"), nil, "Edit window is not a plug-in")
check(pluginName(fromWindowTitle: "Search Inserts, fab f, You are currently on a text field. To enter this field, type."), nil,
      "insert picker is not a plug-in")
check(pluginName(fromWindowTitle: "DEMO MODE"), nil, "demo-mode dialog is not a plug-in")
check(pluginName(fromWindowTitle: "Plug-in:   "), nil, "plug-in window with no name")
check(pluginName(fromWindowTitle: ""), nil, "untitled window")

// Plug-in is a column on the Activity rows: a split of that activity's time, never extra time on top
let plugs = ["Song": ["2026-01-01": ["Mixing": ["Pro-C 2": 1800, "CLA-2A": 600]]]]
let splitCSV = buildProjectCSV(project: "Song", log: log, acts: acts, plugins: plugs)
check(splitCSV,
      "date,type,activity,plugin,hours\n2026-01-01,Activity,Mixing,CLA-2A,0.17\n2026-01-01,Activity,Mixing,Pro-C 2,0.50\n"
      + "2026-01-01,Activity,Mixing,,0.33\n2026-01-01,Activity,Untagged,,1.00\nTOTAL,Activity,,,2.00\n",
      "plug-in time splits its activity, with the rest of the activity on a blank-plug-in row")
let summed = splitCSV.split(separator: "\n").dropFirst().filter { $0.hasPrefix("2026") }
    .compactMap { Double($0.split(separator: ",", omittingEmptySubsequences: false).last ?? "") }.reduce(0, +)
check(abs(summed - 2.0) < 0.02, true, "the Activity rows add up to the TOTAL, so nothing is counted twice")
check(buildFullCSV(log: log, acts: acts, plugins: plugs).contains("\"Song\",2026-01-01,Activity,Mixing,Pro-C 2,0.50\n"),
      true, "all-projects CSV has the plug-in column too")
check(buildProjectCSV(project: "Song", log: log, acts: acts, breaks: ["Song": ["2026-01-01": 1800]], plugins: plugs)
        .hasSuffix("2026-01-01,Break,,,0.50\nTOTAL,Activity,,,2.00\n"), true, "break row follows the activity rows")
check(buildProjectCSV(project: "Nope", log: log, acts: acts, plugins: plugs), "date,type,activity,plugin,hours\nTOTAL,Activity,,,0.00\n",
      "project with nothing logged")

// wavByteRate: the real-time data rate in a WAV header (values match files from a real Pro Tools session)
func wavHeader(rate: Int, channels: Int, bits: Int) -> Data {
    func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    let bytes: [UInt8] = Array("RIFF".utf8) + le(36, 4) + Array("WAVE".utf8) + Array("fmt ".utf8) + le(16, 4)
        + le(1, 2) + le(channels, 2) + le(rate, 4) + le(rate * channels * bits / 8, 4) + le(channels * bits / 8, 2) + le(bits, 2)
        + Array("data".utf8) + le(0, 4)
    return Data(bytes)
}
check(wavByteRate(wavHeader(rate: 48000, channels: 1, bits: 24)), 144000, "mono 48k 24-bit is 144000 bytes/s")
check(wavByteRate(wavHeader(rate: 96000, channels: 2, bits: 32)), 768000, "stereo 96k 32-bit")
check(wavByteRate(Data("not a wav file at all".utf8)), nil, "garbage is not a WAV")
check(wavByteRate(Data()), nil, "empty file")

// RecordingWatcher: only growth at about real-time speed is recording. Files are written at 8000 bytes/s
// of audio, and "time" is advanced by hand, 10 seconds per check, like the real poll.
func watch(header: Data?, grow: [Int]) -> [Bool] {
    let folder = NSTemporaryDirectory() + "pttest-\(UUID().uuidString)"
    let audio = folder + "/Audio Files"
    try? FileManager.default.createDirectory(atPath: audio, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let file = URL(fileURLWithPath: audio + "/Take_01.wav")
    let watcher = RecordingWatcher()
    let t0 = Date()
    var results = [watcher.check(folder: folder, now: t0)]       // first scan: the folder is empty
    var data = header ?? Data()
    for (i, bytes) in grow.enumerated() {
        data.append(Data(count: bytes))
        try? data.write(to: file)
        results.append(watcher.check(folder: folder, now: t0.addingTimeInterval(Double(i + 1) * poll)))
    }
    return Array(results.dropFirst())
}
let slow8k = wavHeader(rate: 8000, channels: 1, bits: 8)
check(watch(header: slow8k, grow: [80_000, 80_000, 80_000]), [false, true, true],
      "a take growing at real-time speed is recording, once it has grown twice")
check(watch(header: slow8k, grow: [2_000_000, 2_000_000, 2_000_000]), [false, false, false],
      "a render or import writing 25x real time is not recording")
check(watch(header: slow8k, grow: [5_000_000, 0, 0]), [false, false, false], "an import that finishes straight away is not recording")
check(watch(header: slow8k, grow: [8_000, 8_000, 8_000]), [false, false, false], "a trickle far below real time is not recording")
check(watch(header: nil, grow: [100, 100, 100]), [false, true, true], "unreadable header: growth alone decides, as before")

print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)

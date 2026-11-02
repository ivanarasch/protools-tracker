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
check(csvRow(project: "Say \"Hi\"", date: "2026-01-01", activity: "Mixing", seconds: 5400),
      "\"Say \"\"Hi\"\"\",2026-01-01,Mixing,1.50\n", "quotes are escaped")
let log = ["Song": ["2026-01-01": 7200]]
let acts = ["Song": ["2026-01-01": ["Mixing": 3600]]]
check(buildProjectCSV(project: "Song", log: log, acts: acts),
      "date,activity,hours\n2026-01-01,Mixing,1.00\n2026-01-01,Untagged,1.00\nTOTAL,,2.00\n",
      "untagged time fills the rest of the day")
check(buildFullCSV(log: log, acts: acts).hasPrefix("project,date,activity,hours\n\"Song\",2026-01-01,Mixing,1.00\n"),
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

print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)

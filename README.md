# Pro Tools Time Tracker

[![CI](https://github.com/ivanarasch/protools-tracker/actions/workflows/ci.yml/badge.svg)](https://github.com/ivanarasch/protools-tracker/actions/workflows/ci.yml)

A macOS menu bar app that automatically tracks how much time you spend in each Pro Tools session, and what you were doing: recording, editing, or mixing.

No timers to start or stop: open a session and it starts counting.

## Download

Get the latest `Pro Tools Time Tracker.zip` from [**Releases**](https://github.com/ivanarasch/protools-tracker/releases/latest), unzip it, and move the app to Applications.

Requires macOS 13 or later. Runs on both Apple Silicon and Intel Macs.

**First launch:** the app isn't notarized by Apple, so macOS will block it the first time. Right-click the app and choose **Open**, or go to **System Settings → Privacy & Security** and click **Open Anyway**. Then allow **Accessibility** access when asked, so the app can read Pro Tools window titles.

## What it does

- **Tracks time per session automatically.** Time counts only while Pro Tools is in front and you've used the keyboard or mouse in the last 5 minutes. After that, the idle time is logged as **Break** in the reports instead (not counted in a project's total). Recording is never treated as a break.
- **Finds the project on its own.** It reads the open `.ptx` file's location, so all versions in one session folder ("Save As" copies) count toward the same project.
- **Tags activity.** Time in the Edit window counts as Editing, the Mix window as Mixing, and it detects Recording by watching for audio files that keep growing. You can also set the activity by hand (Recording, Editing, Mixing, Mastering, Other).
- **Tracks which plug-ins you work in.** Time with a plug-in's window in front is logged per plug-in, per project.
- **Exports hours to CSV**, either one file for all projects or a `<project> - Pro Tools Hours.csv` kept up to date inside each session folder. Each row is either `Activity` (worked time, with a `plugin` column naming the plug-in that was in front, blank if none) or `Break` (idle time). The `Activity` hours add up to the `TOTAL` row exactly, because a plug-in only splits the activity it happened in.
- **Fits the menu bar.** The title shortens itself so macOS doesn't hide it behind the notch.
- **Keeps the menu short.** The project you're in comes first, then the most recently worked on. Only the 6 most recent are listed; the rest go under **Older Projects**.
- Optional **Launch at Login**.

Data is stored in `~/Library/Application Support/ProToolsTimeTracker/`.

## Build from source

```bash
./build.sh   # builds a universal (arm64 + x86_64) app into build/
./test.sh    # runs the Swift logic tests and the pytest suite
```

## Project layout

| Path | What's in it |
| --- | --- |
| `TimeTracker/main.swift` | Menu bar UI, Accessibility window reading, storage |
| `TimeTracker/Logic.swift` | Pure logic: session names, activity detection, recording detection, CSV export |
| `Tests/main.swift` | Tests for `Logic.swift` |
| `pttrack.py` | Earlier command-line version of the tracker, in Python |
| `Tests/test_pttrack.py` | pytest tests for `pttrack.py` |
| `.github/workflows/ci.yml` | CI/CD pipeline |

## CI/CD

Every time code is pushed, GitHub Actions automatically:

1. Runs all the tests (Swift and Python) to catch anything that broke
2. Builds the app
3. Saves the built app so it can be downloaded

When a new version is tagged (for example `v1.9`), it also publishes the app on the [Releases](https://github.com/ivanarasch/protools-tracker/releases) page.

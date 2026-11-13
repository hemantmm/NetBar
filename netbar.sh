#!/bin/bash
# NetBar: a lightweight macOS menu bar monitor for network speed and usage.
# Run with: ./netbar.sh

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "NetBar requires macOS (it uses the native menu bar)." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "NetBar needs the Swift runtime included with macOS/Xcode Command Line Tools." >&2
  exit 1
fi

swift_dir="$(mktemp -d "${TMPDIR:-/tmp}/netbar.XXXXXX")"
swift_file="$swift_dir/netbar.swift"
trap 'rm -f "$swift_file"; rmdir "$swift_dir"' EXIT
cat > "$swift_file" <<'SWIFT'
import AppKit
import Foundation

struct SavedUsage: Codable {
    var interface: String
    var rx: UInt64
    var tx: UInt64
    var days: [String: UInt64]
}

struct SavedAppUsage: Codable {
    var days: [String: [String: UInt64]] = [:]
}

let calendar = Calendar(identifier: .gregorian)
let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = calendar
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()
let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NetBar/usage.json")
let appStateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/NetBar/app-usage-v3.json")

func run(_ command: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: command)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } catch { return "" }
}

func networkCounters() -> (String, UInt64, UInt64)? {
    // On macOS route lives in /sbin, while netstat is in /usr/sbin.
    let route = run("/sbin/route", ["-n", "get", "default"])
    guard let line = route.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }) else { return nil }
    let iface = line.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    guard !iface.isEmpty else { return nil }
    let stats = run("/usr/sbin/netstat", ["-ibn"])
    for row in stats.split(separator: "\n") {
        let fields = row.split(whereSeparator: \.isWhitespace).map(String.init)
        // The link-layer row has stable byte-counter columns: Ibytes=6 and Obytes=9.
        guard fields.count >= 10, fields[0] == iface, fields[2].hasPrefix("<Link#"),
              let rx = UInt64(fields[6]), let tx = UInt64(fields[9]) else { continue }
        return (iface, rx, tx)
    }
    return nil
}

func human(_ bytes: Double, perSecond: Bool = false) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var n = max(0, bytes)
    var i = 0
    while n >= 1000 && i < units.count - 1 { n /= 1000; i += 1 }
    let number = n < 10 ? String(format: "%.1f", n) : String(format: "%.0f", n)
    return number + " " + units[i] + (perSecond ? "/s" : "")
}

func loadState() -> SavedUsage? {
    guard let data = try? Data(contentsOf: stateURL) else { return nil }
    return try? JSONDecoder().decode(SavedUsage.self, from: data)
}

func saveState(_ state: SavedUsage) {
    do {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
    } catch { }
}

func loadAppUsage() -> SavedAppUsage {
    guard let data = try? Data(contentsOf: appStateURL),
          let state = try? JSONDecoder().decode(SavedAppUsage.self, from: data) else {
        return SavedAppUsage()
    }
    return state
}

func saveAppUsage(_ state: SavedAppUsage) {
    do {
        try FileManager.default.createDirectory(at: appStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: appStateURL, options: .atomic)
    } catch { }
}

func csvFields(_ line: String) -> [String] {
    var fields: [String] = []
    var field = ""
    var quoted = false
    let chars = Array(line)
    var index = 0
    while index < chars.count {
        let char = chars[index]
        if char == "\"" {
            if quoted && index + 1 < chars.count && chars[index + 1] == "\"" {
                field.append("\"")
                index += 1
            } else {
                quoted.toggle()
            }
        } else if char == "," && !quoted {
            fields.append(field)
            field = ""
        } else {
            field.append(char)
        }
        index += 1
    }
    fields.append(field)
    return fields
}

func nettopSnapshot() -> [String: UInt64]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    // The first sample is the baseline; the second reports only the interval delta.
    process.arguments = ["-P", "-L", "2", "-d", "-s", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerIndex = lines.lastIndex(where: { $0.contains("bytes_in") && $0.contains("bytes_out") }) else { return nil }
        let header = csvFields(lines[headerIndex])
        guard let inIndex = header.firstIndex(of: "bytes_in"),
              let outIndex = header.firstIndex(of: "bytes_out") else { return nil }
        let processIndex = 0
        var totals: [String: UInt64] = [:]
        for line in lines.dropFirst(headerIndex + 1) {
            let row = csvFields(line)
            guard row.count > max(processIndex, max(inIndex, outIndex)),
                  let incoming = UInt64(row[inIndex].trimmingCharacters(in: .whitespaces)),
                  let outgoing = UInt64(row[outIndex].trimmingCharacters(in: .whitespaces)) else { continue }
            let rawName = row[processIndex].trimmingCharacters(in: .whitespaces)
            guard let pidSuffix = rawName.range(of: "\\.\\d+$", options: .regularExpression) else { continue }
            var name = String(rawName[..<pidSuffix.lowerBound]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("com.apple.WebKit") {
                name = "WebKit helper (Safari and other apps)"
            }
            guard !name.isEmpty else { continue }
            totals[name, default: 0] += incoming + outgoing
        }
        return totals
    } catch { return nil }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let menu = NSMenu()
var menuIsOpen = false
var todayExpanded = false
var weekExpanded = false
final class MenuTrackingDelegate: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        rebuildAppUsageMenus(for: dateFormatter.string(from: Date()))
    }
}
final class MenuActions: NSObject {
    @objc func toggleToday(_ sender: NSMenuItem) { todayExpanded.toggle() }
    @objc func toggleWeek(_ sender: NSMenuItem) { weekExpanded.toggle() }
}
let menuTrackingDelegate = MenuTrackingDelegate()
let menuActions = MenuActions()
menu.delegate = menuTrackingDelegate
let todayItem = NSMenuItem(title: "Today: measuring…", action: nil, keyEquivalent: "")
todayItem.target = menuActions
todayItem.action = #selector(MenuActions.toggleToday(_:))
let weekItem = NSMenuItem(title: "Last 7 days: measuring…", action: nil, keyEquivalent: "")
weekItem.target = menuActions
weekItem.action = #selector(MenuActions.toggleWeek(_:))
let quitItem = NSMenuItem(title: "Quit NetBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
status.menu = menu

var saved = loadState()
var previousTime = Date()
var previousRxSpeed: Double = 0
var previousTxSpeed: Double = 0
var appUsage = loadAppUsage()
var appSampleInFlight = false
var appUsageUnavailable = false

func appendAppUsageRows(_ apps: [String: UInt64], title: String) {
    let section = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    section.isEnabled = false
    menu.addItem(section)
    let total = apps.values.reduce(UInt64(0), +)
    let totalItem = NSMenuItem(title: "All recorded apps: \(human(Double(total)))", action: nil, keyEquivalent: "")
    totalItem.isEnabled = false
    menu.addItem(totalItem)
    let sortedApps = apps.sorted { $0.value > $1.value }
    if sortedApps.isEmpty {
        let message = appUsageUnavailable ? "Per-app data unavailable" : "Collecting app usage…"
        let empty = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        empty.isEnabled = false
        menu.addItem(empty)
        return
    }
    for (name, bytes) in sortedApps {
        let item = NSMenuItem(title: "\(name): \(human(Double(bytes)))", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
}

func rebuildAppUsageMenus(for today: String) {
    guard !menuIsOpen else { return }
    let todayApps = appUsage.days[today, default: [:]]

    let cutoff = dateFormatter.string(from: calendar.date(byAdding: .day, value: -6, to: Date()) ?? Date())
    var weekApps: [String: UInt64] = [:]
    for (day, apps) in appUsage.days where day >= cutoff && day <= today {
        for (name, bytes) in apps { weekApps[name, default: 0] += bytes }
    }

    menu.removeAllItems()
    todayItem.title = "Today: \(human(Double(saved?.days[today, default: 0] ?? 0))) \(todayExpanded ? "⌄" : "›")"
    menu.addItem(todayItem)
    if todayExpanded {
        appendAppUsageRows(todayApps, title: "Today's app usage · cumulative")
    }
    menu.addItem(NSMenuItem.separator())
    let deviceWeek = saved?.days.filter { $0.key >= cutoff }.values.reduce(UInt64(0), +) ?? 0
    weekItem.title = "Last 7 days: \(human(Double(deviceWeek))) \(weekExpanded ? "⌄" : "›")"
    menu.addItem(weekItem)
    if weekExpanded {
        appendAppUsageRows(weekApps, title: "Last 7 days by app · cumulative")
    }
    menu.addItem(NSMenuItem.separator())
    menu.addItem(quitItem)
}

func samplePerAppUsage() {
    guard !appSampleInFlight else { return }
    appSampleInFlight = true
    DispatchQueue.global(qos: .utility).async {
        let sample = nettopSnapshot()
        DispatchQueue.main.async {
            let today = dateFormatter.string(from: Date())
            guard let current = sample else {
                appUsageUnavailable = true
                rebuildAppUsageMenus(for: today)
                appSampleInFlight = false
                return
            }
            appUsageUnavailable = false
            for (name, delta) in current {
                if delta > 0 {
                    appUsage.days[today, default: [:]][name, default: 0] += delta
                }
            }
            appUsage.days = appUsage.days.filter { $0.key >= dateFormatter.string(from: calendar.date(byAdding: .day, value: -6, to: Date()) ?? Date()) }
            saveAppUsage(appUsage)
            rebuildAppUsageMenus(for: today)
            appSampleInFlight = false
        }
    }
}

func refresh() {
    let now = Date()
    let today = dateFormatter.string(from: now)
    samplePerAppUsage()
    rebuildAppUsageMenus(for: today)
    guard let (iface, rx, tx) = networkCounters() else {
        status.button?.title = "⇅ —"
        todayItem.title = "Today: waiting for network…"
        weekItem.title = "Last 7 days: —"
        return
    }

    if saved == nil || saved!.interface != iface {
        saved = SavedUsage(interface: iface, rx: rx, tx: tx, days: saved?.days ?? [:])
    } else if let old = saved {
        if rx >= old.rx { saved!.days[today, default: 0] += rx - old.rx }
        if tx >= old.tx { saved!.days[today, default: 0] += tx - old.tx }
    }
    saved!.interface = iface
    saved!.rx = rx
    saved!.tx = tx

    let elapsed = max(0.2, now.timeIntervalSince(previousTime))
    if previousTime != now {
        if let old = loadState(), old.interface == iface {
            // Speed is measured from the previous sample; usage totals are counter-based.
            previousRxSpeed = rx >= old.rx ? Double(rx - old.rx) / elapsed : 0
            previousTxSpeed = tx >= old.tx ? Double(tx - old.tx) / elapsed : 0
        }
    }
    previousTime = now

    let cutoff = calendar.date(byAdding: .day, value: -6, to: now) ?? now
    let cutoffKey = dateFormatter.string(from: cutoff)
    saved!.days = saved!.days.filter { $0.key >= cutoffKey }
    let week = saved!.days.values.reduce(UInt64(0), +)
    let day = saved!.days[today, default: 0]
    saveState(saved!)

    status.button?.title = "↓ \(human(previousRxSpeed, perSecond: true))  ↑ \(human(previousTxSpeed, perSecond: true))"
    todayItem.title = "Today: \(human(Double(day))) \(todayExpanded ? "⌄" : "›")"
    weekItem.title = "Last 7 days: \(human(Double(week))) \(weekExpanded ? "⌄" : "›")"
}

refresh()
let refreshTimer = Timer(timeInterval: 1, repeats: true) { _ in refresh() }
RunLoop.main.add(refreshTimer, forMode: .common)
app.run()
SWIFT
swift "$swift_file"

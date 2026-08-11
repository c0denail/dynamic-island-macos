import AppKit
import ApplicationServices
import Combine
import SQLite3

struct ClockActivityReadout: Equatable, Sendable {
    let timer: ClockTimerSnapshot?
    let stopwatch: ClockStopwatchSnapshot?
}

enum ClockActivitySnapshotReader {
    static let integrationTitle = "Dynamic Island"
    private static let preferencesDomain = "com.apple.mobiletimerd" as CFString

    static func read(now: Date = Date()) -> ClockActivityReadout {
        let liveTimerValue = CFPreferencesCopyAppValue("MTTimers" as CFString, preferencesDomain)
        let liveStopwatchValue = CFPreferencesCopyAppValue("MTStopwatches" as CFString, preferencesDomain)
        if liveTimerValue != nil || liveStopwatchValue != nil {
            var liveRoot: [String: Any] = [:]
            if let liveTimerValue { liveRoot["MTTimers"] = liveTimerValue }
            if let liveStopwatchValue { liveRoot["MTStopwatches"] = liveStopwatchValue }
            let live = decode(root: liveRoot, now: now)

            // A present CFPreferences container with no active entry means the
            // activity was stopped. Never revive it from a stale disk/SQLite
            // snapshot; use those sources only when the live key is unavailable.
            guard liveTimerValue == nil || liveStopwatchValue == nil else { return live }
            let disk = readDiskPreferences(now: now)
            let timer = liveTimerValue != nil ? live.timer : (disk.timer ?? readLegacyTimer(now: now))
            let stopwatch = liveStopwatchValue != nil ? live.stopwatch : disk.stopwatch
            return ClockActivityReadout(timer: timer, stopwatch: stopwatch)
        }

        let disk = readDiskPreferences(now: now)
        guard disk.timer == nil else { return disk }
        return ClockActivityReadout(timer: readLegacyTimer(now: now), stopwatch: disk.stopwatch)
    }

    private static func readDiskPreferences(now: Date) -> ClockActivityReadout {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.mobiletimerd.plist")
        return (try? Data(contentsOf: url)).map { decode(data: $0, now: now) }
            ?? ClockActivityReadout(timer: nil, stopwatch: nil)
    }

    static func decode(data: Data, now: Date = Date()) -> ClockActivityReadout {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return ClockActivityReadout(timer: nil, stopwatch: nil)
        }

        return decode(root: root, now: now)
    }

    private static func decode(root: [String: Any], now: Date) -> ClockActivityReadout {
        let timer = decodeTimers(root["MTTimers"], now: now)
        let stopwatch = decodeStopwatch(root["MTStopwatches"], now: now)
        return ClockActivityReadout(timer: timer, stopwatch: stopwatch)
    }

    private static func decodeTimers(_ value: Any?, now: Date) -> ClockTimerSnapshot? {
        guard let container = value as? [String: Any],
              let entries = container["MTTimers"] as? [[String: Any]]
        else { return nil }

        let timers = entries.compactMap { entry -> ClockTimerSnapshot? in
            guard let raw = entry["$MTTimer"] as? [String: Any],
                  let identifier = raw["MTTimerID"] as? String,
                  let duration = number(raw["MTTimerDuration"]),
                  let rawState = integer(raw["MTTimerState"])
            else { return nil }

            let state: ClockActivityState
            switch rawState {
            case 2: state = .paused
            case 3: state = .running
            default: state = .stopped
            }
            guard state != .stopped else { return nil }

            let fireTime = raw["MTTimerFireTime"] as? [String: Any]
            let fireDate = ((fireTime?["$MTTimerDate"] as? [String: Any])?["MTTimerTimeDate"] as? Date)
            let storedRemaining = number((fireTime?["$MTTimerTimeInterval"] as? [String: Any])?["MTTimerTimeInterval"])
            let remaining: TimeInterval
            if state == .paused {
                remaining = storedRemaining
                    ?? fireDate.map { max(0, $0.timeIntervalSince(now)) }
                    ?? duration
            } else {
                remaining = fireDate.map { max(0, $0.timeIntervalSince(now)) }
                    ?? storedRemaining
                    ?? duration
            }
            let rawTitle = (raw["MTTimerTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty || rawTitle == "CURRENT_TIMER" ? "macOS Saat Sayacı" : rawTitle

            return ClockTimerSnapshot(
                identifier: identifier,
                duration: duration,
                title: title,
                state: state,
                fireDate: fireDate,
                remainingAtSnapshot: remaining,
                capturedAt: now
            )
        }

        return timers.sorted { lhs, rhs in
            let lhsOwned = lhs.title == integrationTitle
            let rhsOwned = rhs.title == integrationTitle
            if lhsOwned != rhsOwned { return lhsOwned }
            if lhs.state != rhs.state { return lhs.state == .running }
            return lhs.remaining < rhs.remaining
        }.first
    }

    private static func decodeStopwatch(_ value: Any?, now: Date) -> ClockStopwatchSnapshot? {
        guard let container = value as? [String: Any],
              let entries = container["MTStopwatches"] as? [[String: Any]]
        else { return nil }

        return entries.compactMap { entry -> ClockStopwatchSnapshot? in
            guard let raw = entry["$MTStopwatch"] as? [String: Any],
                  let identifier = raw["MTStopwatchIdentifier"] as? String,
                  let rawState = integer(raw["MTStopwatchState"])
            else { return nil }

            let state: ClockActivityState
            switch rawState {
            case 1: state = .paused
            case 2: state = .running
            default: state = .stopped
            }
            let currentInterval = number(raw["MTStopwatchCurrentInterval"]) ?? 0
            let offset = number(raw["MTStopwatchOffset"]) ?? 0
            let startDate = raw["MTStopwatchStartDate"] as? Date
            let liveInterval = state == .running ? startDate.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0
            // MobileTimer keeps the total accumulated stopwatch value in offset.
            // currentInterval mirrors the current lap while paused, so summing both
            // would double the displayed time when there are no laps.
            let accumulated = offset > 0 ? offset : currentInterval
            let baseElapsed = max(0, accumulated + liveInterval)
            guard state != .stopped || baseElapsed > 0 else { return nil }

            return ClockStopwatchSnapshot(
                identifier: identifier,
                state: state,
                baseElapsed: baseElapsed,
                startDate: startDate,
                capturedAt: now
            )
        }.first
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func readLegacyTimer(now: Date) -> ClockTimerSnapshot? {
        let databasePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.mobiletimerd/local.sqlite")
            .path
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database
        else { return nil }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT ZDURATION, ZFIREDDATE, ZTITLE, ZTIMERURL
        FROM ZMTCDTIMER
        WHERE ZFIREDDATE IS NOT NULL
        ORDER BY ZFIREDDATE ASC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let duration = sqlite3_column_double(statement, 0)
        let fireDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
        guard duration > 0, fireDate.timeIntervalSince(now) > -3 else { return nil }
        let rawTitle = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let timerURL = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "legacy-clock-timer"
        let title = rawTitle.isEmpty || rawTitle == "CURRENT_TIMER" ? "macOS Saat Sayacı" : rawTitle

        return ClockTimerSnapshot(
            identifier: timerURL,
            duration: duration,
            title: title,
            state: .running,
            fireDate: fireDate,
            remainingAtSnapshot: max(0, fireDate.timeIntervalSince(now)),
            capturedAt: now
        )
    }
}

private enum ClockAutomationAction: Sendable {
    case startTimer(TimeInterval)
    case pauseTimer(identifier: String, title: String)
    case resumeTimer(identifier: String, title: String)
    case cancelTimer(identifier: String, title: String)
    case startStopwatch
    case pauseStopwatch(identifier: String)
    case resumeStopwatch(identifier: String)
    case resetStopwatch(identifier: String)
}

private enum ClockAutomationResult: Sendable {
    case success
    case failure(String)
}

private enum ClockTab: Int, Sendable {
    case stopwatch = 2
    case timer = 3
}

private enum ClockAutomationBridge {
    private static let clockBundleIdentifier = "com.apple.clock"

    static func perform(_ action: ClockAutomationAction) -> ClockAutomationResult {
        guard AXIsProcessTrusted() else {
            return .failure("Clock denetimi için Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik izni gerekli.")
        }
        guard let application = ensureClockRunning() else {
            return .failure("macOS Saat uygulaması başlatılamadı.")
        }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        let wasHidden = booleanAttribute(root, kAXHiddenAttribute) ?? application.isHidden
        // Clock is launched with `open -j`, and macOS can report AXPress success
        // without dispatching the control action while its window is hidden.
        // Temporarily exposing it to Accessibility (without activating it) makes
        // the controls responsive. Restore the previous hidden state afterwards.
        _ = setHidden(false, on: root)
        Thread.sleep(forTimeInterval: 0.18)
        defer {
            if wasHidden {
                _ = setHidden(true, on: root)
                _ = waitUntil(timeout: 1.2, interval: 0.05) {
                    booleanAttribute(root, kAXHiddenAttribute) == true
                }
            }
        }

        var lastFailure = "Saat komutu çalıştırılamadı."
        for attempt in 0..<2 {
            if attempt > 0, expectedStateReached(for: action) { return .success }

            let result = performOnce(action, in: root)
            if case .failure(let message) = result { lastFailure = message }
            if case .success = result, waitForExpectedState(after: action) { return .success }

            // Re-prime the hidden/background Clock window and acquire fresh AX
            // elements before the single retry.
            _ = setHidden(false, on: root)
            Thread.sleep(forTimeInterval: 0.22)
        }

        if expectedStateReached(for: action) { return .success }
        return .failure("\(lastFailure) macOS Saat durumu değişmedi; işlemi yeniden deneyin.")
    }

    private static func performOnce(_ action: ClockAutomationAction, in root: AXUIElement) -> ClockAutomationResult {
        switch action {
        case .startTimer(let duration):
            guard select(.timer, in: root), prepareTimerEditor(in: root) else {
                return .failure("Saat uygulamasındaki sayaç düzenleyicisi bulunamadı.")
            }
            return configureAndStartTimer(duration: duration, in: root)

        case let .pauseTimer(_, title), let .resumeTimer(_, title):
            guard select(.timer, in: root),
                  let button = waitForElement({ timerButton(identifier: "PauseResumeButton", preferredTitle: title, in: root) })
            else { return .failure("Saat sayacının duraklat/devam düğmesi bulunamadı.") }
            return press(button)

        case let .cancelTimer(_, title):
            guard select(.timer, in: root),
                  let button = waitForElement({ timerButton(identifier: "CancelButton", preferredTitle: title, in: root) })
            else { return .failure("Saat sayacının iptal düğmesi bulunamadı.") }
            return press(button)

        case .startStopwatch, .pauseStopwatch, .resumeStopwatch:
            guard select(.stopwatch, in: root),
                  let button = waitForElement({ firstElement(in: root, identifier: "StartStopButton") })
            else { return .failure("Saat kronometresinin başlat/durdur düğmesi bulunamadı.") }
            return press(button)

        case .resetStopwatch:
            guard select(.stopwatch, in: root) else {
                return .failure("Saat kronometresi açılamadı.")
            }
            if ClockActivitySnapshotReader.read().stopwatch?.state == .running,
               let stop = waitForElement({ firstElement(in: root, identifier: "StartStopButton") }) {
                guard case .success = press(stop) else {
                    return .failure("Saat kronometresi durdurulamadı.")
                }
                guard waitForStopwatchState(.paused) else {
                    return .failure("Saat kronometresinin durması doğrulanamadı.")
                }
                guard select(.stopwatch, in: root) else {
                    return .failure("Saat kronometresi sıfırlamaya hazırlanamadı.")
                }
            }
            guard let reset = waitForElement({ firstElement(in: root, identifier: "LapResetButton") }) else {
                return .failure("Saat kronometresinin sıfırla düğmesi bulunamadı.")
            }
            return press(reset)
        }
    }

    private static func expectedStateReached(for action: ClockAutomationAction) -> Bool {
        let readout = ClockActivitySnapshotReader.read()
        switch action {
        case .startTimer:
            return readout.timer?.state == .running
                && readout.timer?.title == ClockActivitySnapshotReader.integrationTitle
        case let .pauseTimer(identifier, _):
            return readout.timer?.identifier == identifier && readout.timer?.state == .paused
        case let .resumeTimer(identifier, _):
            return readout.timer?.identifier == identifier && readout.timer?.state == .running
        case let .cancelTimer(identifier, _):
            return readout.timer?.identifier != identifier
        case .startStopwatch:
            return readout.stopwatch?.state == .running
        case let .pauseStopwatch(identifier):
            return readout.stopwatch?.identifier == identifier && readout.stopwatch?.state == .paused
        case let .resumeStopwatch(identifier):
            return readout.stopwatch?.identifier == identifier && readout.stopwatch?.state == .running
        case let .resetStopwatch(identifier):
            return readout.stopwatch?.identifier != identifier
        }
    }

    private static func waitForExpectedState(after action: ClockAutomationAction, timeout: TimeInterval = 2.4) -> Bool {
        waitUntil(timeout: timeout) { expectedStateReached(for: action) }
    }

    private static func waitForStopwatchState(_ state: ClockActivityState, timeout: TimeInterval = 2.4) -> Bool {
        waitUntil(timeout: timeout) {
            ClockActivitySnapshotReader.read().stopwatch?.state == state
        }
    }

    private static func ensureClockRunning() -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: clockBundleIdentifier).first,
           !windows(of: AXUIElementCreateApplication(running.processIdentifier)).isEmpty {
            return running
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-b", clockBundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        for _ in 0..<50 {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: clockBundleIdentifier).first,
               !windows(of: AXUIElementCreateApplication(running.processIdentifier)).isEmpty {
                return running
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
        return nil
    }

    private static func select(_ tab: ClockTab, in root: AXUIElement) -> Bool {
        let radioButtons = elements(in: root, role: kAXRadioButtonRole)
        let semanticNames: [String]
        switch tab {
        case .stopwatch: semanticNames = ["kronometre", "stopwatch"]
        case .timer: semanticNames = ["sayaçlar", "sayaç", "timers", "timer"]
        }

        let semanticMatch = radioButtons.first { button in
            let label = [
                stringAttribute(button, kAXDescriptionAttribute),
                stringAttribute(button, kAXTitleAttribute),
                stringAttribute(button, kAXHelpAttribute)
            ].joined(separator: " ").lowercased()
            return semanticNames.contains { label == $0 || label.contains($0) }
        }
        let indexedMatch = radioButtons.indices.contains(tab.rawValue) ? radioButtons[tab.rawValue] : nil
        guard let button = semanticMatch ?? indexedMatch,
              performAXPress(button) == .success
        else { return false }

        // Press even when AXValue was already selected. Clock's hidden window
        // otherwise accepts later AXPress calls without applying their action.
        guard waitUntil(timeout: 1.2, interval: 0.06, condition: {
            numberAttribute(button, kAXValueAttribute) == 1
        }) else { return false }
        Thread.sleep(forTimeInterval: 0.32)
        return true
    }

    private static func prepareTimerEditor(in root: AXUIElement) -> Bool {
        if elements(in: root, role: kAXSliderRole).count >= 3 { return true }

        let addButton = elements(in: root, role: kAXMenuButtonRole).first {
            !stringAttribute($0, kAXDescriptionAttribute).isEmpty
        }
        guard let addButton,
              AXUIElementPerformAction(addButton, cf(kAXPressAction)) == .success
        else { return false }

        for _ in 0..<30 {
            if elements(in: root, role: kAXSliderRole).count >= 3 { return true }
            Thread.sleep(forTimeInterval: 0.06)
        }
        return false
    }

    private static func configureAndStartTimer(duration: TimeInterval, in root: AXUIElement) -> ClockAutomationResult {
        let total = min(86_399, max(1, Int(duration.rounded())))
        let targets = [total / 3_600, (total % 3_600) / 60, total % 60]
        let sliders = Array(elements(in: root, role: kAXSliderRole).prefix(3))
        guard sliders.count == 3 else { return .failure("Saat sayaç süresi alanları bulunamadı.") }

        for (slider, target) in zip(sliders, targets) {
            guard adjust(slider: slider, to: target) else {
                return .failure("Saat sayaç süresi ayarlanamadı.")
            }
        }

        if let titleField = elements(in: root, role: kAXTextFieldRole).first {
            _ = AXUIElementSetAttributeValue(titleField, cf(kAXValueAttribute), ClockActivitySnapshotReader.integrationTitle as CFString)
        }

        guard let start = firstElement(in: root, identifier: "PauseResumeButton") else {
            return .failure("Saat sayacının Başlat düğmesi bulunamadı.")
        }
        return press(start)
    }

    private static func adjust(slider: AXUIElement, to target: Int) -> Bool {
        _ = AXUIElementPerformAction(slider, cf(kAXPressAction))
        Thread.sleep(forTimeInterval: 0.08)
        let current = leadingInteger(stringAttribute(slider, kAXValueAttribute))
        let delta = target - current
        let action = delta >= 0 ? kAXIncrementAction : kAXDecrementAction

        for _ in 0..<abs(delta) {
            guard AXUIElementPerformAction(slider, cf(action)) == .success else { return false }
            Thread.sleep(forTimeInterval: 0.055)
        }
        Thread.sleep(forTimeInterval: 0.08)
        return leadingInteger(stringAttribute(slider, kAXValueAttribute)) == target
    }

    private static func timerButton(identifier: String, preferredTitle: String, in root: AXUIElement) -> AXUIElement? {
        let groups = elements(in: root, role: kAXGroupRole)
        let titles = [preferredTitle, ClockActivitySnapshotReader.integrationTitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "macOS Saat Sayacı" }

        for title in titles {
            let matchingCards = groups.compactMap { group -> (AXUIElement, Int)? in
                guard subtreeContains(group, text: title),
                      let button = firstElement(in: group, identifier: identifier)
                else { return nil }
                return (button, descendantCount(of: group))
            }
            if let best = matchingCards.min(by: { $0.1 < $1.1 }) { return best.0 }
        }
        return firstElement(in: root, identifier: identifier)
    }

    private static func press(_ element: AXUIElement) -> ClockAutomationResult {
        let error = performAXPress(element)
        return error == .success
            ? .success
            : .failure("Saat denetimi çalıştırılamadı (AX hata \(error.rawValue)).")
    }

    private static func performAXPress(_ element: AXUIElement) -> AXError {
        var result: AXError = .cannotComplete
        for _ in 0..<3 {
            result = AXUIElementPerformAction(element, cf(kAXPressAction))
            if result == .success { return result }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return result
    }

    private static func waitForElement(
        _ finder: () -> AXUIElement?,
        timeout: TimeInterval = 1.8
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = finder(), booleanAttribute(element, kAXEnabledAttribute) != false {
                return element
            }
            Thread.sleep(forTimeInterval: 0.06)
        } while Date() < deadline
        return nil
    }

    private static func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.08,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline
        return condition()
    }

    private static func setHidden(_ hidden: Bool, on root: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(root, cf(kAXHiddenAttribute), NSNumber(value: hidden)) == .success
    }

    private static func subtreeContains(_ root: AXUIElement, text: String) -> Bool {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if stringAttribute(root, attribute).localizedCaseInsensitiveContains(text) { return true }
        }
        return children(of: root).contains { subtreeContains($0, text: text) }
    }

    private static func descendantCount(of root: AXUIElement) -> Int {
        let descendants = children(of: root)
        return descendants.reduce(descendants.count) { $0 + descendantCount(of: $1) }
    }

    private static func firstElement(in root: AXUIElement, identifier: String) -> AXUIElement? {
        if stringAttribute(root, "AXIdentifier") == identifier { return root }
        for child in children(of: root) {
            if let match = firstElement(in: child, identifier: identifier) { return match }
        }
        return nil
    }

    private static func elements(in root: AXUIElement, role: String) -> [AXUIElement] {
        var result: [AXUIElement] = []
        collect(root, role: role, into: &result)
        return result
    }

    private static func collect(_ root: AXUIElement, role: String, into result: inout [AXUIElement]) {
        if stringAttribute(root, kAXRoleAttribute) == role { result.append(root) }
        for child in children(of: root) { collect(child, role: role, into: &result) }
    }

    private static func windows(of root: AXUIElement) -> [AXUIElement] {
        arrayAttribute(root, kAXWindowsAttribute)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        arrayAttribute(element, kAXChildrenAttribute)
    }

    private static func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, cf(attribute), &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, cf(attribute), &value) == .success,
              let value
        else { return "" }
        return value as? String ?? String(describing: value)
    }

    private static func numberAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, cf(attribute), &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func booleanAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, cf(attribute), &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func leadingInteger(_ value: String) -> Int {
        Int(value.split(whereSeparator: { !$0.isNumber }).first ?? "0") ?? 0
    }

    private static func cf(_ value: String) -> CFString {
        unsafeBitCast(value as NSString, to: CFString.self)
    }
}

@MainActor
final class ClockTimerService: ObservableObject {
    @Published private(set) var current: ClockTimerSnapshot?
    @Published private(set) var stopwatch: ClockStopwatchSnapshot?
    @Published private(set) var activeMode: TimerMode?
    @Published private(set) var hasActiveActivity = false
    @Published private(set) var isPerformingAction = false
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    @Published var lastError: String?

    private var poller: AnyCancellable?
    private var refreshInFlight = false

    func start() {
        refresh()
        poller = Timer.publish(every: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func toggle(mode: TimerMode, duration: TimeInterval) {
        guard ensureAccessibilityAccess() else { return }
        let action: ClockAutomationAction
        switch mode {
        case .countdown:
            switch current?.state {
            case .running:
                guard let current else { return }
                action = .pauseTimer(identifier: current.identifier, title: current.title)
            case .paused:
                guard let current else { return }
                action = .resumeTimer(identifier: current.identifier, title: current.title)
            case .stopped, nil: action = .startTimer(duration)
            }
        case .stopwatch:
            switch stopwatch?.state {
            case .running:
                guard let stopwatch else { return }
                action = .pauseStopwatch(identifier: stopwatch.identifier)
            case .paused:
                guard let stopwatch else { return }
                action = .resumeStopwatch(identifier: stopwatch.identifier)
            case .stopped, nil: action = .startStopwatch
            }
        }
        run(action, preferredMode: mode)
    }

    func reset(mode: TimerMode) {
        guard ensureAccessibilityAccess() else { return }
        switch mode {
        case .countdown:
            guard let current else { return }
            run(.cancelTimer(identifier: current.identifier, title: current.title), preferredMode: mode)
        case .stopwatch:
            guard let stopwatch else { return }
            run(.resetStopwatch(identifier: stopwatch.identifier), preferredMode: mode)
        }
    }

    func requestAccessibilityAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        if !isAccessibilityTrusted { openAccessibilitySettings() }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func openClock(mode: TimerMode) {
        let scheme = mode == .stopwatch ? "clock-stopwatch:" : "clock-timer:"
        guard let url = URL(string: scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    func displayedTime(for mode: TimerMode, fallbackDuration: TimeInterval) -> TimeInterval {
        switch mode {
        case .countdown: current?.remaining ?? fallbackDuration
        case .stopwatch: stopwatch?.elapsed ?? 0
        }
    }

    func progress(for mode: TimerMode) -> Double? {
        switch mode {
        case .countdown: current?.progress ?? 0
        case .stopwatch: nil
        }
    }

    func state(for mode: TimerMode) -> ClockActivityState {
        switch mode {
        case .countdown: current?.state ?? .stopped
        case .stopwatch: stopwatch?.state ?? .stopped
        }
    }

    func isActive(_ mode: TimerMode) -> Bool {
        switch mode {
        case .countdown: current != nil
        case .stopwatch: stopwatch != nil
        }
    }

    func presentationMode(preferred: TimerMode) -> TimerMode {
        if isActive(preferred) { return preferred }
        if current != nil { return .countdown }
        if stopwatch != nil { return .stopwatch }
        return preferred
    }

    private func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task { [weak self] in
            let readout = await Task.detached(priority: .utility) {
                ClockActivitySnapshotReader.read()
            }.value
            guard let self else { return }
            self.refreshInFlight = false
            self.apply(readout)
        }
    }

    private func apply(_ readout: ClockActivityReadout) {
        let previousTimerActive = current != nil
        let previousStopwatchActive = stopwatch != nil
        current = readout.timer
        stopwatch = readout.stopwatch
        hasActiveActivity = current != nil || stopwatch != nil

        if !previousTimerActive, current != nil {
            activeMode = .countdown
        } else if !previousStopwatchActive, stopwatch != nil {
            activeMode = .stopwatch
        } else if activeMode == .countdown, current == nil, stopwatch != nil {
            activeMode = .stopwatch
        } else if activeMode == .stopwatch, stopwatch == nil, current != nil {
            activeMode = .countdown
        } else if !hasActiveActivity {
            activeMode = nil
        }
    }

    private func run(_ action: ClockAutomationAction, preferredMode: TimerMode) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        lastError = nil
        activeMode = preferredMode

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ClockAutomationBridge.perform(action)
            }.value
            guard let self else { return }
            self.isPerformingAction = false
            if case .failure(let message) = result { self.lastError = message }
            self.refresh()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                self?.refresh()
            }
        }
    }

    private func ensureAccessibilityAccess() -> Bool {
        isAccessibilityTrusted = AXIsProcessTrusted()
        guard isAccessibilityTrusted else {
            lastError = "macOS Saat denetimi için Erişilebilirlik iznini yenileyin ve Dynamic Island’ı yeniden açın."
            requestAccessibilityAccess()
            return false
        }
        return true
    }
}

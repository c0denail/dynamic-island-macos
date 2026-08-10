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

    static func read(now: Date = Date()) -> ClockActivityReadout {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.mobiletimerd.plist")
        let decoded = (try? Data(contentsOf: url)).map { decode(data: $0, now: now) }
            ?? ClockActivityReadout(timer: nil, stopwatch: nil)
        guard decoded.timer == nil else { return decoded }
        return ClockActivityReadout(timer: readLegacyTimer(now: now), stopwatch: decoded.stopwatch)
    }

    static func decode(data: Data, now: Date = Date()) -> ClockActivityReadout {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return ClockActivityReadout(timer: nil, stopwatch: nil)
        }

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
            let remaining = fireDate.map { max(0, $0.timeIntervalSince(now)) }
                ?? storedRemaining
                ?? duration
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
    case pauseTimer
    case resumeTimer
    case cancelTimer
    case startStopwatch
    case pauseStopwatch
    case resumeStopwatch
    case resetStopwatch(wasRunning: Bool)
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
        switch action {
        case .startTimer(let duration):
            guard select(.timer, in: root), prepareTimerEditor(in: root) else {
                return .failure("Saat uygulamasındaki sayaç düzenleyicisi bulunamadı.")
            }
            return configureAndStartTimer(duration: duration, in: root)

        case .pauseTimer, .resumeTimer:
            guard select(.timer, in: root),
                  let button = timerButton(identifier: "PauseResumeButton", in: root)
            else { return .failure("Saat sayacının duraklat/devam düğmesi bulunamadı.") }
            return press(button)

        case .cancelTimer:
            guard select(.timer, in: root),
                  let button = timerButton(identifier: "CancelButton", in: root)
            else { return .failure("Saat sayacının iptal düğmesi bulunamadı.") }
            return press(button)

        case .startStopwatch, .pauseStopwatch, .resumeStopwatch:
            guard select(.stopwatch, in: root),
                  let button = firstElement(in: root, identifier: "StartStopButton")
            else { return .failure("Saat kronometresinin başlat/durdur düğmesi bulunamadı.") }
            return press(button)

        case .resetStopwatch(let wasRunning):
            guard select(.stopwatch, in: root) else {
                return .failure("Saat kronometresi açılamadı.")
            }
            if wasRunning, let stop = firstElement(in: root, identifier: "StartStopButton") {
                guard case .success = press(stop) else {
                    return .failure("Saat kronometresi durdurulamadı.")
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard let reset = firstElement(in: root, identifier: "LapResetButton") else {
                return .failure("Saat kronometresinin sıfırla düğmesi bulunamadı.")
            }
            return press(reset)
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
        guard radioButtons.indices.contains(tab.rawValue) else { return false }
        if numberAttribute(radioButtons[tab.rawValue], kAXValueAttribute) != 1 {
            guard AXUIElementPerformAction(radioButtons[tab.rawValue], cf(kAXPressAction)) == .success else { return false }
            Thread.sleep(forTimeInterval: 0.45)
        }
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

    private static func timerButton(identifier: String, in root: AXUIElement) -> AXUIElement? {
        let groups = elements(in: root, role: kAXGroupRole)
        for group in groups where subtreeContains(group, text: ClockActivitySnapshotReader.integrationTitle) {
            if let button = firstElement(in: group, identifier: identifier) { return button }
        }
        return firstElement(in: root, identifier: identifier)
    }

    private static func press(_ element: AXUIElement) -> ClockAutomationResult {
        AXUIElementPerformAction(element, cf(kAXPressAction)) == .success
            ? .success
            : .failure("Saat denetimi çalıştırılamadı.")
    }

    private static func subtreeContains(_ root: AXUIElement, text: String) -> Bool {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if stringAttribute(root, attribute).localizedCaseInsensitiveContains(text) { return true }
        }
        return children(of: root).contains { subtreeContains($0, text: text) }
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
        let action: ClockAutomationAction
        switch mode {
        case .countdown:
            switch current?.state {
            case .running: action = .pauseTimer
            case .paused: action = .resumeTimer
            case .stopped, nil: action = .startTimer(duration)
            }
        case .stopwatch:
            switch stopwatch?.state {
            case .running: action = .pauseStopwatch
            case .paused: action = .resumeStopwatch
            case .stopped, nil: action = .startStopwatch
            }
        }
        run(action, preferredMode: mode)
    }

    func reset(mode: TimerMode) {
        switch mode {
        case .countdown:
            guard current != nil else { return }
            run(.cancelTimer, preferredMode: mode)
        case .stopwatch:
            guard let stopwatch else { return }
            run(.resetStopwatch(wasRunning: stopwatch.state == .running), preferredMode: mode)
        }
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
}

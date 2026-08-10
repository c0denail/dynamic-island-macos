import AppKit
import Combine
import SQLite3

@MainActor
final class ClockTimerService: ObservableObject {
    @Published var current: ClockTimerSnapshot?

    private var poller: AnyCancellable?
    private let databasePath: String

    init() {
        databasePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.mobiletimerd/local.sqlite")
            .path
    }

    func start() {
        refresh()
        poller = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func openClock() {
        guard let timerURL = URL(string: "clock-timer:") else { return }
        NSWorkspace.shared.open(timerURL)
    }

    func refresh() {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database
        else {
            current = nil
            return
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT ZDURATION, ZFIREDDATE, ZTITLE
        FROM ZMTCDTIMER
        WHERE ZFIREDDATE IS NOT NULL
        ORDER BY ZFIREDDATE ASC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            current = nil
            return
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            current = nil
            return
        }

        let duration = sqlite3_column_double(statement, 0)
        let fireTimestamp = sqlite3_column_double(statement, 1)
        let rawTitle = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let fireDate = Date(timeIntervalSinceReferenceDate: fireTimestamp)

        // Clock fired durumunu kısa süre gösterebilir; eski kayıtları etkin sayma.
        guard duration > 0, fireDate.timeIntervalSinceNow > -3 else {
            current = nil
            return
        }

        let title = rawTitle.isEmpty || rawTitle == "CURRENT_TIMER" ? "Saat Timer'ı" : rawTitle
        current = ClockTimerSnapshot(duration: duration, fireDate: fireDate, title: title)
    }
}

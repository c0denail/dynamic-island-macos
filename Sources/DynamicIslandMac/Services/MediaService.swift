import AppKit
import Combine

@MainActor
final class MediaService: ObservableObject {
    @Published var title = "Bir şeyler çalın"
    @Published var artist = "Tarayıcı, Music veya Spotify"
    @Published var source = ""
    @Published var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var artworkURL: URL?
    @Published var artworkData: Data?

    private let systemBridge = SystemNowPlayingBridge.bundled()
    private var poller: AnyCancellable?
    private var lastPositionUpdate = Date()
    private var missedPolls = 0
    private var refreshInFlight = false

    var hasActiveSource: Bool { !source.isEmpty }
    var displayedElapsed: TimeInterval {
        let extrapolated = isPlaying ? elapsed + Date().timeIntervalSince(lastPositionUpdate) : elapsed
        return max(0, min(duration, extrapolated))
    }
    var remaining: TimeInterval { max(0, duration - displayedElapsed) }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displayedElapsed / duration))
    }

    func start() {
        refresh()
        poller = Timer.publish(every: 0.8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func playPause() {
        if sendSystemCommand("toggle") {
            isPlaying.toggle()
            lastPositionUpdate = Date()
        } else {
            runCommand("""
            tell application "System Events"
                if exists process "Spotify" then
                    tell application "Spotify" to playpause
                else
                    tell application "Music" to playpause
                end if
            end tell
            """)
            isPlaying.toggle()
        }
        delayedRefresh()
    }

    func next() {
        if !sendSystemCommand("next") {
            runSourceCommand(music: "next track", spotify: "next track")
        }
        delayedRefresh()
    }

    func previous() {
        if !sendSystemCommand("previous") {
            runSourceCommand(music: "previous track", spotify: "previous track")
        }
        delayedRefresh()
    }

    func seek(by seconds: Double) {
        guard duration > 0 else { return }
        seek(to: (displayedElapsed + max(-300, min(300, seconds))) / duration)
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let position = max(0, min(1, fraction)) * duration

        if let systemBridge {
            Task.detached { _ = systemBridge.send("seek", value: position) }
        } else {
            runCommand("""
            tell application "System Events"
                if exists process "Spotify" then
                    tell application "Spotify" to set player position to \(position)
                else if exists process "Music" then
                    tell application "Music" to set player position to \(position)
                end if
            end tell
            """)
        }
        elapsed = position
        lastPositionUpdate = Date()
        delayedRefresh()
    }

    func refresh() {
        guard let systemBridge else {
            refreshAppleScript()
            return
        }
        guard !refreshInFlight else { return }
        refreshInFlight = true

        Task { [weak self] in
            let snapshot = await Task.detached { systemBridge.snapshot() }.value
            guard let self else { return }
            self.refreshInFlight = false
            if let snapshot {
                self.apply(snapshot)
            } else {
                self.refreshAppleScript()
            }
        }
    }

    private func apply(_ snapshot: SystemNowPlayingSnapshot) {
        missedPolls = 0
        source = sourceName(for: snapshot.bundleIdentifier)
        title = snapshot.title ?? "Bilinmeyen medya"
        artist = snapshot.artist?.isEmpty == false ? snapshot.artist! : (snapshot.album ?? source)
        duration = max(0, snapshot.duration ?? 0)
        elapsed = max(0, min(duration, snapshot.elapsedTime ?? 0))
        isPlaying = snapshot.playing ?? ((snapshot.playbackRate ?? 0) > 0)
        lastPositionUpdate = Date()
        artworkURL = nil

        let decodedArtwork = snapshot.artworkData.flatMap { Data(base64Encoded: $0) }
        if artworkData != decodedArtwork {
            artworkData = decodedArtwork
        }
    }

    private func refreshAppleScript() {
        let script = """
        set outputText to ""
        tell application "System Events"
            if exists process "Spotify" then
                tell application "Spotify"
                    if player state is not stopped then
                        set artURL to ""
                        try
                            set artURL to artwork url of current track
                        end try
                        set outputText to "Spotify|||" & (player state as text) & "|||" & (name of current track) & "|||" & (artist of current track) & "|||" & ((duration of current track) / 1000) & "|||" & player position & "|||" & artURL
                    end if
                end tell
            else if exists process "Music" then
                tell application "Music"
                    if player state is not stopped then
                        set outputText to "Music|||" & (player state as text) & "|||" & (name of current track) & "|||" & (artist of current track) & "|||" & (duration of current track) & "|||" & player position & "|||"
                    end if
                end tell
            end if
        end tell
        return outputText
        """

        guard let output = execute(script), !output.isEmpty else {
            missedPolls += 1
            if missedPolls >= 2 { clearNowPlaying() }
            return
        }

        let fields = output.components(separatedBy: "|||")
        guard fields.count >= 6 else { return }
        missedPolls = 0
        source = fields[0]
        isPlaying = fields[1].lowercased().contains("playing")
        title = fields[2]
        artist = fields[3]
        duration = fields[4].islandLocalizedTimeInterval
        elapsed = fields[5].islandLocalizedTimeInterval
        lastPositionUpdate = Date()
        artworkData = nil
        artworkURL = fields.count > 6 ? URL(string: fields[6].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    private func clearNowPlaying() {
        isPlaying = false
        source = ""
        title = "Bir şeyler çalın"
        artist = "Tarayıcı, Music veya Spotify"
        elapsed = 0
        duration = 0
        artworkURL = nil
        artworkData = nil
    }

    private func sourceName(for bundleIdentifier: String?) -> String {
        switch bundleIdentifier {
        case "com.google.Chrome": "Chrome"
        case "com.apple.Safari": "Safari"
        case "company.thebrowser.Browser": "Arc"
        case "com.spotify.client": "Spotify"
        case "com.apple.Music": "Music"
        case let identifier?: identifier.split(separator: ".").last.map(String.init) ?? "Medya"
        case nil: "Medya"
        }
    }

    @discardableResult
    private func sendSystemCommand(_ command: String) -> Bool {
        guard let systemBridge, hasActiveSource else { return false }
        Task.detached { _ = systemBridge.send(command) }
        return true
    }

    private func runSourceCommand(music: String, spotify: String) {
        runCommand("""
        tell application "System Events"
            if exists process "Spotify" then
                tell application "Spotify" to \(spotify)
            else
                tell application "Music" to \(music)
            end if
        end tell
        """)
    }

    private func runCommand(_ source: String) {
        _ = execute(source)
    }

    private func execute(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }

    private func delayedRefresh() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.refresh()
        }
    }
}

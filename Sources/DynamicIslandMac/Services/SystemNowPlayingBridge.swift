import Foundation

struct SystemNowPlayingSnapshot: Decodable, Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let playbackRate: Double?
    let playing: Bool?
    let artworkData: String?
    let artworkMimeType: String?
    let bundleIdentifier: String?

    var hasContent: Bool {
        guard let title else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SystemNowPlayingBridge: Sendable {
    private let scriptURL: URL
    private let dylibURL: URL
    private let controlURL: URL

    static func bundled() -> SystemNowPlayingBridge? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let nowPlaying = resources.appendingPathComponent("NowPlaying", isDirectory: true)
        let script = nowPlaying.appendingPathComponent("mediaremote-mini.pl")
        let dylib = nowPlaying.appendingPathComponent("MediaRemoteMini.dylib")
        let control = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("NowPlayingControl")

        guard FileManager.default.isReadableFile(atPath: script.path),
              FileManager.default.isReadableFile(atPath: dylib.path),
              FileManager.default.isExecutableFile(atPath: control.path)
        else { return nil }

        return SystemNowPlayingBridge(scriptURL: script, dylibURL: dylib, controlURL: control)
    }

    func snapshot() -> SystemNowPlayingSnapshot? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, dylibURL.path, "adapter_get_env"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            let snapshot = try JSONDecoder().decode(SystemNowPlayingSnapshot.self, from: data)
            return snapshot.hasContent ? snapshot : nil
        } catch {
            return nil
        }
    }

    @discardableResult
    func send(_ command: String, value: Double? = nil) -> Bool {
        let process = Process()
        process.executableURL = controlURL
        process.arguments = value.map { [command, String($0)] } ?? [command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

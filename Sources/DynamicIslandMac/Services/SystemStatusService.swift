import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Darwin
import IOKit.ps
import Network

struct VolumeEvent: Equatable {
    let value: Float
    let isMuted: Bool
}

struct BrightnessEvent: Equatable {
    let value: Float
}

private enum LowPowerModeChangeResult: Sendable {
    case success
    case helperUnavailable(String)
    case failure(String)
}

@objc protocol DynamicIslandPowerHelperProtocol {
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

private final class LowPowerResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LowPowerModeChangeResult?

    func storeIfEmpty(_ newValue: LowPowerModeChangeResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return false }
        value = newValue
        return true
    }

    func load() -> LowPowerModeChangeResult? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class SystemStatusService: ObservableObject {
    @Published var batteryPercent = 100
    @Published var isCharging = false
    @Published var networkLabel = "Bağlanıyor"
    @Published var isOnline = true
    @Published var outputVolume: Float = 0.5
    @Published var isMuted = false
    @Published var volumeEvent: VolumeEvent?
    @Published var displayBrightness: Float = 0.5
    @Published var brightnessEvent: BrightnessEvent?
    @Published var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var isChangingLowPowerMode = false
    @Published var lowPowerModeError: String?

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "dev.dynamic-island.network")
    private var poller: AnyCancellable?
    private var volumePoller: AnyCancellable?
    private var lastObservedVolume: Float = -1
    private var lastObservedMute = false
    private var lastObservedBrightness: Float = -1
    private var observedOutputDevice: AudioDeviceID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private let brightnessBridge = DisplayBrightnessBridge()

    func start() {
        refresh()
        lastObservedVolume = outputVolume
        lastObservedMute = isMuted
        lastObservedBrightness = displayBrightness
        installAudioListeners()
        volumePoller = Timer.publish(every: 0.12, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollVolume()
                self?.pollBrightness()
            }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let label: String
            if !online {
                label = "Çevrimdışı"
            } else if path.usesInterfaceType(.wifi) {
                label = "Wi-Fi"
            } else if path.usesInterfaceType(.wiredEthernet) {
                label = "Ethernet"
            } else {
                label = "Bağlı"
            }
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.networkLabel != label { self.networkLabel = label }
            }
        }
        pathMonitor.start(queue: monitorQueue)

        poller = Timer.publish(every: 8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stop() {
        pathMonitor.cancel()
        poller?.cancel()
        poller = nil
        volumePoller?.cancel()
        volumePoller = nil
        removeAudioListeners()
    }

    func refresh() {
        refreshBattery()
        let newLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPowerModeEnabled != newLowPowerMode { lowPowerModeEnabled = newLowPowerMode }
        if let newVolume = readOutputVolume(), abs(outputVolume - newVolume) > 0.000_5 {
            outputVolume = newVolume
        }
        if let newMuted = readMute(), isMuted != newMuted { isMuted = newMuted }
        if let newBrightness = brightnessBridge.read(), abs(displayBrightness - newBrightness) > 0.000_5 {
            displayBrightness = newBrightness
        }
    }

    func setLowPowerModeEnabled(_ enabled: Bool) {
        guard !isChangingLowPowerMode else { return }
        isChangingLowPowerMode = true
        lowPowerModeError = nil

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.changeSystemLowPowerMode(enabled)
            }.value
            guard let self else { return }

            self.isChangingLowPowerMode = false
            switch result {
            case .success:
                // pmset changes the persistent AC and battery profiles. Keep the UI
                // responsive while ProcessInfo catches up on the following poll.
                self.lowPowerModeEnabled = enabled
            case .failure(let message):
                self.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.lowPowerModeError = message
            case .helperUnavailable(let message):
                self.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.lowPowerModeError = message
            }
        }
    }

    func setVolume(_ value: Float) {
        let newValue = max(0, min(1, value))
        guard let device = defaultOutputDevice() else { return }
        var didSetVolume = false
        for element in volumeElements(for: device) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var volume = newValue
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
            didSetVolume = didSetVolume || status == noErr
        }
        if didSetVolume { outputVolume = newValue }
    }

    func setDisplayBrightness(_ value: Float) {
        let newValue = max(0, min(1, value))
        guard brightnessBridge.write(newValue) else { return }
        displayBrightness = newValue
        lastObservedBrightness = newValue
        brightnessEvent = BrightnessEvent(value: newValue)
    }

    private func refreshBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
        batteryPercent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : 100
        let state = description[kIOPSPowerSourceStateKey] as? String
        isCharging = state == kIOPSACPowerValue
    }

    nonisolated private static func changeSystemLowPowerMode(_ enabled: Bool) -> LowPowerModeChangeResult {
        let firstAttempt = requestLowPowerModeChange(enabled)
        guard case .helperUnavailable = firstAttempt else { return firstAttempt }

        switch installPowerHelper() {
        case .success:
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.1)
                let result = requestLowPowerModeChange(enabled)
                if case .helperUnavailable = result { continue }
                return result
            }
            return .failure("Güç yardımcısı başlatılamadı. Mac’i yeniden başlatıp tekrar deneyin.")
        case .failure(let message), .helperUnavailable(let message):
            return .failure(message)
        }
    }

    nonisolated private static func requestLowPowerModeChange(_ enabled: Bool) -> LowPowerModeChangeResult {
        let semaphore = DispatchSemaphore(value: 0)
        let response = LowPowerResponseBox()
        let connection = NSXPCConnection(
            machServiceName: "dev.c0denail.DynamicIslandMac.PowerHelper",
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: DynamicIslandPowerHelperProtocol.self)

        let finish: @Sendable (LowPowerModeChangeResult) -> Void = { result in
            if response.storeIfEmpty(result) { semaphore.signal() }
        }
        connection.interruptionHandler = {
            finish(.helperUnavailable("Güç yardımcısıyla bağlantı kesildi."))
        }
        connection.invalidationHandler = {
            finish(.helperUnavailable("Güç yardımcısına ulaşılamadı."))
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.helperUnavailable(error.localizedDescription))
        }) as? DynamicIslandPowerHelperProtocol else {
            connection.invalidate()
            return .helperUnavailable("Güç yardımcısına bağlanılamadı.")
        }

        proxy.setLowPowerMode(enabled) { success, message in
            finish(success ? .success : .failure(message ?? "Düşük Güç Modu değiştirilemedi."))
        }

        guard semaphore.wait(timeout: .now() + 3) == .success else {
            connection.invalidate()
            return .helperUnavailable("Güç yardımcısı yanıt vermedi.")
        }
        let result = response.load() ?? .helperUnavailable("Güç yardımcısı yanıt vermedi.")
        connection.invalidate()
        return result
    }

    nonisolated private static func installPowerHelper() -> LowPowerModeChangeResult {
        let serviceName = "dev.c0denail.DynamicIslandMac.PowerHelper"
        let embeddedHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools/\(serviceName)")
        let embeddedPlist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(serviceName).plist")

        guard FileManager.default.isExecutableFile(atPath: embeddedHelper.path),
              FileManager.default.fileExists(atPath: embeddedPlist.path)
        else {
            return .failure("Güç yardımcısı uygulama paketinde bulunamadı. Uygulamayı DMG’den yeniden kurun.")
        }

        let destinationHelper = "/Library/PrivilegedHelperTools/\(serviceName)"
        let destinationPlist = "/Library/LaunchDaemons/\(serviceName).plist"
        let command = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/launchctl bootout system/\(serviceName) >/dev/null 2>&1 || true",
            "/bin/cp -f \(shellQuote(embeddedHelper.path)) \(shellQuote(destinationHelper))",
            "/usr/sbin/chown root:wheel \(shellQuote(destinationHelper))",
            "/bin/chmod 755 \(shellQuote(destinationHelper))",
            "/bin/cp -f \(shellQuote(embeddedPlist.path)) \(shellQuote(destinationPlist))",
            "/usr/sbin/chown root:wheel \(shellQuote(destinationPlist))",
            "/bin/chmod 644 \(shellQuote(destinationPlist))",
            "/bin/launchctl bootstrap system \(shellQuote(destinationPlist))",
            "/bin/launchctl enable system/\(serviceName)",
            "/bin/launchctl kickstart -k system/\(serviceName)"
        ].joined(separator: "; ")

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(appleScriptQuote(command))\" with administrator privileges"
        ]
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure("Düşük Güç Modu değiştirilemedi: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if detail.contains("-128") || detail.localizedCaseInsensitiveContains("canceled") || detail.localizedCaseInsensitiveContains("cancelled") {
                return .failure("Yönetici onayı iptal edildi.")
            }
            return .failure(detail.isEmpty ? "Düşük Güç Modu değiştirilemedi." : detail)
        }
        return .success
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private func readOutputVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        let values = volumeElements(for: device).compactMap { element -> Float? in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var volume = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
            return status == noErr ? volume : nil
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    private func volumeElements(for device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var probe = Float32(0)
        var probeSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &probeSize, &probe) == noErr {
            return [kAudioObjectPropertyElementMain]
        }

        var stereoAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * channels.count)
        let status = channels.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(device, &stereoAddress, 0, nil, &size, buffer.baseAddress!)
        }
        if status == noErr {
            return channels
        }
        return [1, 2]
    }

    private func readMute() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr ? muted != 0 : nil
    }

    private func installAudioListeners() {
        removeAudioListeners()
        guard let device = defaultOutputDevice() else { return }
        observedOutputDevice = device

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.audioValueDidChange() }
        }
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(device, &volumeAddress, .main, volumeBlock) == noErr {
            volumeListener = volumeBlock
        }

        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.audioValueDidChange() }
        }
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &muteAddress),
           AudioObjectAddPropertyListenerBlock(device, &muteAddress, .main, muteBlock) == noErr {
            muteListener = muteBlock
        }

        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.installAudioListeners()
                self?.audioValueDidChange()
            }
        }
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            .main,
            deviceBlock
        ) == noErr {
            deviceListener = deviceBlock
        }
    }

    private func removeAudioListeners() {
        if let device = observedOutputDevice, let volumeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, volumeListener)
        }
        if let device = observedOutputDevice, let muteListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, muteListener)
        }
        if let deviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                deviceListener
            )
        }
        observedOutputDevice = nil
        volumeListener = nil
        muteListener = nil
        deviceListener = nil
    }

    private func audioValueDidChange() {
        pollVolume()
    }

    private func pollVolume(force: Bool = false) {
        let newVolume = readOutputVolume() ?? outputVolume
        let newMuted = readMute() ?? false
        if abs(outputVolume - newVolume) > 0.000_5 { outputVolume = newVolume }
        if isMuted != newMuted { isMuted = newMuted }
        let changed = abs(newVolume - lastObservedVolume) > 0.003 || newMuted != lastObservedMute
        if changed || force {
            lastObservedVolume = newVolume
            lastObservedMute = newMuted
            volumeEvent = VolumeEvent(value: newVolume, isMuted: newMuted)
        }
    }

    private func pollBrightness(force: Bool = false) {
        guard let newBrightness = brightnessBridge.read() else { return }
        if abs(displayBrightness - newBrightness) > 0.000_5 { displayBrightness = newBrightness }

        if lastObservedBrightness < 0 {
            lastObservedBrightness = newBrightness
            return
        }

        if abs(newBrightness - lastObservedBrightness) > 0.002 || force {
            lastObservedBrightness = newBrightness
            brightnessEvent = BrightnessEvent(value: newBrightness)
        }
    }
}

private final class DisplayBrightnessBridge {
    private typealias GetBrightness = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var getBrightness: GetBrightness?
    private var setBrightness: SetBrightness?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        frameworkHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        guard let frameworkHandle else { return }

        if let symbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        }
        if let symbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") {
            setBrightness = unsafeBitCast(symbol, to: SetBrightness.self)
        }
    }

    deinit {
        if let frameworkHandle { dlclose(frameworkHandle) }
    }

    func read() -> Float? {
        guard let display = builtInDisplay(), let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return nil }
        return max(0, min(1, value))
    }

    func write(_ value: Float) -> Bool {
        guard let display = builtInDisplay(), let setBrightness else { return false }
        return setBrightness(display, max(0, min(1, value))) == 0
    }

    private func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var filled = count
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetOnlineDisplayList(count, buffer.baseAddress, &filled)
        }
        guard result == .success else { return nil }
        return displays.prefix(Int(filled)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

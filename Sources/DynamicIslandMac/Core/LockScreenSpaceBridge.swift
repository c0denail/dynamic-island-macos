import AppKit
import Darwin
import Foundation

/// Best-effort bridge that delegates an AppKit window to the private SkyLight
/// space shown above the standard screen-lock space.
///
/// Every private symbol is resolved at runtime so unsupported macOS versions
/// fail closed instead of crashing or placing a window over authentication UI.
@MainActor
final class LockScreenSpaceBridge {
    static let shared = LockScreenSpaceBridge()

    private typealias MainConnectionIDFunction = @convention(c) () -> Int32
    private typealias SpaceCreateFunction = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevelFunction = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFunction = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFunction = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias CopySpacesForWindowsFunction =
        @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpaceGetAbsoluteLevelFunction = @convention(c) (Int32, UInt64) -> Int32

    private struct Runtime {
        // Retaining the handle keeps every resolved function pointer valid for
        // the lifetime of the process. It is intentionally never dlclosed.
        let handle: UnsafeMutableRawPointer
        let mainConnectionID: MainConnectionIDFunction
        let createSpace: SpaceCreateFunction
        let setAbsoluteLevel: SpaceSetAbsoluteLevelFunction
        let showSpaces: ShowSpacesFunction
        let addWindows: AddWindowsFunction
        let copySpacesForWindows: CopySpacesForWindowsFunction
        let getAbsoluteLevel: SpaceGetAbsoluteLevelFunction

        init?() {
            let frameworkPath =
                "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
            guard let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
                return nil
            }

            guard
                let mainConnectionIDSymbol = dlsym(handle, "SLSMainConnectionID"),
                let createSpaceSymbol = dlsym(handle, "SLSSpaceCreate"),
                let setAbsoluteLevelSymbol = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
                let showSpacesSymbol = dlsym(handle, "SLSShowSpaces"),
                let addWindowsSymbol = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
                let copySpacesSymbol = dlsym(handle, "SLSCopySpacesForWindows"),
                let getAbsoluteLevelSymbol = dlsym(handle, "SLSSpaceGetAbsoluteLevel")
            else {
                dlclose(handle)
                return nil
            }

            self.handle = handle
            mainConnectionID = unsafeBitCast(
                mainConnectionIDSymbol,
                to: MainConnectionIDFunction.self
            )
            createSpace = unsafeBitCast(
                createSpaceSymbol,
                to: SpaceCreateFunction.self
            )
            setAbsoluteLevel = unsafeBitCast(
                setAbsoluteLevelSymbol,
                to: SpaceSetAbsoluteLevelFunction.self
            )
            showSpaces = unsafeBitCast(
                showSpacesSymbol,
                to: ShowSpacesFunction.self
            )
            addWindows = unsafeBitCast(
                addWindowsSymbol,
                to: AddWindowsFunction.self
            )
            copySpacesForWindows = unsafeBitCast(
                copySpacesSymbol,
                to: CopySpacesForWindowsFunction.self
            )
            getAbsoluteLevel = unsafeBitCast(
                getAbsoluteLevelSymbol,
                to: SpaceGetAbsoluteLevelFunction.self
            )
        }
    }

    private lazy var runtime: Runtime? = Runtime()
    private var connectionID: Int32?
    private var lockScreenSpaceID: UInt64?
    private var hasAttemptedSpaceCreation = false

    private init() {}

    /// Returns `true` only when the private runtime accepted delegation of the
    /// window. Callers must keep the real lock-screen card hidden on failure.
    func delegate(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0 else { return false }
        guard let runtime else { return false }
        guard let (connectionID, spaceID) = lockScreenSpace(using: runtime) else {
            return false
        }

        _ = runtime.addWindows(
            connectionID,
            spaceID,
            [NSNumber(value: window.windowNumber)] as CFArray,
            7
        )

        // The private mutation calls can be bridged asynchronously on recent
        // macOS releases. Do not trust their immediate return codes; verify the
        // actual WindowServer membership instead. A short startup-only wait
        // avoids racing that asynchronous hand-off without affecting animation.
        for attempt in 0..<8 {
            if validatesDelegation(
                of: window,
                connectionID: connectionID,
                spaceID: spaceID,
                runtime: runtime
            ) {
                return true
            }
            if attempt < 7 {
                usleep(10_000)
            }
        }
        return false
    }

    private func validatesDelegation(
        of window: NSWindow,
        connectionID: Int32,
        spaceID: UInt64,
        runtime: Runtime
    ) -> Bool {
        let windows = [NSNumber(value: window.windowNumber)] as CFArray

        // 0x0B includes WindowServer-owned/system Spaces. 0x07 returns normal
        // user Spaces. Requiring the first to contain only our level-400 Space
        // and the latter to be empty prevents a shielding-level window from
        // lingering on the unlocked desktop or authentication UI.
        guard let systemSpaces = copiedSpaceIDs(
            runtime.copySpacesForWindows(connectionID, 0x0B, windows)
        ),
        systemSpaces == [spaceID],
        let userSpaces = copiedSpaceIDs(
            runtime.copySpacesForWindows(connectionID, 0x07, windows)
        ),
        userSpaces.isEmpty,
        runtime.getAbsoluteLevel(connectionID, spaceID) == 400
        else {
            return false
        }
        return true
    }

    private func copiedSpaceIDs(_ result: Unmanaged<CFArray>?) -> [UInt64]? {
        guard let array = result?.takeRetainedValue() else { return nil }
        var identifiers: [UInt64] = []
        for value in array as NSArray {
            guard let number = value as? NSNumber else { return nil }
            identifiers.append(number.uint64Value)
        }
        return identifiers
    }

    private func lockScreenSpace(using runtime: Runtime) -> (Int32, UInt64)? {
        if let connectionID, let lockScreenSpaceID {
            return (connectionID, lockScreenSpaceID)
        }

        // Do not repeatedly allocate private spaces after a partial failure.
        guard !hasAttemptedSpaceCreation else { return nil }
        hasAttemptedSpaceCreation = true

        let connectionID = runtime.mainConnectionID()
        guard connectionID > 0 else { return nil }

        let spaceID = runtime.createSpace(connectionID, 1, 0)
        guard spaceID > 0 else { return nil }
        // Recent SkyLight implementations dispatch bridged operations
        // asynchronously, so their immediate CGError return is not a reliable
        // postcondition. Capability is established by resolved symbols plus a
        // valid connection and non-zero 64-bit Space ID.
        _ = runtime.setAbsoluteLevel(connectionID, spaceID, 400)
        _ = runtime.showSpaces(connectionID, [NSNumber(value: spaceID)] as CFArray)

        self.connectionID = connectionID
        lockScreenSpaceID = spaceID
        return (connectionID, spaceID)
    }
}

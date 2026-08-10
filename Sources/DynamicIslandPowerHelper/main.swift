import Darwin
import Foundation

private let serviceName = "dev.c0denail.DynamicIslandMac.PowerHelper"

@objc protocol DynamicIslandPowerHelperProtocol {
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

private final class PowerHelper: NSObject, DynamicIslandPowerHelperProtocol, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: DynamicIslandPowerHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        guard geteuid() == 0 else {
            reply(false, "Güç yardımcısı yönetici yetkisiyle çalışmıyor.")
            return
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        // The helper deliberately exposes no arbitrary command or argument surface.
        process.arguments = ["-a", "lowpowermode", enabled ? "1" : "0"]
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            reply(false, "Düşük Güç Modu değiştirilemedi: \(error.localizedDescription)")
            return
        }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            reply(false, detail?.isEmpty == false ? detail : "Düşük Güç Modu değiştirilemedi.")
            return
        }

        reply(true, nil)
    }
}

private let helper = PowerHelper()
private let listener = NSXPCListener(machServiceName: serviceName)
listener.delegate = helper
listener.resume()
RunLoop.current.run()

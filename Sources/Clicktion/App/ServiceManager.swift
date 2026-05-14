import Foundation

final class ServiceManager {
    private var process: Process?
    private let binaryPath: String

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        binaryPath = appSupport.appendingPathComponent("Clicktion/clicktion-service").path
    }

    func start() {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            print("Service binary not found at \(binaryPath)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.environment = ProcessInfo.processInfo.environment
        try? p.run()
        process = p
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

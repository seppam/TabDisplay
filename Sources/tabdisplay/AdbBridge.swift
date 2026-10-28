import Foundation

/// Keeps `adb reverse` set up for every connected Android device (USB or wireless debugging),
/// so the tablet can open http://localhost:8080 and land on this Mac.
final class AdbBridge {
    struct Device { let serial: String; let model: String; var isWireless: Bool { serial.contains(":") || serial.contains("adb-tls") } }
    enum Status { case notInstalled, noDevice, connected([Device]) }

    var onStatus: ((Status) -> Void)?
    let adbPath: String?
    private let ports: [UInt16]
    private let queue = DispatchQueue(label: "adb")
    private var timer: DispatchSourceTimer?
    private var models: [String: String] = [:]
    private var hardwareIDs: [String: String] = [:]

    init(ports: [UInt16]) {
        self.ports = ports
        adbPath = Self.locateAdb()
    }

    /// GUI apps don't get the shell's PATH, so look in the usual install locations.
    private static func locateAdb() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                          NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key] { candidates.insert(sdk + "/platform-tools/adb", at: 0) }
        }
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 3)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard let adb = adbPath else { return report(.notInstalled) }
        // "serial\tdevice" lines; skip "unauthorized"/"offline" until the user allows debugging.
        let serials = run(adb, ["devices"]).split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: "\t")
            return parts.count == 2 && parts[1] == "device" ? String(parts[0]) : nil
        }
        guard !serials.isEmpty else { return report(.noDevice) }

        var devices: [Device] = []
        var seen: [String: Int] = [:]
        for serial in serials {
            // Reapplied every poll: it is idempotent and is lost whenever the adb server restarts.
            for port in ports { _ = run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]) }
            if models[serial] == nil {
                let model = getprop(adb, serial, "ro.product.model")
                models[serial] = model.isEmpty ? serial : model
                let hardware = getprop(adb, serial, "ro.serialno")
                hardwareIDs[serial] = hardware.isEmpty ? serial : hardware
            }
            let device = Device(serial: serial, model: models[serial]!)
            // Wireless debugging often lists one tablet twice (IP:port and mDNS name): show it once, preferring USB.
            if let index = seen[hardwareIDs[serial]!] {
                if devices[index].isWireless && !device.isWireless { devices[index] = device }
            } else {
                seen[hardwareIDs[serial]!] = devices.count
                devices.append(device)
            }
        }
        report(.connected(devices))
    }

    private func getprop(_ adb: String, _ serial: String, _ key: String) -> String {
        run(adb, ["-s", serial, "shell", "getprop", key]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

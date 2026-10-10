import AppKit
import CoreAudio
import CoreLocation
import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Network
import Security
import AwakeCore

enum Proc {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ argv: [String]) -> Result {
        guard let first = argv.first else {
            return Result(status: 127, stdout: "", stderr: "empty argv")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Result(status: 127, stdout: "", stderr: String(describing: error))
        }
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

enum AdminShell {
    /// Exact strings only. User input never reaches this list.
    static let allowed: Set<String> = [
        "/usr/bin/pmset -a disablesleep 0",
        "/usr/bin/pmset -a disablesleep 1",
        "/usr/bin/pmset -b lowpowermode 0",
        "/usr/bin/pmset -b lowpowermode 1",
    ]

    static func run(_ command: String) -> Proc.Result {
        guard allowed.contains(command) else {
            return Proc.Result(status: 126, stdout: "", stderr: "refused")
        }
        let script = "do shell script \"\(command)\" with administrator privileges"
        return Proc.run(["/usr/bin/osascript", "-e", script])
    }
}

enum PMSet {
    static func read() -> (sleep: Int?, low: Int?) {
        let result = Proc.run(["/usr/bin/pmset", "-g"])
        return (
            AwakeCommands.parseDisableSleep(result.stdout),
            AwakeCommands.parseLowPowerMode(result.stdout)
        )
    }

    static func setDisableSleep(_ value: Int, privilege: PrivilegeMode) -> Bool {
        switch privilege {
        case .sudoers:
            let argv = AwakeCommands.sudoDisableSleep(value)
            guard AwakeCommands.isSudoersAllowed(argv) else { return false }
            return Proc.run(argv).status == 0
        case .prompt:
            return AdminShell.run(AwakeCommands.disableSleep(value).joined(separator: " ")).status == 0
        case .unavailable:
            return false
        }
    }

    static func setLowPowerMode(_ value: Int) -> Bool {
        AdminShell.run(AwakeCommands.lowPower(value).joined(separator: " ")).status == 0
    }
}

final class SleepAssertions {
    private var ids: [IOPMAssertionID] = []

    func acquire() {
        let types = [
            kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionTypePreventSystemSleep,
        ]
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Awake session" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                ids.append(id)
            }
        }
    }

    func releaseAll() {
        for id in ids {
            IOPMAssertionRelease(id)
        }
        ids.removeAll()
    }
}

enum LidProbe {
    /// Public IOKit registry read. No private framework.
    static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return false }
        let value = raw.takeRetainedValue()
        if let flag = value as? Bool { return flag }
        if let number = value as? Int { return number != 0 }
        if let number = value as? NSNumber { return number.intValue != 0 }
        return false
    }
}

enum BatteryProbe {
    static func percent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !list.isEmpty else {
            return nil
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let type = desc[kIOPSTypeKey as String] as? String, type != (kIOPSInternalBatteryType as String) {
                continue
            }
            let current = intFromPlist(desc[kIOPSCurrentCapacityKey as String])
            let max = intFromPlist(desc[kIOPSMaxCapacityKey as String])
            guard let current, let max, max > 0 else { continue }
            if max == 100 { return min(100, max(0, current)) }
            return min(100, max(0, Int((Double(current) / Double(max) * 100).rounded())))
        }
        return nil
    }

    private static func intFromPlist(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }
}

enum ThermalProbe {
    static func state() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}

enum AppProbe {
    static func runningApps() -> [AppInfo] {
        let dock = dockBundleIDs()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleId = app.bundleIdentifier else { return nil }
            let pid = app.processIdentifier
            guard pid > 1 else { return nil }
            return AppInfo(
                pid: pid,
                bundleId: bundleId,
                name: app.localizedName ?? bundleId,
                onDock: dock.contains(bundleId),
                running: !app.isTerminated
            )
        }
    }

    static func dockBundleIDs() -> Set<String> {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apps = plist["persistent-apps"] as? [[String: Any]]
        else { return [] }
        var ids = Set<String>()
        for item in apps {
            if let tile = item["tile-data"] as? [String: Any],
               let bundle = tile["bundle-identifier"] as? String {
                ids.insert(bundle)
            }
        }
        return ids
    }
}

enum Freezer {
    static func freeze(_ app: AppInfo) {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        guard app.pid > 1, app.pid != selfPid else { return }
        _ = kill(app.pid, SIGSTOP)
    }

    static func thaw(_ app: FrozenApp) {
        guard app.pid > 1 else { return }
        _ = kill(app.pid, SIGCONT)
    }
}

public enum SupportPaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Awake", isDirectory: true)
    }

    static var stateURL: URL { directory.appendingPathComponent("session-state.json") }
    static var configURL: URL { directory.appendingPathComponent("config.json") }
    static var logURL: URL { directory.appendingPathComponent("awake.log") }
    static var socketURL: URL { directory.appendingPathComponent("control.sock") }
    static var lockURL: URL { directory.appendingPathComponent("controller.lock") }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try prepare()
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func appendLog(_ message: String) {
        try? prepare()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = stamp + " " + AwakeCommands.redactLog(message) + "\n"
        let fd = open(logURL.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}

public enum KeychainStore {
    static let service = "com.awake.menubar.hotspot"

    public static func save(account: String, secret: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class HotspotClient: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var asked = false

    func prepare() {
        guard !asked else { return }
        asked = true
        location.delegate = self
        location.requestWhenInUseAuthorization()
    }

    func join(ssid: String) -> HotspotResult {
        guard let password = KeychainStore.load(account: ssid), !password.isEmpty else {
            return .noSecret
        }
        prepare()
        guard let iface = CWWiFiClient.shared().interface() else { return .failed }
        do {
            let networks = try iface.scanForNetworks(withSSID: Data(ssid.utf8))
            guard let network = networks.first else { return .failed }
            try iface.associate(to: network, password: password)
            return .joined
        } catch {
            return .failed
        }
    }
}

public enum SudoersInstaller {
    public static func install(username: String) -> String? {
        let contents: String
        do {
            contents = try AwakeCommands.sudoersFileContents(username: username)
        } catch {
            return error.localizedDescription
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("awake-sudoers-\(UUID().uuidString)")
        do {
            try contents.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return "Could not write a temporary sudoers file."
        }
        let path = tmp.path.replacingOccurrences(of: "\"", with: "")
        let command = "visudo -cf \"\(path)\" && cp \"\(path)\" /etc/sudoers.d/awake && chown root:wheel /etc/sudoers.d/awake && chmod 0440 /etc/sudoers.d/awake && rm -f \"\(path)\""
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let result = Proc.run(["/usr/bin/osascript", "-e", script])
        if result.status != 0 {
            return result.stderr.isEmpty ? "Administrator install was cancelled or failed." : result.stderr
        }
        return nil
    }

    public static func remove() -> String? {
        let script = "do shell script \"rm -f /etc/sudoers.d/awake\" with administrator privileges"
        let result = Proc.run(["/usr/bin/osascript", "-e", script])
        if result.status != 0 {
            return result.stderr.isEmpty ? "Could not remove the sudoers rule." : result.stderr
        }
        return nil
    }
}

func pidIsAlive(_ pid: Int32) -> Bool {
    if pid <= 0 { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

enum QuietControl {
    static func read() -> QuietLevels {
        QuietLevels(display: displayBrightness(), keyboard: keyboardBrightness(), muted: outputMuted())
    }

    static func write(display: Double?, keyboard: Double?, muted: Bool?) {
        if let display { _ = setDisplayBrightness(display) }
        if let keyboard { _ = setKeyboardBrightness(keyboard) }
        if let muted { _ = setOutputMuted(muted) }
    }

    private static func displayBrightness() -> Double? {
        guard let service = firstService("IODisplayConnect") else { return nil }
        defer { IOObjectRelease(service) }
        return DisplayBrightness.read(service)
    }

    private static func setDisplayBrightness(_ value: Double) -> Bool {
        guard let service = firstService("IODisplayConnect") else { return false }
        defer { IOObjectRelease(service) }
        return DisplayBrightness.write(service, value)
    }

    private static func keyboardBrightness() -> Double? {
        guard let service = keyboardService() else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, "KeyboardBacklightBrightness" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (raw as? NSNumber)?.doubleValue
    }

    private static func setKeyboardBrightness(_ value: Double) -> Bool {
        guard let service = keyboardService() else { return false }
        defer { IOObjectRelease(service) }
        let number = NSNumber(value: value)
        return IORegistryEntrySetCFProperty(service, "KeyboardBacklightBrightness" as CFString, number) == kIOReturnSuccess
    }

    private static func keyboardService() -> io_service_t? {
        for name in ["AppleHIDKeyboardEventDriverV2", "AppleHIDKeyboardEventDriver"] {
            if let service = firstService(name) { return service }
        }
        return nil
    }

    private static func firstService(_ name: String) -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        return service == 0 ? nil : service
    }

    private static func outputMuted() -> Bool? {
        guard let device = defaultOutput() else { return nil }
        var address = muteAddress()
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    private static func setOutputMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutput() else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0
        else { return nil }
        return device
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private enum DisplayBrightness {
    private typealias GetFn = @convention(c) (UInt32, UInt32, CFString, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, UInt32, CFString, Float) -> Int32

    private static let library: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_LAZY
    )

    static func read(_ service: io_service_t) -> Double? {
        guard let fn = symbol("IODisplayGetFloatParameter", GetFn.self) else { return nil }
        var value: Float = 0
        guard fn(service, 0, "brightness" as CFString, &value) == 0 else { return nil }
        return Double(value)
    }

    static func write(_ service: io_service_t, _ value: Double) -> Bool {
        guard let fn = symbol("IODisplaySetFloatParameter", SetFn.self) else { return false }
        return fn(service, 0, "brightness" as CFString, Float(value)) == 0
    }

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let library, let raw = dlsym(library, name) else { return nil }
        return unsafeBitCast(raw, to: type)
    }
}

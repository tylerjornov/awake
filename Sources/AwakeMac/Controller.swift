import Darwin
import Foundation
import Network
import UserNotifications
import AwakeCore

final class MacEffects: SessionEffects {
    var privilege: PrivilegeMode
    var disableSleep: Int
    var lowPowerMode: Int
    var pmsetFault: PmsetFault?
    var lastJoin = Date.distantPast
    var lastHotspot: HotspotResult?
    private let assertions = SleepAssertions()
    private let hotspot = HotspotClient()
    var onLog: (String) -> Void

    init(privilege: PrivilegeMode, onLog: @escaping (String) -> Void) {
        self.privilege = privilege
        self.onLog = onLog
        let reading = PMSet.read()
        disableSleep = reading.sleep ?? 0
        lowPowerMode = reading.low ?? 0
    }

    func setDisableSleep(_ value: Int) -> Bool {
        let ok = PMSet.setDisableSleep(value, privilege: privilege)
        if ok {
            disableSleep = value
            onLog("disablesleep.set value=\(value)")
        } else {
            onLog("disablesleep.fail")
        }
        return ok
    }

    func setLowPowerMode(_ value: Int) -> Bool {
        let ok = PMSet.setLowPowerMode(value)
        if ok {
            lowPowerMode = value
            onLog("lowpowermode.set value=\(value)")
        } else {
            onLog("lowpowermode.fail")
        }
        return ok
    }

    func acquireAssertions() { assertions.acquire() }
    func releaseAssertions() { assertions.releaseAll() }
    func freeze(_ app: AppInfo) { Freezer.freeze(app) }
    func thaw(_ app: FrozenApp) { Freezer.thaw(app) }
    func log(_ message: String) { onLog(AwakeCommands.redactLog(message)) }
    func notify(title: String, body: String) { Notifier.post(title: title, body: body) }

    func joinHotspot(ssid: String) -> HotspotResult {
        lastJoin = Date()
        let result = hotspot.join(ssid: ssid)
        lastHotspot = result
        return result
    }

    func readQuiet() -> QuietLevels { QuietControl.read() }

    func writeQuiet(display: Double?, keyboard: Double?, muted: Bool?) {
        QuietControl.write(display: display, keyboard: keyboard, muted: muted)
    }

    func refreshPowerReading() {
        let reading = PMSet.read()
        if let sleep = reading.sleep { disableSleep = sleep }
        if let low = reading.low { lowPowerMode = low }
    }
}

enum Notifier {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}

public struct ControlCommand: Codable {
    public var op: String
    public var seconds: Int?
    public var indefinite: Bool?
    public init(op: String, seconds: Int? = nil, indefinite: Bool? = nil) {
        self.op = op
        self.seconds = seconds
        self.indefinite = indefinite
    }
}

public struct ControlReply: Codable {
    public var ok: Bool
    public var error: String?
    public var phase: String?
    public var title: String?
    public var disableSleep: Int?
    public var ownerPid: Int32?
}

public final class SessionController {
    public static let shared = SessionController()

    public private(set) var session: Session?
    public var policy: Policy
    public var onUpdate: (() -> Void)?
    public private(set) var isController = false
    public var lastError: String?

    private let effects: MacEffects
    private var timer: DispatchSourceTimer?
    private var lockFD: Int32 = -1
    private var server: ControlServer?
    private let pathMonitor = NWPathMonitor()
    private var networkUp = true
    private var signals: [any DispatchSourceSignal] = []
    private var cleaning = false
    private var signalsInstalled = false

    public init() {
        policy = Self.loadPolicy()
        effects = MacEffects(privilege: policy.privilege, onLog: { SupportPaths.appendLog($0) })
    }

    public func activate() {
        try? SupportPaths.prepare()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.networkUp = path.status == .satisfied
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "awake.path"))
        if tryAcquireLock() {
            isController = true
            reconcileIfNeeded()
            server = ControlServer(path: SupportPaths.socketURL.path) { [weak self] line in
                self?.perform(line) ?? "{\"ok\":false,\"error\":\"gone\"}\n"
            }
            server?.start()
            installSignals()
            startTimer()
            effects.log("process.start role=controller")
        } else {
            isController = false
            effects.log("process.start role=client")
        }
        onUpdate?()
    }

    public func shutdown() {
        guard isController else { return }
        end(.quit)
        server?.stop()
        timer?.cancel()
        timer = nil
        releaseLock()
        isController = false
    }

    public func menuTitle(now: Date = Date()) -> String {
        guard let session else { return "Awake" }
        if session.phase == .restorePending { return "Restore" }
        guard session.phase == .running else { return "Awake" }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return AwakeCommands.formatRemaining(endsAtMs: session.endsAtMs, nowMs: nowMs)
    }

    public func start(_ length: SessionLength) {
        guard ensureController() else { return }
        effects.privilege = policy.privilege
        effects.refreshPowerReading()
        if PMSet.read().sleep == nil {
            lastError = "Could not read the current sleep setting. Refusing to start."
            onUpdate?()
            return
        }
        let sample = currentSample()
        do {
            try AwakeFlow.start(
                session: &session,
                length: length,
                policy: policy,
                sample: sample,
                ownerPid: ProcessInfo.processInfo.processIdentifier,
                apps: AppProbe.runningApps(),
                effects: effects
            )
            lastError = nil
            persist()
        } catch let error as AwakeError {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }
        onUpdate?()
    }

    public func extend(seconds: Int) {
        guard ensureController() else { return }
        guard var current = session else {
            lastError = "Nothing is running to extend."
            onUpdate?()
            return
        }
        do {
            try AwakeFlow.extend(
                session: &current,
                seconds: seconds,
                nowMs: nowMs(),
                effects: effects
            )
            session = current
            lastError = nil
            persist()
        } catch let error as AwakeError {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }
        onUpdate?()
    }

    public func end(_ reason: EndReason) {
        guard isController, !cleaning else { return }
        guard session?.phase != .ended else { return }
        cleaning = true
        defer { cleaning = false }
        effects.privilege = policy.privilege
        effects.refreshPowerReading()
        AwakeFlow.stop(session: &session, reason: reason, sample: currentSample(), effects: effects)
        persist()
        onUpdate?()
    }

    public func savePolicy() {
        effects.privilege = policy.privilege
        if let data = try? JSONEncoder.pretty.encode(policy) {
            try? SupportPaths.writePrivate(data, to: SupportPaths.configURL)
        }
        onUpdate?()
    }

    public func statusReply() -> ControlReply {
        ControlReply(
            ok: true,
            error: lastError,
            phase: session?.phase.rawValue ?? "idle",
            title: menuTitle(),
            disableSleep: effects.disableSleep,
            ownerPid: ProcessInfo.processInfo.processIdentifier
        )
    }

    public func perform(_ line: String) -> String {
        let reply: ControlReply
        let op: String
        do {
            let command = try JSONDecoder().decode(ControlCommand.self, from: Data(line.utf8))
            op = command.op
            lastError = nil
            switch command.op {
            case "start":
                if command.indefinite == true {
                    start(.indefinite)
                } else {
                    start(.timed(seconds: command.seconds ?? 0))
                }
            case "extend":
                extend(seconds: command.seconds ?? 0)
            case "stop":
                end(.user)
            case "status":
                break
            default:
                lastError = "Unknown command."
            }
            var status = statusReply()
            if op != "status", let lastError {
                status.ok = false
                status.error = lastError
            }
            reply = status
        } catch {
            reply = ControlReply(ok: false, error: "Bad command.", phase: nil, title: nil, disableSleep: nil, ownerPid: nil)
        }
        let data = (try? JSONEncoder().encode(reply)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    public static func send(_ command: ControlCommand) -> ControlReply? {
        let path = SupportPaths.socketURL.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard var addr = unixAddress(path) else { return nil }
        let connected: Int32 = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let payload = (try? JSONEncoder().encode(command)).map { String(data: $0, encoding: .utf8)! + "\n" } ?? "\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        let data = Data(buffer.prefix(count))
        return try? JSONDecoder().decode(ControlReply.self, from: data)
    }

    private func ensureController() -> Bool {
        if isController { return true }
        lastError = "Another Awake controller owns the session."
        onUpdate?()
        return false
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func currentSample() -> MachineSample {
        MachineSample(
            nowMs: nowMs(),
            batteryPercent: BatteryProbe.percent(),
            lidClosed: LidProbe.isClosed(),
            thermal: ThermalProbe.state(),
            networkSatisfied: networkUp,
            lowPowerMode: effects.lowPowerMode,
            disableSleep: effects.disableSleep
        )
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard isController, var current = session, current.phase == .running else { return }
        effects.refreshPowerReading()
        if current.hotspotArmed, !networkUp,
           Date().timeIntervalSince(effects.lastJoin) >= 30,
           effects.lastHotspot == .failed,
           KeychainStore.load(account: policy.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            current.hotspotArmed = false
            session = current
        }
        AwakeFlow.evaluate(
            session: &session,
            policy: policy,
            sample: currentSample(),
            apps: AppProbe.runningApps(),
            effects: effects
        )
        persist()
        onUpdate?()
    }

    private func reconcileIfNeeded() {
        guard let data = try? Data(contentsOf: SupportPaths.stateURL),
              let saved = try? JSONDecoder().decode(Session.self, from: data)
        else { return }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        if saved.ownerPid == selfPid {
            session = saved
            return
        }
        if pidIsAlive(saved.ownerPid) { return }
        session = saved
        effects.refreshPowerReading()
        if effects.disableSleep == 0 && saved.disableSleepApplied {
            effects.disableSleep = 1
        }
        AwakeFlow.reconcile(session: &session, ownerAlive: false, sample: currentSample(), effects: effects)
        persist()
    }

    private func persist() {
        guard let session, session.phase != .ended else {
            try? FileManager.default.removeItem(at: SupportPaths.stateURL)
            return
        }
        var stored = session
        stored.ownerPid = ProcessInfo.processInfo.processIdentifier
        self.session = stored
        if let data = try? JSONEncoder.pretty.encode(stored) {
            try? SupportPaths.writePrivate(data, to: SupportPaths.stateURL)
        }
    }

    private func installSignals() {
        guard !signalsInstalled else { return }
        signalsInstalled = true
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.end(.signal) }
            source.resume()
            signals.append(source)
        }
    }

    private func tryAcquireLock() -> Bool {
        try? SupportPaths.prepare()
        let fd = open(SupportPaths.lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        _ = ftruncate(fd, 0)
        let note = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = note.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    private func releaseLock() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    private static func loadPolicy() -> Policy {
        guard let data = try? Data(contentsOf: SupportPaths.configURL),
              let policy = try? JSONDecoder().decode(Policy.self, from: data)
        else { return Policy() }
        return policy
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= 104 else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        bytes.withUnsafeBytes { src in
            buffer.copyMemory(from: src)
        }
    }
    addr.sun_len = UInt8(2 + bytes.count)
    return addr
}

final class ControlServer {
    private let path: String
    private let handler: (String) -> String
    private var fd: Int32 = -1
    private var thread: Thread?

    init(path: String, handler: @escaping (String) -> String) {
        self.path = path
        self.handler = handler
    }

    func start() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        guard var addr = unixAddress(path) else {
            close(fd)
            return
        }
        let bound: Int32 = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        chmod(path, 0o600)
        self.fd = fd
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "awake.control"
        thread.start()
        self.thread = thread
    }

    func stop() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(path)
    }

    private func loop() {
        while fd >= 0 {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &buffer, buffer.count)
            let line: String
            if count > 0 {
                line = String(data: Data(buffer.prefix(count)), encoding: .utf8) ?? ""
            } else {
                line = ""
            }
            let sem = DispatchSemaphore(value: 0)
            var reply = "{\"ok\":false}\n"
            let handler = self.handler
            DispatchQueue.main.async {
                reply = handler(line.trimmingCharacters(in: .whitespacesAndNewlines))
                sem.signal()
            }
            sem.wait()
            _ = reply.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }
}

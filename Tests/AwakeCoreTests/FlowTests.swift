import XCTest
@testable import AwakeCore

final class MemoryEffects: SessionEffects {
    var disableSleep: Int
    var lowPowerMode: Int
    var pmsetFault: PmsetFault?
    var assertions = false
    var frozen = Set<Int32>()
    var logs: [String] = []
    var notices: [(String, String)] = []
    var password: String
    var joined = 0
    var display = 1.0
    var keyboard = 0.8
    var muted = false

    init(disableSleep: Int = 0, lowPowerMode: Int = 0, password: String = "") {
        self.disableSleep = disableSleep
        self.lowPowerMode = lowPowerMode
        self.password = password
    }

    func setDisableSleep(_ value: Int) -> Bool {
        if pmsetFault == .disableSleep {
            pmsetFault = nil
            log("disablesleep.fail")
            return false
        }
        disableSleep = value
        log("disablesleep.set value=\(value)")
        return true
    }

    func setLowPowerMode(_ value: Int) -> Bool {
        if pmsetFault == .lowPower {
            pmsetFault = nil
            log("lowpowermode.fail")
            return false
        }
        lowPowerMode = value
        log("lowpowermode.set value=\(value)")
        return true
    }

    func acquireAssertions() { assertions = true }
    func releaseAssertions() { assertions = false }
    func freeze(_ app: AppInfo) { frozen.insert(app.pid) }
    func thaw(_ app: FrozenApp) { frozen.remove(app.pid) }
    func log(_ message: String) { logs.append(AwakeCommands.redactLog(message)) }
    func notify(title: String, body: String) { notices.append((title, body)) }
    func joinHotspot(ssid: String) -> HotspotResult {
        if password.isEmpty { return .noSecret }
        joined += 1
        return .joined
    }

    func readQuiet() -> QuietLevels {
        QuietLevels(display: display, keyboard: keyboard, muted: muted)
    }

    func writeQuiet(display: Double?, keyboard: Double?, muted: Bool?) {
        if let display { self.display = display }
        if let keyboard { self.keyboard = keyboard }
        if let muted { self.muted = muted }
    }
}

final class FlowTests: XCTestCase {
    private func apps() -> [AppInfo] {
        [
            AppInfo(pid: 101, bundleId: "com.tinyspeck.slackmacgap", name: "Slack", onDock: true, running: true),
            AppInfo(pid: 102, bundleId: "com.hnc.Discord", name: "Discord", onDock: true, running: true),
            AppInfo(pid: 103, bundleId: "net.whatsapp.WhatsApp", name: "WhatsApp", onDock: false, running: true),
            AppInfo(pid: 104, bundleId: "ru.keepcoder.Telegram", name: "Telegram", onDock: true, running: false),
            AppInfo(pid: 201, bundleId: "com.apple.Terminal", name: "Terminal", onDock: true, running: true),
            AppInfo(pid: 203, bundleId: "com.apple.Safari", name: "Safari", onDock: true, running: true),
            AppInfo(pid: 301, bundleId: "com.spotify.client", name: "Spotify", onDock: true, running: true),
            AppInfo(pid: 401, bundleId: "com.apple.finder", name: "Finder", onDock: true, running: true),
        ]
    }

    private func sample(
        now: Int64,
        battery: Int? = 80,
        lid: Bool = false,
        thermal: ThermalState = .nominal,
        network: Bool = true,
        low: Int = 0,
        sleep: Int = 0
    ) -> MachineSample {
        MachineSample(
            nowMs: now,
            batteryPercent: battery,
            lidClosed: lid,
            thermal: thermal,
            networkSatisfied: network,
            lowPowerMode: low,
            disableSleep: sleep
        )
    }

    func testTimerExpiryRestoresPreviousSleep() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .timed(seconds: 90 * 60),
            policy: Policy(),
            sample: sample(now: 1_000),
            ownerPid: 10,
            apps: apps(),
            effects: fx
        )
        XCTAssertEqual(session?.phase, .running)
        XCTAssertEqual(fx.disableSleep, 1)
        XCTAssertTrue(fx.assertions)
        XCTAssertTrue(fx.frozen.isEmpty)

        var early = sample(now: 1_000 + Int64(90 * 60) * 1000 - 1)
        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: early, effects: fx)
        XCTAssertEqual(session?.phase, .running)

        let due = sample(now: 1_000 + Int64(90 * 60) * 1000)
        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: due, effects: fx)
        XCTAssertEqual(session?.phase, .ended)
        XCTAssertEqual(session?.endReason, .timer)
        XCTAssertEqual(fx.disableSleep, 0)
        XCTAssertFalse(session?.disableSleepApplied ?? true)
        XCTAssertFalse(fx.assertions)
        XCTAssertTrue(fx.frozen.isEmpty)
        XCTAssertEqual(fx.notices.last?.0, "Awake ended")
        XCTAssertTrue(fx.notices.last?.1.contains("Timer finished") ?? false)
    }

    func testIndefiniteDoesNotExpire() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 1,
            apps: apps(),
            effects: fx
        )
        let later = sample(now: Int64(10 * 24 * 60 * 60) * 1000)
        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: later, effects: fx)
        XCTAssertEqual(session?.phase, .running)
        XCTAssertNil(session?.endsAtMs)
    }

    func testExtendTimedAndIndefinite() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .timed(seconds: 60),
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        try AwakeFlow.extend(session: &session!, seconds: 30, nowMs: 0, effects: fx)
        XCTAssertEqual(session?.endsAtMs, 90_000)

        var forever: Session?
        try AwakeFlow.start(
            session: &forever,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 50),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        try AwakeFlow.extend(session: &forever!, seconds: 15 * 60, nowMs: 50, effects: fx)
        XCTAssertEqual(forever?.endsAtMs, 50 + Int64(15 * 60) * 1000)
    }

    func testAlreadyDisabledSleepIsRestoredToOn() throws {
        let fx = MemoryEffects(disableSleep: 1)
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0, sleep: 1),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        XCTAssertEqual(session?.disableSleepApplied, false)
        XCTAssertEqual(fx.disableSleep, 1)
        AwakeFlow.stop(session: &session, reason: .user, sample: sample(now: 5), effects: fx)
        XCTAssertEqual(fx.disableSleep, 1)
        XCTAssertEqual(session?.phase, .ended)
    }

    func testRollbackWhenDisableSleepFails() {
        let fx = MemoryEffects()
        fx.pmsetFault = .disableSleep
        var session: Session?
        XCTAssertThrowsError(try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 1,
            apps: apps(),
            effects: fx
        ))
        XCTAssertNil(session)
        XCTAssertEqual(fx.disableSleep, 0)
        XCTAssertFalse(fx.assertions)
        XCTAssertTrue(fx.frozen.isEmpty)
    }

    func testRestorePendingThenRetry() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 1,
            apps: apps(),
            effects: fx
        )
        fx.pmsetFault = .disableSleep
        AwakeFlow.stop(session: &session, reason: .user, sample: sample(now: 10), effects: fx)
        XCTAssertEqual(session?.phase, .restorePending)
        XCTAssertEqual(fx.disableSleep, 1)
        XCTAssertTrue(fx.frozen.isEmpty)
        AwakeFlow.stop(session: &session, reason: .user, sample: sample(now: 11), effects: fx)
        XCTAssertEqual(session?.phase, .ended)
        XCTAssertEqual(fx.disableSleep, 0)
    }

    func testBatteryFloorAndThermal() throws {
        let fx = MemoryEffects()
        var session: Session?
        let policy = Policy()
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: policy,
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        AwakeFlow.evaluate(session: &session, policy: policy, sample: sample(now: 1, battery: 19), effects: fx)
        XCTAssertEqual(session?.phase, .running)
        AwakeFlow.evaluate(session: &session, policy: policy, sample: sample(now: 2, battery: 18), effects: fx)
        XCTAssertEqual(session?.endReason, .battery)
        XCTAssertEqual(fx.disableSleep, 0)
        XCTAssertTrue(fx.notices.last?.1.contains("Battery at 18%") ?? false)

        var thermal: Session?
        let fx2 = MemoryEffects()
        try AwakeFlow.start(
            session: &thermal,
            length: .indefinite,
            policy: policy,
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: fx2
        )
        AwakeFlow.evaluate(session: &thermal, policy: policy, sample: sample(now: 1, thermal: .fair), effects: fx2)
        XCTAssertEqual(thermal?.phase, .running)
        AwakeFlow.evaluate(session: &thermal, policy: policy, sample: sample(now: 2, thermal: .serious), effects: fx2)
        XCTAssertEqual(thermal?.endReason, .thermal)
        XCTAssertEqual(fx2.disableSleep, 0)
    }

    func testNoBatteryDoesNotEnd() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0, battery: nil),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: sample(now: 5_000, battery: nil), effects: fx)
        XCTAssertEqual(session?.phase, .running)
    }

    func testTimerBeatsBattery() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .timed(seconds: 10),
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: sample(now: 10_000, battery: 10), effects: fx)
        XCTAssertEqual(session?.endReason, .timer)
    }

    func testRefuseWithoutPrivilege() {
        var session: Session?
        let fx = MemoryEffects()
        var policy = Policy()
        policy.privilege = .unavailable
        XCTAssertThrowsError(try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: policy,
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: fx
        ))
        XCTAssertNil(session)
        XCTAssertEqual(fx.disableSleep, 0)
    }

    func testLowPowerPromptOnly() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: sample(now: 1, lid: true), effects: fx)
        XCTAssertEqual(fx.lowPowerMode, 1)
        XCTAssertEqual(session?.lowPowerApplied, true)
        XCTAssertEqual(session?.phase, .running)
        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: sample(now: 2, lid: false, low: 1), effects: fx)
        XCTAssertEqual(fx.lowPowerMode, 0)
        XCTAssertEqual(fx.disableSleep, 1)

        let sudo = MemoryEffects()
        var sudoSession: Session?
        var policy = Policy()
        policy.privilege = .sudoers
        try AwakeFlow.start(
            session: &sudoSession,
            length: .indefinite,
            policy: policy,
            sample: sample(now: 0, lid: true),
            ownerPid: 1,
            apps: [],
            effects: sudo
        )
        XCTAssertEqual(sudo.lowPowerMode, 0)
        XCTAssertTrue(sudo.logs.contains { $0.contains("lowpower.skip privilege=sudoers") })
        XCTAssertFalse(AwakeCommands.isSudoersAllowed(AwakeCommands.lowPower(1)))
        XCTAssertTrue(AwakeCommands.isSudoersAllowed(AwakeCommands.sudoDisableSleep(1)))
        XCTAssertTrue(AwakeCommands.isSudoersAllowed(AwakeCommands.sudoDisableSleep(0)))
    }

    func testFreezeSelection() {
        let names = AwakePolicy.selectFreezeTargets(apps(), policy: Policy()).map(\.name).sorted()
        XCTAssertEqual(names, ["Discord", "Slack", "WhatsApp"])

        var dock = Policy()
        dock.freezeBundleIds = []
        dock.freezeOtherDockApps = true
        let dockNames = AwakePolicy.selectFreezeTargets(apps(), policy: dock).map(\.name).sorted()
        XCTAssertEqual(dockNames, ["Discord", "Slack", "Spotify"])

        var explicit = Policy()
        explicit.freezeBundleIds = ["com.apple.Safari", "com.apple.finder", "com.spotify.client"]
        explicit.freezeOtherDockApps = false
        let explicitNames = AwakePolicy.selectFreezeTargets(apps(), policy: explicit).map(\.name).sorted()
        XCTAssertEqual(explicitNames, ["Spotify"])

        var manual = Policy()
        manual.selectionMode = .manual
        manual.manualPausedBundleIds = ["com.hnc.Discord", "com.spotify.client", "com.apple.Terminal", "com.apple.finder"]
        let manualNames = AwakePolicy.selectFreezeTargets(apps(), policy: manual).map(\.name).sorted()
        XCTAssertEqual(manualNames, ["Discord", "Spotify"])

        var kept = apps()
        kept.append(AppInfo(pid: 501, bundleId: "com.anthropic.claudefordesktop", name: "Claude", onDock: true, running: true))
        kept.append(AppInfo(pid: 502, bundleId: "us.zoom.xos", name: "Zoom", onDock: true, running: true))
        var others = Policy()
        others.freezeBundleIds = []
        others.freezeOtherDockApps = true
        let keptNames = AwakePolicy.selectFreezeTargets(kept, policy: others).map(\.name).sorted()
        XCTAssertEqual(keptNames, ["Discord", "Slack", "Spotify"])
    }

    func testLidClosePausesAndRestores() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 1,
            apps: apps(),
            effects: fx
        )
        XCTAssertTrue(fx.frozen.isEmpty)
        XCTAssertEqual(fx.display, 1)
        XCTAssertFalse(fx.muted)

        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: sample(now: 1, lid: true), apps: apps(), effects: fx)
        XCTAssertTrue(fx.frozen.contains(101))
        XCTAssertTrue(fx.frozen.contains(102))
        XCTAssertTrue(fx.frozen.contains(103))
        XCTAssertFalse(fx.frozen.contains(201))
        XCTAssertFalse(fx.frozen.contains(401))
        XCTAssertEqual(fx.display, 0)
        XCTAssertEqual(fx.keyboard, 0)
        XCTAssertTrue(fx.muted)
        XCTAssertEqual(fx.lowPowerMode, 1)
        XCTAssertEqual(session?.phase, .running)

        AwakeFlow.evaluate(session: &session, policy: Policy(), sample: sample(now: 2, lid: false), apps: apps(), effects: fx)
        XCTAssertTrue(fx.frozen.isEmpty)
        XCTAssertEqual(fx.display, 1)
        XCTAssertEqual(fx.keyboard, 0.8)
        XCTAssertFalse(fx.muted)
        XCTAssertEqual(fx.lowPowerMode, 0)
        XCTAssertEqual(fx.disableSleep, 1)
    }

    func testSudoersAndParsing() throws {
        let line = try AwakeCommands.sudoersRuleLine(username: "tyler")
        XCTAssertEqual(
            line,
            "tyler ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        )
        let file = try AwakeCommands.sudoersFileContents(username: "tyler")
        let rules = file.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(rules, [line])
        XCTAssertFalse(file.contains("lowpowermode"))
        XCTAssertThrowsError(try AwakeCommands.sudoersRuleLine(username: "tyler\nALL=(ALL) NOPASSWD: ALL"))
        XCTAssertThrowsError(try AwakeCommands.sudoersRuleLine(username: "root; rm -rf /"))

        let sample = "System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n lowpowermode         0\n"
        XCTAssertEqual(AwakeCommands.parseDisableSleep(sample), 0)
        XCTAssertEqual(AwakeCommands.parseLowPowerMode(sample), 0)
        XCTAssertEqual(AwakeCommands.parseDisableSleep(" SleepDisabled  1\n"), 1)
        XCTAssertNil(AwakeCommands.parseDisableSleep("nothing"))
        XCTAssertEqual(
            AwakeCommands.redactLog("hotspot.join password=hunter2 ssid=iPhone"),
            "hotspot.join password=[redacted] ssid=iPhone"
        )
        let encoded = try JSONEncoder().encode(Policy())
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("hotspotPassword"))
        XCTAssertFalse(text.contains("hunter2"))
    }

    func testReconcileAfterKill() throws {
        let fx = MemoryEffects()
        var session: Session?
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: Policy(),
            sample: sample(now: 0),
            ownerPid: 99,
            apps: apps(),
            effects: fx
        )
        AwakeFlow.evaluate(
            session: &session,
            policy: Policy(),
            sample: sample(now: 1, lid: true),
            apps: apps(),
            effects: fx
        )
        XCTAssertFalse(fx.frozen.isEmpty)
        XCTAssertEqual(fx.display, 0)
        fx.assertions = false
        AwakeFlow.reconcile(session: &session, ownerAlive: false, sample: sample(now: 50), effects: fx)
        XCTAssertEqual(session?.phase, .ended)
        XCTAssertEqual(fx.disableSleep, 0)
        XCTAssertTrue(fx.frozen.isEmpty)
        XCTAssertEqual(fx.display, 1)
        XCTAssertFalse(fx.muted)
        XCTAssertEqual(fx.notices.last?.0, "Awake ended")
    }

    func testHotspotDoesNotLogSecretAndDoesNotRetryWithoutAPassword() throws {
        let fx = MemoryEffects(password: "")
        var session: Session?
        var policy = Policy()
        policy.hotspotEnabled = true
        policy.hotspotSSID = "iPhone"
        try AwakeFlow.start(
            session: &session,
            length: .indefinite,
            policy: policy,
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: fx
        )
        AwakeFlow.evaluate(session: &session, policy: policy, sample: sample(now: 1, network: false), effects: fx)
        AwakeFlow.evaluate(session: &session, policy: policy, sample: sample(now: 2, network: false), effects: fx)
        XCTAssertEqual(fx.logs.filter { $0.contains("hotspot.skip") }.count, 1)
        XCTAssertFalse(fx.logs.joined(separator: "\n").contains("hunter2"))

        let ok = MemoryEffects(password: "secret-value")
        var joined: Session?
        try AwakeFlow.start(
            session: &joined,
            length: .indefinite,
            policy: policy,
            sample: sample(now: 0),
            ownerPid: 1,
            apps: [],
            effects: ok
        )
        AwakeFlow.evaluate(session: &joined, policy: policy, sample: sample(now: 1, network: false), effects: ok)
        AwakeFlow.evaluate(session: &joined, policy: policy, sample: sample(now: 2, network: false), effects: ok)
        XCTAssertEqual(ok.joined, 1)
        XCTAssertTrue(ok.logs.contains { $0.contains("hotspot.join ssid=iPhone") })
        XCTAssertFalse(ok.logs.joined(separator: "\n").contains("secret-value"))
    }
}

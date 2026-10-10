import Foundation

/// Side effects the session flow is allowed to request.
/// Implementations must not widen the sudoers rule. Low Power Mode is prompt-only.
public protocol SessionEffects: AnyObject {
    var disableSleep: Int { get }
    var lowPowerMode: Int { get }
    var pmsetFault: PmsetFault? { get set }
    func setDisableSleep(_ value: Int) -> Bool
    func setLowPowerMode(_ value: Int) -> Bool
    func acquireAssertions()
    func releaseAssertions()
    func freeze(_ app: AppInfo)
    func thaw(_ app: FrozenApp)
    func log(_ message: String)
    func notify(title: String, body: String)
    /// Password is used in memory only. Log lines must not include it.
    func joinHotspot(ssid: String) -> HotspotResult
    func readQuiet() -> QuietLevels
    func writeQuiet(display: Double?, keyboard: Double?, muted: Bool?)
}

public enum AwakeFlow {
    public static func start(
        session: inout Session?,
        length: SessionLength,
        policy: Policy,
        sample: MachineSample,
        ownerPid: Int32,
        apps: [AppInfo],
        effects: SessionEffects
    ) throws {
        if let session, session.phase != .ended {
            throw AwakeError.alreadyActive
        }
        if let message = AwakePolicy.validateStart(policy, length: length) {
            throw AwakeError.invalid(message)
        }

        effects.acquireAssertions()
        effects.log("assertions.acquire types=PreventUserIdleSystemSleep,PreventSystemSleep")

        let previous = effects.disableSleep == 1 ? 1 : 0
        var appliedSleep = false
        if previous != 1 {
            if !effects.setDisableSleep(1) {
                effects.releaseAssertions()
                effects.log("session.rollback reason=disablesleep")
                session = nil
                throw AwakeError.power("Could not disable sleep. Nothing was left changed.")
            }
            appliedSleep = true
        }

        var created = Session(
            ownerPid: ownerPid,
            startedAtMs: sample.nowMs,
            endsAtMs: endsAt(length, now: sample.nowMs),
            previousDisableSleep: previous,
            disableSleepApplied: appliedSleep,
            previousLowPowerMode: nil,
            lowPowerApplied: false,
            frozen: [],
            assertionsHeld: true,
            phase: .running,
            endReason: nil,
            observedLidClosed: false,
            hotspotArmed: false,
            batteryAtEnd: nil
        )
        if sample.lidClosed {
            closeLid(&created, policy: policy, apps: apps, effects: effects)
        }
        created.observedLidClosed = sample.lidClosed
        session = created
        let label: String
        if case .timed(let seconds) = length {
            label = "\(seconds)s"
        } else {
            label = "indefinite"
        }
        effects.log("session.start length=\(label) privilege=\(policy.privilege.rawValue)")
    }

    public static func extend(session: inout Session, seconds: Int, nowMs: Int64, effects: SessionEffects) throws {
        guard session.phase == .running else { throw AwakeError.invalid("Nothing is running to extend.") }
        guard seconds > 0 else { throw AwakeError.invalid("Extend by a positive amount.") }
        let base = session.endsAtMs.map { max($0, nowMs) } ?? nowMs
        session.endsAtMs = base + Int64(seconds) * 1000
        effects.log("session.extend seconds=\(seconds)")
    }

    public static func stop(session: inout Session?, reason: EndReason, sample: MachineSample, effects: SessionEffects) {
        guard var current = session, current.phase != .ended else { return }
        current = restore(current, reason: reason, battery: sample.batteryPercent, notify: shouldNotify(reason), effects: effects)
        session = current
    }

    /// Timer, battery, thermal, lid, and hotspot. Call about once a second while running.
    public static func evaluate(
        session: inout Session?,
        policy: Policy,
        sample: MachineSample,
        apps: [AppInfo] = [],
        effects: SessionEffects
    ) {
        guard var current = session, current.phase == .running else { return }

        if let ends = current.endsAtMs, sample.nowMs >= ends {
            current = restore(current, reason: .timer, battery: sample.batteryPercent, notify: true, effects: effects)
            session = current
            return
        }
        if let battery = sample.batteryPercent, battery <= policy.batteryFloorPercent {
            current = restore(current, reason: .battery, battery: battery, notify: true, effects: effects)
            session = current
            return
        }
        if sample.thermal.endsSession {
            current = restore(current, reason: .thermal, battery: sample.batteryPercent, notify: true, effects: effects)
            session = current
            return
        }

        if sample.lidClosed && !current.observedLidClosed {
            closeLid(&current, policy: policy, apps: apps, effects: effects)
        } else if !sample.lidClosed && current.observedLidClosed {
            openLid(&current, effects: effects)
        } else if sample.lidClosed {
            syncFreeze(&current, policy: policy, apps: apps, effects: effects)
        }
        current.observedLidClosed = sample.lidClosed
        considerHotspot(&current, policy: policy, networkSatisfied: sample.networkSatisfied, effects: effects)
        session = current
    }

    /// Next launch after SIGKILL or a crash. Assertions are already gone; sleep and SIGSTOP are not.
    public static func reconcile(
        session: inout Session?,
        ownerAlive: Bool,
        sample: MachineSample,
        effects: SessionEffects
    ) {
        guard let current = session, current.phase != .ended else {
            effects.log("process.start reconcile=none")
            return
        }
        if ownerAlive && current.phase == .running {
            return
        }
        effects.log("process.start reconcile=restore")
        let reason: EndReason = current.phase == .running ? .signal : (current.endReason ?? .signal)
        var owned: Session? = current
        stop(session: &owned, reason: reason, sample: sample, effects: effects)
        session = owned
    }

    private static func endsAt(_ length: SessionLength, now: Int64) -> Int64? {
        switch length {
        case .indefinite:
            return nil
        case .timed(let seconds):
            return now + Int64(seconds) * 1000
        }
    }

    private static func shouldNotify(_ reason: EndReason) -> Bool {
        switch reason {
        case .timer, .battery, .thermal, .signal: return true
        case .user, .quit: return false
        }
    }

    private static func closeLid(_ session: inout Session, policy: Policy, apps: [AppInfo], effects: SessionEffects) {
        enableLowPowerIfAllowed(&session, policy: policy, effects: effects)
        syncFreeze(&session, policy: policy, apps: apps, effects: effects)
        engageQuiet(&session, effects: effects)
    }

    private static func openLid(_ session: inout Session, effects: SessionEffects) {
        thawAll(&session, effects: effects)
        restoreQuiet(&session, effects: effects)
        restoreLowPower(&session, effects: effects)
    }

    private static func syncFreeze(_ session: inout Session, policy: Policy, apps: [AppInfo], effects: SessionEffects) {
        let targets = AwakePolicy.selectFreezeTargets(apps, policy: policy)
        let wanted = Set(targets.map(\.pid))
        let stale = session.frozen.filter { !wanted.contains($0.pid) }
        for app in stale {
            effects.thaw(app)
        }
        if !stale.isEmpty {
            effects.log("freeze.thaw count=\(stale.count)")
        }
        let already = Set(session.frozen.map(\.pid)).subtracting(stale.map(\.pid))
        let extra = targets.filter { !already.contains($0.pid) }
        for app in extra {
            effects.freeze(app)
        }
        if !extra.isEmpty {
            effects.log("freeze.stop count=\(extra.count)")
        }
        session.frozen = targets.map { FrozenApp(pid: $0.pid, bundleId: $0.bundleId, name: $0.name) }
    }

    private static func thawAll(_ session: inout Session, effects: SessionEffects) {
        for app in session.frozen {
            effects.thaw(app)
        }
        effects.log("freeze.thaw count=\(session.frozen.count)")
        session.frozen = []
    }

    private static func engageQuiet(_ session: inout Session, effects: SessionEffects) {
        guard !session.quietApplied else { return }
        let current = effects.readQuiet()
        let display: Double? = current.display == nil ? nil : 0
        let keyboard: Double? = current.keyboard == nil ? nil : 0
        let muted: Bool? = current.muted == nil ? nil : true
        effects.writeQuiet(display: display, keyboard: keyboard, muted: muted)
        session.savedDisplay = current.display
        session.savedKeyboard = current.keyboard
        session.savedMuted = current.muted
        session.quietApplied = display != nil || keyboard != nil || muted != nil
        if session.quietApplied { effects.log("lid.quiet") }
    }

    private static func restoreQuiet(_ session: inout Session, effects: SessionEffects) {
        guard session.quietApplied else { return }
        effects.writeQuiet(display: session.savedDisplay, keyboard: session.savedKeyboard, muted: session.savedMuted)
        session.quietApplied = false
        session.savedDisplay = nil
        session.savedKeyboard = nil
        session.savedMuted = nil
        effects.log("lid.restore")
    }

    private static func enableLowPowerIfAllowed(_ session: inout Session, policy: Policy, effects: SessionEffects) {
        guard policy.lowPowerOnLidClose else { return }
        guard AwakePolicy.canToggleLowPower(policy.privilege) else {
            effects.log("lowpower.skip privilege=\(policy.privilege.rawValue)")
            return
        }
        guard !session.lowPowerApplied, effects.lowPowerMode != 1 else { return }
        let previous = effects.lowPowerMode == 1 ? 1 : 0
        guard effects.setLowPowerMode(1) else { return }
        session.previousLowPowerMode = previous
        session.lowPowerApplied = true
    }

    private static func restoreLowPower(_ session: inout Session, effects: SessionEffects) {
        guard session.lowPowerApplied else { return }
        let target = session.previousLowPowerMode ?? 0
        guard effects.setLowPowerMode(target) else { return }
        session.lowPowerApplied = false
        session.previousLowPowerMode = nil
    }

    private static func considerHotspot(
        _ session: inout Session,
        policy: Policy,
        networkSatisfied: Bool,
        effects: SessionEffects
    ) {
        if networkSatisfied {
            session.hotspotArmed = false
            return
        }
        let ssid = policy.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard policy.hotspotEnabled, !ssid.isEmpty, !session.hotspotArmed else { return }
        switch effects.joinHotspot(ssid: ssid) {
        case .joined:
            effects.log("hotspot.join ssid=\(ssid)")
            session.hotspotArmed = true
        case .noSecret:
            effects.log("hotspot.skip reason=no-keychain-item")
            session.hotspotArmed = true
        case .failed:
            effects.log("hotspot.fail")
            session.hotspotArmed = true
        }
    }

    private static func restore(
        _ session: Session,
        reason: EndReason,
        battery: Int?,
        notify: Bool,
        effects: SessionEffects
    ) -> Session {
        var next = session
        thawAll(&next, effects: effects)
        restoreQuiet(&next, effects: effects)

        if next.lowPowerApplied {
            let target = next.previousLowPowerMode ?? 0
            if effects.setLowPowerMode(target) {
                next.lowPowerApplied = false
                next.previousLowPowerMode = nil
            }
        }
        if next.disableSleepApplied {
            if effects.setDisableSleep(next.previousDisableSleep) {
                next.disableSleepApplied = false
            }
        }
        if next.assertionsHeld {
            effects.releaseAssertions()
            effects.log("assertions.release")
            next.assertionsHeld = false
        }

        let pending = next.lowPowerApplied || next.disableSleepApplied
        next.phase = pending ? .restorePending : .ended
        next.endReason = reason
        next.batteryAtEnd = battery
        effects.log(pending ? "session.restore-pending reason=\(reason.rawValue)" : "session.end reason=\(reason.rawValue)")
        if notify, let copy = AwakeCommands.autoEndCopy(reason: reason, battery: battery) {
            effects.notify(title: copy.title, body: copy.body)
        }
        return next
    }
}

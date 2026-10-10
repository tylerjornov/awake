import Foundation

public enum PrivilegeMode: String, Codable, Equatable, Sendable {
    case prompt
    case sudoers
    case unavailable
}

public enum EndReason: String, Codable, Equatable, Sendable {
    case user
    case timer
    case battery
    case thermal
    case quit
    case signal
}

public enum ThermalState: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public var endsSession: Bool { self == .serious || self == .critical }
}

public enum SessionPhase: String, Codable, Equatable, Sendable {
    case running
    case restorePending
    case ended
}

public enum SessionLength: Equatable, Sendable {
    case indefinite
    case timed(seconds: Int)
}

public struct Policy: Codable, Equatable, Sendable {
    public var batteryFloorPercent: Int
    public var freezeBundleIds: [String]
    public var freezeOtherDockApps: Bool
    public var allowBundleIds: [String]
    public var lowPowerOnLidClose: Bool
    public var privilege: PrivilegeMode
    public var hotspotEnabled: Bool
    public var hotspotSSID: String
    /// Automatic mirrors Insomnia: chat apps pause, agent hosts stay up.
    /// Manual pauses only the bundle IDs you marked.
    public var selectionMode: SelectionMode
    public var manualPausedBundleIds: [String]

    public init(
        batteryFloorPercent: Int = Policy.defaultFloor,
        freezeBundleIds: [String] = Policy.defaultFreeze,
        freezeOtherDockApps: Bool = false,
        allowBundleIds: [String] = [],
        lowPowerOnLidClose: Bool = true,
        privilege: PrivilegeMode = .prompt,
        hotspotEnabled: Bool = false,
        hotspotSSID: String = "",
        selectionMode: SelectionMode = .automatic,
        manualPausedBundleIds: [String] = []
    ) {
        self.batteryFloorPercent = batteryFloorPercent
        self.freezeBundleIds = freezeBundleIds
        self.freezeOtherDockApps = freezeOtherDockApps
        self.allowBundleIds = allowBundleIds
        self.lowPowerOnLidClose = lowPowerOnLidClose
        self.privilege = privilege
        self.hotspotEnabled = hotspotEnabled
        self.hotspotSSID = hotspotSSID
        self.selectionMode = selectionMode
        self.manualPausedBundleIds = manualPausedBundleIds
    }

    public static let defaultFloor = 18
    public static let maxDurationSeconds = 14 * 24 * 60 * 60

    public static let defaultFreeze = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "net.whatsapp.WhatsApp",
    ]

    /// On-disk shape. Hotspot passwords are never a field here.
    public func forDisk() -> Policy { self }

    private enum CodingKeys: String, CodingKey {
        case batteryFloorPercent, freezeBundleIds, freezeOtherDockApps, allowBundleIds
        case lowPowerOnLidClose, privilege, hotspotEnabled, hotspotSSID
        case selectionMode, manualPausedBundleIds
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        batteryFloorPercent = try keys.decodeIfPresent(Int.self, forKey: .batteryFloorPercent) ?? Policy.defaultFloor
        freezeBundleIds = try keys.decodeIfPresent([String].self, forKey: .freezeBundleIds) ?? Policy.defaultFreeze
        freezeOtherDockApps = try keys.decodeIfPresent(Bool.self, forKey: .freezeOtherDockApps) ?? false
        allowBundleIds = try keys.decodeIfPresent([String].self, forKey: .allowBundleIds) ?? []
        lowPowerOnLidClose = try keys.decodeIfPresent(Bool.self, forKey: .lowPowerOnLidClose) ?? true
        privilege = try keys.decodeIfPresent(PrivilegeMode.self, forKey: .privilege) ?? .prompt
        hotspotEnabled = try keys.decodeIfPresent(Bool.self, forKey: .hotspotEnabled) ?? false
        hotspotSSID = try keys.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? ""
        selectionMode = try keys.decodeIfPresent(SelectionMode.self, forKey: .selectionMode) ?? .automatic
        manualPausedBundleIds = try keys.decodeIfPresent([String].self, forKey: .manualPausedBundleIds) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(batteryFloorPercent, forKey: .batteryFloorPercent)
        try keys.encode(freezeBundleIds, forKey: .freezeBundleIds)
        try keys.encode(freezeOtherDockApps, forKey: .freezeOtherDockApps)
        try keys.encode(allowBundleIds, forKey: .allowBundleIds)
        try keys.encode(lowPowerOnLidClose, forKey: .lowPowerOnLidClose)
        try keys.encode(privilege, forKey: .privilege)
        try keys.encode(hotspotEnabled, forKey: .hotspotEnabled)
        try keys.encode(hotspotSSID, forKey: .hotspotSSID)
        try keys.encode(selectionMode, forKey: .selectionMode)
        try keys.encode(manualPausedBundleIds, forKey: .manualPausedBundleIds)
    }
}

public struct AppInfo: Equatable, Sendable {
    public var pid: Int32
    public var bundleId: String
    public var name: String
    public var onDock: Bool
    public var running: Bool

    public init(pid: Int32, bundleId: String, name: String, onDock: Bool, running: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.onDock = onDock
        self.running = running
    }
}

public struct FrozenApp: Codable, Equatable, Sendable {
    public var pid: Int32
    public var bundleId: String
    public var name: String

    public init(pid: Int32, bundleId: String, name: String) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var ownerPid: Int32
    public var startedAtMs: Int64
    public var endsAtMs: Int64?
    public var previousDisableSleep: Int
    public var disableSleepApplied: Bool
    public var previousLowPowerMode: Int?
    public var lowPowerApplied: Bool
    public var frozen: [FrozenApp]
    public var assertionsHeld: Bool
    public var phase: SessionPhase
    public var endReason: EndReason?
    public var observedLidClosed: Bool
    public var hotspotArmed: Bool
    public var batteryAtEnd: Int?
    public var quietApplied: Bool
    public var savedDisplay: Double?
    public var savedKeyboard: Double?
    public var savedMuted: Bool?

    public init(
        ownerPid: Int32,
        startedAtMs: Int64,
        endsAtMs: Int64?,
        previousDisableSleep: Int,
        disableSleepApplied: Bool,
        previousLowPowerMode: Int?,
        lowPowerApplied: Bool,
        frozen: [FrozenApp],
        assertionsHeld: Bool,
        phase: SessionPhase,
        endReason: EndReason?,
        observedLidClosed: Bool,
        hotspotArmed: Bool,
        batteryAtEnd: Int?,
        quietApplied: Bool = false,
        savedDisplay: Double? = nil,
        savedKeyboard: Double? = nil,
        savedMuted: Bool? = nil
    ) {
        self.ownerPid = ownerPid
        self.startedAtMs = startedAtMs
        self.endsAtMs = endsAtMs
        self.previousDisableSleep = previousDisableSleep
        self.disableSleepApplied = disableSleepApplied
        self.previousLowPowerMode = previousLowPowerMode
        self.lowPowerApplied = lowPowerApplied
        self.frozen = frozen
        self.assertionsHeld = assertionsHeld
        self.phase = phase
        self.endReason = endReason
        self.observedLidClosed = observedLidClosed
        self.hotspotArmed = hotspotArmed
        self.batteryAtEnd = batteryAtEnd
        self.quietApplied = quietApplied
        self.savedDisplay = savedDisplay
        self.savedKeyboard = savedKeyboard
        self.savedMuted = savedMuted
    }

    private enum CodingKeys: String, CodingKey {
        case ownerPid, startedAtMs, endsAtMs, previousDisableSleep, disableSleepApplied
        case previousLowPowerMode, lowPowerApplied, frozen, assertionsHeld, phase, endReason
        case observedLidClosed, hotspotArmed, batteryAtEnd
        case quietApplied, savedDisplay, savedKeyboard, savedMuted
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        ownerPid = try keys.decode(Int32.self, forKey: .ownerPid)
        startedAtMs = try keys.decode(Int64.self, forKey: .startedAtMs)
        endsAtMs = try keys.decodeIfPresent(Int64.self, forKey: .endsAtMs)
        previousDisableSleep = try keys.decode(Int.self, forKey: .previousDisableSleep)
        disableSleepApplied = try keys.decode(Bool.self, forKey: .disableSleepApplied)
        previousLowPowerMode = try keys.decodeIfPresent(Int.self, forKey: .previousLowPowerMode)
        lowPowerApplied = try keys.decode(Bool.self, forKey: .lowPowerApplied)
        frozen = try keys.decode([FrozenApp].self, forKey: .frozen)
        assertionsHeld = try keys.decode(Bool.self, forKey: .assertionsHeld)
        phase = try keys.decode(SessionPhase.self, forKey: .phase)
        endReason = try keys.decodeIfPresent(EndReason.self, forKey: .endReason)
        observedLidClosed = try keys.decode(Bool.self, forKey: .observedLidClosed)
        hotspotArmed = try keys.decode(Bool.self, forKey: .hotspotArmed)
        batteryAtEnd = try keys.decodeIfPresent(Int.self, forKey: .batteryAtEnd)
        quietApplied = try keys.decodeIfPresent(Bool.self, forKey: .quietApplied) ?? false
        savedDisplay = try keys.decodeIfPresent(Double.self, forKey: .savedDisplay)
        savedKeyboard = try keys.decodeIfPresent(Double.self, forKey: .savedKeyboard)
        savedMuted = try keys.decodeIfPresent(Bool.self, forKey: .savedMuted)
    }

    public func encode(to encoder: Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(ownerPid, forKey: .ownerPid)
        try keys.encode(startedAtMs, forKey: .startedAtMs)
        try keys.encodeIfPresent(endsAtMs, forKey: .endsAtMs)
        try keys.encode(previousDisableSleep, forKey: .previousDisableSleep)
        try keys.encode(disableSleepApplied, forKey: .disableSleepApplied)
        try keys.encodeIfPresent(previousLowPowerMode, forKey: .previousLowPowerMode)
        try keys.encode(lowPowerApplied, forKey: .lowPowerApplied)
        try keys.encode(frozen, forKey: .frozen)
        try keys.encode(assertionsHeld, forKey: .assertionsHeld)
        try keys.encode(phase, forKey: .phase)
        try keys.encodeIfPresent(endReason, forKey: .endReason)
        try keys.encode(observedLidClosed, forKey: .observedLidClosed)
        try keys.encode(hotspotArmed, forKey: .hotspotArmed)
        try keys.encodeIfPresent(batteryAtEnd, forKey: .batteryAtEnd)
        try keys.encode(quietApplied, forKey: .quietApplied)
        try keys.encodeIfPresent(savedDisplay, forKey: .savedDisplay)
        try keys.encodeIfPresent(savedKeyboard, forKey: .savedKeyboard)
        try keys.encodeIfPresent(savedMuted, forKey: .savedMuted)
    }
}

public struct MachineSample: Equatable, Sendable {
    public var nowMs: Int64
    public var batteryPercent: Int?
    public var lidClosed: Bool
    public var thermal: ThermalState
    public var networkSatisfied: Bool
    public var lowPowerMode: Int
    public var disableSleep: Int

    public init(
        nowMs: Int64,
        batteryPercent: Int?,
        lidClosed: Bool,
        thermal: ThermalState,
        networkSatisfied: Bool,
        lowPowerMode: Int,
        disableSleep: Int
    ) {
        self.nowMs = nowMs
        self.batteryPercent = batteryPercent
        self.lidClosed = lidClosed
        self.thermal = thermal
        self.networkSatisfied = networkSatisfied
        self.lowPowerMode = lowPowerMode
        self.disableSleep = disableSleep
    }
}

public struct AutoEndCopy: Equatable, Sendable {
    public var title: String
    public var body: String
}

public enum AwakeError: Error, Equatable, CustomStringConvertible {
    case alreadyActive
    case invalid(String)
    case power(String)

    public var description: String {
        switch self {
        case .alreadyActive:
            return "A session is already running or still restoring."
        case .invalid(let message), .power(let message):
            return message
        }
    }
}

public enum PmsetFault: Equatable, Sendable {
    case disableSleep
    case lowPower
}

public enum SelectionMode: String, Codable, Equatable, Sendable {
    case automatic
    case manual
}

public struct QuietLevels: Equatable, Sendable {
    public var display: Double?
    public var keyboard: Double?
    public var muted: Bool?

    public init(display: Double? = nil, keyboard: Double? = nil, muted: Bool? = nil) {
        self.display = display
        self.keyboard = keyboard
        self.muted = muted
    }
}

public enum HotspotResult: Equatable, Sendable {
    case joined
    case noSecret
    case failed
}

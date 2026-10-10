import Foundation

public enum AwakePolicy {
    public static let selfBundleId = "com.awake.menubar"
    public static let protectedBundleIds: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.SystemUIServer",
        "com.apple.controlcenter",
        "com.apple.loginwindow",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        selfBundleId,
    ]
    public static let allowPrefixes = ["com.jetbrains.", "us.zoom.", "com.cisco.webex."]

    /// Agent hosts, editors, terminals, browsers, password managers, local
    /// databases, Tailscale, and model servers. Apple apps are excluded by prefix.
    public static let keptBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "com.google.android.studio",
        "com.sublimetext.4",
        "com.panic.Nova",
        "dev.zed.Zed",
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.tabby",
        "co.zeit.hyper",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "io.tailscale.ipn.macsys",
        "io.tailscale.ipn.macos",
        "com.docker.docker",
        "dev.orbstack.OrbStack",
        "com.postgresapp.Postgres2",
        "com.ollama.ollama",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "Cisco-Systems.Spark",
        "com.obsproject.obs-studio",
        "com.loom.desktop",
    ]

    public static func isProtected(_ bundleId: String) -> Bool {
        protectedBundleIds.contains(bundleId)
    }

    /// System UI, this app, and every Apple bundle. Never paused.
    public static func isUntouchable(_ bundleId: String) -> Bool {
        bundleId == selfBundleId || bundleId.hasPrefix("com.apple.") || isProtected(bundleId)
    }

    public static func isKept(_ bundleId: String, extras: [String]) -> Bool {
        if extras.contains(bundleId) || keptBundleIds.contains(bundleId) { return true }
        if bundleId.hasPrefix("com.apple.") { return true }
        return allowPrefixes.contains { bundleId.hasPrefix($0) }
    }

    /// Automatic: pause the freeze list, and optionally every other Dock app that is not an agent host.
    /// Manual: pause only bundle IDs the user marked. An explicit freeze entry beats the kept list.
    /// Untouchable apps are never paused.
    public static func selectFreezeTargets(_ apps: [AppInfo], policy: Policy) -> [AppInfo] {
        let explicit = Set(policy.freezeBundleIds)
        let manual = Set(policy.manualPausedBundleIds)
        var chosen: [AppInfo] = []
        var seen = Set<Int32>()
        for app in apps {
            if !app.running || app.pid <= 1 || seen.contains(app.pid) { continue }
            if isUntouchable(app.bundleId) { continue }
            let take: Bool
            if policy.selectionMode == .manual {
                take = manual.contains(app.bundleId)
            } else if explicit.contains(app.bundleId) {
                take = true
            } else {
                take = policy.freezeOtherDockApps
                    && app.onDock
                    && !isKept(app.bundleId, extras: policy.allowBundleIds)
            }
            if take {
                seen.insert(app.pid)
                chosen.append(app)
            }
        }
        return chosen
    }

    public static func canToggleLowPower(_ privilege: PrivilegeMode) -> Bool {
        privilege == .prompt
    }

    public static func validateStart(_ policy: Policy, length: SessionLength) -> String? {
        if policy.privilege == .unavailable {
            return "No privilege path for pmset. Refusing to start on idle assertions alone — lid close would still sleep the Mac."
        }
        if policy.batteryFloorPercent < 5 || policy.batteryFloorPercent > 50 {
            return "Battery floor must be between 5 and 50."
        }
        if case .timed(let seconds) = length {
            if seconds <= 0 { return "Set a duration, or choose until you stop it." }
            if seconds > Policy.maxDurationSeconds { return "Duration is capped at 14 days." }
        }
        return nil
    }
}

public enum AwakeCommands {
    public static func disableSleep(_ value: Int) -> [String] {
        ["/usr/bin/pmset", "-a", "disablesleep", value == 1 ? "1" : "0"]
    }

    public static func sudoDisableSleep(_ value: Int) -> [String] {
        ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", value == 1 ? "1" : "0"]
    }

    public static func lowPower(_ value: Int) -> [String] {
        ["/usr/bin/pmset", "-b", "lowpowermode", value == 1 ? "1" : "0"]
    }

    public static func isSudoersAllowed(_ argv: [String]) -> Bool {
        let joined = argv.joined(separator: " ")
        return joined == "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"
            || joined == "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1"
    }

    public static func sudoersRuleLine(username: String) throws -> String {
        let pattern = #"^[A-Za-z_][A-Za-z0-9._-]{0,31}$"#
        guard username.range(of: pattern, options: .regularExpression) != nil else {
            throw AwakeError.invalid("Refusing unsafe username: \(username)")
        }
        return "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    }

    public static func sudoersFileContents(username: String) throws -> String {
        let rule = try sudoersRuleLine(username: username)
        return """
        # Awake — strictly scoped. Allows only disablesleep 0 and 1.
        # Uninstall: sudo rm /etc/sudoers.d/awake
        \(rule)

        """
    }

    public static func parseDisableSleep(_ output: String) -> Int? {
        var found: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let match = line.range(
                of: #"^\s*(disablesleep|sleepdisabled)\s+(\d+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            let text = String(line[match])
            found = text.split(whereSeparator: \.isWhitespace).last == "1" ? 1 : 0
        }
        return found
    }

    public static func parseLowPowerMode(_ output: String) -> Int? {
        var found: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let match = line.range(
                of: #"^\s*lowpowermode\s+(\d+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            let text = String(line[match])
            found = text.split(whereSeparator: \.isWhitespace).last == "1" ? 1 : 0
        }
        return found
    }

    public static func redactLog(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"password=\S+"#,
            with: "password=[redacted]",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    public static func formatRemaining(endsAtMs: Int64?, nowMs: Int64) -> String {
        guard let endsAtMs else { return "On" }
        let delta = max(Int64(0), endsAtMs - nowMs)
        let totalSec = Int((delta + 999) / 1000)
        let days = totalSec / 86_400
        let hours = (totalSec % 86_400) / 3600
        let minutes = (totalSec % 3600) / 60
        let seconds = totalSec % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes):" + String(format: "%02d", seconds)
    }

    public static func autoEndCopy(reason: EndReason, battery: Int?) -> AutoEndCopy? {
        switch reason {
        case .timer:
            return AutoEndCopy(title: "Awake ended", body: "Timer finished. Sleep settings restored.")
        case .battery:
            return AutoEndCopy(
                title: "Awake ended",
                body: "Battery at \(battery ?? 0)%. Session ended and sleep restored."
            )
        case .thermal:
            return AutoEndCopy(
                title: "Awake ended",
                body: "Thermal pressure is too high. Session ended and sleep restored."
            )
        case .signal:
            return AutoEndCopy(title: "Awake ended", body: "Interrupted. Sleep settings restored.")
        case .user, .quit:
            return nil
        }
    }
}

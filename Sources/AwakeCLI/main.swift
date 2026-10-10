import AppKit
import Foundation
import AwakeCore
import AwakeMac

@main
enum CLIMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let invoked = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        var args = Array(CommandLine.arguments.dropFirst())
        if invoked == "asleep" {
            args = ["stop"]
        }
        let command = args.first ?? "help"
        switch command {
        case "start":
            start(Array(args.dropFirst()))
        case "extend":
            extend(Array(args.dropFirst()))
        case "stop":
            stop()
        case "status":
            status()
        case "help", "-h", "--help":
            print(help)
            exit(0)
        default:
            fputs("Unknown command \(command)\n\(help)", stderr)
            exit(2)
        }
    }

    static func start(_ args: [String]) {
        let parsed = duration(args)
        if let error = parsed.error {
            fputs(error + "\n", stderr)
            exit(2)
        }
        let command = ControlCommand(op: "start", seconds: parsed.seconds, indefinite: parsed.indefinite)
        if let reply = SessionController.send(command) {
            if reply.ok {
                print(reply.title ?? "Started.")
                exit(0)
            }
            fputs((reply.error ?? "Could not start.") + "\n", stderr)
            exit(1)
        }
        let controller = SessionController.shared
        controller.activate()
        guard controller.isController else {
            fputs("Could not take the controller lock.\n", stderr)
            exit(1)
        }
        controller.onUpdate = {
            guard controller.session?.phase != .running else { return }
            let code: Int32 = controller.session?.phase == .ended ? 0 : 1
            if let error = controller.lastError, code != 0 {
                fputs(error + "\n", stderr)
            } else if let reason = controller.session?.endReason {
                print("Ended (\(reason.rawValue)).")
            }
            controller.shutdown()
            exit(code)
        }
        let length: SessionLength = parsed.indefinite ? .indefinite : .timed(seconds: parsed.seconds ?? 0)
        controller.start(length)
        if let error = controller.lastError {
            fputs(error + "\n", stderr)
            controller.shutdown()
            exit(1)
        }
        print("Session running. \(controller.menuTitle()). Ctrl-C restores sleep.")
        dispatchMain()
    }

    static func extend(_ args: [String]) {
        let parsed = duration(args)
        guard parsed.error == nil, let seconds = parsed.seconds, seconds > 0, !parsed.indefinite else {
            fputs("Usage: awake extend [--days n] [--hours n] [--minutes n]\n", stderr)
            exit(2)
        }
        guard let reply = SessionController.send(ControlCommand(op: "extend", seconds: seconds)) else {
            fputs("No Awake controller is running.\n", stderr)
            exit(1)
        }
        if reply.ok {
            print(reply.title ?? "Extended.")
            exit(0)
        }
        fputs((reply.error ?? "Could not extend.") + "\n", stderr)
        exit(1)
    }

    static func stop() {
        if let reply = SessionController.send(ControlCommand(op: "stop")) {
            print(reply.ok ? "Stopped." : (reply.error ?? "Stop failed."))
            exit(reply.ok ? 0 : 1)
        }
        let controller = SessionController.shared
        controller.activate()
        if controller.session?.phase == .running || controller.session?.phase == .restorePending {
            controller.end(.user)
        }
        controller.shutdown()
        print("No running session.")
        exit(0)
    }

    static func status() {
        if let reply = SessionController.send(ControlCommand(op: "status")) {
            let phase = reply.phase ?? "unknown"
            let title = reply.title ?? ""
            print("\(phase) \(title)".trimmingCharacters(in: .whitespaces))
            exit(0)
        }
        print("idle")
        exit(0)
    }

    static func duration(_ args: [String]) -> (seconds: Int?, indefinite: Bool, error: String?) {
        var days = 0
        var hours = 0
        var minutes = 0
        var indefinite = false
        var index = 0
        while index < args.count {
            let flag = args[index]
            if flag == "--until-stop" {
                indefinite = true
                index += 1
                continue
            }
            let flags = ["--days": 86_400, "--hours": 3_600, "--minutes": 60]
            guard let unit = flags[flag], index + 1 < args.count, let value = Int(args[index + 1]), value >= 0 else {
                return (nil, false, "Usage: awake start [--days n] [--hours n] [--minutes n] [--until-stop]")
            }
            if flag == "--days" { days = value }
            if flag == "--hours" { hours = value }
            if flag == "--minutes" { minutes = value }
            _ = unit
            index += 2
        }
        if indefinite && (days + hours + minutes) > 0 {
            return (nil, false, "Use either a duration or --until-stop, not both.")
        }
        if indefinite { return (nil, true, nil) }
        let seconds = days * 86_400 + hours * 3_600 + minutes * 60
        if seconds <= 0 {
            return (nil, false, "Set --days, --hours, or --minutes, or pass --until-stop.")
        }
        return (seconds, false, nil)
    }

    static let help = """
    awake start [--days n] [--hours n] [--minutes n]
    awake start --until-stop
    awake extend [--days n] [--hours n] [--minutes n]
    awake stop
    awake status
    asleep

    If the menu-bar app is running, commands are sent to it.
    Otherwise `awake start` holds the session in this process until it ends.
    """
}

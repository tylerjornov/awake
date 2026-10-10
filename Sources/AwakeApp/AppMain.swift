import AppKit
import AwakeCore
import AwakeMac

private let appDelegate = AppDelegate()

@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = SessionController.shared
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindow?
    private var duration: DurationWindow?
    private var uiTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onUpdate = { [weak self] in self?.refreshTitle() }
        controller.activate()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = eyeImage()
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshTitle()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func refreshTitle() {
        let title: String
        if controller.isController {
            title = controller.menuTitle()
        } else if let reply = SessionController.send(ControlCommand(op: "status")) {
            title = reply.title ?? "Awake"
        } else {
            title = "Awake"
        }
        statusItem.button?.title = " " + title
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: headerTitle(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let error = controller.lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let start = NSMenuItem(title: "Start Session", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        addStart(submenu, "30 Minutes", seconds: 30 * 60)
        addStart(submenu, "1 Hour", seconds: 60 * 60)
        addStart(submenu, "2 Hours", seconds: 2 * 60 * 60)
        addStart(submenu, "4 Hours", seconds: 4 * 60 * 60)
        addStart(submenu, "8 Hours", seconds: 8 * 60 * 60)
        submenu.addItem(item("Until I Stop It", action: #selector(startIndefinite)))
        submenu.addItem(item("Custom…", action: #selector(showCustom)))
        start.submenu = submenu
        menu.addItem(start)
        menu.addItem(item("Extend 30 Minutes", action: #selector(extendHalf)))
        menu.addItem(item("Extend 1 Hour", action: #selector(extendHour)))
        menu.addItem(item("End Session", action: #selector(endSession)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettings)))
        menu.addItem(item("Quit Awake", action: #selector(quit), key: "q"))
    }

    private func addStart(_ menu: NSMenu, _ title: String, seconds: Int) {
        let item = NSMenuItem(title: title, action: #selector(startPreset(_:)), keyEquivalent: "")
        item.target = self
        item.tag = seconds
        menu.addItem(item)
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func headerTitle() -> String {
        if !controller.isController { return "Awake · another controller is active" }
        switch controller.session?.phase {
        case .running:
            return "Awake · \(controller.menuTitle())"
        case .restorePending:
            return "Awake · restore did not finish"
        default:
            return "Awake · idle"
        }
    }

    @objc private func startPreset(_ sender: NSMenuItem) {
        begin(.timed(seconds: sender.tag), indefinite: false, seconds: sender.tag)
    }

    @objc private func startIndefinite() {
        begin(.indefinite, indefinite: true, seconds: nil)
    }

    @objc private func showCustom() {
        let window = duration ?? DurationWindow { [weak self] seconds in
            self?.begin(.timed(seconds: seconds), indefinite: false, seconds: seconds)
        }
        duration = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func extendHalf() { extend(30 * 60) }
    @objc private func extendHour() { extend(60 * 60) }

    @objc private func endSession() {
        if controller.isController {
            controller.end(.user)
        } else {
            _ = SessionController.send(ControlCommand(op: "stop"))
        }
        refreshTitle()
    }

    @objc private func showSettings() {
        let window = settings ?? SettingsWindow(controller: controller)
        settings = window
        window.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func begin(_ length: SessionLength, indefinite: Bool, seconds: Int?) {
        if controller.isController {
            controller.start(length)
            if let error = controller.lastError { alert(error) }
        } else if let reply = SessionController.send(
            ControlCommand(op: "start", seconds: seconds, indefinite: indefinite)
        ) {
            if !reply.ok { alert(reply.error ?? "Could not start.") }
        } else {
            alert("No Awake controller is running.")
        }
        refreshTitle()
    }

    private func extend(_ seconds: Int) {
        if controller.isController {
            controller.extend(seconds: seconds)
            if let error = controller.lastError { alert(error) }
        } else if let reply = SessionController.send(ControlCommand(op: "extend", seconds: seconds)), !reply.ok {
            alert(reply.error ?? "Could not extend.")
        }
        refreshTitle()
    }

    private func alert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Awake"
        alert.informativeText = text
        alert.runModal()
    }
}

private func eyeImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let eye = NSBezierPath(ovalIn: NSRect(x: 1, y: 5.5, width: 16, height: 7))
        eye.lineWidth = 1.5
        eye.stroke()
        NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4)).fill()
        return true
    }
    image.isTemplate = true
    return image
}

final class DurationWindow: NSWindow {
    private let days = NSTextField(string: "0")
    private let hours = NSTextField(string: "1")
    private let minutes = NSTextField(string: "0")
    private let onStart: (Int) -> Void

    init(onStart: @escaping (Int) -> Void) {
        self.onStart = onStart
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 168),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Session Length"
        isReleasedWhenClosed = false
        center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row("Days", days))
        stack.addArrangedSubview(row("Hours", hours))
        stack.addArrangedSubview(row("Minutes", minutes))
        let start = NSButton(title: "Start", target: self, action: #selector(start))
        start.bezelStyle = .rounded
        stack.addArrangedSubview(start)
        contentView = NSView()
        contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 16),
        ])
    }

    private func row(_ label: String, _ field: NSTextField) -> NSView {
        field.frame.size = NSSize(width: 80, height: 24)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let text = NSTextField(labelWithString: label)
        text.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let line = NSStackView(views: [text, field])
        line.orientation = .horizontal
        return line
    }

    @objc private func start() {
        let total = (Int(days.stringValue) ?? 0) * 86_400
            + (Int(hours.stringValue) ?? 0) * 3_600
            + (Int(minutes.stringValue) ?? 0) * 60
        guard total > 0 else { return }
        onStart(total)
        close()
    }
}

final class SettingsWindow: NSWindow {
    private let controller: SessionController
    private let floor = NSSlider(value: 18, minValue: 5, maxValue: 50, target: nil, action: nil)
    private let floorLabel = NSTextField(labelWithString: "18%")
    private let mode = NSSegmentedControl(labels: ["Automatic", "Manual"], trackingMode: .selectOne, target: nil, action: nil)
    private let autoNote = NSTextField(wrappingLabelWithString: "")
    private let freezeOthers = NSButton(checkboxWithTitle: "Also pause every other Dock app", target: nil, action: nil)
    private let manualIntro = NSTextField(wrappingLabelWithString: "Checked apps stay running. Uncheck an app to pause it when the lid closes.")
    private let manualStack = NSStackView()
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let lowPower = NSButton(checkboxWithTitle: "Low Power Mode when the lid closes", target: nil, action: nil)
    private let privilege = NSPopUpButton()
    private let hotspot = NSButton(checkboxWithTitle: "Join a hotspot if Wi-Fi drops", target: nil, action: nil)
    private let ssid = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private var rows: [(id: String, box: NSButton)] = []

    init(controller: SessionController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Awake Settings"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 480)
        center()
        privilege.addItems(withTitles: ["Ask for an admin password", "Passwordless sudoers rule"])
        floor.target = self
        floor.action = #selector(floorMoved)
        mode.target = self
        mode.action = #selector(modeChanged)
        freezeOthers.target = self
        freezeOthers.action = #selector(previewChanged)
        autoNote.maximumNumberOfLines = 6
        manualIntro.maximumNumberOfLines = 3
        preview.maximumNumberOfLines = 4
        note.maximumNumberOfLines = 5
        for label in [autoNote, manualIntro, preview, note] {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        autoNote.stringValue = "Slack, WhatsApp, and Discord pause when the lid closes. Editors, terminals, browsers, AI apps, password managers, Tailscale, local databases, model servers, JetBrains, and Apple apps stay running."
        manualStack.orientation = .vertical
        manualStack.alignment = .leading
        manualStack.spacing = 4

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        let install = NSButton(title: "Install Sudoers Rule…", target: self, action: #selector(installRule))
        let remove = NSButton(title: "Remove Sudoers Rule…", target: self, action: #selector(removeRule))
        let forget = NSButton(title: "Delete Local Data…", target: self, action: #selector(deleteLocal))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(NSTextField(labelWithString: "Which apps stay awake"))
        stack.addArrangedSubview(mode)
        stack.addArrangedSubview(autoNote)
        stack.addArrangedSubview(freezeOthers)
        stack.addArrangedSubview(manualIntro)
        stack.addArrangedSubview(manualStack)
        stack.addArrangedSubview(preview)
        stack.addArrangedSubview(NSTextField(labelWithString: "Battery floor"))
        stack.addArrangedSubview(floorRow())
        stack.addArrangedSubview(lowPower)
        stack.addArrangedSubview(NSTextField(labelWithString: "Sleep privilege"))
        stack.addArrangedSubview(privilege)
        stack.addArrangedSubview(install)
        stack.addArrangedSubview(remove)
        stack.addArrangedSubview(hotspot)
        stack.addArrangedSubview(labeled("Hotspot name", ssid))
        stack.addArrangedSubview(labeled("Hotspot password (login Keychain)", password))
        stack.addArrangedSubview(note)
        stack.addArrangedSubview(save)
        stack.addArrangedSubview(forget)

        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = clip
        contentView = NSView()
        contentView?.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            clip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -16),
            ssid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            password.widthAnchor.constraint(equalTo: stack.widthAnchor),
            autoNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            manualIntro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reload()
    }

    func reload() {
        let policy = controller.policy
        floor.doubleValue = Double(policy.batteryFloorPercent)
        floorLabel.stringValue = "\(policy.batteryFloorPercent)%"
        freezeOthers.state = policy.freezeOtherDockApps ? .on : .off
        lowPower.state = policy.lowPowerOnLidClose ? .on : .off
        privilege.selectItem(at: policy.privilege == .sudoers ? 1 : 0)
        hotspot.state = policy.hotspotEnabled ? .on : .off
        ssid.stringValue = policy.hotspotSSID
        password.stringValue = ""
        mode.selectedSegment = policy.selectionMode == .manual ? 1 : 0
        rebuildManual(seedFromAutomatic: false)
        applyModeVisibility()
        refreshPreview()
        note.stringValue = "Closing the lid pauses the apps above, turns the display and keyboard light off, and mutes audio. Opening the lid puts them back. Low Power Mode uses the admin password and is skipped in passwordless mode. The hotspot password stays in the login Keychain."
    }

    private func floorRow() -> NSView {
        floor.translatesAutoresizingMaskIntoConstraints = false
        floor.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return NSStackView(views: [floor, floorLabel])
    }

    private func labeled(_ title: String, _ field: NSTextField) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.addArrangedSubview(NSTextField(labelWithString: title))
        stack.addArrangedSubview(field)
        return stack
    }

    private func applyModeVisibility() {
        let manual = mode.selectedSegment == 1
        autoNote.isHidden = manual
        freezeOthers.isHidden = manual
        manualIntro.isHidden = !manual
        manualStack.isHidden = !manual
    }

    private func rebuildManual(seedFromAutomatic: Bool) {
        for view in manualStack.arrangedSubviews {
            manualStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = []
        var paused = Set(controller.policy.manualPausedBundleIds)
        if seedFromAutomatic && paused.isEmpty {
            var draft = controller.policy
            draft.selectionMode = .automatic
            paused = Set(AwakePolicy.selectFreezeTargets(AppProbe.runningApps(), policy: draft).map(\.bundleId))
        }
        var seen = Set<String>()
        let running = AppProbe.runningApps().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for app in running where seen.insert(app.bundleId).inserted {
            addRow(name: app.name, bundleId: app.bundleId, paused: paused.contains(app.bundleId))
        }
        for id in paused.sorted() where seen.insert(id).inserted {
            addRow(name: id, bundleId: id, paused: true)
        }
    }

    private func addRow(name: String, bundleId: String, paused: Bool) {
        let locked = AwakePolicy.isUntouchable(bundleId)
        let box = NSButton(
            checkboxWithTitle: locked ? "\(name) (always on)" : name,
            target: self,
            action: #selector(previewChanged)
        )
        box.identifier = NSUserInterfaceItemIdentifier(bundleId)
        box.toolTip = bundleId
        box.state = locked || !paused ? .on : .off
        box.isEnabled = !locked
        manualStack.addArrangedSubview(box)
        rows.append((bundleId, box))
    }

    private func pausedSelection() -> [String] {
        rows.compactMap { row in
            guard !AwakePolicy.isUntouchable(row.id), row.box.state == .off else { return nil }
            return row.id
        }
    }

    private func draftPolicy() -> Policy {
        var policy = controller.policy
        policy.selectionMode = mode.selectedSegment == 1 ? .manual : .automatic
        policy.freezeOtherDockApps = freezeOthers.state == .on
        if policy.selectionMode == .manual {
            policy.manualPausedBundleIds = pausedSelection()
        }
        return policy
    }

    private func refreshPreview() {
        let names = AwakePolicy.selectFreezeTargets(AppProbe.runningApps(), policy: draftPolicy()).map(\.name)
        preview.stringValue = names.isEmpty
            ? "Would pause when the lid closes: nothing running."
            : "Would pause when the lid closes: \(names.joined(separator: ", "))."
    }

    @objc private func floorMoved() {
        floorLabel.stringValue = "\(Int(floor.doubleValue.rounded()))%"
    }

    @objc private func modeChanged() {
        if mode.selectedSegment == 1 && controller.policy.manualPausedBundleIds.isEmpty && rows.allSatisfy({ $0.box.state == .on }) {
            rebuildManual(seedFromAutomatic: true)
        }
        applyModeVisibility()
        refreshPreview()
    }

    @objc private func previewChanged() {
        refreshPreview()
    }

    @objc private func save() {
        var policy = draftPolicy()
        policy.batteryFloorPercent = Int(floor.doubleValue.rounded())
        policy.lowPowerOnLidClose = lowPower.state == .on
        policy.privilege = privilege.indexOfSelectedItem == 1 ? .sudoers : .prompt
        policy.hotspotEnabled = hotspot.state == .on
        policy.hotspotSSID = ssid.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if policy.selectionMode == .manual {
            policy.manualPausedBundleIds = pausedSelection()
        }
        controller.policy = policy
        controller.savePolicy()
        if !password.stringValue.isEmpty && !policy.hotspotSSID.isEmpty {
            _ = KeychainStore.save(account: policy.hotspotSSID, secret: password.stringValue)
            password.stringValue = ""
        }
        refreshPreview()
    }

    @objc private func installRule() {
        if let error = SudoersInstaller.install(username: NSUserName()) {
            inform(error)
            return
        }
        privilege.selectItem(at: 1)
        save()
        inform("Installed /etc/sudoers.d/awake for \(NSUserName()). It allows only disablesleep 0 and 1.")
    }

    @objc private func removeRule() {
        if let error = SudoersInstaller.remove() {
            inform(error)
            return
        }
        privilege.selectItem(at: 0)
        save()
        inform("Removed /etc/sudoers.d/awake.")
    }

    @objc private func deleteLocal() {
        controller.end(.quit)
        KeychainStore.deleteAll()
        try? FileManager.default.removeItem(at: SupportPaths.directory)
        inform("Removed ~/Library/Application Support/Awake and the hotspot Keychain items. Quit Awake, delete the app, and remove /etc/sudoers.d/awake if it is still installed.")
    }

    private func inform(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Awake"
        alert.informativeText = text
        alert.beginSheetModal(for: self)
    }
}
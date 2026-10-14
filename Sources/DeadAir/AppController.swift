import AppKit
import AVFoundation
import DeadAirCore
import ServiceManagement

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    /// One monitored microphone.
    private final class Channel {
        let uid: String
        var name: String
        var monitor: InputMonitor?
        var tracker: SilenceTracker
        var health: ChannelHealth = .live
        var lastPeak: Float?
        var openDropout: Dropout.ID?

        init(uid: String, name: String, tracker: SilenceTracker) {
            self.uid = uid
            self.name = name
            self.tracker = tracker
        }
    }

    private static let pollInterval: TimeInterval = 0.1
    private static let maxDropouts = 15

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let settings = Settings()
    private let alertPanel = AlertPanel()
    private var deviceObserver: DeviceListObserver?

    private var armed = false
    private var channels: [String: Channel] = [:]
    private var dropouts: [Dropout] = []
    private var unacknowledgedDropout = false
    /// Start of the current dead-air episode (any channel dead).
    private var deadSince: Date?
    /// Episode whose pop-up has already been shown, so we only show it once.
    private var alertedEpisode: Date?

    private var pollTimer: Timer?
    private var pulseTimer: Timer?
    private var currentIcon: StatusIcon?
    private var menuIsOpen = false
    private var levelItems: [String: NSMenuItem] = [:]
    private var statusLine: NSMenuItem?

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        alertPanel.onDismiss = { [weak self] in self?.alertPanel.hide() }
        alertPanel.onDisarm = { [weak self] in self?.disarm() }
        deviceObserver = DeviceListObserver { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartMonitors() }
        }
        updateStatusItem()
    }

    // MARK: Arming

    private func toggleArmed() {
        armed ? disarm() : arm()
    }

    private func arm() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    if granted { self?.arm() } else { self?.showPermissionAlert() }
                }
            }
            return
        default:
            showPermissionAlert()
            return
        }

        if settings.selectedDevices.isEmpty, let device = AudioSystem.defaultInputDevice() {
            settings.selectedDevices = [device.uid: device.name]
        }
        armed = true
        deadSince = nil
        alertedEpisode = nil
        syncChannels()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        updateStatusItem()
    }

    private func disarm() {
        armed = false
        pollTimer?.invalidate()
        pollTimer = nil
        let now = Date()
        for channel in channels.values { close(channel, at: now) }
        channels.removeAll()
        deadSince = nil
        alertPanel.hide()
        updateStatusItem()
    }

    /// Make `channels` match the selected devices and what's currently plugged in.
    private func syncChannels() {
        guard armed else { return }
        let now = Date()
        let present = Dictionary(AudioSystem.inputDevices().map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let selected = settings.selectedDevices

        for (uid, channel) in channels where selected[uid] == nil {
            close(channel, at: now)
            channels[uid] = nil
        }

        for (uid, savedName) in selected {
            let channel = channels[uid] ?? {
                let channel = Channel(
                    uid: uid, name: savedName,
                    tracker: SilenceTracker(startedAt: now, silenceFloor: settings.silenceFloor))
                channels[uid] = channel
                return channel
            }()

            guard let device = present[uid] else {
                channel.monitor?.stop()
                channel.monitor = nil
                channel.lastPeak = nil
                channel.tracker.markDisconnected(at: now)
                continue
            }
            channel.name = device.name
            if channel.monitor?.device.id != device.id || channel.tracker.isDisconnected {
                channel.monitor?.stop()
                let monitor = InputMonitor(device: device)
                let status = monitor.start()
                if status != noErr {
                    NSLog("Dead Air: couldn't start monitoring \(device.name): OSStatus \(status)")
                }
                // If it failed to start, the tracker reports "no audio" after the stall timeout.
                channel.monitor = status == noErr ? monitor : nil
                channel.tracker.reset(at: now)
            }
        }
    }

    private func restartMonitors() {
        guard armed else { return }
        for channel in channels.values {
            channel.monitor?.stop()
            channel.monitor = nil
        }
        syncChannels()
    }

    private func devicesChanged() {
        syncChannels()
        if menuIsOpen { rebuildMenu() }
    }

    // MARK: Polling

    private func poll() {
        let now = Date()
        for channel in channels.values {
            if let monitor = channel.monitor {
                let meter = monitor.drain()
                let peak: Float? = meter.callbacks > 0 ? meter.peak : nil
                channel.tracker.record(peak: peak, at: now)
                channel.lastPeak = peak
            }
            let health = channel.tracker.health(at: now)
            if case let .dead(reason, since) = health, channel.openDropout == nil {
                let dropout = Dropout(deviceName: channel.name, reason: reason, start: since)
                dropouts.append(dropout)
                if dropouts.count > Self.maxDropouts { dropouts.removeFirst(dropouts.count - Self.maxDropouts) }
                channel.openDropout = dropout.id
            } else if health == .live, channel.openDropout != nil {
                close(channel, at: now)
                unacknowledgedDropout = true
            }
            channel.health = health
        }

        let dead = channels.values.filter { $0.health.isDead }
        let wasDead = deadSince != nil
        deadSince = dead.compactMap { $0.health.deadSince }.min()

        if let deadSince {
            let elapsed = now.timeIntervalSince(deadSince)
            let alertAfter = settings.alertAfter
            if alertAfter != Settings.neverAlert, elapsed >= alertAfter,
               alertedEpisode != deadSince || alertPanel.isVisible {
                if alertedEpisode != deadSince {
                    alertedEpisode = deadSince
                    if settings.playSound { NSSound(named: "Sosumi")?.play() }
                }
                let names = dead.map { "\($0.name) is \($0.health.reasonLabel)" }.joined(separator: ", ")
                alertPanel.showDead(
                    title: "Dead air for \(formatDuration(elapsed))",
                    detail: "\(names) since \(Self.timeFormatter.string(from: deadSince)).")
            }
        } else if wasDead, alertPanel.isVisible, let last = dropouts.last {
            alertPanel.showRecovered(
                title: "Back on air",
                detail: "Lost \(formatDuration(last.duration(at: now))) of audio from "
                    + "\(Self.timeFormatter.string(from: last.start)). Re-record from there.")
        }

        updateStatusItem()
        if menuIsOpen { updateLiveMenuItems() }
    }

    private func close(_ channel: Channel, at now: Date) {
        guard let id = channel.openDropout, let index = dropouts.firstIndex(where: { $0.id == id }) else { return }
        dropouts[index].end = now
        channel.openDropout = nil
    }

    // MARK: Menu bar item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let icon: StatusIcon = !armed ? .disarmed
            : deadSince != nil ? .dead
            : unacknowledgedDropout ? .warning
            : .armed
        if icon != currentIcon {
            button.image = icon.image()
            button.appearsDisabled = icon == .disarmed
            currentIcon = icon
        }

        if let deadSince {
            button.attributedTitle = NSAttributedString(
                string: " DEAD AIR \(formatDuration(Date().timeIntervalSince(deadSince)))",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold),
                ])
            startPulsing()
        } else {
            button.title = ""
            stopPulsing()
        }
    }

    /// A gentle ~1.2s breathing pulse — noticeable in peripheral vision, not strobing.
    private func startPulsing() {
        guard pulseTimer == nil else { return }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let phase = Date().timeIntervalSince(start) * 2 * .pi / 1.2
                self?.statusItem.button?.alphaValue = 0.6 + 0.4 * cos(phase)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stopPulsing() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem.button?.alphaValue = 1
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        unacknowledgedDropout = false
        updateStatusItem()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        levelItems.removeAll()

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusLine = status
        menu.addItem(status)
        menu.addItem(item(armed ? "Disarm" : "Arm", key: "a") { [weak self] in self?.toggleArmed() })

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Microphones"))
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .denied || permission == .restricted {
            menu.addItem(item("⚠️ Microphone access denied…") { [weak self] in self?.showPermissionAlert() })
        }
        let present = AudioSystem.inputDevices()
        let selected = settings.selectedDevices
        var rows = present.map { (uid: $0.uid, name: $0.name, connected: true) }
        for (uid, name) in selected where !present.contains(where: { $0.uid == uid }) {
            rows.append((uid: uid, name: name, connected: false))
        }
        for row in rows {
            let menuItem = item(row.name) { [weak self] in self?.toggleDevice(uid: row.uid, name: row.name) }
            menuItem.state = selected[row.uid] != nil ? .on : .off
            if !row.connected { menuItem.title = "\(row.name) (not connected)" }
            levelItems[row.uid] = menuItem
            menu.addItem(menuItem)
        }
        if rows.isEmpty {
            let none = NSMenuItem(title: "No input devices found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        if !dropouts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent Dropouts"))
            let now = Date()
            for dropout in dropouts.reversed() {
                let duration = dropout.end == nil ? "ongoing" : formatDuration(dropout.duration(at: now))
                let row = NSMenuItem(
                    title: "\(Self.timeFormatter.string(from: dropout.start))  \(dropout.deviceName) — "
                        + "\(dropout.reason.label), \(duration)",
                    action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
            menu.addItem(item("Clear Dropouts") { [weak self] in
                guard let self else { return }
                dropouts.removeAll { $0.end != nil }
            })
        }

        menu.addItem(.separator())
        menu.addItem(alertAfterMenu())
        menu.addItem(thresholdMenu())
        let sound = item("Play Sound with Pop-up") { [settings] in settings.playSound.toggle() }
        sound.state = settings.playSound ? .on : .off
        menu.addItem(sound)
        let login = item("Launch at Login") { [weak self] in self?.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Dead Air", key: "q") { NSApp.terminate(nil) })

        updateLiveMenuItems()
    }

    private func alertAfterMenu() -> NSMenuItem {
        let submenu = NSMenu()
        for seconds in Settings.alertAfterChoices + [Settings.neverAlert] {
            let title = seconds == Settings.neverAlert ? "Never (menu bar only)" : "\(Int(seconds)) seconds"
            let choice = item(title) { [settings] in settings.alertAfter = seconds }
            choice.state = settings.alertAfter == seconds ? .on : .off
            submenu.addItem(choice)
        }
        let parent = NSMenuItem(title: "Pop Up After", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func thresholdMenu() -> NSMenuItem {
        let submenu = NSMenu()
        for db in Settings.thresholdChoices {
            let choice = item(Settings.thresholdLabel(db)) { [weak self] in self?.setThreshold(db) }
            choice.state = settings.thresholdDB == db ? .on : .off
            submenu.addItem(choice)
        }
        submenu.addItem(.separator())
        let hint = NSMenuItem(
            title: "Pick a level below your mic's quiet-room level (shown while armed)",
            action: nil, keyEquivalent: "")
        hint.isEnabled = false
        submenu.addItem(hint)
        let parent = NSMenuItem(title: "Treat as Dead Air", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// Refresh the parts of the open menu that change while you watch it.
    private func updateLiveMenuItems() {
        let monitored = channels.count
        if !armed {
            statusLine?.title = "Disarmed"
        } else if let deadSince {
            statusLine?.title = "🔴 Dead air for \(formatDuration(Date().timeIntervalSince(deadSince)))"
        } else {
            statusLine?.title = "🐤 Listening to \(monitored) mic\(monitored == 1 ? "" : "s")"
        }

        for (uid, menuItem) in levelItems {
            guard let channel = channels[uid] else { continue }
            let suffix: String
            switch channel.health {
            case let .dead(reason, _):
                suffix = reason.label
            case .live:
                guard let peak = channel.lastPeak else { suffix = "…"; break }
                let db = Level.decibels(fromLinear: peak)
                suffix = db.isFinite ? "\(Int(db.rounded())) dB" : "silence"
            }
            let text = NSMutableAttributedString(string: channel.name)
            text.append(NSAttributedString(
                string: "   \(suffix)",
                attributes: [
                    .foregroundColor: channel.health.isDead ? NSColor.systemRed : NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                ]))
            menuItem.attributedTitle = text
        }
    }

    // MARK: Actions

    private func toggleDevice(uid: String, name: String) {
        var selected = settings.selectedDevices
        selected[uid] = selected[uid] == nil ? name : nil
        settings.selectedDevices = selected
        syncChannels()
    }

    private func setThreshold(_ db: Double) {
        settings.thresholdDB = db
        for channel in channels.values { channel.tracker.silenceFloor = settings.silenceFloor }
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Dead Air needs microphone access"
        alert.informativeText = "Without it macOS feeds the app silence, so it can't tell whether your mic is alive. "
            + "Allow Dead Air under System Settings → Privacy & Security → Microphone."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func item(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let box = ActionBox(action)
        let menuItem = NSMenuItem(title: title, action: #selector(ActionBox.fire), keyEquivalent: key)
        menuItem.target = box
        menuItem.representedObject = box  // keep the box alive as long as the item
        return menuItem
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}

private extension ChannelHealth {
    var reasonLabel: String {
        if case let .dead(reason, _) = self { return reason.label }
        return "live"
    }
}

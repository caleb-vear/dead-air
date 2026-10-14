import AppKit
import DeadAirCore

// `DeadAir --probe [seconds]` prints input devices and live levels, handy for
// checking what your mic looks like with the transmitter on vs. off.
if CommandLine.arguments.dropFirst().first == "--probe" {
    let seconds = CommandLine.arguments.dropFirst(2).first.flatMap(Double.init) ?? 5
    Probe.run(seconds: seconds)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = AppController()
    withExtendedLifetime(controller) { app.run() }
}

enum Probe {
    static func run(seconds: TimeInterval) {
        let devices = AudioSystem.inputDevices()
        let defaultUID = AudioSystem.defaultInputDevice()?.uid
        for device in devices {
            print("\(device.uid == defaultUID ? "*" : " ") \(device.name)  [\(device.uid)]")
        }
        let monitors = devices.map(InputMonitor.init)
        for monitor in monitors {
            let status = monitor.start()
            if status != noErr { print("  ! couldn't start \(monitor.device.name): \(status)") }
        }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let levels = monitors.map { monitor -> String in
                let meter = monitor.drain()
                guard meter.callbacks > 0 else { return "\(monitor.device.name): no audio" }
                let db = Level.decibels(fromLinear: meter.peak)
                return "\(monitor.device.name): " + (db.isFinite ? String(format: "%.1f dB", db) : "digital silence")
            }
            print(levels.joined(separator: " | "))
        }
        monitors.forEach { $0.stop() }
    }
}

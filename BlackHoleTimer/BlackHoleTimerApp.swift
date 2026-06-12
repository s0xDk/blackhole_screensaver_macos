import SwiftUI
import ServiceManagement

@main
struct BlackHoleTimerApp: App {
    @StateObject private var model = BreakTimer()

    var body: some Scene {
        MenuBarExtra {
            Button("Show Black Hole Now") { model.startScreenSaver() }
            Divider()
            if let end = model.endDate {
                Text("Screensaver at \(end.formatted(date: .omitted, time: .shortened))")
                Button("Cancel") { model.cancel() }
                Divider()
            }
            Section("Break in") {
                ForEach(BreakTimer.presets, id: \.self) { minutes in
                    Button("\(minutes) min") { model.start(minutes: minutes) }
                }
                Button("Custom…") { model.promptCustomDuration() }
            }
            Divider()
            Toggle("Repeat", isOn: $model.repeats)
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            if model.endDate != nil {
                Text(model.countdownLabel).monospacedDigit()
            } else {
                Image(nsImage: BreakTimer.menuBarIcon)
            }
        }
    }
}

final class BreakTimer: ObservableObject {
    static let presets = [5, 10, 15, 20, 30, 45, 60]

    // Gargantua: the shadow, the lensed far-side disk as a circular halo
    // around it, and the near-side disk as a thin straight lens through the
    // equator. Template image so it adapts to the menu bar appearance.
    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.fillEllipse(in: CGRect(x: 5.2, y: 5.2, width: 7.6, height: 7.6))
            c.setLineWidth(1.1)
            c.strokeEllipse(in: CGRect(x: 3.0, y: 3.0, width: 12.0, height: 12.0))
            c.fillEllipse(in: CGRect(x: 0.4, y: 8.1, width: 17.2, height: 1.8))
            return true
        }
        image.isTemplate = true
        return image
    }()

    @Published private(set) var endDate: Date?
    @Published private(set) var remaining: TimeInterval = 0
    @Published var repeats: Bool {
        didSet { UserDefaults.standard.set(repeats, forKey: "repeats") }
    }
    @Published private(set) var launchAtLogin: Bool

    private var lastMinutes = 0
    private var timer: Timer?

    init() {
        repeats = UserDefaults.standard.bool(forKey: "repeats")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var countdownLabel: String {
        let s = max(0, Int(remaining.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func start(minutes: Int) {
        lastMinutes = minutes
        endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        remaining = TimeInterval(minutes * 60)
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        endDate = nil
    }

    func promptCustomDuration() {
        let alert = NSAlert()
        alert.messageText = "Start break timer"
        alert.informativeText = "Minutes until the screensaver starts:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 64, height: 24))
        field.placeholderString = "25"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let minutes = Int(field.stringValue), minutes > 0 else { return }
        start(minutes: minutes)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func tick() {
        guard let end = endDate else { return }
        remaining = end.timeIntervalSinceNow
        if remaining <= -120 {
            // Woke from sleep long past the deadline — don't ambush with the saver.
            repeats ? start(minutes: lastMinutes) : cancel()
        } else if remaining <= 0 {
            startScreenSaver()
            repeats ? start(minutes: lastMinutes) : cancel()
        }
    }

    func startScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

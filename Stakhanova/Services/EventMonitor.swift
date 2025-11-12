import Cocoa
import ApplicationServices
import Combine

class EventMonitor {
    private var globalMonitor: Any?
    private let captureService: CaptureService
    private var monitoringStateSub: AnyCancellable?

    var isRunning: Bool {
        return globalMonitor != nil
    }

    init(captureService: CaptureService) {
        self.captureService = captureService

        // Observe AppState.shared.isMonitoring
        monitoringStateSub = AppState.shared.$isMonitoring
            .dropFirst() // Skip initial value
            .removeDuplicates()
            .sink { [weak self] (isMonitoring: Bool) in
                guard let self = self else { return }
                if isMonitoring {
                    self.startInternal()
                } else {
                    self.stopInternal()
                }
            }
    }

    private func startInternal() {
        // Don't start if already running
        guard globalMonitor == nil else { return }

        // Start session
        captureService.startSession()

        // Monitor for left mouse clicks globally (avoid rightClick to prevent menu interference)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleClick(event)
        }

        print("Started monitoring clicks")
    }

    private func stopInternal() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        // End session
        captureService.endSession()
        print("Stopped monitoring clicks")

        // Notify that session ended
        NotificationCenter.default.post(name: NSNotification.Name("SessionEnded"), object: nil)
    }

    private func handleClick(_ event: NSEvent) {
        let mouseLocation = NSEvent.mouseLocation

        // Convert from AppKit coordinates (bottom-left origin) to CGDisplay coordinates (top-left origin)
        guard let screen = NSScreen.main else {
            print("ERROR: No main screen available for click detection")
            return
        }
        let cgPoint = CGPoint(
            x: mouseLocation.x,
            y: screen.frame.height - mouseLocation.y
        )

        let modifiers = extractModifierFlags(from: event.modifierFlags)

        print("Click detected at: \(cgPoint) (AppKit: \(mouseLocation))")
        print("Triggering captureClickEvent...")

        // Capture screenshot immediately
        captureService.captureClickEvent(
            mousePosition: cgPoint,
            modifierFlags: modifiers
        )
    }

    private func extractModifierFlags(from flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.command) { result.append("command") }
        if flags.contains(.option) { result.append("option") }
        if flags.contains(.control) { result.append("control") }
        if flags.contains(.shift) { result.append("shift") }
        return result
    }

    deinit {
        stopInternal()
    }
}

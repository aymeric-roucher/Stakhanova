import Cocoa
import ApplicationServices

class EventMonitor {
    private var globalMonitor: Any?
    private let captureService: CaptureService

    var isRunning: Bool {
        return globalMonitor != nil
    }

    init(captureService: CaptureService) {
        self.captureService = captureService
    }

    func start() {
        // Don't start if already running
        guard globalMonitor == nil else { return }

        // Monitor for left mouse clicks globally
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleClick(event)
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func handleClick(_ event: NSEvent) {
        let mouseLocation = NSEvent.mouseLocation
        let modifiers = extractModifierFlags(from: event.modifierFlags)

        print("Click detected at: \(mouseLocation)")

        // Capture screenshot immediately
        captureService.captureClickEvent(
            mousePosition: mouseLocation,
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
        stop()
    }
}

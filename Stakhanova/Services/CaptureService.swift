import Cocoa
import ScreenCaptureKit

class CaptureService {
    private let storageService = StorageService()
    private var sessionFolder: String?
    private let computerID: String = {
        var size = 0
        sysctlbyname("kern.uuid", nil, &size, nil, 0)
        var uuid = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.uuid", &uuid, &size, nil, 0)
        return String(cString: uuid)
    }()

    func startSession() {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        sessionFolder = "\(timestamp)_\(computerID)"
    }

    func endSession() {
        sessionFolder = nil
    }

    /// Capture a click event with all context
    func captureClickEvent(mousePosition: CGPoint, modifierFlags: [String]) {
        // Capture screenshot immediately (before click effect)
        let screenshotBefore = captureScreen()

        // Get active app
        guard let activeApp = AccessibilityService.getActiveApp() else {
            print("Could not get active app")
            return
        }

        // Get clicked element info
        let clickedElement = AccessibilityService.getElementAtPoint(mousePosition)

        // Get all open windows and running apps
        let openWindows = AccessibilityService.getAllOpenWindows()
        let runningApps = AccessibilityService.getAllRunningApps()

        // Wait 1 second and capture again (after click effect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let screenshotAfter = self?.captureScreen()

            // Create click event with all captured data
            let event = ClickEvent(
                timestamp: Date(),
                mousePosition: mousePosition,
                screenshotBeforeClick: screenshotBefore,
                screenshotAfterClick: screenshotAfter,
                activeApp: activeApp,
                clickedElement: clickedElement,
                openWindows: openWindows,
                runningApps: runningApps,
                modifierFlags: modifierFlags
            )

            // Save to local storage and upload
            self?.saveClickEvent(event)
        }
    }

    /// Capture the entire screen
    private func captureScreen() -> Data? {
        // Get main display
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID? else {
            return nil
        }

        // Create screenshot
        guard let image = CGDisplayCreateImage(displayID) else {
            return nil
        }

        // Convert to NSImage and then to PNG data
        let nsImage = NSImage(cgImage: image, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            return nil
        }

        return pngData
    }

    /// Save click event locally
    private func saveClickEvent(_ event: ClickEvent) {
        // Save locally
        let localPath = getLocalStoragePath()
        saveEventLocally(event, to: localPath)
        print("Saved click event at \(localPath.path)")
    }

    private func getLocalStoragePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var appDir = appSupport.appendingPathComponent("Stakhanova", isDirectory: true)

        // Add session folder if active
        if let session = sessionFolder {
            appDir = appDir.appendingPathComponent(session, isDirectory: true)
        }

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir
    }

    private func saveEventLocally(_ event: ClickEvent, to directory: URL) {
        // Create timestamp string for filenames
        let timestamp = ISO8601DateFormatter().string(from: event.timestamp).replacingOccurrences(of: ":", with: "-")

        // Save metadata as JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        if let jsonData = try? encoder.encode(event) {
            let metadataPath = directory.appendingPathComponent("\(timestamp)_metadata.json")
            try? jsonData.write(to: metadataPath)
        }

        // Save screenshots with timestamp
        if let beforeData = event.screenshotBeforeClick {
            let beforePath = directory.appendingPathComponent("\(timestamp)_before.png")
            try? beforeData.write(to: beforePath)
        }

        if let afterData = event.screenshotAfterClick {
            let afterPath = directory.appendingPathComponent("\(timestamp)_after.png")
            try? afterData.write(to: afterPath)
        }
    }
}

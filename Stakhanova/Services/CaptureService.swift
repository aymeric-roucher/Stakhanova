import Cocoa
import ScreenCaptureKit
import CoreGraphics

class CaptureService {
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

            // Create click event with metadata only
            let event = ClickEvent(
                timestamp: Date(),
                mousePosition: mousePosition,
                activeApp: activeApp,
                clickedElement: clickedElement,
                openWindows: openWindows,
                runningApps: runningApps,
                modifierFlags: modifierFlags
            )

            // Save to local storage with screenshots as separate files
            self?.saveClickEvent(event, screenshotBefore: screenshotBefore, screenshotAfter: screenshotAfter)
        }
    }

    /// Capture the entire screen using CGDisplayCreateImage (most compatible)
    private func captureScreen() -> Data? {
        // Use the main display ID
        let displayID = CGMainDisplayID()

        // Create image of the display
        guard let cgImage = CGDisplayCreateImage(displayID) else {
            print("Failed to capture screen")
            print("Make sure Screen Recording permission is granted in System Settings > Privacy & Security > Screen Recording")
            return nil
        }

        // Convert CGImage to PNG data
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("Failed to convert screenshot to PNG")
            return nil
        }

        return pngData
    }

    /// Save click event locally
    private func saveClickEvent(_ event: ClickEvent, screenshotBefore: Data?, screenshotAfter: Data?) {
        // Save locally
        let localPath = getLocalStoragePath()
        saveEventLocally(event, screenshotBefore: screenshotBefore, screenshotAfter: screenshotAfter, to: localPath)
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

    private func saveEventLocally(_ event: ClickEvent, screenshotBefore: Data?, screenshotAfter: Data?, to directory: URL) {
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
        if let beforeData = screenshotBefore {
            let beforePath = directory.appendingPathComponent("\(timestamp)_before.png")
            try? beforeData.write(to: beforePath)
        }

        if let afterData = screenshotAfter {
            let afterPath = directory.appendingPathComponent("\(timestamp)_after.png")
            try? afterData.write(to: afterPath)
        }
    }
}

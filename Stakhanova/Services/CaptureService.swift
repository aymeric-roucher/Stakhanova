import Cocoa
import ScreenCaptureKit

class CaptureService {
    private let storageService = StorageService()

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

    /// Save click event locally and upload to cloud
    private func saveClickEvent(_ event: ClickEvent) {
        // Save locally first
        let localPath = getLocalStoragePath()
        saveEventLocally(event, to: localPath)

        // Upload to Google Cloud Storage
        Task {
            do {
                try await storageService.uploadClickEvent(event)
                print("Successfully uploaded click event \(event.id)")
            } catch {
                print("Failed to upload click event: \(error)")
            }
        }
    }

    private func getLocalStoragePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("Stakhanova", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir
    }

    private func saveEventLocally(_ event: ClickEvent, to directory: URL) {
        let eventDir = directory.appendingPathComponent(event.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: eventDir, withIntermediateDirectories: true)

        // Save metadata as JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        if let jsonData = try? encoder.encode(event) {
            let metadataPath = eventDir.appendingPathComponent("metadata.json")
            try? jsonData.write(to: metadataPath)
        }

        // Save screenshots separately
        if let beforeData = event.screenshotBeforeClick {
            let beforePath = eventDir.appendingPathComponent("screenshot_before.png")
            try? beforeData.write(to: beforePath)
        }

        if let afterData = event.screenshotAfterClick {
            let afterPath = eventDir.appendingPathComponent("screenshot_after.png")
            try? afterData.write(to: afterPath)
        }
    }
}

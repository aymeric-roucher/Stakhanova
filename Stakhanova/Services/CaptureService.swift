import Cocoa
import ScreenCaptureKit
import CoreGraphics
import CryptoKit

class CaptureService {
    private var sessionFolder: String?
    private var isCancelled = false
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
        isCancelled = false
    }

    func endSession() {
        isCancelled = true
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

        // Wait for screen to stabilize (3 identical captures = stable)
        waitForScreenStability(baseline: screenshotBefore, maxWait: 1.0) { [weak self] screenshotAfter in
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

    /// Wait for screen stability: captures every 100ms, stops when 3 consecutive identical screenshots
    private func waitForScreenStability(baseline: Data?, maxWait: TimeInterval, completion: @escaping (Data?) -> Void) {
        let startTime = Date()
        let captureInterval: TimeInterval = 0.1 // Capture every 100ms
        var captureHistory: [(data: Data, hash: String)] = [] // Keep last 3 captures with hashes

        func captureAndCheck() {
            // Check if cancelled (session ended)
            if self.isCancelled {
                print("Screenshot capture cancelled (session ended)")
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)

            // Check timeout
            if elapsed >= maxWait {
                let finalCapture = captureHistory.last?.data ?? self.captureScreen()
                print("Screenshot capture timed out after \(String(format: "%.2f", elapsed))s")
                completion(finalCapture)
                return
            }

            // Capture current screen
            guard let currentData = self.captureScreen() else {
                // Failed to capture, try again
                DispatchQueue.main.asyncAfter(deadline: .now() + captureInterval) {
                    captureAndCheck()
                }
                return
            }

            // Compute hash for efficient comparison
            let hash = SHA256.hash(data: currentData)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

            // Add to history (keep only last 3)
            captureHistory.append((data: currentData, hash: hashString))
            if captureHistory.count > 3 {
                captureHistory.removeFirst()
            }

            // Check if we have 3 identical screenshots (by hash)
            if captureHistory.count == 3 {
                let hash1 = captureHistory[0].hash
                let hash2 = captureHistory[1].hash
                let hash3 = captureHistory[2].hash

                if hash1 == hash2 && hash2 == hash3 {
                    // Screen stable! (3 identical captures = 200ms of stability)
                    print("Screenshot captured after \(String(format: "%.2f", elapsed))s (screen stable)")
                    completion(captureHistory[2].data)
                    return
                }
            }

            // Not stable yet, capture again
            DispatchQueue.main.asyncAfter(deadline: .now() + captureInterval) {
                captureAndCheck()
            }
        }

        // Start capturing
        captureAndCheck()
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

    /// Draw a circle and cross at the specified point on an image
    static func annotateImageWithClickMarker(_ imageData: Data, at point: CGPoint) -> Data? {
        guard let image = NSImage(data: imageData) else { return nil }

        let size = image.size
        let newImage = NSImage(size: size)

        newImage.lockFocus()

        // Draw the original image
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)

        // Set up drawing context
        guard let context = NSGraphicsContext.current?.cgContext else {
            newImage.unlockFocus()
            return nil
        }

        // Draw red circle and cross
        context.setStrokeColor(NSColor.red.cgColor)
        context.setLineWidth(3.0)

        let radius: CGFloat = 20.0

        // Draw circle
        let circleRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.strokeEllipse(in: circleRect)

        // Draw cross (X shape)
        context.move(to: CGPoint(x: point.x - radius, y: point.y - radius))
        context.addLine(to: CGPoint(x: point.x + radius, y: point.y + radius))
        context.strokePath()

        context.move(to: CGPoint(x: point.x + radius, y: point.y - radius))
        context.addLine(to: CGPoint(x: point.x - radius, y: point.y + radius))
        context.strokePath()

        newImage.unlockFocus()

        // Convert back to PNG data
        guard let tiffData = newImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            return nil
        }

        return pngData
    }

    /// Save click event locally
    private func saveClickEvent(_ event: ClickEvent, screenshotBefore: Data?, screenshotAfter: Data?) {
        // Annotate only the "before" screenshot with click marker if setting is enabled
        let annotatedBefore: Data?
        if AppState.shared.addClickMarker {
            annotatedBefore = screenshotBefore.flatMap { CaptureService.annotateImageWithClickMarker($0, at: event.mousePosition) }
        } else {
            annotatedBefore = screenshotBefore
        }

        // Save locally
        let localPath = getLocalStoragePath()
        saveEventLocally(event, screenshotBefore: annotatedBefore, screenshotAfter: screenshotAfter, to: localPath)
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

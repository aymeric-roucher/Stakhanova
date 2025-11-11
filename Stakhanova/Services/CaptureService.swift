import Cocoa
import ScreenCaptureKit
import CoreGraphics
import CoreMedia

class CaptureService: NSObject, SCStreamDelegate, SCStreamOutput {
    static let shared = CaptureService()

    private var sessionFolder: String?
    private var stream: SCStream?
    private var frameBuffer: [CMSampleBuffer] = [] // Keep last 3 frames
    private let maxBufferSize = 3
    private let streamQueue = DispatchQueue(label: "com.stakhanova.streamQueue")
    private let bufferQueue = DispatchQueue(label: "com.stakhanova.bufferQueue")

    private let computerID: String = {
        var size = 0
        sysctlbyname("kern.uuid", nil, &size, nil, 0)
        var uuid = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.uuid", &uuid, &size, nil, 0)
        return String(cString: uuid)
    }()

    var currentSessionFolder: String? {
        return sessionFolder
    }

    func startSession() {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        sessionFolder = "\(timestamp)_\(computerID)"

        // Start ScreenCaptureKit stream
        Task {
            await startStream()
        }
    }

    func endSession() {
        sessionFolder = nil

        // Stop stream
        Task {
            await stopStream()
        }
    }

    // MARK: - ScreenCaptureKit Stream Management

    private func startStream() async {
        do {
            // Get available content
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                print("ERROR: No displays found")
                return
            }

            // Create filter (capture entire display)
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            // Configure stream
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 FPS
            config.pixelFormat = kCVPixelFormatType_32BGRA

            // Create and start stream
            stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
            try await stream?.startCapture()

            print("ScreenCaptureKit stream started successfully")
        } catch let error as NSError {
            if error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3801 {
                print("ERROR: Screen recording permission denied!")
                print("Please grant screen recording permission in System Settings > Privacy & Security > Screen Recording")
                print("Then restart Stakhanova")
            } else {
                print("ERROR: Failed to start stream: \(error)")
            }
        }
    }

    private func stopStream() async {
        do {
            try await stream?.stopCapture()
            stream = nil
            bufferQueue.sync {
                frameBuffer.removeAll()
            }
            print("ScreenCaptureKit stream stopped")
        } catch {
            print("Failed to stop stream: \(error)")
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Keep a buffer of the last 3 frames
        bufferQueue.sync {
            frameBuffer.append(sampleBuffer)
            if frameBuffer.count > maxBufferSize {
                frameBuffer.removeFirst()
            }
            if frameBuffer.count == 1 {
                print("Frame buffer received first frame - ready to capture")
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")

        // User clicked "Stop Sharing" in macOS menu - sync monitoring state
        DispatchQueue.main.async {
            if AppState.shared.isMonitoring {
                print("User stopped screen sharing from macOS menu - stopping monitoring")
                AppState.shared.isMonitoring = false
            }
        }
    }

    /// Capture a click event with all context
    func captureClickEvent(mousePosition: CGPoint, modifierFlags: [String]) {
        // Capture screenshot from n-1 frame (previous frame, before the click)
        let screenshotBefore = captureFrameFromBuffer(offset: 1)
        print("Captured before screenshot: \(screenshotBefore.count) bytes")

        // Get active app
        let activeApp = AccessibilityService.getActiveApp()!

        // Get clicked element info
        let clickedElement = AccessibilityService.getElementAtPoint(mousePosition)

        // Get all open windows and running apps
        let openWindows = AccessibilityService.getAllOpenWindows()
        let runningApps = AccessibilityService.getAllRunningApps()

        // Wait 500ms and capture again (after click effect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            let screenshotAfter = self.captureFrameFromBuffer(offset: 0)
            print("Captured after screenshot: \(screenshotAfter.count) bytes")

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
            self.saveClickEvent(event, screenshotBefore: screenshotBefore, screenshotAfter: screenshotAfter)
        }
    }

    /// Capture frame from buffer with offset (0 = latest, 1 = previous, 2 = n-2)
    private func captureFrameFromBuffer(offset: Int) -> Data {
        // Process the sample buffer entirely within the sync block to avoid invalidation
        return bufferQueue.sync {
            assert(!frameBuffer.isEmpty, "Frame buffer is empty - ScreenCaptureKit stream may not have started yet or failed to start. Check screen recording permissions.")

            let index = max(0, frameBuffer.count - 1 - offset)
            let sampleBuffer = frameBuffer.indices.contains(index) ? frameBuffer[index] : frameBuffer.last!

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                fatalError("Failed to get image buffer from sample buffer")
            }

            // Lock the pixel buffer
            CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

            // Create CGImage from pixel buffer
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                fatalError("Failed to create CGImage from pixel buffer")
            }

            // Convert to PNG
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                fatalError("Failed to convert image to PNG")
            }

            return pngData
        }
    }

    /// Draw a circle and cross at the specified point on an image
    static func annotateImageWithClickMarker(_ imageData: Data, at point: CGPoint) -> Data {
        let image = NSImage(data: imageData)!

        let size = image.size
        let newImage = NSImage(size: size)

        newImage.lockFocus()

        // Draw the original image
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)

        // Set up drawing context
        let context = NSGraphicsContext.current!.cgContext

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
        let tiffData = newImage.tiffRepresentation!
        let bitmapRep = NSBitmapImageRep(data: tiffData)!
        let pngData = bitmapRep.representation(using: .png, properties: [:])!

        return pngData
    }

    /// Save click event locally
    private func saveClickEvent(_ event: ClickEvent, screenshotBefore: Data, screenshotAfter: Data) {
        // Annotate only the "before" screenshot with click marker if setting is enabled
        let annotatedBefore: Data
        if AppState.shared.addClickMarker {
            annotatedBefore = CaptureService.annotateImageWithClickMarker(screenshotBefore, at: event.mousePosition)
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
        try! FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        return appDir
    }

    private func saveEventLocally(_ event: ClickEvent, screenshotBefore: Data, screenshotAfter: Data, to directory: URL) {
        // Create timestamp string for filenames
        let timestamp = ISO8601DateFormatter().string(from: event.timestamp).replacingOccurrences(of: ":", with: "-")

        // Save metadata as JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let jsonData = try! encoder.encode(event)
        let metadataPath = directory.appendingPathComponent("\(timestamp)_metadata.json")
        try! jsonData.write(to: metadataPath)

        // Save screenshots with timestamp
        let beforePath = directory.appendingPathComponent("\(timestamp)_before.png")
        try! screenshotBefore.write(to: beforePath)

        let afterPath = directory.appendingPathComponent("\(timestamp)_after.png")
        try! screenshotAfter.write(to: afterPath)

        print("Saved screenshots to: \(beforePath.path) and \(afterPath.path)")
    }
}

import SwiftUI

struct MonitoringStatusWindow: View {
    @ObservedObject private var appState = AppState.shared
    @State private var latestScreenshot: NSImage?
    @State private var eventCount: Int = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Currently Monitoring")
                .font(.headline)

            // Screenshot preview
            if let screenshot = latestScreenshot {
                Image(nsImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 300)
                    .cornerRadius(8)
                    .overlay(
                        VStack {
                            Image(systemName: "camera.circle")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("Monitoring clicks...")
                                .foregroundColor(.secondary)
                        }
                    )
            }

            // Stats
            HStack {
                Label("\(eventCount) clicks captured", systemImage: "hand.tap.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Stop button
            Button(action: {
                AppState.shared.isMonitoring = false
            }) {
                Text("Stop Monitoring")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            eventCount = 0
            latestScreenshot = nil
        }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            if appState.isMonitoring {
                loadLatestScreenshot()
            }
        }
    }

    private func getCurrentSessionFolder() -> URL? {
        // Get the current active session folder from CaptureService
        guard let sessionFolderName = CaptureService.shared.currentSessionFolder else {
            return nil
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stakhanovalDir = appSupport.appendingPathComponent("Stakhanova", isDirectory: true)
        let currentSessionDir = stakhanovalDir.appendingPathComponent(sessionFolderName, isDirectory: true)

        // Check if the directory exists
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: currentSessionDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return currentSessionDir
        }

        return nil
    }

    private func loadLatestScreenshot() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let currentSession = self.getCurrentSessionFolder() else {
                DispatchQueue.main.async {
                    self.eventCount = 0
                    self.latestScreenshot = nil
                }
                return
            }

            // Get most recent before screenshot
            let screenshot: NSImage?
            if let screenshots = try? FileManager.default.contentsOfDirectory(at: currentSession, includingPropertiesForKeys: nil)
                .filter({ $0.lastPathComponent.contains("_before.png") })
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }),
               let latest = screenshots.first {
                screenshot = NSImage(contentsOf: latest)
            } else {
                screenshot = nil
            }

            // Count events in current session
            let count: Int
            if let metadataFiles = try? FileManager.default.contentsOfDirectory(at: currentSession, includingPropertiesForKeys: nil)
                .filter({ $0.lastPathComponent.contains("_metadata.json") }) {
                count = metadataFiles.count
            } else {
                count = 0
            }

            // Update UI on main thread
            DispatchQueue.main.async {
                self.latestScreenshot = screenshot
                self.eventCount = count
            }
        }
    }

}


#Preview {
    MonitoringStatusWindow()
}

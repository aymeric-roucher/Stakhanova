import SwiftUI
import Charts

struct SettingsView: View {
    @ObservedObject private var analyticsService = AnalyticsService.shared

    @State private var apiKey: String = ""
    @State private var selectedProvider: LLMProvider = .openai
    @State private var selectedModel: LLMModel?

    // Analytics state
    @State private var sessions: [SessionInfo] = []
    @State private var selectedSession: SessionInfo?
    @State private var analysisResult: SessionAnalysisResult?
    @State private var isAnalyzing = false
    @State private var progress: Double = 0.0
    @State private var errorMessage: String?
    @State private var sessionScreenshots: [(before: NSImage?, after: NSImage?, timestamp: String)] = []
    @State private var sessionMetadata: [ClickEvent] = []
    @State private var currentScreenshotIndex: Int = 0
    @State private var zoomedImage: NSImage?
    @State private var showZoomWindow = false

    var body: some View {
        TabView {
            analyticsTab
            settingsTab
            aboutTab
        }
        .frame(width: 800, height: 600)
        .onAppear {
            loadSettings()
            loadSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SessionEnded"))) { _ in
            loadSessions()
        }
        .sheet(isPresented: $showZoomWindow) {
            if let image = zoomedImage {
                ZoomImageView(image: image, isPresented: $showZoomWindow)
                    .frame(minWidth: 800, minHeight: 600)
            }
        }
    }

    private var analyticsTab: some View {
        VStack(spacing: 20) {
                // Session selector
                HStack {
                    Text("Session:")
                        .font(.headline)

                    Picker("Select Session", selection: $selectedSession) {
                        Text("Select a session").tag(nil as SessionInfo?)
                        ForEach(sessions) { session in
                            Text(session.displayName).tag(session as SessionInfo?)
                        }
                    }
                    .frame(maxWidth: 400)
                    .onChange(of: selectedSession) { oldValue, newValue in
                        loadSessionScreenshots()
                    }

                    Spacer()

                    Button(action: loadSessions) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding()

                // Screenshot carousel with metadata
                if !sessionScreenshots.isEmpty {
                    HStack(alignment: .top, spacing: 20) {
                        // Left: Screenshots
                        VStack(spacing: 10) {
                            Text("Event \(currentScreenshotIndex + 1) of \(sessionScreenshots.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 20) {
                                // Before screenshot
                                VStack {
                                    Text("Before")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let beforeImage = sessionScreenshots[currentScreenshotIndex].before {
                                        Image(nsImage: beforeImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 150)
                                            .cornerRadius(8)
                                            .onTapGesture {
                                                zoomedImage = beforeImage
                                                showZoomWindow = true
                                            }
                                            .help("Click to zoom")
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .frame(height: 150)
                                            .overlay(Text("No image").foregroundColor(.secondary))
                                            .cornerRadius(8)
                                    }
                                }

                                // After screenshot
                                VStack {
                                    Text("After")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let afterImage = sessionScreenshots[currentScreenshotIndex].after {
                                        Image(nsImage: afterImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 150)
                                            .cornerRadius(8)
                                            .onTapGesture {
                                                zoomedImage = afterImage
                                                showZoomWindow = true
                                            }
                                            .help("Click to zoom")
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .frame(height: 150)
                                            .overlay(Text("No image").foregroundColor(.secondary))
                                            .cornerRadius(8)
                                    }
                                }
                            }

                            // Navigation buttons
                            HStack {
                                Button(action: {
                                    if currentScreenshotIndex > 0 {
                                        currentScreenshotIndex -= 1
                                    }
                                }) {
                                    Image(systemName: "chevron.left")
                                }
                                .disabled(currentScreenshotIndex == 0)

                                Spacer()

                                Text(sessionScreenshots[currentScreenshotIndex].timestamp)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Spacer()

                                Button(action: {
                                    if currentScreenshotIndex < sessionScreenshots.count - 1 {
                                        currentScreenshotIndex += 1
                                    }
                                }) {
                                    Image(systemName: "chevron.right")
                                }
                                .disabled(currentScreenshotIndex >= sessionScreenshots.count - 1)
                            }
                            .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity)

                        // Right: Metadata
                        if currentScreenshotIndex < sessionMetadata.count {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Event Metadata")
                                        .font(.headline)
                                        .padding(.bottom, 4)

                                    let metadata = sessionMetadata[currentScreenshotIndex]

                                    MetadataRow(label: "App", value: metadata.activeApp.name)
                                    MetadataRow(label: "Time", value: metadata.timestamp.formatted(date: .omitted, time: .shortened))

                                    if let element = metadata.clickedElement {
                                        MetadataRow(label: "Element", value: element.role ?? "Unknown")
                                        if let title = element.title ?? element.label {
                                            MetadataRow(label: "Label", value: title)
                                        }
                                    }

                                    MetadataRow(label: "Position", value: String(format: "%.0f, %.0f", metadata.mousePosition.x, metadata.mousePosition.y))

                                    if !metadata.modifierFlags.isEmpty {
                                        MetadataRow(label: "Modifiers", value: metadata.modifierFlags.joined(separator: ", "))
                                    }

                                    if !metadata.openWindows.isEmpty {
                                        Text("Open Windows:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .padding(.top, 4)
                                        ForEach(Array(metadata.openWindows.prefix(5).enumerated()), id: \.offset) { index, window in
                                            Text("• \(window.ownerName ?? "Unknown")")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding()
                            }
                            .frame(width: 250)
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                }

                // Run Analysis button
                Button(action: runAnalysis) {
                    HStack {
                        if isAnalyzing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isAnalyzing ? "Analyzing..." : "Run Analysis")
                    }
                    .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSession == nil || isAnalyzing)

                // Progress bar
                if isAnalyzing {
                    ProgressView(value: progress, total: 1.0)
                        .padding(.horizontal)
                    Text("\(Int(progress * 100))% complete")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }

                // Results
                if let result = analysisResult {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Summary
                            HStack {
                                Text("Total Time:")
                                    .font(.headline)
                                Text(String(format: "%.1f minutes", result.totalMinutes))
                                    .font(.title2)
                                    .foregroundColor(.blue)
                            }
                            .padding()

                            // Bar chart
                            Chart(result.appUsage.sorted(by: { $0.minutesUsed > $1.minutesUsed })) { entry in
                                BarMark(
                                    x: .value("Minutes", entry.minutesUsed),
                                    y: .value("App", entry.appName)
                                )
                                .foregroundStyle(.blue)
                            }
                            .frame(height: CGFloat(result.appUsage.count * 40 + 50))
                            .padding()

                            // Detailed list
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Detailed Breakdown")
                                    .font(.headline)
                                    .padding(.bottom, 5)

                                ForEach(result.appUsage.sorted(by: { $0.minutesUsed > $1.minutesUsed })) { entry in
                                    HStack {
                                        Text(entry.appName)
                                            .font(.body)
                                        Spacer()
                                        Text(String(format: "%.1f min", entry.minutesUsed))
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding()
                        }
                    }
                } else if !isAnalyzing && selectedSession != nil {
                    Text("Click 'Run Analysis' to analyze this session")
                        .foregroundColor(.secondary)
                        .frame(maxHeight: .infinity)
                } else {
                    Text("Select a session to begin")
                        .foregroundColor(.secondary)
                        .frame(maxHeight: .infinity)
                }
            }
            .padding()
            .tabItem {
                Label("Analytics", systemImage: "chart.bar")
            }
    }

    private var settingsTab: some View {
        Form {
                Section(header: Text("LLM Provider")) {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedProvider) { oldValue, newValue in
                        // Reset model selection when provider changes
                        selectedModel = newValue.availableModels.first
                    }

                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    if selectedProvider == .huggingface {
                        Text("Leave empty to use HF_TOKEN from .env file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let model = selectedModel {
                        HStack {
                            Text("Model:")
                            Spacer()
                            Text(model.name)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button("Save Settings") {
                        // Update the shared service which will automatically persist to UserDefaults
                        // and trigger updates across all views
                        analyticsService.apiProvider = selectedProvider
                        analyticsService.apiKey = apiKey.isEmpty ? nil : apiKey
                        analyticsService.selectedModel = selectedModel?.id
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)
                }

                Section(header: Text("Provider Info")) {
                    switch selectedProvider {
                    case .openai:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("OpenAI Models")
                                .font(.headline)
                            Text("Get your API key at: platform.openai.com/api-keys")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .huggingface:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HuggingFace Inference Providers")
                                .font(.headline)
                            Text("Get your API key at: huggingface.co/settings/tokens")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Provides access to models from Cerebras, Together AI, and more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

            }
            .padding()
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
    }

    private var aboutTab: some View {
        Form {
                Section(header: Text("About Stakhanova")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stakhanova captures your click interactions and provides AI-powered analytics about your productivity and app usage patterns.")

                        Text("Required Permissions:")
                            .font(.headline)
                            .padding(.top)

                        VStack(alignment: .leading, spacing: 4) {
                            Label("Screen Recording", systemImage: "checkmark.circle.fill")
                            Label("Accessibility", systemImage: "checkmark.circle.fill")
                        }
                        .foregroundColor(.green)

                        Button("Open System Preferences") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .padding(.top)

                        Divider()
                            .padding(.vertical)

                        Text("Storage:")
                            .font(.headline)

                        Text("All captures are stored locally at:")
                            .font(.caption)
                        Text("~/Library/Application Support/Stakhanova/")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
    }

    private func loadSettings() {
        apiKey = analyticsService.apiKey ?? ""
        selectedProvider = analyticsService.apiProvider

        // Always use the first available model for the current provider
        selectedModel = selectedProvider.availableModels.first
    }

    private func loadSessions() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stakhanovalDir = appSupport.appendingPathComponent("Stakhanova", isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: stakhanovalDir,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]
        ) else {
            return
        }

        sessions = contents.compactMap { url -> SessionInfo? in
            guard url.hasDirectoryPath else { return nil }

            // Parse timestamp from folder name
            let folderName = url.lastPathComponent
            let components = folderName.components(separatedBy: "_")
            guard components.count >= 1 else { return nil }

            let timestampString = components[0]
            // Format is like: 2025-11-05T20-02-49Z
            // Need to convert the time part hyphens to colons for ISO8601 parsing
            let timePart = timestampString.components(separatedBy: "T")
            guard timePart.count == 2 else { return nil }

            let datePart = timePart[0]
            let timeWithZone = timePart[1].replacingOccurrences(of: "-", with: ":")
            let isoString = "\(datePart)T\(timeWithZone)"

            let isoFormatter = ISO8601DateFormatter()
            guard let date = isoFormatter.date(from: isoString) else {
                return nil
            }

            // Count events (metadata files)
            let metadataFiles = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.contains("metadata.json") }
            let eventCount = metadataFiles?.count ?? 0

            return SessionInfo(
                id: folderName,
                path: url,
                startTime: date,
                eventCount: eventCount
            )
        }
        .sorted(by: { $0.startTime > $1.startTime })

        // Auto-select most recent
        if selectedSession == nil {
            selectedSession = sessions.first
        }
    }

    private func loadSessionScreenshots() {
        guard let session = selectedSession else {
            sessionScreenshots = []
            sessionMetadata = []
            return
        }

        currentScreenshotIndex = 0

        // Load all metadata files to get timestamps and metadata
        guard let metadataFiles = try? FileManager.default.contentsOfDirectory(at: session.path, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.contains("metadata.json") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else {
            sessionScreenshots = []
            sessionMetadata = []
            return
        }

        var screenshots: [(before: NSImage?, after: NSImage?, timestamp: String)] = []
        var metadata: [ClickEvent] = []

        for metadataFile in metadataFiles {
            let timestamp = metadataFile.lastPathComponent.replacingOccurrences(of: "_metadata.json", with: "")

            let beforePath = session.path.appendingPathComponent("\(timestamp)_before.png")
            let afterPath = session.path.appendingPathComponent("\(timestamp)_after.png")

            let beforeImage = NSImage(contentsOf: beforePath)
            let afterImage = NSImage(contentsOf: afterPath)

            screenshots.append((before: beforeImage, after: afterImage, timestamp: timestamp))

            // Load metadata
            if let data = try? Data(contentsOf: metadataFile),
               let event = try? JSONDecoder().decode(ClickEvent.self, from: data) {
                metadata.append(event)
            }
        }

        sessionScreenshots = screenshots
        sessionMetadata = metadata
    }

    private func runAnalysis() {
        guard let session = selectedSession else { return }

        isAnalyzing = true
        progress = 0.0
        errorMessage = nil
        analysisResult = nil

        Task {
            do {
                let result = try await analyticsService.analyzeSession(
                    sessionPath: session.path,
                    progressCallback: { prog in
                        DispatchQueue.main.async {
                            self.progress = prog
                        }
                    }
                )

                await MainActor.run {
                    analysisResult = SessionAnalysisResult(
                        session: session,
                        appUsage: result,
                        totalMinutes: result.reduce(0) { $0 + $1.minutesUsed }
                    )
                    isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Analysis failed: \(error.localizedDescription)"
                    isAnalyzing = false
                }
            }
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text("\(label):")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
            Spacer()
        }
    }
}

struct ZoomImageView: View {
    let image: NSImage
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: {
                        isPresented = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                .background(Color(NSColor.windowBackgroundColor))

                // Image viewer
                ZStack {
                    Color.black.opacity(0.9)

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(x: offset.width, y: offset.height)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let newScale = lastScale * value
                                        scale = max(0.5, min(newScale, 5.0)) // Limit scale between 0.5x and 5x
                                    }
                                    .onEnded { value in
                                        lastScale = scale
                                    },
                                DragGesture()
                                    .onChanged { value in
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { value in
                                        lastOffset = offset
                                    }
                            )
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Controls
                HStack(spacing: 20) {
                    Button("Zoom In") {
                        withAnimation {
                            scale = min(scale * 1.5, 5.0)
                            lastScale = scale
                        }
                    }

                    Button("Zoom Out") {
                        withAnimation {
                            scale = max(scale / 1.5, 0.5)
                            lastScale = scale
                        }
                    }

                    Button("Reset") {
                        withAnimation {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        }
                    }

                    Spacer()

                    Text("Scroll/pinch to zoom • Drag to pan • Scale: \(String(format: "%.0f%%", scale * 100))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

#Preview {
    SettingsView()
}

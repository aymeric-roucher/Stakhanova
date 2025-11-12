import SwiftUI
import Charts

struct SettingsView: View {
    @ObservedObject private var analyticsService = AnalyticsService.shared

    @State private var apiKey: String = ""
    @State private var selectedProvider: LLMProvider = .openai
    @State private var selectedModel: LLMModel?
    @State private var sendAllScreenshots: Bool = false
    @State private var reasoningEffort: String = "minimal"
    @State private var addClickMarker: Bool = true

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
    @State private var analysisLogs: [String] = []

    var body: some View {
        TabView {
            analyticsTab
            settingsTab
            aboutTab
        }
        .frame(minWidth: 1200, minHeight: 800)
        .onAppear {
            loadSettings()
            loadSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SessionEnded"))) { _ in
            DispatchQueue.main.async {
                loadSessions()
            }
        }
        .sheet(isPresented: $showZoomWindow) {
            if let image = zoomedImage {
                ZoomImageView(image: image, isPresented: $showZoomWindow)
                    .frame(minWidth: 800, minHeight: 600)
            }
        }
    }

    private var analyticsTab: some View {
        VStack(spacing: 0) {
                // Session selector - at the very top
                HStack {
                    Text("Session:")
                        .font(.headline)

                    Picker("Select Session", selection: $selectedSession) {
                        Text("Select a session to begin").tag(nil as SessionInfo?)
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
                .background(Color.gray.opacity(0.05))

                // Screenshot carousel with metadata
                if !sessionScreenshots.isEmpty {
                    ScrollView {
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

                        // Right: Metadata (must always exist if screenshots exist)
                        VStack(alignment: .leading, spacing: 8) {
                                    Text("Event Metadata")
                                        .font(.headline)
                                        .padding(.bottom, 4)

                                    let metadata = sessionMetadata[currentScreenshotIndex]

                                    Divider()

                                    Text("Application")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)

                                    MetadataRow(label: "Name", value: metadata.activeApp.name)
                                    if let bundleId = metadata.activeApp.bundleIdentifier {
                                        MetadataRow(label: "Bundle ID", value: bundleId)
                                    }
                                    MetadataRow(label: "PID", value: String(metadata.activeApp.processID))

                                    Divider().padding(.vertical, 4)

                                    Text("Event Details")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)

                                    MetadataRow(label: "Time", value: metadata.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    MetadataRow(label: "Position", value: String(format: "%.0f, %.0f", metadata.mousePosition.x, metadata.mousePosition.y))

                                    if !metadata.modifierFlags.isEmpty {
                                        MetadataRow(label: "Modifiers", value: metadata.modifierFlags.joined(separator: ", "))
                                    }

                                    if let element = metadata.clickedElement {
                                        Divider().padding(.vertical, 4)

                                        Text("Clicked Element")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)

                                        if let role = element.role {
                                            MetadataRow(label: "Role", value: role)
                                        }
                                        if let title = element.title {
                                            MetadataRow(label: "Title", value: title)
                                        }
                                        if let label = element.label {
                                            MetadataRow(label: "Label", value: label)
                                        }
                                        if let description = element.description {
                                            MetadataRow(label: "Desc", value: description)
                                        }
                                        if let value = element.value {
                                            MetadataRow(label: "Value", value: value)
                                        }
                                        if let type = element.elementType {
                                            MetadataRow(label: "Type", value: type)
                                        }
                                    }

                                    if !metadata.openWindows.isEmpty {
                                        Divider().padding(.vertical, 4)

                                        Text("Open Windows (\(metadata.openWindows.count))")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)

                                        ForEach(Array(metadata.openWindows.prefix(5).enumerated()), id: \.offset) { index, window in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(window.ownerName ?? "Unknown")
                                                    .font(.caption2)
                                                    .foregroundColor(.primary)
                                                    .textSelection(.enabled)
                                                if let title = window.title, !title.isEmpty {
                                                    Text(title)
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                        .lineLimit(1)
                                                        .textSelection(.enabled)
                                                }
                                            }
                                            .padding(.leading, 8)
                                            .padding(.vertical, 2)
                                        }
                                        if metadata.openWindows.count > 5 {
                                            Text("... and \(metadata.openWindows.count - 5) more")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .padding(.leading, 8)
                                        }
                                    }

                                    if !metadata.runningApps.isEmpty {
                                        Divider().padding(.vertical, 4)

                                        Text("Running Apps (\(metadata.runningApps.count))")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)

                                        ForEach(Array(metadata.runningApps.prefix(5).enumerated()), id: \.offset) { index, app in
                                            Text(app.name)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .padding(.leading, 8)
                                                .textSelection(.enabled)
                                        }
                                        if metadata.runningApps.count > 5 {
                                            Text("... and \(metadata.runningApps.count - 5) more")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .padding(.leading, 8)
                                        }
                                    }
                                }
                                .padding()
                                .frame(width: 300)
                                .background(Color.gray.opacity(0.05))
                                .cornerRadius(8)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(10)
                    }
                }

                // Run Analysis button with provider/model info
                VStack(spacing: 8) {
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

                    // Show current provider and model
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(analyticsService.apiProvider.rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let modelId = analyticsService.selectedModel,
                           let model = analyticsService.apiProvider.availableModels.first(where: { $0.id == modelId }) {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(model.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Get the actual API key (user-set or .env)
                        let actualApiKey: String? = {
                            let userKey = analyticsService.apiKey
                            if let key = userKey, !key.isEmpty {
                                return key
                            }
                            // Fall back to .env
                            switch analyticsService.apiProvider {
                            case .openai:
                                return EnvLoader.shared.get("OPENAI_API_KEY")
                            case .huggingface:
                                return EnvLoader.shared.get("HF_TOKEN")
                            }
                        }()

                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Show masked API key or warning
                        if let key = actualApiKey, !key.isEmpty {
                            let visibleChars = min(4, key.count)
                            let masked = String(key.prefix(visibleChars)) + String(repeating: "*", count: 10)
                            Text(masked)
                                .font(.caption)
                                .foregroundColor(.green)
                                .fontDesign(.monospaced)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                            Text("No API Key")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

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

                // Console logs
                if !analysisLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Analysis Log")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                analysisLogs.removeAll()
                            }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))

                        ScrollView {
                            ScrollViewReader { proxy in
                                Text(analysisLogs.joined(separator: "\n"))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .textSelection(.enabled)
                                    .id("logs")
                                    .onChange(of: analysisLogs.count) { _, _ in
                                        proxy.scrollTo("logs", anchor: .bottom)
                                    }
                            }
                        }
                        .frame(height: 200)
                        .background(Color(NSColor.textBackgroundColor))
                        .border(Color.gray.opacity(0.3))
                    }
                    .padding(.horizontal)
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
                            .chartXAxisLabel("Time in minutes")
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
                        // Auto-save
                        analyticsService.apiProvider = newValue
                        analyticsService.selectedModel = selectedModel?.id
                        // Reload settings to update API key display for new provider
                        loadSettings()
                    }

                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { oldValue, newValue in
                            // Don't save if it's just the masked .env token (contains asterisks)
                            if !newValue.contains("*") {
                                // Auto-save when user types a custom API key
                                analyticsService.apiKey = newValue.isEmpty ? nil : newValue
                            }
                        }

                    // Show .env status
                    let envKey: String? = {
                        switch selectedProvider {
                        case .openai:
                            return EnvLoader.shared.get("OPENAI_API_KEY")
                        case .huggingface:
                            return EnvLoader.shared.get("HF_TOKEN")
                        }
                    }()
                    let envKeyName = selectedProvider == .openai ? "OPENAI_API_KEY" : "HF_TOKEN"
                    let usingEnvToken = (apiKey.isEmpty || apiKey.contains("*")) && envKey != nil

                    if usingEnvToken {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Using \(envKeyName) from .env file")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if apiKey.isEmpty {
                        Text("No \(envKeyName) found in .env file")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else if !apiKey.contains("*") {
                        Text("Using custom API key (overrides .env)")
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

                    // Reasoning effort picker (OpenAI only)
                    if selectedProvider == .openai {
                        HStack {
                            Text("Reasoning Effort:")
                            Picker("", selection: $reasoningEffort) {
                                Text("Minimal").tag("minimal")
                                Text("Medium").tag("medium")
                                Text("High").tag("high")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                            .onChange(of: reasoningEffort) { oldValue, newValue in
                                analyticsService.reasoningEffort = newValue
                            }
                        }
                        Text("Controls how much computational effort OpenAI uses for reasoning. Minimal = fastest, high = most thorough.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Send all screenshots (before & after)", isOn: $sendAllScreenshots)
                        .help("By default, only before-click screenshots are sent to save bandwidth. Enable to send both before and after screenshots.")

                    Toggle("Add click marker on screenshots", isOn: $addClickMarker)
                        .onChange(of: addClickMarker) { oldValue, newValue in
                            AppState.shared.addClickMarker = newValue
                        }
                        .help("Add a red cross marker at the click position on pre-click screenshots.")

                    Text("Settings are saved automatically")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
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
        selectedProvider = analyticsService.apiProvider

        // Load API key from service (user-set key) or show masked .env token
        if let userKey = analyticsService.apiKey, !userKey.isEmpty {
            apiKey = userKey
        } else {
            // Check .env based on provider
            let envKey: String? = {
                switch selectedProvider {
                case .openai:
                    return EnvLoader.shared.get("OPENAI_API_KEY")
                case .huggingface:
                    return EnvLoader.shared.get("HF_TOKEN")
                }
            }()

            if let envToken = envKey, !envToken.isEmpty {
                // Show masked .env token (first 4 chars + 10 asterisks)
                let visibleChars = min(4, envToken.count)
                let masked = String(envToken.prefix(visibleChars)) + String(repeating: "*", count: 10)
                apiKey = masked
            } else {
                apiKey = ""
            }
        }

        // Load the selected model from service, or default to first available
        if let savedModelId = analyticsService.selectedModel,
           let model = selectedProvider.availableModels.first(where: { $0.id == savedModelId }) {
            selectedModel = model
        } else {
            selectedModel = selectedProvider.availableModels.first
        }

        // Load reasoning effort
        reasoningEffort = analyticsService.reasoningEffort

        // Load click marker setting
        addClickMarker = AppState.shared.addClickMarker
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

            // Load metadata - will crash with clear error if it fails
            let data = try! Data(contentsOf: metadataFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let event = try! decoder.decode(ClickEvent.self, from: data)
            metadata.append(event)
        }

        sessionScreenshots = screenshots
        sessionMetadata = metadata

        print("✅ Loaded \(screenshots.count) screenshots and \(metadata.count) metadata entries")

        assert(metadata.count == screenshots.count, "BUG: Screenshots (\(screenshots.count)) and metadata (\(metadata.count)) counts don't match!")
    }

    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async {
            self.analysisLogs.append("[\(timestamp)] \(message)")
        }
    }

    private func runAnalysis() {
        guard let session = selectedSession else { return }

        isAnalyzing = true
        progress = 0.0
        errorMessage = nil
        analysisResult = nil
        analysisLogs.removeAll()

        addLog("Starting analysis for session: \(session.displayName)")
        addLog("Provider: \(analyticsService.apiProvider.rawValue)")
        if let model = analyticsService.selectedModel {
            addLog("Model: \(model)")
        }

        Task {
            do {
                addLog("Loading session data...")
                let result = try await analyticsService.analyzeSession(
                    sessionPath: session.path,
                    sendAllScreenshots: sendAllScreenshots,
                    progressCallback: { prog in
                        DispatchQueue.main.async {
                            self.progress = prog
                        }
                    },
                    logCallback: { log in
                        self.addLog(log)
                    }
                )

                addLog("Analysis complete!")
                addLog("Total apps analyzed: \(result.count)")

                let totalMins = result.reduce(0) { $0 + $1.minutesUsed }
                addLog("Total minutes: \(String(format: "%.1f", totalMins))")

                for (idx, app) in result.prefix(5).enumerated() {
                    addLog("  \(idx + 1). \(app.appName): \(String(format: "%.1f", app.minutesUsed)) min")
                }

                await MainActor.run {
                    addLog("Setting analysisResult in UI...")
                    analysisResult = SessionAnalysisResult(
                        session: session,
                        appUsage: result,
                        totalMinutes: totalMins
                    )
                    isAnalyzing = false
                    addLog("UI updated - analysisResult is now set with \(result.count) apps")
                }
            } catch {
                addLog("ERROR: \(error.localizedDescription)")
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
                .textSelection(.enabled)
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

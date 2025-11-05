import SwiftUI
import Charts

struct AnalyticsView: View {
    @ObservedObject private var analyticsService = AnalyticsService.shared
    @State private var sessions: [SessionInfo] = []
    @State private var selectedSession: SessionInfo?
    @State private var analysisResult: SessionAnalysisResult?
    @State private var isAnalyzing = false
    @State private var progress: Double = 0.0
    @State private var errorMessage: String?

    var body: some View {
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

                Spacer()

                Button(action: loadSessions) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding()

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
        .frame(width: 800, height: 600)
        .onAppear {
            loadSessions()
        }
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
            let isoFormatter = ISO8601DateFormatter()
            guard let date = isoFormatter.date(from: timestampString.replacingOccurrences(of: "-", with: ":")) else {
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

#Preview {
    AnalyticsView()
}

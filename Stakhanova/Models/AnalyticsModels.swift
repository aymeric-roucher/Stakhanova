import Foundation

// Structured output format for LLM response
struct AppUsageAnalysis: Codable {
    let apps: [AppUsageEntry]
}

struct AppUsageEntry: Codable, Identifiable {
    var id: String { appName }
    let appName: String
    let minutesUsed: Double
}

// Session info
struct SessionInfo: Identifiable, Hashable {
    let id: String
    let path: URL
    let startTime: Date
    let eventCount: Int

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: startTime)) (\(eventCount) events)"
    }
}

// Analysis result for display
struct SessionAnalysisResult {
    let session: SessionInfo
    let appUsage: [AppUsageEntry]
    let totalMinutes: Double
}

import Foundation
import AppKit

class AnalyticsService: ObservableObject {
    static let shared = AnalyticsService()

    // Helper function to compress image to 1080p max
    private func compressImage(_ imageData: Data) -> Data? {
        guard let image = NSImage(data: imageData) else { return nil }

        let maxDimension: CGFloat = 1920 // 1080p width
        let currentSize = image.size

        // Calculate new size maintaining aspect ratio
        var newSize = currentSize
        if currentSize.width > maxDimension || currentSize.height > maxDimension {
            let ratio = currentSize.width / currentSize.height
            if currentSize.width > currentSize.height {
                newSize = CGSize(width: maxDimension, height: maxDimension / ratio)
            } else {
                newSize = CGSize(width: maxDimension * ratio, height: maxDimension)
            }
        }

        // Create compressed image
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        newImage.unlockFocus()

        // Convert to JPEG data with 70% quality for better compression
        guard let tiffData = newImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return imageData // Return original if compression fails
        }

        return jpegData
    }

    private let userDefaults = UserDefaults.standard
    private let apiKeyKey = "LLMAPIKey"
    private let apiProviderKey = "LLMProvider"
    private let modelKey = "LLMModel"

    @Published var apiKey: String? {
        didSet {
            userDefaults.set(apiKey, forKey: apiKeyKey)
        }
    }

    @Published var apiProvider: LLMProvider {
        didSet {
            userDefaults.set(apiProvider.rawValue, forKey: apiProviderKey)
        }
    }

    @Published var selectedModel: String? {
        didSet {
            userDefaults.set(selectedModel, forKey: modelKey)
        }
    }

    private init() {
        // Load initial values from UserDefaults or .env

        // Check if provider is set in UserDefaults
        if let rawValue = userDefaults.string(forKey: apiProviderKey),
           let provider = LLMProvider(rawValue: rawValue) {
            self.apiProvider = provider
        } else if EnvLoader.shared.get("HF_TOKEN") != nil {
            // If HF_TOKEN exists in .env, default to HuggingFace
            self.apiProvider = .huggingface
        } else if EnvLoader.shared.get("OPENAI_API_KEY") != nil {
            // If OPENAI_API_KEY exists in .env, default to OpenAI
            self.apiProvider = .openai
        } else {
            // Otherwise default to OpenAI
            self.apiProvider = .openai
        }

        // Load API key from UserDefaults (user-set key overrides .env)
        self.apiKey = userDefaults.string(forKey: apiKeyKey)

        // Load or set default model
        if let savedModel = userDefaults.string(forKey: modelKey) {
            self.selectedModel = savedModel
        } else {
            // Auto-select first model for the provider
            self.selectedModel = self.apiProvider.availableModels.first?.id
        }
    }

    /// Analyze a session folder with batch processing
    func analyzeSession(sessionPath: URL, sendAllScreenshots: Bool = false, progressCallback: @escaping (Double) -> Void, logCallback: @escaping (String) -> Void) async throws -> [AppUsageEntry] {
        logCallback("Scanning session folder...")

        // Load all metadata files
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: sessionPath, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("metadata.json") }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        logCallback("Found \(metadataFiles.count) events to analyze")

        guard !metadataFiles.isEmpty else {
            throw AnalyticsError.noEventsFound
        }

        // Split into batches of 10
        let batchSize = 10
        let batches = stride(from: 0, to: metadataFiles.count, by: batchSize).map {
            Array(metadataFiles[$0..<min($0 + batchSize, metadataFiles.count)])
        }

        logCallback("Processing \(batches.count) batches (batch size: \(batchSize))")

        var allResults: [AppUsageEntry] = []

        for (index, batch) in batches.enumerated() {
            logCallback("Processing batch \(index + 1)/\(batches.count)")

            // Load screenshot pairs and metadata for this batch
            var batchData: [(before: Data?, after: Data?, metadata: ClickEvent)] = []

            for metadataFile in batch {
                logCallback("Loading metadata: \(metadataFile.lastPathComponent)")
                let metadataData = try Data(contentsOf: metadataFile)

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let metadata = try decoder.decode(ClickEvent.self, from: metadataData)

                let timestamp = metadataFile.lastPathComponent
                    .replacingOccurrences(of: "_metadata.json", with: "")

                let beforePath = sessionPath.appendingPathComponent("\(timestamp)_before.png")
                let afterPath = sessionPath.appendingPathComponent("\(timestamp)_after.png")

                let beforeData = try Data(contentsOf: beforePath)
                let afterData = try Data(contentsOf: afterPath)

                batchData.append((before: beforeData, after: afterData, metadata: metadata))
            }

            logCallback("Loaded \(batchData.count) events in batch")

            // Analyze this batch
            logCallback("Calling LLM API for batch \(index + 1)...")
            let batchResult = try await analyzeBatch(batchData: batchData, batchNumber: index + 1, totalBatches: batches.count, sendAllScreenshots: sendAllScreenshots, logCallback: logCallback)
            allResults.append(contentsOf: batchResult.apps)

            logCallback("Batch \(index + 1) complete. Found \(batchResult.apps.count) app(s)")
            for (idx, app) in batchResult.apps.prefix(5).enumerated() {
                logCallback("  \(idx + 1). \(app.appName): \(String(format: "%.1f", app.minutesUsed)) min")
            }
            if batchResult.apps.count > 5 {
                logCallback("  ... and \(batchResult.apps.count - 5) more")
            }

            // Update progress
            progressCallback(Double(index + 1) / Double(batches.count))
        }

        // Aggregate results by app name
        logCallback("Aggregating results from \(allResults.count) entries...")
        let aggregated = aggregateAppUsage(allResults)
        logCallback("Final aggregated results: \(aggregated.count) unique apps")
        for (idx, app) in aggregated.prefix(5).enumerated() {
            logCallback("  \(idx + 1). \(app.appName): \(String(format: "%.1f", app.minutesUsed)) min")
        }
        if aggregated.count > 5 {
            logCallback("  ... and \(aggregated.count - 5) more")
        }
        return aggregated
    }

    /// Get the effective API key for the current provider
    private func getEffectiveApiKey() -> String? {
        switch apiProvider {
        case .openai:
            // User key overrides .env
            if let key = self.apiKey, !key.isEmpty {
                return key
            }
            return EnvLoader.shared.get("OPENAI_API_KEY")
        case .huggingface:
            // User key overrides .env
            if let key = self.apiKey, !key.isEmpty {
                return key
            }
            return EnvLoader.shared.get("HF_TOKEN")
        }
    }

    /// Analyze a batch of click events using LLM
    func analyzeClickEvents(_ events: [ClickEvent]) async throws -> AnalyticsResult {
        // Get API key based on provider
        guard let apiKey = getEffectiveApiKey(), !apiKey.isEmpty else {
            throw AnalyticsError.missingAPIKey
        }

        guard let model = selectedModel else {
            throw AnalyticsError.missingModel
        }

        let prompt = buildAnalysisPrompt(from: events)
        let analysis = try await queryLLM(prompt: prompt, model: model, apiKey: apiKey)

        return AnalyticsResult(
            timestamp: Date(),
            eventsAnalyzed: events.count,
            analysis: analysis,
            events: events
        )
    }

    private func buildAnalysisPrompt(from events: [ClickEvent]) -> String {
        var prompt = """
        Analyze user interaction data to provide insights about productivity, app usage patterns, and behavior.

        I have \(events.count) click events with the following information for each:
        - Timestamp
        - Active application
        - Clicked UI element (type, label, description)
        - All open windows and applications at the time
        - Modifier keys used

        Please analyze these events and provide:
        1. Overall productivity patterns
        2. Most used applications and features
        3. Workflow patterns and context switching behavior
        4. Recommendations for improving efficiency

        Here are the events:

        """

        for (index, event) in events.enumerated() {
            prompt += "\n--- Event \(index + 1) ---\n"
            prompt += "Time: \(event.timestamp.formatted())\n"
            prompt += "App: \(event.activeApp.name)\n"

            if let element = event.clickedElement {
                prompt += "Clicked: \(element.role ?? "unknown") - \(element.title ?? element.label ?? "no label")\n"
            }

            if !event.openWindows.isEmpty {
                prompt += "Open windows: \(event.openWindows.map { $0.ownerName ?? "unknown" }.joined(separator: ", "))\n"
            }

            if !event.modifierFlags.isEmpty {
                prompt += "Modifiers: \(event.modifierFlags.joined(separator: ", "))\n"
            }
        }

        return prompt
    }

    private func queryLLM(prompt: String, model: String, apiKey: String) async throws -> String {
        switch apiProvider {
        case .openai:
            return try await queryOpenAI(prompt: prompt, model: model, apiKey: apiKey)
        case .huggingface:
            return try await queryHuggingFace(prompt: prompt, model: model, apiKey: apiKey)
        }
    }

    private func queryOpenAI(prompt: String, model: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "developer", "content": "You are a productivity analytics assistant."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 4096
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalyticsError.apiRequestFailed
        }

        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("OpenAI API error: \(errorString)")
            }
            throw AnalyticsError.apiRequestFailed
        }

        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return result.choices.first?.message.content ?? ""
    }

    private func queryHuggingFace(prompt: String, model: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://router.huggingface.co/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a productivity analytics assistant."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 4096,
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalyticsError.apiRequestFailed
        }

        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("HuggingFace API error: \(errorString)")
            }
            throw AnalyticsError.apiRequestFailed
        }

        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return result.choices.first?.message.content ?? ""
    }
}

// MARK: - Models

enum LLMProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case huggingface = "HuggingFace"

    var id: String { rawValue }

    var availableModels: [LLMModel] {
        switch self {
        case .openai:
            return [
                LLMModel(id: "gpt-5", name: "GPT-5")
            ]
        case .huggingface:
            return [
                LLMModel(id: "Qwen/Qwen3-VL-30B-A3B-Instruct:novita", name: "Qwen3-VL-30B (Novita)")
            ]
        }
    }
}

struct LLMModel: Identifiable, Hashable, Equatable {
    let id: String
    let name: String

    static func == (lhs: LLMModel, rhs: LLMModel) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct AnalyticsResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let eventsAnalyzed: Int
    let analysis: String
    let events: [ClickEvent]
}

struct OpenAIResponse: Codable {
    let choices: [OpenAIChoice]
}

struct OpenAIChoice: Codable {
    let message: OpenAIMessage
}

struct OpenAIMessage: Codable {
    let content: String
}

extension AnalyticsService {
    private func analyzeBatch(batchData: [(before: Data?, after: Data?, metadata: ClickEvent)], batchNumber: Int, totalBatches: Int, sendAllScreenshots: Bool, logCallback: @escaping (String) -> Void) async throws -> AppUsageAnalysis {
        // Get API key
        guard let apiKey = getEffectiveApiKey(), !apiKey.isEmpty else {
            logCallback("ERROR: No API key available")
            throw AnalyticsError.missingAPIKey
        }

        guard let model = selectedModel else {
            logCallback("ERROR: No model selected")
            throw AnalyticsError.missingModel
        }

        logCallback("Building prompt for batch \(batchNumber)...")

        // Build prompt with structured output request
        let prompt = buildBatchAnalysisPrompt(batchData: batchData, batchNumber: batchNumber, totalBatches: totalBatches, sendAllScreenshots: sendAllScreenshots)

        logCallback("Prompt size: \(prompt.count) characters")
        logCallback("=== FULL PROMPT ===")
        logCallback(prompt)
        logCallback("=== END PROMPT ===")
        logCallback("Making API request to \(apiProvider.rawValue)...")

        // Call LLM with structured output (including screenshots)
        let result = try await queryLLMWithStructuredOutput(prompt: prompt, batchData: batchData, sendAllScreenshots: sendAllScreenshots, model: model, apiKey: apiKey, logCallback: logCallback)

        logCallback("API response received successfully")

        return result
    }

    private func buildBatchAnalysisPrompt(batchData: [(before: Data?, after: Data?, metadata: ClickEvent)], batchNumber: Int, totalBatches: Int, sendAllScreenshots: Bool) -> String {
        var prompt = """
        You are analyzing user productivity data from screen captures and interaction metadata.

        This is batch \(batchNumber) of \(totalBatches). Each batch contains up to 10 click events with screenshots and metadata.

        For each event, I'm providing:
        - \(sendAllScreenshots ? "Before and after screenshots" : "Before-click screenshots") (images attached below)
        - The active application name
        - Timestamp (both human-readable and Unix timestamp in seconds)
        - Clicked UI element details
        - Time between events

        Your task: Estimate how many SECONDS the user spent in each application during this batch.
        Base your estimate on:
        1. Which app was active in each event
        2. Time gaps between consecutive events (calculate using Unix timestamps)
        3. Context from the metadata AND screenshots (what the user was actually doing)

        IMPORTANT: For browsers (Safari, Chrome, Firefox, etc.), look at the screenshots to identify the top-level domain/website being used.
        Instead of reporting time as "Safari" or "Google Chrome", report it by the website domain.
        For example:
        - If the user is on YouTube in Chrome, report it as "youtube" (not "Google Chrome")
        - If the user is on GitHub in Safari, report it as "github" (not "Safari")
        - If the user is on reddit.com, report it as "reddit"
        Use the visible URL bar, page title, or recognizable website UI in the screenshots to identify the domain.

        Look at the screenshots to understand what the user was doing in each application.
        \(sendAllScreenshots ? "Compare before/after screenshots to see what changed." : "Use the before-click screenshots to see what the user was working on.")

        Events in this batch:

        """

        for (index, data) in batchData.enumerated() {
            let metadata = data.metadata
            let unixTimestamp = Int(metadata.timestamp.timeIntervalSince1970)

            // Calculate time since previous event
            var timeSincePrevious = ""
            if index > 0 {
                let prevMetadata = batchData[index - 1].metadata
                let timeDiff = metadata.timestamp.timeIntervalSince(prevMetadata.timestamp)
                timeSincePrevious = String(format: " (%.0f seconds since previous)", timeDiff)
            }

            prompt += """

            Event \(index + 1)\(timeSincePrevious):
            - Time: \(metadata.timestamp.formatted()) (Unix: \(unixTimestamp))
            - Active App: \(metadata.activeApp.name) (bundle: \(metadata.activeApp.bundleIdentifier ?? "unknown"))
            - Mouse Position: (\(Int(metadata.mousePosition.x)), \(Int(metadata.mousePosition.y)))
            """

            if let element = metadata.clickedElement {
                prompt += "\n- Clicked Element: role=\(element.role ?? "nil"), title=\(element.title ?? "nil"), label=\(element.label ?? "nil"), description=\(element.description ?? "nil"), value=\(element.value ?? "nil")"
            }

            if !metadata.modifierFlags.isEmpty {
                prompt += "\n- Modifier Keys: \(metadata.modifierFlags.joined(separator: ", "))"
            }

            if !metadata.openWindows.isEmpty {
                let windowNames = metadata.openWindows.prefix(5).compactMap { $0.ownerName }.joined(separator: ", ")
                prompt += "\n- Open Windows: \(windowNames)"
            }

            prompt += "\n"
        }

        prompt += """


        Provide your analysis as a JSON array of app usage entries. Each entry should have:
        - appName: The application name
        - secondsUsed: Estimated seconds spent (integer, e.g., 150 for 2.5 minutes)

        Only include apps that were actively used. Combine time for the same app across multiple events.
        Use the Unix timestamps to calculate accurate durations.
        """

        return prompt
    }

    private func queryLLMWithStructuredOutput(prompt: String, batchData: [(before: Data?, after: Data?, metadata: ClickEvent)], sendAllScreenshots: Bool, model: String, apiKey: String, logCallback: @escaping (String) -> Void) async throws -> AppUsageAnalysis {
        switch apiProvider {
        case .openai:
            return try await queryOpenAIStructured(prompt: prompt, batchData: batchData, sendAllScreenshots: sendAllScreenshots, model: model, apiKey: apiKey, logCallback: logCallback)
        case .huggingface:
            return try await queryHuggingFaceStructured(prompt: prompt, batchData: batchData, sendAllScreenshots: sendAllScreenshots, model: model, apiKey: apiKey, logCallback: logCallback)
        }
    }

    private func queryOpenAIStructured(prompt: String, batchData: [(before: Data?, after: Data?, metadata: ClickEvent)], sendAllScreenshots: Bool, model: String, apiKey: String, logCallback: @escaping (String) -> Void) async throws -> AppUsageAnalysis {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        logCallback("Request URL: \(url)")
        logCallback("Model: \(model)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build message content with text and images
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]

        // Add screenshots as base64 images (compressed to 1080p)
        for (index, data) in batchData.enumerated() {
            // Always send before screenshot (compressed)
            if let beforeData = data.before,
               let compressedData = compressImage(beforeData) {
                let base64 = compressedData.base64EncodedString()
                let originalSize = Double(beforeData.count) / 1024 / 1024
                let compressedSize = Double(compressedData.count) / 1024 / 1024
                contentArray.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64)"
                    ]
                ])
                logCallback("Added before screenshot for event \(index + 1) (\(String(format: "%.2f", originalSize))MB → \(String(format: "%.2f", compressedSize))MB)")
            }

            // Only send after screenshot if requested
            if sendAllScreenshots, let afterData = data.after,
               let compressedData = compressImage(afterData) {
                let base64 = compressedData.base64EncodedString()
                let originalSize = Double(afterData.count) / 1024 / 1024
                let compressedSize = Double(compressedData.count) / 1024 / 1024
                contentArray.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64)"
                    ]
                ])
                logCallback("Added after screenshot for event \(index + 1) (\(String(format: "%.2f", originalSize))MB → \(String(format: "%.2f", compressedSize))MB)")
            }
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "apps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "appName": ["type": "string"],
                            "secondsUsed": ["type": "number"]
                        ],
                        "required": ["appName", "secondsUsed"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["apps"],
            "additionalProperties": false
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a productivity analytics assistant. Always respond with valid JSON."],
                ["role": "user", "content": contentArray]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "app_usage_analysis",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]

        logCallback("Total message parts (text + images): \(contentArray.count)")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logCallback("Sending request...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logCallback("ERROR: Invalid HTTP response")
            throw AnalyticsError.apiRequestFailed
        }

        logCallback("Response status: \(httpResponse.statusCode)")
        logCallback("Response size: \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                logCallback("API Error: \(errorString)")
            }
            throw AnalyticsError.apiRequestFailed
        }

        logCallback("Parsing response...")
        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = result.choices.first?.message.content else {
            logCallback("ERROR: No content in response")
            throw AnalyticsError.apiRequestFailed
        }

        logCallback("LLM Response:")
        logCallback(content)
        logCallback("---")

        logCallback("Decoding app usage data...")
        return try JSONDecoder().decode(AppUsageAnalysis.self, from: content.data(using: .utf8)!)
    }

    private func queryHuggingFaceStructured(prompt: String, batchData: [(before: Data?, after: Data?, metadata: ClickEvent)], sendAllScreenshots: Bool, model: String, apiKey: String, logCallback: @escaping (String) -> Void) async throws -> AppUsageAnalysis {
        // HuggingFace: Use same approach but without response_format (will parse from content)
        let url = URL(string: "https://router.huggingface.co/v1/chat/completions")!
        logCallback("Request URL: \(url)")
        logCallback("Model: \(model)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build message content with text and images
        var contentArray: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]

        // Add screenshots as base64 images (compressed to 1080p)
        for (index, data) in batchData.enumerated() {
            // Always send before screenshot (compressed)
            if let beforeData = data.before,
               let compressedData = compressImage(beforeData) {
                let base64 = compressedData.base64EncodedString()
                let originalSize = Double(beforeData.count) / 1024 / 1024
                let compressedSize = Double(compressedData.count) / 1024 / 1024
                contentArray.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64)"
                    ]
                ])
                logCallback("Added before screenshot for event \(index + 1) (\(String(format: "%.2f", originalSize))MB → \(String(format: "%.2f", compressedSize))MB)")
            }

            // Only send after screenshot if requested
            if sendAllScreenshots, let afterData = data.after,
               let compressedData = compressImage(afterData) {
                let base64 = compressedData.base64EncodedString()
                let originalSize = Double(afterData.count) / 1024 / 1024
                let compressedSize = Double(compressedData.count) / 1024 / 1024
                contentArray.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64)"
                    ]
                ])
                logCallback("Added after screenshot for event \(index + 1) (\(String(format: "%.2f", originalSize))MB → \(String(format: "%.2f", compressedSize))MB)")
            }
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a productivity analytics assistant. Always respond with valid JSON only, no other text."],
                ["role": "user", "content": contentArray]
            ],
            "max_tokens": 4096,
            "stream": false
        ]

        logCallback("Total message parts (text + images): \(contentArray.count)")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logCallback("Sending request...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logCallback("ERROR: Invalid HTTP response")
            throw AnalyticsError.apiRequestFailed
        }

        logCallback("Response status: \(httpResponse.statusCode)")
        logCallback("Response size: \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                logCallback("API Error: \(errorString)")
            }
            throw AnalyticsError.apiRequestFailed
        }

        logCallback("Parsing response...")
        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = result.choices.first?.message.content else {
            logCallback("ERROR: No content in response")
            throw AnalyticsError.apiRequestFailed
        }

        logCallback("LLM Response:")
        logCallback(content)
        logCallback("---")

        logCallback("Decoding app usage data...")
        // Parse JSON from content
        let analysis = try JSONDecoder().decode(AppUsageAnalysis.self, from: content.data(using: .utf8)!)
        logCallback("Decoded \(analysis.apps.count) apps from LLM response")
        for app in analysis.apps {
            logCallback("  - \(app.appName): \(app.secondsUsed) seconds")
        }
        return analysis
    }

    private func aggregateAppUsage(_ entries: [AppUsageEntry]) -> [AppUsageEntry] {
        var appTotals: [String: Double] = [:]

        for entry in entries {
            appTotals[entry.appName, default: 0] += entry.secondsUsed
        }

        return appTotals.map { AppUsageEntry(appName: $0.key, secondsUsed: $0.value) }
            .sorted(by: { $0.secondsUsed > $1.secondsUsed })
    }
}

enum AnalyticsError: Error, LocalizedError {
    case missingAPIKey
    case missingModel
    case apiRequestFailed
    case noEventsFound

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key not configured. Please set your API key in Settings."
        case .missingModel:
            return "No model selected. Please select a model in Settings."
        case .apiRequestFailed:
            return "API request failed. Check your API key and network connection."
        case .noEventsFound:
            return "No events found in this session."
        }
    }
}

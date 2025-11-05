import Foundation

class AnalyticsService: ObservableObject {
    static let shared = AnalyticsService()

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
        // Load initial values from UserDefaults
        self.apiKey = userDefaults.string(forKey: apiKeyKey)

        if let rawValue = userDefaults.string(forKey: apiProviderKey),
           let provider = LLMProvider(rawValue: rawValue) {
            self.apiProvider = provider
        } else {
            self.apiProvider = .openai
        }

        self.selectedModel = userDefaults.string(forKey: modelKey)
    }

    /// Analyze a session folder with batch processing
    func analyzeSession(sessionPath: URL, progressCallback: @escaping (Double) -> Void) async throws -> [AppUsageEntry] {
        // Load all metadata files
        let metadataFiles = try FileManager.default.contentsOfDirectory(at: sessionPath, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("metadata.json") }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        guard !metadataFiles.isEmpty else {
            throw AnalyticsError.noEventsFound
        }

        // Split into batches of 10
        let batchSize = 10
        let batches = stride(from: 0, to: metadataFiles.count, by: batchSize).map {
            Array(metadataFiles[$0..<min($0 + batchSize, metadataFiles.count)])
        }

        var allResults: [AppUsageEntry] = []

        for (index, batch) in batches.enumerated() {
            // Load screenshot pairs and metadata for this batch
            var batchData: [(before: Data?, after: Data?, metadata: ClickEvent)] = []

            for metadataFile in batch {
                guard let metadataData = try? Data(contentsOf: metadataFile),
                      let metadata = try? JSONDecoder().decode(ClickEvent.self, from: metadataData) else {
                    continue
                }

                let timestamp = metadataFile.lastPathComponent
                    .replacingOccurrences(of: "_metadata.json", with: "")

                let beforePath = sessionPath.appendingPathComponent("\(timestamp)_before.png")
                let afterPath = sessionPath.appendingPathComponent("\(timestamp)_after.png")

                let beforeData = try? Data(contentsOf: beforePath)
                let afterData = try? Data(contentsOf: afterPath)

                batchData.append((before: beforeData, after: afterData, metadata: metadata))
            }

            // Analyze this batch
            let batchResult = try await analyzeBatch(batchData: batchData, batchNumber: index + 1, totalBatches: batches.count)
            allResults.append(contentsOf: batchResult.apps)

            // Update progress
            progressCallback(Double(index + 1) / Double(batches.count))
        }

        // Aggregate results by app name
        return aggregateAppUsage(allResults)
    }

    /// Analyze a batch of click events using LLM
    func analyzeClickEvents(_ events: [ClickEvent]) async throws -> AnalyticsResult {
        // Get API key based on provider
        let apiKey: String
        switch apiProvider {
        case .openai:
            // OpenAI requires manual key
            guard let key = self.apiKey, !key.isEmpty else {
                throw AnalyticsError.missingAPIKey
            }
            apiKey = key
        case .huggingface:
            // HuggingFace: manual key overrides env, fallback to .env
            if let key = self.apiKey, !key.isEmpty {
                apiKey = key
            } else if let envKey = EnvLoader.shared.get("HF_TOKEN") {
                apiKey = envKey
            } else {
                throw AnalyticsError.missingAPIKey
            }
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
    private func analyzeBatch(batchData: [(before: Data?, after: Data?, metadata: ClickEvent)], batchNumber: Int, totalBatches: Int) async throws -> AppUsageAnalysis {
        // Get API key
        let apiKey: String
        switch apiProvider {
        case .openai:
            guard let key = self.apiKey, !key.isEmpty else {
                throw AnalyticsError.missingAPIKey
            }
            apiKey = key
        case .huggingface:
            if let key = self.apiKey, !key.isEmpty {
                apiKey = key
            } else if let envKey = EnvLoader.shared.get("HF_TOKEN") {
                apiKey = envKey
            } else {
                throw AnalyticsError.missingAPIKey
            }
        }

        guard let model = selectedModel else {
            throw AnalyticsError.missingModel
        }

        // Build prompt with structured output request
        let prompt = buildBatchAnalysisPrompt(batchData: batchData, batchNumber: batchNumber, totalBatches: totalBatches)

        // Call LLM with structured output
        let result = try await queryLLMWithStructuredOutput(prompt: prompt, model: model, apiKey: apiKey)

        return result
    }

    private func buildBatchAnalysisPrompt(batchData: [(before: Data?, after: Data?, metadata: ClickEvent)], batchNumber: Int, totalBatches: Int) -> String {
        var prompt = """
        You are analyzing user productivity data from screen captures and interaction metadata.

        This is batch \(batchNumber) of \(totalBatches). Each batch contains up to 10 click events with before/after screenshots and metadata.

        For each event, I'm providing:
        - The active application name
        - Timestamp
        - Clicked UI element details
        - Time between events (approximate)

        Your task: Estimate how many MINUTES the user spent in each application during this batch.
        Base your estimate on:
        1. Which app was active in each event
        2. Time gaps between consecutive events
        3. Context from the metadata

        Events in this batch:

        """

        for (index, data) in batchData.enumerated() {
            let metadata = data.metadata
            prompt += """

            Event \(index + 1):
            - Time: \(metadata.timestamp.formatted())
            - Active App: \(metadata.activeApp.name)
            - Clicked Element: \(metadata.clickedElement?.title ?? metadata.clickedElement?.label ?? "N/A")

            """
        }

        prompt += """


        Provide your analysis as a JSON array of app usage entries. Each entry should have:
        - appName: The application name
        - minutesUsed: Estimated minutes spent (can be fractional, e.g., 2.5)

        Only include apps that were actively used. Combine time for the same app across multiple events.
        """

        return prompt
    }

    private func queryLLMWithStructuredOutput(prompt: String, model: String, apiKey: String) async throws -> AppUsageAnalysis {
        switch apiProvider {
        case .openai:
            return try await queryOpenAIStructured(prompt: prompt, model: model, apiKey: apiKey)
        case .huggingface:
            return try await queryHuggingFaceStructured(prompt: prompt, model: model, apiKey: apiKey)
        }
    }

    private func queryOpenAIStructured(prompt: String, model: String, apiKey: String) async throws -> AppUsageAnalysis {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "apps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "appName": ["type": "string"],
                            "minutesUsed": ["type": "number"]
                        ],
                        "required": ["appName", "minutesUsed"],
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
                ["role": "user", "content": prompt]
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
        guard let content = result.choices.first?.message.content else {
            throw AnalyticsError.apiRequestFailed
        }

        return try JSONDecoder().decode(AppUsageAnalysis.self, from: content.data(using: .utf8)!)
    }

    private func queryHuggingFaceStructured(prompt: String, model: String, apiKey: String) async throws -> AppUsageAnalysis {
        // HuggingFace: Use same approach but without response_format (will parse from content)
        let url = URL(string: "https://router.huggingface.co/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a productivity analytics assistant. Always respond with valid JSON only, no other text."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 2048,
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
        guard let content = result.choices.first?.message.content else {
            throw AnalyticsError.apiRequestFailed
        }

        // Parse JSON from content
        return try JSONDecoder().decode(AppUsageAnalysis.self, from: content.data(using: .utf8)!)
    }

    private func aggregateAppUsage(_ entries: [AppUsageEntry]) -> [AppUsageEntry] {
        var appTotals: [String: Double] = [:]

        for entry in entries {
            appTotals[entry.appName, default: 0] += entry.minutesUsed
        }

        return appTotals.map { AppUsageEntry(appName: $0.key, minutesUsed: $0.value) }
            .sorted(by: { $0.minutesUsed > $1.minutesUsed })
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

import Foundation

class AnalyticsService: ObservableObject {
    private let userDefaults = UserDefaults.standard
    private let apiKeyKey = "LLMAPIKey"
    private let apiProviderKey = "LLMProvider"

    var apiKey: String? {
        get { userDefaults.string(forKey: apiKeyKey) }
        set { userDefaults.set(newValue, forKey: apiKeyKey) }
    }

    var apiProvider: LLMProvider {
        get {
            guard let rawValue = userDefaults.string(forKey: apiProviderKey),
                  let provider = LLMProvider(rawValue: rawValue) else {
                return .anthropic
            }
            return provider
        }
        set { userDefaults.set(newValue.rawValue, forKey: apiProviderKey) }
    }

    /// Analyze a batch of click events using LLM
    func analyzeClickEvents(_ events: [ClickEvent]) async throws -> AnalyticsResult {
        guard let apiKey = apiKey else {
            throw AnalyticsError.missingAPIKey
        }

        // Prepare the prompt with all event context
        let prompt = buildAnalysisPrompt(from: events)

        // Send to LLM API
        let analysis = try await queryLLM(prompt: prompt, apiKey: apiKey)

        return AnalyticsResult(
            timestamp: Date(),
            eventsAnalyzed: events.count,
            analysis: analysis,
            events: events
        )
    }

    private func buildAnalysisPrompt(from events: [ClickEvent]) -> String {
        var prompt = """
        You are analyzing user interaction data to provide insights about productivity, app usage patterns, and behavior.

        I have \(events.count) click events with the following information for each:
        - Timestamp
        - Active application
        - Clicked UI element (type, label, description)
        - All open windows and applications at the time
        - Screenshots before and after the click
        - Modifier keys used

        Please analyze these events and provide:
        1. Overall productivity patterns
        2. Most used applications and features
        3. Workflow patterns and context switching behavior
        4. Time spent on different types of tasks
        5. Recommendations for improving efficiency

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

    private func queryLLM(prompt: String, apiKey: String) async throws -> String {
        switch apiProvider {
        case .anthropic:
            return try await queryAnthropic(prompt: prompt, apiKey: apiKey)
        case .openai:
            return try await queryOpenAI(prompt: prompt, apiKey: apiKey)
        }
    }

    private func queryAnthropic(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "claude-3-5-sonnet-20241022",
            "max_tokens": 4096,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AnalyticsError.apiRequestFailed
        }

        let result = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return result.content.first?.text ?? ""
    }

    private func queryOpenAI(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4-turbo-preview",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 4096
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AnalyticsError.apiRequestFailed
        }

        let result = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return result.choices.first?.message.content ?? ""
    }
}

// MARK: - Models

enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic = "Anthropic"
    case openai = "OpenAI"

    var id: String { rawValue }
}

struct AnalyticsResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let eventsAnalyzed: Int
    let analysis: String
    let events: [ClickEvent]
}

struct AnthropicResponse: Codable {
    let content: [AnthropicContent]
}

struct AnthropicContent: Codable {
    let text: String
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

enum AnalyticsError: Error {
    case missingAPIKey
    case apiRequestFailed
}

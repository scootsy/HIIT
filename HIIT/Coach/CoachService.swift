import Foundation

/// Which large-language-model service powers the optional AI coach. The user
/// brings their own API key; requests go straight from the device to the
/// chosen provider — there is no middleman server.
enum CoachProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic, openai, gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "Anthropic API key (sk-ant-…)"
        case .openai: return "OpenAI API key (sk-…)"
        case .gemini: return "Gemini API key (AIza…)"
        }
    }

    /// Where to create a key, for the settings footer.
    var consoleName: String {
        switch self {
        case .anthropic: return "console.anthropic.com"
        case .openai: return "platform.openai.com"
        case .gemini: return "aistudio.google.com"
        }
    }
}

/// Optional AI coach: sends a compact summary of recent sessions to the
/// user's chosen provider (with their own key) and returns short, practical
/// feedback. Entirely opt-in — the app works fully without it.
enum CoachService {

    struct CoachError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let systemPrompt = """
    You are a friendly, evidence-based HIIT coach reviewing a user's recent workout data from their interval-training app. \
    Reply with: a short assessment (2-3 sentences), then 2 specific and actionable suggestions for upcoming sessions, \
    then one line of encouragement. Be concrete about paces, durations, and recovery. Plain text only, no markdown. \
    You are not a medical professional; if anything in the data looks concerning, suggest they check with one.
    """

    /// True when the user has saved a key for their selected provider —
    /// gates every "Ask the AI coach" entry point in the UI.
    static func isConfigured(_ provider: CoachProvider) -> Bool {
        KeychainHelper.load(provider: provider)?.isEmpty == false
    }

    static func feedback(provider: CoachProvider, apiKey: String, summary: String) async throws -> String {
        switch provider {
        case .anthropic: return try await anthropicFeedback(apiKey: apiKey, summary: summary)
        case .openai: return try await openAIFeedback(apiKey: apiKey, summary: summary)
        case .gemini: return try await geminiFeedback(apiKey: apiKey, summary: summary)
        }
    }

    // MARK: - Shared plumbing

    private static func post(url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: url) else {
            throw CoachError(message: "Bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachError(message: "No response from server")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard http.statusCode == 200 else {
            // All three providers wrap failures as {"error": {"message": …}}.
            let apiMessage = ((json["error"] as? [String: Any])?["message"] as? String)
            throw CoachError(message: apiMessage ?? "Request failed (HTTP \(http.statusCode))")
        }
        return json
    }

    private static func finish(text: String, cutShort: Bool) throws -> String {
        guard !text.isEmpty else {
            throw CoachError(message: cutShort
                ? "The reply ran out of room — please try again."
                : "Empty response — please try again.")
        }
        // Don't render a mid-sentence cutoff as if it were the whole reply.
        if cutShort {
            return text + "\n\n(The reply was cut short.)"
        }
        return text
    }

    // MARK: - Anthropic

    private static func anthropicFeedback(apiKey: String, summary: String) async throws -> String {
        // max_tokens caps the model's thinking plus the visible reply on this
        // model, so leave generous headroom over the short reply we expect.
        let json = try await post(
            url: "https://api.anthropic.com/v1/messages",
            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
            body: [
                "model": "claude-opus-5",
                "max_tokens": 6000,
                "output_config": ["effort": "low"],
                "system": systemPrompt,
                "messages": [["role": "user", "content": summary]],
            ])
        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            throw CoachError(message: "The model declined this request. Please try again.")
        }
        let text = (json["content"] as? [[String: Any]])?
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n") ?? ""
        return try finish(text: text, cutShort: stopReason == "max_tokens")
    }

    // MARK: - OpenAI

    private static func openAIFeedback(apiKey: String, summary: String) async throws -> String {
        // GPT-5-family models spend reasoning tokens from the same cap as the
        // visible reply (and only accept max_completion_tokens), so leave the
        // same generous headroom here.
        let json = try await post(
            url: "https://api.openai.com/v1/chat/completions",
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: [
                "model": "gpt-5-mini",
                "max_completion_tokens": 6000,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": summary],
                ],
            ])
        let choice = (json["choices"] as? [[String: Any]])?.first
        let text = ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
        let finishReason = choice?["finish_reason"] as? String
        return try finish(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          cutShort: finishReason == "length")
    }

    // MARK: - Gemini

    private static func geminiFeedback(apiKey: String, summary: String) async throws -> String {
        // Gemini 2.5 models think by default and the thinking budget draws
        // from maxOutputTokens — generous headroom again.
        let json = try await post(
            url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
            headers: ["x-goog-api-key": apiKey],
            body: [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [["role": "user", "parts": [["text": summary]]]],
                "generationConfig": ["maxOutputTokens": 6000],
            ])
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        let text = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n") ?? ""
        let finishReason = candidate?["finishReason"] as? String
        return try finish(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          cutShort: finishReason == "MAX_TOKENS")
    }

    // MARK: - Session summary

    static func buildSummary(sessions: [WorkoutSession], settings: SettingsStore) -> String {
        var lines: [String] = []
        var profile: [String] = []
        if let age = settings.value.age { profile.append("age \(age)") }
        if let kg = settings.value.weightKg { profile.append(String(format: "weight %.0f kg", kg)) }
        if let resting = settings.value.restingHR { profile.append(String(format: "resting HR %.0f", resting)) }
        profile.append("experience \(settings.experience.label.lowercased())")
        lines.append("Profile: " + profile.joined(separator: ", ") + ".")
        lines.append("Recent sessions (most recent first):")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for session in sessions.prefix(10) {
            var parts: [String] = []
            parts.append(formatter.string(from: session.date))
            parts.append(session.equipment.label)
            parts.append("\"\(session.planName)\"")
            parts.append("\(Int(session.totalSeconds / 60)) min")
            parts.append("\(session.completedWorkIntervals)/\(session.totalWorkIntervals) intervals")
            if let avg = session.avgHeartRate {
                var hr = String(format: "avg HR %.0f", avg)
                if let peak = session.maxHeartRate { hr += String(format: " (max %.0f)", peak) }
                parts.append(hr)
            }
            if let rpe = session.rpe { parts.append("RPE \(rpe)/10") }
            parts.append(String(format: "~%.0f kcal", session.estimatedCalories))
            if !session.notes.isEmpty { parts.append("notes: \(session.notes)") }
            lines.append("- " + parts.joined(separator: ", "))
        }
        if sessions.isEmpty {
            lines.append("- none yet")
        }
        return lines.joined(separator: "\n")
    }
}

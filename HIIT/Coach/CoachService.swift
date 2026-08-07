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

/// Optional AI coach: a small chat grounded in a compact summary of recent
/// sessions, sent to the user's chosen provider (with their own key). The
/// model can *propose* concrete plan changes through a fixed action menu —
/// rendered as tap-to-confirm buttons; nothing applies without the user's
/// tap. Entirely opt-in — the app works fully without it.
enum CoachService {

    struct CoachError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct ChatTurn {
        enum Role { case user, assistant }
        var role: Role
        var text: String
    }

    private static let coachPersona = """
    You are a friendly, evidence-based HIIT coach inside an interval-training app, chatting with the user about their \
    recent training. Be concrete about paces, durations, and recovery. Keep replies under 150 words, plain text only, \
    no markdown. You are not a medical professional; if anything in the data looks concerning, suggest they check with one.
    """

    private static let firstReplyStyle = """
    For your FIRST reply only: a short assessment (2-3 sentences), then 2 specific and actionable suggestions for \
    upcoming sessions, then one line of encouragement.
    """

    /// The model proposes changes as machine-readable trailing lines; the app
    /// renders them as buttons. Line-based (not fenced JSON) because all three
    /// providers reproduce plain prefixed lines far more reliably.
    private static let actionProtocol = """
    You can also propose real changes to the user's plan — but only when they ask for a change (easier, harder, \
    shorter, longer, walking recoveries). Propose at most 2 by adding, as the FINAL lines of your reply, one line \
    each in exactly this form (no markdown, no backticks):
    ACTION {"type":"adjust_level","equipment":"treadmill","delta":-1,"label":"Ease treadmill targets one notch"}
    Allowed actions:
    - {"type":"adjust_level","equipment":"treadmill"|"bike"|"outdoor","delta":-2..2,"label":"..."} — shifts that equipment's difficulty (one level ≈ 0.2 mph of work speed).
    - {"type":"set_next_minutes","minutes":8..60,"label":"..."} — the length of the user's next session.
    - {"type":"prefer_walk_recoveries","enabled":true|false,"label":"..."} — walking vs jogging treadmill recoveries.
    The app shows these as buttons the user must tap to apply. Never claim an action has been applied, and never \
    invent other action types.
    """

    static var systemPrompt: String {
        [coachPersona, firstReplyStyle, actionProtocol].joined(separator: "\n\n")
    }

    /// True when the user has saved a key for their selected provider —
    /// gates every "Ask the AI coach" entry point in the UI.
    static func isConfigured(_ provider: CoachProvider) -> Bool {
        KeychainHelper.load(provider: provider)?.isEmpty == false
    }

    static func chat(provider: CoachProvider, apiKey: String, turns: [ChatTurn]) async throws -> String {
        // Anthropic and Gemini require strictly alternating roles, and hidden
        // app notes (applied actions) can stack consecutive user turns —
        // collapse them before every request.
        let merged = merged(turns)
        switch provider {
        case .anthropic: return try await anthropicChat(apiKey: apiKey, turns: merged)
        case .openai: return try await openAIChat(apiKey: apiKey, turns: merged)
        case .gemini: return try await geminiChat(apiKey: apiKey, turns: merged)
        }
    }

    private static func merged(_ turns: [ChatTurn]) -> [ChatTurn] {
        var result: [ChatTurn] = []
        for turn in turns {
            if let last = result.last, last.role == turn.role {
                result[result.count - 1].text = last.text + "\n\n" + turn.text
            } else {
                result.append(turn)
            }
        }
        return result
    }

    // MARK: - Proposed actions

    /// A change the model proposed. Applied only by an explicit user tap,
    /// through the app's ordinary setters — the model itself writes nothing.
    struct CoachAction: Identifiable, Equatable {
        let id = UUID()
        var type: String
        var equipment: String?
        var delta: Int?
        var minutes: Int?
        var enabled: Bool?
        var label: String

        var isValid: Bool {
            switch type {
            case "adjust_level":
                guard let delta, (-2...2).contains(delta), delta != 0,
                      let equipment, Equipment(rawValue: equipment) != nil else { return false }
                return true
            case "set_next_minutes":
                guard let minutes, (8...60).contains(minutes) else { return false }
                return true
            case "prefer_walk_recoveries":
                return enabled != nil
            default:
                return false
            }
        }
    }

    /// Splits a model reply into display text and validated proposed actions.
    /// Malformed or out-of-menu lines are dropped silently — the reply text
    /// still renders.
    static func parseActions(from reply: String) -> (text: String, actions: [CoachAction]) {
        var textLines: [String] = []
        var actions: [CoachAction] = []
        for line in reply.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ACTION "),
               let data = String(trimmed.dropFirst(7)).data(using: .utf8),
               let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                var action = CoachAction(
                    type: (raw["type"] as? String) ?? "",
                    equipment: raw["equipment"] as? String,
                    delta: raw["delta"] as? Int,
                    minutes: raw["minutes"] as? Int,
                    enabled: raw["enabled"] as? Bool,
                    label: (raw["label"] as? String) ?? "")
                if action.label.isEmpty { action.label = fallbackLabel(action) }
                if action.isValid, actions.count < 2 { actions.append(action) }
            } else {
                textLines.append(line)
            }
        }
        return (textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), actions)
    }

    private static func fallbackLabel(_ action: CoachAction) -> String {
        switch action.type {
        case "adjust_level":
            let delta = action.delta ?? 0
            return "\(delta > 0 ? "Raise" : "Ease") \(action.equipment ?? "") targets \(abs(delta) == 1 ? "one notch" : "\(abs(delta)) notches")"
        case "set_next_minutes":
            return "Make the next session \(action.minutes ?? 0) minutes"
        case "prefer_walk_recoveries":
            return (action.enabled == true) ? "Switch to walking recoveries" : "Switch to jogging recoveries"
        default:
            return "Apply change"
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

    private static func anthropicChat(apiKey: String, turns: [ChatTurn]) async throws -> String {
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
                "messages": turns.map {
                    ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
                },
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

    private static func openAIChat(apiKey: String, turns: [ChatTurn]) async throws -> String {
        // GPT-5-family models spend reasoning tokens from the same cap as the
        // visible reply (and only accept max_completion_tokens), so leave the
        // same generous headroom here.
        let messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
            + turns.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] }
        let json = try await post(
            url: "https://api.openai.com/v1/chat/completions",
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: [
                "model": "gpt-5-mini",
                "max_completion_tokens": 6000,
                "messages": messages,
            ])
        let choice = (json["choices"] as? [[String: Any]])?.first
        let text = ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
        let finishReason = choice?["finish_reason"] as? String
        return try finish(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          cutShort: finishReason == "length")
    }

    // MARK: - Gemini

    private static func geminiChat(apiKey: String, turns: [ChatTurn]) async throws -> String {
        // Gemini 2.5 models think by default and the thinking budget draws
        // from maxOutputTokens — generous headroom again.
        let json = try await post(
            url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
            headers: ["x-goog-api-key": apiKey],
            body: [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": turns.map { turn -> [String: Any] in
                    ["role": turn.role == .user ? "user" : "model", "parts": [["text": turn.text]]]
                },
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

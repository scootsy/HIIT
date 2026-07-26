import Foundation

/// Optional AI coach: sends a compact summary of recent sessions to the
/// Anthropic Messages API (with the user's own key) and returns short,
/// practical feedback. Entirely opt-in — the app works fully without it.
enum CoachService {

    struct CoachError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func feedback(apiKey: String, summary: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw CoachError(message: "Bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let system = """
        You are a friendly, evidence-based HIIT coach reviewing a user's recent workout data from their interval-training app. \
        Reply with: a short assessment (2-3 sentences), then 2 specific and actionable suggestions for upcoming sessions, \
        then one line of encouragement. Be concrete about paces, durations, and recovery. Plain text only, no markdown. \
        You are not a medical professional; if anything in the data looks concerning, suggest they check with one.
        """

        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 4000,
            "output_config": ["effort": "low"],
            "system": system,
            "messages": [["role": "user", "content": summary]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoachError(message: "No response from server")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard http.statusCode == 200 else {
            let apiMessage = ((json?["error"] as? [String: Any])?["message"] as? String)
            throw CoachError(message: apiMessage ?? "Request failed (HTTP \(http.statusCode))")
        }
        if let stop = json?["stop_reason"] as? String, stop == "refusal" {
            throw CoachError(message: "The model declined this request. Please try again.")
        }
        let text = (json?["content"] as? [[String: Any]])?
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n") ?? ""
        guard !text.isEmpty else {
            throw CoachError(message: "Empty response — please try again.")
        }
        return text
    }

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

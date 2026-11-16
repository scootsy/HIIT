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

/// Which model each provider's coach request names — and how the app keeps
/// working when a provider retires that model.
///
/// Providers shut models down on their own schedule (both the OpenAI and the
/// Gemini model this app originally shipped with were given end dates within
/// a year of release), and a sideloaded app can't count on a prompt update.
/// So the built-in default is only a starting point: when a provider answers
/// "that model doesn't exist", the app lists the models the user's key can
/// reach, picks the closest current equivalent with the rules below, and
/// remembers the answer. A model name typed into Settings always wins and is
/// never second-guessed.
///
/// Foundation-only on purpose, so the selection rules run in the unit tests.
enum CoachModelCatalog {

    static func defaultModel(for provider: CoachProvider) -> String {
        switch provider {
        case .anthropic: return "claude-opus-5-5"
        case .openai: return "gpt-5-mini"
        case .gemini: return "gemini-2.5-flash"
        }
    }

    /// The model a request should name: the user's explicit choice, else the
    /// one auto-discovery last settled on, else the built-in default.
    static func resolve(provider: CoachProvider, override: String?, remembered: String?) -> String {
        if let override = cleaned(override) { return override }
        if let remembered = cleaned(remembered) { return remembered }
        return defaultModel(for: provider)
    }

    static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Recognizing a retired model

    /// True when a failed request reads as "this model can't be used" rather
    /// than a bad key, a rate limit, or a malformed request. All three
    /// providers answer 404 for an unknown model; a few retirements surface
    /// as other 4xx codes whose text names the model.
    static func looksLikeUnavailableModel(status: Int, message: String) -> Bool {
        if status == 404 { return true }
        guard status == 400 || status == 403 || status == 410 else { return false }
        let text = message.lowercased()
        guard text.contains("model") else { return false }
        let markers = ["not found", "does not exist", "deprecated", "decommissioned",
                       "no longer", "not supported", "only supported", "retired",
                       "shut down", "unknown model", "invalid model", "not available"]
        return markers.contains { text.contains($0) }
    }

    // MARK: - Picking a replacement

    /// One entry from a provider's "list models" response, reduced to what
    /// the selection rules need.
    struct Listing: Equatable {
        var id: String
        /// False when the provider says the model can't serve this kind of
        /// request (Gemini publishes this per model).
        var usable: Bool = true
        /// Seconds since 1970 when known — a tie-breaker only.
        var created: Double = 0
    }

    /// The best current model for the coach among what the key can reach,
    /// or nil when nothing recognizable is listed. `excluding` is the model
    /// that just failed.
    static func bestModel(for provider: CoachProvider, among listings: [Listing], excluding failed: String? = nil) -> String? {
        // Gemini's list prefixes every id with "models/"; requests don't.
        func bare(_ id: String) -> String {
            id.hasPrefix("models/") ? String(id.dropFirst(7)) : id
        }
        let usable = listings.filter { $0.usable && bare($0.id) != failed }
        switch provider {
        case .anthropic: return bestAnthropic(usable)
        case .openai: return bestOpenAI(usable)
        case .gemini: return bestGemini(usable)
        }
    }

    /// Dotted or dashed numeric version, compared component-wise:
    /// "6.1" > "5.10" > "5.4" > "5".
    struct Version: Comparable, Equatable {
        var parts: [Int]

        init?(_ text: Substring) {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            var parsed: [Int] = []
            for piece in pieces {
                guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else {
                    return nil
                }
                parsed.append(value)
            }
            guard !parsed.isEmpty else { return nil }
            parts = parsed
        }

        init(parts: [Int]) { self.parts = parts }

        static func < (lhs: Version, rhs: Version) -> Bool {
            for index in 0..<max(lhs.parts.count, rhs.parts.count) {
                let left = index < lhs.parts.count ? lhs.parts[index] : 0
                let right = index < rhs.parts.count ? rhs.parts[index] : 0
                if left != right { return left < right }
            }
            return false
        }

        static func == (lhs: Version, rhs: Version) -> Bool {
            !(lhs < rhs) && !(rhs < lhs)
        }
    }

    private struct Candidate {
        var id: String
        var rank: Int
        var version: Version
        var created: Double
    }

    /// Lowest rank wins, then newest version, then newest listing; the id
    /// breaks any remaining tie so the choice is deterministic.
    private static func pick(_ candidates: [Candidate]) -> String? {
        candidates.min { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.version != b.version { return a.version > b.version }
            if a.created != b.created { return a.created > b.created }
            return a.id < b.id
        }?.id
    }

    private static func isDateStamp(_ text: Substring) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Claude ids read `claude-<family>-<major>[-<minor>]`, sometimes with a
    /// trailing date snapshot. Opus is the coach's tier; Sonnet is the
    /// fallback when a key can't reach any Opus.
    private static func bestAnthropic(_ listings: [Listing]) -> String? {
        var candidates: [Candidate] = []
        for listing in listings {
            var pieces = listing.id.split(separator: "-")
            guard pieces.count >= 3, pieces[0] == "claude" else { continue }
            let family = pieces[1]
            let familyRank: Int
            switch family {
            case "opus": familyRank = 0
            case "sonnet": familyRank = 2
            default: continue
            }
            pieces.removeFirst(2)
            var dated = false
            if let last = pieces.last, isDateStamp(last) {
                dated = true
                pieces.removeLast()
            }
            guard !pieces.isEmpty, pieces.count <= 2 else { continue }
            var numbers: [Int] = []
            for piece in pieces {
                guard piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else {
                    numbers = []
                    break
                }
                numbers.append(value)
            }
            guard !numbers.isEmpty else { continue }
            // An undated id is the stable alias — prefer it to a snapshot of
            // the same model.
            candidates.append(Candidate(id: listing.id,
                                        rank: familyRank + (dated ? 1 : 0),
                                        version: Version(parts: numbers),
                                        created: listing.created))
        }
        // Newest model first across "alias" and "snapshot" forms of a family:
        // rank separates families, so fold the dated penalty in after version.
        return candidates.min { a, b in
            let familyA = a.rank / 2, familyB = b.rank / 2
            if familyA != familyB { return familyA < familyB }
            if a.version != b.version { return a.version > b.version }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.created != b.created { return a.created > b.created }
            return a.id < b.id
        }?.id
    }

    /// Words that mark an OpenAI id as something other than a general chat
    /// model (speech, images, search, coding agents, …) or as a tier this
    /// endpoint can't serve.
    private static let openAIExcluded = ["audio", "realtime", "transcribe", "tts", "image", "search",
                                         "codex", "instruct", "embedding", "moderation", "preview",
                                         "latest", "vision", "turbo", "pro", "research", "computer",
                                         "oss", "guard"]

    /// OpenAI ids read `gpt-<version>[-<tier>]`. The coach wants the small,
    /// inexpensive general tier: "mini" through GPT-5.x, renamed "terra" in
    /// later generations. The untiered model is the next choice, then the
    /// smallest tiers, then anything else that still looks like a chat model.
    private static func bestOpenAI(_ listings: [Listing]) -> String? {
        var candidates: [Candidate] = []
        for listing in listings {
            let pieces = listing.id.split(separator: "-")
            guard pieces.count >= 2, pieces.count <= 3, pieces[0] == "gpt" else { continue }
            guard let version = Version(pieces[1]), version >= Version(parts: [5]) else { continue }
            let tier = pieces.count == 3 ? String(pieces[2]) : ""
            if openAIExcluded.contains(where: { tier.contains($0) }) { continue }
            // A trailing date component would have made four pieces
            // (gpt-5-mini-2025-08-07) and been dropped above; a bare year
            // can't be a tier name either.
            if !tier.isEmpty, tier.allSatisfy({ $0.isNumber }) { continue }
            let rank: Int
            switch tier {
            case "mini", "terra": rank = 0
            case "": rank = 1
            case "nano", "luna": rank = 2
            default: rank = 3
            }
            candidates.append(Candidate(id: listing.id, rank: rank, version: version, created: listing.created))
        }
        return pick(candidates)
    }

    /// Gemini ids read `gemini-<version>-<family>[-lite]` (the list API
    /// prefixes them with "models/"). Stable Flash is the coach's tier, then
    /// Flash-Lite, then Pro; previews and experiments are never picked.
    private static func bestGemini(_ listings: [Listing]) -> String? {
        var candidates: [Candidate] = []
        for listing in listings {
            let bare = listing.id.hasPrefix("models/") ? String(listing.id.dropFirst(7)) : listing.id
            let pieces = bare.split(separator: "-")
            guard pieces.count >= 3, pieces.count <= 4, pieces[0] == "gemini",
                  let version = Version(pieces[1]) else { continue }
            let rank: Int
            if pieces.count == 3, pieces[2] == "flash" {
                rank = 0
            } else if pieces.count == 4, pieces[2] == "flash", pieces[3] == "lite" {
                rank = 1
            } else if pieces.count == 3, pieces[2] == "pro" {
                rank = 2
            } else {
                continue
            }
            candidates.append(Candidate(id: bare, rank: rank, version: version, created: listing.created))
        }
        return pick(candidates)
    }
}

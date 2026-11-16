import Foundation

/// The AI coach's model-selection rules: which model a request names, when a
/// provider's error means "that model is gone", and which listed model takes
/// its place. Sample lists mix real ids from each provider's catalogue over
/// time with the look-alikes the rules must refuse (speech, image, search,
/// preview and dated-snapshot variants).
func runCoachModelTests() {
    typealias Listing = CoachModelCatalog.Listing

    // Resolution order: explicit setting, then the remembered discovery,
    // then the built-in default. Blank strings count as "not set".
    expect(CoachModelCatalog.resolve(provider: .anthropic, override: nil, remembered: nil) == "claude-opus-5-5",
           "anthropic default model")
    expect(CoachModelCatalog.resolve(provider: .openai, override: "  my-model \n", remembered: "auto") == "my-model",
           "an explicit model wins and is trimmed")
    expect(CoachModelCatalog.resolve(provider: .openai, override: "   ", remembered: "auto-pick") == "auto-pick",
           "a blank override falls through to the remembered model")
    expect(CoachModelCatalog.resolve(provider: .gemini, override: "", remembered: "") == CoachModelCatalog.defaultModel(for: .gemini),
           "blank values fall through to the default")

    // Retired-model detection.
    expect(CoachModelCatalog.looksLikeUnavailableModel(status: 404, message: "model: claude-opus-9"),
           "404 always reads as an unavailable model")
    expect(CoachModelCatalog.looksLikeUnavailableModel(
        status: 400, message: "The model `gpt-5-mini` has been deprecated, learn more here"),
           "a 400 naming a deprecated model is an unavailable model")
    expect(CoachModelCatalog.looksLikeUnavailableModel(
        status: 400, message: "This model is only supported in v1/responses and not in v1/chat/completions."),
           "an endpoint mismatch is treated as an unavailable model")
    expect(!CoachModelCatalog.looksLikeUnavailableModel(status: 401, message: "Incorrect API key provided"),
           "a bad key is not a model problem")
    expect(!CoachModelCatalog.looksLikeUnavailableModel(status: 429, message: "Rate limit reached for model gpt-5-mini"),
           "a rate limit is not a model problem")
    expect(!CoachModelCatalog.looksLikeUnavailableModel(status: 400, message: "messages: roles must alternate"),
           "a malformed request is not a model problem")
    expect(!CoachModelCatalog.looksLikeUnavailableModel(status: 400, message: "max_tokens is not supported; use max_completion_tokens"),
           "a 400 that never mentions the model is not a model problem")

    // Version ordering is numeric, not lexical.
    func version(_ text: String) -> CoachModelCatalog.Version {
        guard let parsed = CoachModelCatalog.Version(Substring(text)) else {
            fputs("FAIL: \(text) should parse as a version\n", stderr)
            exit(1)
        }
        return parsed
    }
    expect(version("5.10") > version("5.4"), "5.10 is newer than 5.4")
    expect(version("6.1") > version("5.10"), "6.1 is newer than 5.10")
    expect(version("5") == version("5.0"), "5 and 5.0 are the same version")
    expect(CoachModelCatalog.Version(Substring("4o")) == nil, "4o is not a numeric version")
    expect(CoachModelCatalog.Version(Substring("")) == nil, "empty is not a version")
    expect(CoachModelCatalog.Version(Substring("5.")) == nil, "a trailing dot is not a version")

    func ids(_ list: [String]) -> [Listing] { list.map { Listing(id: $0) } }

    // OpenAI: the small general tier, newest generation, never a specialist.
    let openAI2026 = ids([
        "gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-5", "gpt-5-mini", "gpt-5-nano",
        "gpt-5-mini-2025-08-07", "gpt-5-chat-latest", "gpt-5-pro", "gpt-5-codex", "gpt-5.4", "gpt-5.4-mini",
        "gpt-5.4-nano", "gpt-5.4-pro", "gpt-image-1", "gpt-realtime", "gpt-audio-mini", "gpt-5-search-api",
        "gpt-4o-mini-tts", "gpt-4o-transcribe", "o3", "o4-mini", "text-embedding-3-small", "whisper-1",
        "omni-moderation-latest", "dall-e-3", "sora-2",
    ])
    expect(CoachModelCatalog.bestModel(for: .openai, among: openAI2026) == "gpt-5.4-mini",
           "newest mini wins over older minis and every other tier")
    expect(CoachModelCatalog.bestModel(for: .openai, among: openAI2026, excluding: "gpt-5.4-mini") == "gpt-5-mini",
           "the failed model is never chosen again")
    let openAIRenamed = ids(["gpt-5.4-mini", "gpt-5.6-terra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6.1-luna",
                             "gpt-6.1-terra-2026-10-26", "gpt-6.1-pro"])
    expect(CoachModelCatalog.bestModel(for: .openai, among: openAIRenamed) == "gpt-6.1-terra",
           "a renamed small tier in a newer generation outranks the old mini")
    expect(CoachModelCatalog.bestModel(for: .openai, among: ids(["gpt-7", "gpt-7-luna", "gpt-7-sol"])) == "gpt-7",
           "with no small general tier, the untiered model is next")
    expect(CoachModelCatalog.bestModel(for: .openai, among: ids(["gpt-7-luna", "gpt-7-sol"])) == "gpt-7-luna",
           "the smallest tier beats an unknown one")
    expect(CoachModelCatalog.bestModel(for: .openai, among: ids(["gpt-9-zeta"])) == "gpt-9-zeta",
           "an unrecognised tier is still better than nothing")
    expect(CoachModelCatalog.bestModel(for: .openai, among: ids(["gpt-4o", "gpt-4.1-mini", "whisper-1", "gpt-image-1"])) == nil,
           "nothing recognisable means no automatic choice")
    expect(CoachModelCatalog.bestModel(for: .openai, among: [
        Listing(id: "gpt-6-mini", created: 100), Listing(id: "gpt-6-terra", created: 200),
    ]) == "gpt-6-terra", "equal tier and version fall back to the newest listing")

    // Gemini: stable Flash, newest version; ids arrive prefixed "models/".
    let gemini = [
        Listing(id: "models/gemini-2.5-flash"), Listing(id: "models/gemini-2.5-pro"),
        Listing(id: "models/gemini-2.5-flash-lite"), Listing(id: "models/gemini-3.5-flash"),
        Listing(id: "models/gemini-3.6-flash"), Listing(id: "models/gemini-3.8-flash"),
        Listing(id: "models/gemini-3.5-flash-lite"), Listing(id: "models/gemini-3.8-pro"),
        Listing(id: "models/gemini-3.9-flash-preview"), Listing(id: "models/gemini-4-flash-preview-09-2026"),
        Listing(id: "models/gemini-flash-latest"), Listing(id: "models/gemini-3.8-flash-image"),
        Listing(id: "models/gemini-3.8-flash-tts"), Listing(id: "models/gemini-embedding-001", usable: false),
        Listing(id: "models/imagen-4.0-generate-001", usable: false), Listing(id: "models/gemma-3-27b-it"),
        Listing(id: "models/gemini-9.9-flash", usable: false),
    ]
    expect(CoachModelCatalog.bestModel(for: .gemini, among: gemini) == "gemini-3.8-flash",
           "newest stable Flash wins; previews, aliases and non-chat models are ignored; the prefix is stripped")
    expect(CoachModelCatalog.bestModel(for: .gemini, among: gemini, excluding: "gemini-3.8-flash") == "gemini-3.6-flash",
           "the failed Gemini model is excluded even though the list prefixes ids")
    expect(CoachModelCatalog.bestModel(for: .gemini, among: [
        Listing(id: "models/gemini-3.5-flash-lite"), Listing(id: "models/gemini-3.8-pro"),
    ]) == "gemini-3.5-flash-lite", "Flash-Lite outranks Pro when no stable Flash is listed")
    expect(CoachModelCatalog.bestModel(for: .gemini, among: [Listing(id: "models/gemini-3.8-pro")]) == "gemini-3.8-pro",
           "Pro is the last resort")
    expect(CoachModelCatalog.bestModel(for: .gemini, among: [Listing(id: "models/gemini-flash-latest")]) == nil,
           "an alias alone is not auto-selected")

    // Anthropic: newest Opus, the undated alias over a dated snapshot.
    let anthropic = ids([
        "claude-fable-5-2", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-sonnet-5-5",
        "claude-haiku-5-5", "claude-opus-4-5-20251101", "claude-sonnet-4-5-20250929",
    ])
    expect(CoachModelCatalog.bestModel(for: .anthropic, among: anthropic) == "claude-opus-5-5",
           "newest Opus wins")
    expect(CoachModelCatalog.bestModel(for: .anthropic, among: anthropic, excluding: "claude-opus-5-5") == "claude-opus-5",
           "the next Opus down follows")
    expect(CoachModelCatalog.bestModel(for: .anthropic, among: ids(["claude-opus-6-20270101", "claude-opus-6", "claude-opus-5-5"])) == "claude-opus-6",
           "an undated alias beats the dated snapshot of the same model")
    expect(CoachModelCatalog.bestModel(for: .anthropic, among: ids(["claude-opus-6-20270101", "claude-opus-5-5"])) == "claude-opus-6-20270101",
           "a newer model listed only as a snapshot still beats an older alias")
    expect(CoachModelCatalog.bestModel(for: .anthropic, among: ids(["claude-sonnet-5-5", "claude-haiku-5-5", "claude-sonnet-5"])) == "claude-sonnet-5-5",
           "Sonnet stands in when the key reaches no Opus")
    expect(CoachModelCatalog.bestModel(for: .anthropic, among: ids(["claude-haiku-5-5", "claude-fable-5-2"])) == nil,
           "other families are never auto-selected")

    print("Coach model checks passed")
}

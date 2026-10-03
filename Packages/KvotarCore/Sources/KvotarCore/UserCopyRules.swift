import Foundation

/// The copy rule every user-visible string answers to (Baseline §10, STEP_239): the app never
/// names its own polling — no cadence, no throttling, no retries. One list, so the tests that
/// sweep the explanation registry, the notifications and the History payloads cannot drift apart
/// the way their seven inline lists did.
public enum UserCopyRules {
    /// Word stems, matched case-insensitively from a word start, so `poll` catches `polling` and
    /// `polled` but not `apollo`. `429` must stand alone.
    public static let pollingWords = [
        "poll", "cadence", "throttl", "backoff", "back off", "backing off", "rate limit",
        "rate-limit", "endpoint", "next in", "retry", "429",
    ]

    /// The first banned word `text` contains, or nil.
    public static func pollingWord(in text: String) -> String? {
        pollingWords.first { word in
            let tail = word.last!.isNumber ? "\\b" : ""
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + tail
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

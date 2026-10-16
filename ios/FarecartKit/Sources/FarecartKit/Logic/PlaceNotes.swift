import Foundation

/// What the detail screen may show from a listing's free-text `notes`.
///
/// Researchers write provenance into `notes` ("Address confirmed on …", "UNSURE: …", "Plentiful
/// listing …", "CTA: #20 Madison"). Riders only need the part that helps them visit, so this strips
/// everything from `UNSURE:` on, drops sentences that read as citations or contain raw URLs, and
/// lifts the "CTA: …" sentence out into its own field.
public struct PlaceNotes: Sendable, Hashable {
    /// Plain-language notes for the rider, or `nil` when nothing survives the cleanup.
    public var body: String?
    /// "#20 Madison bus; Blue Line Western" when the notes mention nearby CTA service.
    public var transitHint: String?

    public init(body: String? = nil, transitHint: String? = nil) {
        self.body = body
        self.transitHint = transitHint
    }

    public static let empty = PlaceNotes()

    /// Fragments that mark a sentence as researcher-internal rather than rider-facing.
    static let internalMarkers: [String] = [
        "listing", "listed on", "listed as", "confirm", "verify", "per chain policy", "source", "locator",
        "store list", "store page", "snippet", "automated fetch", "hours as of", "hours from", "contact ",
        "served by gcfd", "agrees", "borderless", "vivery", "official", "store #", "giveaway_events",
        "address from", "phone from", "inferred", "third-party", "as of jan", "as of feb", "as of mar",
        "as of apr", "as of may", "as of jun", "as of jul", "as of aug", "as of sep", "as of oct",
        "as of nov", "as of dec", "survived", "block",
    ]

    public static func clean(_ raw: String?) -> PlaceNotes {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .empty }
        if let unsure = text.range(of: "UNSURE") {
            text = String(text[..<unsure.lowerBound])
        }
        var kept: [String] = []
        var transit: String?
        for sentence in splitSentences(text) {
            let lowered = sentence.lowercased()
            if lowered.hasPrefix("cta:") || lowered.hasPrefix("cta ") {
                let hint = sentence.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
                if !hint.isEmpty { transit = hint }
                continue
            }
            if looksInternal(lowered) || containsURL(lowered) { continue }
            kept.append(sentence)
        }
        var body = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // A dangling fragment left by the UNSURE cut ("… - ") is not a sentence.
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "-–—;, "))
        if body.count < 3 { body = "" }
        return PlaceNotes(body: body.isEmpty ? nil : body, transitHint: transit)
    }

    /// Splits on sentence ends (". ", "; ") without breaking "#20 Madison bus; Blue Line" inside a
    /// CTA sentence, which is handled as one unit because it starts with "CTA:".
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var inCTA = false
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            if !inCTA, current.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("cta:") { inCTA = true }
            guard !inCTA else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            // "0.3 mi" and "example.org" stay together; a sentence ends at ". " / ";".
            if (character == "." && (next.isWhitespace || next == ")")) || character == ";" {
                flush(&current, into: &sentences)
            }
        }
        flush(&current, into: &sentences)
        return sentences
    }

    private static func flush(_ current: inout String, into sentences: inout [String]) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        current = ""
    }

    static func looksInternal(_ lowered: String) -> Bool {
        if lowered.hasPrefix("(") && lowered.hasSuffix(")") { return true }
        return internalMarkers.contains { lowered.contains($0) }
    }

    static func containsURL(_ lowered: String) -> Bool {
        if lowered.contains("http://") || lowered.contains("https://") || lowered.contains("www.") { return true }
        // "petesfresh.com", "chicagosfoodbank.org/locations"
        let domainEndings = [".com", ".org", ".net", ".us", ".gov", ".edu"]
        return domainEndings.contains { ending in
            guard let range = lowered.range(of: ending) else { return false }
            let before = lowered[..<range.lowerBound]
            return before.last.map { $0.isLetter || $0.isNumber } ?? false
        }
    }
}

extension Place {
    /// Rider-facing notes and the nearby-CTA hint, with researcher text removed.
    public var publicNotes: PlaceNotes { PlaceNotes.clean(notes) }
}

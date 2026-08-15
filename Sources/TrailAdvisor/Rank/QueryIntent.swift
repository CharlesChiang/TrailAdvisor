import Foundation

/// The handful of things worth reading out of a free-text request without a model.
///
/// Deliberately shallow: it recognises duration, distance, gradient and difficulty, and
/// ignores everything else rather than guessing. This is the layer the LLM later replaces
/// for nuance — but it stays, because it is what runs when the model is unreachable.
struct QueryIntent: Sendable, Equatable {
    var targetDistanceKm: Double?
    var targetAscentMeters: Double?
    var targetMinutes: Double?
    var maximumDifficulty: Int?
    var minimumDifficulty: Int?

    /// Walking pace used to turn a requested duration into a distance when the caller
    /// supplies no reference of their own.
    static let defaultPaceMinPerKm: Double = 15

    /// Paces outside this range are not someone walking. The app learned this the hard
    /// way: a hike fed by simulated GPS covered 3.3 km in 100 seconds — 0.5 min/km — and
    /// since pace converts "a gentle 2 hours" into a distance, that asked for 240 km.
    static let plausiblePaceMinPerKm: ClosedRange<Double> = 5...45

    init(query: String, constraints: Constraints?) {
        let text = query.lowercased()

        let pace: Double = {
            guard let reference = constraints?.paceMinPerKm,
                  Self.plausiblePaceMinPerKm.contains(reference)
            else { return Self.defaultPaceMinPerKm }
            return reference
        }()

        if let hours = Self.number(in: text, matching: #"(\d+(?:\.\d+)?)\s*(?:h\b|hour|hours|hr)"#) {
            targetMinutes = hours * 60
        } else if let minutes = Self.number(in: text, matching: #"(\d+)\s*(?:min|minute|minutes)"#) {
            targetMinutes = minutes
        }

        if let km = Self.number(in: text, matching: #"(\d+(?:\.\d+)?)\s*(?:km|kilometre|kilometer)"#) {
            targetDistanceKm = km
        } else if let minutes = targetMinutes {
            targetDistanceKm = minutes / pace
        } else if let usual = constraints?.referenceDistanceKm {
            if text.contains("short") || text.contains("quick") { targetDistanceKm = usual * 0.6 }
            if text.contains("long") { targetDistanceKm = usual * 1.5 }
        }

        if text.contains("flat") || text.contains("gentle") || text.contains("level") {
            targetAscentMeters = 50
        } else if ["steep", "climb", "summit", "peak", "ascent"].contains(where: text.contains) {
            targetAscentMeters = max(constraints?.maxAscentMeters ?? 600, 600)
        }

        if ["easy", "relaxed", "recovery"].contains(where: text.contains) {
            maximumDifficulty = 2
        }
        if ["hard", "challenging", "difficult", "tough"].contains(where: text.contains) {
            minimumDifficulty = 3
        }
    }

    private static func number(in text: String, matching pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range])
    }
}

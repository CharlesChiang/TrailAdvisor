import Foundation

/// Ranks routes without a model.
///
/// This is step 4 of the build order and the checkpoint that matters: with only this, the
/// service is useful and completely testable, and nothing has been spent on an API key. It
/// is also what runs whenever the model is unreachable, so it is not scaffolding to be
/// thrown away — it is the floor the LLM layer sits on.
///
/// Deterministic on purpose: the same inputs always produce the same order, so the golden
/// query set can assert on it.
enum HeuristicRanker {

    struct Ranked: Sendable {
        let route: Route
        let penalty: Double
        let reason: String
    }

    static func rank(
        query: String,
        constraints: Constraints?,
        slate: [Route],
        limit: Int
    ) -> [Ranked] {
        guard !slate.isEmpty else { return [] }

        let intent = QueryIntent(query: query, constraints: constraints)
        let targetKm = intent.targetDistanceKm
            ?? constraints?.targetDistanceKm
            ?? constraints?.referenceDistanceKm
            ?? 8
        let targetAscent = intent.targetAscentMeters
            ?? constraints?.referenceAscentMeters
            ?? 300

        let scored = slate.map { route -> Ranked in
            // Relative error: a 1 km miss matters more on a 2 km walk than a 20 km one.
            var penalty = abs(route.lengthKm - targetKm) / max(targetKm, 1) * 2
            penalty += abs(Double(route.ascentMeters) - targetAscent) / max(targetAscent, 100)

            if let ceiling = intent.maximumDifficulty ?? constraints?.maxDifficulty,
               route.difficulty > ceiling {
                penalty += Double(route.difficulty - ceiling)
            }
            if let floor = intent.minimumDifficulty, route.difficulty < floor {
                penalty += Double(floor - route.difficulty) * 0.5
            }
            if let ceiling = constraints?.maxAscentMeters, Double(route.ascentMeters) > ceiling {
                penalty += (Double(route.ascentMeters) - ceiling) / max(ceiling, 100)
            }

            return Ranked(route: route, penalty: penalty,
                          reason: reason(for: route, intent: intent, constraints: constraints))
        }

        return scored
            // Ties break on id so the order is stable across runs and assertable.
            .sorted { $0.penalty == $1.penalty ? $0.route.id < $1.route.id : $0.penalty < $1.penalty }
            .prefix(limit)
            .map { $0 }
    }

    /// Every reason cites a concrete number. Without that rule these collapse into "a
    /// beautiful scenic route", which is the failure mode that makes the whole feature
    /// feel worthless.
    private static func reason(
        for route: Route,
        intent: QueryIntent,
        constraints: Constraints?
    ) -> String {
        let shape = String(format: "%.1f km with %d m of ascent", route.lengthKm, route.ascentMeters)

        if intent.targetAscentMeters ?? 0 >= 600 {
            return String(format: "%@ — %.0f m of climbing per km, sustained %.0f%% at its steepest.",
                          shape, route.ascentPerKm, route.maxSustainedGradient)
        }
        if let minutes = intent.targetMinutes {
            return String(format: "%@ — about %.0f minutes against the %.0f you asked for.",
                          shape, route.estimatedMinutes, minutes)
        }
        guard let usual = constraints?.referenceDistanceKm, usual > 0 else {
            return "\(shape), graded \(route.difficultyLabel)."
        }

        let comparison: String
        switch route.lengthKm / usual {
        case ..<0.75:  comparison = String(format: "shorter than your usual %.1f km", usual)
        case ..<1.25:  comparison = String(format: "close to your usual %.1f km", usual)
        case ..<1.75:  comparison = String(format: "a step up from your usual %.1f km", usual)
        default:       comparison = String(format: "well beyond your usual %.1f km", usual)
        }
        return "\(shape) — \(comparison)."
    }
}

import Foundation
import Hummingbird

// The HTTP contract the iOS app is written against. Change it only with a version bump.

/// What the caller asks for.
///
/// Note what is **not** here: no heart rate, no per-hike records, no GPS traces, no
/// timestamps, no identifier. The device derives `Constraints` locally from its own
/// history and sends only the resulting envelope. Two anonymous scalars is a real
/// reduction from a hike history — it is not anonymity, and it shouldn't be described as
/// such.
struct RecommendationRequest: Decodable, Sendable {
    let query: String
    let area: Area
    var constraints: Constraints?
    var limit: Int?
    var locale: String?

    struct Area: Decodable, Sendable {
        let lat: Double
        let lon: Double
        var radiusKm: Double?
    }
}

struct Constraints: Decodable, Sendable {
    var targetDistanceKm: Double?
    var maxAscentMeters: Double?
    var maxDifficulty: Int?
    /// What the hiker usually does — used so a reason can say "close to your usual 7.5 km".
    var referenceDistanceKm: Double?
    var referenceAscentMeters: Double?
    var paceMinPerKm: Double?
}

struct RecommendationResponse: ResponseEncodable, Sendable {
    let engine: String
    let picks: [Pick]
    /// The full records, so the app can render without a second round trip to
    /// Outdooractive. This is most of the latency win.
    let candidates: [Route]
    let slate: Slate
    let generatedAt: String

    struct Pick: Encodable, Sendable {
        let trailId: String
        let rank: Int
        let reason: String
    }

    struct Slate: Encodable, Sendable {
        let cell: String
        let size: Int
        let ingestedAt: String?
    }
}

struct CellCount: Encodable, Sendable {
    let cell: String
    let routeCount: Int
}

struct HealthResponse: ResponseEncodable, Sendable {
    let status: String
    let routeCount: Int
    let ingestedAt: String?
    let ageHours: Double?
    /// Which grid cells actually hold routes. The test project's data is spread across
    /// Europe rather than concentrated where you'd expect, so this is the only honest
    /// answer to "what does this service cover".
    let coverage: [CellCount]
}

struct CoverageResponse: ResponseEncodable, Sendable {
    let cellSizeDegrees: Double
    let cells: [CellCount]
}

struct APIError: Error, ResponseEncodable, Sendable {
    let code: String
    let message: String

    static let noSlate = APIError(code: "no_slate_for_area",
                                  message: "No route slate covers that area.")
    static func invalid(_ message: String) -> APIError {
        APIError(code: "invalid_request", message: message)
    }
}

/// Top-level code in `main.swift` is `@MainActor` under Swift 6, and
/// `ISO8601DateFormatter` is a non-Sendable class — a shared instance there cannot cross
/// into a request handler. `ISO8601FormatStyle` is a value type, so this is safe to call
/// from anywhere and costs nothing to construct.
func iso8601(_ date: Date) -> String {
    date.formatted(.iso8601)
}

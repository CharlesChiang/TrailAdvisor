import Foundation
import GISTools

/// A normalized Outdooractive route, with the terrain features the API doesn't expose.
///
/// The derived fields are the reason this service exists: they're computable from the
/// geometry but too expensive to do per request on a phone, and they're what the ranker
/// actually reasons over.
struct Route: Sendable, Codable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let lengthMeters: Double
    let ascentMeters: Int
    let descentMeters: Int
    let difficulty: Int
    let categoryName: String
    let imageURL: String?

    // Derived — see `Route.derive(...)`
    let ascentPerKm: Double
    let maxSustainedGradient: Double
    let minAltitude: Double
    let maxAltitude: Double
    let estimatedMinutes: Double
    let centroidLat: Double
    let centroidLon: Double

    /// Outdooractive's raw `"lon,lat,alt lon,lat,alt …"` string, stored verbatim.
    /// Kept in its wire form so the client parses it with exactly the same code it
    /// already uses for the API's own responses.
    let geometry: String

    var lengthKm: Double { lengthMeters / 1000 }

    var difficultyLabel: String {
        switch difficulty {
        case 1: return "easy"
        case 2: return "moderate"
        case 3: return "intermediate"
        case 4: return "difficult"
        case 5: return "very difficult"
        default: return "expert"
        }
    }
}

// MARK: - Deriving terrain features

extension Route {

    /// Window used for the sustained-gradient measure, in metres.
    ///
    /// A single steep step between two GPS fixes says nothing about how a route feels;
    /// half a kilometre of sustained climbing does.
    static let gradientWindowMeters: Double = 500

    static func derive(from tour: OATour) -> Route? {
        let coordinates = tour.parsedGeometry
        guard !coordinates.isEmpty else { return nil }

        let lengthMeters = tour.length ?? pathLength(coordinates)
        guard lengthMeters > 0 else { return nil }

        let altitudes = coordinates.compactMap(\.altitude)
        let ascent = tour.elevation?.ascent ?? Int(ascentFromAltitudes(altitudes))
        let lengthKm = lengthMeters / 1000

        return Route(
            id: tour.id,
            title: tour.title?.strippingHTML ?? "Untitled Route",
            summary: String((tour.shortText?.strippingHTML ?? "").prefix(160)),
            lengthMeters: lengthMeters,
            ascentMeters: ascent,
            descentMeters: tour.elevation?.descent ?? 0,
            difficulty: tour.rating?.difficulty ?? 1,
            categoryName: tour.category?.name?.strippingHTML ?? "",
            imageURL: tour.primaryImage?.imageURL,
            ascentPerKm: lengthKm > 0 ? Double(ascent) / lengthKm : 0,
            maxSustainedGradient: maxSustainedGradient(coordinates),
            minAltitude: altitudes.min() ?? 0,
            maxAltitude: altitudes.max() ?? 0,
            estimatedMinutes: naismithMinutes(lengthKm: lengthKm, ascentMeters: Double(ascent)),
            centroidLat: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
            centroidLon: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count),
            geometry: tour.geometry ?? ""
        )
    }

    static func pathLength(_ coordinates: [Coordinate3D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// Positive elevation change only — descent is not effort in the same way.
    static func ascentFromAltitudes(_ altitudes: [Double]) -> Double {
        zip(altitudes, altitudes.dropFirst()).reduce(0) { $0 + max(0, $1.1 - $1.0) }
    }

    /// Naismith's rule: walking pace plus a penalty for climbing.
    ///
    /// Crude, but it turns two numbers a hiker doesn't think in into one they do — nobody
    /// asks for "8 km with 400 m of ascent", they ask for "about three hours".
    static func naismithMinutes(lengthKm: Double, ascentMeters: Double) -> Double {
        lengthKm * 12 + ascentMeters / 100 * 10
    }

    /// Steepest `gradientWindowMeters` stretch anywhere on the route, as a percentage.
    static func maxSustainedGradient(_ coordinates: [Coordinate3D]) -> Double {
        guard coordinates.count > 1 else { return 0 }

        var steepest = 0.0
        var start = 0
        var runningDistance = 0.0

        for end in 1..<coordinates.count {
            runningDistance += coordinates[end - 1].distance(to: coordinates[end])

            // Shrink from the left until the window is no longer than the target.
            while runningDistance > gradientWindowMeters, start < end - 1 {
                runningDistance -= coordinates[start].distance(to: coordinates[start + 1])
                start += 1
            }

            guard runningDistance >= gradientWindowMeters * 0.5,
                  let lowAltitude = coordinates[start].altitude,
                  let highAltitude = coordinates[end].altitude
            else { continue }

            let rise = highAltitude - lowAltitude
            steepest = max(steepest, rise / runningDistance * 100)
        }
        return steepest
    }
}

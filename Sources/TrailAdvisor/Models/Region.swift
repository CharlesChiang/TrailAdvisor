import Foundation

/// Great-circle distance in metres.
///
/// Deliberately not `CLLocation.distance(from:)`: that returns different values for
/// identical inputs, which the app discovered when it broke exhaustive test assertions.
/// Same reasoning here — ranking must be reproducible.
func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let earthRadius = 6_371_008.8
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
}

/// A coarse geographic cell that a request's coordinates are snapped to.
///
/// **This exists for cache stability, not for geography.** Selecting a slate from the
/// caller's exact coordinates would give every caller a slightly different slate, and a
/// slate that differs per caller cannot be cached — which is the whole basis of the
/// prompt-caching design. Snapping to a grid means everyone in the same area shares one
/// byte-identical slate.
///
/// Half a degree is roughly 55 km north–south, so a 30 km search from anywhere in a cell
/// still lands on a sensible set of routes.
struct GridCell: Sendable, Codable, Hashable {
    static let sizeDegrees = 0.5

    let latIndex: Int
    let lonIndex: Int

    init(latitude: Double, longitude: Double) {
        latIndex = Int(floor(latitude / Self.sizeDegrees))
        lonIndex = Int(floor(longitude / Self.sizeDegrees))
    }

    var id: String { "\(latIndex),\(lonIndex)" }

    /// The cell's centre — what radius selection actually measures from.
    var center: (latitude: Double, longitude: Double) {
        ((Double(latIndex) + 0.5) * Self.sizeDegrees,
         (Double(lonIndex) + 0.5) * Self.sizeDegrees)
    }
}

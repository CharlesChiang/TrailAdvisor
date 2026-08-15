import Foundation
import GISTools

// The Outdooractive Data API wire shapes, modelled against live responses from the
// api-dev-oa test project. These mirror the app's own DTOs deliberately — the two must
// agree about what the API returns, and divergence between them is a bug in one of them.
//
// Quirks modelled faithfully:
//   • /oois/ returns objects keyed by type ("tour"), not a generic envelope.
//   • `geometry` is a space-separated "lon,lat,alt" string — NOT GeoJSON.
//   • ascent/descent live under `elevation`, difficulty under `rating`.
//   • Text fields contain HTML fragments and must be stripped.

struct OAFilterResponse: Decodable, Sendable {
    let data: [IDBox]
    struct IDBox: Decodable, Sendable { let id: String }
}

struct OAOoisResponse: Decodable, Sendable {
    let tour: [OATour]?
}

struct OATour: Decodable, Sendable {
    let id: String
    let title: String?
    let shortText: String?
    let length: Double?
    let geometry: String?
    let elevation: OAElevation?
    let rating: OARating?
    let primaryImage: OAImageRef?
    let category: OACategoryRef?

    /// Parsed into the same `gis-tools` types the iOS app draws from, so the geometry has
    /// one representation across client and server rather than two that drift.
    var parsedGeometry: [Coordinate3D] {
        guard let geometry, !geometry.isEmpty else { return [] }
        return geometry.split(separator: " ").compactMap { vertex in
            let parts = vertex.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 2 else { return nil }
            return Coordinate3D(
                latitude: parts[1],
                longitude: parts[0],
                altitude: parts.count >= 3 ? parts[2] : nil)
        }
    }
}

struct OAElevation: Decodable, Sendable {
    let ascent: Int?
    let descent: Int?
    let minAltitude: Int?
    let maxAltitude: Int?
}

struct OARating: Decodable, Sendable {
    let difficulty: Int?
}

struct OAImageRef: Decodable, Sendable {
    let id: String?

    var imageURL: String? {
        guard let id else { return nil }
        return "https://img.oastatic.com/img2/\(id)/700x400r/image.jpg"
    }
}

struct OACategoryRef: Decodable, Sendable {
    let name: String?
}

// MARK: - HTML stripping

extension String {
    /// API text fields are HTML fragments. Strip tags and decode the entities that
    /// actually occur in this data set.
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

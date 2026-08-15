import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum OutdooractiveError: Error, CustomStringConvertible {
    case badURL
    case http(Int)

    var description: String {
        switch self {
        case .badURL: return "could not build request URL"
        case let .http(code): return "Outdooractive returned HTTP \(code)"
        }
    }
}

/// The two-phase Outdooractive fetch, server-side.
///
/// This is the whole reason the service exists. The Data API has no "routes near here"
/// call: `/filter/tour` returns bare IDs and `/oois/{ids}` returns the records. Doing that
/// per request from a phone either truncates the result or hangs.
struct OutdooractiveClient: Sendable {

    /// The public test credentials documented at developers.outdooractive.com — the same
    /// ones the app uses. A production deployment reads a real key from the environment.
    static let baseURL = "https://www.outdooractive.com/api/project/api-dev-oa"
    let apiKey = ProcessInfo.processInfo.environment["OA_API_KEY"] ?? "yourtest-outdoora-ctiveapi"

    /// `/filter/tour` ignores **every** filter it accepts.
    ///
    /// `limit` is not honoured — a search returns all ~9,800 ids regardless — and neither
    /// are `lat`, `lon`, or `radius`: calls 480 km apart return the identical set, as does
    /// a call with no location parameters. Verified against the live api-dev-oa project.
    ///
    /// So this sends none of them and truncates client-side. Sending parameters the server
    /// ignores would imply a filter is being applied when none is; location filtering
    /// happens later, from the geometry, in `RouteStore.slate(near:)`.
    func fetchIDs(limit: Int) async throws -> [String] {
        let response: OAFilterResponse = try await get("/filter/tour")
        return Array(response.data.map(\.id).prefix(limit))
    }

    func fetchTours(ids: [String]) async throws -> [OATour] {
        var tours: [OATour] = []
        for chunk in ids.chunked(into: 25) {
            let response: OAOoisResponse = try await get("/oois/\(chunk.joined(separator: ","))")
            tours.append(contentsOf: response.tour ?? [])
        }
        return tours
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(string: Self.baseURL + path) else {
            throw OutdooractiveError.badURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)] + query
        guard let url = components.url else { throw OutdooractiveError.badURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OutdooractiveError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

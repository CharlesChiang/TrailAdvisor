import Foundation
import Logging

/// Walks Outdooractive once and writes a normalized route pool.
///
/// **There is no region concept at ingest, and that is a finding rather than a
/// simplification.** `/filter/tour` accepts `lat`, `lon` and `radius` and ignores all
/// three: two calls 480 km apart return the identical 9,837 ids, as does a call with no
/// location parameters at all. Asking it for "routes near here" is asking a question it
/// does not answer.
///
/// So the service does the filtering itself, at query time, from the centroids it derives
/// while normalizing. That is only affordable because the geometry has already been parsed
/// once here rather than per request — and it is something the app, which trusts the
/// upstream filter, currently gets wrong.
struct IngestJob: Sendable {
    let client: OutdooractiveClient
    let store: RouteStore
    let logger: Logger

    /// How many routes to pull. The test project holds ~9,800; a fuller pool means better
    /// geographic coverage at the cost of a longer job (25 records per request).
    static let poolSize = 1200

    @discardableResult
    func run(poolSize: Int = IngestJob.poolSize) async -> Int {
        do {
            logger.info("fetching route ids…")
            let ids = try await client.fetchIDs(limit: poolSize)
            logger.info("  \(ids.count) ids")

            let tours = try await client.fetchTours(ids: ids)
            let routes = tours.compactMap(Route.derive(from:))
            logger.info("  \(tours.count) records → \(routes.count) usable routes")

            try await store.replaceAll(with: routes, at: Date())
            return routes.count
        } catch {
            // A failed ingest must never take the service down: the previous pool stays
            // served and its age is reported on /v1/health.
            logger.error("ingest failed: \(error)")
            return 0
        }
    }
}

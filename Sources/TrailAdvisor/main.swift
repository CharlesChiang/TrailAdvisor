import Foundation
import Hummingbird
import Logging

// TrailAdvisor — a recommendation service over Outdooractive's route data.
//
// Build order step 4: aggregation, storage, and deterministic ranking. No LLM, no API key,
// no cloud account. The service is complete and testable at this point; the model layer
// (steps 5–7) sits on top of it and degrades back to it whenever the model is unreachable.

let logger = Logger(label: "trail-advisor")

let databasePath = ProcessInfo.processInfo.environment["DB_PATH"] ?? "trailadvisor.sqlite"
let store = try RouteStore(path: databasePath)
let ingest = IngestJob(client: OutdooractiveClient(), store: store, logger: logger)

/// `swift run TrailAdvisor ingest` walks Outdooractive and exits — the scheduled job.
/// Without the argument the HTTP server starts. One binary means the server and the job
/// can never disagree about the schema.
/// `TrailAdvisor healthcheck` exits 0 when the store holds routes.
///
/// A Docker HEALTHCHECK needs something to run *inside* the container, and this image has
/// no wget and no curl — `ubuntu:noble` ships neither, and adding one just to poll
/// ourselves would be a package and an attack surface for nothing. The binary already
/// knows the answer.
if CommandLine.arguments.dropFirst().first == "healthcheck" {
    let info = try? await store.ingestInfo()
    exit((info?.count ?? 0) > 0 ? 0 : 1)
}

if CommandLine.arguments.dropFirst().first == "ingest" {
    let count = await ingest.run()
    logger.info("stored \(count) routes")
    exit(count > 0 ? 0 : 1)
}

let router = Router()

// MARK: - GET /v1/health

router.get("/v1/health") { _, _ -> HealthResponse in
    guard let info = try await store.ingestInfo() else {
        return HealthResponse(status: "degraded", routeCount: 0, ingestedAt: nil,
                              ageHours: nil, coverage: [])
    }
    let ageHours = Date().timeIntervalSince(info.date) / 3600
    // `status` answers exactly one question — can this serve a recommendation — because an
    // uptime monitor reads it as a binary and nothing else belongs in it.
    //
    // It used to also degrade past 72 hours of data age, which was wrong for how this
    // deploys. The route pool is baked into the image at build time and changes only on a
    // redeploy, so a service left running (which is what a demo is) would start calling
    // itself degraded within three days while answering every request correctly. Callers
    // who care about freshness have `ingestedAt` and `ageHours` to judge it with, and
    // hiking routes do not go stale on the scale of days.
    return HealthResponse(
        status: info.count > 0 ? "ok" : "degraded",
        routeCount: info.count,
        ingestedAt: iso8601(info.date),
        ageHours: (ageHours * 10).rounded() / 10,
        coverage: try await store.populatedCells(minimumRoutes: 5)
            .prefix(20)
            .map { .init(cell: $0.cell, routeCount: $0.count) })
}

// MARK: - GET /v1/coverage

router.get("/v1/coverage") { _, _ -> CoverageResponse in
    CoverageResponse(
        cellSizeDegrees: GridCell.sizeDegrees,
        cells: try await store.populatedCells(minimumRoutes: 1)
            .map { .init(cell: $0.cell, routeCount: $0.count) })
}

// MARK: - POST /v1/recommendations

router.post("/v1/recommendations") { request, context -> RecommendationResponse in
    let body = try await request.decode(as: RecommendationRequest.self, context: context)

    let query = body.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
        throw HTTPError(.badRequest, message: "query must not be empty")
    }

    // Snap to a grid cell so callers in the same area share one byte-identical slate.
    // Without this the slate differs per caller and nothing caches — see the brief, §5.
    let cell = GridCell(latitude: body.area.lat, longitude: body.area.lon)
    let radiusKm = min(max(body.area.radiusKm ?? 30, 1), 100)

    // Filtered by area only — never by the caller's constraints, for the same reason.
    let slate = try await store.slate(cell: cell, radiusKm: radiusKm, limit: 300)
    guard !slate.isEmpty else {
        throw HTTPError(.serviceUnavailable, message: APIError.noSlate.message)
    }

    let ranked = HeuristicRanker.rank(
        query: query,
        constraints: body.constraints,
        slate: slate,
        limit: min(max(body.limit ?? 3, 1), 10))

    // Re-read the picked routes with their geometry attached — the slate deliberately
    // leaves it out, and the app needs the vertices to draw the route on its map.
    let hydrated = try await store.hydrate(ids: ranked.map(\.route.id))
    let info = try await store.ingestInfo()

    return RecommendationResponse(
        engine: "localScoring",
        picks: ranked.enumerated().map { index, item in
            .init(trailId: item.route.id, rank: index + 1, reason: item.reason)
        },
        // Only the routes actually picked — the app needs those to render, and shipping
        // the whole slate would make the response an order of magnitude larger.
        candidates: ranked.compactMap { hydrated[$0.route.id] ?? $0.route },
        slate: .init(cell: cell.id, size: slate.count,
                     ingestedAt: info.map { iso8601($0.date) }),
        generatedAt: iso8601(Date()))
}

// MARK: - Serve

// Cloud Run assigns the port through PORT and **requires the process to listen on
// 0.0.0.0** — a container bound to 127.0.0.1 accepts nothing from outside itself and the
// deploy fails its health check with no obvious cause. The Dockerfile sets HOST; the
// local default stays on the loopback so `swift run` doesn't expose the service to the
// rest of the network.
let environment = ProcessInfo.processInfo.environment
let port = Int(environment["PORT"] ?? "8080") ?? 8080
let host = environment["HOST"] ?? "127.0.0.1"

let app = Application(
    router: router,
    configuration: .init(address: .hostname(host, port: port),
                         serverName: "TrailAdvisor"),
    logger: logger)

logger.info("listening on http://\(host):\(port)")
try await app.runService()

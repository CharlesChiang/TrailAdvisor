import Foundation
import CSQLite

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sql(String)

    var description: String {
        switch self {
        case let .open(message): return "could not open database: \(message)"
        case let .sql(message): return "sqlite: \(message)"
        }
    }
}

/// Route storage, in one SQLite file.
///
/// An actor because the connection is not thread-safe and the ingest job writes while
/// requests read. WAL keeps those from blocking each other.
actor RouteStore {
    // The pointer never changes after init; every *use* of it is serialized by the
    // actor. `nonisolated(unsafe)` is what lets deinit close it.
    nonisolated(unsafe) private let db: OpaquePointer

    // An actor's init is nonisolated, so setup goes through the static helpers below
    // rather than the isolated instance methods.
    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw StoreError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        try Self.execute("PRAGMA journal_mode=WAL;", on: handle)
        try Self.execute(Self.schema, on: handle)
    }

    deinit { sqlite3_close(db) }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS routes (
            id                     TEXT PRIMARY KEY,
            title                  TEXT NOT NULL,
            summary                TEXT NOT NULL,
            length_meters          REAL NOT NULL,
            ascent_meters          INTEGER NOT NULL,
            descent_meters         INTEGER NOT NULL,
            difficulty             INTEGER NOT NULL,
            category_name          TEXT NOT NULL,
            image_url              TEXT,
            ascent_per_km          REAL NOT NULL,
            max_sustained_gradient REAL NOT NULL,
            min_altitude           REAL NOT NULL,
            max_altitude           REAL NOT NULL,
            estimated_minutes      REAL NOT NULL,
            centroid_lat           REAL NOT NULL,
            centroid_lon           REAL NOT NULL,
            geometry               TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_routes_centroid ON routes(centroid_lat, centroid_lon);

        CREATE TABLE IF NOT EXISTS ingests (
            id           INTEGER PRIMARY KEY CHECK (id = 1),
            ingested_at  REAL NOT NULL,
            route_count  INTEGER NOT NULL
        );
        """

    // MARK: Writing

    /// Replaces the whole pool in **one transaction**.
    ///
    /// Atomic on purpose: killing the process mid-ingest must leave the previous pool
    /// intact and servable. A half-written pool is worse than a stale one.
    func replaceAll(with routes: [Route], at date: Date) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("DELETE FROM routes;")
            for route in routes { try insert(route) }
            try run("""
                INSERT INTO ingests (id, ingested_at, route_count) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET ingested_at = excluded.ingested_at,
                                              route_count = excluded.route_count;
                """) { statement in
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                sqlite3_bind_int(statement, 2, Int32(routes.count))
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func insert(_ route: Route) throws {
        try run("INSERT INTO routes VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);") { statement in
            sqlite3_bind_text(statement, 1, route.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, route.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, route.summary, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 4, route.lengthMeters)
            sqlite3_bind_int(statement, 5, Int32(route.ascentMeters))
            sqlite3_bind_int(statement, 6, Int32(route.descentMeters))
            sqlite3_bind_int(statement, 7, Int32(route.difficulty))
            sqlite3_bind_text(statement, 8, route.categoryName, -1, SQLITE_TRANSIENT)
            if let url = route.imageURL {
                sqlite3_bind_text(statement, 9, url, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 9)
            }
            sqlite3_bind_double(statement, 10, route.ascentPerKm)
            sqlite3_bind_double(statement, 11, route.maxSustainedGradient)
            sqlite3_bind_double(statement, 12, route.minAltitude)
            sqlite3_bind_double(statement, 13, route.maxAltitude)
            sqlite3_bind_double(statement, 14, route.estimatedMinutes)
            sqlite3_bind_double(statement, 15, route.centroidLat)
            sqlite3_bind_double(statement, 16, route.centroidLon)
            sqlite3_bind_text(statement, 17, route.geometry, -1, SQLITE_TRANSIENT)
        }
    }

    // MARK: Reading

    /// The routes within `radiusKm` of a grid cell's centre, **ordered by id**.
    ///
    /// Measured from the cell centre rather than the caller's exact position — see
    /// `GridCell`. The ordering is not cosmetic: once this feeds a cached LLM prompt, a
    /// slate that reorders between reads changes the prompt prefix byte-for-byte and
    /// silently costs every cache hit.
    ///
    /// A bounding box does the indexable work in SQL; the exact great-circle test happens
    /// in Swift, because SQLite has no trigonometry without an extension.
    func slate(cell: GridCell, radiusKm: Double, limit: Int) throws -> [Route] {
        let (centerLat, centerLon) = cell.center
        let latPadding = radiusKm / 111.0
        // Longitude degrees shrink toward the poles; guard the cosine near ±90°.
        let lonPadding = radiusKm / (111.0 * max(cos(centerLat * .pi / 180), 0.01))

        var routes: [Route] = []
        // Explicit columns, not SELECT * — the slate is a ranking pass over hundreds of
        // routes and their geometry would dominate the read for no benefit. Geometry comes
        // back only for the handful of routes actually picked, via `hydrate(ids:)`.
        try run("""
            SELECT \(Self.slateColumns), '' FROM routes
            WHERE centroid_lat BETWEEN ? AND ? AND centroid_lon BETWEEN ? AND ?
            ORDER BY id;
            """, bind: { statement in
            sqlite3_bind_double(statement, 1, centerLat - latPadding)
            sqlite3_bind_double(statement, 2, centerLat + latPadding)
            sqlite3_bind_double(statement, 3, centerLon - lonPadding)
            sqlite3_bind_double(statement, 4, centerLon + lonPadding)
        }, step: { statement in
            let route = Self.route(from: statement)
            let distance = haversineMeters(lat1: centerLat, lon1: centerLon,
                                           lat2: route.centroidLat, lon2: route.centroidLon)
            if distance <= radiusKm * 1000, routes.count < limit {
                routes.append(route)
            }
        })
        return routes
    }

    private static let slateColumns = """
        id, title, summary, length_meters, ascent_meters, descent_meters, difficulty, \
        category_name, image_url, ascent_per_km, max_sustained_gradient, min_altitude, \
        max_altitude, estimated_minutes, centroid_lat, centroid_lon
        """

    /// The full records, geometry included, for routes that were actually picked.
    ///
    /// The app draws the route on a map, so it needs the vertices — and it must not have
    /// to go back to Outdooractive for them, which is the point of the service returning
    /// candidates at all.
    func hydrate(ids: [String]) throws -> [String: Route] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var result: [String: Route] = [:]
        try run("SELECT * FROM routes WHERE id IN (\(placeholders));", bind: { statement in
            for (index, id) in ids.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), id, -1, SQLITE_TRANSIENT)
            }
        }, step: { statement in
            let route = Self.route(from: statement)
            result[route.id] = route
        })
        return result
    }

    func ingestInfo() throws -> (date: Date, count: Int)? {
        var result: (Date, Int)?
        try run("SELECT ingested_at, route_count FROM ingests WHERE id = 1;", step: { statement in
            result = (Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                      Int(sqlite3_column_int(statement, 1)))
        })
        return result
    }

    /// Where the pool actually is, for `/v1/health`. The test project's routes are spread
    /// across Europe, so "which cells have data" is the only honest coverage answer.
    func populatedCells(minimumRoutes: Int) throws -> [(cell: String, count: Int)] {
        var cells: [String: Int] = [:]
        try run("SELECT centroid_lat, centroid_lon FROM routes;", step: { statement in
            let cell = GridCell(latitude: sqlite3_column_double(statement, 0),
                                longitude: sqlite3_column_double(statement, 1))
            cells[cell.id, default: 0] += 1
        })
        return cells
            .filter { $0.value >= minimumRoutes }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (cell: $0.key, count: $0.value) }
    }

    private static func route(from statement: OpaquePointer) -> Route {
        func text(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
        return Route(
            id: text(0),
            title: text(1),
            summary: text(2),
            lengthMeters: sqlite3_column_double(statement, 3),
            ascentMeters: Int(sqlite3_column_int(statement, 4)),
            descentMeters: Int(sqlite3_column_int(statement, 5)),
            difficulty: Int(sqlite3_column_int(statement, 6)),
            categoryName: text(7),
            imageURL: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : text(8),
            ascentPerKm: sqlite3_column_double(statement, 9),
            maxSustainedGradient: sqlite3_column_double(statement, 10),
            minAltitude: sqlite3_column_double(statement, 11),
            maxAltitude: sqlite3_column_double(statement, 12),
            estimatedMinutes: sqlite3_column_double(statement, 13),
            centroidLat: sqlite3_column_double(statement, 14),
            centroidLon: sqlite3_column_double(statement, 15),
            geometry: text(16))
    }

    // MARK: Plumbing

    private static func execute(_ sql: String, on db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    private static func run(
        _ sql: String,
        on db: OpaquePointer,
        bind: ((OpaquePointer) -> Void)? = nil,
        step: ((OpaquePointer) -> Void)? = nil
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bind?(statement)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: step?(statement)
            case SQLITE_DONE: return
            default: throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: db)
    }

    private func run(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        step: ((OpaquePointer) -> Void)? = nil
    ) throws {
        try Self.run(sql, on: db, bind: bind, step: step)
    }
}

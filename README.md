# TrailAdvisor

A route recommendation service over Outdooractive's Data API. Swift 6, [Hummingbird](https://github.com/hummingbird-project/hummingbird) 2, [Outdooractive/gis-tools](https://github.com/Outdooractive/gis-tools), SQLite. Runs at **`https://api.tcchiang.dev`**.

It answers one question — *"which of these routes fits what this person asked for, and why"* — and it exists because that question cannot be answered honestly on a phone.

The iOS client is [TrailHealth](https://github.com/CharlesChiang/TrailHealth), a separate repository.

---

## Why a service at all

The obvious design is to do the ranking in the app. That fails on a specific, checkable point.

`GET /filter/tour` accepts `lat`, `lon` and `radius`. **In the public test project, it ignores all three.** Three calls:

| Request | IDs returned |
|---|---|
| `lat=47.42 lon=10.99 radius=30000` (Alps) | 9,837 |
| `lat=51.75 lon=10.62 radius=30000` (Harz, 480 km north) | 9,837 |
| no location parameters at all | 9,837 |

The three ID sets are identical, in identical order. `limit` is ignored as well.

That was not found by reading documentation. It surfaced as a `UNIQUE constraint failed: routes.id` during the first ingest, because two regions 480 km apart returned the same routes.

**Scope of that claim:** measured against the documented public test credentials (`yourtest-outdoora-ctiveapi`) on the test project only. Whether a production project behaves the same way, I have no way to check. If it does not, the interesting part of this repository is the shape of the workaround rather than the need for it.

The consequence is concrete. Filtering by location honestly means holding each route's geometry to test it against a radius — which means pulling ~9,800 routes onto the phone before you can answer anything. Two-phase fetch at 25 records per request is ~390 sequential requests. A service normalizes once and filters from derived centroids; a client cannot.

So the split is not architectural taste. It is the only place the work fits.

---

## What it does

Three endpoints. No API key, no account, no LLM.

```
GET  /v1/health           what it holds, how old, and which cells it covers
GET  /v1/coverage         every populated grid cell with a route count
POST /v1/recommendations  a ranked answer with a reason per pick
```

**Ingest** walks the catalogue once (1,200 routes by default), parses each geometry, and derives what the API does not expose:

- centroid and bounding box — so area filtering becomes possible at all
- `ascentPerKm`
- `maxSustainedGradient` over a 500 m window — a route with one short wall is not the same as a route that climbs relentlessly, and total ascent cannot tell them apart
- `estimatedMinutes` by Naismith's rule

**Ranking** scores on *relative* error against what was asked: a 1 km miss matters more on a 2 km walk than on a 20 km one. Difficulty ceilings and ascent caps add penalties rather than filtering, so a near-miss still surfaces instead of the answer coming back empty. Ties break on ID, so ordering is deterministic and testable.

**Reasons are generated from the numbers**, not from a model:

> `8.8 km with 61 m of ascent — about 112 minutes against the 120 you asked for.`

---

## Two design decisions worth explaining

**The pre-filter is by area, never by the caller's constraints.**

The obvious optimization is to narrow the candidate slate using the constraints before ranking. That is exactly wrong if a model tier is ever added: a slate that varies with every caller's distance and ascent numbers is a prompt prefix that never repeats, and nothing caches. Filtering by area only means everyone asking about the same place gets a byte-identical slate.

Coordinates are snapped to a 0.5° grid cell for the same reason. The grid exists for cache stability, not for geography — 0.5° is not a meaningful hiking distance, and the actual radius filter runs against real centroid distances afterwards.

**The route pool is baked into the image at build time.**

The build runs the ingest and ships `trailadvisor.sqlite` inside the image. A container with no persistent disk would otherwise face an empty store and a 40-second re-ingest on every cold start. The trade is that route data is only as fresh as the last deploy, which for data that changes on the order of months is the right side of it.

It also means a build fails loudly if Outdooractive is unreachable — better than deploying a service that starts fine and answers nothing.

---

## Running it locally

**Requirements:** Swift 6.0+ and SQLite headers. macOS 15+ or Linux.

```bash
git clone https://github.com/CharlesChiang/TrailAdvisor.git
cd TrailAdvisor
```

On Linux, the SQLite headers are a package:

```bash
sudo apt-get install -y libsqlite3-dev
```

Build:

```bash
swift build -c release
```

Populate the store. This reaches out to Outdooractive and takes about 40 seconds:

```bash
.build/release/TrailAdvisor ingest
```

```
info trail-advisor: [TrailAdvisor] fetching route ids…
info trail-advisor: [TrailAdvisor]   1200 ids
info trail-advisor: [TrailAdvisor]   1200 records → 1200 usable routes
info trail-advisor: [TrailAdvisor] stored 1200 routes
```

Start the server:

```bash
.build/release/TrailAdvisor
```

It listens on `127.0.0.1:8080`. Check it:

```bash
curl -s localhost:8080/v1/health | python3 -m json.tool
```

### Environment

| Variable | Default | Notes |
|---|---|---|
| `PORT` | `8080` | |
| `HOST` | `127.0.0.1` | Must be `0.0.0.0` in a container, or nothing outside reaches it |
| `DB_PATH` | `trailadvisor.sqlite` | |

### Subcommands

```bash
TrailAdvisor              # serve
TrailAdvisor ingest       # refresh the pool and exit; non-zero if it stored nothing
TrailAdvisor healthcheck  # exit 0 when the store holds routes
```

`healthcheck` exists because the runtime image has neither `wget` nor `curl` — `ubuntu:noble` ships neither, and adding one just to poll ourselves would be a package and an attack surface for nothing. The binary already knows the answer.

---

## Using the API

### POST /v1/recommendations

```bash
curl -s https://api.tcchiang.dev/v1/recommendations \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "A gentle 2 hours",
    "area": { "lat": 42.75, "lon": 0.75, "radiusKm": 30 },
    "limit": 3
  }' | python3 -m json.tool
```

`query` is free text. `area` is required — `radiusKm` defaults to 30 and is clamped to 1–100. `limit` defaults to 3, clamped to 1–10.

`constraints` is optional and all of it is optional:

```json
{
  "targetDistanceKm": 9,
  "maxAscentMeters": 600,
  "maxDifficulty": 2,
  "referenceDistanceKm": 8.2,
  "referenceAscentMeters": 410,
  "paceMinPerKm": 14.5
}
```

The `reference*` fields are what the hiker usually does, so a reason can say *"a step up from your usual 8.2 km"*. `paceMinPerKm` is what turns "2 hours" into a target distance.

The response:

```json
{
  "engine": "localScoring",
  "picks": [
    {
      "trailId": "128646460",
      "rank": 1,
      "reason": "8.8 km with 61 m of ascent — about 112 minutes against the 120 you asked for."
    }
  ],
  "candidates": [ { "id": "128646460", "title": "…", "geometry": "…" } ],
  "slate": { "cell": "85,1", "size": 53, "ingestedAt": "2026-08-15T07:00:39Z" },
  "generatedAt": "2026-08-15T07:36:12Z"
}
```

`engine` names what actually ran, so a caller can report the truth rather than assuming. `candidates` carries the full record for each pick — including geometry in Outdooractive's own space-separated `lon,lat,alt` wire format, so a client parses it with the same code it already uses for the Data API. That is most of the latency win: no second round trip.

`slate` is diagnostic — which cell was consulted and how many routes were in play. A pick that looks odd is usually a thin slate.

### Where there is data

The test project's routes are scattered across Europe rather than concentrated anywhere, so ask before you guess:

```bash
curl -s https://api.tcchiang.dev/v1/coverage | python3 -m json.tool
```

The densest cell is the **Val d'Aran** valley in the Pyrenees (`42.75, 0.75`), which is why the examples here use it.

### Errors

| Status | When |
|---|---|
| `400` | `query` is empty |
| `503` | no routes within the requested radius — the honest answer, not an error to hide |

A failed ingest never takes the service down: the previous pool stays served and its age is on `/v1/health`.

---

## Deploying it

```bash
docker build -t trailadvisor .
docker run -p 8080:8080 -e HOST=0.0.0.0 trailadvisor
```

The runtime image is `ubuntu:noble` with no Swift toolchain — about 250 MB rather than 2.5 GB.

Two things that are easy to get wrong here, both learned the hard way:

- **`--static-swift-stdlib` does not cover Foundation's C dependencies.** On Linux, Foundation dynamically links libcurl (URLSession) and libxml2. Without `libcurl4 libxml2 libsqlite3-0` the binary dies at exec with `error while loading shared libraries: libcurl.so.4` — before a single line of Swift runs, so nothing appears in the application log.
- **The `/app` *directory* must be owned by the app user**, not just the database file. SQLite in WAL mode creates `-wal` and `-shm` siblings when it opens, so a writable file in a root-owned directory still fails with "attempt to write a readonly database" — an error that names the file and is really about the directory.

The deployed instance runs on a Synology DS720+ behind a Cloudflare tunnel. `docker-compose.yml` has both containers; the tunnel makes an outbound connection, so there is no port forwarding and no public port on the NAS. GitHub Actions builds the image, because the NAS has 2 GB of RAM and the Swift compiler wants more than that.

`TUNNEL_TOKEN` goes in a `.env` file beside the compose file, or in Container Manager's environment. It is a bearer credential — never commit it.

---

## What is deliberately not here

**There is no LLM.** `engine` reports `localScoring` because that is the truth.

The design puts a model tier above the scorer — that is what the area-only pre-filter and the grid snapping exist to make cacheable — but it is not wired up, because it needs an API key I have not spent. Everything below it is complete, tested, and the thing the model would degrade back to anyway. `BRIEF.md` §5–7 specifies that tier: the slate as a cached prompt prefix, structured output, validation of every returned ID against the slate, and refusal handling.

A deterministic scorer that ships beats a model tier that does not, and the honest `engine` field is what makes the difference visible rather than hidden.

---

## Repository map

```
Sources/TrailAdvisor/
  main.swift              routing, subcommands, server setup
  API/Contract.swift      request and response types
  Ingest/                 the Outdooractive client, DTOs, and the ingest job
  Models/Route.swift      normalization and the derived terrain features
  Models/Region.swift     grid cells and haversine
  Rank/                   query parsing and the scorer
  Store/RouteStore.swift  SQLite actor
Sources/CSQLite/          modulemap for libsqlite3 — deliberately no pkgConfig:
BRIEF.md                  the full design spec, including the unbuilt model tier
```

`Sources/CSQLite/module.modulemap` has no `pkgConfig:` on purpose. `gis-tools-geopackage` declares `pkgConfig: "sqlite3"`, and on an iOS build SwiftPM resolves that to Homebrew's *macOS* dylib and the link fails — the cause being Homebrew sqlite's *presence*, not its absence. `link "sqlite3"` avoids the whole mechanism. The iOS client works around the same problem from the other side; [Vendor/README.md](https://github.com/CharlesChiang/TrailHealth/blob/main/Vendor/README.md) over there has the diff and a proposal worth filing upstream.

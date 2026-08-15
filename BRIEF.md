# TrailAdvisor — Service Brief

A recommendation service over Outdooractive's route data, and the companion to the
TrailHealth iOS app. This document is the specification: it states what to build, the
decisions already made and why, and what "done" means. It is written to be dropped into a
new repository as its `CLAUDE.md` or `BRIEF.md`.

**This is a separate project from TrailHealth.** The app is the client; nothing in this
service lives in the app's repository and nothing in the app's repository is required to
build it. The only shared artefact is the HTTP contract in §4.

---

## 1. What it is, and what it is not

The service ranks Outdooractive routes against a free-text request and a set of numeric
constraints, and returns a short list with a written reason for each pick.

**It is not an LLM proxy.** A service whose only job is to hide an API key is not worth
deploying and will not survive a technical interview. TrailAdvisor earns the name by doing
three things the app cannot:

1. **Aggregating Outdooractive's API server-side.** The Data API has no "routes near here"
   call: `/filter/tour` returns bare IDs — roughly 9,800 of them for a 30 km search — and
   `/oois/{ids}` returns records in batches. A client that fans this out on demand either
   truncates the result set or hangs. The service walks it once per region on a schedule
   and serves from a local store.
2. **Precomputing terrain features the API does not expose.** Ascent per kilometre, maximum
   sustained gradient, elevation band, bounding box, centroid, estimated duration. These
   are derivable from the geometry but too expensive to compute per request on a phone.
3. **Holding the ranking logic somewhere it can be changed.** Prompt, model, and scoring
   iterate on the server without an App Store release.

Everything else — including the LLM call — is downstream of those three.

### Explicitly out of scope

| Not building | Why, and what it costs |
|---|---|
| Vector search over route descriptions | Deferred to v2. **This has a real consequence**: semantic queries ("with a lake", "good with kids") are answered only by the model reading the descriptions in the candidate slate. If the matching route is not in the slate, it cannot be found. §5 sizes the slate to make this rare, but it does not eliminate it. Say so rather than claiming semantic search works. |
| Health or fitness telemetry | The device sends two derived scalars, not a history. See §4.2. |
| Weather and seasonal conditions | Sensible for the domain and Outdooractive does it, but it doubles the ingest surface and adds a second upstream dependency. |
| User accounts, saved preferences, sync | No identity model. Requests are anonymous. |

---

## 2. Stack

| Layer | Choice | Reasoning |
|---|---|---|
| Language | **Swift 6** | Outdooractive publishes server-side Swift (`PostgresConnectionPool`, `mvt-postgis`). More importantly, `gis-tools` runs on both client and server, so route geometry uses **one representation end to end** — the API's coordinate string is parsed into the same `Feature`/`LineString` types the app draws from. That is a genuine architectural property, not a language preference. |
| HTTP | **Hummingbird 2** | Smaller and faster to cold-start than Vapor, which matters when the machine suspends between requests. Vapor is a defensible substitute. |
| Store | **SQLite** (`import SQLite3`, WAL) | Same choice and same reasoning as the app: the working set is tens of thousands of rows and a single file is a single backup. Postgres only if you later want PostGIS spatial indexing. |
| LLM | **Claude API**, `claude-opus-5` | See §6. |
| Host | **Fly.io**, one `shared-cpu-1x` 256 MB machine | `auto_stop_machines = "suspend"` with `min_machines_running = 0` means it costs approximately nothing at demo traffic. A Swift binary in a slim container resumes in well under a second, which is why this works where a JVM or a cold Node bundle would not. |
| Schedule | Fly Machines scheduled job, or an in-process timer | Ingest runs every 12 h. |

**If free-tier economics turn out to matter more than the Swift story**, the fallback is
TypeScript on Cloudflare Workers with D1 and Cron Triggers — genuinely free, but it gives up
`gis-tools`, gives up shared geometry types, and gives up the server-side Swift signal.
Choose deliberately; do not drift into it.

**Do not commit secrets.** `OA_API_KEY`, `ANTHROPIC_API_KEY`, and `APP_TOKEN` are
environment variables, set via `fly secrets set`. The repository contains a `.env.example`
listing the names and nothing else.

---

## 3. Ingest

A scheduled job, not a request path. It must be possible to run it locally against a fixture.

### 3.1 Regions

The service covers a fixed list of regions, declared in `Regions.swift`. Start with the two
the Outdooractive test project actually has data for; the list is data, not code.

```swift
struct Region {
    let id: String            // "bavarian-alps"
    let center: Coordinate3D
    let radiusKm: Double
}
```

### 3.2 Pipeline

For each region, every 12 hours:

1. `GET /filter/tour` for the region → IDs. **Truncate client-side.** The endpoint ignores
   its `limit` parameter; this is the bug that hung the app's Explore tab, and it will hang
   the ingest job the same way if you trust the parameter.
2. `GET /oois/{ids}` in batches of 25 → full records.
3. Normalize:
   - Strip HTML from `shortText`/`longText`.
   - Parse `geometry` — a space-separated string of `lon,lat,alt` triples, **not GeoJSON** —
     into a `gis-tools` `LineString`, discarding malformed vertices rather than failing the
     whole record.
4. Derive and store, per route:

   | Field | Definition |
   |---|---|
   | `lengthMeters`, `ascentMeters`, `descentMeters` | From the API where present, from the geometry where not |
   | `ascentPerKm` | `ascentMeters / lengthKm` — the single best proxy for "how steep does this feel" |
   | `maxSustainedGradient` | Steepest 500 m window, as a percentage |
   | `minAltitude`, `maxAltitude` | Elevation band; drives "is this above the snow line in April" later |
   | `estimatedMinutes` | Naismith's rule: distance at 12 min/km plus 10 min per 100 m of ascent |
   | `centroid`, `bbox` | For spatial pre-filtering |
   | `difficulty`, `categoryName` | Passed through |
   | `summary` | Stripped, truncated to 160 characters |

5. Upsert into SQLite in one transaction per region. Never leave a region half-written.

### 3.3 Failure policy

An ingest failure must never take the service down. The last good slate stays served, and
the response reports its age (§4.3). A region whose slate is older than 72 hours is logged
as unhealthy but still served — stale route data is far better than none.

---

## 4. HTTP contract

This is the interface the app is written against. Change it only with a version bump.

### 4.1 Endpoints

```
POST /v1/recommendations     the only endpoint that matters
GET  /v1/health              region slate ages, last ingest, model reachability
GET  /v1/regions             what the service covers
```

### 4.2 Request

```json
{
  "query": "a gentle 2 hours",
  "area":  { "lat": 47.42, "lon": 10.99, "radiusKm": 30 },
  "constraints": {
    "targetDistanceKm": 8.0,
    "maxAscentMeters": 600,
    "maxDifficulty": 3,
    "referenceDistanceKm": 7.5,
    "referenceAscentMeters": 380
  },
  "limit": 3,
  "locale": "en"
}
```

**`constraints` is the privacy boundary, and describe it accurately.** The device never
sends heart rate, per-hike records, GPS traces, or timestamps. It sends the two derived
scalars the reason text needs in order to say "close to your usual 7.5 km", plus the
envelope it computed locally from those scalars. Two anonymous numbers is a real reduction
from a hike history — it is not anonymity, and claiming otherwise in an interview will not
survive one follow-up question. State the reduction, not a guarantee.

`constraints` is optional in full. A request with none is a cold-start user and must work.

### 4.3 Response

```json
{
  "engine": "service",
  "model": "claude-opus-5",
  "picks": [
    { "trailId": "...", "rank": 1, "reason": "..." }
  ],
  "candidates": [ /* full route records, app-model shaped */ ],
  "slate": { "regionId": "bavarian-alps", "size": 280, "ingestedAt": "..." },
  "generatedAt": "..."
}
```

**The response carries the candidate records, not just IDs.** The app must be able to render
the result without a second round trip to Outdooractive — that is most of the latency win,
and it means a recommendation works even where the app's own API path is rate-limited.

### 4.4 Errors

Ordinary HTTP status codes with a JSON body of `{ "error": { "code", "message" } }`. The
codes the app branches on:

| Status | `code` | App behaviour |
|---|---|---|
| 400 | `invalid_request` | Show the message; do not fall back |
| 401 | `unauthorized` | Fall back silently; log |
| 429 | `rate_limited` | Fall back; honour `Retry-After` |
| 503 | `no_slate_for_area` | Fall back; this area is not covered |
| 503 | `budget_exhausted` | Fall back; the daily spend cap tripped (§8) |

Everything except 400 is a fall-back case. The app must treat *any* non-200 as fallback-worthy.

---

## 5. Ranking: the pre-filter, and why it is by area rather than by constraint

This is the decision that shapes everything else, and it is counterintuitive enough to be
worth stating twice.

**The naive design pre-filters candidates by the caller's constraints and sends the model a
small tailored slate.** It is wrong here, because it makes the prompt different for every
request — and a prompt that differs for every request cannot be cached. Prompt caching is a
prefix match: the cached span ends at the first byte that differs.

**So pre-filter by area only.** For a given region the slate is identical for every caller,
so it caches; the model does the constraint matching, which is what it is for.

```
system prompt      ← stable, identical for every request
candidate slate    ← stable per region + ingest generation   ┐ cache breakpoint here
─────────────────────────────────────────────────────────────┘
hiker's request    ← differs every request, never cached
```

Concretely:

- The slate is every route in the region, ordered deterministically by ID, capped at
  **300 routes**. One line each, roughly 45 tokens: about **13,000 tokens**.
- At `claude-opus-5` input pricing ($5/MTok), a cache read of that slate costs about
  **$0.0065 per request**. A cold write costs about $0.08. Break-even is two requests
  inside the TTL.
- The minimum cacheable prefix on `claude-opus-5` is **512 tokens**, so the slate clears it
  comfortably. (It is 1024 on `claude-sonnet-5` — still fine, but the number differs.)

**Determinism is now a correctness requirement, not a nicety.** These will silently cost you
every cache hit, with no error:

- Any timestamp, request ID, or `Date.now()` in the system prompt or the slate.
- Non-deterministic JSON key order, or iterating a `Set`, when serializing the slate.
- Reordering the ingest output between runs — order by route ID, not by insertion.
- Changing the tool list or the model mid-conversation.

Verify by asserting `usage.cache_read_input_tokens > 0` on the second identical-region
request. Zero across repeated requests means something in the prefix is moving.

**At demo traffic the cache will often not pay for itself in money.** It pays in latency and
it is the correct shape at any real volume. Say that plainly rather than overstating the
saving.

---

## 6. The model call

### 6.1 Model

Use **`claude-opus-5`**. 1M context, $5/MTok in and $25/MTok out.

`claude-sonnet-5` ($3/$15, with an introductory $2/$10 through 2026-08-31) is the cost
option and is strong on this kind of structured selection. It is a deliberate downgrade,
not a default — pick it if the per-request cost matters more than answer quality, and note
that its prompt-cache minimum is 1024 tokens rather than 512.

### 6.2 Request shape

```swift
// Thinking is ON by default on claude-opus-5 — omitting the parameter runs adaptive.
// max_tokens caps thinking AND response text together, so size it for both.
{
  "model": "claude-opus-5",
  "max_tokens": 4096,
  "output_config": { "effort": "medium" },
  "system": [
    { "type": "text", "text": "<instructions>" },
    { "type": "text", "text": "<candidate slate>",
      "cache_control": { "type": "ephemeral", "ttl": "1h" } }
  ],
  "messages": [ { "role": "user", "content": "<the hiker's request + constraints>" } ]
}
```

Notes that are easy to get wrong:

- **`output_config.format`, not `output_format`.** The latter is deprecated API-wide.
- **Effort is nested inside `output_config`**, not top-level.
- **Do not send `temperature`, `top_p`, or `top_k`** — they return a 400 on `claude-opus-5`.
- **Do not send `thinking: {type: "enabled", budget_tokens: N}`** — also a 400. Use
  `output_config.effort` to control depth.
- Start at `effort: "medium"`. This is a selection task over a bounded slate, not open-ended
  reasoning; sweep `low`/`medium`/`high` against the golden set in §9 before settling.

### 6.3 Structured output

Constrain the response with a JSON schema rather than parsing prose:

```json
"output_config": {
  "effort": "medium",
  "format": {
    "type": "json_schema",
    "schema": {
      "type": "object",
      "properties": {
        "picks": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id":     { "type": "string" },
              "reason": { "type": "string" }
            },
            "required": ["id", "reason"],
            "additionalProperties": false
          }
        }
      },
      "required": ["picks"],
      "additionalProperties": false
    }
  }
}
```

`additionalProperties: false` is required on every object. The schema language does **not**
support `minItems`/`maxItems` or `minLength`/`maxLength`, so "at most three picks" and
"twenty words" belong in the prompt text and in the validator — not in the schema.

A new schema pays a one-time compilation cost on its first request, then caches for 24 hours.
Do not generate the schema dynamically per request.

### 6.4 System prompt (first draft — iterate against the golden set)

```
You help a hiker choose a route for today.

You are given a numbered list of candidate routes and a request. Each candidate has an id,
a name, its distance, total ascent, ascent per kilometre, an estimated duration, a
difficulty label, and a short description which may be in German.

Choose at most three candidates that match what the hiker asked for and suit the
constraints given with the request. Prefer routes close to their reference distance and
ascent; suggest something harder only if they asked for it. Order strongest first.

Copy each id exactly as given. Never invent a route or an id. Every reason must be one
sentence in English, at most twenty words, and must cite a concrete number from the route
or from the constraints.

If nothing in the list is a reasonable match, return fewer picks — or none. An honest empty
answer is better than a poor one.
```

Two things this prompt does on purpose:

- **It licenses an empty answer.** Without that line the model will always return three
  routes, including for requests nothing in the region satisfies.
- **It says "cite a concrete number".** This is what stops reasons collapsing into
  "a beautiful scenic route" — the failure mode that makes an AI feature feel worthless.

### 6.5 Validate the output — always

Structured output guarantees the *shape*, never the *content*. Every returned ID is matched
back against the slate; anything invented, duplicated, or missing a reason is dropped. If
nothing survives, the service falls back to its own deterministic scorer and says so in
`engine`.

The app already has this logic in `ModelOutputResolver`, deliberately written free of any
model-framework types so it could be tested without one. **Port it, do not rewrite it** —
and port its tests with it.

### 6.6 Refusals

`stop_reason == "refusal"` must be checked before reading `content`; a refused response
returns HTTP 200 with an empty or partial `content` array, so code that indexes `content[0]`
crashes. Route recommendation will essentially never trip a safety classifier, so treat this
as three lines of defensive handling that log and fall back, not as a subsystem. Skip the
`fallbacks` parameter here — it exists for workloads that actually get declined.

---

## 7. Degradation

Three tiers, and the boundary between them is the whole point of the feature for a company
whose users are in the mountains without signal.

| Tier | Runs when | Produced by |
|---|---|---|
| **Service** | Network reachable, service healthy | This service, LLM-ranked over the full regional slate |
| **On-device** | No network, iOS 26 hardware with Apple Intelligence | The app's existing `OnDeviceRecommender` |
| **Local scoring** | Everything else | The app's existing `HeuristicRecommender` |

**The user's engine preference is a preference, not a guarantee.** Someone who selected
"Service" in Settings and then walks into a valley with no signal must still get a
recommendation. The selection biases which engine is *attempted*; failure always degrades.
The UI reports which engine actually ran, never which one was selected.

Client budget: **4 s connect, 12 s total.** Exceeding it is a fallback, not an error dialog.

---

## 8. Abuse, cost, and the public endpoint

A public endpoint that spends money per request needs a ceiling before it is deployed, not
after.

- **`APP_TOKEN`** — a shared bearer token the app ships with. It stops casual scraping. It
  is not a security boundary: anyone can extract it from the binary. Treat it as a speed
  bump and size the other limits assuming it is public.
- **Per-IP rate limit** — 20 requests per hour, in-process token bucket.
- **Daily spend cap** — count input and output tokens per day; past the cap, return
  `503 budget_exhausted` and let every client fall back. **This is the only control that
  actually bounds the bill.** Implement it first.
- **Log token usage per request** — `input_tokens`, `output_tokens`,
  `cache_read_input_tokens`, `cache_creation_input_tokens`. Without this, none of the
  caching work in §5 is measurable, and §9's cost assertion cannot be written.

---

## 9. Acceptance criteria

The TrailHealth repository carries an `AUDIT.md` recording seven rounds of finding real
defects by running the thing rather than reading it. Hold this service to the same standard:
these are executable checks, not aspirations.

**Contract**
1. Every documented endpoint returns its documented shape for a valid request.
2. Every error code in §4.4 is reachable by a test.
3. A request with no `constraints` returns picks.

**Invariants — assert these, they are where the bugs will be**

4. Every `trailId` returned appears in `candidates`. No exceptions, ever.
5. A recommendation request makes **zero** calls to Outdooractive. If a request can fan out
   to the upstream API, the aggregation layer is not doing its job.
6. Ingest is atomic per region: kill the process mid-run and the previous slate is intact.
7. `/filter/tour` truncation holds — assert the ingest never issues more than N object
   requests for a region regardless of how many IDs come back.

**Caching**

8. Two identical-region requests: the second reports `cache_read_input_tokens > 0`.
9. Changing only the `query` still hits the cache. Changing the region does not.

**Quality — a golden set, asserted on properties rather than exact output**

10. Twelve to twenty recorded queries with asserted properties, not asserted text. LLM
    output varies; assertions that pin exact strings will be deleted within a week and the
    suite will rot. Assert things like:
    - "a gentle 2 hours" → every pick within 40 % of the derived target distance
    - "something steep" → top pick has the highest `ascentPerKm` among the picks
    - "an easy 5 km recovery walk" → no pick above difficulty 2
    - a request nothing satisfies → zero or one pick, not three
11. Every returned reason contains a digit. This is a cheap, stable proxy for "cites a
    concrete number" and it catches prompt regressions immediately.

**Cost and latency**

12. A recommendation completes within 12 s at p95 against a warm cache.
13. Per-request token usage is asserted against a ceiling, so a prompt change that doubles
    the slate fails a test instead of a bill.

**Degradation**

14. Service returns 503 → the app falls back and reports `localScoring`. This test lives in
    the app repository, but it is this service's contract, so it belongs on this list.

---

## 10. Work in the TrailHealth repository (not here)

Listed so the interface is agreed, and so nobody builds half of it twice. This is app work
and belongs in the app's own commits.

1. **`ServiceRecommendationClient`** — a `@DependencyClient` over the §4 contract, with the
   same `liveValue` / `previewValue` / `testValue` shape as the six existing clients.
2. **`RecommendationClient` becomes a router**, not an implementation: it reads the user's
   engine preference, attempts that engine, and degrades per §7.
3. **A Settings screen** with the engine picker, worded as a preference. It must not promise
   an engine the device cannot always reach.
4. **`FitnessProfile` → constraint envelope** — a pure function, unit-tested. It is the
   privacy boundary in §4.2 and it should be readable in one screen.
5. **Move `ModelOutputResolver`** to a form both projects can use, or accept the duplication
   deliberately and keep the two test suites in sync.

---

## 11. Build order

Each step is independently demonstrable. Do not proceed past a step that is not.

1. Hummingbird skeleton, `/v1/health`, deployed to Fly. **Prove the deployment before
   writing anything worth deploying.**
2. Ingest for one region into SQLite, run manually. Verify the row count and spot-check
   three routes against the Outdooractive web UI.
3. Derived fields plus the golden-set fixtures.
4. `/v1/recommendations` backed by a deterministic scorer only, no LLM. **The service is
   useful and fully testable at this point** — and if the LLM layer is ever removed, this is
   what remains.
5. Add the Claude call, structured output, and ID validation.
6. Add prompt caching and assert the cache-hit test.
7. Rate limit, spend cap, usage logging.
8. Scheduled ingest.
9. App-side client and Settings (in the app repository).

Step 4 is the checkpoint that matters. A service that ranks well without the model is a
service with a working fallback and an honest story; a service that only works with the
model is one outage away from having nothing to show.

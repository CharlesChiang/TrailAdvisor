# TrailAdvisor for Google Cloud Run.
#
# Two things are unusual here and both are deliberate.
#
# 1. **The route pool is ingested at build time**, so `trailadvisor.sqlite` ships inside
#    the image. Cloud Run scales to zero and gives a container no persistent disk, so a
#    database written at runtime is gone the moment the instance sleeps — every cold start
#    would face an empty store and a 40-second re-ingest before it could answer anything.
#    Baking it in means a cold start serves immediately. The trade is that route data is
#    only as fresh as the last deploy, which for a data set that changes on the order of
#    months is the right side of the trade. Re-deploy to refresh.
#
# 2. **The runtime image carries no Swift toolchain.** Copying the Swift runtime libraries
#    out of the build stage keeps the final image around 250 MB instead of 2.5 GB, and a
#    smaller image is a faster cold start — which is most of what a scale-to-zero service
#    is judged on.

# ---------- build ----------
FROM swift:6.1-noble AS build

# libsqlite3-dev provides the headers Sources/CSQLite/module.modulemap includes. Without
# it the build fails at `import CSQLite`, not at link time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsqlite3-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Resolve dependencies as their own layer so a source-only change doesn't re-fetch them.
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib

# Populate the store. This reaches out to Outdooractive during the build, which means a
# build fails loudly if the upstream API is unreachable — better than deploying a service
# that starts fine and answers nothing.
RUN .build/release/TrailAdvisor ingest \
    && test -s trailadvisor.sqlite

# ---------- runtime ----------
FROM ubuntu:noble

RUN apt-get update && apt-get install -y --no-install-recommends \
        libsqlite3-0 ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

# Run as a non-root user. Cloud Run does not require it; it is simply correct.
RUN useradd --user-group --create-home --system --skel /dev/null trailadvisor
WORKDIR /app

COPY --from=build --chown=trailadvisor:trailadvisor /src/.build/release/TrailAdvisor ./
COPY --from=build --chown=trailadvisor:trailadvisor /src/trailadvisor.sqlite ./

USER trailadvisor

# Cloud Run overrides PORT; HOST must be 0.0.0.0 or the health check never connects.
ENV HOST=0.0.0.0 \
    PORT=8080 \
    DB_PATH=/app/trailadvisor.sqlite
EXPOSE 8080

ENTRYPOINT ["./TrailAdvisor"]

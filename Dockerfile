# WhatFeature server image.
#
# Two stages: build with the full Swift toolchain, then run on plain Ubuntu with only the binary and the few
# system libraries it needs. The Swift runtime and Foundation are linked in statically.
#
#   docker build -t whatfeature .
#   docker run -p 8080:8080 -v whatfeature-data:/data whatfeature
#
# Settings are environment variables (see the README): HOST, PORT, DATABASE_PATH, SEED_FILE, RATE_LIMIT_ADMIN.
# The SQLite database lives on the /data volume. For the first admin token, see `just docker-token`.

FROM swift:6.4.2-noble AS build

# GRDB needs SQLite's headers, which the Swift image doesn't include.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Dependencies first, so changing the code doesn't download them again.
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Tests aren't built, but SwiftPM wants every target's folder to exist.
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product whatfeature --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/whatfeature" /whatfeature


FROM ubuntu:noble

# What the binary links against besides libc (checked with ldd), plus CA certificates and time zones.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 libstdc++6 libgcc-s1 zlib1g ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --user-group --create-home --home-dir /data whatfeature
COPY --from=build /whatfeature /usr/local/bin/whatfeature

USER whatfeature
WORKDIR /data
VOLUME /data

ENV HOST=0.0.0.0 \
    PORT=8080 \
    DATABASE_PATH=/data/whatfeature.sqlite
EXPOSE 8080

ENTRYPOINT ["whatfeature"]
CMD ["serve"]

# shelf with map tiles from OpenStreetMap (via the gateway) instead of MapTiler, whose URL and key are
# compiled into the client bundle, and a server that listens only on HOST; each patch fails the build
# unless exactly one place matches.
FROM ghcr.io/shelf-nu/shelf.nu:2.2.0

COPY use-osm-tiles.ts listen-on-host.ts /tmp/
RUN node --experimental-strip-types /tmp/use-osm-tiles.ts /src/apps/webapp/build \
    && node --experimental-strip-types /tmp/listen-on-host.ts /src/apps/webapp/build \
    && rm /tmp/use-osm-tiles.ts /tmp/listen-on-host.ts

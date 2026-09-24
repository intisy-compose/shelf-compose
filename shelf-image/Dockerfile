# shelf with map tiles from OpenStreetMap (via the gateway) instead of MapTiler, whose URL and key are
# compiled into the client bundle; the patch fails the build unless exactly one tile template matches.
FROM ghcr.io/shelf-nu/shelf.nu:2.2.0

COPY use-osm-tiles.ts /tmp/use-osm-tiles.ts
RUN node --experimental-strip-types /tmp/use-osm-tiles.ts /src/apps/webapp/build && rm /tmp/use-osm-tiles.ts

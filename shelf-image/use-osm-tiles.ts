import { readdirSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";

const maptilerTemplate =
  /"https:\/\/api\.maptiler\.com\/maps\/"\+(\w+)\+"\/256\/"\+(\w+)\+"\/"\+(\w+)\+"\/"\+(\w+)\+\((\w+)>=2\?"@2x":""\)\+"\.png\?key="\+(\w+)/g;

function* javascriptFiles(directory: string): Generator<string> {
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    if (statSync(path).isDirectory()) yield* javascriptFiles(path);
    else if (path.endsWith(".js")) yield path;
  }
}

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

const buildRoot = process.argv[2] ?? fail("usage: use-osm-tiles.ts <webapp build directory>");
const clientFiles = [...javascriptFiles(join(buildRoot, "client"))];
const allFiles = [...clientFiles, ...javascriptFiles(join(buildRoot, "server"))];

let replaced = 0;
const patched: string[] = [];
for (const path of clientFiles) {
  const source = readFileSync(path, "utf8");
  const updated = source.replace(maptilerTemplate, (_match: string, _style: string, zoom: string, x: string, y: string) => {
    replaced += 1;
    return `"/osm-tiles/"+${zoom}+"/"+${x}+"/"+${y}+".png"`;
  });
  if (updated !== source) {
    writeFileSync(path, updated);
    patched.push(path);
  }
}
if (replaced !== 1) fail(`expected exactly one MapTiler tile template, replaced ${replaced}`);

/**
 * @implNote Client assets are served with a one-year max-age under content-hashed names, so a
 * browser that loaded the MapTiler version keeps it until the name changes. Every file that leads
 * to the patched one (its importers, their importers, up to the manifest the uncached HTML links)
 * is renamed, and every reference in the client and server builds follows.
 */
function renameImportChain(start: string[]): number {
  const chain = new Set(start);
  let grew = true;
  while (grew) {
    grew = false;
    const names = [...chain].map((path) => basename(path));
    for (const path of clientFiles) {
      if (chain.has(path)) continue;
      const source = readFileSync(path, "utf8");
      if (names.some((name) => source.includes(name))) {
        chain.add(path);
        grew = true;
      }
    }
  }
  const renames = [...chain].map((path) => [basename(path), basename(path).replace(/\.js$/, "-osm.js")] as const);
  for (const path of allFiles) {
    const source = readFileSync(path, "utf8");
    const updated = renames.reduce((text, [from, to]) => text.split(from).join(to), source);
    if (updated !== source) writeFileSync(path, updated);
  }
  for (const path of chain) renameSync(path, path.replace(/\.js$/, "-osm.js"));
  return chain.size;
}

const renamed = renameImportChain(patched);
console.log(`map tiles now load from /osm-tiles/; renamed ${renamed} cached client files`);

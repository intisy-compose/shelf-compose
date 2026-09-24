import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const maptilerTemplate =
  /"https:\/\/api\.maptiler\.com\/maps\/"\+(\w+)\+"\/256\/"\+(\w+)\+"\/"\+(\w+)\+"\/"\+(\w+)\+\((\w+)>=2\?"@2x":""\)\+"\.png\?key="\+(\w+)/g;

function* javascriptFiles(directory: string): Generator<string> {
  for (const entry of readdirSync(directory)) {
    const path = join(directory, entry);
    if (statSync(path).isDirectory()) yield* javascriptFiles(path);
    else if (path.endsWith(".js")) yield path;
  }
}

let replaced = 0;
const clientBuild = process.argv[2];
if (!clientBuild) {
  console.error("usage: use-osm-tiles.ts <client build directory>");
  process.exit(1);
}

for (const path of javascriptFiles(clientBuild)) {
  const source = readFileSync(path, "utf8");
  const patched = source.replace(maptilerTemplate, (_match: string, _style: string, zoom: string, x: string, y: string) => {
    replaced += 1;
    return `"/osm-tiles/"+${zoom}+"/"+${x}+"/"+${y}+".png"`;
  });
  if (patched !== source) writeFileSync(path, patched);
}

if (replaced !== 1) {
  console.error(`expected exactly one MapTiler tile template, replaced ${replaced}`);
  process.exit(1);
}
console.log("map tiles now load from /osm-tiles/");

import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * @implNote shelf's server passes no hostname to react-router-hono-server, so Node listens on every
 * address. In the gateway's namespace that includes 127.0.0.1, where tailscale in userspace mode
 * hands every tailnet connection on a port serve.json does not forward. The patched server listens
 * on HOST only, and refuses to start without it rather than fall back to every address.
 */
const listenOption = "hostname: mergedOptions.hostname";
const listenOnHost =
  'hostname: process.env.HOST || (() => { throw new Error("HOST is not set: shelf listens only on the address it names"); })()';

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

const buildRoot = process.argv[2] ?? fail("usage: listen-on-host.ts <webapp build directory>");

let replaced = 0;
for (const path of javascriptFiles(join(buildRoot, "server"))) {
  const source = readFileSync(path, "utf8");
  const occurrences = source.split(listenOption).length - 1;
  if (occurrences === 0) continue;
  replaced += occurrences;
  writeFileSync(path, source.split(listenOption).join(listenOnHost));
}
if (replaced !== 1) fail(`expected exactly one '${listenOption}' in the server build, replaced ${replaced}`);
console.log("the server now listens only on HOST");

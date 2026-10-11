/* Collects the web app into www/, the folder Capacitor packs into the iOS app.

   The web app lives in the root of the repository (GitHub Pages serves it from
   there), next to things the phone has no use for: the native project, the
   documentation, node_modules. So only what the pages load is copied.

   Two differences from the site:
   - no sw.js: the files are inside the app already;
   - ".mjs" files are copied as ".js". The shell names a file's type by its
     extension and does not know ".mjs"; a module served as "octet-stream" is
     refused by the browser. platform.js asks for them by the new name. */

import { cp, mkdir, readdir, rm, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "www");

const FILES = [
  "index.html",
  "style.css",
  "platform.js",
  "spring.js",
  "icons.js",
  "recognizer.js",
  "framer.js",
  "pose-worker.js",
  "cloud.js",
  "capture.js",
  "app.js",
  "server.json",
  "manifest.webmanifest",
  "icon.svg",
  "icon-180.png",
  "icon-192.png",
  "icon-512.png",
];
const FOLDERS = ["fonts", "model", "vendor"];

async function copyTree(from, to) {
  await mkdir(to, { recursive: true });
  for (const entry of await readdir(from, { withFileTypes: true })) {
    const src = join(from, entry.name);
    if (entry.isDirectory()) await copyTree(src, join(to, entry.name));
    else await cp(src, join(to, entry.name.replace(/\.mjs$/, ".js")));
  }
}

async function size(dir) {
  let total = 0;
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    total += entry.isDirectory() ? await size(p) : (await stat(p)).size;
  }
  return total;
}

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
for (const f of FILES) await cp(join(root, f), join(out, f));
for (const d of FOLDERS) await copyTree(join(root, d), join(out, d));

console.log(`www/ is ready: ${(await size(out) / 1048576).toFixed(1)} MB`);

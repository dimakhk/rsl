/* Keeps the whole app - interface, runtime and the 19 MB model - in the
   device's cache, so after the first open it starts without a connection and
   never downloads the model again.

   Bump CACHE when anything ships: a new name means a fresh copy of everything,
   and the old one is deleted once the new version takes over. */

const CACHE = "rsl-v7";
const ASSETS = [
  "./",
  "index.html",
  "style.css",
  "spring.js",
  "recognizer.js",
  "framer.js",
  "pose-worker.js",
  "cloud.js",
  "app.js",
  "manifest.webmanifest",
  "icon.svg",
  "icon-180.png",
  "icon-192.png",
  "icon-512.png",
  "fonts/Katgru.ttf",
  "fonts/MFEvoltSpecialFree.otf",
  "vendor/ort.webgpu.min.js",
  "vendor/ort-wasm-simd-threaded.asyncify.mjs",
  "vendor/ort-wasm-simd-threaded.asyncify.wasm",
  "model/labels.json",
  "model/s3d.onnx",
  "model/pose_landmarker_lite.task",
  "vendor/mediapipe/vision_bundle.mjs",
  "vendor/mediapipe/wasm/vision_wasm_internal.js",
  "vendor/mediapipe/wasm/vision_wasm_internal.wasm",
];

self.addEventListener("install", (e) => {
  // One at a time: a tablet on a weak connection chokes on 15 parallel requests,
  // and the model is by far the largest of them.
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    for (const url of ASSETS) {
      try { await cache.add(new Request(url, { cache: "reload" })); }
      catch (err) { console.warn("sw: skipped", url, err); }
    }
    self.skipWaiting();
  })());
});

self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key !== CACHE) await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

/* Cache first: these files never change within a version, and reaching for the
   network first would make every start wait for a timeout when there is none. */
self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  // Where the recognition server lives may change between two openings of the
  // app; that one file always comes from the network (and fails without one,
  // which the app reads as "no server").
  if (new URL(e.request.url).pathname.endsWith("/server.json")) return;
  e.respondWith((async () => {
    const hit = await caches.match(e.request, { ignoreSearch: true });
    if (hit) return hit;
    try {
      const res = await fetch(e.request);
      if (res.ok && new URL(e.request.url).origin === location.origin) {
        (await caches.open(CACHE)).put(e.request, res.clone());
      }
      return res;
    } catch (err) {
      const shell = await caches.match("index.html");
      if (e.request.mode === "navigate" && shell) return shell;
      throw err;
    }
  })());
});

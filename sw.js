/* Keeps the app in the device's cache, so after the first open it starts
   without a connection and never downloads the models again.

   Two kinds of files, two rules:

   - the interface (pages, scripts, styles, the font) is small and changes with
     every release. It comes from the network whenever there is one, so a new
     version shows up on the next open; the cached copy is for being offline.

   - the models and their runtimes are 60 MB that change rarely. They come
     from the cache, and a new version of this worker takes them over from the
     previous one instead of downloading them again. If one of them is ever
     replaced, give it a new file name.

   Bump CACHE with every release. */

const CACHE = "rsl-v9";

const SHELL = [
  "./",
  "index.html",
  "style.css",
  "spring.js",
  "icons.js",
  "recognizer.js",
  "framer.js",
  "pose-worker.js",
  "cloud.js",
  "capture.js",
  "app.js",
  "manifest.webmanifest",
  "icon.svg",
  "icon-180.png",
  "icon-192.png",
  "icon-512.png",
  "fonts/GolosText.ttf",
];

const isHeavy = (url) => /\/(vendor|model)\//.test(new URL(url).pathname);

/* Only the interface is fetched here, so a new version takes over within
   seconds. The big files are carried over from the previous version when this
   one activates, and anything still missing is cached the first time the page
   asks for it - which it does at start-up. */
self.addEventListener("install", (e) => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    for (const url of SHELL) {
      try { await cache.add(new Request(url, { cache: "reload" })); }
      catch (err) { console.warn("sw: skipped", url, err); }
    }
    self.skipWaiting();
  })());
});

self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    for (const key of await caches.keys()) {
      if (key === CACHE) continue;
      // Carry the big files over before the old cache goes.
      const old = await caches.open(key);
      for (const req of await old.keys()) {
        if (isHeavy(req.url) && !(await cache.match(req))) {
          const res = await old.match(req);
          if (res) await cache.put(req, res);
        }
      }
      await caches.delete(key);
    }
    await self.clients.claim();
  })());
});

/* The network, but not for ever: on a connection that hangs the cached copy is
   served after a few seconds. */
async function fresh(request) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(request, { ignoreSearch: true });
  const network = fetch(request, { cache: "no-cache" }).then((res) => {
    if (res.ok) cache.put(request, res.clone());
    return res;
  });
  if (!cached) return network;
  const late = new Promise((resolve) => setTimeout(() => resolve(cached), 3500));
  return Promise.race([network.catch(() => cached), late]);
}

async function stored(request) {
  const hit = await caches.match(request, { ignoreSearch: true });
  if (hit) return hit;
  const res = await fetch(request);
  if (res.ok) (await caches.open(CACHE)).put(request, res.clone());
  return res;
}

self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;
  // Where the recognition server lives may change between two openings of the
  // app; that one file always comes from the network (and fails without one,
  // which the app reads as "no server").
  if (url.pathname.endsWith("/server.json")) return;
  e.respondWith(isHeavy(e.request.url) ? stored(e.request) : fresh(e.request));
});

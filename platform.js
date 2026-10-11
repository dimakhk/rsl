/* Where the app runs: in a browser (the site, the home-screen icon), or inside
   the iOS app - the same pages packed into a native shell (Capacitor; see
   docs/ios-install.md).

   The shell differs in three ways, and each has its switch here:

   - its files are inside the app, so it needs no service worker (app.js);
   - it tells the browser what a file is by its extension and does not know
     ".mjs", so the two module files are packed as ".js" (scripts/www.mjs);
   - the server.json packed into it is as old as the build, so the one on the
     site is asked first (cloud.js). */

const Platform = (() => {
  const cap = window.Capacitor;
  const native = location.protocol === "capacitor:" ||
                 Boolean(cap && cap.isNativePlatform && cap.isNativePlatform());
  return {
    native,
    site: "https://dimakhk.github.io/rsl/",
    /* The name a module file goes by here. */
    module: (path) => (native ? path.replace(/\.mjs$/, ".js") : path),
  };
})();

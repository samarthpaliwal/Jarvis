// Keeps the app's own files so it opens instantly and can say "can't reach your Mac" when it can't.
// It never stores or answers API calls: those always go to the Mac.
const CACHE = "jarvis-shell-v1";
const SHELL = ["./", "app.css", "app.js", "manifest.webmanifest", "icon-192.png", "icon-512.png", "apple-touch-icon.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin || url.pathname.includes("/v1/")) return;
  // Newest from the Mac when reachable, the saved copy otherwise.
  event.respondWith(
    fetch(event.request, { cache: "no-store" })
      .then((response) => {
        if (response.ok) { const copy = response.clone(); caches.open(CACHE).then((c) => c.put(event.request, copy)); }
        return response;
      })
      .catch(() => caches.match(event.request, { ignoreSearch: true }).then((hit) => hit || Response.error()))
  );
});

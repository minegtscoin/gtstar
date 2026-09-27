// Service worker: lets phones install GTStar as an app. It caches nothing, so every page
// and every chain read always comes straight from the network, exactly as in the browser.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", e => {
  if (e.request.mode === "navigate") e.respondWith(fetch(e.request));
});

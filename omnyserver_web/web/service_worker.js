// OmnyServer dashboard PWA service worker.
//
// Strategy:
//  - Precache the app shell (incl. the self-hosted xterm) so the dashboard
//    installs and opens offline.
//  - Same-origin GETs: network-first — fresh app code online, cached shell
//    offline. Navigations fall back to the cached shell, so the hash router
//    still resolves.
//  - Cross-origin requests: not intercepted at all.
//
// That last rule is the one that matters here, and it is where this worker
// parts ways with OmnyShell's. The Hub is a *different origin* — its URL is
// typed at login — so everything the dashboard actually reads is cross-origin:
// node status, metrics, the event stream, the shell socket. A cache-first (or
// any caching) policy there would answer a poll for live fleet state out of the
// cache, and the dashboard would confidently show a node that has been offline
// for an hour. It would also swallow the SSE stream, which must never be
// buffered or replayed. So those requests are left to the browser untouched.
//
// Bump CACHE_VERSION to invalidate old caches when the shell changes.
const CACHE_VERSION = 'omnyserver-v2';

const SHELL = [
  './',
  './app.css',
  './kit.css',
  './terminal.css',
  './boot.js',
  './manifest.json',
  './vendor/xterm/xterm.min.css',
  './vendor/xterm/xterm.min.js',
  './vendor/xterm/addon-fit.min.js',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png',
  './icons/favicon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) =>
      // Cache shell entries best-effort: a single missing file must not abort
      // the whole install.
      Promise.allSettled(SHELL.map((url) => cache.add(url)))
    ).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

async function networkFirst(request) {
  const cache = await caches.open(CACHE_VERSION);
  try {
    const response = await fetch(request);
    if (response && response.ok) cache.put(request, response.clone());
    return response;
  } catch (err) {
    const cached = await cache.match(request);
    if (cached) return cached;
    if (request.mode === 'navigate') {
      const shell = await cache.match('./');
      if (shell) return shell;
    }
    throw err;
  }
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return; // The Hub. Never ours to cache.

  event.respondWith(networkFirst(request));
});

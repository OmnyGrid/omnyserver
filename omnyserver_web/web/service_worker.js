// OmnyServer dashboard PWA service worker.
//
// Strategy:
//  - Precache the app shell (incl. the self-hosted xterm) so the dashboard
//    installs and opens offline.
//  - Same-origin GETs: network-first — fresh app code online, cached shell
//    offline. Navigations fall back to the cached shell, so the hash router
//    still resolves.
//  - Anything belonging to the Hub: not intercepted at all.
//
// That last rule is the one that matters here. Nothing the dashboard reads from
// the Hub may be cached: a poll for live fleet state answered out of the cache
// would show a node that has been offline for an hour, confidently. The SSE
// stream must not be touched either — cloning it into the cache reads a body
// that never ends, buffering events for the life of the session.
//
// "Belonging to the Hub" needs two tests, because the dashboard reaches it two
// different ways:
//
//   * A **different origin**, when you sign in with the Hub's own URL
//     (`https://hub:8443`). Nothing cross-origin is intercepted.
//   * The **same origin**, when a proxy serves this app and forwards the API —
//     which is how `example/docker_fleet/` runs it, precisely so a browser never
//     has to be talked into trusting a self-signed certificate. Then
//     `/api/v1/...` arrives here looking like one of ours, and only the path
//     tells them apart.
//
// The origin check alone used to be the whole rule, and it silently stopped
// being enough the day the fleet grew a proxy.
//
// Bump CACHE_VERSION to invalidate old caches when the shell changes.
const CACHE_VERSION = 'omnyserver-v3';

// Paths the Hub answers, which are never ours to cache. Matched on this origin
// only; a Hub on its own origin is already excluded by the origin check.
const HUB_PATHS = ['/api/', '/shell', '/healthz', '/metrics'];

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

// `/api/` matches as a prefix; the rest match exactly or as a path segment, so
// an app asset that merely starts with those letters is still ours.
function isHubPath(pathname) {
  return HUB_PATHS.some(
    (p) =>
      p.endsWith('/')
        ? pathname.startsWith(p)
        : pathname === p || pathname.startsWith(`${p}/`)
  );
}

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
  if (url.origin !== self.location.origin) return; // A Hub of its own.
  if (isHubPath(url.pathname)) return; // A Hub behind our proxy.

  event.respondWith(networkFirst(request));
});

const CACHE = 'mahsoob-v8';

const PRECACHE = [
  '/',
  '/app',
  '/login',
  '/pricing',
  '/onboarding',
  '/payment-return',
  '/manifest.json',
  '/js/onboarding-data.js',
  '/fonts/PingARLT-Light.otf',
  '/fonts/PingARLT-Medium.otf',
  '/fonts/PingARLT-Bold.otf',
  '/js/auth.js',
  '/js/config.js',
  '/js/geo-data.js',
  '/js/security.js',
  '/img/logo-icon.png',
  '/img/logo-text.png',
  '/img/icon-192.png',
  '/img/icon-512.png',
];

// Install: pre-cache all shell assets
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(PRECACHE))
      .then(() => self.skipWaiting())
  );
});

// Activate: delete old caches
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Fetch: cache-first for assets, network-first for API calls
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // Only handle same-origin GET requests — let browser handle everything else
  if (
    url.origin !== self.location.origin ||
    e.request.method !== 'GET'
  ) {
    return;
  }

  e.respondWith(
    caches.match(e.request).then(cached => {
      if (cached) return cached;

      return fetch(e.request).then(response => {
        // Cache successful responses for same-origin assets
        if (response.ok && url.origin === self.location.origin) {
          const copy = response.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return response;
      }).catch(() => {
        if (e.request.mode === 'navigate') {
          return caches.match('/index.html');
        }
        return new Response('', { status: 503 });
      });
    })
  );
});

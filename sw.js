const CACHE = 'mahsoob-v3';

const PRECACHE = [
  '/',
  '/index.html',
  '/login.html',
  '/pricing.html',
  '/manifest.json',
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

  // Always go to network for Supabase API and auth
  if (
    url.hostname.includes('supabase.co') ||
    url.hostname.includes('supabase.io') ||
    e.request.method !== 'GET'
  ) {
    return; // let browser handle it normally
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
        // Offline fallback for navigation requests
        if (e.request.mode === 'navigate') {
          return caches.match('/index.html');
        }
      });
    })
  );
});

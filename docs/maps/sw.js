// Service worker: app shell is precached; map tiles are cached as they are
// viewed or downloaded, and served from cache when offline.
const SHELL = 'maps-shell-v1';
const TILES = 'maps-tiles-v1';
const SHELL_FILES = [
  './', 'index.html', 'manifest.webmanifest', 'icon.svg',
  'vendor/leaflet.js', 'vendor/leaflet.css',
  'vendor/images/marker-icon.png', 'vendor/images/marker-icon-2x.png',
  'vendor/images/marker-shadow.png', 'vendor/images/layers.png',
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== SHELL && k !== TILES).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

const isTile = url => /\/\d+\/\d+\/\d+\.(png|jpg|jpeg|webp)$/.test(url.pathname);

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (isTile(url)) {
    e.respondWith(
      caches.open(TILES).then(async cache => {
        const hit = await cache.match(req);
        if (hit) return hit;
        try {
          const res = await fetch(req);
          if (res.ok) cache.put(req, res.clone());
          return res;
        } catch {
          return new Response('', { status: 504 });
        }
      })
    );
    return;
  }

  if (url.origin === location.origin) {
    e.respondWith(caches.match(req, { ignoreSearch: true }).then(hit => hit || fetch(req)));
  }
});

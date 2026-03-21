// ============================================================
// CleanSync — Service Worker
// Stratégie : Network First avec fallback cache
// Permet l'utilisation offline et l'installation sur iPhone/Android
// ============================================================

const CACHE_NAME    = 'cleansync-v1';
const OFFLINE_URL   = '/CleanSync/';

// Ressources à mettre en cache immédiatement à l'installation
const PRECACHE_URLS = [
  '/CleanSync/',
  '/CleanSync/index.html',
  '/CleanSync/manifest.json',
  '/CleanSync/icons/icon-192.png',
  '/CleanSync/icons/icon-512.png',
];

// ============================================================
// INSTALL — précache les ressources essentielles
// ============================================================
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

// ============================================================
// ACTIVATE — nettoie les anciens caches
// ============================================================
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys
          .filter(key => key !== CACHE_NAME)
          .map(key => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});

// ============================================================
// FETCH — Network First, fallback cache
// ============================================================
self.addEventListener('fetch', event => {
  // Ne pas intercepter les requêtes Supabase (auth, données)
  if (event.request.url.includes('supabase.co')) return;
  if (event.request.url.includes('googleapis.com')) return;
  if (event.request.url.includes('jsdelivr.net')) return;

  // Pour les navigations (pages HTML) : Network First
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          // Mettre en cache la réponse fraîche
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          return response;
        })
        .catch(() => {
          // Offline : servir depuis le cache
          return caches.match(OFFLINE_URL) || caches.match('/CleanSync/index.html');
        })
    );
    return;
  }

  // Pour les autres ressources : Cache First
  event.respondWith(
    caches.match(event.request)
      .then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(response => {
          if (!response || response.status !== 200 || response.type !== 'basic') return response;
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          return response;
        });
      })
  );
});

// ============================================================
// MESSAGE — force la mise à jour
// ============================================================
self.addEventListener('message', event => {
  if (event.data?.type === 'SKIP_WAITING') self.skipWaiting();
});

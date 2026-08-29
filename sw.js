// ============================================================
// CleanSync — Service Worker
// Stratégie : Network First avec fallback cache
// Permet l'utilisation offline et l'installation sur iPhone/Android
//
// Tous les chemins sont RELATIFS (pas de "/CleanSync/" en dur) afin
// que le service worker fonctionne quel que soit l'endroit où l'app
// est déployée : sous-dossier GitHub Pages, racine d'un domaine
// personnalisé, etc. Les chemins relatifs se résolvent par rapport
// à l'emplacement de ce fichier sw.js lui-même.
// ============================================================

const CACHE_NAME  = 'cleansync-v2';
const OFFLINE_URL = './index.html';

// Ressources à mettre en cache immédiatement à l'installation.
// Les icônes sont à la racine du dépôt (pas dans un sous-dossier /icons/).
const PRECACHE_URLS = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
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
  // Ne pas intercepter les requêtes vers des services tiers
  if (event.request.url.includes('supabase.co')) return;
  if (event.request.url.includes('googleapis.com')) return;
  if (event.request.url.includes('jsdelivr.net')) return;

  // Pour les navigations (pages HTML) : Network First
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          return response;
        })
        .catch(() => caches.match(OFFLINE_URL))
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

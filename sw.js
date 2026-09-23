// ============================================================================
// DOMUS — Service Worker: cachea el "app shell" para que la PWA instale y
// abra rápido. Las llamadas a Supabase (auth/datos) NUNCA se cachean aquí:
// solo se intercepta lo que es del mismo origen (HTML/CSS/JS/íconos).
// ============================================================================

const VERSION = 'domus-v15';
const CACHE_SHELL = `${VERSION}-shell`;

const ARCHIVOS_SHELL = [
  './',
  './index.html',
  './registro/',
  './recuperar/',
  './nueva-password/',
  './hogares/',
  './dashboard/',
  './miembros/',
  './perfil/',
  './mercado/',
  './gastos/',
  './servicios/',
  './manifest.json',
  './css/styles.css',
  './js/config.js',
  './js/supabaseClient.js',
  './js/auth.js',
  './js/hogares.js',
  './js/mercado.js',
  './js/gastos.js',
  './js/servicios.js',
  './js/ui.js',
  './js/register-sw.js',
  './icons/icon-192.png',
  './icons/icon-512.png',
];

self.addEventListener('install', (evento) => {
  evento.waitUntil(
    caches.open(CACHE_SHELL).then((cache) => cache.addAll(ARCHIVOS_SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (evento) => {
  evento.waitUntil(
    caches
      .keys()
      .then((claves) =>
        Promise.all(claves.filter((clave) => clave !== CACHE_SHELL).map((clave) => caches.delete(clave)))
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (evento) => {
  const url = new URL(evento.request.url);

  // Solo intervenimos peticiones GET del mismo origen (nunca Supabase ni CDNs)
  if (evento.request.method !== 'GET' || url.origin !== self.location.origin) {
    return;
  }

  evento.respondWith(
    caches.match(evento.request).then((enCache) => {
      const redFetch = fetch(evento.request)
        .then((respuesta) => {
          const copia = respuesta.clone();
          caches.open(CACHE_SHELL).then((cache) => cache.put(evento.request, copia));
          return respuesta;
        })
        .catch(() => enCache);

      // Estrategia "stale-while-revalidate": responde rápido con caché si existe,
      // y actualiza el caché en segundo plano.
      return enCache || redFetch;
    })
  );
});

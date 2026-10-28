// Guarda la app en el teléfono para que abra rápido y aunque no haya señal.
// Las consultas al BCRA siempre van por internet (no se guardan acá).
// Al cambiar algo de la app, subir la versión para que los teléfonos tomen la nueva.
const VERSION = 'consulta-cuit-v1';
const ARCHIVOS = ['./', 'index.html', 'manifest.webmanifest', 'icono-192.png', 'icono-512.png', 'apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(ARCHIVOS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;   // BCRA: directo a internet
  // Primero intenta lo nuevo de internet; si no hay señal, usa lo guardado
  e.respondWith(
    fetch(e.request).then(r => {
      const copia = r.clone();
      caches.open(VERSION).then(c => c.put(e.request, copia));
      return r;
    }).catch(() => caches.match(e.request).then(r => r || caches.match('index.html')))
  );
});

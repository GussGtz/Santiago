// Service worker de "La foto con Santi": permite instalar el sitio como app y abrirlo sin conexión.
// Siempre intenta primero la red (así cada cambio publicado llega al instante) y usa la copia guardada solo si no hay internet.
// Las fotos, los likes y todo lo de Supabase nunca pasan por aquí.
const CACHE = 'santi-v1';
const BASE = ['./', 'index.html', 'favicon.svg', 'apple-touch-icon.png', 'icon-192.png', 'icon-512.png', 'manifest.webmanifest'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(BASE)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((nombres) => Promise.all(nombres.filter((n) => n !== CACHE).map((n) => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const pedido = e.request;
  // La música pide el archivo por partes (Range); eso se deja directo a la red
  if (pedido.method !== 'GET' || new URL(pedido.url).origin !== self.location.origin || pedido.headers.has('range')) return;
  e.respondWith(
    fetch(pedido)
      .then((respuesta) => {
        if (respuesta.ok) { const copia = respuesta.clone(); caches.open(CACHE).then((c) => c.put(pedido, copia)); }
        return respuesta;
      })
      .catch(() => caches.match(pedido, { ignoreSearch: true })
        .then((guardada) => guardada || (pedido.mode === 'navigate' ? caches.match('index.html') : Response.error())))
  );
});

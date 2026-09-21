// KMP Player service worker: приложение открывается без сети, обновления подтягиваются сами.
const V = 'kmp-v8';
const SHELL = ['./', './index.html', './manifest.webmanifest', './config.js', './icons/icon-192.png', './icons/icon-512.png', './icons/favicon.svg', './icons/apple-touch-icon.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const req = e.request; if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin) {
    if (url.pathname.includes('/api/')) return; // локальный сервер: только сеть
    if (req.mode === 'navigate' || url.pathname.endsWith('.html') || url.pathname.endsWith('/')) {
      e.respondWith(fetch(req).then(r => { const c = r.clone(); caches.open(V).then(x => x.put(req, c)); return r; }).catch(() => caches.match(req).then(r => r || caches.match('./index.html'))));
      return;
    }
    e.respondWith(caches.match(req).then(hit => { const net = fetch(req).then(r => { if (r.ok) { const c = r.clone(); caches.open(V).then(x => x.put(req, c)); } return r; }).catch(() => hit); return hit || net; }));
    return;
  }
  if (/fonts\.(googleapis|gstatic)\.com$|cdn\.jsdelivr\.net$/.test(url.hostname)) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => { const c = r.clone(); caches.open(V).then(x => x.put(req, c)); return r; })));
  }
});

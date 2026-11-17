// Minimal service worker so the game can be installed as an app. It caches nothing (every update shows up right away);
// it only shows a short message instead of the browser's error page when the app is opened offline.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (e) => {
  if (e.request.mode !== 'navigate') return;
  e.respondWith(fetch(e.request).catch(() => new Response(
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>타격 명상</title>' +
    '<body style="margin:0;height:100vh;display:grid;place-items:center;background:#0d1829;color:#eef2ec;font:16px system-ui,sans-serif;text-align:center">' +
    '<div><p style="font-size:22px;font-weight:700;color:#ffb43a">인터넷에 연결되지 않았어요</p><p>연결된 뒤 다시 열어 주세요.</p></div>',
    { headers: { 'Content-Type': 'text/html; charset=utf-8' } })));
});

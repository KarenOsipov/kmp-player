// KMP Player: локальный сервер. Отдаёт плеер и ищет музыку в легальных источниках:
//   Audius      — полные треки, которые артисты сами выложили для стриминга (без ключа)
//   Apple Music — каталог почти всей музыки, превью 30 секунд (iTunes Search API, без ключа)
//   Jamendo     — свободная музыка Creative Commons, можно скачивать (нужен бесплатный ключ)
const http = require('http');
const fs = require('fs');
const path = require('path');
const { Readable } = require('stream');

try {
  for (const line of fs.readFileSync(path.join(__dirname, '.env'), 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
} catch (e) {}

const PORT = +process.env.PORT || 5173;
const JAMENDO = process.env.JAMENDO_CLIENT_ID || '';
const COUNTRY = process.env.ITUNES_COUNTRY || 'KZ';
const APP = 'KMP_PLAYER';
const UA = { 'user-agent': 'KMP-Player/1.1 (local)' };

const json = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' }); res.end(JSON.stringify(obj)); };
const hostIs = (u, re) => { try { const h = new URL(u).hostname; return new URL(u).protocol === 'https:' && re.test(h); } catch (e) { return false; } };

let audiusHost = null, audiusAt = 0;
async function audius() {
  if (audiusHost && Date.now() - audiusAt < 3600e3) return audiusHost;
  try {
    const j = await (await fetch('https://api.audius.co', { headers: UA })).json();
    const list = (j.data || []).filter(Boolean);
    audiusHost = list[Math.floor(Math.random() * list.length)] || 'https://discoveryprovider.audius.co';
  } catch (e) { audiusHost = 'https://discoveryprovider.audius.co'; }
  audiusAt = Date.now();
  return audiusHost;
}

async function search(src, q) {
  if (src === 'audius') {
    const h = await audius();
    const r = await fetch(`${h}/v1/tracks/search?query=${encodeURIComponent(q)}&app_name=${APP}&limit=30`, { headers: UA });
    if (!r.ok) { audiusHost = null; throw new Error('Audius не ответил (' + r.status + ')'); }
    const j = await r.json();
    return (j.data || []).filter(t => t.is_streamable !== false).map(t => ({
      src: 'audius', id: 'audius:' + t.id, raw: t.id, title: t.title, artist: (t.user && t.user.name) || '', album: '',
      duration: t.duration, cover: (t.artwork && (t.artwork['480x480'] || t.artwork['150x150'])) || '',
      link: t.permalink ? 'https://audius.co' + t.permalink : ''
    }));
  }
  if (src === 'itunes') {
    const r = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(q)}&media=music&entity=song&limit=30&country=${COUNTRY}`, { headers: UA });
    if (!r.ok) throw new Error('Apple Music не ответил (' + r.status + ')');
    const j = await r.json();
    return (j.results || []).filter(t => t.previewUrl).map(t => ({
      src: 'itunes', id: 'itunes:' + t.trackId, title: t.trackName, artist: t.artistName, album: t.collectionName || '',
      duration: (t.trackTimeMillis || 30000) / 1000, cover: (t.artworkUrl100 || '').replace('100x100bb', '600x600bb'),
      preview: t.previewUrl, link: t.trackViewUrl
    }));
  }
  if (src === 'jamendo') {
    if (!JAMENDO) throw new Error('Нет JAMENDO_CLIENT_ID в .env');
    const api = new URL('https://api.jamendo.com/v3.0/tracks/');
    Object.entries({ client_id: JAMENDO, format: 'json', limit: '30', search: q, audioformat: 'mp32', imagesize: '300', order: 'relevance' }).forEach(([k, v]) => api.searchParams.set(k, v));
    const j = await (await fetch(api, { headers: UA })).json();
    if (j.headers && j.headers.status !== 'success') throw new Error(j.headers.error_message || 'Ошибка Jamendo');
    return (j.results || []).map(t => ({
      src: 'jamendo', id: 'jamendo:' + t.id, title: t.name, artist: t.artist_name, album: t.album_name || '',
      duration: t.duration, cover: t.image || t.album_image || '', audio: t.audio, download: t.audiodownload_allowed ? t.audiodownload : '', link: t.shareurl || ''
    }));
  }
  throw new Error('Неизвестный источник');
}

async function pipe(res, target, allowFinal) {
  const r = await fetch(target, { headers: UA, redirect: 'follow' });
  if (allowFinal && !allowFinal(r.url)) return json(res, 403, { error: 'Источник не разрешён' });
  if (!r.ok) return json(res, r.status, { error: 'Файл недоступен (' + r.status + ')' });
  res.writeHead(200, { 'content-type': r.headers.get('content-type') || 'application/octet-stream', 'cache-control': 'private, max-age=3600' });
  Readable.fromWeb(r.body).pipe(res);
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost'), q = k => url.searchParams.get(k) || '';
  try {
    if (!url.pathname.startsWith('/api/')) {
      const TYPES = { '.mp3': 'audio/mpeg', '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.webmanifest': 'application/manifest+json', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };
      const rel = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname);
      const file = path.normalize(path.join(__dirname, rel));
      if (!file.startsWith(__dirname + path.sep) || /[\\/]\.env|server\.js$|package\.json$/.test(file) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return json(res, 404, { error: 'Не найдено' });
      const type = TYPES[path.extname(file)] || 'application/octet-stream', size = fs.statSync(file).size, range = req.headers.range;
      const m = range && /bytes=(\d*)-(\d*)/.exec(range);
      if (m) {
        const start = m[1] ? +m[1] : size - +m[2], end = m[1] && m[2] ? Math.min(+m[2], size - 1) : size - 1;
        if (start >= size || start > end) { res.writeHead(416, { 'content-range': `bytes */${size}` }); return res.end(); }
        res.writeHead(206, { 'content-type': type, 'content-range': `bytes ${start}-${end}/${size}`, 'accept-ranges': 'bytes', 'content-length': end - start + 1 });
        return fs.createReadStream(file, { start, end }).pipe(res);
      }
      res.writeHead(200, { 'content-type': type, 'accept-ranges': 'bytes', 'content-length': size, 'cache-control': 'no-cache' });
      return fs.createReadStream(file).pipe(res);
    }
    if (url.pathname === '/api/health') return json(res, 200, { kmp: true, jamendo: !!JAMENDO, audius: true, itunes: true });
    if (url.pathname === '/api/search') {
      const term = q('q').trim().slice(0, 200);
      if (!term) return json(res, 200, { items: [] });
      return json(res, 200, { items: await search(q('src'), term) });
    }
    if (url.pathname === '/api/stream') {
      const src = q('src');
      if (src === 'audius') {
        const id = q('id'); if (!/^[A-Za-z0-9]+$/.test(id)) return json(res, 400, { error: 'Плохой id' });
        return pipe(res, `${await audius()}/v1/tracks/${id}/stream?app_name=${APP}`);
      }
      if (src === 'itunes' && hostIs(q('url'), /(\.|^)(apple\.com|mzstatic\.com)$/i)) return pipe(res, q('url'), u => hostIs(u, /(\.|^)(apple\.com|mzstatic\.com)$/i));
      if (src === 'jamendo' && hostIs(q('url'), /(\.|^)jamendo\.com$/i)) return pipe(res, q('url'), u => hostIs(u, /(\.|^)jamendo\.com$/i));
      return json(res, 403, { error: 'Источник не разрешён' });
    }
    if (url.pathname === '/api/img') {
      const u = q('url'); if (!hostIs(u, /./)) return json(res, 400, { error: 'Плохая ссылка' });
      const r = await fetch(u, { headers: UA });
      const type = r.headers.get('content-type') || '';
      if (!r.ok || !type.startsWith('image/')) return json(res, 415, { error: 'Не картинка' });
      const buf = Buffer.from(await r.arrayBuffer());
      if (buf.length > 3e6) return json(res, 413, { error: 'Слишком большая' });
      res.writeHead(200, { 'content-type': type }); return res.end(buf);
    }
    json(res, 404, { error: 'Не найдено' });
  } catch (e) {
    if (!res.headersSent) json(res, 502, { error: e.message }); else res.end();
  }
}).listen(PORT, '127.0.0.1', () => {
  console.log(`\n  KMP Player: http://localhost:${PORT}\n`);
  console.log('  Audius (полные треки):     включён');
  console.log('  Apple Music (превью 30с):  включён');
  console.log('  Jamendo (скачивание):      ' + (JAMENDO ? 'включён' : 'выключен, добавь JAMENDO_CLIENT_ID в .env'));
});

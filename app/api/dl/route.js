// Proxy download: supaya file TikTok bisa tersimpan langsung (tanpa diblok CORS)
export const dynamic = 'force-dynamic';
export const maxDuration = 60;

const UA =
  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36';

function isPrivateHost(h) {
  h = h.toLowerCase();
  if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || h === '::1' || h === '[::1]') return true;
  const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return false;
  const [a, b] = [+m[1], +m[2]];
  return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

export async function GET(req) {
  const sp = new URL(req.url).searchParams;
  const target = sp.get('url');
  const name = (sp.get('name') || 'tiktok').replace(/[^\w.\- ]+/g, '_').slice(0, 80);

  let u;
  try {
    u = new URL(target);
  } catch {
    return Response.json({ error: 'Invalid url' }, { status: 400 });
  }
  if (!/^https?:$/.test(u.protocol) || isPrivateHost(u.hostname)) {
    return Response.json({ error: 'Blocked url' }, { status: 400 });
  }

  try {
    const up = await fetch(u, { headers: { 'User-Agent': UA, Referer: 'https://savett.cc/' }, redirect: 'follow' });
    if (!up.ok || !up.body) return Response.json({ error: 'Upstream ' + up.status }, { status: 502 });

    const h = new Headers();
    h.set('Content-Type', up.headers.get('content-type') || 'application/octet-stream');
    const len = up.headers.get('content-length');
    if (len) h.set('Content-Length', len);
    h.set('Content-Disposition', `attachment; filename="${name}"`);
    h.set('Cache-Control', 'no-store');
    return new Response(up.body, { headers: h });
  } catch (e) {
    return Response.json({ error: 'Failed to fetch file', details: e.message }, { status: 502 });
  }
}

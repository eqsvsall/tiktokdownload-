import axios from 'axios';
import * as cheerio from 'cheerio';

export const dynamic = 'force-dynamic';
export const maxDuration = 30;

const headers = {
  'Content-Type': 'application/x-www-form-urlencoded',
  Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  Origin: 'https://savett.cc',
  Referer: 'https://savett.cc/en1/download',
  'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36',
};

async function getCsrf() {
  const res = await axios.get('https://savett.cc/en1/download');
  return {
    csrf: res.data.match(/name="csrf_token" value="([^"]+)"/)?.[1],
    cookie: res.headers['set-cookie'].map((v) => v.split(';')[0]).join('; '),
  };
}

async function postUrl(url, csrf, cookie) {
  const res = await axios.post(
    'https://savett.cc/en1/download',
    `csrf_token=${encodeURIComponent(csrf)}&url=${encodeURIComponent(url)}`,
    { headers: { ...headers, Cookie: cookie } }
  );
  return res.data;
}

function parseHtml(html) {
  const $ = cheerio.load(html);
  const stats = [];
  $('#video-info .my-1 span').each((_, el) => stats.push($(el).text().trim()));

  const data = {
    username: $('#video-info h3').first().text().trim(),
    views: stats[0] || '0',
    likes: stats[1] || '0',
    comments: stats[3] || '0',
    shares: stats[4] || '0',
    duration: $('#video-info p.text-muted').first().text().replace(/Duration:/i, '').trim() || null,
    type: 'video',
    downloads: { nowm: [], wm: [] },
    mp3: [],
    slides: [],
  };

  const slides = $('.carousel-item[data-data]');
  if (slides.length) {
    data.type = 'photo';
    slides.each((_, el) => {
      try {
        const json = JSON.parse($(el).attr('data-data').replace(/&quot;/g, '"'));
        if (Array.isArray(json.URL)) {
          json.URL.forEach((url) => data.slides.push({ index: data.slides.length + 1, url }));
        }
      } catch {}
    });
    return data;
  }

  $('#formatselect option').each((_, el) => {
    const label = $(el).text().toLowerCase();
    const raw = $(el).attr('value');
    if (!raw) return;
    try {
      const json = JSON.parse(raw.replace(/&quot;/g, '"'));
      if (!json.URL) return;
      if (label.includes('mp4') && !label.includes('watermark')) data.downloads.nowm.push(...json.URL);
      if (label.includes('watermark')) data.downloads.wm.push(...json.URL);
      if (label.includes('mp3')) data.mp3.push(...json.URL);
    } catch {}
  });

  return data;
}

export async function GET(req) {
  const url = new URL(req.url).searchParams.get('url');
  if (!url) return Response.json({ error: 'URL is required' }, { status: 400 });

  try {
    const { csrf, cookie } = await getCsrf();
    const html = await postUrl(url, csrf, cookie);
    const result = parseHtml(html);
    if (!result.username) throw new Error('Failed to parse or content not found');
    return Response.json(result);
  } catch (error) {
    return Response.json({ error: 'Failed to download', details: error.message }, { status: 500 });
  }
}

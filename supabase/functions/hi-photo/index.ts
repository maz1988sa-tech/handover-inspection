// Upload (POST) or delete (DELETE) one inspection photo after checking the key.
// Query: ?i=<inspection uuid>&p=<photo id>; header x-hi-key: <owner key or developer key>; body: the JPEG bytes.
// Owner: uploads (p_… ids) and deletes. Developer: uploads new reply photos only (d_… ids, never overwrites).
// Videos (owner only, v_… ids): the poster frame goes up like a photo (<id>.jpg); for the clip itself, POST with
// ?v=1 and headers x-hi-type / x-hi-size returns a one-time signed upload URL for <id>.mp4, so the clip goes
// straight to storage (any size the storage limit allows) instead of through this function. DELETE of a v_… id removes both files.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const BUCKET = 'handover-photos';
const MAX_PHOTOS = 1500; // per inspection
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-hi-key, x-hi-type, x-hi-size',
  'Access-Control-Max-Age': '86400',
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PID = /^[A-Za-z0-9_-]{4,64}$/;
const TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const VTYPES = new Set(['video/mp4', 'video/quicktime', 'video/webm']);
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const u = new URL(req.url);
  const id = u.searchParams.get('i') ?? '', pid = u.searchParams.get('p') ?? '', key = req.headers.get('x-hi-key') ?? '';
  if (!UUID.test(id) || !PID.test(pid) || key.length < 24) return json(400, { error: 'bad request' });
  const { data: role, error } = await sb.rpc('hi_role', { p_id: id, p_key: key });
  if (error) return json(500, { error: 'check failed' });
  if (role !== 'owner' && role !== 'dev') return json(403, { error: 'not allowed' });
  const dev = role === 'dev', path = `${id}/${pid}.jpg`;
  if (req.method === 'DELETE') {
    if (dev) return json(403, { error: 'not allowed' });
    const { error: e } = await sb.storage.from(BUCKET).remove(pid.startsWith('v_') ? [path, `${id}/${pid}.mp4`] : [path]);
    return e ? json(500, { error: e.message }) : json(200, { ok: true });
  }
  if (req.method !== 'POST') return json(405, { error: 'method not allowed' });
  if (dev !== pid.startsWith('d_')) return json(403, { error: 'not allowed' }); // reply photos are the developer's alone
  if (u.searchParams.get('v') === '1') {
    if (dev || !pid.startsWith('v_')) return json(403, { error: 'not allowed' });
    const vt = (req.headers.get('x-hi-type') ?? '').split(';')[0].trim(), size = Number(req.headers.get('x-hi-size') ?? '0');
    if (!VTYPES.has(vt)) return json(415, { error: 'unsupported type' });
    if (!(size > 0)) return json(413, { error: 'size' }); // no cap here: storage's own file limit applies
    const { data: s, error: e } = await sb.storage.from(BUCKET).createSignedUploadUrl(`${id}/${pid}.mp4`, { upsert: true });
    return e || !s ? json(500, { error: e?.message ?? 'sign failed' }) : json(200, { url: s.signedUrl });
  }
  const type = (req.headers.get('content-type') ?? 'image/jpeg').split(';')[0].trim();
  if (!TYPES.has(type)) return json(415, { error: 'unsupported type' });
  const body = new Uint8Array(await req.arrayBuffer());
  if (!body.length || body.length > 5 * 1024 * 1024) return json(413, { error: 'size' });
  const { data: listed } = await sb.storage.from(BUCKET).list(id, { limit: MAX_PHOTOS + 1 });
  if ((listed?.length ?? 0) >= MAX_PHOTOS) return json(507, { error: 'photo limit reached' });
  const { error: e } = await sb.storage.from(BUCKET).upload(path, body, { contentType: type, upsert: !dev, cacheControl: '31536000' });
  if (e) return json(dev && /exists/i.test(e.message) ? 409 : 500, { error: e.message });
  return json(200, { ok: true });
});

// Upload (POST) or delete (DELETE) one inspection photo after checking the owner key.
// Query: ?i=<inspection uuid>&p=<photo id>; header x-hi-key: <owner key>; body: the JPEG bytes.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const BUCKET = 'handover-photos';
const MAX_PHOTOS = 800; // per inspection
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-hi-key',
  'Access-Control-Max-Age': '86400',
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PID = /^[A-Za-z0-9_-]{4,64}$/;
const TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const u = new URL(req.url);
  const id = u.searchParams.get('i') ?? '', pid = u.searchParams.get('p') ?? '', key = req.headers.get('x-hi-key') ?? '';
  if (!UUID.test(id) || !PID.test(pid) || key.length < 24) return json(400, { error: 'bad request' });
  const { data: ok, error } = await sb.rpc('hi_check', { p_id: id, p_key: key });
  if (error) return json(500, { error: 'check failed' });
  if (ok !== true) return json(403, { error: 'not allowed' });
  const path = `${id}/${pid}.jpg`;
  if (req.method === 'DELETE') {
    const { error: e } = await sb.storage.from(BUCKET).remove([path]);
    return e ? json(500, { error: e.message }) : json(200, { ok: true });
  }
  if (req.method !== 'POST') return json(405, { error: 'method not allowed' });
  const type = (req.headers.get('content-type') ?? 'image/jpeg').split(';')[0].trim();
  if (!TYPES.has(type)) return json(415, { error: 'unsupported type' });
  const body = new Uint8Array(await req.arrayBuffer());
  if (!body.length || body.length > 5 * 1024 * 1024) return json(413, { error: 'size' });
  const { data: listed } = await sb.storage.from(BUCKET).list(id, { limit: MAX_PHOTOS + 1 });
  if ((listed?.length ?? 0) >= MAX_PHOTOS) return json(507, { error: 'photo limit reached' });
  const { error: e } = await sb.storage.from(BUCKET).upload(path, body, { contentType: type, upsert: true, cacheControl: '31536000' });
  return e ? json(500, { error: e.message }) : json(200, { ok: true });
});

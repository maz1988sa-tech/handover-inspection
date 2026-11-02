-- Developer replies (second migration). The developer link carries its own key (dev_key); with it the developer
-- can add a reply to an observation — a note and at least one photo of the fix — but cannot change the owner's
-- inspection. Replies are append-only rows; the owner's accept / reject decisions travel inside the owner's state.
alter table handover.inspections add column if not exists dev_key text;

create table if not exists handover.events (
  id            bigint generated always as identity primary key,
  inspection_id uuid not null references handover.inspections(id) on delete cascade,
  obs_id        text not null check (length(obs_id) between 1 and 64),
  actor         text not null check (actor in ('dev')),
  action        text not null check (action in ('fix')),
  note          text not null default '' check (length(note) <= 2000),
  photos        jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) between 1 and 12),
  archived      boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists events_inspection_idx on handover.events (inspection_id, id);
alter table handover.events enable row level security;
revoke all on table handover.events from public, anon, authenticated;

-- which key is this: 'owner', 'dev' or null
create or replace function public.hi_role(p_id uuid, p_key text)
returns text language sql stable security definer set search_path = handover, extensions, pg_temp as $$
  select case when key_hash = extensions.crypt(p_key, key_hash) then 'owner'
              when dev_key is not null and dev_key = p_key then 'dev' end
  from handover.inspections where id = p_id;
$$;

-- owner reads (and on first use creates) the developer key; p_rotate makes a new one and retires the old link
create or replace function public.hi_devkey(p_id uuid, p_key text, p_rotate boolean default false)
returns text language plpgsql security definer set search_path = handover, extensions, pg_temp as $$
declare v text;
begin
  select dev_key into v from handover.inspections where id = p_id and key_hash = extensions.crypt(p_key, key_hash) for update;
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
  if v is null or p_rotate then
    v := rtrim(translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_'), '=');
    update handover.inspections set dev_key = v where id = p_id;
  end if;
  return v;
end $$;

-- developer reply: note + 1..12 photos already uploaded through hi-photo (ids start with d_)
create or replace function public.hi_respond(p_id uuid, p_devkey text, p_obs text, p_note text, p_photos jsonb)
returns bigint language plpgsql security definer set search_path = handover, pg_temp as $$
declare v_state jsonb; v_id bigint; v_n int; ph text;
begin
  select state into v_state from handover.inspections where id = p_id and dev_key is not null and dev_key = p_devkey;
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_obs is null or not exists (select 1 from jsonb_array_elements(coalesce(v_state->'obs', '[]'::jsonb)) o where o->>'id' = p_obs) then
    raise exception 'unknown observation' using errcode = '22023';
  end if;
  if p_photos is null or jsonb_typeof(p_photos) <> 'array' or jsonb_array_length(p_photos) < 1 or jsonb_array_length(p_photos) > 12 then
    raise exception 'photo required' using errcode = '22023';
  end if;
  for ph in select jsonb_array_elements_text(p_photos) loop
    if ph !~ '^d_[A-Za-z0-9_-]{4,62}$' or not exists (
         select 1 from storage.objects where bucket_id = 'handover-photos' and name = p_id::text || '/' || ph || '.jpg') then
      raise exception 'photo missing' using errcode = '22023';
    end if;
  end loop;
  if length(coalesce(p_note, '')) > 2000 then raise exception 'note too long' using errcode = '22023'; end if;
  select count(*) into v_n from handover.events where inspection_id = p_id and not archived;
  if v_n >= 3000 then raise exception 'limit reached' using errcode = '54000'; end if;
  insert into handover.events (inspection_id, obs_id, actor, action, note, photos)
  values (p_id, p_obs, 'dev', 'fix', coalesce(p_note, ''), p_photos)
  returning id into v_id;
  return v_id;
end $$;

-- owner starts over: archives the replies (kept as a record, no longer shown) and returns their photo ids
-- so the app can delete the files
create or replace function public.hi_reset(p_id uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = handover, extensions, pg_temp as $$
declare v jsonb;
begin
  if not exists (select 1 from handover.inspections where id = p_id and key_hash = extensions.crypt(p_key, key_hash)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(ph), '[]'::jsonb) into v
    from handover.events e, jsonb_array_elements_text(e.photos) ph where e.inspection_id = p_id and not e.archived;
  update handover.events set archived = true where inspection_id = p_id and not archived;
  return v;
end $$;

-- read: the report plus the developer replies
create or replace function public.hi_get(p_id uuid)
returns jsonb language sql stable security definer set search_path = handover, pg_temp as $$
  select jsonb_build_object('state', i.state, 'updated_at', i.updated_at,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'obs', e.obs_id, 'by', e.actor, 'act', e.action,
                                                             'note', e.note, 'ph', e.photos, 'at', e.created_at) order by e.id)
                          from handover.events e where e.inspection_id = i.id and not e.archived), '[]'::jsonb))
  from handover.inspections i where i.id = p_id;
$$;

revoke all on function public.hi_role(uuid, text), public.hi_devkey(uuid, text, boolean),
  public.hi_respond(uuid, text, text, text, jsonb), public.hi_reset(uuid, text) from public, anon, authenticated;
grant execute on function public.hi_role(uuid, text), public.hi_devkey(uuid, text, boolean),
  public.hi_respond(uuid, text, text, text, jsonb), public.hi_reset(uuid, text), public.hi_get(uuid) to anon, service_role;

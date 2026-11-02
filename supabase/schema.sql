-- Property Handover Inspection (villa 858): cloud copy + read-only developer link.
-- Lives inside an existing project, fully separate from it: its own schema (handover), its own
-- hi_* functions, its own storage bucket (handover-photos) and its own edge function (hi-photo).
-- Removing it: drop schema handover cascade; drop the four hi_* functions; delete the bucket and the function.
--
-- One row per inspection. Nobody reads or writes the table directly (not exposed to the API, RLS on, no policies);
-- everything goes through the functions below. The edit key is stored only as a bcrypt hash.
create schema if not exists handover;
revoke all on schema handover from public, anon, authenticated;

create table if not exists handover.inspections (
  id         uuid primary key default gen_random_uuid(),
  key_hash   text not null,
  state      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table handover.inspections enable row level security;
revoke all on table handover.inspections from public, anon, authenticated;

-- create: owner only (run from SQL); the browser never creates inspections on this site
create or replace function public.hi_create(p_key text, p_state jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = handover, extensions, pg_temp as $$
declare v_id uuid;
begin
  if p_key is null or length(p_key) < 24 then raise exception 'weak key' using errcode = '22023'; end if;
  insert into handover.inspections (key_hash, state)
  values (extensions.crypt(p_key, extensions.gen_salt('bf', 8)), coalesce(p_state, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.hi_check(p_id uuid, p_key text)
returns boolean language sql stable security definer set search_path = handover, extensions, pg_temp as $$
  select exists (select 1 from handover.inspections where id = p_id and key_hash = extensions.crypt(p_key, key_hash));
$$;

-- save: only with the right key
create or replace function public.hi_save(p_id uuid, p_key text, p_state jsonb)
returns timestamptz language plpgsql security definer set search_path = handover, extensions, pg_temp as $$
declare v_ts timestamptz;
begin
  if octet_length(p_state::text) > 2000000 then raise exception 'state too large' using errcode = '54000'; end if;
  update handover.inspections set state = p_state, updated_at = now()
   where id = p_id and key_hash = extensions.crypt(p_key, key_hash)
  returning updated_at into v_ts;
  if v_ts is null then raise exception 'not allowed' using errcode = '42501'; end if;
  return v_ts;
end $$;

-- read: anyone holding the id (the developer link) sees the report, never the key
create or replace function public.hi_get(p_id uuid)
returns jsonb language sql stable security definer set search_path = handover, pg_temp as $$
  select jsonb_build_object('state', state, 'updated_at', updated_at) from handover.inspections where id = p_id;
$$;

revoke all on function public.hi_create(text, jsonb), public.hi_check(uuid, text),
  public.hi_save(uuid, text, jsonb), public.hi_get(uuid) from public, anon, authenticated;
grant execute on function public.hi_check(uuid, text), public.hi_save(uuid, text, jsonb), public.hi_get(uuid)
  to anon, service_role; -- the site calls them without signing in
grant execute on function public.hi_create(text, jsonb) to service_role;

-- photos: public read by exact path (<inspection id>/<photo id>.jpg); no listing, no anonymous writes.
-- Uploads and deletes go through the hi-photo edge function, which checks the key.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('handover-photos', 'handover-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Hide while editing (third migration). The owner can hide the report from the view link and the developer link
-- while adding observations and photos; those links then get only {hidden:true, hidden_at}. The owner reads
-- through hi_get_own with the key, so the owner's own copy keeps syncing while hidden.
alter table handover.inspections add column if not exists hidden_at timestamptz;

-- owner turns hiding on / off; returns the new hidden_at (null = visible)
create or replace function public.hi_hide(p_id uuid, p_key text, p_on boolean)
returns timestamptz language plpgsql security definer set search_path = handover, extensions, pg_temp as $$
declare v timestamptz;
begin
  update handover.inspections set hidden_at = case when p_on then coalesce(hidden_at, now()) end
   where id = p_id and key_hash = extensions.crypt(p_key, key_hash)
   returning hidden_at into v;
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
  return v;
end $$;

-- public read (view link, developer link): hidden while the owner is editing
create or replace function public.hi_get(p_id uuid)
returns jsonb language sql stable security definer set search_path = handover, pg_temp as $$
  select case when i.hidden_at is not null then jsonb_build_object('hidden', true, 'hidden_at', i.hidden_at)
  else jsonb_build_object('state', i.state, 'updated_at', i.updated_at,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'obs', e.obs_id, 'by', e.actor, 'act', e.action,
                                                             'note', e.note, 'ph', e.photos, 'at', e.created_at) order by e.id)
                          from handover.events e where e.inspection_id = i.id and not e.archived), '[]'::jsonb)) end
  from handover.inspections i where i.id = p_id;
$$;

-- owner read: always the full report, plus hidden_at so the app can show the switch state
create or replace function public.hi_get_own(p_id uuid, p_key text)
returns jsonb language plpgsql stable security definer set search_path = handover, extensions, pg_temp as $$
declare r jsonb;
begin
  select jsonb_build_object('state', i.state, 'updated_at', i.updated_at, 'hidden_at', i.hidden_at,
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'obs', e.obs_id, 'by', e.actor, 'act', e.action,
                                                             'note', e.note, 'ph', e.photos, 'at', e.created_at) order by e.id)
                          from handover.events e where e.inspection_id = i.id and not e.archived), '[]'::jsonb))
    into r from handover.inspections i where i.id = p_id and i.key_hash = extensions.crypt(p_key, i.key_hash);
  if r is null then raise exception 'not allowed' using errcode = '42501'; end if;
  return r;
end $$;

revoke all on function public.hi_hide(uuid, text, boolean), public.hi_get_own(uuid, text) from public, anon, authenticated;
grant execute on function public.hi_hide(uuid, text, boolean), public.hi_get_own(uuid, text), public.hi_get(uuid)
  to anon, service_role;

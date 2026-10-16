-- Farecart: pantry inventory + visit scheduling (contract in README.md,
-- "Pantry inventory and visit scheduling"). Pantries post what they have and
-- open visit slots; people book a slot and see what is available before they
-- travel. All writes go through SECURITY DEFINER functions; anon can read
-- pantry_inventory and pantry_slots directly, never pantry_visits or
-- pantry_staff_codes. Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- locations: pantry metadata + Feed America link
-- ---------------------------------------------------------------------------
alter table locations add column if not exists pantry_model text;
alter table locations add column if not exists requires_snap boolean not null default false;
alter table locations add column if not exists requires_id boolean;
alter table locations add column if not exists feedam_id int;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'locations_pantry_model_check') then
    alter table locations add constraint locations_pantry_model_check
      check (pantry_model is null or pantry_model in ('client_choice','pre_packed','both'));
  end if;
end $$;

-- 'feedam' joins the allowed source kinds (data/feedam.mjs).
alter table locations drop constraint if exists locations_source_kind_check;
alter table locations add constraint locations_source_kind_check
  check (source_kind in ('curated','usda_snap','osm','gcfd','plentiful','feedam','other'));

create unique index if not exists locations_feedam_id_idx on locations (feedam_id) where feedam_id is not null;

-- ---------------------------------------------------------------------------
-- tables
-- ---------------------------------------------------------------------------
create table if not exists pantry_inventory (
  id           uuid primary key default gen_random_uuid(),
  location_id  uuid not null references locations(id) on delete cascade,
  category     text not null check (category in ('produce','dairy','protein','canned','bread','baby','water','other')),
  level        text not null check (level in ('plenty','low','out')),
  note         text,
  reported_at  timestamptz not null default now(),
  expires_at   timestamptz,                       -- default reported_at + 24h (trigger below)
  source       text not null default 'staff' check (source in ('staff','feedam','demo')),
  unique (location_id, category)                  -- one current row per category; upsert replaces
);
create index if not exists pantry_inventory_location_idx on pantry_inventory (location_id, expires_at);

create or replace function pantry_inventory_defaults() returns trigger
language plpgsql as $$
begin
  if new.reported_at is null then new.reported_at := now(); end if;
  if new.expires_at is null then new.expires_at := new.reported_at + interval '24 hours'; end if;
  return new;
end $$;
drop trigger if exists pantry_inventory_defaults on pantry_inventory;
create trigger pantry_inventory_defaults before insert or update on pantry_inventory
  for each row execute function pantry_inventory_defaults();

create table if not exists pantry_slots (
  id           uuid primary key default gen_random_uuid(),
  location_id  uuid not null references locations(id) on delete cascade,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  capacity     int not null check (capacity > 0),
  booked       int not null default 0 check (booked >= 0),
  notes        text,
  created_by   text,                               -- 'staff' | 'demo' | contact name
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (ends_at > starts_at),
  check (booked <= capacity)
);
create index if not exists pantry_slots_location_starts_idx on pantry_slots (location_id, starts_at);
drop trigger if exists pantry_slots_updated_at on pantry_slots;
create trigger pantry_slots_updated_at before update on pantry_slots for each row execute function set_updated_at();

create table if not exists pantry_visits (
  id                 uuid primary key default gen_random_uuid(),
  slot_id            uuid not null references pantry_slots(id) on delete cascade,
  location_id        uuid not null references locations(id) on delete cascade,
  device_id          text not null,
  user_id            uuid,
  party_size         int not null default 1 check (party_size between 1 and 20),
  status             text not null default 'booked' check (status in ('booked','cancelled','arrived')),
  confirmation_code  text not null unique check (confirmation_code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  cancel_token       uuid not null default gen_random_uuid(),
  created_at         timestamptz not null default now()
);
create index if not exists pantry_visits_device_idx on pantry_visits (device_id, created_at desc);
create index if not exists pantry_visits_slot_idx on pantry_visits (slot_id);
-- one live booking per device per slot (already_booked)
create unique index if not exists pantry_visits_device_slot_live_idx
  on pantry_visits (slot_id, device_id) where status <> 'cancelled';

create table if not exists pantry_staff_codes (
  location_id    uuid primary key references locations(id) on delete cascade,
  code           text not null unique,
  contact_name   text,
  contact_phone  text,
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- RLS and grants. Supabase grants anon/authenticated full table privileges by
-- default; take them back so the only write path is the functions below.
-- ---------------------------------------------------------------------------
alter table pantry_inventory   enable row level security;
alter table pantry_slots       enable row level security;
alter table pantry_visits      enable row level security;
alter table pantry_staff_codes enable row level security;

drop policy if exists "public read pantry_inventory" on pantry_inventory;
create policy "public read pantry_inventory" on pantry_inventory for select using (true);
drop policy if exists "public read pantry_slots" on pantry_slots;
create policy "public read pantry_slots" on pantry_slots for select using (true);
-- pantry_visits and pantry_staff_codes: no policies at all -> nothing readable by anon/authenticated.

revoke all on pantry_inventory, pantry_slots, pantry_visits, pantry_staff_codes from anon, authenticated;
grant select on pantry_inventory, pantry_slots to anon, authenticated;

-- ---------------------------------------------------------------------------
-- helpers (private: not granted to anon)
-- ---------------------------------------------------------------------------
create or replace function pantry_fail(p_code text) returns void
language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_code;
end $$;
revoke all on function pantry_fail(text) from public, anon, authenticated;

-- 6 chars, uppercase alphanumeric, no 0/O/1/I.
create or replace function pantry_new_code(p_len int default 6) returns text
language plpgsql volatile as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_out text := '';
  i int;
begin
  for i in 1..p_len loop
    v_out := v_out || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return v_out;
end $$;
revoke all on function pantry_new_code(int) from public, anon, authenticated;

-- Resolve a staff code to its location, or raise bad_code.
create or replace function pantry_staff_location(p_code text) returns uuid
language plpgsql stable as $$
declare
  v_location uuid;
begin
  select location_id into v_location from pantry_staff_codes
   where code = upper(trim(coalesce(p_code, '')));
  if v_location is null then perform pantry_fail('bad_code'); end if;
  return v_location;
end $$;
revoke all on function pantry_staff_location(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- public read: inventory + next 14 days of slots
-- ---------------------------------------------------------------------------
create or replace function pantry_availability(p_location_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'location_id', p_location_id,
    'inventory', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'category', i.category, 'level', i.level, 'note', i.note,
               'reported_at', i.reported_at, 'expires_at', i.expires_at, 'source', i.source)
             order by i.category)
      from pantry_inventory i
      where i.location_id = p_location_id and i.expires_at > now()), '[]'::jsonb),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'starts_at', s.starts_at, 'ends_at', s.ends_at,
               'capacity', s.capacity, 'booked', s.booked, 'remaining', s.capacity - s.booked,
               'notes', s.notes)
             order by s.starts_at)
      from pantry_slots s
      where s.location_id = p_location_id
        and s.ends_at > now()
        and s.starts_at < now() + interval '14 days'), '[]'::jsonb),
    'staff_updated_at', (
      select greatest(
        (select max(i.reported_at) from pantry_inventory i where i.location_id = p_location_id),
        (select max(s.updated_at) from pantry_slots s where s.location_id = p_location_id)))
  );
$$;

-- ---------------------------------------------------------------------------
-- booking
-- ---------------------------------------------------------------------------
create or replace function book_visit(
  p_slot_id uuid,
  p_device_id text,
  p_party_size int default 1,
  p_user_id uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  s pantry_slots%rowtype;
  l locations%rowtype;
  v_code text;
  v_visit pantry_visits%rowtype;
  i int;
begin
  if p_device_id is null or length(trim(p_device_id)) < 8 then perform pantry_fail('bad_device'); end if;
  if coalesce(p_party_size, 1) not between 1 and 20 then perform pantry_fail('bad_party_size'); end if;

  -- Row lock serialises concurrent bookings on the same slot.
  select * into s from pantry_slots where id = p_slot_id for update;
  if not found then perform pantry_fail('slot_not_found'); end if;
  if s.ends_at <= now() then perform pantry_fail('slot_past'); end if;
  if exists (select 1 from pantry_visits v where v.slot_id = s.id and v.device_id = p_device_id and v.status <> 'cancelled') then
    perform pantry_fail('already_booked');
  end if;
  if s.booked >= s.capacity then perform pantry_fail('slot_full'); end if;

  for i in 1..20 loop
    v_code := pantry_new_code(6);
    exit when not exists (select 1 from pantry_visits where confirmation_code = v_code);
    v_code := null;
  end loop;
  if v_code is null then perform pantry_fail('code_collision'); end if;

  insert into pantry_visits (slot_id, location_id, device_id, user_id, party_size, confirmation_code)
  values (s.id, s.location_id, p_device_id, p_user_id, coalesce(p_party_size, 1), v_code)
  returning * into v_visit;

  update pantry_slots set booked = booked + 1 where id = s.id;
  select * into l from locations where id = s.location_id;

  return jsonb_build_object(
    'visit_id', v_visit.id,
    'confirmation_code', v_visit.confirmation_code,
    'cancel_token', v_visit.cancel_token,
    'starts_at', s.starts_at,
    'ends_at', s.ends_at,
    'location_id', l.id,
    'location_name', l.name,
    'address', l.address,
    'party_size', v_visit.party_size,
    'status', v_visit.status
  );
end $$;

create or replace function cancel_visit(p_visit_id uuid, p_cancel_token uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v pantry_visits%rowtype;
begin
  select * into v from pantry_visits where id = p_visit_id and cancel_token = p_cancel_token for update;
  if not found then perform pantry_fail('visit_not_found'); end if;
  if v.status = 'booked' then
    -- lock the slot before touching its counter
    perform 1 from pantry_slots where id = v.slot_id for update;
    update pantry_slots set booked = greatest(0, booked - 1) where id = v.slot_id;
    update pantry_visits set status = 'cancelled' where id = v.id returning * into v;
  elsif v.status = 'arrived' then
    perform pantry_fail('already_arrived');
  end if;
  -- already cancelled: idempotent
  return jsonb_build_object('visit_id', v.id, 'status', v.status, 'slot_id', v.slot_id);
end $$;

create or replace function my_visits(p_device_id text)
returns table (
  visit_id uuid, slot_id uuid, location_id uuid, location_name text, address text,
  lat double precision, lng double precision,
  starts_at timestamptz, ends_at timestamptz, party_size int, status text,
  confirmation_code text, cancel_token uuid, created_at timestamptz, is_upcoming boolean
)
language sql stable security definer set search_path = public as $$
  select v.id, v.slot_id, v.location_id, l.name, l.address, l.lat, l.lng,
         s.starts_at, s.ends_at, v.party_size, v.status, v.confirmation_code, v.cancel_token, v.created_at,
         (s.ends_at > now()) as is_upcoming
  from pantry_visits v
  join pantry_slots s on s.id = v.slot_id
  join locations l on l.id = v.location_id
  where v.device_id = p_device_id
    and s.ends_at > now() - interval '30 days'
  order by (s.ends_at > now()) desc,
           case when s.ends_at > now() then s.starts_at end asc,
           s.starts_at desc;
$$;

-- ---------------------------------------------------------------------------
-- staff (every function re-validates p_code)
-- ---------------------------------------------------------------------------
create or replace function staff_login(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_loc uuid := pantry_staff_location(p_code);
  l locations%rowtype;
  c pantry_staff_codes%rowtype;
begin
  select * into l from locations where id = v_loc;
  select * into c from pantry_staff_codes where location_id = v_loc;
  return jsonb_build_object('location_id', l.id, 'name', l.name, 'address', l.address,
                            'contact_name', c.contact_name, 'contact_phone', c.contact_phone);
end $$;

create or replace function staff_set_inventory(p_code text, p_category text, p_level text, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_loc uuid := pantry_staff_location(p_code);
  r pantry_inventory%rowtype;
begin
  if p_category not in ('produce','dairy','protein','canned','bread','baby','water','other') then perform pantry_fail('bad_category'); end if;
  if p_level not in ('plenty','low','out') then perform pantry_fail('bad_level'); end if;
  insert into pantry_inventory (location_id, category, level, note, reported_at, expires_at, source)
  values (v_loc, p_category, p_level, nullif(trim(p_note), ''), now(), now() + interval '24 hours', 'staff')
  on conflict (location_id, category) do update
    set level = excluded.level, note = excluded.note, reported_at = excluded.reported_at,
        expires_at = excluded.expires_at, source = excluded.source
  returning * into r;
  return to_jsonb(r);
end $$;

create or replace function staff_upsert_slot(
  p_code text, p_slot_id uuid, p_starts_at timestamptz, p_ends_at timestamptz, p_capacity int, p_notes text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_loc uuid := pantry_staff_location(p_code);
  r pantry_slots%rowtype;
  c pantry_staff_codes%rowtype;
begin
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then perform pantry_fail('bad_times'); end if;
  if coalesce(p_capacity, 0) < 1 then perform pantry_fail('bad_capacity'); end if;
  select * into c from pantry_staff_codes where location_id = v_loc;
  if p_slot_id is null then
    insert into pantry_slots (location_id, starts_at, ends_at, capacity, notes, created_by)
    values (v_loc, p_starts_at, p_ends_at, p_capacity, nullif(trim(p_notes), ''), coalesce(c.contact_name, 'staff'))
    returning * into r;
  else
    select * into r from pantry_slots where id = p_slot_id and location_id = v_loc for update;
    if not found then perform pantry_fail('slot_not_found'); end if;
    if p_capacity < r.booked then perform pantry_fail('capacity_below_booked'); end if;
    update pantry_slots
       set starts_at = p_starts_at, ends_at = p_ends_at, capacity = p_capacity, notes = nullif(trim(p_notes), '')
     where id = r.id
    returning * into r;
  end if;
  return to_jsonb(r) || jsonb_build_object('remaining', r.capacity - r.booked);
end $$;

create or replace function staff_delete_slot(p_code text, p_slot_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_loc uuid := pantry_staff_location(p_code);
  v_cancelled int;
begin
  perform 1 from pantry_slots where id = p_slot_id and location_id = v_loc for update;
  if not found then perform pantry_fail('slot_not_found'); end if;
  select count(*) into v_cancelled from pantry_visits where slot_id = p_slot_id and status = 'booked';
  delete from pantry_slots where id = p_slot_id;   -- visits cascade
  return jsonb_build_object('deleted', true, 'slot_id', p_slot_id, 'cancelled_visits', v_cancelled);
end $$;

create or replace function staff_bookings(p_code text, p_day date)
returns table (
  visit_id uuid, slot_id uuid, starts_at timestamptz, ends_at timestamptz,
  party_size int, status text, confirmation_code text, created_at timestamptz
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_loc uuid := pantry_staff_location(p_code);
begin
  return query
    select v.id, v.slot_id, s.starts_at, s.ends_at, v.party_size, v.status, v.confirmation_code, v.created_at
    from pantry_visits v
    join pantry_slots s on s.id = v.slot_id
    where v.location_id = v_loc
      and (s.starts_at at time zone 'America/Chicago')::date = coalesce(p_day, (now() at time zone 'America/Chicago')::date)
    order by s.starts_at, v.created_at;
end $$;

create or replace function staff_mark_arrived(p_code text, p_visit_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_loc uuid := pantry_staff_location(p_code);
  v pantry_visits%rowtype;
begin
  select * into v from pantry_visits where id = p_visit_id and location_id = v_loc for update;
  if not found then perform pantry_fail('visit_not_found'); end if;
  if v.status = 'cancelled' then perform pantry_fail('visit_cancelled'); end if;
  update pantry_visits set status = 'arrived' where id = v.id returning * into v;
  return jsonb_build_object('visit_id', v.id, 'status', v.status, 'confirmation_code', v.confirmation_code, 'party_size', v.party_size);
end $$;

-- ---------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------
grant execute on function pantry_availability(uuid) to anon, authenticated;
grant execute on function book_visit(uuid, text, int, uuid) to anon, authenticated;
grant execute on function cancel_visit(uuid, uuid) to anon, authenticated;
grant execute on function my_visits(text) to anon, authenticated;
grant execute on function staff_login(text) to anon, authenticated;
grant execute on function staff_set_inventory(text, text, text, text) to anon, authenticated;
grant execute on function staff_upsert_slot(text, uuid, timestamptz, timestamptz, int, text) to anon, authenticated;
grant execute on function staff_delete_slot(text, uuid) to anon, authenticated;
grant execute on function staff_bookings(text, date) to anon, authenticated;
grant execute on function staff_mark_arrived(text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- nearby_locations: same argument signature, every existing column kept,
-- pantry_model / requires_snap / requires_id / feedam_id appended.
-- ---------------------------------------------------------------------------
drop function if exists nearby_locations(double precision, double precision, location_type[], int, int);
create or replace function nearby_locations(
  p_lat double precision,
  p_lng double precision,
  p_types location_type[] default null,
  p_limit int default 25,
  p_radius_m int default 8000
)
returns table (
  id uuid, name text, type location_type, address text, neighborhood text,
  lat double precision, lng double precision, hours jsonb, hours_text text,
  accepts_ebt boolean, requirements text, languages text[], phone text, website text,
  source_url text, notes text, verified_on date, distance_m double precision,
  source_kind text, logo_url text,
  pantry_model text, requires_snap boolean, requires_id boolean, feedam_id int
)
language sql stable as $$
  select l.id, l.name, l.type, l.address, l.neighborhood, l.lat, l.lng, l.hours, l.hours_text,
         l.accepts_ebt, l.requirements, l.languages, l.phone, l.website, l.source_url, l.notes,
         l.verified_on,
         st_distance(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography) as distance_m,
         l.source_kind, l.logo_url,
         l.pantry_model, l.requires_snap, l.requires_id, l.feedam_id
  from locations l
  where l.is_active
    and (p_types is null or l.type = any(p_types))
    and st_dwithin(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
  order by distance_m
  limit p_limit;
$$;

-- FreshRoute initial schema
create extension if not exists postgis;

create type location_type as enum ('grocery', 'pantry', 'giveaway');

create table if not exists locations (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  type          location_type not null,
  address       text not null,
  neighborhood  text,
  lat           double precision not null,
  lng           double precision not null,
  geog          geography(point, 4326) generated always as (st_setsrid(st_makepoint(lng, lat), 4326)::geography) stored,
  hours         jsonb,                      -- {"mon":"9:00-17:00", ...} or free text in "notes"
  hours_text    text,
  accepts_ebt   boolean,                    -- grocery: takes Link/EBT
  requirements  text,                       -- pantry: ID, proof of address, zip restrictions
  languages     text[] default '{}',
  phone         text,
  website       text,
  source_url    text,
  notes         text,
  verified_on   date,
  verified_by   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists locations_geog_idx on locations using gist (geog);
create index if not exists locations_type_idx on locations (type) where is_active;

-- one-off giveaway events (mobile pantries, pop-ups)
create table if not exists giveaway_events (
  id           uuid primary key default gen_random_uuid(),
  location_id  uuid references locations(id) on delete cascade,
  title        text not null,
  starts_at    timestamptz not null,
  ends_at      timestamptz,
  details      text,
  source_url   text,
  created_at   timestamptz not null default now()
);
create index if not exists giveaway_events_starts_idx on giveaway_events (starts_at);

-- fares kept in data so prices change without an app release
create table if not exists fares (
  id           serial primary key,
  agency       text not null default 'CTA',
  mode         text not null,                -- bus | train
  rider        text not null,                -- full | reduced_access | student | senior_disabled
  price_cents  int  not null,
  label        text not null,
  how_to_get   text,
  signup_url   text,
  effective_on date,
  source_url   text,
  unique (agency, mode, rider)
);

-- discount programs for the eligibility quiz
create table if not exists programs (
  key          text primary key,            -- access | student
  name         text not null,
  who          text not null,
  what         text not null,
  how          text not null,
  signup_url   text,
  phone        text,
  source_url   text,
  updated_at   timestamptz not null default now()
);

-- nearest locations to a point
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
  source_url text, notes text, verified_on date, distance_m double precision
)
language sql stable as $$
  select l.id, l.name, l.type, l.address, l.neighborhood, l.lat, l.lng, l.hours, l.hours_text,
         l.accepts_ebt, l.requirements, l.languages, l.phone, l.website, l.source_url, l.notes,
         l.verified_on,
         st_distance(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography) as distance_m
  from locations l
  where l.is_active
    and (p_types is null or l.type = any(p_types))
    and st_dwithin(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
  order by distance_m
  limit p_limit;
$$;

-- updated_at trigger
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists locations_updated_at on locations;
create trigger locations_updated_at before update on locations for each row execute function set_updated_at();

-- RLS: anyone can read, only service role writes
alter table locations enable row level security;
alter table giveaway_events enable row level security;
alter table fares enable row level security;
alter table programs enable row level security;
create policy "public read locations" on locations for select using (true);
create policy "public read giveaways" on giveaway_events for select using (true);
create policy "public read fares" on fares for select using (true);
create policy "public read programs" on programs for select using (true);

-- seed fares (CTA, Oct 2026; Access reduced fares start Oct 1 2026)
insert into fares (mode, rider, price_cents, label, how_to_get, signup_url, effective_on, source_url) values
 ('bus',   'full',           225, 'Full fare bus',   null, null, '2026-10-01', 'https://www.transitchicago.com/fares/'),
 ('train', 'full',           250, 'Full fare train', null, null, '2026-10-01', 'https://www.transitchicago.com/fares/'),
 ('bus',   'reduced_access', 110, 'Access reduced fare bus',   'Apply for an Access permit (SNAP households)', 'https://getaccess.org', '2026-10-01', 'https://nita.illinois.gov/riders/access'),
 ('train', 'reduced_access', 125, 'Access reduced fare train', 'Apply for an Access permit (SNAP households)', 'https://getaccess.org', '2026-10-01', 'https://nita.illinois.gov/riders/access'),
 ('bus',   'student',         75, 'Student reduced fare bus',   'Ventra Student Card from your school, school days only', 'https://www.transitchicago.com/fares/reduced-fare/', '2026-10-01', 'https://www.transitchicago.com/fares/reduced-fare/'),
 ('train', 'student',         75, 'Student reduced fare train', 'Ventra Student Card from your school, school days only', 'https://www.transitchicago.com/fares/reduced-fare/', '2026-10-01', 'https://www.transitchicago.com/fares/reduced-fare/')
on conflict (agency, mode, rider) do update set price_cents = excluded.price_cents, label = excluded.label, how_to_get = excluded.how_to_get, signup_url = excluded.signup_url, effective_on = excluded.effective_on, source_url = excluded.source_url;

insert into programs (key, name, who, what, how, signup_url, phone, source_url) values
 ('access', 'Access reduced fare',
  'Anyone in a household that receives SNAP in Cook, DuPage, Kane, Lake, McHenry or Will County.',
  'Half-price rides: $1.10 CTA bus, $1.25 CTA train, $1 Pace. Permit lasts 4 years.',
  'Apply online at GetAccess.org with your SNAP decision letter and a state ID with the same address (ages 12–64).',
  'https://getaccess.org', '312-913-3110', 'https://nita.illinois.gov/riders/access'),
 ('student', 'Student reduced fare',
  'K–12 students (ages 7–20) on school days.',
  'Reduced fare of $0.75 per ride on CTA bus and train on school days, 5:30am–8:30pm.',
  'Ask your school for a Ventra Student Card. CPS students: see your school office.',
  'https://www.transitchicago.com/fares/reduced-fare/', null, 'https://www.transitchicago.com/fares/reduced-fare/')
on conflict (key) do update set name=excluded.name, who=excluded.who, what=excluded.what, how=excluded.how, signup_url=excluded.signup_url, phone=excluded.phone, source_url=excluded.source_url, updated_at=now();

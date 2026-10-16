-- Farecart: per-place logo. Filled by data/seed.mjs from data/logos.mjs (chain
-- table, else the website's host) as a Google favicon URL. NULL when unknown.
-- Idempotent: safe to re-run.
alter table locations add column if not exists logo_url text;

-- nearby_locations now also returns logo_url (argument signature unchanged).
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
  source_kind text, logo_url text
)
language sql stable as $$
  select l.id, l.name, l.type, l.address, l.neighborhood, l.lat, l.lng, l.hours, l.hours_text,
         l.accepts_ebt, l.requirements, l.languages, l.phone, l.website, l.source_url, l.notes,
         l.verified_on,
         st_distance(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography) as distance_m,
         l.source_kind, l.logo_url
  from locations l
  where l.is_active
    and (p_types is null or l.type = any(p_types))
    and st_dwithin(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
  order by distance_m
  limit p_limit;
$$;

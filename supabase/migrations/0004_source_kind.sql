-- Farecart: tag each location with where it came from so bulk-imported rows
-- (USDA SNAP retailer list, OpenStreetMap, pantry directories) can be told
-- apart from the hand-researched "curated" tier. Idempotent: safe to re-run.
alter table locations add column if not exists source_kind text not null default 'curated';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'locations_source_kind_check') then
    alter table locations add constraint locations_source_kind_check
      check (source_kind in ('curated','usda_snap','osm','gcfd','plentiful','other'));
  end if;
end $$;

create index if not exists locations_source_kind_idx on locations (source_kind);

-- nearby_locations now also returns source_kind (argument signature unchanged).
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
  source_kind text
)
language sql stable as $$
  select l.id, l.name, l.type, l.address, l.neighborhood, l.lat, l.lng, l.hours, l.hours_text,
         l.accepts_ebt, l.requirements, l.languages, l.phone, l.website, l.source_url, l.notes,
         l.verified_on,
         st_distance(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography) as distance_m,
         l.source_kind
  from locations l
  where l.is_active
    and (p_types is null or l.type = any(p_types))
    and st_dwithin(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
  order by distance_m
  limit p_limit;
$$;

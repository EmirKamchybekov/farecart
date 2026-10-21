-- nearby_locations also reports how many bookable visit slots each place has in the next 14 days,
-- so the results list can tag places as "Book a visit" vs "Walk-in" without one call per place.
drop function if exists nearby_locations(double precision, double precision, location_type[], int, int);
create function nearby_locations(
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
  pantry_model text, requires_snap boolean, requires_id boolean, feedam_id int,
  bookable_slots int
)
language sql stable as $$
  select l.id, l.name, l.type, l.address, l.neighborhood, l.lat, l.lng, l.hours, l.hours_text,
         l.accepts_ebt, l.requirements, l.languages, l.phone, l.website, l.source_url, l.notes,
         l.verified_on,
         st_distance(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography) as distance_m,
         l.source_kind, l.logo_url,
         l.pantry_model, l.requires_snap, l.requires_id, l.feedam_id,
         (select count(*)::int from pantry_slots s
           where s.location_id = l.id and s.ends_at > now()
             and s.starts_at < now() + interval '14 days' and s.booked < s.capacity) as bookable_slots
  from locations l
  where l.is_active
    and (p_types is null or l.type = any(p_types))
    and st_dwithin(l.geog, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_radius_m)
  order by distance_m
  limit p_limit;
$$;
grant execute on function nearby_locations(double precision, double precision, location_type[], int, int) to anon, authenticated;

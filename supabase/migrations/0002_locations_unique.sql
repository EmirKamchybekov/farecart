-- Farecart: unique key for idempotent upserts from data/seed.mjs
-- Idempotent: safe to re-run.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'locations_name_address_key'
  ) then
    alter table locations add constraint locations_name_address_key unique (name, address);
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'giveaway_events_location_title_starts_key'
  ) then
    alter table giveaway_events add constraint giveaway_events_location_title_starts_key unique (location_id, title, starts_at);
  end if;
end $$;

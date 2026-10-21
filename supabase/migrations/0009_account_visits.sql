-- Farecart: pantry visits follow the signed-in account (docs/DEVELOPER.md,
-- "Accounts"). Guests keep booking by device id exactly as before; a signed-in
-- caller (PostgREST request with the user's JWT) gets user_id stamped from
-- auth.uid(), can claim the visits this phone booked as a guest, can list every
-- visit on the account from any phone, and can delete the account.
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- pantry_visits.user_id → auth.users, nulled when the account is deleted
-- ---------------------------------------------------------------------------
-- Visits pointing at users that no longer exist would block the foreign key.
update pantry_visits v set user_id = null
where v.user_id is not null and not exists (select 1 from auth.users u where u.id = v.user_id);

alter table pantry_visits drop constraint if exists pantry_visits_user_id_fkey;
alter table pantry_visits add constraint pantry_visits_user_id_fkey
  foreign key (user_id) references auth.users (id) on delete set null;

create index if not exists pantry_visits_user_idx on pantry_visits (user_id, created_at desc) where user_id is not null;

-- ---------------------------------------------------------------------------
-- book_visit: user_id comes from the JWT, never from the client
-- ---------------------------------------------------------------------------
-- p_user_id stays in the signature so older app builds keep working, but it is
-- ignored: auth.uid() is the caller's verified id (null for anon callers), so
-- nobody can attach a booking to someone else's account.
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
  v_user uuid := auth.uid();
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
  values (s.id, s.location_id, p_device_id, v_user, coalesce(p_party_size, 1), v_code)
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

-- ---------------------------------------------------------------------------
-- claim_device_visits: guest bookings from this phone join the account
-- ---------------------------------------------------------------------------
create or replace function claim_device_visits(p_device_id text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_count int;
begin
  if v_user is null then perform pantry_fail('not_signed_in'); end if;
  if p_device_id is null or length(trim(p_device_id)) < 8 then perform pantry_fail('bad_device'); end if;
  update pantry_visits set user_id = v_user
  where device_id = p_device_id and user_id is null;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- my_account_visits: same columns as my_visits, keyed by the JWT's user
-- ---------------------------------------------------------------------------
-- my_visits(p_device_id) is unchanged (the guest path). The app calls both
-- when signed in and merges them by visit_id.
create or replace function my_account_visits()
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
  where auth.uid() is not null
    and v.user_id = auth.uid()
    and s.ends_at > now() - interval '30 days'
  order by (s.ends_at > now()) desc,
           case when s.ends_at > now() then s.starts_at end asc,
           s.starts_at desc;
$$;

-- ---------------------------------------------------------------------------
-- delete_my_account: App Store account deletion
-- ---------------------------------------------------------------------------
-- Deleting the auth.users row cascades to profiles (and GoTrue's own sessions,
-- identities and refresh tokens) and sets pantry_visits.user_id to null; the
-- visits themselves stay with the device that booked them so pantry counts
-- remain right.
create or replace function delete_my_account()
returns boolean
language plpgsql volatile security definer set search_path = public, auth as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then perform pantry_fail('not_signed_in'); end if;
  delete from auth.users where id = v_user;
  return found;
end $$;

-- ---------------------------------------------------------------------------
-- grants: the three account functions are for signed-in callers only
-- ---------------------------------------------------------------------------
revoke all on function claim_device_visits(text) from public, anon;
revoke all on function my_account_visits() from public, anon;
revoke all on function delete_my_account() from public, anon;
grant execute on function claim_device_visits(text) to authenticated;
grant execute on function my_account_visits() to authenticated;
grant execute on function delete_my_account() to authenticated;
grant execute on function book_visit(uuid, text, int, uuid) to anon, authenticated;

notify pgrst, 'reload schema';

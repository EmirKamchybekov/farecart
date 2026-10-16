-- Per-user profile for people who choose to sign in (Sign in with Apple via Supabase Auth).
-- Signing in is optional; the app works fully without a row here.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  household_snap boolean,
  is_student boolean,
  language text,
  theme text,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Users can read and write only their own row.
drop policy if exists "profiles: own row select" on public.profiles;
create policy "profiles: own row select" on public.profiles
  for select to authenticated using (auth.uid() = id);

drop policy if exists "profiles: own row insert" on public.profiles;
create policy "profiles: own row insert" on public.profiles
  for insert to authenticated with check (auth.uid() = id);

drop policy if exists "profiles: own row update" on public.profiles;
create policy "profiles: own row update" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- Keep updated_at honest on every write.
create or replace function public.profiles_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before insert or update on public.profiles
  for each row execute function public.profiles_set_updated_at();

grant select, insert, update on public.profiles to authenticated;

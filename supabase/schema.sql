-- ExpoWalk · Supabase schema (run once in SQL Editor)
-- Holds ONLY account details and usage counters. Never audio, photos, transcripts or minutes.

create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  shared_enabled boolean not null default true,      -- master switch for the shared AI allowance
  max_free_users int not null default 100,           -- first N sign-ups get the free allowance
  cap_meetings int not null default 25,              -- per user
  cap_scans int not null default 300,                -- per user (cards + notes)
  cap_seconds int not null default 28800,            -- per user, 8 h of audio
  budget_usd numeric not null default 500,           -- global stop
  cost_meeting_usd numeric not null default 0.08,    -- conservative estimate per recording
  cost_scan_usd numeric not null default 0.003,
  total_meetings int not null default 0,
  total_scans int not null default 0,
  total_seconds bigint not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default '',
  company text not null default '',
  designation text not null default '',
  phone text not null default '',
  country text not null default '',
  consent_at timestamptz,                             -- "ExpoWalk may contact me" tick
  free_slot boolean not null default false,          -- assigned automatically to the first N
  meetings_used int not null default 0,
  scans_used int not null default 0,
  seconds_used int not null default 0,
  blocked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.usage_log (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('audio','card','note')),
  item text not null,                                 -- client item id, for retry de-duplication
  seconds int not null default 0,
  created_at timestamptz not null default now(),
  unique (user_id, item)
);

-- first N sign-ups get the free allowance
create or replace function public.assign_free_slot() returns trigger language plpgsql security definer as $$
begin
  new.free_slot := (select count(*) from public.profiles where free_slot) < (select max_free_users from public.settings where id = 1);
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists profiles_free_slot on public.profiles;
create trigger profiles_free_slot before insert on public.profiles for each row execute function public.assign_free_slot();

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

-- Consume quota atomically. Called by the server (service role) before minting a token.
create or replace function public.use_quota(p_user uuid, p_kind text, p_seconds int, p_item text)
returns jsonb language plpgsql security definer as $$
declare s public.settings; p public.profiles; est numeric; already boolean;
begin
  select * into s from public.settings where id = 1 for update;
  select * into p from public.profiles where id = p_user for update;
  if p is null then return jsonb_build_object('ok', false, 'reason', 'no_profile'); end if;
  if p.blocked then return jsonb_build_object('ok', false, 'reason', 'blocked'); end if;
  if not s.shared_enabled then return jsonb_build_object('ok', false, 'reason', 'disabled'); end if;
  if not p.free_slot then return jsonb_build_object('ok', false, 'reason', 'no_free_slot'); end if;
  -- retry of the same item within 20 minutes is free
  select exists(select 1 from public.usage_log where user_id = p_user and item = p_item and created_at > now() - interval '20 minutes') into already;
  if already then
    return jsonb_build_object('ok', true, 'retry', true, 'remaining', jsonb_build_object('meetings', s.cap_meetings - p.meetings_used, 'scans', s.cap_scans - p.scans_used, 'seconds', s.cap_seconds - p.seconds_used));
  end if;
  est := s.total_meetings * s.cost_meeting_usd + s.total_scans * s.cost_scan_usd;
  if est >= s.budget_usd then return jsonb_build_object('ok', false, 'reason', 'budget'); end if;
  if p_kind = 'audio' then
    if p.meetings_used >= s.cap_meetings then return jsonb_build_object('ok', false, 'reason', 'cap_meetings'); end if;
    if p.seconds_used + coalesce(p_seconds,0) > s.cap_seconds then return jsonb_build_object('ok', false, 'reason', 'cap_seconds'); end if;
    update public.profiles set meetings_used = meetings_used + 1, seconds_used = seconds_used + coalesce(p_seconds,0) where id = p_user;
    update public.settings set total_meetings = total_meetings + 1, total_seconds = total_seconds + coalesce(p_seconds,0), updated_at = now() where id = 1;
  else
    if p.scans_used >= s.cap_scans then return jsonb_build_object('ok', false, 'reason', 'cap_scans'); end if;
    update public.profiles set scans_used = scans_used + 1 where id = p_user;
    update public.settings set total_scans = total_scans + 1, updated_at = now() where id = 1;
  end if;
  insert into public.usage_log (user_id, kind, item, seconds) values (p_user, p_kind, p_item, coalesce(p_seconds,0)) on conflict do nothing;
  select * into p from public.profiles where id = p_user;
  return jsonb_build_object('ok', true, 'remaining', jsonb_build_object('meetings', s.cap_meetings - p.meetings_used, 'scans', s.cap_scans - p.scans_used, 'seconds', s.cap_seconds - p.seconds_used));
end $$;
revoke all on function public.use_quota(uuid, text, int, text) from public, anon, authenticated;

-- Row level security: users see and edit only their own profile; settings and usage_log are server-only.
alter table public.profiles enable row level security;
alter table public.settings enable row level security;
alter table public.usage_log enable row level security;
drop policy if exists "own profile select" on public.profiles;
create policy "own profile select" on public.profiles for select using (auth.uid() = id);
drop policy if exists "own profile insert" on public.profiles;
create policy "own profile insert" on public.profiles for insert with check (auth.uid() = id and email = lower(coalesce(auth.jwt() ->> 'email', '')));
drop policy if exists "own profile update" on public.profiles;
create policy "own profile update" on public.profiles for update using (auth.uid() = id)
  with check (auth.uid() = id and email = lower(coalesce(auth.jwt() ->> 'email', '')));
-- usage counters and free_slot cannot be changed by the user
create or replace function public.protect_profile_counters() returns trigger language plpgsql as $$
begin
  if auth.role() = 'authenticated' then
    new.meetings_used := old.meetings_used; new.scans_used := old.scans_used; new.seconds_used := old.seconds_used;
    new.free_slot := old.free_slot; new.blocked := old.blocked; new.created_at := old.created_at;
  end if;
  return new;
end $$;
drop trigger if exists profiles_protect on public.profiles;
create trigger profiles_protect before update on public.profiles for each row execute function public.protect_profile_counters();

-- public, read-only view of the limits (no counters) so the app can show "25 meetings free"
create or replace view public.limits as
  select shared_enabled, max_free_users, cap_meetings, cap_scans, cap_seconds,
         (select count(*) from public.profiles where free_slot) as free_slots_taken
  from public.settings where id = 1;
grant select on public.limits to anon, authenticated;

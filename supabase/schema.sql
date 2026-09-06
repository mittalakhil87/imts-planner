-- ExpoWalk · Supabase schema (run once in SQL Editor; safe to re-run — every statement is idempotent)
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
  free_slots_taken int not null default 0,           -- atomic counter — avoids the count(*) race on sign-up
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict (id) do nothing;
-- older deployments may be missing this column — add it now; it is backfilled from the real count just
-- below, AFTER public.profiles exists (on a brand-new database this file creates profiles for the first
-- time in the same run, so the backfill can't run any earlier than that).
alter table public.settings add column if not exists free_slots_taken int not null default 0;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default '',
  company text not null default '',
  designation text not null default '',
  phone text not null default '',
  country text not null default '',
  consent_at timestamptz,                             -- "ExpoWalk may contact me" tick — also the AI-eligibility gate, checked at use time
  free_slot boolean not null default false,          -- assigned automatically to the first N sign-ups (a reserved place, not by itself permission to use it)
  meetings_used int not null default 0,
  scans_used int not null default 0,
  seconds_used int not null default 0,
  blocked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- One-time backfill for a deployment that already had profiles before free_slots_taken existed; on a
-- brand-new database profiles is empty so this is a no-op.
update public.settings set free_slots_taken = (select count(*) from public.profiles where free_slot)
  where id = 1 and free_slots_taken = 0 and exists (select 1 from public.profiles where free_slot);

create table if not exists public.usage_log (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('audio','card','note')),
  item text not null,                                 -- client item id, for retry de-duplication
  seconds int not null default 0,                     -- client-reported estimate, at reservation time
  actual_seconds int,                                 -- server-confirmed actual, at completion time (audio only)
  status text not null default 'reserved' check (status in ('reserved','completed','failed')),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  unique (user_id, item)
);
-- older deployments: add the two-phase columns if the table pre-dates this migration
alter table public.usage_log add column if not exists actual_seconds int;
alter table public.usage_log add column if not exists status text not null default 'completed' check (status in ('reserved','completed','failed'));
alter table public.usage_log add column if not exists confirmed_at timestamptz;

-- first N sign-ups get the free allowance. Uses an atomic counter (locked settings row) instead of
-- count(*) so concurrent sign-ups near the limit cannot oversubscribe the pool (EW-20).
create or replace function public.assign_free_slot() returns trigger language plpgsql security definer as $$
declare maxu int; taken int;
begin
  select max_free_users, free_slots_taken into maxu, taken from public.settings where id = 1 for update;
  if taken < maxu then
    new.free_slot := true;
    update public.settings set free_slots_taken = free_slots_taken + 1, updated_at = now() where id = 1;
  else
    new.free_slot := false;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists profiles_free_slot on public.profiles;
create trigger profiles_free_slot before insert on public.profiles for each row execute function public.assign_free_slot();

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

-- Force server-owned defaults on INSERT too — a direct authenticated INSERT (allowed by the policy below,
-- keyed on auth.uid()) must not be able to choose its own usage counters, blocked state or slot (EW-03).
-- free_slot itself is still set by profiles_free_slot above, which runs first (alphabetical trigger order).
create or replace function public.protect_profile_counters_insert() returns trigger language plpgsql as $$
begin
  new.meetings_used := 0; new.scans_used := 0; new.seconds_used := 0; new.blocked := false;
  return new;
end $$;
drop trigger if exists profiles_protect_insert on public.profiles;
create trigger profiles_protect_insert before insert on public.profiles for each row execute function public.protect_profile_counters_insert();

-- Defense in depth: usage counters and totals can never go negative, however they are written.
alter table public.profiles drop constraint if exists profiles_counters_nonneg;
alter table public.profiles add constraint profiles_counters_nonneg check (meetings_used >= 0 and scans_used >= 0 and seconds_used >= 0);
alter table public.settings drop constraint if exists settings_nonneg;
alter table public.settings add constraint settings_nonneg check (
  total_meetings >= 0 and total_scans >= 0 and total_seconds >= 0 and free_slots_taken >= 0 and
  budget_usd >= 0 and cap_meetings >= 0 and cap_scans >= 0 and cap_seconds >= 0 and max_free_users >= 0
);

-- ---- Two-phase quota: reserve before the Google call, confirm (or fail) after it. ----
-- This lets the server charge the ACTUAL outcome (real audio seconds, real success/failure) instead of
-- committing usage the moment a token is handed out — fixes EW-02's zero-duration accounting and
-- EW-19's double-charged/undercounted retries, and gives every operation a refund path on failure.

-- Reserve: called by the server before minting a short-lived Google token. Does not yet touch counters.
create or replace function public.reserve_quota(p_user uuid, p_kind text, p_seconds_est int, p_item text)
returns jsonb language plpgsql security definer as $$
declare s public.settings; p public.profiles; est numeric; existing public.usage_log; active_reserved int;
begin
  select * into s from public.settings where id = 1 for update;
  select * into p from public.profiles where id = p_user for update;
  if p is null then return jsonb_build_object('ok', false, 'reason', 'no_profile'); end if;
  if p.blocked then return jsonb_build_object('ok', false, 'reason', 'blocked'); end if;
  if not s.shared_enabled then return jsonb_build_object('ok', false, 'reason', 'disabled'); end if;
  if not p.free_slot then return jsonb_build_object('ok', false, 'reason', 'no_free_slot'); end if;
  if p.consent_at is null then return jsonb_build_object('ok', false, 'reason', 'no_consent'); end if;

  select * into existing from public.usage_log where user_id = p_user and item = p_item;
  if existing.id is not null then
    if existing.status = 'completed' and existing.confirmed_at > now() - interval '20 minutes' then
      return jsonb_build_object('ok', true, 'retry', true, 'already_done', true,
        'remaining', jsonb_build_object('meetings', s.cap_meetings - p.meetings_used, 'scans', s.cap_scans - p.scans_used, 'seconds', s.cap_seconds - p.seconds_used));
    elsif existing.status = 'reserved' and existing.created_at > now() - interval '10 minutes' then
      return jsonb_build_object('ok', true, 'retry', true,
        'remaining', jsonb_build_object('meetings', s.cap_meetings - p.meetings_used, 'scans', s.cap_scans - p.scans_used, 'seconds', s.cap_seconds - p.seconds_used));
    else
      -- stale reservation (abandoned tab) or a prior failure: free it and reserve again below
      delete from public.usage_log where user_id = p_user and item = p_item;
    end if;
  end if;

  est := s.total_meetings * s.cost_meeting_usd + s.total_scans * s.cost_scan_usd;
  if est >= s.budget_usd then return jsonb_build_object('ok', false, 'reason', 'budget'); end if;

  select count(*) into active_reserved from public.usage_log
    where user_id = p_user and kind = p_kind and status = 'reserved' and created_at > now() - interval '10 minutes';
  if p_kind = 'audio' then
    if p.meetings_used + active_reserved >= s.cap_meetings then return jsonb_build_object('ok', false, 'reason', 'cap_meetings'); end if;
    if p.seconds_used + coalesce(p_seconds_est,0) > s.cap_seconds then return jsonb_build_object('ok', false, 'reason', 'cap_seconds'); end if;
  else
    if p.scans_used + active_reserved >= s.cap_scans then return jsonb_build_object('ok', false, 'reason', 'cap_scans'); end if;
  end if;

  insert into public.usage_log (user_id, kind, item, seconds, status) values (p_user, p_kind, p_item, greatest(0, coalesce(p_seconds_est,0)), 'reserved');
  return jsonb_build_object('ok', true, 'remaining', jsonb_build_object(
    'meetings', s.cap_meetings - p.meetings_used - (case when p_kind='audio' then active_reserved+1 else active_reserved end),
    'scans', s.cap_scans - p.scans_used - (case when p_kind<>'audio' then active_reserved+1 else active_reserved end),
    'seconds', s.cap_seconds - p.seconds_used - coalesce(p_seconds_est,0)));
end $$;
revoke all on function public.reserve_quota(uuid, text, int, text) from public, anon, authenticated;

-- Confirm: called by the server after the Google call finishes (success or failure). Only now do the
-- counters move — so a failed or abandoned attempt costs the visitor nothing, and audio must report a
-- real (>0) duration to be charged (a zero-second "audio" op is rejected, not silently accepted).
create or replace function public.confirm_quota(p_user uuid, p_item text, p_actual_seconds int, p_success boolean)
returns jsonb language plpgsql security definer as $$
declare s public.settings; p public.profiles; row public.usage_log;
begin
  select * into row from public.usage_log where user_id = p_user and item = p_item for update;
  if row.id is null then return jsonb_build_object('ok', false, 'reason', 'no_reservation'); end if;
  if row.status = 'completed' then return jsonb_build_object('ok', true, 'already_done', true); end if;

  if not p_success or (row.kind = 'audio' and coalesce(p_actual_seconds,0) <= 0) then
    update public.usage_log set status = 'failed', confirmed_at = now() where id = row.id;
    return jsonb_build_object('ok', true, 'charged', false);
  end if;

  select * into s from public.settings where id = 1 for update;
  select * into p from public.profiles where id = p_user for update;
  update public.usage_log set status = 'completed', actual_seconds = p_actual_seconds, confirmed_at = now() where id = row.id;
  if row.kind = 'audio' then
    update public.profiles set meetings_used = meetings_used + 1, seconds_used = seconds_used + greatest(0, coalesce(p_actual_seconds,0)) where id = p_user;
    update public.settings set total_meetings = total_meetings + 1, total_seconds = total_seconds + greatest(0, coalesce(p_actual_seconds,0)), updated_at = now() where id = 1;
  else
    update public.profiles set scans_used = scans_used + 1 where id = p_user;
    update public.settings set total_scans = total_scans + 1, updated_at = now() where id = 1;
  end if;
  select * into p from public.profiles where id = p_user;
  return jsonb_build_object('ok', true, 'charged', true, 'remaining', jsonb_build_object(
    'meetings', s.cap_meetings - p.meetings_used, 'scans', s.cap_scans - p.scans_used, 'seconds', s.cap_seconds - p.seconds_used));
end $$;
revoke all on function public.confirm_quota(uuid, text, int, boolean) from public, anon, authenticated;

-- Legacy single-call RPC kept ONLY so an old cached client (or a rollback) doesn't hard-fail; the current
-- server no longer calls this — it uses reserve_quota + confirm_quota. Semantics match the pre-migration
-- behaviour (commit usage immediately) and it deliberately does NOT enforce consent_at, to stay a faithful
-- shim rather than a second, subtly-different code path. Remove once no deployed revision references it.
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
  insert into public.usage_log (user_id, kind, item, seconds, status) values (p_user, p_kind, p_item, coalesce(p_seconds,0), 'completed') on conflict (user_id, item) do nothing;
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

-- ---- Email abuse controls (EW-10) ----
-- The relay endpoint fixes the recipient to the caller's own verified address (never an open relay), but
-- had no per-account/global rate limit or duplicate-send protection. This table + function add both.
create table if not exists public.email_log (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  dedupe_key text,
  sent_at timestamptz not null default now()
);
create unique index if not exists email_log_dedupe on public.email_log (user_id, dedupe_key) where dedupe_key is not null;
alter table public.email_log enable row level security; -- no policies: server (service role) only

create or replace function public.check_email_rate(p_user uuid, p_dedupe text)
returns jsonb language plpgsql security definer as $$
declare p public.profiles; last_hour int; last_day int;
begin
  select * into p from public.profiles where id = p_user;
  if p is null then return jsonb_build_object('ok', false, 'reason', 'no_profile'); end if;
  if p.blocked then return jsonb_build_object('ok', false, 'reason', 'blocked'); end if;
  if p_dedupe is not null and exists(select 1 from public.email_log where user_id = p_user and dedupe_key = p_dedupe) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  select count(*) into last_hour from public.email_log where user_id = p_user and sent_at > now() - interval '1 hour';
  if last_hour >= 12 then return jsonb_build_object('ok', false, 'reason', 'rate_hour'); end if;
  select count(*) into last_day from public.email_log where user_id = p_user and sent_at > now() - interval '24 hours';
  if last_day >= 60 then return jsonb_build_object('ok', false, 'reason', 'rate_day'); end if;
  insert into public.email_log (user_id, dedupe_key) values (p_user, p_dedupe) on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.check_email_rate(uuid, text) from public, anon, authenticated;

-- public, read-only view of the limits (no counters) so the app can show "25 meetings free"
create or replace view public.limits as
  select shared_enabled, max_free_users, cap_meetings, cap_scans, cap_seconds,
         free_slots_taken
  from public.settings where id = 1;
grant select on public.limits to anon, authenticated;

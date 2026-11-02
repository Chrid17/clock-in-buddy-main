-- =============================================================================
-- Clock In Buddy: remote clock-in backend (Supabase / PostgreSQL)
--
-- How to apply: Supabase Dashboard -> SQL Editor -> New query -> paste this
-- whole file -> Run. It is safe to run more than once and keeps existing data.
--
-- What it creates:
--   * profiles            staff records with roles (staff / admin)
--   * work_sites          places staff are expected to work (geofences)
--   * attendance_events   tamper-resistant clock-in / clock-out records
--   * attendance-photos   private storage bucket for verification selfies
--   * REST endpoints (PostgREST RPC):
--       POST /rest/v1/rpc/clock_event    record a clock-in or clock-out
--       POST /rest/v1/rpc/review_event   manager verifies or rejects an event
--       POST /rest/v1/rpc/team_status    manager view of who is clocked in
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Profiles
-- -----------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists job_title text;
alter table public.profiles add column if not exists role text not null default 'staff';
alter table public.profiles add column if not exists require_site boolean not null default false;
alter table public.profiles add column if not exists active boolean not null default true;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_role_check') then
    alter table public.profiles
      add constraint profiles_role_check check (role in ('staff', 'admin'));
  end if;
end $$;

create unique index if not exists profiles_user_id_key on public.profiles (user_id);

-- Every existing account gets a profile.
insert into public.profiles (user_id, full_name, email)
select u.id,
       coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''), split_part(u.email, '@', 1)),
       u.email
from auth.users u
on conflict (user_id) do nothing;

update public.profiles p
set email = u.email
from auth.users u
where u.id = p.user_id and p.email is distinct from u.email;

-- The earliest account becomes the first manager if there is none yet.
update public.profiles
set role = 'admin'
where id = (select id from public.profiles order by created_at asc limit 1)
  and not exists (select 1 from public.profiles where role = 'admin');

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role = 'admin' and active
  );
$$;

-- New sign-ups get a profile automatically. The very first one is a manager.
create or replace function public.handle_new_staff()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (user_id, full_name, email, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from public.profiles where role = 'admin') then 'staff' else 'admin' end
  )
  on conflict (user_id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_staff on auth.users;
create trigger on_auth_user_created_staff
  after insert on auth.users
  for each row execute function public.handle_new_staff();

-- Staff can edit their own name and job title, but only managers can change
-- roles, site requirements or deactivate accounts.
create or replace function public.protect_profile_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role;
    new.require_site := old.require_site;
    new.active := old.active;
    new.email := old.email;
  end if;
  new.user_id := old.user_id;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists protect_profile_fields on public.profiles;
create trigger protect_profile_fields
  before update on public.profiles
  for each row execute function public.protect_profile_fields();

alter table public.profiles enable row level security;

drop policy if exists "profiles: read own or admin" on public.profiles;
create policy "profiles: read own or admin" on public.profiles
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "profiles: update own or admin" on public.profiles;
create policy "profiles: update own or admin" on public.profiles
  for update to authenticated
  using (user_id = auth.uid() or public.is_admin())
  with check (user_id = auth.uid() or public.is_admin());

-- -----------------------------------------------------------------------------
-- Work sites (geofences)
-- -----------------------------------------------------------------------------
create table if not exists public.work_sites (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  address text,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  radius_m integer not null default 150 check (radius_m between 20 and 50000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.work_sites enable row level security;

drop policy if exists "work_sites: staff read" on public.work_sites;
create policy "work_sites: staff read" on public.work_sites
  for select to authenticated
  using (true);

drop policy if exists "work_sites: admin write" on public.work_sites;
create policy "work_sites: admin write" on public.work_sites
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Great-circle distance in metres.
create or replace function public.distance_m(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision)
returns double precision
language sql
immutable
as $$
  select 2 * 6371000 * asin(least(1.0, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  )));
$$;

-- -----------------------------------------------------------------------------
-- Attendance events
-- -----------------------------------------------------------------------------
create table if not exists public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  staff_name text,
  event_type text not null check (event_type in ('clock_in', 'clock_out')),
  server_time timestamptz not null default now(),
  device_time timestamptz,
  latitude double precision,
  longitude double precision,
  accuracy_m double precision,
  is_mocked boolean not null default false,
  address text,
  site_id uuid references public.work_sites (id) on delete set null,
  site_name text,
  distance_m double precision,
  within_site boolean,
  photo_path text,
  photo_sha256 text,
  notes text,
  platform text,
  captured_offline boolean not null default false,
  flags text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  review_note text,
  odoo_synced boolean not null default false,
  odoo_error text
);

create index if not exists attendance_events_user_time_idx
  on public.attendance_events (user_id, server_time desc);
create index if not exists attendance_events_time_idx
  on public.attendance_events (server_time desc);
create index if not exists attendance_events_status_idx
  on public.attendance_events (status);

alter table public.attendance_events enable row level security;

-- Read only. Events are created through clock_event() and reviewed through
-- review_event(), so nobody can edit or delete proof of attendance directly.
drop policy if exists "attendance: read own or admin" on public.attendance_events;
create policy "attendance: read own or admin" on public.attendance_events
  for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- -----------------------------------------------------------------------------
-- Photo storage
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attendance-photos', 'attendance-photos', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists "attendance photos: upload own" on storage.objects;
create policy "attendance photos: upload own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'attendance-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "attendance photos: read own or admin" on storage.objects;
create policy "attendance photos: read own or admin" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'attendance-photos'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin())
  );

-- -----------------------------------------------------------------------------
-- REST endpoint: POST /rest/v1/rpc/clock_event
-- -----------------------------------------------------------------------------
create or replace function public.clock_event(
  p_event_type text,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m double precision default null,
  p_is_mocked boolean default false,
  p_address text default null,
  p_photo_path text default null,
  p_photo_sha256 text default null,
  p_notes text default null,
  p_platform text default null,
  p_device_time timestamptz default null,
  p_captured_offline boolean default false
)
returns public.attendance_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_last text;
  v_site public.work_sites;
  v_distance double precision;
  v_within boolean;
  v_slack double precision;
  v_flags text[] := '{}';
  v_row public.attendance_events;
begin
  if v_uid is null then
    raise exception 'You are not signed in.' using errcode = '28000';
  end if;

  select * into v_profile from public.profiles where user_id = v_uid;
  if v_profile.user_id is null then
    raise exception 'No staff profile was found for this account.';
  end if;
  if not v_profile.active then
    raise exception 'Your account has been deactivated. Please contact your manager.';
  end if;

  if p_event_type is null or p_event_type not in ('clock_in', 'clock_out') then
    raise exception 'Invalid event type.';
  end if;
  if p_latitude is null or p_longitude is null then
    raise exception 'Your location is required to clock in or out.';
  end if;
  if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'The location received is not valid.';
  end if;
  if p_photo_path is null or p_photo_path not like v_uid::text || '/%' then
    raise exception 'A verification photo is required.';
  end if;
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'attendance-photos' and name = p_photo_path
  ) then
    raise exception 'The verification photo was not uploaded. Please try again.';
  end if;
  if p_device_time is not null and p_device_time > now() + interval '10 minutes' then
    raise exception 'Your phone''s clock is ahead of the real time. Please correct it and try again.';
  end if;

  -- One clock action per person at a time.
  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  select event_type into v_last
  from public.attendance_events
  where user_id = v_uid
  order by server_time desc
  limit 1;

  if p_event_type = 'clock_in' and v_last = 'clock_in' then
    raise exception 'You are already clocked in.';
  end if;
  if p_event_type = 'clock_out' and coalesce(v_last, 'clock_out') <> 'clock_in' then
    raise exception 'You are not clocked in.';
  end if;

  -- Nearest active work site.
  select * into v_site
  from public.work_sites s
  where s.active
  order by public.distance_m(p_latitude, p_longitude, s.latitude, s.longitude)
  limit 1;

  if v_site.id is not null then
    v_distance := public.distance_m(p_latitude, p_longitude, v_site.latitude, v_site.longitude);
    v_slack := least(coalesce(p_accuracy_m, 0), 100);
    v_within := v_distance <= v_site.radius_m + v_slack;
  end if;

  if v_profile.require_site then
    if v_site.id is null then
      raise exception 'No work sites have been set up yet. Please ask your manager.';
    elsif not v_within then
      raise exception 'You are % m from %. Move within % m of the site to clock in or out.',
        round(v_distance), v_site.name, v_site.radius_m;
    end if;
  end if;

  if coalesce(p_is_mocked, false) then v_flags := array_append(v_flags, 'mock_location'); end if;
  if v_site.id is not null and not v_within then v_flags := array_append(v_flags, 'outside_site'); end if;
  if p_accuracy_m is null or p_accuracy_m > 100 then v_flags := array_append(v_flags, 'low_accuracy'); end if;
  if coalesce(p_captured_offline, false) then v_flags := array_append(v_flags, 'offline'); end if;
  if p_device_time is not null and not coalesce(p_captured_offline, false)
     and abs(extract(epoch from (now() - p_device_time))) > 300 then
    v_flags := array_append(v_flags, 'device_clock_skew');
  end if;

  insert into public.attendance_events (
    user_id, staff_name, event_type, device_time,
    latitude, longitude, accuracy_m, is_mocked, address,
    site_id, site_name, distance_m, within_site,
    photo_path, photo_sha256, notes, platform, captured_offline, flags
  ) values (
    v_uid, v_profile.full_name, p_event_type, p_device_time,
    p_latitude, p_longitude, p_accuracy_m, coalesce(p_is_mocked, false), left(p_address, 500),
    v_site.id, v_site.name, round(v_distance::numeric, 1)::double precision, v_within,
    p_photo_path, p_photo_sha256, left(p_notes, 500), left(p_platform, 40),
    coalesce(p_captured_offline, false), v_flags
  )
  returning * into v_row;

  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- REST endpoint: POST /rest/v1/rpc/review_event (managers)
-- -----------------------------------------------------------------------------
create or replace function public.review_event(
  p_event_id uuid,
  p_status text,
  p_note text default null
)
returns public.attendance_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.attendance_events;
begin
  if not public.is_admin() then
    raise exception 'Only managers can review attendance.';
  end if;
  if p_status not in ('pending', 'verified', 'rejected') then
    raise exception 'Invalid review status.';
  end if;

  update public.attendance_events
  set status = p_status,
      review_note = nullif(trim(coalesce(p_note, '')), ''),
      reviewed_by = case when p_status = 'pending' then null else auth.uid() end,
      reviewed_at = case when p_status = 'pending' then null else now() end
  where id = p_event_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Attendance record not found.';
  end if;
  return v_row;
end;
$$;

-- -----------------------------------------------------------------------------
-- REST endpoint: POST /rest/v1/rpc/team_status (managers)
-- -----------------------------------------------------------------------------
create or replace function public.team_status()
returns table (
  user_id uuid,
  full_name text,
  email text,
  role text,
  job_title text,
  active boolean,
  last_event_type text,
  last_event_time timestamptz,
  last_site_name text,
  last_within_site boolean,
  pending_reviews bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select p.user_id, p.full_name, p.email, p.role, p.job_title, p.active,
         l.event_type, l.server_time, l.site_name, l.within_site,
         (select count(*) from public.attendance_events e
          where e.user_id = p.user_id and e.status = 'pending')
  from public.profiles p
  left join lateral (
    select e.event_type, e.server_time, e.site_name, e.within_site
    from public.attendance_events e
    where e.user_id = p.user_id
    order by e.server_time desc
    limit 1
  ) l on true
  where public.is_admin()
  order by p.active desc, lower(coalesce(p.full_name, p.email));
$$;

revoke execute on function public.clock_event(text, double precision, double precision, double precision, boolean, text, text, text, text, text, timestamptz, boolean) from anon;
revoke execute on function public.review_event(uuid, text, text) from anon;
revoke execute on function public.team_status() from anon;
grant execute on function public.clock_event(text, double precision, double precision, double precision, boolean, text, text, text, text, text, timestamptz, boolean) to authenticated;
grant execute on function public.review_event(uuid, text, text) to authenticated;
grant execute on function public.team_status() to authenticated;

-- -----------------------------------------------------------------------------
-- Bring over history from the previous version (clock_events), once.
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (
       select 1 from information_schema.tables
       where table_schema = 'public' and table_name = 'clock_events')
     and not exists (
       select 1 from public.attendance_events where 'imported' = any (flags)) then
    insert into public.attendance_events (
      user_id, staff_name, event_type, server_time, latitude, longitude,
      address, notes, flags, status)
    select c.user_id, p.full_name, c.event_type, c.created_at, c.latitude, c.longitude,
           c.address, c.notes, array['imported'], 'pending'
    from public.clock_events c
    left join public.profiles p on p.user_id = c.user_id
    where c.event_type in ('clock_in', 'clock_out')
      and exists (select 1 from auth.users u where u.id = c.user_id);
  end if;
end $$;

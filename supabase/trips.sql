-- 함께하는 커버럽 여정 (shared trips)
-- Run this in the Supabase SQL editor (paste the whole file at once). The client works without it (solo trips stay local),
-- and switches the shared features on as soon as these tables exist.
--
--   trips          one row per journey: owner, name, start/end, final card (jsonb)
--   trip_members   who is in it and in which state; each member keeps their own GPS track (jsonb)
--   trip_photos    photos taken during the journey (by any joined member)
--
-- Member states:
--   owner      the person who started the trip
--   invited    owner invited them, waiting for their answer      → joined / declined
--   requested  they asked to join, waiting for the owner         → joined / rejected
--   joined     taking part
--   follower   following an open trip: sees its photos in the feed, does not post, not counted as a participant
--   declined / rejected / left   out (may be invited, follow or request again)

create extension if not exists pgcrypto;

create table if not exists public.trips (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null references auth.users(id) on delete cascade,
  name        text not null default '',
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  card        jsonb,                      -- {ids, track, dur, cap, title, img, members}
  created_at  timestamptz not null default now()
);
create index if not exists trips_owner_idx on public.trips(owner);
create index if not exists trips_live_idx  on public.trips(started_at) where ended_at is null;

create table if not exists public.trip_members (
  trip_id     uuid not null references public.trips(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  state       text not null check (state in ('owner','invited','requested','joined','declined','rejected','left')),
  track       jsonb not null default '[]'::jsonb,   -- [{lat,lng,ts,photo?}] downsampled by the client
  updated_at  timestamptz not null default now(),
  primary key (trip_id, user_id)
);
create index if not exists trip_members_user_idx on public.trip_members(user_id);

create table if not exists public.trip_photos (
  trip_id     uuid not null references public.trips(id) on delete cascade,
  photo_id    uuid not null,
  user_id     uuid not null,
  created_at  timestamptz not null default now(),
  primary key (trip_id, photo_id)
);

-- Later additions (safe to re-run): who may see a trip, and what an invited friend may do
alter table public.trips add column if not exists visibility text not null default 'invite';
alter table public.trips drop constraint if exists trips_visibility_check;
alter table public.trips add constraint trips_visibility_check check (visibility in ('invite','open'));
alter table public.trip_members add column if not exists role text not null default 'post';
alter table public.trip_members drop constraint if exists trip_members_role_check;
alter table public.trip_members add constraint trip_members_role_check check (role in ('post','view'));
alter table public.trip_members drop constraint if exists trip_members_state_check;
alter table public.trip_members add constraint trip_members_state_check check (state in ('owner','invited','requested','joined','declined','rejected','left','follower'));

alter table public.trips        enable row level security;
alter table public.trip_members enable row level security;
alter table public.trip_photos  enable row level security;

-- trips: everyone signed in can see them (needed to show "여정 중" badges and to ask to join);
-- only the owner creates/updates (name, ended_at, card)
drop policy if exists trips_read   on public.trips;
drop policy if exists trips_insert on public.trips;
drop policy if exists trips_update on public.trips;
create policy trips_read   on public.trips for select to authenticated using (true);
create policy trips_insert on public.trips for insert to authenticated with check (owner = auth.uid());
create policy trips_update on public.trips for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists trips_delete on public.trips;
create policy trips_delete on public.trips for delete to authenticated using (owner = auth.uid());

-- trip_members: readable by everyone signed in; the owner adds invites (and their own owner row),
-- anyone may add themselves as requested; updates go through the guard trigger below
drop policy if exists tm_read   on public.trip_members;
drop policy if exists tm_insert on public.trip_members;
drop policy if exists tm_update on public.trip_members;
create policy tm_read   on public.trip_members for select to authenticated using (true);
create policy tm_insert on public.trip_members for insert to authenticated with check (
  (user_id = auth.uid() and state = 'requested')
  or (user_id = auth.uid() and state = 'follower'
      and exists (select 1 from public.trips t where t.id = trip_members.trip_id and (t.visibility = 'open' or t.ended_at is not null)))
  or exists (select 1 from public.trips t where t.id = trip_members.trip_id and t.owner = auth.uid() and state in ('owner','invited'))
);
create policy tm_update on public.trip_members for update to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.trips t where t.id = trip_members.trip_id and t.owner = auth.uid())
);

-- trip_photos: readable by everyone; a joined member links their own photo while the trip is live; the owner may link at any time (journey cards)
drop policy if exists tp_read   on public.trip_photos;
drop policy if exists tp_insert on public.trip_photos;
create policy tp_read   on public.trip_photos for select to authenticated using (true);
create policy tp_insert on public.trip_photos for insert to authenticated with check (
  exists (select 1 from public.trips t where t.id = trip_photos.trip_id and t.owner = auth.uid())
  or (user_id = auth.uid()
      and exists (select 1 from public.trip_members m join public.trips t on t.id = m.trip_id
                  where m.trip_id = trip_photos.trip_id and m.user_id = auth.uid() and m.state in ('owner','joined') and m.role = 'post' and t.ended_at is null))
);
drop policy if exists tp_update on public.trip_photos;
create policy tp_update on public.trip_photos for update to authenticated using (
  exists (select 1 from public.trips t where t.id = trip_photos.trip_id and t.owner = auth.uid())
);

-- Guard: only the transitions listed above are allowed, members can only touch their own track,
-- and a trip holds at most 10 people besides the owner.
-- The body is a plain single-quoted string (quotes inside doubled) instead of dollar quoting: the Supabase SQL
-- editor splits statements without understanding dollar quotes and kept breaking the function apart.
-- Rules: my own row — invited→joined/declined, joined|requested→left, declined|rejected|left→requested; track updates free.
--        owner on others — requested→joined/rejected, joined|invited|requested→left (remove/cancel), declined|rejected|left→invited;
--        never their track. At most 10 people besides the owner.
create or replace function public.trip_members_guard() returns trigger
language plpgsql security definer set search_path = public
as '
declare
  is_owner boolean;
  n_active int;
begin
  is_owner := (select t.owner = auth.uid() from public.trips t where t.id = new.trip_id);
  if is_owner is null then raise exception ''no such trip''; end if;

  if tg_op = ''INSERT'' then
    if new.state = ''follower'' and not exists (select 1 from public.trips t where t.id = new.trip_id and (t.visibility = ''open'' or t.ended_at is not null)) then
      raise exception ''trip is not open'';
    end if;
    if new.state in (''invited'',''requested'') then
      n_active := (select count(*) from public.trip_members m
        where m.trip_id = new.trip_id and m.state in (''invited'',''requested'',''joined''));
      if n_active >= 10 then raise exception ''trip is full (10)''; end if;
    end if;
    new.updated_at := now();
    return new;
  end if;

  if new.trip_id <> old.trip_id or new.user_id <> old.user_id then raise exception ''not allowed''; end if;
  if new.user_id = auth.uid() then
    if new.role <> old.role and not is_owner then raise exception ''not allowed''; end if;
    if new.state <> old.state then
      if old.state = ''owner'' then raise exception ''not allowed''; end if;
      if not ((old.state = ''invited'' and new.state in (''joined'',''declined'',''follower''))
           or (old.state in (''joined'',''requested'',''follower'') and new.state = ''left'')
           or (old.state = ''follower'' and new.state = ''requested'')
           or (old.state = ''requested'' and new.state = ''follower'')
           or (old.state in (''declined'',''rejected'',''left'') and new.state in (''requested'',''follower''))) then
        raise exception ''not allowed'';
      end if;
    end if;
  elsif is_owner then
    if new.track is distinct from old.track then raise exception ''not allowed''; end if;
    if new.state <> old.state then
      if not ((old.state = ''requested'' and new.state in (''joined'',''rejected''))
           or (old.state in (''joined'',''invited'',''requested'',''follower'') and new.state = ''left'')
           or (old.state in (''declined'',''rejected'',''left'') and new.state = ''invited'')) then
        raise exception ''not allowed'';
      end if;
      if new.state = ''invited'' then
        n_active := (select count(*) from public.trip_members m
          where m.trip_id = new.trip_id and m.user_id <> new.user_id and m.state in (''invited'',''requested'',''joined''));
        if n_active >= 10 then raise exception ''trip is full (10)''; end if;
      end if;
    end if;
  else
    raise exception ''not allowed'';
  end if;
  new.updated_at := now();
  return new;
end
';

drop trigger if exists trip_members_guard on public.trip_members;
create trigger trip_members_guard before insert or update on public.trip_members
  for each row execute function public.trip_members_guard();

-- Version stamp. The app calls this to tell whether (and which version of) this file is applied; it is created last,
-- so if it exists everything above it ran too. Bump the number together with TRIPS_SQL_EXPECT in index.html.
create or replace function public.trips_sql_version() returns int language sql stable as 'select 8';
grant execute on function public.trips_sql_version() to authenticated;

-- Owner must be able to see profiles to search friends by name: profiles already readable (used by the app).
-- Card images are uploaded to the existing public photos bucket at {owner}/trip-{trip_id}.jpg.

-- When the whole file ran, the editor shows one row with installed_version = 8
select public.trips_sql_version() as installed_version;

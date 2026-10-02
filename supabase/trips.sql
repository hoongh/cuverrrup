-- 함께하는 커버럽 여정 (shared trips)
-- Run this in the Supabase SQL editor (paste the whole file at once; the function body uses $guard$ quotes so the
-- editor's statement splitter leaves it alone). The client works without it (solo trips stay local),
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
--   declined / rejected / left   out (may be invited or request again)

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

-- trip_members: readable by everyone signed in; the owner adds invites (and their own 'owner' row),
-- anyone may add themselves as 'requested'; updates go through the guard trigger below
drop policy if exists tm_read   on public.trip_members;
drop policy if exists tm_insert on public.trip_members;
drop policy if exists tm_update on public.trip_members;
create policy tm_read   on public.trip_members for select to authenticated using (true);
create policy tm_insert on public.trip_members for insert to authenticated with check (
  (user_id = auth.uid() and state = 'requested')
  or exists (select 1 from public.trips t where t.id = trip_id and t.owner = auth.uid() and state in ('owner','invited'))
);
create policy tm_update on public.trip_members for update to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.trips t where t.id = trip_id and t.owner = auth.uid())
);

-- trip_photos: readable by everyone; a joined member (or the owner) links their own photo while the trip is live
drop policy if exists tp_read   on public.trip_photos;
drop policy if exists tp_insert on public.trip_photos;
create policy tp_read   on public.trip_photos for select to authenticated using (true);
create policy tp_insert on public.trip_photos for insert to authenticated with check (
  user_id = auth.uid()
  and exists (select 1 from public.trip_members m join public.trips t on t.id = m.trip_id
              where m.trip_id = trip_id and m.user_id = auth.uid() and m.state in ('owner','joined') and t.ended_at is null)
);

-- Guard: only the transitions listed above are allowed, members can only touch their own track,
-- and a trip holds at most 10 people besides the owner.
create or replace function public.trip_members_guard() returns trigger
language plpgsql security definer set search_path = public
as $guard$
declare
  is_owner boolean;
  n_active int;
begin
  -- (assignments instead of SELECT ... INTO: the Supabase editor mistakes SELECT INTO for table creation
  --  and splices its own ALTER TABLE lines in the middle of the function body)
  is_owner := (select t.owner = auth.uid() from public.trips t where t.id = new.trip_id);
  if is_owner is null then raise exception 'no such trip'; end if;

  if tg_op = 'INSERT' then
    if new.state in ('invited','requested') then
      n_active := (select count(*) from public.trip_members m
        where m.trip_id = new.trip_id and m.state in ('invited','requested','joined'));
      if n_active >= 10 then raise exception 'trip is full (10)'; end if;
    end if;
    new.updated_at := now();
    return new;
  end if;

  -- UPDATE
  if new.trip_id <> old.trip_id or new.user_id <> old.user_id then raise exception 'not allowed'; end if;
  if new.user_id = auth.uid() then
    -- my own row: answer an invite, leave, ask again; track updates are free
    if new.state <> old.state then
      if old.state = 'owner' then raise exception 'not allowed'; end if;
      if not ((old.state = 'invited' and new.state in ('joined','declined'))
           or (old.state in ('joined','requested') and new.state = 'left')
           or (old.state in ('declined','rejected','left') and new.state = 'requested')) then
        raise exception 'not allowed';
      end if;
    end if;
  elsif is_owner then
    -- someone else's row, I am the owner: decide requests, remove, cancel or re-invite; never their track
    if new.track is distinct from old.track then raise exception 'not allowed'; end if;
    if new.state <> old.state then
      if not ((old.state = 'requested' and new.state in ('joined','rejected'))
           or (old.state in ('joined','invited','requested') and new.state = 'left')
           or (old.state in ('declined','rejected','left') and new.state = 'invited')) then
        raise exception 'not allowed';
      end if;
      if new.state = 'invited' then
        n_active := (select count(*) from public.trip_members m
          where m.trip_id = new.trip_id and m.user_id <> new.user_id and m.state in ('invited','requested','joined'));
        if n_active >= 10 then raise exception 'trip is full (10)'; end if;
      end if;
    end if;
  else
    raise exception 'not allowed';
  end if;
  new.updated_at := now();
  return new;
end
$guard$;

drop trigger if exists trip_members_guard on public.trip_members;
create trigger trip_members_guard before insert or update on public.trip_members
  for each row execute function public.trip_members_guard();

-- Owner must be able to see profiles to search friends by name: profiles already readable (used by the app).
-- Card images are uploaded to the existing public 'photos' bucket at {owner}/trip-{trip_id}.jpg.

-- Proposal: server-side journey cards (not yet wired into index.html).
--
-- Today a journey card exists only in the browser's localStorage (key ctw-journeys), so:
--   * a card's ♥ is a local flag on this phone only,
--   * other people cannot comment on or report the card itself,
--   * hashtags written on a card do not count in the Follow tab's hashtag ranking.
-- Running this file in the Supabase SQL editor creates the tables that make those features real.
-- The client work (publish a card on "여정카드에 올리기", read likes/comments, extend the activity
-- log and the ranking) is a follow-up once these exist.

create table if not exists public.journeys (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  title       text,
  caption     text,                 -- free text incl. #hashtags, same as photos.caption
  photo_ids   uuid[] not null,      -- ordered photos that make up the card
  img_path    text not null,        -- rendered card in the `photos` bucket: <user_id>/journeys/<id>.jpg
  hidden      boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.journey_likes (
  journey_id  uuid not null references public.journeys (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (journey_id, user_id)
);

create table if not exists public.journey_comments (
  id          uuid primary key default gen_random_uuid(),
  journey_id  uuid not null references public.journeys (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  body        text not null check (length(body) between 1 and 500),
  created_at  timestamptz not null default now()
);

-- Reports already exist for photos; allow a report to point at a journey instead.
alter table public.reports add column if not exists journey_id uuid references public.journeys (id) on delete cascade;
alter table public.reports alter column photo_id drop not null;

alter table public.journeys         enable row level security;
alter table public.journey_likes    enable row level security;
alter table public.journey_comments enable row level security;

create policy "journeys are readable"        on public.journeys         for select using (not hidden or auth.uid() = user_id);
create policy "owners write journeys"        on public.journeys         for all    using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "journey likes are readable"   on public.journey_likes    for select using (true);
create policy "users like as themselves"     on public.journey_likes    for all    using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "journey comments are readable" on public.journey_comments for select using (true);
create policy "users comment as themselves"  on public.journey_comments for insert with check (auth.uid() = user_id);
create policy "users delete own comments"    on public.journey_comments for delete using (auth.uid() = user_id);

-- Hashtag ranking: count tags from photo captions AND journey captions.
-- (Replace the body of the existing hashtag_counts view; keep the (tag, n) shape the client reads.)
create or replace view public.hashtag_counts as
with src as (
  select caption from public.photos   where caption is not null and hidden = false
  union all
  select caption from public.journeys where caption is not null and hidden = false
),
tags as (
  select lower(m[1]) as tag
  from src, regexp_matches(src.caption, '#([^\s#]+)', 'g') as m
)
select tag, count(*)::int as n from tags group by tag;

-- 014_create_favorite_places.sql
-- 사용자별 즐겨찾기 장소를 저장합니다.
-- 핵심 목표:
-- 1. 사용자가 관심 가게를 앱 재실행 후에도 유지할 수 있게 합니다.
-- 2. 한 사용자가 같은 장소를 중복 즐겨찾기하지 못하게 합니다.
-- 3. RLS로 본인 즐겨찾기만 조회/추가/삭제할 수 있게 막습니다.

create table if not exists public.favorite_places (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  place_id uuid not null references public.places(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id, place_id)
);

create index if not exists favorite_places_user_created_at_idx
on public.favorite_places (user_id, created_at desc);

create index if not exists favorite_places_place_id_idx
on public.favorite_places (place_id);

alter table public.favorite_places enable row level security;

drop policy if exists "favorite_places_self_read" on public.favorite_places;
drop policy if exists "favorite_places_self_insert" on public.favorite_places;
drop policy if exists "favorite_places_self_delete" on public.favorite_places;

create policy "favorite_places_self_read"
on public.favorite_places
for select
to authenticated
using (auth.uid() = user_id);

create policy "favorite_places_self_insert"
on public.favorite_places
for insert
to authenticated
with check (auth.uid() = user_id);

create policy "favorite_places_self_delete"
on public.favorite_places
for delete
to authenticated
using (auth.uid() = user_id);

-- 검증 예시:
-- select id, user_id, place_id, created_at
-- from public.favorite_places
-- order by created_at desc
-- limit 20;

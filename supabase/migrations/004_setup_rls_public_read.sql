-- 004_setup_rls_public_read.sql
-- RLS(Row Level Security) 보안 정책을 설정합니다.
-- v0.1 기준: 누구나 읽을 수 있고, 로그인한 사용자만 쓸 수 있습니다.
-- 운영 버전에서는 쓰기 권한을 관리자 또는 Edge Function으로 더 좁히는 것을 권장합니다.

alter table public.places enable row level security;
alter table public.menus enable row level security;

drop policy if exists "places_public_read" on public.places;
drop policy if exists "places_authenticated_insert" on public.places;
drop policy if exists "places_authenticated_update" on public.places;
drop policy if exists "places_authenticated_delete" on public.places;

create policy "places_public_read"
on public.places
for select
to anon, authenticated
using (true);

create policy "places_authenticated_insert"
on public.places
for insert
to authenticated
with check (true);

create policy "places_authenticated_update"
on public.places
for update
to authenticated
using (true)
with check (true);

create policy "places_authenticated_delete"
on public.places
for delete
to authenticated
using (true);

drop policy if exists "menus_public_read" on public.menus;
drop policy if exists "menus_authenticated_insert" on public.menus;
drop policy if exists "menus_authenticated_update" on public.menus;
drop policy if exists "menus_authenticated_delete" on public.menus;

create policy "menus_public_read"
on public.menus
for select
to anon, authenticated
using (true);

create policy "menus_authenticated_insert"
on public.menus
for insert
to authenticated
with check (true);

create policy "menus_authenticated_update"
on public.menus
for update
to authenticated
using (true)
with check (true);

create policy "menus_authenticated_delete"
on public.menus
for delete
to authenticated
using (true);

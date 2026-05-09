-- 007_create_profiles_and_auth_reports.sql
-- Supabase Auth 사용자와 앱 프로필을 연결하고, 가격 제보에 user_id를 붙입니다.
-- 이 단계부터 MY 페이지와 제보 내역을 실제 사용자 기준으로 확장할 수 있습니다.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text not null default '짠테커',
  point_balance integer not null default 0 check (point_balance >= 0),
  report_count integer not null default 0 check (report_count >= 0),
  accepted_report_count integer not null default 0 check (accepted_report_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists set_profiles_updated_at on public.profiles;

create trigger set_profiles_updated_at
before update on public.profiles
for each row
execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'display_name', '짠테커')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

alter table public.profiles enable row level security;

drop policy if exists "profiles_self_read" on public.profiles;
drop policy if exists "profiles_self_update" on public.profiles;
drop policy if exists "profiles_self_insert" on public.profiles;

create policy "profiles_self_read"
on public.profiles
for select
to authenticated
using (auth.uid() = id);

create policy "profiles_self_update"
on public.profiles
for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

create policy "profiles_self_insert"
on public.profiles
for insert
to authenticated
with check (auth.uid() = id);

alter table public.price_reports
add column if not exists user_id uuid references auth.users(id) on delete set null,
add column if not exists upload_status text not null default 'uploaded'
  check (upload_status in ('pending_upload', 'uploaded', 'upload_failed'));

create index if not exists price_reports_user_id_idx on public.price_reports (user_id);
create index if not exists price_reports_upload_status_idx on public.price_reports (upload_status);

drop policy if exists "price_reports_public_insert" on public.price_reports;
drop policy if exists "price_reports_authenticated_read" on public.price_reports;
drop policy if exists "price_reports_self_read" on public.price_reports;

-- v0.3 전환 정책:
-- 익명 사용자는 user_id 없이 제보할 수 있고,
-- 로그인 사용자는 반드시 본인 auth.uid()를 user_id로 넣어야 합니다.
create policy "price_reports_public_insert"
on public.price_reports
for insert
to anon, authenticated
with check (
  reported_price > 0
  and photo_count between 1 and 4
  and has_photo_attachment = true
  and report_status = 'pending'
  and (
    user_id is null
    or auth.uid() = user_id
  )
);

-- 로그인 사용자는 본인 제보만 조회할 수 있습니다.
create policy "price_reports_self_read"
on public.price_reports
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "report_photos_authenticated_read" on public.report_photos;
drop policy if exists "report_photos_self_read" on public.report_photos;

create policy "report_photos_self_read"
on public.report_photos
for select
to authenticated
using (
  exists (
    select 1
    from public.price_reports
    where price_reports.id = report_photos.report_id
      and price_reports.user_id = auth.uid()
  )
);

drop policy if exists "price_report_photos_authenticated_read" on storage.objects;
drop policy if exists "price_report_photos_self_read" on storage.objects;

create policy "price_report_photos_self_read"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'price-report-photos'
  and exists (
    select 1
    from public.report_photos
    join public.price_reports on price_reports.id = report_photos.report_id
    where report_photos.storage_bucket = storage.objects.bucket_id
      and report_photos.storage_path = storage.objects.name
      and price_reports.user_id = auth.uid()
  )
);

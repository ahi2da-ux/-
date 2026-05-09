-- 005_create_price_reports_table.sql
-- 사용자가 앱에서 제출한 가격 제보를 저장하는 테이블입니다.
-- v0.1에서는 사진 파일 자체가 아니라 사진 첨부 개수만 저장합니다.
-- 실제 이미지 업로드는 다음 단계에서 Supabase Storage + EXIF 제거 후 붙입니다.

create table if not exists public.price_reports (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places(id) on delete cascade,
  menu_name text not null check (char_length(trim(menu_name)) > 0),
  reported_price integer not null check (reported_price > 0),
  visit_date date not null,
  memo text,
  photo_count integer not null default 0 check (photo_count between 0 and 4),
  has_photo_attachment boolean not null default false,
  report_status text not null default 'pending' check (report_status in ('pending', 'approved', 'rejected')),
  reward_points integer not null default 30 check (reward_points >= 0),
  client_created_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists price_reports_place_id_idx on public.price_reports (place_id);
create index if not exists price_reports_status_idx on public.price_reports (report_status);
create index if not exists price_reports_created_at_idx on public.price_reports (created_at desc);

drop trigger if exists set_price_reports_updated_at on public.price_reports;

create trigger set_price_reports_updated_at
before update on public.price_reports
for each row
execute function public.set_updated_at();

alter table public.price_reports enable row level security;

drop policy if exists "price_reports_public_insert" on public.price_reports;
drop policy if exists "price_reports_no_public_read" on public.price_reports;
drop policy if exists "price_reports_authenticated_read" on public.price_reports;
drop policy if exists "price_reports_authenticated_update" on public.price_reports;

-- v0.1 UX 검증용 정책:
-- 로그인 전에도 가격 제보를 받을 수 있게 insert만 허용합니다.
-- 공개 read 정책은 만들지 않아서 anon 사용자는 제보 내역을 조회할 수 없습니다.
create policy "price_reports_public_insert"
on public.price_reports
for insert
to anon, authenticated
with check (
  reported_price > 0
  and photo_count between 1 and 4
  and has_photo_attachment = true
  and report_status = 'pending'
);

-- 베타 운영자/로그인 사용자 검수용 임시 read 정책입니다.
-- 정식 운영에서는 관리자 역할 또는 Edge Function 기반으로 더 좁혀야 합니다.
create policy "price_reports_authenticated_read"
on public.price_reports
for select
to authenticated
using (true);

-- 일반 클라이언트에서 승인/반려 상태를 직접 바꾸지 못하게 update/delete 정책은 만들지 않습니다.

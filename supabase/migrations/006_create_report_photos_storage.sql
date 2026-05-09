-- 006_create_report_photos_storage.sql
-- 가격 제보에 첨부된 영수증/메뉴판 사진을 Supabase Storage에 저장하기 위한 구조입니다.
-- 사진 파일은 Storage bucket에 저장하고, DB에는 파일 경로와 크기 같은 메타데이터만 저장합니다.

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
) values (
  'price-report-photos',
  'price-report-photos',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/heic', 'image/heif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.report_photos (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.price_reports(id) on delete cascade,
  storage_bucket text not null default 'price-report-photos',
  storage_path text not null,
  content_type text not null default 'image/jpeg',
  file_size_bytes integer not null check (file_size_bytes > 0),
  display_order integer not null default 0 check (display_order >= 0),
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);

create index if not exists report_photos_report_id_idx on public.report_photos (report_id);

alter table public.report_photos enable row level security;

drop policy if exists "report_photos_public_insert" on public.report_photos;
drop policy if exists "report_photos_authenticated_read" on public.report_photos;

-- v0.1에서는 로그인 없이도 가격 제보를 받을 수 있으므로 사진 메타데이터 insert도 허용합니다.
-- 공개 조회 정책은 만들지 않습니다. 제보 사진은 검수 전 민감 데이터입니다.
create policy "report_photos_public_insert"
on public.report_photos
for insert
to anon, authenticated
with check (
  storage_bucket = 'price-report-photos'
  and content_type = 'image/jpeg'
  and file_size_bytes > 0
);

-- 베타 운영 검수용 임시 read 정책입니다.
-- 정식 운영에서는 관리자 role 또는 Edge Function으로 좁히는 것을 권장합니다.
create policy "report_photos_authenticated_read"
on public.report_photos
for select
to authenticated
using (true);

drop policy if exists "price_report_photos_public_upload" on storage.objects;
drop policy if exists "price_report_photos_authenticated_read" on storage.objects;

-- Supabase Storage는 RLS 정책이 없으면 업로드를 허용하지 않습니다.
-- 업로드에는 storage.objects INSERT 권한이 필요합니다.
create policy "price_report_photos_public_upload"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'price-report-photos'
  and (storage.foldername(name))[1] = 'price_reports'
);

-- 베타 운영 검수용 임시 read 정책입니다.
-- anon 공개 조회는 허용하지 않습니다.
create policy "price_report_photos_authenticated_read"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'price-report-photos'
  and (storage.foldername(name))[1] = 'price_reports'
);

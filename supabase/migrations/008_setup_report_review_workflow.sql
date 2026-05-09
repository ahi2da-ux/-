-- 008_setup_report_review_workflow.sql
-- 가격 제보 운영 검수 기반을 추가합니다.
-- 목표:
-- 1. 운영자가 승인/반려 사유를 남길 수 있게 합니다.
-- 2. 일반 사용자는 본인 제보의 검수 결과만 읽을 수 있게 유지합니다.
-- 3. 관리자 권한은 app_admins 테이블로 분리해서 앱 사용자가 임의로 올릴 수 없게 합니다.

create table if not exists public.app_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'reviewer' check (role in ('reviewer', 'owner')),
  created_at timestamptz not null default now()
);

alter table public.app_admins enable row level security;

drop policy if exists "app_admins_self_read" on public.app_admins;

-- 관리자는 본인이 관리자 목록에 있는지만 확인할 수 있습니다.
-- 관리자 추가/삭제는 Supabase SQL Editor 또는 서버 권한에서만 처리합니다.
create policy "app_admins_self_read"
on public.app_admins
for select
to authenticated
using (auth.uid() = user_id);

create or replace function public.is_app_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.app_admins
    where app_admins.user_id = auth.uid()
  );
$$;

alter table public.price_reports
add column if not exists reviewed_by uuid references auth.users(id) on delete set null,
add column if not exists reviewed_at timestamptz,
add column if not exists review_note text,
add column if not exists rejection_reason text,
add column if not exists point_granted_at timestamptz;

create index if not exists price_reports_reviewed_by_idx on public.price_reports (reviewed_by);
create index if not exists price_reports_reviewed_at_idx on public.price_reports (reviewed_at desc);

drop policy if exists "price_reports_admin_read" on public.price_reports;
drop policy if exists "price_reports_admin_update" on public.price_reports;

-- 관리자는 모든 제보를 읽을 수 있습니다.
create policy "price_reports_admin_read"
on public.price_reports
for select
to authenticated
using (public.is_app_admin());

-- 관리자는 검수 관련 값을 업데이트할 수 있습니다.
-- 단, 승인/반려 상태와 검수자 기록이 서로 맞도록 최소 조건을 둡니다.
create policy "price_reports_admin_update"
on public.price_reports
for update
to authenticated
using (public.is_app_admin())
with check (
  public.is_app_admin()
  and report_status in ('pending', 'approved', 'rejected')
  and (
    report_status = 'pending'
    or (
      reviewed_by = auth.uid()
      and reviewed_at is not null
    )
  )
  and (
    report_status <> 'rejected'
    or nullif(trim(coalesce(rejection_reason, '')), '') is not null
  )
);

create or replace function public.apply_price_report_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.report_status in ('approved', 'rejected') and old.report_status is distinct from new.report_status then
    new.reviewed_at = coalesce(new.reviewed_at, now());
  end if;

  if new.report_status = 'approved' then
    new.rejection_reason = null;
    new.point_granted_at = coalesce(new.point_granted_at, now());
  end if;

  if new.report_status = 'pending' then
    new.reviewed_by = null;
    new.reviewed_at = null;
    new.review_note = null;
    new.rejection_reason = null;
    new.point_granted_at = null;
  end if;

  return new;
end;
$$;

drop trigger if exists apply_price_report_review on public.price_reports;

create trigger apply_price_report_review
before update on public.price_reports
for each row
execute function public.apply_price_report_review();

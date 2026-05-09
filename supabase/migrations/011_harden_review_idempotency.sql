-- 011_harden_review_idempotency.sql
-- 승인/반려 처리를 멱등성 있게 보강합니다.
-- 핵심 목표:
-- 1. 이미 승인/반려된 제보를 다시 승인/반려하지 못하게 막습니다.
-- 2. 같은 제보 승인으로 포인트가 중복 지급되지 않게 합니다.
-- 3. 운영자 검수 이력을 별도 테이블에 남깁니다.

create table if not exists public.price_report_review_logs (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.price_reports(id) on delete cascade,
  admin_id uuid references auth.users(id) on delete set null,
  action text not null check (action in ('approved', 'rejected')),
  previous_status text not null,
  next_status text not null,
  note text,
  rejection_reason text,
  created_at timestamptz not null default now()
);

create index if not exists price_report_review_logs_report_id_idx
on public.price_report_review_logs (report_id, created_at desc);

create index if not exists price_report_review_logs_admin_id_idx
on public.price_report_review_logs (admin_id, created_at desc);

alter table public.price_report_review_logs enable row level security;

drop policy if exists "review_logs_admin_read" on public.price_report_review_logs;

create policy "review_logs_admin_read"
on public.price_report_review_logs
for select
to authenticated
using (public.is_app_admin());

create or replace function public.approve_price_report(
  target_report_id uuid,
  admin_note text default null
)
returns public.price_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  target_report public.price_reports;
  updated_report public.price_reports;
  trimmed_note text;
begin
  if not public.is_app_admin() then
    raise exception '관리자만 가격 제보를 승인할 수 있습니다.';
  end if;

  select *
  into target_report
  from public.price_reports
  where id = target_report_id
  for update;

  if target_report.id is null then
    raise exception '승인할 가격 제보를 찾지 못했습니다.';
  end if;

  if target_report.report_status <> 'pending' then
    raise exception '이미 검수 완료된 제보는 다시 승인할 수 없습니다. 현재 상태: %', target_report.report_status;
  end if;

  trimmed_note := nullif(trim(coalesce(admin_note, '')), '');

  update public.price_reports
  set
    report_status = 'approved',
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    review_note = trimmed_note,
    rejection_reason = null,
    point_granted_at = now()
  where id = target_report_id
  returning * into updated_report;

  update public.profiles
  set
    point_balance = point_balance + updated_report.reward_points,
    accepted_report_count = accepted_report_count + 1,
    report_count = report_count + 1,
    updated_at = now()
  where id = updated_report.user_id
    and updated_report.user_id is not null;

  insert into public.price_report_review_logs (
    report_id,
    admin_id,
    action,
    previous_status,
    next_status,
    note,
    rejection_reason
  ) values (
    updated_report.id,
    auth.uid(),
    'approved',
    target_report.report_status,
    updated_report.report_status,
    trimmed_note,
    null
  );

  return updated_report;
end;
$$;

create or replace function public.reject_price_report(
  target_report_id uuid,
  reason text,
  admin_note text default null
)
returns public.price_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  target_report public.price_reports;
  updated_report public.price_reports;
  trimmed_reason text;
  trimmed_note text;
begin
  if not public.is_app_admin() then
    raise exception '관리자만 가격 제보를 반려할 수 있습니다.';
  end if;

  select *
  into target_report
  from public.price_reports
  where id = target_report_id
  for update;

  if target_report.id is null then
    raise exception '반려할 가격 제보를 찾지 못했습니다.';
  end if;

  if target_report.report_status <> 'pending' then
    raise exception '이미 검수 완료된 제보는 다시 반려할 수 없습니다. 현재 상태: %', target_report.report_status;
  end if;

  trimmed_reason := nullif(trim(coalesce(reason, '')), '');
  trimmed_note := nullif(trim(coalesce(admin_note, '')), '');

  if trimmed_reason is null then
    raise exception '반려 사유는 반드시 입력해야 합니다.';
  end if;

  update public.price_reports
  set
    report_status = 'rejected',
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    review_note = trimmed_note,
    rejection_reason = trimmed_reason,
    point_granted_at = null
  where id = target_report_id
  returning * into updated_report;

  update public.profiles
  set
    report_count = report_count + 1,
    updated_at = now()
  where id = updated_report.user_id
    and updated_report.user_id is not null;

  insert into public.price_report_review_logs (
    report_id,
    admin_id,
    action,
    previous_status,
    next_status,
    note,
    rejection_reason
  ) values (
    updated_report.id,
    auth.uid(),
    'rejected',
    target_report.report_status,
    updated_report.report_status,
    trimmed_note,
    trimmed_reason
  );

  return updated_report;
end;
$$;

grant execute on function public.approve_price_report(uuid, text) to authenticated;
grant execute on function public.reject_price_report(uuid, text, text) to authenticated;

-- 운영자 검수 이력 확인 예시
-- select
--   report_id,
--   admin_id,
--   action,
--   previous_status,
--   next_status,
--   note,
--   rejection_reason,
--   created_at
-- from public.price_report_review_logs
-- order by created_at desc
-- limit 50;

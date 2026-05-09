-- 013_create_point_transactions.sql
-- 포인트 적립/차감 이력을 별도 장부로 남깁니다.
-- 핵심 목표:
-- 1. profiles.point_balance는 현재 잔액, point_transactions는 상세 이력으로 역할을 나눕니다.
-- 2. 가격 제보 승인 시 어떤 report_id로 몇 포인트가 지급됐는지 추적합니다.
-- 3. 같은 가격 제보로 포인트 이력이 중복 생성되지 않게 unique 제약을 둡니다.

create table if not exists public.point_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  report_id uuid references public.price_reports(id) on delete set null,
  amount integer not null check (amount <> 0),
  transaction_type text not null check (transaction_type in ('report_reward', 'manual_adjustment', 'spend')),
  title text not null,
  description text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists point_transactions_report_reward_unique_idx
on public.point_transactions (report_id)
where transaction_type = 'report_reward' and report_id is not null;

create index if not exists point_transactions_user_created_at_idx
on public.point_transactions (user_id, created_at desc);

create index if not exists point_transactions_report_id_idx
on public.point_transactions (report_id);

alter table public.point_transactions enable row level security;

drop policy if exists "point_transactions_self_read" on public.point_transactions;
drop policy if exists "point_transactions_admin_read" on public.point_transactions;

create policy "point_transactions_self_read"
on public.point_transactions
for select
to authenticated
using (auth.uid() = user_id);

create policy "point_transactions_admin_read"
on public.point_transactions
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

  if updated_report.user_id is not null then
    insert into public.point_transactions (
      user_id,
      report_id,
      amount,
      transaction_type,
      title,
      description,
      created_by
    ) values (
      updated_report.user_id,
      updated_report.id,
      updated_report.reward_points,
      'report_reward',
      '가격 제보 승인 적립',
      concat(updated_report.menu_name, ' ', updated_report.reported_price, '원 제보 승인'),
      auth.uid()
    );
  end if;

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

grant execute on function public.approve_price_report(uuid, text) to authenticated;

-- 기존 승인 데이터 중 point_transactions가 없는 건을 장부에 한 번만 보강합니다.
insert into public.point_transactions (
  user_id,
  report_id,
  amount,
  transaction_type,
  title,
  description,
  created_by,
  created_at
)
select
  user_id,
  id,
  reward_points,
  'report_reward',
  '가격 제보 승인 적립',
  concat(menu_name, ' ', reported_price, '원 제보 승인'),
  reviewed_by,
  coalesce(point_granted_at, reviewed_at, created_at)
from public.price_reports
where report_status = 'approved'
  and user_id is not null
on conflict do nothing;

-- 검증 예시:
-- select user_id, amount, transaction_type, title, created_at
-- from public.point_transactions
-- order by created_at desc
-- limit 20;

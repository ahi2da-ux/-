-- 016_create_price_alert_events.sql
-- 가격 알림 조건이 충족됐을 때 사용자 알림함에 남길 이벤트를 저장합니다.
-- 핵심 목표:
-- 1. APNs 푸시 토큰을 저장하기 전, 개인정보 부담이 낮은 인앱 알림함 구조를 먼저 만듭니다.
-- 2. 가격 제보 승인 시 즐겨찾기 알림 목표가 이하라면 알림 이벤트를 자동 생성합니다.
-- 3. 같은 가격 제보로 같은 사용자에게 중복 알림이 쌓이지 않게 막습니다.

create table if not exists public.price_alert_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  place_id uuid not null references public.places(id) on delete cascade,
  report_id uuid references public.price_reports(id) on delete set null,
  title text not null,
  message text not null,
  target_price integer,
  matched_price integer not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create unique index if not exists price_alert_events_user_report_unique_idx
on public.price_alert_events (user_id, report_id)
where report_id is not null;

create index if not exists price_alert_events_user_created_at_idx
on public.price_alert_events (user_id, created_at desc);

create index if not exists price_alert_events_user_unread_idx
on public.price_alert_events (user_id, is_read, created_at desc);

alter table public.price_alert_events enable row level security;

drop policy if exists "price_alert_events_self_read" on public.price_alert_events;
drop policy if exists "price_alert_events_self_update" on public.price_alert_events;

create policy "price_alert_events_self_read"
on public.price_alert_events
for select
to authenticated
using (auth.uid() = user_id);

-- 사용자는 읽음 여부만 바꾸는 용도로 update합니다.
-- 컬럼 단위 제한은 PostgREST만으로 완벽하지 않으므로, 앱에서는 is_read만 수정하고
-- 운영 단계에서는 mark_price_alert_event_read RPC로 더 좁히는 것을 권장합니다.
create policy "price_alert_events_self_update"
on public.price_alert_events
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

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

  insert into public.price_alert_events (
    user_id,
    place_id,
    report_id,
    title,
    message,
    target_price,
    matched_price
  )
  select
    settings.user_id,
    updated_report.place_id,
    updated_report.id,
    '목표 가격 발견',
    concat(updated_report.menu_name, ' ', updated_report.reported_price, '원 제보가 승인됐어요.'),
    settings.target_price,
    updated_report.reported_price
  from public.price_alert_settings as settings
  where settings.place_id = updated_report.place_id
    and settings.is_enabled = true
    and (
      settings.target_price is null
      or updated_report.reported_price <= settings.target_price
    )
  on conflict do nothing;

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

-- 검증 예시:
-- select user_id, title, message, matched_price, is_read, created_at
-- from public.price_alert_events
-- order by created_at desc
-- limit 20;

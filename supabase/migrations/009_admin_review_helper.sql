-- 009_admin_review_helper.sql
-- 운영자가 가격 제보를 안전하게 승인/반려할 수 있도록 도와주는 RPC 함수를 만듭니다.
-- 이 파일은 008_setup_report_review_workflow.sql 실행 이후에 실행해야 합니다.

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
  updated_report public.price_reports;
begin
  if not public.is_app_admin() then
    raise exception '관리자만 가격 제보를 승인할 수 있습니다.';
  end if;

  update public.price_reports
  set
    report_status = 'approved',
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    review_note = nullif(trim(coalesce(admin_note, '')), ''),
    rejection_reason = null,
    point_granted_at = now()
  where id = target_report_id
  returning * into updated_report;

  if updated_report.id is null then
    raise exception '승인할 가격 제보를 찾지 못했습니다.';
  end if;

  update public.profiles
  set
    point_balance = point_balance + updated_report.reward_points,
    accepted_report_count = accepted_report_count + 1,
    report_count = greatest(report_count, 1),
    updated_at = now()
  where id = updated_report.user_id
    and updated_report.user_id is not null;

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
  trimmed_reason text;
  updated_report public.price_reports;
begin
  if not public.is_app_admin() then
    raise exception '관리자만 가격 제보를 반려할 수 있습니다.';
  end if;

  trimmed_reason := nullif(trim(coalesce(reason, '')), '');

  if trimmed_reason is null then
    raise exception '반려 사유는 반드시 입력해야 합니다.';
  end if;

  update public.price_reports
  set
    report_status = 'rejected',
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    review_note = nullif(trim(coalesce(admin_note, '')), ''),
    rejection_reason = trimmed_reason,
    point_granted_at = null
  where id = target_report_id
  returning * into updated_report;

  if updated_report.id is null then
    raise exception '반려할 가격 제보를 찾지 못했습니다.';
  end if;

  return updated_report;
end;
$$;

grant execute on function public.approve_price_report(uuid, text) to authenticated;
grant execute on function public.reject_price_report(uuid, text, text) to authenticated;

-- 사용 예시 1: 관리자 등록
-- Supabase Dashboard > Authentication > Users에서 운영자 계정의 User UID를 복사한 뒤 실행합니다.
-- insert into public.app_admins (user_id, role)
-- values ('여기에-운영자-user-uid', 'owner')
-- on conflict (user_id) do update set role = excluded.role;

-- 사용 예시 2: 검수 대기 제보 확인
-- select
--   id,
--   user_id,
--   menu_name,
--   reported_price,
--   photo_count,
--   created_at
-- from public.price_reports
-- where report_status = 'pending'
-- order by created_at asc;

-- 사용 예시 3: 가격 제보 승인
-- select public.approve_price_report(
--   '여기에-price_reports-id',
--   '영수증 가격과 메뉴명이 확인되어 승인합니다.'
-- );

-- 사용 예시 4: 가격 제보 반려
-- select public.reject_price_report(
--   '여기에-price_reports-id',
--   '영수증 사진이 흐려 가격 확인이 어렵습니다.',
--   '사용자에게 선명한 사진 재제보를 안내합니다.'
-- );

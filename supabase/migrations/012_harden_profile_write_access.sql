-- 012_harden_profile_write_access.sql
-- 프로필 쓰기 권한을 안전하게 줄입니다.
-- 핵심 목표:
-- 1. 앱 사용자가 point_balance, report_count, accepted_report_count를 직접 수정하지 못하게 막습니다.
-- 2. 사용자가 바꿀 수 있는 값은 display_name(닉네임)으로 제한합니다.
-- 3. 포인트와 제보 통계는 운영자 검수 RPC(approve/reject)만 변경하도록 유지합니다.

drop policy if exists "profiles_self_update" on public.profiles;

create or replace function public.update_my_profile_display_name(new_display_name text)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  trimmed_name text;
  updated_profile public.profiles;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 프로필을 수정할 수 있습니다.';
  end if;

  trimmed_name := nullif(trim(coalesce(new_display_name, '')), '');

  if trimmed_name is null then
    raise exception '닉네임을 입력해주세요.';
  end if;

  if char_length(trimmed_name) < 2 or char_length(trimmed_name) > 20 then
    raise exception '닉네임은 2자 이상 20자 이하로 입력해주세요.';
  end if;

  update public.profiles
  set
    display_name = trimmed_name,
    updated_at = now()
  where id = auth.uid()
  returning * into updated_profile;

  if updated_profile.id is null then
    raise exception '수정할 프로필을 찾지 못했습니다.';
  end if;

  return updated_profile;
end;
$$;

grant execute on function public.update_my_profile_display_name(text) to authenticated;

-- 검증 예시:
-- 1. 로그인 사용자 REST update로 point_balance 수정 시도
--    -> RLS update 정책이 없으므로 차단되어야 합니다.
-- 2. 로그인 사용자 RPC 호출
--    select public.update_my_profile_display_name('짠테커');
--    -> display_name만 정상 변경되어야 합니다.

-- 017_harden_price_alert_event_read_rpc.sql
-- 가격 알림 읽음 처리를 RPC 함수로 좁힙니다.
-- 핵심 목표:
-- 1. 사용자가 price_alert_events 테이블을 직접 update하지 못하게 막습니다.
-- 2. 사용자는 본인 알림 1건의 is_read 값을 true로 바꾸는 함수만 호출할 수 있습니다.
-- 3. title, message, matched_price 같은 운영 데이터는 클라이언트가 수정할 수 없게 보호합니다.

drop policy if exists "price_alert_events_self_update" on public.price_alert_events;

create or replace function public.mark_price_alert_event_read(
  target_event_id uuid
)
returns public.price_alert_events
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_event public.price_alert_events;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 알림을 읽음 처리할 수 있습니다.';
  end if;

  update public.price_alert_events
  set is_read = true
  where id = target_event_id
    and user_id = auth.uid()
  returning * into updated_event;

  if updated_event.id is null then
    raise exception '읽음 처리할 알림을 찾지 못했습니다.';
  end if;

  return updated_event;
end;
$$;

grant execute on function public.mark_price_alert_event_read(uuid) to authenticated;

-- 검증 예시:
-- 로그인 사용자 토큰으로 아래 RPC를 호출하면 본인 알림만 읽음 처리됩니다.
-- select public.mark_price_alert_event_read('여기에-price_alert_events-id');

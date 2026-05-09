-- 015_create_price_alert_settings.sql
-- 즐겨찾기 장소별 가격 알림 설정을 저장합니다.
-- 핵심 목표:
-- 1. 사용자가 관심 장소의 가격 변동 알림을 켜고 끌 수 있게 합니다.
-- 2. 목표 가격(target_price)을 저장해 "이 가격 이하가 되면 알려줘" 구조를 준비합니다.
-- 3. 실제 푸시 발송은 v2에서 Edge Function/APNs와 연결하고, 지금은 안전한 데이터 기반을 만듭니다.

create table if not exists public.price_alert_settings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  place_id uuid not null references public.places(id) on delete cascade,
  is_enabled boolean not null default true,
  target_price integer check (target_price is null or target_price > 0),
  last_notified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, place_id)
);

drop trigger if exists set_price_alert_settings_updated_at on public.price_alert_settings;

create trigger set_price_alert_settings_updated_at
before update on public.price_alert_settings
for each row
execute function public.set_updated_at();

create index if not exists price_alert_settings_user_enabled_idx
on public.price_alert_settings (user_id, is_enabled, updated_at desc);

create index if not exists price_alert_settings_place_id_idx
on public.price_alert_settings (place_id);

alter table public.price_alert_settings enable row level security;

drop policy if exists "price_alert_settings_self_read" on public.price_alert_settings;
drop policy if exists "price_alert_settings_self_insert" on public.price_alert_settings;
drop policy if exists "price_alert_settings_self_update" on public.price_alert_settings;
drop policy if exists "price_alert_settings_self_delete" on public.price_alert_settings;

create policy "price_alert_settings_self_read"
on public.price_alert_settings
for select
to authenticated
using (auth.uid() = user_id);

create policy "price_alert_settings_self_insert"
on public.price_alert_settings
for insert
to authenticated
with check (auth.uid() = user_id);

create policy "price_alert_settings_self_update"
on public.price_alert_settings
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy "price_alert_settings_self_delete"
on public.price_alert_settings
for delete
to authenticated
using (auth.uid() = user_id);

-- 즐겨찾기가 이미 있는 사용자는 기본 알림 설정을 자동으로 만들어 둡니다.
insert into public.price_alert_settings (user_id, place_id, is_enabled)
select user_id, place_id, true
from public.favorite_places
on conflict (user_id, place_id) do nothing;

-- 검증 예시:
-- select id, user_id, place_id, is_enabled, target_price
-- from public.price_alert_settings
-- order by updated_at desc
-- limit 20;

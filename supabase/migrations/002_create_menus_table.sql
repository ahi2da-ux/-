-- 002_create_menus_table.sql
-- 장소별 메뉴와 가격 정보를 저장하는 테이블입니다.
-- 하나의 places row가 여러 개의 menus row를 가질 수 있습니다.

create table if not exists public.menus (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references public.places(id) on delete cascade,
  name text not null,
  description text,
  price integer not null check (price >= 0),
  is_verified boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (place_id, name)
);

create index if not exists menus_place_id_idx on public.menus (place_id);
create index if not exists menus_price_idx on public.menus (price);

drop trigger if exists set_menus_updated_at on public.menus;

create trigger set_menus_updated_at
before update on public.menus
for each row
execute function public.set_updated_at();

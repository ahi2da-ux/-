-- 001_create_places_table.sql
-- 짠테크맵 장소 기본 정보를 저장하는 테이블입니다.
-- 앱의 Place.mock 데이터를 Supabase DB로 옮기기 위한 1단계 구조입니다.

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.places (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null check (category in ('food', 'cafe', 'hair', 'lodging')),
  kind text not null,
  icon text not null,
  distance_text text,
  distance_text_short text,
  base_price integer not null check (base_price >= 0),
  rating numeric(2,1) not null default 0 check (rating >= 0 and rating <= 5),
  review_count integer not null default 0 check (review_count >= 0),
  is_verified boolean not null default false,
  verify_text text,
  is_featured boolean not null default false,
  trust_score integer not null default 0 check (trust_score >= 0 and trust_score <= 100),
  receipt_count integer not null default 0 check (receipt_count >= 0),
  updated_text text,
  open_time text,
  status_text text not null default '확인필요',
  address text not null,
  station_note text,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  tip text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists places_category_idx on public.places (category);
create index if not exists places_base_price_idx on public.places (base_price);
create index if not exists places_location_idx on public.places (latitude, longitude);

drop trigger if exists set_places_updated_at on public.places;

create trigger set_places_updated_at
before update on public.places
for each row
execute function public.set_updated_at();

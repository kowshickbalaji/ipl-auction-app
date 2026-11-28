-- IPL Auction App - Supabase Schema & Realtime Setup
-- Run this in the Supabase SQL Editor

-- 1. Rooms table
create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  admin_pin text not null default '1234',
  status text not null default 'waiting' check (status in ('waiting', 'live', 'paused', 'completed')),
  current_player_id uuid,
  current_bid numeric(10, 2) not null default 0,
  highest_bidder_team_id uuid,
  timer_seconds integer not null default 20,
  timer_ends_at timestamptz,
  bid_increment numeric(10, 2) not null default 0.25,
  created_at timestamptz not null default now()
);

-- 2. Teams table
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  name text not null,
  short_name text not null,
  color text not null default '#3b82f6',
  purse_total numeric(10, 2) not null default 120.00,
  purse_remaining numeric(10, 2) not null default 120.00,
  max_squad_size integer not null default 25,
  max_overseas integer not null default 8,
  owner_name text,
  created_at timestamptz not null default now()
);

-- 3. Players table
create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  name text not null,
  role text not null check (role in ('Batsman', 'Bowler', 'All-Rounder', 'Wicketkeeper')),
  country text not null default 'India',
  is_overseas boolean not null default false,
  base_price numeric(10, 2) not null default 2.00,
  sold_price numeric(10, 2),
  status text not null default 'upcoming' check (status in ('upcoming', 'live', 'sold', 'unsold')),
  sold_to_team_id uuid references public.teams(id) on delete set null,
  set_name text not null default 'Marquee',
  stats jsonb not null default '{}'::jsonb,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- 4. Bids table
create table if not exists public.bids (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  amount numeric(10, 2) not null,
  bidder_name text,
  created_at timestamptz not null default now()
);

-- Indexes for fast room queries
create index if not exists idx_teams_room_id on public.teams(room_id);
create index if not exists idx_players_room_id on public.players(room_id);
create index if not exists idx_bids_room_id on public.bids(room_id);
create index if not exists idx_bids_player_id on public.bids(player_id);

-- 5. Enable Row Level Security & Permissive Room Policies
alter table public.rooms enable row level security;
alter table public.teams enable row level security;
alter table public.players enable row level security;
alter table public.bids enable row level security;

drop policy if exists "Allow all on rooms" on public.rooms;
create policy "Allow all on rooms" on public.rooms for all using (true) with check (true);

drop policy if exists "Allow all on teams" on public.teams;
create policy "Allow all on teams" on public.teams for all using (true) with check (true);

drop policy if exists "Allow all on players" on public.players;
create policy "Allow all on players" on public.players for all using (true) with check (true);

drop policy if exists "Allow all on bids" on public.bids;
create policy "Allow all on bids" on public.bids for all using (true) with check (true);

-- 6. Atomic Bid RPC (prevents race conditions & validates purse)
create or replace function public.place_bid(
  p_room_id uuid,
  p_player_id uuid,
  p_team_id uuid,
  p_amount numeric,
  p_bidder_name text default null
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_room record;
  v_player record;
  v_team record;
  v_min_required numeric;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Room not found');
  end if;
  if v_room.status <> 'live' then
    return jsonb_build_object('ok', false, 'error', 'Auction is not live');
  end if;
  if v_room.current_player_id <> p_player_id then
    return jsonb_build_object('ok', false, 'error', 'Player is no longer on the block');
  end if;
  if v_room.highest_bidder_team_id = p_team_id then
    return jsonb_build_object('ok', false, 'error', 'Your team already holds the highest bid');
  end if;

  select * into v_player from public.players where id = p_player_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Player not found');
  end if;

  if v_room.highest_bidder_team_id is null then
    v_min_required := v_player.base_price;
  else
    v_min_required := v_room.current_bid + v_room.bid_increment;
  end if;

  if p_amount < v_min_required then
    return jsonb_build_object('ok', false, 'error', 'Bid must be at least ' || v_min_required || ' Cr');
  end if;

  select * into v_team from public.teams where id = p_team_id and room_id = p_room_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Team not found');
  end if;
  if v_team.purse_remaining < p_amount then
    return jsonb_build_object('ok', false, 'error', 'Insufficient purse remaining');
  end if;

  insert into public.bids(room_id, player_id, team_id, amount, bidder_name)
  values (p_room_id, p_player_id, p_team_id, p_amount, p_bidder_name);

  update public.rooms
  set current_bid = p_amount,
      highest_bidder_team_id = p_team_id,
      timer_ends_at = now() + make_interval(secs => greatest(v_room.timer_seconds, 10))
  where id = p_room_id;

  return jsonb_build_object('ok', true, 'amount', p_amount);
end;
$$;

-- 7. Atomic Hammer RPC (Sell or mark Unsold)
create or replace function public.hammer_player(
  p_room_id uuid,
  p_action text
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_room record;
  v_player_id uuid;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Room not found');
  end if;

  v_player_id := v_room.current_player_id;
  if v_player_id is null then
    return jsonb_build_object('ok', false, 'error', 'No active player on the block');
  end if;

  if p_action = 'sold' and v_room.highest_bidder_team_id is not null then
    update public.players
    set status = 'sold',
        sold_price = v_room.current_bid,
        sold_to_team_id = v_room.highest_bidder_team_id
    where id = v_player_id;

    update public.teams
    set purse_remaining = greatest(0, purse_remaining - v_room.current_bid)
    where id = v_room.highest_bidder_team_id;
  else
    update public.players
    set status = 'unsold',
        sold_price = null,
        sold_to_team_id = null
    where id = v_player_id;
  end if;

  update public.rooms
  set status = 'waiting',
      current_player_id = null,
      current_bid = 0,
      highest_bidder_team_id = null,
      timer_ends_at = null
  where id = p_room_id;

  return jsonb_build_object('ok', true, 'action', p_action);
end;
$$;

-- 8. Enable Realtime for all auction tables
alter publication supabase_realtime add table public.rooms;
alter publication supabase_realtime add table public.teams;
alter publication supabase_realtime add table public.players;
alter publication supabase_realtime add table public.bids;

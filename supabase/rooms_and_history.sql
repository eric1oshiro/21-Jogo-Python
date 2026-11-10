-- Referência do esquema aplicado no projeto Supabase "21 game".
-- Salas e resultados são escritos pelo servidor. Clientes autenticados podem
-- ler dados apenas das salas em que participam.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated;

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  code varchar(6) not null unique,
  host_user_id uuid not null references public.profiles (id) on delete restrict,
  status text not null default 'waiting'
    check (status in ('waiting', 'playing', 'finished')),
  max_players smallint not null default 4
    check (max_players between 2 and 4),
  duration_seconds smallint not null default 600
    check (duration_seconds between 60 and 600),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  ends_at timestamptz,
  finished_at timestamptz,
  winner_user_id uuid references public.profiles (id) on delete set null,
  constraint rooms_status_timestamps_check check (
    (status = 'waiting' and started_at is null and ends_at is null and finished_at is null)
    or
    (status = 'playing' and started_at is not null and ends_at > started_at and finished_at is null)
    or
    (status = 'finished' and started_at is not null and ends_at is not null and finished_at >= started_at)
  ),
  constraint rooms_winner_only_after_finish check (
    status = 'finished' or winner_user_id is null
  ),
  constraint rooms_code_format check (code ~ '^[A-Z0-9]{6}$')
);

create index rooms_status_created_at_idx on public.rooms (status, created_at desc);
create index rooms_host_user_id_idx on public.rooms (host_user_id);
create index rooms_winner_user_id_idx on public.rooms (winner_user_id);

create table public.room_players (
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete restrict,
  seat_number smallint not null check (seat_number between 1 and 4),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  starting_balance numeric(12, 2) not null default 100.00 check (starting_balance >= 0),
  current_balance numeric(12, 2) not null default 100.00 check (current_balance >= 0),
  current_bet numeric(12, 2) not null default 0 check (current_bet >= 0),
  total_wagered numeric(12, 2) not null default 0 check (total_wagered >= 0),
  primary key (room_id, user_id),
  unique (room_id, seat_number),
  constraint room_players_left_at_check check (left_at is null or left_at >= joined_at)
);

create index room_players_user_id_idx on public.room_players (user_id);
create index room_players_room_user_idx on public.room_players (room_id, user_id);

create table public.matches (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null unique references public.rooms (id) on delete restrict,
  winner_user_id uuid references public.profiles (id) on delete set null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint matches_time_order_check check (ended_at >= started_at)
);

create index matches_ended_at_idx on public.matches (ended_at desc);
create index matches_winner_user_id_idx on public.matches (winner_user_id);

create table public.match_players (
  match_id uuid not null references public.matches (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete restrict,
  starting_balance numeric(12, 2) not null check (starting_balance >= 0),
  final_balance numeric(12, 2) not null check (final_balance >= 0),
  total_wagered numeric(12, 2) not null default 0 check (total_wagered >= 0),
  final_rank smallint not null check (final_rank between 1 and 4),
  outcome text not null check (outcome in ('win', 'loss', 'tie')),
  result_at timestamptz not null,
  primary key (match_id, user_id)
);

create index match_players_user_match_idx on public.match_players (user_id, match_id);
create index match_players_match_rank_idx on public.match_players (match_id, final_rank);

create function private.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.room_players as rp
    where rp.room_id = p_room_id
      and rp.user_id = (select auth.uid())
  );
$$;

revoke all on function private.is_room_member(uuid) from public, anon, authenticated;
grant execute on function private.is_room_member(uuid) to authenticated;

alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.matches enable row level security;
alter table public.match_players enable row level security;

revoke all on table public.rooms, public.room_players, public.matches, public.match_players
  from anon, authenticated;
grant select on table public.rooms, public.room_players, public.matches, public.match_players
  to authenticated;
grant all on table public.rooms, public.room_players, public.matches, public.match_players
  to service_role;

create policy "Room hosts and members can read rooms"
  on public.rooms for select to authenticated
  using (
    (select auth.uid()) = host_user_id
    or (select private.is_room_member(id))
  );

create policy "Room members can read live player balances and bets"
  on public.room_players for select to authenticated
  using ((select private.is_room_member(room_id)));

create policy "Room members can read match history"
  on public.matches for select to authenticated
  using ((select private.is_room_member(room_id)));

create policy "Room members can read match participant results"
  on public.match_players for select to authenticated
  using (
    exists (
      select 1
      from public.matches as m
      where m.id = match_players.match_id
        and (select private.is_room_member(m.room_id))
    )
  );

create view public.head_to_head_stats
with (security_invoker = true)
as
select
  mine.user_id as player_id,
  opponent.user_id as opponent_id,
  count(*)::bigint as matches_played,
  count(*) filter (where mine.final_rank < opponent.final_rank)::bigint as wins,
  count(*) filter (where mine.final_rank > opponent.final_rank)::bigint as losses,
  count(*) filter (where mine.final_rank = opponent.final_rank)::bigint as draws,
  round(avg(extract(epoch from (mine.result_at - m.started_at)))::numeric, 1)
    as average_seconds_to_result
from public.match_players as mine
join public.match_players as opponent
  on opponent.match_id = mine.match_id
 and opponent.user_id <> mine.user_id
join public.matches as m
  on m.id = mine.match_id
where mine.user_id = (select auth.uid())
group by mine.user_id, opponent.user_id;

revoke all on table public.head_to_head_stats from anon, authenticated;
grant select on table public.head_to_head_stats to authenticated;

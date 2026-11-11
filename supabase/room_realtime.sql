-- Complementa rooms_and_history.sql com lobby, segurança e Supabase Realtime.
-- Já aplicado ao projeto Supabase hgeojoctlcdrebxtjsem.

alter table public.room_players
  add column if not exists last_seen_at timestamptz not null default now();

alter table public.room_players drop constraint if exists room_players_room_id_seat_number_key;
create unique index if not exists room_players_active_seat_key
  on public.room_players (room_id, seat_number)
  where left_at is null;

create or replace function private.is_active_room_member(p_room_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id
      and rp.user_id = (select auth.uid())
      and rp.left_at is null
  );
$$;
revoke all on function private.is_active_room_member(uuid) from public, anon, authenticated;
grant execute on function private.is_active_room_member(uuid) to authenticated;

drop policy if exists "Room members can read live player balances and bets" on public.room_players;
create policy "Active room members can read live player balances and bets"
  on public.room_players for select to authenticated
  using ((select private.is_active_room_member(room_id)));

create or replace function public.list_open_rooms()
returns table (
  id uuid, code varchar(6), host_nickname text, player_count bigint,
  max_players smallint, duration_seconds smallint, created_at timestamptz
)
language plpgsql security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then raise exception 'É necessário entrar na conta.'; end if;
  update public.room_players rp
  set left_at = now(), current_bet = 0
  from public.rooms r
  where rp.room_id = r.id and r.status = 'waiting'
    and rp.left_at is null and rp.last_seen_at < now() - interval '2 minutes';
  update public.rooms r
  set host_user_id = (
    select rp.user_id from public.room_players rp
    where rp.room_id = r.id and rp.left_at is null
    order by rp.joined_at, rp.seat_number limit 1
  )
  where r.status = 'waiting'
    and not exists (select 1 from public.room_players rp where rp.room_id = r.id and rp.user_id = r.host_user_id and rp.left_at is null)
    and exists (select 1 from public.room_players rp where rp.room_id = r.id and rp.left_at is null);
  return query
  select r.id, r.code, p.nickname, count(rp.user_id)::bigint,
         r.max_players, r.duration_seconds, r.created_at
  from public.rooms r
  join public.profiles p on p.id = r.host_user_id
  left join public.room_players rp on rp.room_id = r.id and rp.left_at is null
  where r.status = 'waiting'
  group by r.id, r.code, p.nickname, r.max_players, r.duration_seconds, r.created_at
  having count(rp.user_id) < r.max_players
  order by r.created_at desc;
end;
$$;

create or replace function public.create_room(p_max_players smallint default 4, p_duration_seconds smallint default 600)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_room_id uuid;
  v_code varchar(6);
begin
  if v_user_id is null then raise exception 'É necessário entrar na conta.'; end if;
  if p_max_players < 2 or p_max_players > 4 then raise exception 'A sala deve aceitar de 2 a 4 jogadores.'; end if;
  if p_duration_seconds < 60 or p_duration_seconds > 600 then raise exception 'A duração deve ficar entre 1 e 10 minutos.'; end if;
  if not exists (select 1 from public.profiles p where p.id = v_user_id) then raise exception 'Crie seu perfil antes de abrir uma sala.'; end if;
  loop
    v_code := upper(lpad(to_hex(floor(random() * 16777216)::integer), 6, '0'));
    begin
      insert into public.rooms (code, host_user_id, max_players, duration_seconds)
      values (v_code, v_user_id, p_max_players, p_duration_seconds)
      returning id into v_room_id;
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  insert into public.room_players (room_id, user_id, seat_number)
  values (v_room_id, v_user_id, 1);
  return v_room_id;
end;
$$;

create or replace function public.join_room(p_room_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_room public.rooms%rowtype;
  v_seat smallint;
begin
  if v_user_id is null then raise exception 'É necessário entrar na conta.'; end if;
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found or v_room.status <> 'waiting' then raise exception 'Esta sala não está mais disponível.'; end if;
  update public.room_players set left_at = now(), current_bet = 0
  where room_id = p_room_id and left_at is null and last_seen_at < now() - interval '2 minutes';
  if exists (select 1 from public.room_players where room_id = p_room_id and user_id = v_user_id and left_at is null) then
    update public.room_players set last_seen_at = now() where room_id = p_room_id and user_id = v_user_id;
    update public.rooms r set host_user_id = v_user_id
    where r.id = p_room_id and not exists (
      select 1 from public.room_players rp where rp.room_id = p_room_id and rp.user_id = r.host_user_id and rp.left_at is null
    );
    return;
  end if;
  select seats.seat::smallint into v_seat
  from generate_series(1, v_room.max_players) seats(seat)
  where not exists (
    select 1 from public.room_players rp
    where rp.room_id = p_room_id and rp.seat_number = seats.seat and rp.left_at is null
  ) order by seats.seat limit 1;
  if v_seat is null then raise exception 'A sala está cheia.'; end if;
  update public.room_players
  set seat_number = v_seat, joined_at = now(), left_at = null, last_seen_at = now(),
      starting_balance = 100, current_balance = 100, current_bet = 0, total_wagered = 0
  where room_id = p_room_id and user_id = v_user_id;
  if not found then
    insert into public.room_players (room_id, user_id, seat_number, last_seen_at)
    values (p_room_id, v_user_id, v_seat, now());
  end if;
  update public.rooms r set host_user_id = v_user_id
  where r.id = p_room_id and not exists (
    select 1 from public.room_players rp where rp.room_id = p_room_id and rp.user_id = r.host_user_id and rp.left_at is null
  );
end;
$$;

create or replace function public.leave_room(p_room_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_host_id uuid;
  v_next_host uuid;
begin
  if v_user_id is null then raise exception 'É necessário entrar na conta.'; end if;
  select host_user_id into v_host_id from public.rooms where id = p_room_id and status = 'waiting' for update;
  if not found then raise exception 'A sala não está mais aguardando jogadores.'; end if;
  update public.room_players set left_at = now(), current_bet = 0
  where room_id = p_room_id and user_id = v_user_id and left_at is null;
  if v_host_id = v_user_id then
    select user_id into v_next_host from public.room_players
    where room_id = p_room_id and left_at is null order by joined_at, seat_number limit 1;
    if v_next_host is null then delete from public.rooms where id = p_room_id;
    else update public.rooms set host_user_id = v_next_host where id = p_room_id;
    end if;
  end if;
end;
$$;

create or replace function public.touch_room(p_room_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null then raise exception 'É necessário entrar na conta.'; end if;
  update public.room_players set last_seen_at = now()
  where room_id = p_room_id and user_id = v_user_id and left_at is null;
  if not found then raise exception 'Você não está mais nesta sala.'; end if;
end;
$$;

revoke all on function public.list_open_rooms() from public, anon;
revoke all on function public.create_room(smallint, smallint) from public, anon;
revoke all on function public.join_room(uuid) from public, anon;
revoke all on function public.leave_room(uuid) from public, anon;
revoke all on function public.touch_room(uuid) from public, anon;
grant execute on function public.list_open_rooms() to authenticated;
grant execute on function public.create_room(smallint, smallint) to authenticated;
grant execute on function public.join_room(uuid) to authenticated;
grant execute on function public.leave_room(uuid) to authenticated;
grant execute on function public.touch_room(uuid) to authenticated;

-- Permite sair de salas encerradas sem alterar os resultados históricos.
create or replace function private.leave_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_host_id uuid;
  v_room_status text;
  v_next_host uuid;
begin
  if v_user_id is null then raise exception 'É necessário entrar na conta.'; end if;
  select host_user_id, status into v_host_id, v_room_status
  from public.rooms where id = p_room_id and status in ('waiting','finished') for update;
  if not found then raise exception 'Não é possível sair durante uma partida em andamento.'; end if;
  update public.room_players set left_at = now(), current_bet = 0
  where room_id = p_room_id and user_id = v_user_id and left_at is null;
  if not found then raise exception 'Você não está nesta sala.'; end if;
  if v_room_status = 'finished' then return; end if;
  if v_host_id = v_user_id then
    select user_id into v_next_host from public.room_players
    where room_id = p_room_id and left_at is null order by joined_at, seat_number limit 1;
    if v_next_host is null then delete from public.rooms where id = p_room_id;
    else update public.rooms set host_user_id = v_next_host where id = p_room_id;
    end if;
  end if;
end;
$$;

drop policy if exists "authenticated room members can read and write private room topics" on realtime.messages;
drop policy if exists "authenticated users can read and write lobby broadcasts" on realtime.messages;
drop policy if exists "authenticated room members can receive private room events" on realtime.messages;
drop policy if exists "authenticated room members can send private room events" on realtime.messages;
drop policy if exists "authenticated users can receive lobby broadcasts" on realtime.messages;
drop policy if exists "authenticated users can send lobby broadcasts" on realtime.messages;
create policy "authenticated room members can receive private room events"
on realtime.messages for select to authenticated
using (
  extension in ('broadcast', 'presence')
  and case when (select realtime.topic()) ~ '^room:[0-9a-fA-F-]{36}$'
    then (select private.is_active_room_member(substring((select realtime.topic()) from 6)::uuid))
    else false end
);
create policy "authenticated room members can send private room events"
on realtime.messages for insert to authenticated
with check (
  extension in ('broadcast', 'presence')
  and case when (select realtime.topic()) ~ '^room:[0-9a-fA-F-]{36}$'
    then (select private.is_active_room_member(substring((select realtime.topic()) from 6)::uuid))
    else false end
);
create policy "authenticated users can receive lobby broadcasts"
on realtime.messages for select to authenticated
using ((select realtime.topic()) = 'lobby' and extension = 'broadcast');
create policy "authenticated users can send lobby broadcasts"
on realtime.messages for insert to authenticated
with check ((select realtime.topic()) = 'lobby' and extension = 'broadcast');

alter publication supabase_realtime add table public.rooms;
alter publication supabase_realtime add table public.room_players;

-- A lógica com privilégios elevados mora fora dos schemas expostos pela API.
alter function public.list_open_rooms() set schema private;
alter function public.create_room(smallint, smallint) set schema private;
alter function public.join_room(uuid) set schema private;
alter function public.leave_room(uuid) set schema private;
alter function public.touch_room(uuid) set schema private;

revoke all on function private.list_open_rooms() from public, anon;
revoke all on function private.create_room(smallint, smallint) from public, anon;
revoke all on function private.join_room(uuid) from public, anon;
revoke all on function private.leave_room(uuid) from public, anon;
revoke all on function private.touch_room(uuid) from public, anon;
grant execute on function private.list_open_rooms() to authenticated;
grant execute on function private.create_room(smallint, smallint) to authenticated;
grant execute on function private.join_room(uuid) to authenticated;
grant execute on function private.leave_room(uuid) to authenticated;
grant execute on function private.touch_room(uuid) to authenticated;

create function public.list_open_rooms()
returns table (
  id uuid, code varchar(6), host_nickname text, player_count bigint,
  max_players smallint, duration_seconds smallint, created_at timestamptz
)
language sql security invoker
set search_path = ''
as $$ select * from private.list_open_rooms(); $$;

create function public.create_room(p_max_players smallint default 4, p_duration_seconds smallint default 600)
returns uuid language sql security invoker
set search_path = ''
as $$ select private.create_room(p_max_players, p_duration_seconds); $$;

create function public.join_room(p_room_id uuid)
returns void language sql security invoker
set search_path = ''
as $$ select private.join_room(p_room_id); $$;

create function public.leave_room(p_room_id uuid)
returns void language sql security invoker
set search_path = ''
as $$ select private.leave_room(p_room_id); $$;

create function public.touch_room(p_room_id uuid)
returns void language sql security invoker
set search_path = ''
as $$ select private.touch_room(p_room_id); $$;

revoke all on function public.list_open_rooms() from public, anon;
revoke all on function public.create_room(smallint, smallint) from public, anon;
revoke all on function public.join_room(uuid) from public, anon;
revoke all on function public.leave_room(uuid) from public, anon;
revoke all on function public.touch_room(uuid) from public, anon;
grant execute on function public.list_open_rooms() to authenticated;
grant execute on function public.create_room(smallint, smallint) to authenticated;
grant execute on function public.join_room(uuid) to authenticated;
grant execute on function public.leave_room(uuid) to authenticated;
grant execute on function public.touch_room(uuid) to authenticated;

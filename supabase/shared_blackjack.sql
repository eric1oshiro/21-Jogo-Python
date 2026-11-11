-- Motor da partida compartilhada. Aplicado no projeto hgeojoctlcdrebxtjsem.
-- RPCs públicas SECURITY INVOKER chamam implementação privilegiada no schema private.

create table public.room_match_state (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  status text not null check (status in ('betting','playing','round_complete','finished')),
  started_at timestamptz not null,
  ends_at timestamptz not null,
  round_number integer not null default 1 check (round_number >= 1),
  deck jsonb not null default '[]'::jsonb,
  dealer_hand jsonb not null default '[]'::jsonb,
  current_turn_user_id uuid references public.profiles(id) on delete set null,
  turn_started_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint room_match_state_time_check check (ends_at > started_at)
);
create index room_match_state_current_turn_user_idx
  on public.room_match_state(current_turn_user_id);

create table public.room_round_players (
  room_id uuid not null references public.rooms(id) on delete cascade,
  round_number integer not null,
  user_id uuid not null references public.profiles(id) on delete restrict,
  bet numeric(12,2) not null default 0 check (bet >= 0),
  hand jsonb not null default '[]'::jsonb,
  status text not null default 'waiting_bet'
    check (status in ('waiting_bet','bet_placed','playing','stood','bust','settled')),
  payout numeric(12,2) not null default 0 check (payout >= 0),
  updated_at timestamptz not null default now(),
  primary key (room_id, round_number, user_id)
);
create index room_round_players_turn_idx
  on public.room_round_players(room_id, round_number, status, user_id);
create index room_round_players_user_id_idx
  on public.room_round_players(user_id);

alter table public.room_match_state enable row level security;
alter table public.room_round_players enable row level security;
revoke all on table public.room_match_state, public.room_round_players from anon, authenticated;
grant select on table public.room_round_players to authenticated;
grant all on table public.room_match_state, public.room_round_players to service_role;
create policy "Match state is available only through the filtered RPC"
  on public.room_match_state for select to authenticated using (false);
create policy "Active room members can read shared round hands"
  on public.room_round_players for select to authenticated
  using ((select private.is_active_room_member(room_id)));
alter publication supabase_realtime add table public.room_round_players;

create function private.hand_score(p_hand jsonb)
returns integer language plpgsql immutable set search_path = ''
as $$
declare
  v_card jsonb;
  v_value text;
  v_total integer := 0;
  v_aces integer := 0;
begin
  for v_card in select value from jsonb_array_elements(coalesce(p_hand, '[]'::jsonb)) loop
    v_value := v_card ->> 'value';
    if v_value = 'A' then v_total := v_total + 11; v_aces := v_aces + 1;
    elsif v_value in ('J','Q','K') then v_total := v_total + 10;
    else v_total := v_total + v_value::integer;
    end if;
  end loop;
  while v_total > 21 and v_aces > 0 loop v_total := v_total - 10; v_aces := v_aces - 1; end loop;
  return v_total;
end;
$$;

create function private.draw_card(p_deck jsonb, out card jsonb, out remaining_deck jsonb)
returns record language plpgsql set search_path = ''
as $$
begin
  if jsonb_array_length(coalesce(p_deck, '[]'::jsonb)) = 0 then raise exception 'O baralho da rodada acabou.'; end if;
  card := p_deck -> 0;
  remaining_deck := p_deck - 0;
end;
$$;

create function private.settle_shared_round(p_room_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_state public.room_match_state%rowtype;
  v_deck jsonb;
  v_dealer jsonb;
  v_card jsonb;
  v_rest jsonb;
  v_dealer_total integer;
  v_player record;
  v_player_total integer;
  v_player_natural boolean;
  v_dealer_natural boolean;
  v_payout numeric(12,2);
begin
  select * into v_state from public.room_match_state where room_id = p_room_id for update;
  if not found or v_state.status not in ('playing','betting') then return; end if;
  v_deck := v_state.deck; v_dealer := v_state.dealer_hand;
  v_dealer_total := private.hand_score(v_dealer);
  while v_dealer_total < 17 loop
    select d.card, d.remaining_deck into v_card, v_rest from private.draw_card(v_deck) as d;
    v_dealer := v_dealer || jsonb_build_array(v_card);
    v_deck := v_rest; v_dealer_total := private.hand_score(v_dealer);
  end loop;
  v_dealer_natural := jsonb_array_length(v_dealer) = 2 and v_dealer_total = 21;
  update public.room_match_state set deck = v_deck, dealer_hand = v_dealer,
    status = 'round_complete', current_turn_user_id = null, turn_started_at = null, updated_at = now()
  where room_id = p_room_id;
  for v_player in select * from public.room_round_players
    where room_id = p_room_id and round_number = v_state.round_number and status in ('stood','bust') loop
    v_player_total := private.hand_score(v_player.hand);
    v_player_natural := jsonb_array_length(v_player.hand) = 2 and v_player_total = 21;
    if v_player.status = 'bust' then v_payout := 0;
    elsif v_player_natural and v_dealer_natural then v_payout := v_player.bet;
    elsif v_player_natural then v_payout := v_player.bet * 2.5;
    elsif v_dealer_natural then v_payout := 0;
    elsif v_dealer_total > 21 or v_player_total > v_dealer_total then v_payout := v_player.bet * 2;
    elsif v_player_total = v_dealer_total then v_payout := v_player.bet;
    else v_payout := 0;
    end if;
    update public.room_round_players set payout = v_payout, status = 'settled', updated_at = now()
      where room_id = p_room_id and round_number = v_state.round_number and user_id = v_player.user_id;
    update public.room_players set current_balance = current_balance + v_payout, current_bet = 0
      where room_id = p_room_id and user_id = v_player.user_id;
  end loop;
end;
$$;

create function private.advance_shared_turn(p_room_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_state public.room_match_state%rowtype;
  v_next uuid;
begin
  select * into v_state from public.room_match_state where room_id = p_room_id for update;
  select rp.user_id into v_next from public.room_round_players rp
  join public.room_players p on p.room_id = rp.room_id and p.user_id = rp.user_id
  where rp.room_id = p_room_id and rp.round_number = v_state.round_number and rp.status = 'playing'
  order by p.seat_number limit 1;
  if v_next is null then perform private.settle_shared_round(p_room_id);
  else update public.room_match_state set current_turn_user_id = v_next, turn_started_at = now(), updated_at = now()
    where room_id = p_room_id;
  end if;
end;
$$;

create function private.finish_shared_match(p_room_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_state public.room_match_state%rowtype;
  v_match_id uuid;
  v_winner uuid;
  v_winner_count integer;
begin
  select * into v_state from public.room_match_state where room_id = p_room_id for update;
  if not found or v_state.status = 'finished' then return; end if;
  if v_state.status = 'playing' then
    update public.room_round_players set status = 'stood', updated_at = now()
    where room_id = p_room_id and round_number = v_state.round_number and status = 'playing';
    perform private.settle_shared_round(p_room_id);
  elsif v_state.status = 'betting' then
    update public.room_players set current_balance = current_balance + current_bet, current_bet = 0
    where room_id = p_room_id and current_bet > 0;
    update public.room_round_players set status = 'settled', payout = bet, updated_at = now()
    where room_id = p_room_id and round_number = v_state.round_number and status in ('waiting_bet','bet_placed');
  end if;
  select count(*)::integer into v_winner_count
  from public.room_players where room_id = p_room_id and left_at is null
    and current_balance = (select max(current_balance) from public.room_players where room_id = p_room_id and left_at is null);
  select user_id into v_winner from public.room_players
  where room_id = p_room_id and left_at is null
    and current_balance = (select max(current_balance) from public.room_players where room_id = p_room_id and left_at is null)
  order by user_id limit 1;
  if v_winner_count <> 1 then v_winner := null; end if;
  insert into public.matches(room_id,winner_user_id,started_at,ended_at)
  values(p_room_id,v_winner,v_state.started_at,greatest(now(),v_state.started_at)) returning id into v_match_id;
  insert into public.match_players(match_id,user_id,starting_balance,final_balance,total_wagered,final_rank,outcome,result_at)
  select v_match_id,p.user_id,p.starting_balance,p.current_balance,p.total_wagered,
    rank() over(order by p.current_balance desc)::smallint,
    case when rank() over(order by p.current_balance desc)=1 and v_winner_count>1 then 'tie'
         when rank() over(order by p.current_balance desc)=1 then 'win' else 'loss' end,
    greatest(now(),v_state.started_at)
  from public.room_players p where p.room_id=p_room_id and p.left_at is null;
  update public.rooms set status='finished',finished_at=now(),winner_user_id=v_winner where id=p_room_id;
  update public.room_match_state set status='finished',current_turn_user_id=null,turn_started_at=null,updated_at=now()
  where room_id=p_room_id;
end;
$$;

create function private.start_shared_match(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_room public.rooms%rowtype;
  v_count integer;
begin
  if v_user_id is null then raise exception 'Entre na sua conta para iniciar.'; end if;
  select * into v_room from public.rooms where id=p_room_id for update;
  if not found or v_room.status<>'waiting' then raise exception 'A sala não está aguardando uma partida.'; end if;
  if v_room.host_user_id<>v_user_id then raise exception 'Somente o anfitrião pode iniciar a partida.'; end if;
  update public.room_players set left_at=now(),current_bet=0
  where room_id=p_room_id and left_at is null and last_seen_at<now()-interval '2 minutes';
  select count(*)::integer into v_count from public.room_players where room_id=p_room_id and left_at is null;
  if v_count<2 then raise exception 'São necessários pelo menos dois jogadores conectados.'; end if;
  update public.rooms set status='playing',started_at=now(),ends_at=now()+make_interval(secs=>duration_seconds) where id=p_room_id;
  insert into public.room_match_state(room_id,status,started_at,ends_at,round_number)
  select p_room_id,'betting',now(),now()+make_interval(secs=>v_room.duration_seconds),1;
  insert into public.room_round_players(room_id,round_number,user_id)
  select p_room_id,1,user_id from public.room_players where room_id=p_room_id and left_at is null;
  return jsonb_build_object('room_id',p_room_id,'started_at',now(),
    'ends_at',now()+make_interval(secs=>v_room.duration_seconds),'status','betting');
end;
$$;

create function private.place_shared_bet(p_room_id uuid,p_bet numeric)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_state public.room_match_state%rowtype;
  v_player public.room_players%rowtype;
  v_deck jsonb; v_hand jsonb; v_card jsonb; v_rest jsonb; v_dealer jsonb := '[]'::jsonb;
  v_all_bets boolean; v_item record; v_status text; v_first_turn uuid;
begin
  if v_user_id is null then raise exception 'Entre na sua conta para apostar.'; end if;
  select * into v_state from public.room_match_state where room_id=p_room_id for update;
  if not found then raise exception 'A partida ainda não começou.'; end if;
  if now()>=v_state.ends_at then perform private.finish_shared_match(p_room_id); return; end if;
  if v_state.status='round_complete' then
    update public.room_match_state set round_number=round_number+1,status='betting',dealer_hand='[]'::jsonb,
      current_turn_user_id=null,turn_started_at=null,updated_at=now() where room_id=p_room_id;
    select * into v_state from public.room_match_state where room_id=p_room_id;
    insert into public.room_round_players(room_id,round_number,user_id)
    select p_room_id,v_state.round_number,user_id from public.room_players
    where room_id=p_room_id and left_at is null and current_balance>0;
  end if;
  if v_state.status<>'betting' then raise exception 'As apostas desta rodada já terminaram.'; end if;
  if p_bet is null or p_bet<=0 or p_bet<>round(p_bet,2) then raise exception 'Informe uma aposta válida.'; end if;
  select * into v_player from public.room_players
  where room_id=p_room_id and user_id=v_user_id and left_at is null for update;
  if not found then raise exception 'Você não está mais nesta sala.'; end if;
  if v_player.current_balance<=0 then raise exception 'Seu saldo acabou; não é possível apostar.'; end if;
  if p_bet>v_player.current_balance then raise exception 'A aposta supera seu saldo.'; end if;
  update public.room_round_players set bet=p_bet,status='bet_placed',updated_at=now()
  where room_id=p_room_id and round_number=v_state.round_number and user_id=v_user_id and status='waiting_bet';
  if not found then raise exception 'Você já apostou nesta rodada.'; end if;
  update public.room_players set current_balance=current_balance-p_bet,current_bet=p_bet,total_wagered=total_wagered+p_bet
  where room_id=p_room_id and user_id=v_user_id;
  select not exists(select 1 from public.room_round_players where room_id=p_room_id
    and round_number=v_state.round_number and status='waiting_bet') into v_all_bets;
  if not v_all_bets then return; end if;
  select jsonb_agg(jsonb_build_object('value',vals.value,'suit',suits.suit) order by random()) into v_deck
  from unnest(array['A','2','3','4','5','6','7','8','9','10','J','Q','K']) vals(value)
  cross join unnest(array['♠','♥','♦','♣']) suits(suit);
  for v_item in select rp.user_id from public.room_round_players rp
    join public.room_players p on p.room_id=rp.room_id and p.user_id=rp.user_id
    where rp.room_id=p_room_id and rp.round_number=v_state.round_number order by p.seat_number loop
    v_hand:='[]'::jsonb;
    for i in 1..2 loop
      select d.card,d.remaining_deck into v_card,v_rest from private.draw_card(v_deck) d;
      v_hand:=v_hand||jsonb_build_array(v_card); v_deck:=v_rest;
    end loop;
    v_status:=case when private.hand_score(v_hand)=21 then 'stood' else 'playing' end;
    update public.room_round_players set hand=v_hand,status=v_status,updated_at=now()
    where room_id=p_room_id and round_number=v_state.round_number and user_id=v_item.user_id;
  end loop;
  for i in 1..2 loop
    select d.card,d.remaining_deck into v_card,v_rest from private.draw_card(v_deck) d;
    v_dealer:=v_dealer||jsonb_build_array(v_card); v_deck:=v_rest;
  end loop;
  update public.room_match_state set deck=v_deck,dealer_hand=v_dealer,status='playing',updated_at=now() where room_id=p_room_id;
  select rp.user_id into v_first_turn from public.room_round_players rp
  join public.room_players p on p.room_id=rp.room_id and p.user_id=rp.user_id
  where rp.room_id=p_room_id and rp.round_number=v_state.round_number and rp.status='playing'
  order by p.seat_number limit 1;
  if v_first_turn is null then perform private.settle_shared_round(p_room_id);
  else update public.room_match_state set current_turn_user_id=v_first_turn,turn_started_at=now() where room_id=p_room_id;
  end if;
end;
$$;

create function private.shared_player_action(p_room_id uuid,p_action text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid()); v_state public.room_match_state%rowtype;
  v_hand jsonb; v_card jsonb; v_rest jsonb; v_score integer;
begin
  if v_user_id is null then raise exception 'Entre na sua conta para jogar.'; end if;
  select * into v_state from public.room_match_state where room_id=p_room_id for update;
  if not found or v_state.status<>'playing' then raise exception 'Não há uma rodada em andamento.'; end if;
  if now()>=v_state.ends_at then perform private.finish_shared_match(p_room_id); return; end if;
  if v_state.current_turn_user_id<>v_user_id then raise exception 'Aguarde sua vez.'; end if;
  if p_action not in ('hit','stand') then raise exception 'Ação inválida.'; end if;
  select hand into v_hand from public.room_round_players
  where room_id=p_room_id and round_number=v_state.round_number and user_id=v_user_id and status='playing' for update;
  if not found then raise exception 'Sua mão já foi concluída.'; end if;
  if p_action='hit' then
    select d.card,d.remaining_deck into v_card,v_rest from private.draw_card(v_state.deck) d;
    v_hand:=v_hand||jsonb_build_array(v_card); v_score:=private.hand_score(v_hand);
    update public.room_match_state set deck=v_rest,updated_at=now() where room_id=p_room_id;
    update public.room_round_players set hand=v_hand,
      status=case when v_score>=21 then case when v_score>21 then 'bust' else 'stood' end else 'playing' end,
      updated_at=now() where room_id=p_room_id and round_number=v_state.round_number and user_id=v_user_id;
  else
    update public.room_round_players set status='stood',updated_at=now()
    where room_id=p_room_id and round_number=v_state.round_number and user_id=v_user_id;
  end if;
  perform private.advance_shared_turn(p_room_id);
end;
$$;

create function private.get_shared_match_state(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid()); v_state public.room_match_state%rowtype;
  v_room public.rooms%rowtype; v_players jsonb; v_hands jsonb; v_dealer jsonb;
begin
  if v_user_id is null then raise exception 'Entre na sua conta para ver a partida.'; end if;
  if not (select private.is_active_room_member(p_room_id)) then raise exception 'Você não tem acesso a esta sala.'; end if;
  select * into v_state from public.room_match_state where room_id=p_room_id for update;
  if not found then return null; end if;
  if v_state.status<>'finished' and now()>=v_state.ends_at then perform private.finish_shared_match(p_room_id);
  elsif v_state.status='playing' and v_state.turn_started_at<now()-interval '30 seconds' then
    update public.room_round_players set status='stood',updated_at=now()
    where room_id=p_room_id and round_number=v_state.round_number and user_id=v_state.current_turn_user_id and status='playing';
    perform private.advance_shared_turn(p_room_id);
  end if;
  select * into v_state from public.room_match_state where room_id=p_room_id;
  if v_state.status='round_complete' and not exists(
    select 1 from public.room_players where room_id=p_room_id and left_at is null and current_balance>0
  ) then perform private.finish_shared_match(p_room_id); select * into v_state from public.room_match_state where room_id=p_room_id; end if;
  select * into v_room from public.rooms where id=p_room_id;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',rp.user_id,'nickname',pr.nickname,'seat_number',rp.seat_number,
    'balance',rp.current_balance,'current_bet',rp.current_bet,'total_wagered',rp.total_wagered,
    'online',rp.last_seen_at>now()-interval '90 seconds') order by rp.seat_number),'[]'::jsonb)
  into v_players from public.room_players rp join public.profiles pr on pr.id=rp.user_id
  where rp.room_id=p_room_id and rp.left_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',rrp.user_id,'nickname',pr.nickname,'seat_number',rp.seat_number,
    'bet',rrp.bet,'hand',rrp.hand,'status',rrp.status,'payout',rrp.payout) order by rp.seat_number),'[]'::jsonb)
  into v_hands from public.room_round_players rrp
  join public.room_players rp on rp.room_id=rrp.room_id and rp.user_id=rrp.user_id
  join public.profiles pr on pr.id=rrp.user_id
  where rrp.room_id=p_room_id and rrp.round_number=v_state.round_number;
  select coalesce(jsonb_agg(case when v_state.status='playing' and cards.ordinality=1
    then jsonb_build_object('hidden',true) else cards.card end order by cards.ordinality),'[]'::jsonb)
  into v_dealer from jsonb_array_elements(v_state.dealer_hand) with ordinality cards(card,ordinality);
  return jsonb_build_object('room_id',p_room_id,'room_status',v_room.status,'host_user_id',v_room.host_user_id,
    'status',v_state.status,'started_at',v_state.started_at,'ends_at',v_state.ends_at,'round_number',v_state.round_number,
    'current_turn_user_id',v_state.current_turn_user_id,'turn_started_at',v_state.turn_started_at,'dealer_hand',v_dealer,
    'dealer_total',case when v_state.status='playing' then null else private.hand_score(v_state.dealer_hand) end,
    'players',v_players,'hands',v_hands,'winner_user_id',v_room.winner_user_id);
end;
$$;

revoke all on function private.hand_score(jsonb) from public, anon, authenticated;
revoke all on function private.draw_card(jsonb) from public, anon, authenticated;
revoke all on function private.settle_shared_round(uuid) from public, anon, authenticated;
revoke all on function private.advance_shared_turn(uuid) from public, anon, authenticated;
revoke all on function private.finish_shared_match(uuid) from public, anon, authenticated;
revoke all on function private.start_shared_match(uuid) from public, anon, authenticated;
revoke all on function private.place_shared_bet(uuid,numeric) from public, anon, authenticated;
revoke all on function private.shared_player_action(uuid,text) from public, anon, authenticated;
revoke all on function private.get_shared_match_state(uuid) from public, anon, authenticated;
grant execute on function private.start_shared_match(uuid) to authenticated;
grant execute on function private.place_shared_bet(uuid,numeric) to authenticated;
grant execute on function private.shared_player_action(uuid,text) to authenticated;
grant execute on function private.get_shared_match_state(uuid) to authenticated;

create function public.start_shared_match(p_room_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.start_shared_match(p_room_id); $$;
create function public.place_shared_bet(p_room_id uuid,p_bet numeric)
returns void language sql security invoker set search_path = ''
as $$ select private.place_shared_bet(p_room_id,p_bet); $$;
create function public.shared_player_action(p_room_id uuid,p_action text)
returns void language sql security invoker set search_path = ''
as $$ select private.shared_player_action(p_room_id,p_action); $$;
create function public.get_shared_match_state(p_room_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.get_shared_match_state(p_room_id); $$;
revoke all on function public.start_shared_match(uuid) from public, anon;
revoke all on function public.place_shared_bet(uuid,numeric) from public, anon;
revoke all on function public.shared_player_action(uuid,text) from public, anon;
revoke all on function public.get_shared_match_state(uuid) from public, anon;
grant execute on function public.start_shared_match(uuid) to authenticated;
grant execute on function public.place_shared_bet(uuid,numeric) to authenticated;
grant execute on function public.shared_player_action(uuid,text) to authenticated;
grant execute on function public.get_shared_match_state(uuid) to authenticated;

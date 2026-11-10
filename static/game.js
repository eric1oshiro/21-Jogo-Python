(() => {
const sdk = window.supabase;
const config = window.SUPABASE_CONFIG;
if (!sdk?.createClient || !config?.url || !config?.publishableKey) {
  const message = document.querySelector('#auth-message');
  if (message) {
    message.textContent = !sdk?.createClient
      ? 'O cliente do Supabase não carregou. Verifique a conexão e atualize a página.'
      : 'A configuração pública do Supabase não foi carregada. Confira static/supabase-config.js.';
    message.classList.add('is-error');
  }
  return;
}

const { createClient } = sdk;
const { url, publishableKey } = config;

const supabase = createClient(url, publishableKey, {
  auth: {
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: true,
  },
});

const money = (value) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(value);
let authViewVersion = 0;
let signedInUser = null;
let onlineNickname = '';
let lobbyChannel = null;
let roomChannel = null;
let activeRoomId = null;
let roomHeartbeat = null;
let presenceUsers = new Map();
let onlineInitializedUser = null;

function showAuthMessage(message, isError = false) {
  const element = document.querySelector('#auth-message');
  element.textContent = message;
  element.classList.toggle('is-error', isError);
}

function showProfileMessage(message, isError = false) {
  const element = document.querySelector('#profile-message');
  element.textContent = message;
  element.classList.toggle('is-error', isError);
}

function authErrorMessage(error) {
  const message = String(error?.message || 'Não foi possível concluir o acesso.');
  const normalized = message.toLowerCase();
  if (normalized.includes('redirect') || normalized.includes('requested path')) {
    return `O Supabase recusou o endereço de retorno. Em Authentication → URL Configuration → Redirect URLs, permita ${window.location.origin}/**.`;
  }
  if (normalized.includes('rate limit') || normalized.includes('too many')) {
    return 'O limite de emails do Supabase foi atingido. Aguarde um pouco ou configure um SMTP próprio no projeto.';
  }
  if (normalized.includes('failed to fetch') || normalized.includes('network')) {
    return 'Não consegui alcançar o Supabase. Verifique sua conexão, a URL e a chave em static/supabase-config.js.';
  }
  return message;
}

function setAuthMode(mode) {
  const isLogin = mode === 'login';
  document.querySelector('#login-form').hidden = !isLogin;
  document.querySelector('#signup-form').hidden = isLogin;
  document.querySelector('#login-tab').classList.toggle('active', isLogin);
  document.querySelector('#signup-tab').classList.toggle('active', !isLogin);
  document.querySelector('#login-tab').setAttribute('aria-selected', String(isLogin));
  document.querySelector('#signup-tab').setAttribute('aria-selected', String(!isLogin));
  document.querySelector('#auth-title').textContent = isLogin ? 'Entre no jogo' : 'Crie sua conta';
  showAuthMessage('');
}

function showAuthScreen() {
  document.querySelector('#auth-panel').hidden = false;
  document.querySelector('#profile-panel').hidden = true;
  document.querySelector('#game-app').hidden = true;
}

function showProfileScreen(user) {
  document.querySelector('#auth-panel').hidden = true;
  document.querySelector('#profile-panel').hidden = false;
  document.querySelector('#game-app').hidden = true;
  const nickname = user.user_metadata?.nickname || '';
  document.querySelector('#profile-nickname').value = nickname;
  showProfileMessage('');
}

async function showGameScreen(nickname) {
  document.querySelector('#auth-panel').hidden = true;
  document.querySelector('#profile-panel').hidden = true;
  document.querySelector('#game-app').hidden = false;
  document.querySelector('#player-nickname').textContent = nickname;
  onlineNickname = nickname;
  await run(() => api('/api/state'));
  await initializeOnline();
}

async function routeSession(session) {
  const version = ++authViewVersion;
  signedInUser = session?.user || null;
  if (!signedInUser) {
    await closeOnlineChannels();
    showAuthScreen();
    return;
  }

  const { data: profile, error } = await supabase
    .from('profiles')
    .select('nickname')
    .eq('id', signedInUser.id)
    .maybeSingle();

  if (version !== authViewVersion) return;
  if (error) {
    showProfileScreen(signedInUser);
    showProfileMessage(`Não consegui carregar seu perfil: ${error.message}`, true);
    return;
  }
  if (!profile) {
    showProfileScreen(signedInUser);
    return;
  }
  await showGameScreen(profile.nickname);
}

async function runAuthForm(form, action) {
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    await action(new FormData(form));
  } catch (error) {
    showAuthMessage(authErrorMessage(error), true);
  } finally {
    button.disabled = false;
  }
}

document.querySelector('#login-tab').addEventListener('click', () => setAuthMode('login'));
document.querySelector('#signup-tab').addEventListener('click', () => setAuthMode('signup'));

document.querySelector('#login-form').addEventListener('submit', (event) => {
  event.preventDefault();
  runAuthForm(event.currentTarget, async (formData) => {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: String(formData.get('email')).trim(),
      password: String(formData.get('password')),
    });
    if (error) throw error;
    showAuthMessage('Login realizado. Carregando sua mesa...');
    await routeSession(data.session);
  });
});

document.querySelector('#signup-form').addEventListener('submit', (event) => {
  event.preventDefault();
  runAuthForm(event.currentTarget, async (formData) => {
    const nickname = String(formData.get('nickname')).trim();
    if (nickname.length < 3 || nickname.length > 20) {
      throw new Error('O apelido precisa ter entre 3 e 20 caracteres.');
    }
    const { data, error } = await supabase.auth.signUp({
      email: String(formData.get('email')).trim(),
      password: String(formData.get('password')),
      options: {
        data: { nickname },
        emailRedirectTo: window.location.origin,
      },
    });
    if (error) throw error;
    if (data.session) {
      showAuthMessage('Conta criada! Vamos preparar seu perfil...');
      await routeSession(data.session);
    } else {
      setAuthMode('login');
      showAuthMessage('Conta criada. Confira seu email para confirmar o cadastro e depois entre.');
    }
  });
});

document.querySelector('#signup-form').addEventListener('invalid', (event) => {
  if (event.target.validity.tooShort) {
    const fieldName = event.target.name === 'password' ? 'A senha' : 'O apelido';
    const minimum = event.target.name === 'password' ? '8' : '3';
    showAuthMessage(`${fieldName} precisa ter pelo menos ${minimum} caracteres.`, true);
  }
}, true);

document.querySelector('#profile-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!signedInUser) return;
  const form = event.currentTarget;
  const button = form.querySelector('button[type="submit"]');
  const nickname = document.querySelector('#profile-nickname').value.trim();
  if (nickname.length < 3 || nickname.length > 20) {
    showProfileMessage('O apelido precisa ter entre 3 e 20 caracteres.', true);
    return;
  }
  button.disabled = true;
  showProfileMessage('Salvando apelido...');
  try {
    const { error } = await supabase.from('profiles').insert({ id: signedInUser.id, nickname });
    if (error) {
      const message = error.code === '23505'
        ? 'Esse apelido já está sendo usado. Escolha outro.'
        : `Não foi possível salvar o apelido: ${error.message}`;
      showProfileMessage(message, true);
      return;
    }
    await showGameScreen(nickname);
  } catch (error) {
    showProfileMessage(authErrorMessage(error), true);
  } finally {
    button.disabled = false;
  }
});

async function signOut() {
  if (activeRoomId) await leaveRoom();
  const { error } = await supabase.auth.signOut();
  if (error) {
    showProfileMessage(error.message, true);
    return;
  }
  await closeOnlineChannels();
  signedInUser = null;
  showAuthScreen();
  setAuthMode('login');
  showAuthMessage('Você saiu da sua conta.');
}

document.querySelector('#signout-button').addEventListener('click', signOut);
document.querySelector('#profile-signout').addEventListener('click', signOut);

supabase.auth.onAuthStateChange((_event, session) => {
  queueMicrotask(() => { void routeSession(session); });
});

supabase.auth.getSession().then(({ data, error }) => {
  if (error) {
    showAuthMessage(`Não consegui conectar ao Supabase: ${error.message}`, true);
    return;
  }
  return routeSession(data.session);
});

async function api(path, data) {
  const options = data ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) } : {};
  const response = await fetch(path, options);
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || 'Não foi possível concluir a ação.');
  return payload;
}

function renderCards(container, cards) {
  container.replaceChildren();
  cards.forEach((card) => {
    const element = document.createElement('div');
    element.className = `playing-card${card.hidden ? ' card-back' : ''}${['♥', '♦'].includes(card.suit) ? ' red' : ''}`;
    if (!card.hidden) {
      element.innerHTML = `<span class="card-corner">${card.value}<small>${card.suit}</small></span><span class="card-center">${card.suit}</span>`;
      element.setAttribute('aria-label', `${card.value} de ${card.suit}`);
    } else {
      element.setAttribute('aria-label', 'Carta virada para baixo');
    }
    container.append(element);
  });
}

function render(state) {
  document.querySelector('#balance').textContent = money(state.balance);
  document.querySelector('#player-score').textContent = state.player.length ? state.player_total : '—';
  document.querySelector('#dealer-score').textContent = state.dealer.length ? (state.dealer_total ?? '•') : '—';
  document.querySelector('#message').textContent = state.message;
  document.querySelector('#message').className = `round-message ${state.result || ''}`;
  renderCards(document.querySelector('#player-cards'), state.player);
  renderCards(document.querySelector('#dealer-cards'), state.dealer);
  document.querySelector('#bet-controls').hidden = state.active || Boolean(state.result);
  document.querySelector('#action-controls').hidden = !state.active;
  document.querySelector('#finished-controls').hidden = state.active || !state.result;
  document.querySelector('#start-button').disabled = state.balance <= 0;
  document.querySelector('#bet-input').max = state.balance;
}

function showError(error) {
  const message = document.querySelector('#message');
  message.textContent = error.message;
  message.className = 'round-message error';
}

async function run(action) {
  try { render(await action()); } catch (error) { showError(error); }
}

function showOnlineMode(isOnline) {
  document.querySelector('#offline-view').hidden = isOnline;
  document.querySelector('#online-view').hidden = !isOnline;
  document.querySelector('#offline-tab').classList.toggle('active', !isOnline);
  document.querySelector('#online-tab').classList.toggle('active', isOnline);
  if (isOnline) void loadRooms();
}

function showOnlineTab(tab) {
  const showHistory = tab === 'history';
  document.querySelector('#rooms-view').hidden = showHistory;
  document.querySelector('#history-view').hidden = !showHistory;
  document.querySelector('#rooms-tab').classList.toggle('active', !showHistory);
  document.querySelector('#history-tab').classList.toggle('active', showHistory);
  document.querySelector('#rooms-tab').setAttribute('aria-selected', String(!showHistory));
  document.querySelector('#history-tab').setAttribute('aria-selected', String(showHistory));
  if (showHistory) void loadHistory();
}

function setLobbyStatus(text, isError = false) {
  const element = document.querySelector('#lobby-status');
  element.textContent = text;
  element.classList.toggle('is-error', isError);
}

function showRoomsMessage(text, isError = false) {
  const element = document.querySelector('#rooms-message');
  element.textContent = text;
  element.classList.toggle('is-error', isError);
}

async function announceLobbyChange() {
  if (!lobbyChannel) return;
  await lobbyChannel.send({
    type: 'broadcast', event: 'rooms_changed',
    payload: { user_id: signedInUser?.id, at: new Date().toISOString() },
  });
}

async function initializeOnline() {
  if (!signedInUser) return;
  if (onlineInitializedUser === signedInUser.id && lobbyChannel) return;
  await closeOnlineChannels();
  onlineInitializedUser = signedInUser.id;
  lobbyChannel = supabase.channel('lobby', { config: { private: true } });
  lobbyChannel
    .on('broadcast', { event: 'rooms_changed' }, () => { void loadRooms(); })
    .subscribe((status, error) => {
      if (status === 'SUBSCRIBED') {
        setLobbyStatus('Conectado ao lobby');
        void loadRooms();
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        setLobbyStatus(error?.message || 'Não foi possível conectar ao lobby.', true);
      }
    });
  void loadHistory();
}

async function closeOnlineChannels() {
  if (roomHeartbeat) window.clearInterval(roomHeartbeat);
  roomHeartbeat = null;
  presenceUsers = new Map();
  const channels = [roomChannel, lobbyChannel].filter(Boolean);
  roomChannel = null;
  lobbyChannel = null;
  activeRoomId = null;
  onlineInitializedUser = null;
  document.querySelector('#room-detail').hidden = true;
  await Promise.all(channels.map((channel) => supabase.removeChannel(channel)));
}

async function loadRooms() {
  if (!signedInUser) return;
  const list = document.querySelector('#room-list');
  const { data, error } = await supabase.rpc('list_open_rooms');
  if (error) {
    showRoomsMessage(`Não consegui carregar as salas: ${error.message}`, true);
    return;
  }
  showRoomsMessage(data.length ? '' : 'Não há salas aguardando jogadores. Você pode criar uma.');
  list.replaceChildren();
  data.forEach((room) => {
    const card = document.createElement('article');
    card.className = 'room-list-item';
    const info = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = `Sala ${room.code}`;
    const details = document.createElement('span');
    details.textContent = `Anfitrião: ${room.host_nickname} · ${room.player_count}/${room.max_players} jogadores · ${Math.round(room.duration_seconds / 60)} min`;
    info.append(title, details);
    const join = document.createElement('button');
    join.type = 'button';
    join.className = 'button button-primary compact-button';
    join.textContent = 'Entrar';
    join.addEventListener('click', () => { void joinRoom(room); });
    card.append(info, join);
    list.append(card);
  });
}

async function enterRoom(roomId, eventKind) {
  if (roomChannel) await supabase.removeChannel(roomChannel);
  if (roomHeartbeat) window.clearInterval(roomHeartbeat);
  activeRoomId = roomId;
  document.querySelector('#room-detail').hidden = false;
  document.querySelector('#room-title').textContent = 'Sala online';
  document.querySelector('#room-notice').textContent = 'Conectando à sala…';
  const channel = supabase.channel(`room:${roomId}`, {
    config: { private: true, presence: { key: signedInUser.id } },
  });
  roomChannel = channel;
  channel
    .on('presence', { event: 'sync' }, () => renderPresence())
    .on('presence', { event: 'join' }, ({ newPresences }) => {
      const name = newPresences?.[0]?.nickname;
      if (name && name !== onlineNickname) document.querySelector('#room-notice').textContent = `${name} entrou na sala.`;
      renderPresence();
    })
    .on('presence', { event: 'leave' }, ({ leftPresences }) => {
      const name = leftPresences?.[0]?.nickname;
      if (name) document.querySelector('#room-notice').textContent = `${name} saiu da conexão.`;
      renderPresence();
    })
    .on('broadcast', { event: 'room_event' }, ({ payload }) => {
      if (payload?.nickname && payload.nickname !== onlineNickname) {
        const verb = payload.kind === 'joined' ? 'entrou na sala.' : 'saiu da sala.';
        document.querySelector('#room-notice').textContent = `${payload.nickname} ${verb}`;
      }
      void refreshRoom();
      void loadRooms();
    })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players', filter: `room_id=eq.${roomId}` }, () => {
      void refreshRoom();
      void loadRooms();
    })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${roomId}` }, () => { void refreshRoom(); })
    .subscribe(async (status, error) => {
      if (status === 'SUBSCRIBED') {
        await channel.track({ user_id: signedInUser.id, nickname: onlineNickname, online_at: new Date().toISOString() });
        await channel.send({ type: 'broadcast', event: 'room_event', payload: { kind: eventKind, nickname: onlineNickname } });
        await refreshRoom();
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        document.querySelector('#room-notice').textContent = error?.message || 'A conexão em tempo real falhou. Atualize a página.';
      }
    });
  roomHeartbeat = window.setInterval(async () => {
    if (activeRoomId !== roomId) return;
    const { error } = await supabase.rpc('touch_room', { p_room_id: roomId });
    if (error) setLobbyStatus(`A conexão com a sala caiu: ${error.message}`, true);
  }, 30000);
  await refreshRoom();
}

function renderPresence() {
  if (!roomChannel) return;
  const state = roomChannel.presenceState();
  const users = new Map();
  Object.values(state).flat().forEach((presence) => {
    if (presence.user_id) users.set(presence.user_id, presence.nickname || 'Jogador');
  });
  presenceUsers = users;
  document.querySelector('#online-count').textContent = `${users.size} online`;
  document.querySelectorAll('[data-player-id]').forEach((row) => {
    const online = users.has(row.dataset.playerId);
    row.classList.toggle('is-online', online);
    const dot = row.querySelector('.player-presence');
    if (dot) dot.textContent = online ? 'Online' : 'Desconectado';
  });
}

async function refreshRoom() {
  const roomId = activeRoomId;
  if (!roomId) return;
  const [{ data: room, error: roomError }, { data: players, error: playersError }] = await Promise.all([
    supabase.from('rooms').select('id, code, host_user_id, status, max_players, duration_seconds').eq('id', roomId).maybeSingle(),
    supabase.from('room_players').select('user_id, seat_number, starting_balance, current_balance, current_bet, total_wagered, profiles(nickname)').eq('room_id', roomId).is('left_at', null).order('seat_number'),
  ]);
  if (roomError || playersError) {
    document.querySelector('#room-notice').textContent = `Não consegui atualizar a sala: ${(roomError || playersError).message}`;
    return;
  }
  if (!room) {
    document.querySelector('#room-detail').hidden = true;
    return;
  }
  document.querySelector('#room-title').textContent = room.status === 'waiting' ? 'Aguardando jogadores' : 'Partida em andamento';
  document.querySelector('#room-code').textContent = room.code;
  document.querySelector('#room-count').textContent = `(${players.length}/${room.max_players})`;
  const roster = document.querySelector('#room-roster');
  roster.replaceChildren();
  players.forEach((player) => {
    const row = document.createElement('div');
    row.className = 'roster-player';
    row.dataset.playerId = player.user_id;
    const name = document.createElement('strong');
    name.textContent = `${player.profiles?.nickname || 'Jogador'}${player.user_id === room.host_user_id ? ' · anfitrião' : ''}`;
    const balance = document.createElement('span');
    balance.textContent = `Saldo ${money(Number(player.current_balance))} · aposta ${money(Number(player.current_bet))}`;
    const presence = document.createElement('small');
    presence.className = 'player-presence';
    presence.textContent = presenceUsers.has(player.user_id) ? 'Online' : 'Conectando…';
    row.append(name, balance, presence);
    roster.append(row);
  });
  document.querySelector('#room-notice').textContent = room.status === 'waiting'
    ? `Sala de ${Math.round(room.duration_seconds / 60)} minutos. A sincronização de presença está ativa.`
    : 'A partida foi iniciada.';
  renderPresence();
}

async function joinRoom(room) {
  showRoomsMessage('Entrando na sala…');
  const { error } = await supabase.rpc('join_room', { p_room_id: room.id });
  if (error) {
    showRoomsMessage(error.message, true);
    await loadRooms();
    return;
  }
  await enterRoom(room.id, 'joined');
  await announceLobbyChange();
  await loadRooms();
}

async function createRoom(event) {
  event.preventDefault();
  const button = event.currentTarget.querySelector('button[type="submit"]');
  button.disabled = true;
  showRoomsMessage('Criando sala…');
  const capacity = Number(document.querySelector('#room-capacity').value);
  const duration = Number(document.querySelector('#room-duration').value);
  const { data: roomId, error } = await supabase.rpc('create_room', {
    p_max_players: capacity,
    p_duration_seconds: duration,
  });
  button.disabled = false;
  if (error) {
    showRoomsMessage(error.message, true);
    return;
  }
  showRoomsMessage('Sala criada. Compartilhe o código com seus amigos.');
  await enterRoom(roomId, 'joined');
  await announceLobbyChange();
  await loadRooms();
}

async function leaveRoom() {
  const roomId = activeRoomId;
  if (!roomId) return;
  if (roomChannel) {
    await roomChannel.send({ type: 'broadcast', event: 'room_event', payload: { kind: 'left', nickname: onlineNickname } });
    await roomChannel.untrack();
  }
  const { error } = await supabase.rpc('leave_room', { p_room_id: roomId });
  if (error) {
    document.querySelector('#room-notice').textContent = error.message;
    return;
  }
  if (roomHeartbeat) window.clearInterval(roomHeartbeat);
  roomHeartbeat = null;
  if (roomChannel) await supabase.removeChannel(roomChannel);
  roomChannel = null;
  activeRoomId = null;
  document.querySelector('#room-detail').hidden = true;
  await announceLobbyChange();
  await loadRooms();
}

async function loadHistory() {
  if (!signedInUser) return;
  const list = document.querySelector('#history-list');
  const message = document.querySelector('#history-message');
  const { data: results, error } = await supabase.from('match_players')
    .select('match_id, starting_balance, final_balance, total_wagered, final_rank, outcome, result_at, matches!inner(id, room_id, started_at, ended_at)')
    .eq('user_id', signedInUser.id)
    .order('result_at', { ascending: false })
    .limit(30);
  if (error) {
    message.textContent = `Não consegui carregar o histórico: ${error.message}`;
    message.classList.add('is-error');
    return;
  }
  message.classList.remove('is-error');
  const wins = results.filter((row) => row.outcome === 'win').length;
  const losses = results.filter((row) => row.outcome === 'loss').length;
  const ties = results.filter((row) => row.outcome === 'tie').length;
  document.querySelector('#history-summary').textContent = `${wins} vitórias · ${losses} derrotas · ${ties} empates`;
  list.replaceChildren();
  if (!results.length) {
    message.textContent = 'Suas partidas concluídas aparecerão aqui. Ainda não há resultados registrados.';
    return;
  }
  message.textContent = '';
  const matchIds = results.map((row) => row.match_id);
  const [{ data: opponents }, { data: rooms }] = await Promise.all([
    supabase.from('match_players').select('match_id, user_id, final_rank, profiles(nickname)').in('match_id', matchIds).neq('user_id', signedInUser.id),
    supabase.from('rooms').select('id, code').in('id', [...new Set(results.map((row) => row.matches.room_id))]),
  ]);
  results.forEach((result) => {
    const card = document.createElement('article');
    card.className = `history-item ${result.outcome}`;
    const title = document.createElement('strong');
    title.textContent = result.outcome === 'win' ? 'Vitória' : result.outcome === 'loss' ? 'Derrota' : 'Empate';
    const room = rooms?.find((entry) => entry.id === result.matches.room_id);
    const others = (opponents || []).filter((entry) => entry.match_id === result.match_id);
    const names = others.map((entry) => entry.profiles?.nickname || 'Jogador').join(', ') || 'sem adversários registrados';
    const detail = document.createElement('span');
    detail.textContent = `Sala ${room?.code || '—'} · contra ${names} · posição ${result.final_rank}º`;
    const numbers = document.createElement('small');
    numbers.textContent = `Saldo final ${money(Number(result.final_balance))} · apostado ${money(Number(result.total_wagered))} · ${new Date(result.matches.ended_at).toLocaleString('pt-BR')}`;
    card.append(title, detail, numbers);
    list.append(card);
  });
}

document.querySelector('#offline-tab').addEventListener('click', () => showOnlineMode(false));
document.querySelector('#online-tab').addEventListener('click', () => showOnlineMode(true));
document.querySelector('#rooms-tab').addEventListener('click', () => showOnlineTab('rooms'));
document.querySelector('#history-tab').addEventListener('click', () => showOnlineTab('history'));
document.querySelector('#refresh-rooms').addEventListener('click', () => { void loadRooms(); });
document.querySelector('#refresh-history').addEventListener('click', () => { void loadHistory(); });
document.querySelector('#create-room-form').addEventListener('submit', (event) => { void createRoom(event); });
document.querySelector('#leave-room').addEventListener('click', () => { void leaveRoom(); });

document.querySelector('#start-button').addEventListener('click', () => {
  const bet = Number(document.querySelector('#bet-input').value);
  run(() => api('/api/start', { bet }));
});
document.querySelector('#hit-button').addEventListener('click', () => run(() => api('/api/action', { action: 'hit' })));
document.querySelector('#stand-button').addEventListener('click', () => run(() => api('/api/action', { action: 'stand' })));
document.querySelector('#next-button').addEventListener('click', () => run(() => api('/api/new-round', {})));
document.querySelector('#reset-button').addEventListener('click', () => run(() => api('/api/reset', {})));
})();

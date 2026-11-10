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
  await run(() => api('/api/state'));
}

async function routeSession(session) {
  const version = ++authViewVersion;
  signedInUser = session?.user || null;
  if (!signedInUser) {
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
  const { error } = await supabase.auth.signOut();
  if (error) {
    showProfileMessage(error.message, true);
    return;
  }
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

document.querySelector('#start-button').addEventListener('click', () => {
  const bet = Number(document.querySelector('#bet-input').value);
  run(() => api('/api/start', { bet }));
});
document.querySelector('#hit-button').addEventListener('click', () => run(() => api('/api/action', { action: 'hit' })));
document.querySelector('#stand-button').addEventListener('click', () => run(() => api('/api/action', { action: 'stand' })));
document.querySelector('#next-button').addEventListener('click', () => run(() => api('/api/new-round', {})));
document.querySelector('#reset-button').addEventListener('click', () => run(() => api('/api/reset', {})));
})();

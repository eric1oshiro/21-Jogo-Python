const money = (value) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(value);

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

run(() => api('/api/state'));

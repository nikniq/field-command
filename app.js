const state = {
  supply: 240,
  morale: 84,
  wave: 1,
  phase: 'deploy',
  selected: 'ranger',
  paused: false,
  units: [],
  enemies: [],
  nextEnemyId: 1,
  seconds: 84,
  waveTimer: null,
  enemyTimer: null,
};

const unitTypes = {
  ranger: { label: 'Ranger', short: 'R', cost: 40, damage: 16, range: 23, color: 'teal' },
  support: { label: 'Field Medic', short: '+', cost: 55, damage: 5, range: 19, color: 'teal' },
  heavy: { label: 'Heavy Gunner', short: 'H', cost: 80, damage: 30, range: 28, color: 'gold' },
};
const battlefield = document.querySelector('#battlefield');
const unitsLayer = document.querySelector('#unitsLayer');
const enemiesLayer = document.querySelector('#enemiesLayer');
const log = document.querySelector('#log');
const phaseMessage = document.querySelector('#phaseMessage');
const phaseKicker = document.querySelector('#phaseKicker');

function addLog(message) {
  const item = document.createElement('div');
  item.className = 'log-line';
  item.innerHTML = `<b>${String(new Date().getMinutes()).padStart(2, '0')}:${String(new Date().getSeconds()).padStart(2, '0')}</b>${message}`;
  log.prepend(item);
  while (log.children.length > 4) log.lastElementChild.remove();
}

function updateUI() {
  document.querySelector('#supplyValue').textContent = state.supply;
  document.querySelector('#moraleValue').textContent = state.morale;
  document.querySelector('#moraleBar').style.width = `${state.morale}%`;
  document.querySelector('#waveNumber').textContent = String(state.wave).padStart(2, '0');
  document.querySelector('#nextContact').textContent = state.phase === 'deploy' ? '01:24' : `${String(Math.max(0, 22 - state.enemies.length * 2)).padStart(2, '0')} SEC`;
  const moraleState = document.querySelector('#moraleState');
  const cohesion = document.querySelector('#cohesionText');
  moraleState.textContent = state.morale > 65 ? 'STEADY' : state.morale > 35 ? 'SHAKEN' : 'CRITICAL';
  cohesion.textContent = state.morale > 65 ? 'GOOD' : state.morale > 35 ? 'FAIR' : 'LOW';
  moraleState.style.color = state.morale > 65 ? 'var(--teal)' : 'var(--orange-dark)';
  phaseKicker.textContent = state.phase === 'deploy' ? 'DEPLOYMENT PHASE' : state.phase === 'complete' ? 'SECTOR SECURED' : state.paused ? 'SIMULATION PAUSED' : `WAVE ${String(state.wave).padStart(2, '0')} IN PROGRESS`;
  phaseMessage.textContent = state.phase === 'deploy' ? 'Place your squad before contact.' : state.phase === 'complete' ? 'All hostile contacts neutralized.' : state.paused ? 'Resume when you are ready.' : 'Hold the line. Your units engage automatically.';
}

function renderUnit(unit) {
  const el = document.createElement('div');
  el.className = 'unit';
  el.dataset.id = unit.id;
  el.style.left = `${unit.x}%`;
  el.style.top = `${unit.y}%`;
  el.title = `${unitTypes[unit.type].label} - ${unit.hp} HP`;
  el.textContent = unitTypes[unit.type].short;
  unitsLayer.appendChild(el);
}

function renderEnemy(enemy) {
  const el = document.createElement('div');
  el.className = 'enemy';
  el.dataset.id = enemy.id;
  el.style.left = `${enemy.x}%`;
  el.style.top = `${enemy.y}%`;
  el.title = `Hostile scout - ${enemy.hp} HP`;
  el.innerHTML = `×<div class="health"><span style="width:${(enemy.hp / enemy.maxHp) * 100}%"></span></div>`;
  enemiesLayer.appendChild(el);
}

function deploy(event) {
  if (state.phase !== 'deploy' || state.paused || event.target.closest('.unit, .enemy')) return;
  const type = unitTypes[state.selected];
  if (state.supply < type.cost) { addLog('Insufficient supply for deployment.'); return; }
  const rect = battlefield.getBoundingClientRect();
  const x = ((event.clientX - rect.left) / rect.width) * 100;
  const y = ((event.clientY - rect.top) / rect.height) * 100;
  if (x > 77 || x < 4 || y < 5 || y > 95) { addLog('Position outside deployment corridor.'); return; }
  const unit = { id: `u-${Date.now()}`, type: state.selected, x, y, hp: 100, cooldown: 0 };
  state.units.push(unit); state.supply -= type.cost; renderUnit(unit); updateUI();
  addLog(`${type.label.toUpperCase()} deployed to grid ${Math.ceil(x / 10)}-${Math.ceil(y / 10)}.`);
}

function selectUnit(event) {
  const card = event.target.closest('.unit-card');
  if (!card) return;
  document.querySelectorAll('.unit-card').forEach((item) => item.classList.remove('selected'));
  card.classList.add('selected'); state.selected = card.dataset.unit;
}

function spawnEnemy() {
  const enemy = { id: `e-${state.nextEnemyId++}`, x: 10 + Math.random() * 25, y: 22 + Math.random() * 57, hp: 54 + state.wave * 12, maxHp: 54 + state.wave * 12, speed: .6 + Math.random() * .3 };
  state.enemies.push(enemy); renderEnemy(enemy); updateUI();
}

function battleTick() {
  if (state.paused || state.phase !== 'battle') return;
  state.enemies.forEach((enemy) => {
    enemy.x += enemy.speed;
    const el = enemiesLayer.querySelector(`[data-id="${enemy.id}"]`);
    if (el) el.style.left = `${enemy.x}%`;
    if (enemy.x > 78) { enemy.x = 78; state.morale = Math.max(0, state.morale - 2); }
  });
  state.units.forEach((unit) => {
    unit.cooldown -= 1;
    if (unit.cooldown > 0) return;
    const type = unitTypes[unit.type];
    const target = state.enemies.find((enemy) => Math.hypot(enemy.x - unit.x, (enemy.y - unit.y) * .8) < type.range);
    if (target) { target.hp -= type.damage; unit.cooldown = unit.type === 'heavy' ? 3 : 2; }
  });
  state.enemies = state.enemies.filter((enemy) => {
    if (enemy.hp > 0) return true;
    enemiesLayer.querySelector(`[data-id="${enemy.id}"]`)?.remove();
    state.supply += 12;
    return false;
  });
  if (state.morale <= 0) endGame(false);
  if (state.enemies.length === 0 && state.waveTimer === null && state.units.length > 0) { state.waveTimer = setTimeout(() => { state.waveTimer = null; nextWave(); }, 2200); }
  updateUI();
}

function nextWave() {
  if (state.wave >= 3) { endGame(true); return; }
  state.wave += 1;
  addLog(`WAVE ${String(state.wave).padStart(2, '0')} CONTACT. Brace for impact.`);
  for (let i = 0; i < 3 + state.wave; i += 1) setTimeout(spawnEnemy, i * 500);
  updateUI();
}

function startWave() {
  if (state.phase === 'complete') return;
  if (!state.units.length) { addLog('Deploy at least one unit before starting.'); return; }
  if (state.phase === 'deploy') {
    state.phase = 'battle';
    addLog('CONTACT CONFIRMED. Weapons free.');
    for (let i = 0; i < 3; i += 1) setTimeout(spawnEnemy, i * 500);
    state.enemyTimer = setInterval(battleTick, 500);
    document.querySelector('#startWave').innerHTML = '<span class="button-icon">▮▮</span> WAVE ACTIVE';
  }
  updateUI();
}

function endGame(won) {
  state.phase = won ? 'complete' : 'deploy';
  clearInterval(state.enemyTimer); state.enemyTimer = null;
  addLog(won ? 'SECTOR SECURED. Mission success.' : 'MORALE BROKEN. Reset and redeploy.');
  document.querySelector('#startWave').innerHTML = won ? 'MISSION COMPLETE' : '<span class="button-icon">▶</span> RETRY MISSION';
  updateUI();
}

function reset() {
  clearInterval(state.enemyTimer); clearTimeout(state.waveTimer);
  Object.assign(state, { supply: 240, morale: 84, wave: 1, phase: 'deploy', selected: 'ranger', paused: false, units: [], enemies: [], nextEnemyId: 1, waveTimer: null, enemyTimer: null });
  unitsLayer.innerHTML = ''; enemiesLayer.innerHTML = ''; document.querySelector('#startWave').innerHTML = '<span class="button-icon">▶</span> START WAVE';
  addLog('Mission reset. Awaiting deployment.'); updateUI();
}

battlefield.addEventListener('click', deploy);
document.querySelector('#unitCards').addEventListener('click', selectUnit);
document.querySelector('#startWave').addEventListener('click', () => state.phase === 'complete' ? reset() : startWave());
document.querySelector('#pauseGame').addEventListener('click', () => { if (state.phase !== 'battle') return; state.paused = !state.paused; document.querySelector('#pauseGame').textContent = state.paused ? '▶' : 'Ⅱ'; updateUI(); });
document.querySelector('#resetGame').addEventListener('click', reset);
document.addEventListener('keydown', (event) => { if (event.key.toLowerCase() === 'r') reset(); if (event.key === 'Escape' && state.phase === 'battle') { state.paused = !state.paused; document.querySelector('#pauseGame').textContent = state.paused ? '▶' : 'Ⅱ'; updateUI(); } });
addLog('Relay online. Awaiting field orders.'); addLog('Intel: hostile scouts, light armor.'); updateUI();

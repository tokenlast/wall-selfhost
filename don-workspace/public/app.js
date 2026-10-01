const wallView = document.querySelector('#wall-view');
const canvasStage = document.querySelector('#canvas-stage');
const inkLayer = document.querySelector('#ink-layer');
const inkContext = inkLayer.getContext('2d');
const gifLayer = document.querySelector('#gif-layer');
const wallNote = document.querySelector('#wall-note');
const wallGoons = document.querySelector('#wall-goons');
const wallWeather = document.querySelector('#wall-weather');
const wallTransit = document.querySelector('#wall-transit');
const wallSonos = document.querySelector('#wall-sonos');
const widgetLayer = document.querySelector('#widget-layer');
const wallDate = document.querySelector('#wall-date');
const wallTime = document.querySelector('#wall-time');
const clockBlock = document.querySelector('#clock-block');
const selectionToolbar = document.querySelector('#selection-toolbar');
const syncStatus = document.querySelector('#sync-status');
const drawToggle = document.querySelector('#draw-toggle');
const undoDrawing = document.querySelector('#undo-drawing');
const addGIF = document.querySelector('#add-gif');
const addWidget = document.querySelector('#add-widget');
const gifUpload = document.querySelector('#gif-upload');
const widgetPicker = document.querySelector('#widget-picker');
const widgetOptions = document.querySelector('#widget-options');
const goonPicker = document.querySelector('#goon-picker');
const goonOptions = document.querySelector('#goon-options');
const goonCelebration = document.querySelector('#goon-celebration');
const sonosSearchModal = document.querySelector('#sonos-search-modal');
const sonosSearchForm = document.querySelector('#sonos-search-form');
const sonosSearchInput = document.querySelector('#sonos-search-input');
const sonosSearchResults = document.querySelector('#sonos-search-results');
const musicSourceSpotify = document.querySelector('#music-source-spotify');
const musicSourceSoundCloud = document.querySelector('#music-source-soundcloud');
const settingsButton = document.querySelector('#settings');
const settingsModal = document.querySelector('#settings-modal');
const soundcloudSettingsForm = document.querySelector('#soundcloud-settings-form');
const soundcloudClientID = document.querySelector('#soundcloud-client-id');
const soundcloudClientSecret = document.querySelector('#soundcloud-client-secret');
const soundcloudStatus = document.querySelector('#soundcloud-status');
const soundcloudRedirect = document.querySelector('#soundcloud-redirect');
const soundcloudConnect = document.querySelector('#soundcloud-connect');

const photos = document.querySelector('#photos');
const template = document.querySelector('#photo-template');
const videoView = document.querySelector('#video-view');
const goonLog = document.querySelector('#goon-log');
const goonTotals = document.querySelector('#goon-totals');
const goonEvents = document.querySelector('#goon-events');
const goonEmpty = document.querySelector('#goon-empty');
const videoImage = document.querySelector('#video-image');
const videoTime = document.querySelector('#video-time');
const spotifyConnect = document.querySelector('#spotify-connect');
const status = document.querySelector('#status');

const viewButtons = {
  wall: document.querySelector('#wall'),
  photoBooth: document.querySelector('#booth'),
  video: document.querySelector('#video'),
  gallery: document.querySelector('#gallery'),
  icons: document.querySelector('#icons'),
  goons: document.querySelector('#goons'),
};

const CANVAS_WIDTH = 1024;
const CANVAS_HEIGHT = 768;
const MAX_VIDEO_FRAMES = 50;
let canvasDocument = null;
let canvasScope = 'wall';
let selectedObject = null;
let drawingEnabled = false;
let activeStroke = null;
let saveTimer = null;
let canvasDirty = false;
let saving = false;
let photoData = [];
let csrf = '';
let frameIndex = 0;
let loopTimer = null;
let preloadGeneration = 0;
const readyPhotoNames = new Set();
let goonData = { totals: {}, events: [] };
let dashboardData = { weather: null, transit: [] };
let horoscopeData = { readings: {} };
let rapidGoonTaps = [];
let goonCelebrationGeneration = 0;
let rapidGoonActiveUntil = 0;
let sonosState = {};
let sonosVolumeTimer = null;
let sonosModalTimer = null;
let settingsModalTimer = null;
let musicSearchSource = 'spotify';

const ELEMENT_SIZES = {
  clock: [650, 230], weather: [360, 82], transit: [660, 78], note: [390, 370],
  goonCounter: [310, 244], sonosNowPlaying: [520, 184],
};
const WIDGET_CATALOG = [
  ['date','Today','A large day and date',[270,132]], ['monthCalendar','Month','The current month at a glance',[292,238]],
  ['dayProgress','Day progress','How much of today has passed',[276,126]], ['yearProgress','Year progress','How much of this year has passed',[276,126]],
  ['battery','iPad battery','Charge level and power state',[220,120]], ['weatherDetails','Weather details','High, low, and rain chance',[280,150]],
  ['subwayStatus','Subway status','Active L and M alerts',[336,260]], ['voiceAssistant','Sift + Sonos','Private Sift connection status',[236,124]],
  ['focusTimer','Focus timer','A persistent 25-minute timer',[244,150]], ['stopwatch','Stopwatch','A persistent elapsed-time clock',[244,142]],
  ['midnightCountdown','Until midnight','Time remaining in the day',[268,126]], ['departureChecklist','Before you leave','Keys, wallet, phone, headphones',[290,218]],
  ['wifiQRCode','Wi-Fi QR','Guest Wi-Fi from the Wall note',[228,256]], ['moonPhase','Moon phase',"Tonight's lunar phase",[228,174]],
  ['worldTime','World time','New York, Los Angeles, and London',[276,188]], ['weekStrip','This week','Seven days, with today underlined',[360,130]],
  ['threeMonths','Three months','Last, current, and next month',[390,244]], ['weekNumber','Week number','Your ISO week, unreasonably large',[250,132]],
  ['dayOfYear','Day of year','Where today sits inside the year',[250,132]], ['astrologicalWeather','Astrological weather','A tiny cosmic mood report',[286,160]],
  ['mercuryMemo','Memo from Mercury','Questionable planetary correspondence',[286,160]], ['lacanianSignifier','Signifier of the day','One floating signifier',[286,160]],
  ['mirrorStage','Mirror stage','An amateur psychoanalytic mirror',[286,160]], ['desireOfOther','Desire of the Other','What the room imagines you want',[286,160]],
  ['dreamResidue','Dream residue','A generated fragment from last night',[286,160]], ['defenseMechanism','Defense mechanism','A playful mechanism of the moment',[286,160]],
  ['projection',"Today’s projection",'What you may be putting on the furniture',[286,160]], ['superegoForecast','Superego forecast','Internal weather, severe but unserious',[286,160]],
  ['strangeOracle','Strange oracle','Tap for an unhelpfully precise omen',[286,160]], ['unreliableNarrator','Unreliable narrator','A one-line rewrite of your day',[286,160]],
  ['dailyHoroscopes','Daily horoscopes','Casey, Drew, Alex, Blake, and Ellis',[680,590]],
];
const WIDGET_META = Object.fromEntries(WIDGET_CATALOG.map(([kind,title,detail,size]) => [kind,{title,detail,size}]));
const STRANGE_LINES = {
  astrologicalWeather:['The room is between aspects. Avoid replying all.','Venus is in a group chat it cannot leave.'],
  mercuryMemo:['Mercury left no forwarding address.','Read it twice before deciding it was a sign.'],
  lacanianSignifier:['the almost','elsewhere, but underlined'], mirrorStage:['You recognize yourself, but the image has better posture.'],
  desireOfOther:['to be interrupted','for someone else to choose the song','to leave before the ending explains itself'],
  dreamResidue:["A hallway, a receipt, someone else’s coat."], defenseMechanism:['Intellectualization, but make it decorative.'],
  projection:['The chair is not judging your calendar.'], superegoForecast:['High pressure, clearing after dinner.'],
  strangeOracle:['Do it, but put it somewhere reversible.'], unreliableNarrator:['By noon, she had already decided this was foreshadowing.'],
};

function scopeState() {
  return canvasDocument?.state?.[canvasScope] || {};
}

function ensureCanvasShape() {
  if (!canvasDocument) {
    canvasDocument = {
      version: 1,
      revision: 0,
      state: { schema: 1, wall: {}, photoBooth: {} },
    };
  }
  canvasDocument.state ||= { schema: 1, wall: {}, photoBooth: {} };
  canvasDocument.state.schema = 1;
  canvasDocument.state.wall ||= {};
  canvasDocument.state.photoBooth ||= {};
  for (const scope of ['wall', 'photoBooth']) {
    canvasDocument.state[scope].gifs ||= [];
    canvasDocument.state[scope].layers ||= [];
  }
  canvasDocument.state.wall.drawings ||= [];
  canvasDocument.state.wall.widgets ||= [];
  canvasDocument.state.wall.elements ||= [];
  canvasDocument.state.wall.note ||= { text: '', font: 'Helvetica', size: 28 };
}

function setSyncStatus(message, isError = false) {
  syncStatus.textContent = message;
  syncStatus.classList.toggle('error', isError);
}

function setView(view) {
  stopLoop();
  const isCanvas = view === 'wall' || view === 'photoBooth';
  canvasScope = view === 'photoBooth' ? 'photoBooth' : 'wall';
  wallView.hidden = !isCanvas;
  videoView.hidden = view !== 'video';
  photos.hidden = view !== 'gallery' && view !== 'icons';
  goonLog.hidden = view !== 'goons';
  if (view === 'gallery' || view === 'icons') photos.className = `photos ${view}`;
  for (const [name, button] of Object.entries(viewButtons)) button.classList.toggle('active', name === view);
  document.body.classList.toggle('photo-booth-canvas', view === 'photoBooth');
  if (view === 'video') startLoop();
  if (isCanvas) {
    selectedObject = null;
    renderCanvas();
  }
}

for (const [view, button] of Object.entries(viewButtons)) {
  button.addEventListener('click', () => setView(view));
}

function layerIndex(key, fallback) {
  const index = scopeState().layers.indexOf(key);
  return index >= 0 ? 100 + index : fallback;
}

function normalizedTransform(value, fallback) {
  return {
    normalizedX: Number.isFinite(value?.normalizedX) ? value.normalizedX : fallback.normalizedX,
    normalizedY: Number.isFinite(value?.normalizedY) ? value.normalizedY : fallback.normalizedY,
    scale: Number.isFinite(value?.scale) ? value.scale : 1,
    rotationDegrees: Number.isFinite(value?.rotationDegrees) ? value.rotationDegrees : 0,
  };
}

function elementTransforms() {
  const value = scopeState().elements;
  if (!Array.isArray(value)) return value || {};
  const decoded = {};
  for (let index = 0; index + 1 < value.length; index += 2) {
    if (typeof value[index] === 'string' && value[index + 1] && typeof value[index + 1] === 'object') decoded[value[index]] = value[index + 1];
  }
  return decoded;
}

function setElementTransform(id, transform) {
  const scope = scopeState();
  if (!Array.isArray(scope.elements)) {
    scope.elements ||= {};
    scope.elements[id] = transform;
    return;
  }
  const index = scope.elements.findIndex((value, position) => position % 2 === 0 && value === id);
  if (index >= 0) scope.elements[index + 1] = transform;
  else scope.elements.push(id, transform);
}

function isSelected(type, id) { return selectedObject?.type === type && selectedObject?.id === id; }
function selectionKey(selection = selectedObject) {
  if (!selection) return '';
  if (selection.type === 'element') return `element:${selection.id}`;
  return `${selection.type}:${selection.id.toLowerCase()}`;
}

function applyElementTransform(element, transform, baseWidth, baseHeight, zIndex) {
  element.style.left = `${transform.normalizedX * 100}%`;
  element.style.top = `${transform.normalizedY * 100}%`;
  element.style.width = `${baseWidth}px`;
  element.style.height = `${baseHeight}px`;
  element.style.transform = `translate(-50%, -50%) rotate(${transform.rotationDegrees}deg) scale(${transform.scale})`;
  element.style.zIndex = String(zIndex);
}

function applyGIFStyle(image, item, zIndex) {
  image.style.left = `${item.normalizedX * 100}%`;
  image.style.top = `${item.normalizedY * 100}%`;
  image.style.width = `${Math.max(1, item.naturalWidth * item.scale)}px`;
  image.style.height = 'auto';
  image.style.transform = `translate(-50%, -50%) rotate(${item.rotationDegrees}deg)`;
  image.style.zIndex = String(zIndex);
}

function renderCanvas() {
  if (!canvasDocument) return;
  ensureCanvasShape();
  const scope = scopeState();
  gifLayer.replaceChildren();
  widgetLayer.replaceChildren();

  for (const item of scope.gifs) {
    const image = document.createElement('img');
    image.className = 'wall-gif';
    image.src = `/canvas-assets/${item.asset}.gif`;
    image.alt = '';
    image.draggable = false;
    image.dataset.id = item.id;
    image.classList.toggle('selected', isSelected('gif', item.id));
    applyGIFStyle(image, item, layerIndex(`gif:${item.id.toLowerCase()}`, 200 + scope.gifs.indexOf(item)));
    installObjectGestures(image, 'gif', item);
    gifLayer.append(image);
  }

  const elements = elementTransforms();
  const clockTransform = normalizedTransform(elements.clock, { normalizedX: 0.22, normalizedY: 0.13 });
  applyElementTransform(clockBlock, clockTransform, ...ELEMENT_SIZES.clock, layerIndex('element:clock', 140));
  clockBlock.hidden = false;
  prepareCanvasObject(clockBlock, 'element', 'clock', clockTransform);

  if (canvasScope === 'wall') {
    const note = scope.note || {};
    wallNote.hidden = false;
    if (document.activeElement !== wallNote) wallNote.textContent = note.text || '';
    wallNote.style.fontFamily = `${note.font || 'Helvetica'}, Arial, sans-serif`;
    wallNote.style.fontSize = `${Math.min(64, Math.max(12, Number(note.size) || 28))}px`;
    const noteTransform = normalizedTransform(elements.note, { normalizedX: 0.78, normalizedY: 0.28 });
    applyElementTransform(wallNote, noteTransform, ...ELEMENT_SIZES.note, layerIndex('element:note', 150));
    prepareCanvasObject(wallNote, 'element', 'note', noteTransform, true);

    wallGoons.hidden = false;
    renderCanvasGoons();
    const goonTransform = normalizedTransform(elements.goonCounter, { normalizedX: 0.70, normalizedY: 0.72 });
    applyElementTransform(wallGoons, goonTransform, ...ELEMENT_SIZES.goonCounter, layerIndex('element:goonCounter', 160));
    prepareCanvasObject(wallGoons, 'element', 'goonCounter', goonTransform, true);

    renderWeather();
    const weatherTransform = normalizedTransform(elements.weather, { normalizedX: 0.21, normalizedY: 0.40 });
    applyElementTransform(wallWeather, weatherTransform, ...ELEMENT_SIZES.weather, layerIndex('element:weather', 145));
    prepareCanvasObject(wallWeather, 'element', 'weather', weatherTransform);

    renderTransit();
    const transitTransform = normalizedTransform(elements.transit, { normalizedX: 0.34, normalizedY: 0.50 });
    applyElementTransform(wallTransit, transitTransform, ELEMENT_SIZES.transit[0], Math.max(26, (dashboardData.transit.length || 1) * 26), layerIndex('element:transit', 146));
    prepareCanvasObject(wallTransit, 'element', 'transit', transitTransform);

    renderSonos();
    const sonosTransform = normalizedTransform(elements.sonosNowPlaying, { normalizedX: 0.29, normalizedY: 0.79 });
    applyElementTransform(wallSonos, sonosTransform, ...ELEMENT_SIZES.sonosNowPlaying, layerIndex('element:sonosNowPlaying', 161));
    prepareCanvasObject(wallSonos, 'element', 'sonosNowPlaying', sonosTransform, true);

    for (const item of scope.widgets || []) renderWidget(item);
    drawInk();
  } else {
    wallNote.hidden = true;
    wallGoons.hidden = true;
    wallWeather.hidden = true;
    wallTransit.hidden = true;
    wallSonos.hidden = true;
    inkContext.clearRect(0, 0, CANVAS_WIDTH, CANVAS_HEIGHT);
  }
  selectionToolbar.hidden = !selectedObject;
  document.querySelector('#delete-object').disabled = selectedObject?.type === 'element';
  undoDrawing.disabled = !(canvasDocument.state.wall.drawings || []).length;
}

function renderCanvasGoons() {
  wallGoons.replaceChildren();
  const head = document.createElement('div');
  head.className = 'goon-head';
  const title = document.createElement('span');
  title.textContent = 'GOON COUNTER';
  const trigger = document.createElement('button');
  trigger.type = 'button'; trigger.className = 'goon-trigger'; trigger.textContent = '😩'; trigger.ariaLabel = 'Adjust goon tallies';
  trigger.addEventListener('pointerdown', event => event.stopPropagation());
  trigger.onclick = event => { event.stopPropagation(); openGoonPicker(); };
  head.append(title, trigger);
  const rows = document.createElement('div'); rows.className = 'goon-rows';
  const ranked = Object.entries(goonData.totals || {}).sort((left, right) => right[1] - left[1]);
  for (const [person, count] of ranked) {
    const row = document.createElement('div');
    row.className = 'goon-row';
    const name = animatedName(person);
    const tallies = document.createElement('span'); tallies.className = `tallies person-${person}`; tallies.textContent = tallyText(count);
    const number = document.createElement('strong');
    number.className = `person-${person}`;
    number.textContent = String(count);
    row.append(name, tallies, number);
    rows.append(row);
  }
  wallGoons.append(head, rows);
}

function animatedName(person) {
  const name = document.createElement('span'); name.className = `animated-name person-${person}`;
  if (person === 'drew' || person === 'ellis') {
    [...person].forEach((letter, index) => { const span = document.createElement('span'); span.textContent = letter; span.style.setProperty('--letter', index); name.append(span); });
  } else name.textContent = person;
  return name;
}

function tallyText(count) {
  if (!count) return '—';
  const groups = [];
  for (let remaining = count; remaining > 0; remaining -= 5) groups.push(remaining >= 5 ? '||||̸' : '|'.repeat(Math.min(4, remaining)));
  return groups.join(' ');
}

function prepareCanvasObject(element, type, id, transform, interactive = false) {
  element.hidden = false;
  element.classList.add('canvas-object');
  element.classList.toggle('selected', isSelected(type, id));
  element.dataset.type = type; element.dataset.id = id;
  installObjectGestures(element, type, transform, id);
}

function renderWeather() {
  wallWeather.replaceChildren();
  const weather = dashboardData.weather;
  const top = document.createElement('div'); top.className = 'weather-top';
  const symbol = document.createElement('span'); symbol.className = `weather-symbol ${weather?.expectsRain ? 'umbrella' : 'sun'}`;
  const current = document.createElement('strong'); current.className = 'weather-current'; current.textContent = weather ? `${Math.round(weather.currentTemperature)}°` : '—'; symbol.append(current);
  const copy = document.createElement('span'); copy.className = 'weather-copy';
  const temperature = document.createElement('span'); temperature.textContent = weather ? `${Math.round(weather.high)}° / ${Math.round(weather.low)}°` : 'NYC weather';
  copy.append(temperature);
  if (weather) { const status = document.createElement('small'); status.textContent = `${weather.status} · ${weather.rainChance}% rain today`; copy.append(status); }
  top.append(symbol, copy); wallWeather.append(top);
  if (weather?.periods?.length) {
    const periods = document.createElement('div'); periods.className = 'weather-periods';
    for (const period of weather.periods) {
      const block = document.createElement('div'); block.className = 'weather-period';
      const date = new Date(period.time);
      const time = document.createElement('span'); time.textContent = date.toLocaleTimeString([], {hour:'numeric'}).toLowerCase();
      const icon = document.createElement('b'); icon.textContent = weatherGlyph(period.weatherCode); icon.title = period.status;
      const rain = document.createElement('strong'); rain.textContent = `${period.rainChance}%`;
      const temp = document.createElement('span'); temp.textContent = `${Math.round(period.temperature)}°`;
      block.append(time, icon, rain, temp); periods.append(block);
    }
    wallWeather.append(periods);
  }
}

function weatherGlyph(code) {
  if (code === 0) return '☀';
  if (code === 1 || code === 2) return '◒';
  if (code === 3 || code === 45 || code === 48) return '☁';
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return '☂';
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return '❄';
  if (code >= 95 && code <= 99) return 'ϟ';
  return '☁';
}

function renderTransit(target = wallTransit, expanded = false) {
  target.replaceChildren();
  const alerts = dashboardData.transit || [];
  if (!alerts.length) {
    const row = document.createElement('div'); row.className = 'transit-row';
    for (const route of ['L','M']) { const bullet = document.createElement('span'); bullet.className = `route-bullet route-${route}`; bullet.textContent = route; row.append(bullet); }
    const text = document.createElement('span'); text.textContent = 'no active alerts'; row.append(text); target.append(row); return;
  }
  for (const alert of alerts) {
    const row = document.createElement('div'); row.className = 'transit-row';
    for (const route of alert.routes || []) { const bullet = document.createElement('span'); bullet.className = `route-bullet route-${route}`; bullet.textContent = route; row.append(bullet); }
    const text = document.createElement('span'); text.className = 'transit-headline'; text.textContent = alert.headline; row.append(text); target.append(row);
    if (!expanded && target.childElementCount >= 3) break;
  }
}

function renderSonos() {
  wallSonos.replaceChildren();
  const art = document.createElement('div'); art.className = 'sonos-art'; art.textContent = '♪';
  const copy = document.createElement('div'); copy.className = 'sonos-copy';
  const title = document.createElement('strong'); title.textContent = sonosState.title || 'Nothing playing';
  const byline = document.createElement('small'); byline.textContent = [sonosState.artist, sonosState.album].filter(Boolean).join(' · ') || (sonosState.updated_at ? 'Living Room' : 'Waiting for Wall iPad'); copy.append(title, byline);
  const controls = document.createElement('div'); controls.className = 'sonos-controls';
  for (const [label, glyph, action] of [['previous','|‹','previous'],['play or pause',sonosState.isPlaying ? 'Ⅱ' : '▶','play_pause'],['next','›|','next'],['shuffle','↝','shuffle']]) {
    const button = document.createElement('button'); button.type = 'button'; button.className = 'square-control'; button.ariaLabel = label; button.textContent = glyph;
    if (action === 'shuffle') button.classList.toggle('active', Boolean(sonosState.isShuffleEnabled));
    button.addEventListener('pointerdown', event => event.stopPropagation());
    button.addEventListener('click', event => { event.stopPropagation(); sendSonosCommand({ action }); }); controls.append(button);
  }
  const volume = document.createElement('input'); volume.className = 'sonos-volume'; volume.type = 'range'; volume.min = '0'; volume.max = '100'; volume.value = String(sonosState.volume ?? 50); volume.ariaLabel = 'Sonos volume';
  volume.addEventListener('pointerdown', event => event.stopPropagation());
  volume.addEventListener('input', event => { event.stopPropagation(); window.clearTimeout(sonosVolumeTimer); sonosVolumeTimer = window.setTimeout(() => sendSonosCommand({ action:'volume', value:Number(volume.value) }), 120); }); controls.append(volume);
  const search = document.createElement('button'); search.type='button'; search.className='square-control'; search.textContent='⌕'; search.ariaLabel='Search music';
  search.addEventListener('pointerdown', event => event.stopPropagation()); search.addEventListener('click', event => { event.stopPropagation(); openSonosSearch(); }); controls.append(search);
  wallSonos.append(art, copy, controls);
}

async function sendSonosCommand(command) {
  setSyncStatus(command.action === 'spotify_radio' || command.action === 'soundcloud_play' ? 'starting music…' : 'sending to Sonos…');
  const response = await fetch('/api/sonos/commands', {
    method:'POST', credentials:'same-origin',
    headers:{'Content-Type':'application/json','X-CSRF-Token':csrf}, body:JSON.stringify(command),
  });
  if (!response.ok) { setSyncStatus('Sonos command failed.', true); return false; }
  setSyncStatus('sent to Living Room');
  window.setTimeout(() => loadSonosState().catch(() => {}), 900);
  return true;
}

async function loadSonosState() {
  const response = await fetch('/api/sonos/state', { credentials:'same-origin', cache:'no-store' });
  if (!response.ok) throw new Error('Sonos unavailable');
  const data = await response.json();
  sonosState = data.state || {};
  if (canvasDocument && canvasScope === 'wall') renderSonos();
}

function openSonosSearch() {
  sonosSearchModal.hidden = false;
  sonosSearchInput.focus();
  resetSonosModalTimer();
}

function selectMusicSearchSource(source) {
  musicSearchSource = source === 'soundcloud' ? 'soundcloud' : 'spotify';
  musicSourceSpotify.classList.toggle('active', musicSearchSource === 'spotify');
  musicSourceSoundCloud.classList.toggle('active', musicSearchSource === 'soundcloud');
  musicSourceSpotify.setAttribute('aria-selected', String(musicSearchSource === 'spotify'));
  musicSourceSoundCloud.setAttribute('aria-selected', String(musicSearchSource === 'soundcloud'));
  sonosSearchInput.placeholder = `search ${musicSearchSource}`;
  sonosSearchResults.replaceChildren();
  sonosSearchInput.focus();
  resetSonosModalTimer();
}

function resetSonosModalTimer() {
  window.clearTimeout(sonosModalTimer);
  sonosModalTimer = window.setTimeout(() => { sonosSearchModal.hidden = true; }, 20_000);
}

sonosSearchModal.addEventListener('pointerdown', event => { resetSonosModalTimer(); if (event.target === sonosSearchModal) sonosSearchModal.hidden = true; });
sonosSearchModal.querySelector('.close-modal').addEventListener('click', () => { sonosSearchModal.hidden = true; });
musicSourceSpotify.addEventListener('click', () => selectMusicSearchSource('spotify'));
musicSourceSoundCloud.addEventListener('click', () => selectMusicSearchSource('soundcloud'));
sonosSearchForm.addEventListener('submit', async event => {
  event.preventDefault(); resetSonosModalTimer();
  const query = sonosSearchInput.value.trim(); if (!query) return;
  sonosSearchResults.textContent = 'searching…';
  const endpoint = musicSearchSource === 'soundcloud' ? '/api/soundcloud/search' : '/api/sonos/search';
  const response = await fetch(`${endpoint}?q=${encodeURIComponent(query)}`, { credentials:'same-origin', cache:'no-store' });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) { sonosSearchResults.textContent = data.error || 'search unavailable'; return; }
  renderSonosSearchResults(musicSearchSource === 'soundcloud' ? (data.tracks || []) : (data.tracks?.items || []), musicSearchSource);
});

function renderSonosSearchResults(items, source) {
  sonosSearchResults.replaceChildren();
  for (const item of items.filter(Boolean).slice(0, 12)) {
    if (!item.id || source === 'spotify' && item.type && item.type !== 'track') continue;
    const row = document.createElement('div'); row.className='sonos-search-result';
    const play = document.createElement('button'); play.type='button'; play.className='sonos-result-copy';
    const trackName = source === 'soundcloud' ? item.title : item.name;
    const artistName = source === 'soundcloud' ? item.artist : (item.artists||[]).map(value=>value.name).join(', ');
    const strong=document.createElement('strong');strong.textContent=trackName||'Track';
    const small=document.createElement('small');small.textContent=artistName||source;
    play.append(strong,small);
    const queue=document.createElement('button');queue.type='button';queue.className='sonos-result-queue';queue.textContent='+ queue';
    const command = action => source === 'soundcloud'
      ? {action,reference:item.id,title:`${trackName} by ${artistName}`}
      : {action,reference:`spotify:track:${item.id}`,title:`${trackName} by ${artistName}`};
    const playAction = source === 'soundcloud' ? 'soundcloud_play' : 'spotify_radio';
    const queueAction = source === 'soundcloud' ? 'soundcloud_queue' : 'spotify_queue';
    play.addEventListener('click',async()=>{if(await sendSonosCommand(command(playAction)))sonosSearchModal.hidden=true;});
    queue.addEventListener('click',()=>sendSonosCommand(command(queueAction)));
    row.append(play,queue);sonosSearchResults.append(row);
  }
  if (!sonosSearchResults.childElementCount) sonosSearchResults.textContent='no results';
}

function renderWidget(item) {
  const meta = WIDGET_META[item.kind] || { title: item.kind, detail: '', size: [286,160] };
  const element = document.createElement('section'); element.className = 'wall-widget canvas-object'; element.dataset.id = item.id;
  element.classList.toggle('selected', isSelected('widget', item.id));
  applyElementTransform(element, item, ...meta.size, layerIndex(`widget:${item.id.toLowerCase()}`, 180 + scopeState().widgets.indexOf(item)));
  buildWidgetContent(element, item, meta);
  installObjectGestures(element, 'widget', item);
  widgetLayer.append(element);
}

function widgetShell(target, title) {
  const shell = document.createElement('div'); shell.className = 'widget-shell';
  const heading = document.createElement('div'); heading.className = 'widget-title'; heading.textContent = title;
  const body = document.createElement('div'); body.className = 'widget-body'; shell.append(heading, body); target.append(shell); return body;
}

function buildWidgetContent(target, item, meta) {
  const now = new Date();
  if (item.kind === 'desireOfOther') { const body = document.createElement('div'); body.className = 'desire-widget'; body.textContent = dailyLine(item.kind); target.append(body); return; }
  if (item.kind === 'dailyHoroscopes') {
    const shell = document.createElement('div'); shell.className = 'widget-shell';
    for (const person of ['casey','drew','alex','blake','ellis']) { const row = document.createElement('div'); row.className = 'horoscope-row'; const text = document.createElement('p'); text.textContent = horoscopeData.readings?.[person] || 'The sky is checking its notes.'; row.append(animatedName(person), text); shell.append(row); }
    target.append(shell); return;
  }
  if (item.kind === 'date') {
    const shell = document.createElement('div'); shell.className = 'widget-shell';
    const body = document.createElement('div'); body.className = 'widget-body date-widget-body';
    const big = document.createElement('div'); big.className='widget-big'; big.textContent=String(now.getDate());
    const sub=document.createElement('div');sub.className='widget-sub';sub.textContent=now.toLocaleDateString(undefined,{weekday:'long',month:'long',year:'numeric'});
    body.append(big,sub); shell.append(body); target.append(shell); return;
  }
  const body = widgetShell(target, meta.title);
  if (item.kind === 'monthCalendar') return buildCalendar(body, now);
  if (item.kind === 'dayProgress' || item.kind === 'yearProgress') {
    const start = item.kind === 'dayProgress' ? new Date(now.getFullYear(),now.getMonth(),now.getDate()) : new Date(now.getFullYear(),0,1);
    const end = item.kind === 'dayProgress' ? new Date(now.getFullYear(),now.getMonth(),now.getDate()+1) : new Date(now.getFullYear()+1,0,1);
    const progress = Math.max(0,Math.min(1,(now-start)/(end-start))); const big=document.createElement('div');big.className='widget-big';big.textContent=`${Math.round(progress*100)}%`; const meter=document.createElement('div');meter.className='widget-meter';const fill=document.createElement('span');fill.style.width=`${progress*100}%`;meter.append(fill);body.append(big,meter);return;
  }
  if (item.kind === 'battery') { const big=document.createElement('div');big.className='widget-big';big.textContent='—%'; body.append(big); navigator.getBattery?.().then(value=>{big.textContent=`${Math.round(value.level*100)}%`;}); return; }
  if (item.kind === 'weatherDetails') { const weather=dashboardData.weather; body.textContent=weather?`${Math.round(weather.currentTemperature)}° now · ${weather.status}\n${Math.round(weather.high)}° high · ${Math.round(weather.low)}° low · ${weather.rainChance}% rain`:'NYC weather is loading.';body.style.whiteSpace='pre-line';return; }
  if (item.kind === 'subwayStatus') { renderTransit(body,true); return; }
  if (item.kind === 'voiceAssistant') { body.textContent='Sift + Sonos connected through the Wall iPad.'; return; }
  if (item.kind === 'focusTimer') return buildFocusTimer(body);
  if (item.kind === 'stopwatch') return buildStopwatch(body);
  if (item.kind === 'midnightCountdown') { const big=document.createElement('div');big.className='widget-big';big.dataset.clock='midnight';body.append(big);updateInteractiveClocks();return; }
  if (item.kind === 'departureChecklist') return buildChecklist(body);
  if (item.kind === 'wifiQRCode') { body.textContent='Guest Wi-Fi lives in the Wall note.'; return; }
  if (item.kind === 'moonPhase') { const big=document.createElement('div');big.className='widget-big';big.textContent=moonPhase(now);const sub=document.createElement('div');sub.className='widget-sub';sub.textContent='tonight';body.append(big,sub);return; }
  if (item.kind === 'worldTime') { for(const [city,zone] of [['new york','America/New_York'],['los angeles','America/Los_Angeles'],['london','Europe/London']]){const row=document.createElement('div');row.className='goon-row';const name=document.createElement('span');name.textContent=city;const time=document.createElement('strong');time.dataset.zone=zone;row.append(name,time);body.append(row);}updateInteractiveClocks();return; }
  if (item.kind === 'weekStrip') return buildWeekStrip(body,now);
  if (item.kind === 'threeMonths') { body.textContent=[-1,0,1].map(offset=>new Date(now.getFullYear(),now.getMonth()+offset,1).toLocaleDateString(undefined,{month:'long',year:'numeric'})).join('\n');body.style.whiteSpace='pre-line';return; }
  if (item.kind === 'weekNumber') { const big=document.createElement('div');big.className='widget-big';big.textContent=String(isoWeek(now));body.append(big);return; }
  if (item.kind === 'dayOfYear') { const big=document.createElement('div');big.className='widget-big';big.textContent=String(Math.floor((now-new Date(now.getFullYear(),0,0))/86400000));body.append(big);return; }
  const line=document.createElement('div');line.textContent=dailyLine(item.kind);body.append(line);
  if (item.kind === 'strangeOracle') { target.addEventListener('click',event=>{if(isSelected('widget',item.id))return;event.stopPropagation();item.oracleNonce=(item.oracleNonce||0)+1;line.textContent=dailyLine(item.kind,item.oracleNonce);}); }
}

function dailyLine(kind, nonce=0) { const lines=STRANGE_LINES[kind]||['The sign is loading.'];const day=Math.floor(Date.now()/86400000);return lines[(day+nonce)%lines.length]; }
function buildCalendar(body,date){const grid=document.createElement('div');grid.className='widget-calendar';for(const day of ['S','M','T','W','T','F','S']){const cell=document.createElement('b');cell.textContent=day;grid.append(cell);}const first=new Date(date.getFullYear(),date.getMonth(),1).getDay();for(let i=0;i<first;i++)grid.append(document.createElement('span'));const days=new Date(date.getFullYear(),date.getMonth()+1,0).getDate();for(let day=1;day<=days;day++){const cell=document.createElement('span');cell.textContent=day;if(day===date.getDate())cell.className='today';grid.append(cell);}body.append(grid);}
function buildWeekStrip(body,date){const grid=document.createElement('div');grid.className='widget-calendar';const start=new Date(date);start.setDate(date.getDate()-date.getDay());for(let i=0;i<7;i++){const day=new Date(start);day.setDate(start.getDate()+i);const cell=document.createElement('span');cell.textContent=`${day.toLocaleDateString(undefined,{weekday:'short'})}\n${day.getDate()}`;cell.style.whiteSpace='pre-line';if(day.toDateString()===date.toDateString())cell.className='today';grid.append(cell);}body.append(grid);}
function buildFocusTimer(body){const big=document.createElement('div');big.className='widget-big';big.dataset.clock='focus';const actions=document.createElement('div');actions.className='widget-actions';const toggle=document.createElement('button');toggle.textContent='start';toggle.addEventListener('click',event=>{event.stopPropagation();const end=Number(localStorage.getItem('wall-focus-end')||0);if(end>Date.now()){localStorage.removeItem('wall-focus-end');toggle.textContent='start';}else{localStorage.setItem('wall-focus-end',String(Date.now()+25*60000));toggle.textContent='pause';}updateInteractiveClocks();});actions.append(toggle);body.append(big,actions);updateInteractiveClocks();}
function buildStopwatch(body){const big=document.createElement('div');big.className='widget-big';big.dataset.clock='stopwatch';const actions=document.createElement('div');actions.className='widget-actions';for(const [label,action] of [['start',()=>localStorage.setItem('wall-stopwatch-start',String(Date.now()))],['reset',()=>localStorage.removeItem('wall-stopwatch-start')]]){const button=document.createElement('button');button.textContent=label;button.addEventListener('click',event=>{event.stopPropagation();action();updateInteractiveClocks();});actions.append(button);}body.append(big,actions);updateInteractiveClocks();}
function buildChecklist(body){const list=document.createElement('div');list.className='widget-list';const saved=JSON.parse(localStorage.getItem('wall-checklist')||'{}');for(const name of ['keys','wallet','phone','headphones']){const button=document.createElement('button');button.classList.toggle('done',Boolean(saved[name]));button.textContent=`${saved[name]?'✓':'□'} ${name}`;button.addEventListener('click',event=>{event.stopPropagation();saved[name]=!saved[name];localStorage.setItem('wall-checklist',JSON.stringify(saved));renderCanvas();});list.append(button);}body.append(list);}
function moonPhase(date){const known=new Date('2000-01-06T18:14:00Z');const phase=((date-known)/86400000)%29.53058867;return ['●','◔','◑','◕','○','◕','◑','◔'][Math.floor(((phase+29.53058867)%29.53058867)/29.53058867*8)%8];}
function isoWeek(date){const value=new Date(Date.UTC(date.getFullYear(),date.getMonth(),date.getDate()));value.setUTCDate(value.getUTCDate()+4-(value.getUTCDay()||7));return Math.ceil((((value-new Date(Date.UTC(value.getUTCFullYear(),0,1)))/86400000)+1)/7);}
function updateInteractiveClocks(){const now=Date.now();document.querySelectorAll('[data-clock="midnight"]').forEach(el=>{const date=new Date();const end=new Date(date.getFullYear(),date.getMonth(),date.getDate()+1);el.textContent=formatDuration(end-now);});document.querySelectorAll('[data-clock="focus"]').forEach(el=>{const end=Number(localStorage.getItem('wall-focus-end')||0);el.textContent=formatDuration(Math.max(0,end-now)||25*60000);});document.querySelectorAll('[data-clock="stopwatch"]').forEach(el=>{const start=Number(localStorage.getItem('wall-stopwatch-start')||0);el.textContent=formatDuration(start?now-start:0);});document.querySelectorAll('[data-zone]').forEach(el=>{el.textContent=new Date().toLocaleTimeString([],{timeZone:el.dataset.zone,hour:'numeric',minute:'2-digit'});});}
function formatDuration(ms){const total=Math.max(0,Math.floor(ms/1000));const hours=Math.floor(total/3600);const minutes=Math.floor(total%3600/60);const seconds=total%60;return hours?`${hours}:${String(minutes).padStart(2,'0')}:${String(seconds).padStart(2,'0')}`:`${minutes}:${String(seconds).padStart(2,'0')}`;}

function stagePoint(event) {
  const rect = canvasStage.getBoundingClientRect();
  return {
    x: Math.min(CANVAS_WIDTH, Math.max(0, (event.clientX - rect.left) * CANVAS_WIDTH / rect.width)),
    y: Math.min(CANVAS_HEIGHT, Math.max(0, (event.clientY - rect.top) * CANVAS_HEIGHT / rect.height)),
  };
}

function installObjectGestures(element, type, item, explicitID = null) {
  if (element.dataset.gestures === '1') return;
  element.dataset.gestures = '1';
  let holdTimer = null;
  let holdStart = null;
  const pointers = new Map();
  let gestureOrigin = null;
  const id = explicitID || item.id;

  function select() {
    selectedObject = { type, id };
    renderCanvas();
  }

  function beginTransform() {
    const values = [...pointers.values()];
    gestureOrigin = {
      x: item.normalizedX,
      y: item.normalizedY,
      scale: item.scale,
      rotation: item.rotationDegrees,
      points: values.map(point => ({ ...point })),
    };
  }

  element.addEventListener('dblclick', event => {
    event.preventDefault();
    select();
  });

  element.addEventListener('pointerdown', event => {
    event.stopPropagation();
    element.setPointerCapture(event.pointerId);
    const point = stagePoint(event);
    if (!isSelected(type, id)) {
      holdStart = point;
      holdTimer = window.setTimeout(select, 420);
      return;
    }
    event.preventDefault();
    pointers.set(event.pointerId, point);
    beginTransform();
  });

  element.addEventListener('pointermove', event => {
    const point = stagePoint(event);
    if (holdTimer && holdStart && Math.hypot(point.x - holdStart.x, point.y - holdStart.y) > 9) {
      window.clearTimeout(holdTimer);
      holdTimer = null;
    }
    if (!pointers.has(event.pointerId) || !gestureOrigin) return;
    pointers.set(event.pointerId, point);
    const current = [...pointers.values()];
    if (current.length === 1) {
      item.normalizedX = Math.min(1, Math.max(0, gestureOrigin.x + (current[0].x - gestureOrigin.points[0].x) / CANVAS_WIDTH));
      item.normalizedY = Math.min(1, Math.max(0, gestureOrigin.y + (current[0].y - gestureOrigin.points[0].y) / CANVAS_HEIGHT));
    } else {
      const startA = gestureOrigin.points[0];
      const startB = gestureOrigin.points[1] || startA;
      const nowA = current[0];
      const nowB = current[1];
      const startDistance = Math.max(1, Math.hypot(startB.x - startA.x, startB.y - startA.y));
      const nowDistance = Math.max(1, Math.hypot(nowB.x - nowA.x, nowB.y - nowA.y));
      item.scale = Math.min(20, Math.max(0.05, gestureOrigin.scale * nowDistance / startDistance));
      const startAngle = Math.atan2(startB.y - startA.y, startB.x - startA.x);
      const nowAngle = Math.atan2(nowB.y - nowA.y, nowB.x - nowA.x);
      item.rotationDegrees = gestureOrigin.rotation + (nowAngle - startAngle) * 180 / Math.PI;
    }
    if (type === 'gif') {
      applyGIFStyle(element, item, layerIndex(`gif:${id.toLowerCase()}`, 200 + scopeState().gifs.indexOf(item)));
    } else {
      if (type === 'element') setElementTransform(id, item);
      const size = type === 'widget' ? WIDGET_META[item.kind]?.size || [286, 160] : ELEMENT_SIZES[id] || [286, 160];
      applyElementTransform(element, item, ...size, layerIndex(selectionKey({ type, id }), 170));
    }
    markCanvasDirty();
  });

  function endPointer(event) {
    if (holdTimer) window.clearTimeout(holdTimer);
    holdTimer = null;
    holdStart = null;
    if (pointers.delete(event.pointerId)) {
      if (pointers.size) beginTransform();
      else gestureOrigin = null;
      renderCanvas();
      scheduleCanvasSave();
    }
  }
  element.addEventListener('pointerup', endPointer);
  element.addEventListener('pointercancel', endPointer);
}

function selectedItem() {
  if (!selectedObject) return null;
  if (selectedObject.type === 'gif') return scopeState().gifs.find(item => item.id === selectedObject.id);
  if (selectedObject.type === 'widget') return (scopeState().widgets || []).find(item => item.id === selectedObject.id);
  return elementTransforms()[selectedObject.id] || null;
}

function updateLayer(action) {
  const item = selectedItem();
  if (!item) return;
  const scope = scopeState();
  const key = selectionKey();
  scope.layers = scope.layers.filter(value => value !== key);
  if (action === 'front') scope.layers.push(key);
  else scope.layers.unshift(key);
  markCanvasDirty();
  renderCanvas();
  scheduleCanvasSave();
}

document.querySelector('#send-back').addEventListener('click', () => updateLayer('back'));
document.querySelector('#bring-front').addEventListener('click', () => updateLayer('front'));
document.querySelector('#snap-rotation').addEventListener('click', () => {
  const item = selectedItem();
  if (!item) return;
  const snaps = [0, 45, 90, 135, 180];
  const normalized = ((item.rotationDegrees % 360) + 360) % 360;
  item.rotationDegrees = snaps.reduce((best, angle) => Math.abs(angle - normalized) < Math.abs(best - normalized) ? angle : best, 0);
  if (selectedObject.type === 'element') setElementTransform(selectedObject.id, item);
  markCanvasDirty();
  renderCanvas();
  scheduleCanvasSave();
});
document.querySelector('#delete-object').addEventListener('click', () => {
  if (!selectedObject || selectedObject.type === 'element') return;
  const scope = scopeState();
  if (selectedObject.type === 'gif') scope.gifs = scope.gifs.filter(item => item.id !== selectedObject.id);
  if (selectedObject.type === 'widget') scope.widgets = (scope.widgets || []).filter(item => item.id !== selectedObject.id);
  scope.layers = scope.layers.filter(key => key !== selectionKey());
  selectedObject = null;
  markCanvasDirty();
  renderCanvas();
  scheduleCanvasSave();
});

canvasStage.addEventListener('pointerdown', event => {
  if (drawingEnabled && canvasScope === 'wall' && (event.target === canvasStage || event.target === inkLayer || event.target === gifLayer || event.target === widgetLayer)) {
    event.preventDefault();
    canvasStage.setPointerCapture(event.pointerId);
    activeStroke = { id: crypto.randomUUID(), color: 'black', points: [stagePoint(event)] };
    canvasDocument.state.wall.drawings.push(activeStroke);
    drawInk();
    return;
  }
  if (event.target === canvasStage || event.target === inkLayer || event.target === gifLayer || event.target === widgetLayer) {
    selectedObject = null;
    renderCanvas();
  }
});
canvasStage.addEventListener('pointermove', event => {
  if (!activeStroke) return;
  activeStroke.points.push(stagePoint(event));
  drawInk();
});
function finishStroke() {
  if (!activeStroke) return;
  activeStroke = null;
  markCanvasDirty();
  scheduleCanvasSave();
}
canvasStage.addEventListener('pointerup', finishStroke);
canvasStage.addEventListener('pointercancel', finishStroke);

function drawInk() {
  inkContext.clearRect(0, 0, CANVAS_WIDTH, CANVAS_HEIGHT);
  inkContext.lineWidth = 3;
  inkContext.lineCap = 'round';
  inkContext.lineJoin = 'round';
  const colors = { black: '#000', red: '#d11414', blue: '#103fd1', green: '#0d7a33', orange: '#f05a08', purple: '#7a1fad' };
  for (const stroke of canvasDocument?.state?.wall?.drawings || []) {
    if (!Array.isArray(stroke.points) || !stroke.points.length) continue;
    inkContext.beginPath();
    inkContext.strokeStyle = colors[stroke.color] || '#000';
    inkContext.moveTo(stroke.points[0].x, stroke.points[0].y);
    for (const point of stroke.points.slice(1)) inkContext.lineTo(point.x, point.y);
    inkContext.stroke();
  }
}

drawToggle.addEventListener('click', () => {
  drawingEnabled = !drawingEnabled;
  drawToggle.classList.toggle('active', drawingEnabled);
  canvasStage.classList.toggle('drawing', drawingEnabled);
});
undoDrawing.addEventListener('click', () => {
  const drawings = canvasDocument.state.wall.drawings;
  if (!drawings.length) return;
  drawings.pop();
  markCanvasDirty();
  drawInk();
  renderCanvas();
  scheduleCanvasSave();
});

wallNote.addEventListener('click', () => {
  if (canvasScope !== 'wall' || drawingEnabled) return;
  wallNote.contentEditable = 'plaintext-only';
  wallNote.focus();
});
wallNote.addEventListener('blur', () => {
  wallNote.removeAttribute('contenteditable');
  canvasDocument.state.wall.note.text = wallNote.textContent;
  markCanvasDirty();
  scheduleCanvasSave();
});
wallNote.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') wallNote.blur();
});

function openWidgetPicker() {
  widgetOptions.replaceChildren();
  const existing = new Set((canvasDocument.state.wall.widgets || []).map(item => item.kind));
  for (const [kind, title, detail] of WIDGET_CATALOG) {
    const button = document.createElement('button'); button.type = 'button'; button.className = 'widget-option'; button.disabled = existing.has(kind);
    const copy = document.createElement('span'); const strong = document.createElement('strong'); strong.textContent = title; const small = document.createElement('small'); small.textContent = detail; copy.append(strong, small);
    const action = document.createElement('span'); action.textContent = existing.has(kind) ? 'added' : 'add'; button.append(copy, action);
    button.addEventListener('click', () => { addWallWidget(kind); widgetPicker.hidden = true; }); widgetOptions.append(button);
  }
  widgetPicker.hidden = false;
}

function addWallWidget(kind) {
  if ((canvasDocument.state.wall.widgets || []).some(item => item.kind === kind)) return;
  const item = { id: crypto.randomUUID(), kind, normalizedX: .5, normalizedY: .5, scale: 1, rotationDegrees: 0 };
  canvasDocument.state.wall.widgets.push(item); canvasDocument.state.wall.layers.push(`widget:${item.id.toLowerCase()}`); selectedObject = { type: 'widget', id: item.id };
  markCanvasDirty(); renderCanvas(); scheduleCanvasSave();
}

addWidget.addEventListener('click', openWidgetPicker);
for (const modal of [widgetPicker, goonPicker]) {
  modal.addEventListener('pointerdown', event => { if (event.target === modal) modal.hidden = true; });
  modal.querySelector('.close-modal').addEventListener('click', () => { modal.hidden = true; });
}

function openGoonPicker() {
  goonOptions.replaceChildren();
  for (const person of ['alex','blake','casey','drew','ellis']) {
    const row = document.createElement('div'); row.className = 'goon-option';
    const name = animatedName(person); const count = document.createElement('span'); count.className = `person-${person}`; count.textContent = String(goonData.totals?.[person] || 0);
    const buttons = [];
    for (const [action, glyph] of [['remove','−'],['add','+']]) { const button=document.createElement('button');button.type='button';button.textContent=glyph;button.ariaLabel=`${action} one for ${person}`;button.addEventListener('click',()=>adjustGoon(person,action));buttons.push(button); }
    row.append(name, count, ...buttons);
    goonOptions.append(row);
  }
  goonPicker.hidden = false;
}

async function adjustGoon(person, action) {
  const response = await fetch('/api/goons', { method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json','X-CSRF-Token':csrf}, body:JSON.stringify({id:crypto.randomUUID(),person,action,occurred_at:new Date().toISOString()}) });
  if (!response.ok) { setSyncStatus('Goon counter did not save.', true); return; }
  if (action === 'add') celebrateGoon();
  const data = await fetch('/api/goons',{credentials:'same-origin'}).then(value=>value.json()); renderGoonLog(data); openGoonPicker();
}

function celebrateGoon() {
  const now = Date.now();
  // Match the native app: once a combo starts, a stray fourth tap must not
  // replace it with the shorter single-point splash.
  if (now < rapidGoonActiveUntil) return;
  const generation = ++goonCelebrationGeneration;
  rapidGoonTaps = rapidGoonTaps.filter(value => now-value <= 5000); rapidGoonTaps.push(now);
  const rapid = rapidGoonTaps.length >= 3; if (rapid) rapidGoonTaps = [];
  if (rapid) rapidGoonActiveUntil = now + 5000;
  goonCelebration.replaceChildren(); goonCelebration.classList.add('visible');
  if (!rapid) { const grid=document.createElement('div');grid.className='splash-grid';for(let i=0;i<42;i++){const emoji=document.createElement('span');emoji.textContent='💦';grid.append(emoji);}goonCelebration.append(grid);setTimeout(()=>{if(generation===goonCelebrationGeneration)goonCelebration.classList.remove('visible');},1200);return; }
  let phase=0; const render=()=>{if(generation!==goonCelebrationGeneration)return;goonCelebration.replaceChildren();const emoji=phase%2===0?'🍆':'🍑';const grid=document.createElement('div');grid.className='rapid-grid';for(let i=0;i<48;i++){const value=document.createElement('span');value.textContent=emoji;grid.append(value);}const main=document.createElement('div');main.className='rapid-main';main.textContent=emoji;goonCelebration.append(grid,main);phase+=1;if(phase<10)setTimeout(render,500);else setTimeout(()=>{if(generation===goonCelebrationGeneration){rapidGoonActiveUntil=0;goonCelebration.classList.remove('visible');}},500);};render();
}

async function loadHoroscopes() {
  const response = await fetch('/api/horoscopes', { credentials: 'same-origin', cache: 'no-store' });
  if (!response.ok) throw new Error('horoscope refresh failed');
  horoscopeData = await response.json();
  renderCanvas();
}

async function loadDashboard() {
  const response = await fetch('/api/dashboard', { credentials: 'same-origin', cache: 'no-store' });
  if (!response.ok) throw new Error('dashboard refresh failed');
  dashboardData = await response.json();
  renderCanvas();
}

addGIF.addEventListener('click', () => gifUpload.click());
gifUpload.addEventListener('change', async () => {
  const file = gifUpload.files[0];
  gifUpload.value = '';
  if (!file || file.type !== 'image/gif' || file.size > 15 * 1024 * 1024) {
    setSyncStatus('That GIF cannot be added.', true);
    return;
  }
  setSyncStatus('adding gif…');
  try {
    const response = await fetch('/api/canvas/assets', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'image/gif', 'X-CSRF-Token': csrf },
      body: file,
    });
    if (!response.ok) throw new Error('upload failed');
    const asset = await response.json();
    const dimensions = await imageDimensions(file);
    const item = {
      id: crypto.randomUUID(), asset: asset.asset,
      naturalWidth: dimensions.width, naturalHeight: dimensions.height,
      normalizedX: 0.5, normalizedY: 0.5, scale: 1, rotationDegrees: 0,
    };
    scopeState().gifs.push(item);
    scopeState().layers.push(`gif:${item.id.toLowerCase()}`);
    selectedObject = { type: 'gif', id: item.id };
    markCanvasDirty();
    renderCanvas();
    await saveCanvas();
    setSyncStatus('gif added');
  } catch (_) {
    setSyncStatus('GIF upload failed.', true);
  }
});

function imageDimensions(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => {
      URL.revokeObjectURL(url);
      resolve({ width: image.naturalWidth, height: image.naturalHeight });
    };
    image.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error('invalid image'));
    };
    image.src = url;
  });
}

function markCanvasDirty() {
  canvasDirty = true;
  setSyncStatus('saving…');
}

function scheduleCanvasSave() {
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(saveCanvas, 650);
}

async function saveCanvas() {
  window.clearTimeout(saveTimer);
  if (!canvasDirty || saving || !canvasDocument) return;
  saving = true;
  try {
    const response = await fetch('/api/canvas', {
      method: 'PUT', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
      body: JSON.stringify({ base_revision: canvasDocument.revision, state: canvasDocument.state }),
    });
    const data = await response.json();
    if (response.status === 409) {
      canvasDocument = data.current;
      ensureCanvasShape();
      canvasDirty = false;
      selectedObject = null;
      renderCanvas();
      setSyncStatus('updated from another screen');
      return;
    }
    if (!response.ok) throw new Error(data.error || 'save failed');
    canvasDocument.revision = data.revision;
    canvasDocument.updated_at = data.updated_at;
    canvasDirty = false;
    setSyncStatus('saved');
  } catch (_) {
    setSyncStatus('not saved — retrying', true);
    scheduleCanvasSave();
  } finally {
    saving = false;
  }
}

async function loadCanvas({ quiet = false } = {}) {
  try {
    const response = await fetch('/api/canvas', { credentials: 'same-origin' });
    if (!response.ok) throw new Error('canvas unavailable');
    const data = await response.json();
    csrf = data.csrf || csrf;
    if (!canvasDirty && canvasDocument && data.revision > canvasDocument.revision) {
      window.location.reload();
      return;
    }
    if (!canvasDirty && !canvasDocument) {
      canvasDocument = data;
      ensureCanvasShape();
      renderCanvas();
    }
    if (!quiet) setSyncStatus('saved');
  } catch (_) {
    if (!quiet) setSyncStatus('cloud unavailable', true);
  }
}

window.setInterval(() => { if (!canvasDirty && !saving) loadCanvas({ quiet: true }); }, 10_000);
window.addEventListener('pagehide', () => { if (canvasDirty) saveCanvas(); });

function updateClock() {
  const now = new Date();
  wallDate.textContent = now.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  wallTime.textContent = now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  updateInteractiveClocks();
}
updateClock();
window.setInterval(updateClock, 1_000);

function stopLoop() {
  if (loopTimer) window.clearInterval(loopTimer);
  loopTimer = null;
}
function playbackCandidates() { return photoData.filter(photo => !photo.hidden).slice(0, MAX_VIDEO_FRAMES); }
function playablePhotos() { return playbackCandidates().filter(photo => readyPhotoNames.has(photo.name)); }
function showFrame() {
  const frames = playablePhotos();
  if (!frames.length) {
    videoImage.removeAttribute('src');
    videoTime.textContent = photoData.length ? 'Loading fit pics…' : 'No fit pics yet.';
    return;
  }
  if (frameIndex >= frames.length) frameIndex = 0;
  const photo = frames[frameIndex];
  videoImage.src = photo.objectURL || photo.url;
  videoTime.textContent = new Date(photo.created).toLocaleString();
}
function startLoop() {
  stopLoop();
  showFrame();
  if (document.hidden || playablePhotos().length < 2) return;
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  loopTimer = window.setInterval(() => {
    const count = playablePhotos().length;
    if (count < 2) return stopLoop();
    frameIndex = (frameIndex + 1) % count;
    showFrame();
  }, reduced ? 1000 : 200);
}
function preparePlayback() {
  const generation = ++preloadGeneration;
  stopLoop();
  frameIndex = 0;
  readyPhotoNames.clear();
  showFrame();
  for (const photo of playbackCandidates()) {
    fetch(photo.url, { credentials: 'same-origin' }).then(response => response.blob()).then(blob => {
      if (generation !== preloadGeneration) return;
      photo.objectURL = URL.createObjectURL(blob);
      const preloader = new Image();
      preloader.onload = () => {
        readyPhotoNames.add(photo.name);
        if (readyPhotoNames.size === 1) showFrame();
        if (!videoView.hidden && readyPhotoNames.size >= 2 && !loopTimer) startLoop();
      };
      preloader.src = photo.objectURL;
    }).catch(() => {});
  }
}
function renderGallery() {
  photos.replaceChildren();
  for (const photo of photoData) {
    const item = template.content.cloneNode(true);
    const figure = item.querySelector('figure');
    const photoLink = item.querySelector('a');
    photoLink.href = photo.url;
    photoLink.addEventListener('click', event => {
      const bridge = window.webkit?.messageHandlers?.wallPhotoEdit;
      if (!bridge) return;
      event.preventDefault();
      bridge.postMessage({ name: photo.name, created: photo.created });
    });
    item.querySelector('img').src = photo.objectURL || photo.url;
    item.querySelector('figcaption').textContent = new Date(photo.created).toLocaleString();
    figure.classList.toggle('is-hidden', Boolean(photo.hidden));
    item.querySelector('.delete-photo').addEventListener('click', () => deletePhoto(photo.name));
    const visibility = item.querySelector('.hide-photo');
    visibility.textContent = photo.hidden ? 'show' : 'hide';
    visibility.addEventListener('click', () => setPhotoHidden(photo.name, !photo.hidden));
    photos.append(item);
  }
}
async function setPhotoHidden(name, hidden) {
  const response = await fetch(`/api/photos/${encodeURIComponent(name)}/visibility`, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf }, body: JSON.stringify({ hidden }),
  });
  if (!response.ok) return showGalleryError('Hide failed.');
  const photo = photoData.find(item => item.name === name);
  if (photo) photo.hidden = hidden;
  renderGallery();
  preparePlayback();
}
async function deletePhoto(name) {
  const response = await fetch(`/api/photos/${encodeURIComponent(name)}`, {
    method: 'DELETE', credentials: 'same-origin', headers: { 'X-CSRF-Token': csrf },
  });
  if (!response.ok) return showGalleryError('Delete failed.');
  photoData = photoData.filter(photo => photo.name !== name);
  renderGallery();
  preparePlayback();
}
function showGalleryError(message) { status.hidden = false; status.textContent = message; }
async function loadSpotifyStatus() {
  try {
    const response = await fetch('/api/spotify/status', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) return;
    const data = await response.json();
    spotifyConnect.textContent = data.connected ? 'spotify ✓' : 'connect spotify';
    spotifyConnect.title = data.connected && data.display_name ? `connected as ${data.display_name}` : '';
  } catch (_) {}
}

function resetSettingsModalTimer() {
  window.clearTimeout(settingsModalTimer);
  settingsModalTimer = window.setTimeout(() => { settingsModal.hidden = true; }, 20_000);
}

async function loadSoundCloudStatus() {
  try {
    const response = await fetch('/api/soundcloud/status', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) return;
    const data = await response.json();
    soundcloudClientID.value = data.client_id || '';
    soundcloudRedirect.textContent = data.redirect_uri || '';
    soundcloudConnect.hidden = !data.configured;
    soundcloudConnect.textContent = data.connected ? 'reconnect soundcloud' : 'sign in with soundcloud';
    soundcloudStatus.textContent = data.connected
      ? `connected${data.display_name ? ` as ${data.display_name}` : ''}`
      : (data.configured ? 'settings saved · sign in next' : 'enter the app credentials from SoundCloud');
  } catch (_) {
    soundcloudStatus.textContent = 'soundcloud status unavailable';
  }
}

async function openSettings() {
  settingsModal.hidden = false;
  resetSettingsModalTimer();
  await Promise.all([loadSpotifyStatus(), loadSoundCloudStatus()]);
}

settingsButton.addEventListener('click', openSettings);
settingsModal.addEventListener('pointerdown', event => {
  resetSettingsModalTimer();
  if (event.target === settingsModal) settingsModal.hidden = true;
});
settingsModal.querySelector('.close-modal').addEventListener('click', () => { settingsModal.hidden = true; });
soundcloudSettingsForm.addEventListener('submit', async event => {
  event.preventDefault();
  resetSettingsModalTimer();
  soundcloudStatus.textContent = 'saving…';
  const response = await fetch('/api/soundcloud/settings', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
    body: JSON.stringify({ client_id: soundcloudClientID.value.trim(), client_secret: soundcloudClientSecret.value }),
  });
  const data = await response.json().catch(() => ({}));
  soundcloudClientSecret.value = '';
  if (!response.ok) {
    soundcloudStatus.textContent = data.error || 'could not save soundcloud settings';
    return;
  }
  await loadSoundCloudStatus();
  soundcloudConnect.focus();
});

if (new URLSearchParams(location.search).has('soundcloud')) {
  window.setTimeout(openSettings, 0);
}

function renderGoonLog(data) {
  goonData = data;
  renderCanvasGoons();
  goonTotals.replaceChildren();
  for (const [person, count] of Object.entries(data.totals || {}).sort((a, b) => b[1] - a[1])) {
    const item = document.createElement('div');
    item.className = 'goon-total';
    const name = document.createElement('span');
    name.className = `person-${person}`;
    name.textContent = person;
    const number = document.createElement('strong');
    number.textContent = String(count);
    item.append(name, number);
    goonTotals.append(item);
  }
  goonEvents.replaceChildren();
  for (const event of data.events || []) {
    const row = document.createElement('li');
    row.className = 'goon-event';
    const time = document.createElement('time');
    time.dateTime = event.occurred_at;
    time.textContent = new Date(event.occurred_at).toLocaleString();
    const name = document.createElement('span');
    name.className = `person person-${event.person}`;
    name.textContent = event.person;
    const action = document.createElement('span');
    action.className = 'action';
    action.textContent = event.action === 'remove' ? 'correction −1' : 'gooned +1';
    row.append(time, name, action);
    goonEvents.append(row);
  }
  goonEmpty.hidden = Boolean((data.events || []).length);
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) stopLoop();
  else {
    if (!videoView.hidden) startLoop();
    loadDashboard().catch(() => {});
    loadHoroscopes().catch(() => {});
  }
});

// Wall is designed to stay open indefinitely. Recheck often enough to cross
// midnight even if the browser never backgrounds the page.
window.setInterval(() => loadHoroscopes().catch(() => {}), 15 * 60 * 1000);
window.setInterval(() => loadDashboard().catch(() => {}), 10 * 60 * 1000);
window.setInterval(() => loadSonosState().catch(() => {}), 2_000);

Promise.all([
  loadCanvas(),
  fetch('/api/goons', { credentials: 'same-origin' }).then(response => response.json()).then(renderGoonLog),
  loadDashboard(),
  loadHoroscopes(),
  loadSpotifyStatus(),
  loadSonosState(),
  fetch('/api/photos?include_hidden=1', { credentials: 'same-origin' }).then(response => response.json()).then(data => {
    csrf = data.csrf || csrf;
    photoData = data.photos;
    renderGallery();
    preparePlayback();
  }),
]).catch(() => {});

setView('video');

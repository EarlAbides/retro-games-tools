'use strict';

// The overworld is 168 x 156 tiles; view coordinates are in tiles, with x across and y down,
// the same as the game's own (and the X/Y in the save files).
const W = 168, H = 156;
const TILE = 16;                                   // EGATILES.BIN tile size
const TOWN_W = 38, TOWN_H = 18, TOWN_TILE = 8;     // TCD.BIN layouts, EGATOWN.BIN tiles

const EGA = [0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
             0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF];
const WORLD_TILE = [0, 1, 2, 3, 4, 6, 7, 9];       // MAP.BIN value -> EGATILES tile (5 and 8 are animation frames)
const TERRAIN = ['Water', 'Grass', 'Forest', 'Mountains', 'Castle', 'Landmark', 'Town', 'Dungeon entrance'];

// Land names as OUT.EXE prints them; the land is 2*(y > 77) + (x > 83).
const LANDS = ['of Lord British', 'of the Feudal Lords', 'of the Dark Unknown', 'of Danger and Despair'];
const landName = (i) => `The Lands ${LANDS[i]}`;
const landOf = (x, y) => 2 * (y > 77) + (x > 83);

// min: the zoom (screen px per tile) at which that kind's labels appear
// color: the label, and the place's dot on the zoomed-out map
const KINDS = {
  castle:   { label: 'Castle',   min: 3, order: 0, color: '#ffffff' },
  town:     { label: 'Town',     min: 4, order: 1, color: '#fff3c4' },
  landmark: { label: 'Landmark', min: 4, order: 2, color: '#9fe8ff' },
  dungeon:  { label: 'Dungeon',  min: 8, order: 3, color: '#ff9a8a' },
};

// Below this zoom (px per tile) the map is drawn in flat terrain colors (MAP.BIN values 0-3).
const OVERVIEW_BELOW = 10;
const OVERVIEW_COLORS = ['#1c2f8f', '#3c7a2c', '#1d5220', '#7d7468'];

const LAYERS = [
  ['castle', 'Castles'], ['town', 'Towns'],
  ['landmark', 'Landmarks'], ['dungeon', 'Dungeons'],
  ['characters', 'Characters'], ['visited', 'Visited marks'],
  ['lands', 'Lands'], ['grid', 'Tile grid'],
];
const LAYER_DEFAULTS = { grid: false };

const $ = (sel) => document.querySelector(sel);
const canvas = $('#map');
const ctx = canvas.getContext('2d');

let places = [], byPos = new Map(), terrain, world, overview, townTiles, tcd;
let characters = [];
let notes = emptyNotes();
let prefs = loadPrefs();
let view = { cx: W / 2, cy: H / 2, s: 4 };   // s = screen px per tile
let fitScale = 4;
let selection = null;                         // { type: 'place'|'char', id }
let hover = null;                             // { x, y } tile under the mouse

// ------------------------------------------------------------ helpers

function emptyNotes() {
  return { version: 1, places: {}, general: '' };
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (k in node) node[k] = v;
    else node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

const layerOn = (id) => prefs.layers[id] ?? (LAYER_DEFAULTS[id] ?? true);
const placeNote = (id, create = false) => {
  if (!notes.places[id] && create) notes.places[id] = {};
  return notes.places[id];
};
const isVisited = (p) => !!(notes.places[p.id] && notes.places[p.id].visited);
const findPlace = (id) => places.find((p) => p.id === id);
const findChar = (slot) => characters.find((c) => c.slot === slot);
const terrainAt = (x, y) => terrain[y * W + x];

function loadPrefs() {
  const base = { layers: {}, view: null };
  try { return Object.assign(base, JSON.parse(localStorage.getItem('u1-map-prefs')) || {}); }
  catch { return base; }
}
function savePrefs() {
  try { localStorage.setItem('u1-map-prefs', JSON.stringify(prefs)); } catch { /* private window etc. */ }
}

function nearestPlace(x, y) {
  let best = null, bestD = Infinity;
  for (const p of places) {
    const d = Math.max(Math.abs(p.x - x), Math.abs(p.y - y));
    if (d < bestD) { best = p; bestD = d; }
  }
  return best && { place: best, dist: bestD };
}

function whereText(x, y) {
  const n = nearestPlace(x, y);
  if (!n) return '';
  if (n.dist === 0) return `at ${n.place.name}`;
  return `${n.dist} ${n.dist === 1 ? 'tile' : 'tiles'} from ${n.place.name}`;
}

// ------------------------------------------------------------ game files

async function fetchBytes(name) {
  const r = await fetch(`/api/game/${name}`);
  if (!r.ok) throw new Error(`Couldn't read ${name} from the game folder.`);
  return new Uint8Array(await r.arrayBuffer());
}

// EGA tiles, each pixel row stored as 4 bit planes (as in Export-Maps.ps1).
function decodeTiles(b, size) {
  const rowBytes = size / 8, tileBytes = size * size / 2;
  const out = [];
  for (let t = 0; t < Math.floor(b.length / tileBytes); t++) {
    const c = document.createElement('canvas');
    c.width = c.height = size;
    const cx = c.getContext('2d');
    const img = cx.createImageData(size, size);
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        let v = 0;
        for (let p = 0; p < 4; p++) {
          if (b[t * tileBytes + (y * 4 + p) * rowBytes + (x >> 3)] & (0x80 >> (x % 8))) v |= 1 << p;
        }
        const i = (y * size + x) * 4;
        img.data[i] = EGA[v] >> 16; img.data[i + 1] = (EGA[v] >> 8) & 255; img.data[i + 2] = EGA[v] & 255; img.data[i + 3] = 255;
      }
    }
    cx.putImageData(img, 0, 0);
    out.push(c);
  }
  return out;
}

function buildWorld(map, tiles) {
  terrain = new Uint8Array(W * H);
  world = document.createElement('canvas');
  world.width = W * TILE; world.height = H * TILE;
  overview = document.createElement('canvas');
  overview.width = W; overview.height = H;
  const g = world.getContext('2d'), o = overview.getContext('2d');
  for (let i = 0; i < W * H; i++) {
    const v = i % 2 === 0 ? map[i >> 1] >> 4 : map[i >> 1] & 15;
    terrain[i] = v;
    g.drawImage(tiles[WORLD_TILE[v]], (i % W) * TILE, Math.floor(i / W) * TILE);
    o.fillStyle = OVERVIEW_COLORS[v] || OVERVIEW_COLORS[1];    // places sit on grass
    o.fillRect(i % W, Math.floor(i / W), 1, 1);
  }
}

// Draw a town or castle layout ('town-3', 'castle-1') at its native 8 px tiles.
function drawLayout(target, layout) {
  const [kind, n] = layout.split('-');
  const block = kind === 'castle' ? n - 1 : +n + 1;     // TCD.BIN stores the 2 castles, then the 8 towns
  target.width = TOWN_W * TOWN_TILE; target.height = TOWN_H * TOWN_TILE;
  const g = target.getContext('2d');
  for (let x = 0; x < TOWN_W; x++) {
    for (let y = 0; y < TOWN_H; y++) {
      let v = tcd[block * TOWN_W * TOWN_H + x * TOWN_H + y];
      if (v >= townTiles.length) v = 1;                 // shop zone marker: plain floor
      g.drawImage(townTiles[v], x * TOWN_TILE, y * TOWN_TILE);
    }
  }
}

// ------------------------------------------------------------ view

function size() {
  return { w: canvas.clientWidth, h: canvas.clientHeight };
}
function origin() {
  const { w, h } = size();
  return { ox: w / 2 - view.cx * view.s, oy: h / 2 - view.cy * view.s };
}
function tileAt(mx, my) {
  const { ox, oy } = origin();
  const x = Math.floor((mx - ox) / view.s), y = Math.floor((my - oy) / view.s);
  return x >= 0 && y >= 0 && x < W && y < H ? { x, y } : null;
}

function computeFit() {
  const { w, h } = size();
  fitScale = Math.min(w / W, h / H) * 0.98;
}
function clampView() {
  view.s = Math.min(64, Math.max(fitScale * 0.75, view.s));
  view.cx = Math.min(W, Math.max(0, view.cx));
  view.cy = Math.min(H, Math.max(0, view.cy));
}
function fit() {
  computeFit();
  view = { cx: W / 2, cy: H / 2, s: fitScale };
  viewChanged();
}

let viewSaveTimer = null;
function viewChanged() {
  clampView();
  requestDraw();
  clearTimeout(viewSaveTimer);
  viewSaveTimer = setTimeout(() => { prefs.view = view; savePrefs(); }, 400);
}

function zoomAt(mx, my, factor) {
  const { ox, oy } = origin();
  const wx = (mx - ox) / view.s, wy = (my - oy) / view.s;
  const { w, h } = size();
  view.s *= factor;
  clampView();
  view.cx = wx - (mx - w / 2) / view.s;
  view.cy = wy - (my - h / 2) / view.s;
  viewChanged();
}

let flight = null;
function flyTo(x, y, s = Math.max(view.s, 16)) {
  const from = { ...view }, to = { cx: x + 0.5, cy: y + 0.5, s };
  const start = performance.now(), ms = 450;
  cancelAnimationFrame(flight);
  const step = (t) => {
    const k = Math.min(1, (t - start) / ms), e = k < 0.5 ? 2 * k * k : 1 - (-2 * k + 2) ** 2 / 2;
    view.cx = from.cx + (to.cx - from.cx) * e;
    view.cy = from.cy + (to.cy - from.cy) * e;
    view.s = from.s * (to.s / from.s) ** e;
    viewChanged();
    if (k < 1) flight = requestAnimationFrame(step);
  };
  flight = requestAnimationFrame(step);
}

// ------------------------------------------------------------ drawing

let drawPending = false;
function requestDraw() {
  if (drawPending) return;
  drawPending = true;
  requestAnimationFrame(() => { drawPending = false; draw(); });
}

function draw() {
  const dpr = window.devicePixelRatio || 1;
  const { w, h } = size();
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, w, h);
  if (!world) return;

  const s = view.s, { ox, oy } = origin();
  // The game's tiles are mostly black with dithered dots, so shrunk below about half size they
  // turn to noise or murk; zoomed out, draw flat terrain colors with a dot for each place instead.
  const tiles = s >= OVERVIEW_BELOW;
  ctx.imageSmoothingEnabled = tiles && s < TILE;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(tiles ? world : overview, ox, oy, W * s, H * s);
  if (!tiles) drawPlaceDots(ox, oy, s);

  if (layerOn('grid') && s >= 8) {
    ctx.strokeStyle = 'rgba(0,0,0,0.22)'; ctx.lineWidth = 1;
    ctx.beginPath();
    const x0 = Math.max(0, Math.floor(-ox / s)), x1 = Math.min(W, Math.ceil((w - ox) / s));
    const y0 = Math.max(0, Math.floor(-oy / s)), y1 = Math.min(H, Math.ceil((h - oy) / s));
    for (let x = x0; x <= x1; x++) { ctx.moveTo(Math.round(ox + x * s) + 0.5, oy + y0 * s); ctx.lineTo(Math.round(ox + x * s) + 0.5, oy + y1 * s); }
    for (let y = y0; y <= y1; y++) { ctx.moveTo(ox + x0 * s, Math.round(oy + y * s) + 0.5); ctx.lineTo(ox + x1 * s, Math.round(oy + y * s) + 0.5); }
    ctx.stroke();
  }

  if (layerOn('lands')) drawLands(ox, oy, s);

  if (layerOn('visited')) {
    ctx.strokeStyle = getCss('--visited'); ctx.lineWidth = 2;
    for (const p of places) {
      if (!isVisited(p) || !layerOn(p.kind)) continue;
      ctx.strokeRect(ox + p.x * s - 1, oy + p.y * s - 1, s + 2, s + 2);
    }
  }

  drawLabels(ox, oy, s);

  if (selection) {
    const t = selection.type === 'place' ? findPlace(selection.id) : findChar(selection.id);
    if (t) {
      const pad = Math.max(3, s * 0.25);
      ctx.strokeStyle = getCss('--select'); ctx.lineWidth = 2;
      ctx.setLineDash([5, 4]);
      ctx.strokeRect(ox + t.x * s - pad, oy + t.y * s - pad, s + 2 * pad, s + 2 * pad);
      ctx.setLineDash([]);
    }
  }

  if (layerOn('characters')) drawCharacters(ox, oy, s);
}

const cssCache = {};
function getCss(name) {
  return cssCache[name] ??= getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function drawPlaceDots(ox, oy, s) {
  const r = Math.max(2, s * 0.45);
  ctx.lineWidth = 1; ctx.strokeStyle = '#000';
  for (const p of places) {
    if (!layerOn(p.kind)) continue;
    ctx.fillStyle = KINDS[p.kind].color;
    ctx.beginPath();
    const x = ox + (p.x + 0.5) * s, y = oy + (p.y + 0.5) * s;
    if (p.kind === 'castle') ctx.rect(x - r * 1.2, y - r * 1.2, r * 2.4, r * 2.4);
    else ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fill(); ctx.stroke();
  }
}

function drawLands(ox, oy, s) {
  ctx.save();
  ctx.strokeStyle = 'rgba(255,255,255,0.35)'; ctx.lineWidth = 1.5; ctx.setLineDash([8, 6]);
  ctx.beginPath();
  ctx.moveTo(ox + 84 * s, oy); ctx.lineTo(ox + 84 * s, oy + H * s);
  ctx.moveTo(ox, oy + 78 * s); ctx.lineTo(ox + W * s, oy + 78 * s);
  ctx.stroke();
  ctx.setLineDash([]);
  if (s < 10) {
    // in the strip of open sea along the top and bottom edges, clear of the place labels
    const size = Math.max(13, Math.min(22, s * 3));
    ctx.font = `italic 700 ${size}px "Palatino Linotype", "Book Antiqua", Palatino, serif`;
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.lineJoin = 'round'; ctx.lineWidth = 4; ctx.strokeStyle = 'rgba(0,0,0,0.6)';
    ctx.fillStyle = 'rgba(244,236,216,0.85)';
    for (let i = 0; i < 4; i++) {
      const x = ox + (i % 2 ? 0.75 : 0.25) * W * s, y = oy + (i < 2 ? 2.5 : H - 2.5) * s;
      ctx.strokeText(landName(i), x, y); ctx.fillText(landName(i), x, y);
    }
  }
  ctx.restore();
}

function drawLabels(ox, oy, s) {
  const { w, h } = size();
  const font = Math.round(Math.max(11, Math.min(15, 8 + s * 0.35)));
  ctx.font = `600 ${font}px "Segoe UI", system-ui, sans-serif`;
  ctx.textAlign = 'center'; ctx.textBaseline = 'top';
  ctx.lineJoin = 'round'; ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(0,0,0,0.85)';
  const taken = [];
  const sel = selection && selection.type === 'place' ? selection.id : null;
  const list = places
    .filter((p) => layerOn(p.kind) && (s >= KINDS[p.kind].min || p.id === sel))
    .sort((a, b) => (b.id === sel) - (a.id === sel) || KINDS[a.kind].order - KINDS[b.kind].order);
  for (const p of list) {
    const x = ox + (p.x + 0.5) * s, y = oy + (p.y + 1) * s + 2;
    if (x < -100 || x > w + 100 || y < -20 || y > h + 20) continue;
    const tw = ctx.measureText(p.name).width;
    const r = { x0: x - tw / 2 - 2, x1: x + tw / 2 + 2, y0: y, y1: y + font + 2 };
    if (p.id !== sel && taken.some((t) => r.x0 < t.x1 && r.x1 > t.x0 && r.y0 < t.y1 && r.y1 > t.y0)) continue;
    taken.push(r);
    ctx.fillStyle = p.id === sel ? '#ffffff' : KINDS[p.kind].color;
    ctx.strokeText(p.name, x, y); ctx.fillText(p.name, x, y);
  }
}

function drawCharacters(ox, oy, s) {
  const groups = new Map();
  for (const c of characters) {
    const k = `${c.x},${c.y}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(c);
  }
  ctx.save();
  for (const group of groups.values()) {
    const { x, y } = group[0];
    const px = ox + x * s, py = oy + y * s, box = Math.max(s, 8), off = (box - s) / 2;
    ctx.strokeStyle = '#000'; ctx.lineWidth = 4;
    ctx.strokeRect(px - off, py - off, box, box);
    ctx.strokeStyle = getCss('--char'); ctx.lineWidth = 2;
    ctx.strokeRect(px - off, py - off, box, box);

    // a flag above the tile with each name
    ctx.font = '700 13px "Segoe UI", system-ui, sans-serif';
    ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
    const text = group.map((c) => c.name || `Player ${c.slot}`).join(', ');
    const tw = ctx.measureText(text).width;
    const fx = px + s / 2, fy = py - off - 26;
    ctx.fillStyle = getCss('--char');
    ctx.fillRect(fx - 1, fy, 2, 26 - 1);
    ctx.fillRect(fx, fy, tw + 12, 18);
    ctx.fillStyle = '#1a1206';
    ctx.fillText(text, fx + 6, fy + 9.5);
  }
  ctx.restore();
}

// ------------------------------------------------------------ sidebar

function renderLayers() {
  const box = $('#layer-toggles');
  box.replaceChildren(...LAYERS.map(([id, label]) => el('label', {},
    el('input', { type: 'checkbox', checked: layerOn(id), onchange: (e) => {
      prefs.layers[id] = e.target.checked; savePrefs(); requestDraw();
    } }), label)));
}

function renderCharacters() {
  const ul = $('#characters');
  if (!characters.length) {
    ul.replaceChildren(el('li', { class: 'none' }, 'No saved characters found.'));
    return;
  }
  ul.replaceChildren(...characters.map((c) => el('li', {
    class: selection && selection.type === 'char' && selection.id === c.slot ? 'selected' : '',
    title: 'Show on the map',
    onclick: () => select({ type: 'char', id: c.slot }, true),
  },
  el('span', { class: 'who' }, el('b', {}, c.name || `Player ${c.slot}`), el('span', { class: 'sub' }, `${c.x}, ${c.y}`)),
  el('span', { class: 'stats' }, `Level ${c.level} ${c.sex} ${c.race} ${c.class} · ${whereText(c.x, c.y)}`))));
}

function renderPlaces() {
  const q = $('#search').value.trim().toLowerCase();
  const items = [];
  for (let land = 0; land < 4; land++) {
    const list = places
      .filter((p) => p.land === land && (!q || p.name.toLowerCase().includes(q) || p.kind.includes(q)))
      .sort((a, b) => KINDS[a.kind].order - KINDS[b.kind].order || a.name.localeCompare(b.name));
    if (!list.length) continue;
    items.push(el('li', { class: 'land' }, landName(land)));
    for (const p of list) {
      items.push(el('li', {
        class: selection && selection.type === 'place' && selection.id === p.id ? 'selected' : '',
        onclick: () => select({ type: 'place', id: p.id }, true),
      }, el('span', { class: 'tick', title: isVisited(p) ? 'Visited' : '' }, isVisited(p) ? '✓' : ''),
      p.name, el('span', { class: 'sub' }, KINDS[p.kind].label)));
    }
  }
  if (!items.length) items.push(el('li', { class: 'none' }, 'No places match.'));
  $('#places').replaceChildren(...items);
}

function renderInspector() {
  const box = $('#inspector');
  if (!selection) {
    box.replaceChildren(el('p', { class: 'empty' }, 'Click a town, castle, landmark or dungeon. Drag to move, scroll to zoom.'));
    return;
  }
  if (selection.type === 'char') {
    const c = findChar(selection.id);
    if (!c) { selection = null; renderInspector(); return; }
    box.replaceChildren(
      el('h3', {}, c.name || `Player ${c.slot}`),
      el('p', { class: 'kind' }, `Level ${c.level} ${c.sex} ${c.race} ${c.class}`),
      el('p', { class: 'hint' }, `Hits ${c.hits} · Food ${c.food} · Exp. ${c.exp} · Coin ${c.coin}`),
      el('p', { class: 'hint' }, `At ${c.x}, ${c.y} in ${landName(landOf(c.x, c.y))}, ${whereText(c.x, c.y)}.`),
      el('p', { class: 'hint' }, `PLAYER${c.slot}.U1, saved ${new Date(c.saved).toLocaleString()}`));
    return;
  }

  const p = findPlace(selection.id);
  const n = placeNote(p.id) || {};
  const parts = [
    el('h3', {}, p.name),
    el('p', { class: 'kind' }, `${KINDS[p.kind].label} in ${landName(p.land)}`),
    el('div', { class: 'row' },
      el('span', { class: 'hint' }, `${p.x}, ${p.y}`),
      el('label', { class: 'check' }, el('input', { type: 'checkbox', checked: !!n.visited, onchange: (e) => {
        placeNote(p.id, true).visited = e.target.checked;
        prune(p.id); notesChanged(); renderPlaces(); requestDraw();
      } }), 'Visited')),
  ];
  if (p.layout) {
    const c = el('canvas', { class: 'layout', title: 'Click to enlarge', onclick: () => openLayout(p) });
    drawLayout(c, p.layout);
    const shared = places.filter((o) => o.layout === p.layout && o.id !== p.id).map((o) => o.name);
    parts.push(c, el('p', { class: 'hint' }, `Same layout as ${shared.join(', ')}.`));
  }
  parts.push(el('textarea', {
    rows: 5, placeholder: 'Notes: quests, shops, what you found...', value: n.note || '',
    oninput: (e) => { placeNote(p.id, true).note = e.target.value; prune(p.id); notesChanged(); },
  }));
  box.replaceChildren(...parts);
}

function openLayout(p) {
  $('#layout-title').textContent = p.name;
  const c = $('#layout-big');
  drawLayout(c, p.layout);
  const k = Math.max(1, Math.floor(Math.min(window.innerWidth * 0.9 / c.width, window.innerHeight * 0.75 / c.height)));
  c.style.width = `${c.width * k}px`;
  $('#layout-dialog').showModal();
}

function prune(id) {
  const n = notes.places[id];
  if (n && !n.visited && !n.note) delete notes.places[id];
}

function select(sel, fly = false) {
  selection = sel;
  renderInspector(); renderPlaces(); renderCharacters(); requestDraw();
  if (sel && fly) {
    const t = sel.type === 'place' ? findPlace(sel.id) : findChar(sel.id);
    if (t) flyTo(t.x, t.y);
  }
  if (sel && sel.type === 'place') {
    // scroll just the list (scrollIntoView would scroll the whole sidebar too)
    const ul = $('#places'), li = ul.querySelector('li.selected');
    if (li && (li.offsetTop < ul.scrollTop || li.offsetTop + li.offsetHeight > ul.scrollTop + ul.clientHeight)) {
      ul.scrollTop = li.offsetTop - ul.clientHeight / 2;
    }
  }
}

// ------------------------------------------------------------ notes

let saveTimer = null;
function notesChanged() {
  $('#save-status').textContent = 'Unsaved changes...';
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNotes, 600);
}
async function saveNotes() {
  try {
    const r = await fetch('/api/notes', { method: 'PUT', body: JSON.stringify(notes, null, 1) });
    if (!r.ok) throw new Error(await r.text());
    $('#save-status').textContent = 'Notes saved';
  } catch (e) {
    $('#save-status').textContent = `Save failed: ${e.message}`;
  }
}
function adoptNotes(data) {
  notes = Object.assign(emptyNotes(), data || {});
  if (typeof notes.places !== 'object' || !notes.places) notes.places = {};
  $('#general-notes').value = notes.general || '';
}

// ------------------------------------------------------------ input

function setupInput() {
  let drag = null;
  canvas.addEventListener('pointerdown', (e) => {
    canvas.setPointerCapture(e.pointerId);
    drag = { x: e.offsetX, y: e.offsetY, cx: view.cx, cy: view.cy, moved: false };
  });
  canvas.addEventListener('pointermove', (e) => {
    if (drag) {
      const dx = e.offsetX - drag.x, dy = e.offsetY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) { drag.moved = true; canvas.classList.add('dragging'); }
      if (drag.moved) {
        cancelAnimationFrame(flight);
        view.cx = drag.cx - dx / view.s; view.cy = drag.cy - dy / view.s;
        viewChanged();
      }
    }
    updateHover(e.offsetX, e.offsetY);
  });
  canvas.addEventListener('pointerup', (e) => {
    canvas.classList.remove('dragging');
    if (drag && !drag.moved) click(e.offsetX, e.offsetY);
    drag = null;
  });
  canvas.addEventListener('pointerleave', () => { hover = null; $('#tooltip').hidden = true; $('#cursor-pos').innerHTML = '&nbsp;'; });
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    cancelAnimationFrame(flight);
    zoomAt(e.offsetX, e.offsetY, Math.pow(1.2, -e.deltaY / 100));
  }, { passive: false });
  canvas.addEventListener('dblclick', (e) => zoomAt(e.offsetX, e.offsetY, 2));

  const center = () => { const { w, h } = size(); return [w / 2, h / 2]; };
  $('#zoom-in').onclick = () => zoomAt(...center(), 1.5);
  $('#zoom-out').onclick = () => zoomAt(...center(), 1 / 1.5);
  $('#zoom-fit').onclick = fit;

  document.addEventListener('keydown', (e) => {
    if (e.target.matches('input, textarea')) {
      if (e.key === 'Escape') e.target.blur();
      return;
    }
    if (e.key === '+' || e.key === '=') zoomAt(...center(), 1.5);
    else if (e.key === '-') zoomAt(...center(), 1 / 1.5);
    else if (e.key === '0') fit();
    else if (e.key === 'Escape') select(null);
    else if (e.key === '/') { e.preventDefault(); $('#search').focus(); }
  });

  $('#search').addEventListener('input', renderPlaces);
  $('#search').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const q = e.target.value.trim().toLowerCase();
    const hit = places.find((p) => p.name.toLowerCase() === q) || places.find((p) => p.name.toLowerCase().includes(q));
    if (hit) select({ type: 'place', id: hit.id }, true);
  });

  $('#general-notes').addEventListener('input', (e) => { notes.general = e.target.value; notesChanged(); });
  $('#refresh-chars').onclick = loadCharacters;
  $('#layout-close').onclick = () => $('#layout-dialog').close();
  $('#layout-dialog').addEventListener('click', (e) => { if (e.target === e.currentTarget) e.currentTarget.close(); });

  $('#export').onclick = () => {
    const a = el('a', {
      href: URL.createObjectURL(new Blob([JSON.stringify(notes, null, 1)], { type: 'application/json' })),
      download: `ultima1-map-notes-${new Date().toISOString().slice(0, 10)}.json`,
    });
    a.click();
    URL.revokeObjectURL(a.href);
  };
  $('#import').addEventListener('change', async (e) => {
    const f = e.target.files[0];
    e.target.value = '';
    if (!f) return;
    try {
      const data = JSON.parse(await f.text());
      if (typeof data !== 'object' || !data.places) throw new Error('That file has no map notes in it.');
      if (!confirm('Replace your current map notes with this file?')) return;
      adoptNotes(data);
      notesChanged(); renderInspector(); renderPlaces(); requestDraw();
    } catch (err) { alert(`Import failed: ${err.message}`); }
  });

  window.addEventListener('resize', () => { computeFit(); viewChanged(); });
  window.addEventListener('focus', loadCharacters);
}

function hitTest(mx, my) {
  const t = tileAt(mx, my);
  if (!t) return null;
  const p = byPos.get(`${t.x},${t.y}`);
  if (p && layerOn(p.kind)) return { type: 'place', id: p.id };
  if (layerOn('characters')) {
    const c = characters.find((ch) => ch.x === t.x && ch.y === t.y);
    if (c) return { type: 'char', id: c.slot };
  }
  return null;
}

function click(mx, my) {
  select(hitTest(mx, my));
}

function updateHover(mx, my) {
  const t = tileAt(mx, my);
  hover = t;
  const tip = $('#tooltip');
  if (!t) { tip.hidden = true; $('#cursor-pos').innerHTML = '&nbsp;'; canvas.classList.remove('over-place'); return; }
  $('#cursor-pos').textContent = `${t.x}, ${t.y} · ${TERRAIN[terrainAt(t.x, t.y)]} · ${landName(landOf(t.x, t.y))}`;
  const hit = hitTest(mx, my);
  canvas.classList.toggle('over-place', !!hit);
  if (!hit) { tip.hidden = true; return; }
  if (hit.type === 'place') {
    const p = findPlace(hit.id);
    tip.replaceChildren(el('b', {}, p.name), el('br'),
      el('span', { class: 'dim' }, `${KINDS[p.kind].label} · ${p.x}, ${p.y}${isVisited(p) ? ' · visited' : ''}`));
  } else {
    const c = findChar(hit.id);
    tip.replaceChildren(el('b', {}, c.name || `Player ${c.slot}`), el('br'),
      el('span', { class: 'dim' }, `Level ${c.level} ${c.race} ${c.class} · last save`));
  }
  tip.hidden = false;
  const wrap = $('#map-wrap').getBoundingClientRect();
  const left = Math.min(mx + 14, wrap.width - tip.offsetWidth - 6);
  tip.style.left = `${left}px`;
  tip.style.top = `${my + 16}px`;
}

// ------------------------------------------------------------ startup

async function loadCharacters() {
  try {
    const r = await fetch('/api/characters');
    if (!r.ok) return;
    characters = (await r.json()).filter((c) => c.x < W && c.y < H);
    if (selection && selection.type === 'char' && !findChar(selection.id)) selection = null;
    renderCharacters(); renderInspector(); requestDraw();
  } catch { /* server gone; the ping will say so */ }
}

async function start() {
  setupInput();
  renderLayers();
  computeFit();
  view = prefs.view || { cx: W / 2, cy: H / 2, s: fitScale };
  clampView();
  requestDraw();

  try {
    const [map, wt, tt, t, pl, nt] = await Promise.all([
      fetchBytes('MAP.BIN'), fetchBytes('EGATILES.BIN'), fetchBytes('EGATOWN.BIN'), fetchBytes('TCD.BIN'),
      fetch('/api/places').then((r) => { if (!r.ok) return r.text().then((m) => { throw new Error(m); }); return r.json(); }),
      fetch('/api/notes').then((r) => r.json()),
    ]);
    buildWorld(map, decodeTiles(wt, TILE));
    townTiles = decodeTiles(tt, TOWN_TILE);
    tcd = t;
    places = pl;
    byPos = new Map(places.map((p) => [`${p.x},${p.y}`, p]));
    adoptNotes(nt);
  } catch (e) {
    const box = $('#load-error');
    box.textContent = `Couldn't load the map.\n\n${e.message}\n\nIs the map server still running? Start it again with "Ultima 1 Map.bat".`;
    box.hidden = false;
    return;
  }
  renderPlaces(); renderInspector();
  await loadCharacters();
  requestDraw();

  // keep the server alive while the page is open
  setInterval(() => fetch('/api/ping').catch(() => { $('#save-status').textContent = 'Map server stopped - notes are not being saved'; }), 30000);
}

start();

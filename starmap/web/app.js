'use strict';

// Game coordinates: x 0..250 (outward -> coreward), y 0..220 (downspin -> upspin).
// SVG user units equal game units, with y flipped so upspin is at the top.
const W = 250, H = 220;
const WORLD = { x0: -32, y0: -52, x1: 282, y1: 252 };   // SVG-space extent incl. title and axes
const SVGNS = 'http://www.w3.org/2000/svg';

// Spectral class -> poster color (sampled from the EA poster scan)
const CLASSES = {
  O: { name: 'Blue',       color: '#1f6fb0' },
  B: { name: 'Light blue', color: '#a1dde9' },
  A: { name: 'Green',      color: '#16ab25' },
  F: { name: 'White',      color: '#f8f8f3' },
  G: { name: 'Yellow',     color: '#f9ea10' },
  K: { name: 'Orange',     color: '#edae1a' },
  M: { name: 'Red',        color: '#f0571d' },
};

// Planet colors from the game's in-system view (PS>C), in its 16-color palette.
// Molten and rock both come out brown there, so they share a label here too.
const SURFACES = {
  gas:     { label: 'Gas giant', color: '#aa00aa' },
  liquid:  { label: 'Liquid',    color: '#55ffff' },
  frozen:  { label: 'Frozen',    color: '#ffffff' },
  molten:  { label: 'Rocky',     color: '#aa5500' },
  rock:    { label: 'Rocky',     color: '#aa5500' },
  unknown: { label: 'Unknown',   color: '#555555' },
};

const MARKER_KINDS = {
  encounter: { label: 'Encounter',   path: 'M0,-1.25L1.25,0L0,1.25L-1.25,0Z' },
  note:      { label: 'Note',        path: 'M-1,-1H1V1H-1Z' },
  poi:       { label: 'Point of interest', path: 'M0,-1.3L1.2,0.9H-1.2Z' },
};

// Names the game manual and maps give away up front. A name you type in wins.
const KNOWN_NAMES = { '125,100': 'Arth' };
// The maps mark the starting system with a purple arrow coming in from the lower right.
const START_STAR = '125,100';

const LAYERS = [
  ['grid', 'Grid'], ['nebulae', 'Nebulae'],
  ['flux', 'Flux lines'], ['stars', 'Stars'],
  ['visited', 'Visited rings'], ['dimUnvisited', 'Dim unvisited'],
  ['territories', 'Territories'], ['undiscovered', 'Undiscovered'],
  ['lines', 'Poster lines'], ['labels', 'Star labels'],
  ['markers', 'Markers'], ['start', 'Start arrow'],
  ['axes', 'Axes & frame'],
];
const LAYER_DEFAULTS = { dimUnvisited: false };

const $ = (sel) => document.querySelector(sel);
const svg = $('#map');

let mapData, overlay;
let notes = emptyNotes();
let prefs = loadPrefs();
let view = { cx: 125, cy: 100, s: 1 };   // s = screen px per game unit
let fitScale = 1;
let selection = null;                     // { type: 'star'|'marker'|'territory'|'flux', key }
let placing = false;

// ------------------------------------------------------------ helpers

function emptyNotes() {
  return { version: 1, stars: {}, markers: [], territories: {}, general: '' };
}

function el(tag, attrs = {}, ...children) {
  const svgTags = ['svg', 'g', 'circle', 'line', 'path', 'rect', 'text', 'title'];
  const node = svgTags.includes(tag) ? document.createElementNS(SVGNS, tag) : document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'class') node.setAttribute('class', v);
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (k in node && !svgTags.includes(tag)) node[k] = v;
    else node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

const sy = (gy) => H - gy;
const starKey = (s) => `${s.x},${s.y}`;
const fmt = (n) => (Math.round(n * 10) / 10).toString();
const coordText = (x, y) => `${fmt(x)}, ${fmt(y)}`;
const today = () => { const d = new Date(); return new Date(d - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); };
const now = () => new Date().toISOString();
const layerOn = (id) => prefs.layers[id] ?? (LAYER_DEFAULTS[id] ?? true);

function loadPrefs() {
  const base = { layers: {}, hiddenClasses: [], view: null };
  try { return Object.assign(base, JSON.parse(localStorage.getItem('sf-starmap-prefs')) || {}); }
  catch { return base; }
}
function savePrefs() {
  try { localStorage.setItem('sf-starmap-prefs', JSON.stringify(prefs)); } catch { /* private window etc. */ }
}

// ------------------------------------------------------------ data access

function starNote(key, create = false) {
  if (!notes.stars[key] && create) notes.stars[key] = {};
  return notes.stars[key];
}
function territoryNote(id, create = false) {
  if (!notes.territories[id] && create) notes.territories[id] = {};
  return notes.territories[id];
}
const findStar = (key) => mapData.stars.find((s) => starKey(s) === key);
const findMarker = (id) => notes.markers.find((m) => m.id === id);
const findTerritory = (id) => overlay.territories.find((t) => t.id === id);

function territoryName(t) {
  const n = notes.territories[t.id];
  return (n && n.name) || `Territory near ${Math.round(Math.max(0, t.x))}, ${Math.round(Math.min(H, t.y))}`;
}
function starTitle(s) {
  const n = notes.stars[starKey(s)];
  return (n && n.name) || KNOWN_NAMES[starKey(s)] || `${s.cls}-class star`;
}
function pruneStar(key) {
  const n = notes.stars[key];
  if (n && n.planets) for (const o of Object.keys(n.planets)) if (!n.planets[o]) delete n.planets[o];
  if (n && n.planets && !Object.keys(n.planets).length) delete n.planets;
  if (n && !n.name && !n.note && !n.visited && !n.planets) delete notes.stars[key];
}

// ------------------------------------------------------------ static rendering

function renderStatic() {
  const grid = $('#layer-grid');
  for (let x = 10; x < W; x += 10) grid.append(el('line', { x1: x, y1: 0, x2: x, y2: H }));
  for (let y = 10; y < H; y += 10) grid.append(el('line', { x1: 0, y1: sy(y), x2: W, y2: sy(y) }));

  const neb = $('#layer-nebulae');
  // Each nebula is a circle; overlapping ones merge into the poster's blobs.
  // Radius = size + 0.5 best matches the poster artwork.
  for (const n of mapData.nebulae) neb.append(el('circle', { cx: n.x, cy: sy(n.y), r: n.size + 0.5 }));

  const lines = $('#layer-lines');
  for (const l of overlay.lines) lines.append(el('line', { x1: l.x, y1: 0, x2: l.x, y2: H }));

  const flux = $('#layer-flux');
  for (const f of mapData.flux) {
    flux.append(el('line', { x1: f.a[0], y1: sy(f.a[1]), x2: f.b[0], y2: sy(f.b[1]) }));
  }
  for (const f of mapData.flux) {
    flux.append(el('circle', { cx: f.a[0], cy: sy(f.a[1]) }), el('circle', { cx: f.b[0], cy: sy(f.b[1]) }));
  }

  const axes = $('#layer-axes');
  axes.append(el('rect', { class: 'frame', x: WORLD.x0 + 3, y: WORLD.y0 + 3, width: WORLD.x1 - WORLD.x0 - 6, height: WORLD.y1 - WORLD.y0 - 6 }));
  for (let x = 0; x <= W; x += 10) axes.append(el('text', { class: 'tick-x', x, y: H + 5 }, x));
  for (let y = 0; y <= H; y += 10) axes.append(el('text', { class: 'tick-y', x: -2, y: sy(y) }, y));
  axes.append(
    el('text', { class: 'dir', x: W / 2, y: -8 }, 'UPSPIN'),
    el('text', { class: 'dir', x: W / 2, y: H + 17 }, 'DOWNSPIN'),
    el('text', { class: 'dir', transform: `translate(-15 ${H / 2}) rotate(-90)` }, 'OUTWARD'),
    el('text', { class: 'dir', transform: `translate(265 ${H / 2}) rotate(90)` }, 'COREWARD'),
    el('text', { class: 'dir', x: W / 2, y: -30, style: 'fill:#fff;font-size:15px' }, 'STARFLIGHT STARMAP'),
  );

  const stars = $('#layer-stars');
  for (const s of mapData.stars) {
    stars.append(el('circle', { cx: s.x, cy: sy(s.y), fill: CLASSES[s.cls].color, 'data-key': starKey(s), 'data-cls': s.cls }));
  }
}

// ------------------------------------------------------------ dynamic rendering

function renderTerritories() {
  const g = $('#layer-territories');
  g.replaceChildren();
  g.classList.toggle('hide-undiscovered', !layerOn('undiscovered'));
  for (const t of overlay.territories) {
    const n = notes.territories[t.id];
    const found = !!(n && n.discovered);
    const sel = selection?.type === 'territory' && selection.key === t.id;
    g.append(el('circle', { cx: t.x, cy: sy(t.y), r: t.r, class: `${found ? 'discovered' : 'undiscovered'}${sel ? ' selected' : ''}` }));
    if (found) {
      const lx = Math.min(W - 10, Math.max(10, t.x));
      const ly = Math.min(H - 6, Math.max(6, t.y));
      g.append(el('text', { x: lx, y: sy(ly) }, territoryName(t)));
    }
  }
}

function renderStars() {
  const hidden = new Set(prefs.hiddenClasses);
  $('#layer-stars').classList.toggle('dim-unvisited', layerOn('dimUnvisited'));
  for (const c of $('#layer-stars').children) {
    const n = notes.stars[c.dataset.key];
    c.classList.toggle('visited', !!(n && n.visited));
    c.classList.toggle('cls-hidden', hidden.has(c.dataset.cls));
  }
  const rings = $('#layer-visited');
  rings.replaceChildren();
  for (const s of mapData.stars) {
    const n = notes.stars[starKey(s)];
    if (n && n.visited) rings.append(el('circle', { cx: s.x, cy: sy(s.y), class: hidden.has(s.cls) ? 'cls-hidden' : null }));
  }
}

function renderLabels() {
  const g = $('#layer-labels');
  g.replaceChildren();
  const z = view.s / fitScale;
  const hidden = new Set(prefs.hiddenClasses);
  const showCoords = z >= 3.2;
  const dx = parseFloat(getComputedStyle(svg).getPropertyValue('--star-r')) * 1.6;
  for (const s of mapData.stars) {
    if (hidden.has(s.cls)) continue;
    const n = notes.stars[starKey(s)];
    const name = (n && n.name) || KNOWN_NAMES[starKey(s)];
    if (name) g.append(el('text', { class: 'named', x: s.x + dx, y: sy(s.y) + dx * 0.4 }, showCoords ? `${name} (${s.x},${s.y})` : name));
    else if (showCoords) g.append(el('text', { x: s.x + dx, y: sy(s.y) + dx * 0.4 }, `${s.x},${s.y}`));
  }
}

function renderMarkers() {
  const g = $('#layer-markers');
  g.replaceChildren();
  const k = 7 / view.s;   // ~7px half-size regardless of zoom
  for (const m of notes.markers) {
    const kind = MARKER_KINDS[m.kind] ? m.kind : 'encounter';
    g.append(el('g', { class: kind, transform: `translate(${m.x} ${sy(m.y)}) scale(${k})` },
      el('path', { d: MARKER_KINDS[kind].path })));
  }
}

function renderStartArrow(starPx) {
  const g = $('#layer-start');
  g.replaceChildren();
  const s = findStar(START_STAR);
  if (!s) return;
  // Drawn in screen pixels so it stays the same size at any zoom, aimed up-left at the star.
  const tip = starPx + 3, tail = tip + 24, head = 7;
  g.append(el('g', { transform: `translate(${s.x} ${sy(s.y)}) scale(${1 / view.s}) rotate(45)` },
    el('line', { x1: tip + head - 1, y1: 0, x2: tail, y2: 0 }),
    el('path', { d: `M${tip},0L${tip + head},${-head / 2}L${tip + head},${head / 2}Z` })));
}

function renderSelection() {
  const g = $('#layer-selection');
  g.replaceChildren();
  const p = selectionPoint();
  if (p) g.append(el('circle', { cx: p.x, cy: sy(p.y), r: 13 / view.s }));
}

function selectionPoint() {
  if (!selection) return null;
  if (selection.type === 'star') return findStar(selection.key);
  if (selection.type === 'marker') return findMarker(selection.key);
  if (selection.type === 'flux') { const [x, y] = selection.key.split(',').map(Number); return { x, y }; }
  return null;
}

function renderMapData() {
  renderTerritories(); renderStars(); renderLabels(); renderMarkers(); renderSelection();
}

function renderLists() {
  renderJournal(); renderTerritoryList();
}

// ------------------------------------------------------------ view / zoom

function applyView() {
  const { width: w, height: h } = svg.getBoundingClientRect();
  svg.setAttribute('viewBox', `${view.cx - w / 2 / view.s} ${view.cy - h / 2 / view.s} ${w / view.s} ${h / view.s}`);
  const z = view.s / fitScale;
  const starPx = Math.min(9, 3.4 * Math.pow(z, 0.45));
  svg.style.setProperty('--star-r', `${starPx / view.s}px`);
  svg.style.setProperty('--label-size', `${11 / view.s}px`);
  svg.style.setProperty('--terr-size', `${Math.min(22, 13 * Math.pow(z, 0.3)) / view.s}px`);
  renderLabels(); renderMarkers(); renderStartArrow(starPx); renderSelection();
  prefs.view = { cx: view.cx, cy: view.cy, z };
  savePrefsSoon();
}

let prefsTimer;
function savePrefsSoon() { clearTimeout(prefsTimer); prefsTimer = setTimeout(savePrefs, 400); }

function computeFit() {
  const { width: w, height: h } = svg.getBoundingClientRect();
  fitScale = Math.min(w / (WORLD.x1 - WORLD.x0), h / (WORLD.y1 - WORLD.y0));
}

function clampView() {
  view.s = Math.min(fitScale * 60, Math.max(fitScale * 0.7, view.s));
  view.cx = Math.min(WORLD.x1, Math.max(WORLD.x0, view.cx));
  view.cy = Math.min(WORLD.y1, Math.max(WORLD.y0, view.cy));
}

function fitView() {
  computeFit();
  view = { cx: (WORLD.x0 + WORLD.x1) / 2, cy: (WORLD.y0 + WORLD.y1) / 2, s: fitScale };
  applyView();
}

function toWorld(clientX, clientY) {
  const r = svg.getBoundingClientRect();
  return { x: view.cx + (clientX - r.left - r.width / 2) / view.s, y: view.cy + (clientY - r.top - r.height / 2) / view.s };
}

function zoomAt(clientX, clientY, factor) {
  const p = toWorld(clientX, clientY);
  const r = svg.getBoundingClientRect();
  view.s *= factor;
  clampView();
  view.cx = p.x - (clientX - r.left - r.width / 2) / view.s;
  view.cy = p.y - (clientY - r.top - r.height / 2) / view.s;
  clampView();
  applyView();
}

function zoomCenter(factor) {
  const r = svg.getBoundingClientRect();
  zoomAt(r.left + r.width / 2, r.top + r.height / 2, factor);
}

let flight;
function flyTo(gx, gy, minZoom = 4) {
  cancelAnimationFrame(flight);
  const from = { ...view };
  const to = { cx: gx, cy: sy(gy), s: Math.max(view.s, fitScale * minZoom) };
  const t0 = performance.now();
  const step = (t) => {
    const k = Math.min(1, (t - t0) / 450);
    const e = 1 - Math.pow(1 - k, 3);
    view.cx = from.cx + (to.cx - from.cx) * e;
    view.cy = from.cy + (to.cy - from.cy) * e;
    view.s = from.s * Math.pow(to.s / from.s, e);
    applyView();
    if (k < 1) flight = requestAnimationFrame(step);
  };
  flight = requestAnimationFrame(step);
}

// ------------------------------------------------------------ hit testing

function hitTest(clientX, clientY) {
  const p = toWorld(clientX, clientY);
  const tol = 11 / view.s;
  let best = null;
  const consider = (type, key, x, y, bias = 0) => {
    const d = Math.hypot(x - p.x, sy(y) - p.y) - bias;
    if (d <= tol && (!best || d < best.d)) best = { type, key, d };
  };
  if (layerOn('markers')) for (const m of notes.markers) consider('marker', m.id, m.x, m.y, 2 / view.s);
  if (layerOn('stars')) {
    const hidden = new Set(prefs.hiddenClasses);
    for (const s of mapData.stars) if (!hidden.has(s.cls)) consider('star', starKey(s), s.x, s.y);
  }
  if (layerOn('flux')) {
    for (const f of mapData.flux) {
      consider('flux', `${f.a[0]},${f.a[1]}`, f.a[0], f.a[1], -1 / view.s);
      consider('flux', `${f.b[0]},${f.b[1]}`, f.b[0], f.b[1], -1 / view.s);
    }
  }
  return best;
}

function fluxPartner(key) {
  for (const f of mapData.flux) {
    if (`${f.a[0]},${f.a[1]}` === key) return { x: f.b[0], y: f.b[1] };
    if (`${f.b[0]},${f.b[1]}` === key) return { x: f.a[0], y: f.a[1] };
  }
  return null;
}

function territoriesAt(gx, gy) {
  return overlay.territories.filter((t) => notes.territories[t.id]?.discovered && Math.hypot(gx - t.x, gy - t.y) <= t.r);
}

function describeHit(hit) {
  if (hit.type === 'star') {
    const s = findStar(hit.key); const n = notes.stars[hit.key];
    let t = `${starTitle(s)} · ${CLASSES[s.cls].name} · ${s.x}, ${s.y}`;
    if (n?.visited) t += ` · visited · ${s.planets.length} planet${s.planets.length === 1 ? '' : 's'}`;
    if (n?.note) t += ' · has notes';
    return t;
  }
  if (hit.type === 'marker') {
    const m = findMarker(hit.key);
    return `${MARKER_KINDS[m.kind]?.label ?? 'Marker'}: ${m.title || '(untitled)'} · ${coordText(m.x, m.y)}`;
  }
  const o = fluxPartner(hit.key);
  return `Flux node ${hit.key.replace(',', ', ')} → exits at ${o.x}, ${o.y}`;
}

// ------------------------------------------------------------ pointer input

let drag = null;

svg.addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  drag = { id: e.pointerId, x: e.clientX, y: e.clientY, moved: false };
  svg.setPointerCapture(e.pointerId);
});

svg.addEventListener('pointermove', (e) => {
  const p = toWorld(e.clientX, e.clientY);
  const gx = p.x, gy = H - p.y;
  const inPlot = gx >= 0 && gx <= W && gy >= 0 && gy <= H;
  let status = inPlot ? `x ${Math.round(gx)}, y ${Math.round(gy)}` : ' ';
  if (inPlot) {
    const terr = territoriesAt(gx, gy).map(territoryName);
    if (terr.length) status += ` · ${terr.join(', ')}`;
  }
  $('#cursor-pos').textContent = status;

  if (drag && e.pointerId === drag.id) {
    if (!drag.moved && Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 4) {
      drag.moved = true; svg.classList.add('dragging'); hideTooltip();
    }
    if (drag.moved) {
      view.cx -= (e.clientX - drag.x) / view.s;
      view.cy -= (e.clientY - drag.y) / view.s;
      drag.x = e.clientX; drag.y = e.clientY;
      clampView(); applyView();
    }
    return;
  }
  const hit = hitTest(e.clientX, e.clientY);
  if (hit) showTooltip(e, describeHit(hit)); else hideTooltip();
  svg.style.cursor = placing ? '' : (hit ? 'pointer' : '');
});

svg.addEventListener('pointerup', (e) => {
  if (!drag || e.pointerId !== drag.id) return;
  const wasDrag = drag.moved;
  drag = null;
  svg.classList.remove('dragging');
  if (wasDrag) return;
  if (placing) { addMarkerAt(e.clientX, e.clientY); setPlacing(false); return; }
  const hit = hitTest(e.clientX, e.clientY);
  select(hit ? { type: hit.type, key: hit.key } : null);
});

svg.addEventListener('dblclick', (e) => {
  if (hitTest(e.clientX, e.clientY)) return;
  addMarkerAt(e.clientX, e.clientY);
});

svg.addEventListener('wheel', (e) => {
  e.preventDefault();
  const unit = e.deltaMode === 1 ? 0.05 : e.deltaMode === 2 ? 1 : 0.0015;
  zoomAt(e.clientX, e.clientY, Math.exp(-e.deltaY * unit));
}, { passive: false });

svg.addEventListener('pointerleave', () => { hideTooltip(); $('#cursor-pos').textContent = ' '; });

function showTooltip(e, text) {
  const tip = $('#tooltip');
  const r = $('#map-wrap').getBoundingClientRect();
  tip.textContent = text;
  tip.hidden = false;
  const x = e.clientX - r.left + 14, y = e.clientY - r.top + 14;
  tip.style.left = `${Math.min(x, r.width - tip.offsetWidth - 6)}px`;
  tip.style.top = `${Math.min(y, r.height - tip.offsetHeight - 30)}px`;
}
function hideTooltip() { $('#tooltip').hidden = true; }

document.addEventListener('keydown', (e) => {
  if (e.target.closest('input, textarea, select')) return;
  const pan = 60 / view.s;
  switch (e.key) {
    case '+': case '=': zoomCenter(1.4); break;
    case '-': case '_': zoomCenter(1 / 1.4); break;
    case '0': fitView(); break;
    case 'ArrowLeft': view.cx -= pan; clampView(); applyView(); break;
    case 'ArrowRight': view.cx += pan; clampView(); applyView(); break;
    case 'ArrowUp': view.cy -= pan; clampView(); applyView(); break;
    case 'ArrowDown': view.cy += pan; clampView(); applyView(); break;
    case 'Escape': if (placing) setPlacing(false); else select(null); break;
    default: return;
  }
  e.preventDefault();
});

$('#zoom-in').onclick = () => zoomCenter(1.5);
$('#zoom-out').onclick = () => zoomCenter(1 / 1.5);
$('#zoom-fit').onclick = fitView;
$('#add-marker').onclick = () => setPlacing(!placing);

function setPlacing(on) {
  placing = on;
  svg.classList.toggle('placing', on);
  $('#add-marker').classList.toggle('active', on);
  $('#add-marker').textContent = on ? 'Click the map...' : '+ Add marker';
  $('#mode-hint').textContent = on ? 'Click where the encounter happened (Esc to cancel)' : '';
}

// ------------------------------------------------------------ selection & markers

function select(sel, fly = false) {
  selection = sel;
  renderTerritories(); renderSelection(); renderInspector(); renderLists();
  if (fly && sel) {
    if (sel.type === 'territory') {
      const t = findTerritory(sel.key);
      flyTo(Math.min(W, Math.max(0, t.x)), Math.min(H, Math.max(0, t.y)), Math.max(1, 70 / t.r));
    } else {
      const p = selectionPoint();
      if (p) flyTo(p.x, p.y);
    }
  }
}

function addMarkerAt(clientX, clientY) {
  const p = toWorld(clientX, clientY);
  const x = Math.round(Math.min(W, Math.max(0, p.x)));
  const y = Math.round(Math.min(H, Math.max(0, H - p.y)));
  const m = { id: `m${Date.now().toString(36)}`, kind: 'encounter', x, y, title: '', note: '', created: now(), updated: now() };
  notes.markers.push(m);
  changed();
  select({ type: 'marker', key: m.id });
  $('#inspector [data-focus]')?.focus();
}

// ------------------------------------------------------------ inspector

function field(label, input) {
  return el('div', { class: 'field' }, el('label', {}, label), input);
}

function renderInspector() {
  const box = $('#inspector');
  box.replaceChildren();
  if (!selection) {
    box.append(el('p', { class: 'empty' }, 'Click a star or marker. Double-click empty space to drop an encounter marker.'));
    return;
  }
  if (selection.type === 'star') return renderStarInspector(box);
  if (selection.type === 'marker') return renderMarkerInspector(box);
  if (selection.type === 'territory') return renderTerritoryInspector(box);
  if (selection.type === 'flux') return renderFluxInspector(box);
}

function renderStarInspector(box) {
  const key = selection.key;
  const s = findStar(key);
  const n = starNote(key) || {};
  const title = el('h2', {}, starTitle(s));
  const update = (fn) => {
    fn(starNote(key, true));
    starNote(key).updated = now();
    pruneStar(key);
    title.textContent = starTitle(s);
    changed({ keepInspector: true });
  };
  let system = renderSystem(s, update);
  const visitedOn = el('input', {
    type: 'date', value: n.visitedOn || '', disabled: !n.visited,
    oninput: (e) => update((d) => { d.visitedOn = e.target.value; }),
  });
  box.append(
    el('div', { class: 'inspector-title' }, el('span', { class: 'swatch', style: `background:${CLASSES[s.cls].color}` }), title),
    el('div', { class: 'meta' }, `${s.cls}-class · ${CLASSES[s.cls].name} · ${s.x}, ${s.y}`),
    field('Name', el('input', {
      type: 'text', value: n.name || '', placeholder: KNOWN_NAMES[key] || 'e.g. Arth system',
      oninput: (e) => update((d) => { d.name = e.target.value.trim() ? e.target.value : ''; }),
    })),
    el('div', { class: 'field row' },
      el('label', { class: 'check' },
        el('input', {
          type: 'checkbox', checked: !!n.visited,
          onchange: (e) => update((d) => {
            d.visited = e.target.checked;
            if (d.visited && !d.visitedOn) d.visitedOn = today();
            if (!d.visited) delete d.visitedOn;
            visitedOn.disabled = !d.visited; visitedOn.value = d.visitedOn || '';
            system.replaceWith(system = renderSystem(s, update));
          }),
        }), 'Visited'),
      visitedOn),
    field('Notes', el('textarea', {
      rows: 6, value: n.note || '', placeholder: 'Planets, minerals, lifeforms, ruins...', 'data-focus': '',
      oninput: (e) => update((d) => { d.note = e.target.value; }),
    })),
    system,
  );
}

// Orbit numbers are fixed in the game data, but where a planet sits on its orbit is
// decided at run time, so the angles here are just a stable scatter per system.
function planetAngle(s, orbit) {
  const v = Math.sin(s.x * 12.9898 + s.y * 78.233 + orbit * 37.719) * 43758.5453;
  return (v - Math.floor(v)) * Math.PI * 2;
}

function renderSystem(s, update) {
  const key = starKey(s);
  const n = starNote(key) || {};
  if (!n.visited) return el('p', { class: 'hint system-hint' }, 'Mark this star visited to show its system map.');
  if (!s.planets.length) return el('div', { class: 'field system' }, el('label', {}, 'System'), el('p', { class: 'empty' }, 'No planets.'));

  const R = 130, ring = (o) => 14 + (o - 1) * 15.5;
  const map = el('svg', { class: 'system-map', viewBox: `${-R} ${-R} ${2 * R} ${2 * R}`, role: 'img', 'aria-label': 'System map' });
  for (let o = 1; o <= 8; o++) map.append(el('circle', { class: 'orbit', r: ring(o) }));
  map.append(el('circle', { class: 'sun', r: 6, fill: CLASSES[s.cls].color }));
  const rows = el('ul', { class: 'planets' });
  const inputs = {};
  for (const p of s.planets) {
    const surf = SURFACES[p.surface] || SURFACES.unknown;
    const a = planetAngle(s, p.orbit), r = ring(p.orbit);
    const px = r * Math.cos(a), py = r * Math.sin(a);
    const pr = 1.6 + p.size * 0.9;
    map.append(el('circle', { class: 'orbit used', r }));
    map.append(el('circle', {
      class: 'planet', cx: px, cy: py, r: pr, fill: surf.color,
      onclick: () => inputs[p.orbit].focus(),
    }, el('title', {}, `Orbit ${p.orbit} · ${surf.label}`)));
    map.append(el('text', { class: 'orbit-num', x: px + pr + 2, y: py - pr - 1 }, p.orbit));
    const note = (n.planets && n.planets[p.orbit]) || '';
    inputs[p.orbit] = el('input', {
      type: 'text', value: note, placeholder: 'Notes...',
      oninput: (e) => update((d) => { d.planets = d.planets || {}; d.planets[p.orbit] = e.target.value; }),
    });
    rows.append(el('li', {},
      el('span', { class: 'swatch', style: `background:${surf.color}` }),
      el('span', { class: 'orbit-label', title: surf.label }, `${p.orbit} · ${surf.label}`),
      inputs[p.orbit]));
  }
  return el('div', { class: 'field system' }, el('label', {}, `System · ${s.planets.length} planet${s.planets.length === 1 ? '' : 's'}`), map, rows);
}

function renderMarkerInspector(box) {
  const m = findMarker(selection.key);
  if (!m) { selection = null; return renderInspector(); }
  const update = (fn) => { fn(m); m.updated = now(); changed({ keepInspector: true }); };
  const kind = el('select', { onchange: (e) => update((d) => { d.kind = e.target.value; }) },
    Object.entries(MARKER_KINDS).map(([k, v]) => el('option', { value: k, selected: m.kind === k }, v.label)));
  const num = (prop, max) => el('input', {
    type: 'number', min: 0, max, step: 1, value: m[prop],
    oninput: (e) => { const v = parseFloat(e.target.value); if (!Number.isNaN(v)) update((d) => { d[prop] = Math.min(max, Math.max(0, v)); }); },
  });
  box.append(
    el('h2', {}, 'Marker'),
    el('div', { class: 'meta' }, `Created ${new Date(m.created).toLocaleString()}`),
    field('Type', kind),
    field('Title', el('input', {
      type: 'text', value: m.title || '', placeholder: 'e.g. Spemin blobship', 'data-focus': '',
      oninput: (e) => update((d) => { d.title = e.target.value; }),
    })),
    el('div', { class: 'row' }, field('X', num('x', W)), field('Y', num('y', H))),
    field('Notes', el('textarea', {
      rows: 6, value: m.note || '', placeholder: 'What happened?',
      oninput: (e) => update((d) => { d.note = e.target.value; }),
    })),
    el('div', { class: 'inspector-actions' },
      el('button', { onclick: () => flyTo(m.x, m.y) }, 'Center'),
      el('button', {
        class: 'danger',
        onclick: () => {
          if (!confirm(`Delete marker "${m.title || 'untitled'}"?`)) return;
          notes.markers = notes.markers.filter((x) => x !== m);
          selection = null;
          changed();
        },
      }, 'Delete')),
  );
}

function renderTerritoryInspector(box) {
  const t = findTerritory(selection.key);
  const n = territoryNote(t.id) || {};
  const title = el('h2', {}, territoryName(t));
  const update = (fn) => {
    fn(territoryNote(t.id, true)); territoryNote(t.id).updated = now();
    title.textContent = territoryName(t);
    changed({ keepInspector: true });
  };
  box.append(
    title,
    el('div', { class: 'meta' }, `Circle centered ${coordText(t.x, t.y)}, radius ${fmt(t.r)} (traced from the poster)`),
    el('div', { class: 'field' }, el('label', { class: 'check' },
      el('input', { type: 'checkbox', checked: !!n.discovered, onchange: (e) => update((d) => { d.discovered = e.target.checked; }) }),
      'Discovered')),
    field('Name', el('input', {
      type: 'text', value: n.name || '', placeholder: 'Whose space is this?', 'data-focus': '',
      oninput: (e) => update((d) => { d.name = e.target.value; }),
    })),
    field('Notes', el('textarea', {
      rows: 5, value: n.note || '',
      oninput: (e) => update((d) => { d.note = e.target.value; }),
    })),
  );
}

function renderFluxInspector(box) {
  const [x, y] = selection.key.split(',').map(Number);
  const o = fluxPartner(selection.key);
  box.append(
    el('h2', {}, 'Flux node'),
    el('div', { class: 'meta' }, `At ${x}, ${y}`),
    el('p', {}, `Fly into this flux and you come out at `, el('strong', {}, `${o.x}, ${o.y}`), '.'),
    el('div', { class: 'inspector-actions' },
      el('button', { onclick: () => select({ type: 'flux', key: `${o.x},${o.y}` }, true) }, 'Go to other end')),
  );
}

// ------------------------------------------------------------ sidebar lists

function renderJournal() {
  const q = $('#journal-filter').value.trim().toLowerCase();
  const items = [];
  for (const [key, n] of Object.entries(notes.stars)) {
    const s = findStar(key);
    if (!s) continue;
    const planetNotes = Object.entries(n.planets || {}).map(([o, t]) => `${o}: ${t}`).join(' · ');
    items.push({
      sel: { type: 'star', key }, swatch: CLASSES[s.cls].color, title: starTitle(s),
      snippet: n.note || planetNotes || (n.visited ? `Visited${n.visitedOn ? ` ${n.visitedOn}` : ''}` : ''),
      coords: `${s.x}, ${s.y}`, updated: n.updated || '', search: `${n.name || ''} ${n.note || ''} ${planetNotes} ${s.cls} ${key}`,
    });
  }
  for (const m of notes.markers) {
    items.push({
      sel: { type: 'marker', key: m.id }, marker: m.kind, title: m.title || `${MARKER_KINDS[m.kind]?.label ?? 'Marker'} (untitled)`,
      snippet: m.note || '', coords: coordText(m.x, m.y), updated: m.updated || m.created,
      search: `${m.title || ''} ${m.note || ''} ${m.kind} ${m.x},${m.y}`,
    });
  }
  for (const t of overlay.territories) {
    const n = notes.territories[t.id];
    if (!n || !(n.discovered || n.note)) continue;
    items.push({
      sel: { type: 'territory', key: t.id }, title: territoryName(t), snippet: n.note || 'Territory',
      coords: '', updated: n.updated || '', search: `${n.name || ''} ${n.note || ''}`,
    });
  }
  const list = $('#journal');
  list.replaceChildren();
  const shown = items.filter((i) => !q || `${i.title} ${i.search}`.toLowerCase().includes(q))
    .sort((a, b) => b.updated.localeCompare(a.updated));
  if (!shown.length) {
    list.append(el('li', { class: 'empty' }, q ? 'No matches.' : 'Nothing yet. Select a star to mark it visited or add notes.'));
  }
  for (const i of shown) {
    const isSel = selection && selection.type === i.sel.type && selection.key === i.sel.key;
    const icon = i.swatch ? el('span', { class: 'swatch', style: `background:${i.swatch}` })
      : i.marker ? el('span', { class: 'swatch', style: `background:var(--marker-${i.marker});border-radius:2px` })
        : el('span', { class: 'swatch', style: 'background:rgba(25,25,60,.5);border-style:dashed' });
    list.append(el('li', { class: isSel ? 'selected' : null, onclick: () => select(i.sel, true) },
      icon,
      el('span', { class: 'what' }, el('span', { class: 'title' }, i.title), i.snippet ? el('span', { class: 'snippet' }, i.snippet) : null),
      el('span', { class: 'coords' }, i.coords)));
  }
}

function renderTerritoryList() {
  const list = $('#territories');
  list.replaceChildren();
  for (const t of overlay.territories) {
    const n = notes.territories[t.id] || {};
    const isSel = selection?.type === 'territory' && selection.key === t.id;
    list.append(el('li', { class: isSel ? 'selected' : null, onclick: () => select({ type: 'territory', key: t.id }, true) },
      el('input', {
        type: 'checkbox', checked: !!n.discovered, title: 'Discovered',
        onclick: (e) => e.stopPropagation(),
        onchange: (e) => {
          const d = territoryNote(t.id, true); d.discovered = e.target.checked; d.updated = now();
          changed();
        },
      }),
      el('span', { class: 'what' }, el('span', { class: 'title' }, territoryName(t)))));
  }
}

function renderLayerToggles() {
  const box = $('#layer-toggles');
  box.replaceChildren();
  for (const [id, label] of LAYERS) {
    box.append(el('label', { class: 'check' },
      el('input', {
        type: 'checkbox', checked: layerOn(id),
        onchange: (e) => { prefs.layers[id] = e.target.checked; savePrefs(); applyLayers(); },
      }), label));
  }
  const legend = $('#class-toggles');
  legend.replaceChildren();
  const counts = {};
  for (const s of mapData.stars) counts[s.cls] = (counts[s.cls] || 0) + 1;
  for (const [cls, c] of Object.entries(CLASSES)) {
    legend.append(el('label', { class: 'check', title: `${cls}-class stars` },
      el('input', {
        type: 'checkbox', checked: !prefs.hiddenClasses.includes(cls),
        onchange: (e) => {
          const set = new Set(prefs.hiddenClasses);
          if (e.target.checked) set.delete(cls); else set.add(cls);
          prefs.hiddenClasses = [...set];
          savePrefs(); renderStars(); renderLabels();
        },
      }),
      el('span', { class: 'swatch', style: `background:${c.color}` }), `${cls} ${c.name}`,
      el('span', { class: 'count' }, counts[cls] || 0)));
  }
}

function applyLayers() {
  for (const id of ['grid', 'nebulae', 'flux', 'stars', 'visited', 'territories', 'lines', 'labels', 'markers', 'start', 'axes']) {
    $(`#layer-${id}`).classList.toggle('off', !layerOn(id));
  }
  renderStars(); renderTerritories();
}

// ------------------------------------------------------------ persistence

let saveTimer;
let serverOk = false;

function setSaveStatus(text, error = false) {
  const s = $('#save-status');
  s.textContent = text;
  s.classList.toggle('error', error);
}

function changed({ keepInspector = false } = {}) {
  renderMapData();
  renderLists();
  if (!keepInspector) renderInspector();
  setSaveStatus('Unsaved changes...');
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNotes, 600);
}

function backupLocally() {
  try { localStorage.setItem('sf-starmap-notes', JSON.stringify(notes)); return true; } catch { return false; }
}

async function saveNotes(keepalive = false) {
  clearTimeout(saveTimer);
  notes.savedAt = now();
  try {
    const res = await fetch('api/notes', {
      method: 'PUT', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(notes, null, 1), keepalive,
    });
    if (!res.ok) throw new Error(await res.text());
    const info = await res.json();
    serverOk = true;
    try { localStorage.removeItem('sf-starmap-notes'); } catch { /* ignore */ }
    setSaveStatus(`Saved ${new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`);
    $('#save-status').title = info.savedTo || '';
  } catch (err) {
    serverOk = false;
    const kept = backupLocally();
    setSaveStatus(kept ? 'Map server not running - changes kept in this browser for now' : `Save failed: ${err.message}`, true);
  }
}

async function loadNotes() {
  let local = null;
  try { local = JSON.parse(localStorage.getItem('sf-starmap-notes')); } catch { /* none */ }
  try {
    const res = await fetch('api/notes');
    if (!res.ok) throw new Error(res.statusText);
    const server = await res.json();
    serverOk = true;
    // A local copy only exists if a save to the server failed; keep whichever is newer.
    if (local && (!server.savedAt || local.savedAt > server.savedAt)) {
      notes = normalizeNotes(local);
      saveNotes();
    } else {
      notes = normalizeNotes(server);
      setSaveStatus('Notes loaded');
    }
  } catch {
    notes = normalizeNotes(local || {});
    setSaveStatus('Map server not running - notes kept in this browser only', true);
  }
}

function normalizeNotes(n) {
  const base = emptyNotes();
  if (!n || typeof n !== 'object') return base;
  return {
    ...base, ...n,
    stars: n.stars && typeof n.stars === 'object' ? n.stars : {},
    markers: Array.isArray(n.markers) ? n.markers : [],
    territories: n.territories && typeof n.territories === 'object' ? n.territories : {},
    general: typeof n.general === 'string' ? n.general : '',
  };
}

$('#general-notes').addEventListener('input', (e) => {
  notes.general = e.target.value;
  setSaveStatus('Unsaved changes...');
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNotes, 600);
});

$('#journal-filter').addEventListener('input', renderJournal);

$('#export').onclick = () => {
  const blob = new Blob([JSON.stringify(notes, null, 1)], { type: 'application/json' });
  const a = el('a', { href: URL.createObjectURL(blob), download: `starmap-notes-${today()}.json` });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
};

$('#import').onchange = async (e) => {
  const file = e.target.files[0];
  e.target.value = '';
  if (!file) return;
  try {
    const data = JSON.parse(await file.text());
    if (!data || typeof data !== 'object' || !('stars' in data || 'markers' in data)) throw new Error('Not a starmap notes file.');
    if (!confirm('Replace all current notes with the imported file? (Export first if you want a copy.)')) return;
    notes = normalizeNotes(data);
    selection = null;
    $('#general-notes').value = notes.general;
    changed();
  } catch (err) {
    alert(`Import failed: ${err.message}`);
  }
};

window.addEventListener('beforeunload', () => {
  if (saveTimer) saveNotes(true);
});

// Lets the server know a map is still open; it exits a few minutes after the last ping.
setInterval(() => { fetch('api/ping', { method: 'POST' }).catch(() => {}); }, 30000);

// ------------------------------------------------------------ startup

window.addEventListener('resize', () => {
  const z = view.s / fitScale;
  computeFit();
  view.s = fitScale * z;
  clampView(); applyView();
});

async function start() {
  try {
    [mapData, overlay] = await Promise.all([
      fetch('map-data.json').then((r) => r.json()),
      fetch('poster-overlay.json').then((r) => r.json()),
    ]);
  } catch {
    $('#inspector').replaceChildren(el('p', { class: 'empty' },
      'Could not load the map data. Start the map with "Starflight Starmap.bat" rather than opening index.html directly.'));
    return;
  }
  await loadNotes();
  $('#general-notes').value = notes.general;
  renderStatic();
  renderLayerToggles();
  applyLayers();
  computeFit();
  if (prefs.view) {
    view = { cx: prefs.view.cx, cy: prefs.view.cy, s: fitScale * prefs.view.z };
    clampView(); applyView();
  } else {
    fitView();
  }
  renderMapData();
  renderLists();
}

start();

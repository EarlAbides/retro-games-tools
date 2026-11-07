'use strict';

// The world is 256 x 256 tiles; view coordinates are in tiles, with x across and y down, the same
// as the game's own (and the x/y in the save file).
const WORLD = 256, TILE = 16, TOWN = 32, DNG = 8, ROOM = 11;

const EGA = [0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
             0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF];

const TERRAIN = {
  0: 'Deep water', 1: 'Water', 2: 'Shallows', 3: 'Swamp', 4: 'Grass', 5: 'Scrub', 6: 'Forest', 7: 'Hills', 8: 'Mountains',
  9: 'Dungeon', 10: 'Town', 11: 'Keep', 12: 'Village', 13: 'Castle', 14: 'Castle', 15: 'Castle', 0x17: 'Bridge', 0x1D: 'Ruin',
  0x1E: 'Shrine', 0x3D: 'Ankh', 0x46: 'Volcano', 0x4C: 'Lava',
};
const OVERVIEW = {
  0: '#14246f', 1: '#1c2f8f', 2: '#2d4cb8', 3: '#3d5a35', 4: '#3c7a2c', 5: '#55802f', 6: '#1d5220', 7: '#7d6a45', 8: '#7d7468',
  0x17: '#8a5a2b', 0x46: '#a33', 0x4C: '#b5461f',
};

// min: the zoom (screen px per tile) at which that kind's labels appear
const KINDS = {
  castle:  { label: 'Castle',  group: 'Castles and keeps', layer: 'castle',  min: 2, order: 0, color: '#ffffff' },
  keep:    { label: 'Keep',    group: 'Castles and keeps', layer: 'castle',  min: 3, order: 1, color: '#ffffff' },
  town:    { label: 'Town',    group: 'Towns and villages', layer: 'town',   min: 3, order: 2, color: '#fff3c4' },
  village: { label: 'Village', group: 'Towns and villages', layer: 'town',   min: 4, order: 3, color: '#fff3c4' },
  ruin:    { label: 'Ruins',   group: 'Towns and villages', layer: 'town',   min: 4, order: 4, color: '#c9bb96' },
  dungeon: { label: 'Dungeon', group: 'Dungeons',           layer: 'dungeon', min: 4, order: 5, color: '#ff9a8a' },
  shrine:  { label: 'Shrine',  group: 'Shrines',            layer: 'shrine', min: 5, order: 6, color: '#9fe8ff' },
};
const GROUPS = ['Castles and keeps', 'Towns and villages', 'Dungeons', 'Shrines'];

const LAYERS = [
  ['castle', 'Castles'], ['town', 'Towns'], ['dungeon', 'Dungeons'], ['shrine', 'Shrines'],
  ['party', 'Party'], ['visited', 'Visited marks'], ['grid', 'Tile grid'],
];
const LAYER_DEFAULTS = { grid: false };

// Everything that could spoil the game starts hidden. Nothing here gives anything away itself.
const REVEALS = [
  ['gates', 'Moongates', 'Where they open, and where they lead.'],
  ['secrets', 'Secret places', 'Places this map doesn\'t name.'],
  ['items', 'Hidden items', 'What to search for, and where.'],
  ['people', 'Townsfolk', 'Who they are, and all they\'ll say.'],
  ['dungeons', 'Dungeon maps', 'Every level, room, trap and treasure.'],
];

const MOONS = ['New', 'Waxing crescent', 'First quarter', 'Waxing gibbous', 'Full', 'Waning gibbous', 'Last quarter', 'Waning crescent'];
const VIRTUES = ['Honesty', 'Compassion', 'Valor', 'Justice', 'Sacrifice', 'Honor', 'Spirituality', 'Humility'];

// The Search command's table, by the handler each entry calls. Conditions are from those handlers.
const ITEMS = {
  mandrake:     { name: 'Mandrake',          note: 'Only when both moons are new. It grows back after you\'ve moved on a while.' },
  nightshade:   { name: 'Nightshade',        note: 'Only when both moons are new. It grows back after you\'ve moved on a while.' },
  bell:         { name: 'Bell of Courage',   have: (p) => p.items & 0x10 },
  horn:         { name: 'Silver Horn',       have: (p) => p.items & 0x100 },
  wheel:        { name: 'Wheel of the H.M.S. Cape', have: (p) => p.items & 0x200 },
  skull:        { name: 'Skull of Mondain',  note: 'Only when both moons are new.', have: (p) => p.items & 3 },
  blackstone:   { name: 'Black Stone',       note: 'Only when both moons are new.', have: (p) => p.stones & 0x80 },
  whitestone:   { name: 'White Stone',       have: (p) => p.stones & 0x40 },
  book:         { name: 'Book of Truth',     have: (p) => p.items & 8 },
  candle:       { name: 'Candle of Love',    have: (p) => p.items & 4 },
  telescope:    { name: 'Telescope',         note: 'Search it, then pick A-P to look over a town.' },
  mysticarmour: { name: 'Mystic Robes',      note: 'Only once you are an Avatar in all eight virtues.', have: (p) => p.mysticArmour },
  mysticweapon: { name: 'Mystic Swords',     note: 'Only once you are an Avatar in all eight virtues.', have: (p) => p.mysticWeapon },
  rune:         { name: 'Rune',              have: (p, it) => p.runes & it.bit },
};
const itemName = (it) => (it.key === 'rune' ? `Rune of ${VIRTUES[Math.log2(it.bit)]}` : ITEMS[it.key].name);

const $ = (sel) => document.querySelector(sel);
const canvas = $('#map');
const ctx = canvas.getContext('2d');

let places = [], gates = [], items = [], byPos = new Map(), world, overview, worldBytes;
let shapes = [], sprites = [];                // the 256 tiles, opaque and with black see-through
const gameFiles = {};                         // file name -> bytes
let party = null;
let notes = emptyNotes();
let prefs = loadPrefs();
let view = { cx: WORLD / 2, cy: WORLD / 2, s: 4 };  // s = screen px per tile
let fitScale = 4;
let selection = null;                         // { type: 'place'|'party'|'gate'|'item', id }
let townView = { place: null, floor: 0, person: null };
let dungeonView = { place: null, level: 0, room: null };

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
const revealed = (id) => !!prefs.reveals[id];
const placeNote = (id, create = false) => {
  if (!notes.places[id] && create) notes.places[id] = {};
  return notes.places[id];
};
const isVisited = (p) => !!(notes.places[p.id] && notes.places[p.id].visited);
const findPlace = (id) => places.find((p) => p.id === id);
const hasParty = () => party && party.members && party.members.length > 0;
const visiblePlaces = () => places.filter((p) => !p.secret || revealed('secrets'));
const onMap = (p) => p.x !== null && p.y !== null;
const worldTile = (x, y) => worldBytes[((y >> 5) * 8 + (x >> 5)) * 1024 + (y & 31) * 32 + (x & 31)];
const terrainName = (t) => TERRAIN[t] || 'Landmark';
// The sextant reads each coordinate as two letters.
const sextant = (x, y) => {
  const two = (v) => `${String.fromCharCode(65 + (v >> 4))}'${String.fromCharCode(65 + (v & 15))}"`;
  return `${two(y)} ${two(x)}`;
};

function loadPrefs() {
  const base = { layers: {}, reveals: {}, view: null };
  try { return Object.assign(base, JSON.parse(localStorage.getItem('u4-map-prefs')) || {}); }
  catch { return base; }
}
function savePrefs() {
  try { localStorage.setItem('u4-map-prefs', JSON.stringify(prefs)); } catch { /* private window etc. */ }
}

function nearestPlace(x, y) {
  let best = null, bestD = Infinity;
  for (const p of visiblePlaces()) {
    if (!onMap(p)) continue;
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

// Where the party is, in words. Saves only happen on the surface or in a dungeon.
function partyWhere() {
  const p = party;
  if (p.loc >= 17 && p.loc <= 24) {
    const d = findPlace(p.loc);
    return d && (!d.secret || revealed('secrets')) ? `In ${d.name}, level ${p.level + 1}` : 'Underground';
  }
  return `${p.x}, ${p.y} · ${whereText(p.x, p.y)}`;
}

// ------------------------------------------------------------ game files

async function fetchBytes(name) {
  if (gameFiles[name]) return gameFiles[name];
  const r = await fetch(`/api/game/${name}`);
  if (!r.ok) throw new Error(`Couldn't read ${name} from the game folder.`);
  gameFiles[name] = new Uint8Array(await r.arrayBuffer());
  return gameFiles[name];
}

// SHAPES.EGA: 256 tiles of 16 x 16, four bits per pixel, high nibble first.
function decodeShapes(b, seeThrough) {
  const out = [];
  for (let t = 0; t < 256; t++) {
    const c = document.createElement('canvas');
    c.width = c.height = TILE;
    const cx = c.getContext('2d');
    const img = cx.createImageData(TILE, TILE);
    for (let i = 0; i < TILE * TILE; i++) {
      const byte = b[t * 128 + (i >> 1)];
      const v = i % 2 ? byte & 15 : byte >> 4;
      img.data[i * 4] = EGA[v] >> 16; img.data[i * 4 + 1] = (EGA[v] >> 8) & 255; img.data[i * 4 + 2] = EGA[v] & 255;
      img.data[i * 4 + 3] = seeThrough && v === 0 ? 0 : 255;
    }
    cx.putImageData(img, 0, 0);
    out.push(c);
  }
  return out;
}

function buildWorld() {
  world = document.createElement('canvas');
  world.width = world.height = WORLD * TILE;
  overview = document.createElement('canvas');
  overview.width = overview.height = WORLD;
  const g = world.getContext('2d'), o = overview.getContext('2d');
  for (let y = 0; y < WORLD; y++) {
    for (let x = 0; x < WORLD; x++) {
      const t = worldTile(x, y);
      g.drawImage(shapes[t], x * TILE, y * TILE);
      o.fillStyle = OVERVIEW[t] || OVERVIEW[4];     // places sit on grass
      o.fillRect(x, y, 1, 1);
    }
  }
}

// ------------------------------------------------------------ towns

// A .ULT file: the 32 x 32 map, then 32 slots for people, one table per field.
function townPeople(u) {
  const out = [];
  for (let i = 0; i < 32; i++) {
    const tile = u[1024 + i];
    if (!tile) continue;
    out.push({ slot: i, tile, x: u[1024 + 32 + i], y: u[1024 + 64 + i], move: u[1024 + 192 + i], conv: u[1024 + 224 + i] });
  }
  return out;
}

function drawTown(target, u, marks = []) {
  target.width = target.height = TOWN * TILE;
  const g = target.getContext('2d');
  for (let y = 0; y < TOWN; y++) {
    for (let x = 0; x < TOWN; x++) g.drawImage(shapes[u[y * TOWN + x]], x * TILE, y * TILE);
  }
  for (const n of townPeople(u)) g.drawImage(sprites[n.tile], n.x * TILE, n.y * TILE);
  for (const m of marks) {
    g.strokeStyle = m.color; g.lineWidth = 2;
    g.strokeRect(m.x * TILE + 1, m.y * TILE + 1, TILE - 2, TILE - 2);
  }
}

// A .TLK file: 16 records of 288 bytes. Three bytes of flags, then twelve strings in order.
function parseTalk(b) {
  const out = [];
  for (let r = 0; r < 16; r++) {
    const parts = [];
    let at = r * 288 + 3;
    for (let k = 0; k < 12; k++) {
      let s = '';
      for (; b[at]; at++) s += b[at] === 10 ? ' ' : String.fromCharCode(b[at]);
      parts.push(s.replace(/\s+/g, ' ').trim());
      at++;
    }
    const [name, pronoun, look, job, health, answer1, answer2, question, yes, no, word1, word2] = parts;
    out.push({ name, pronoun, look, job, health, answer1, answer2, question, yes, no, word1, word2 });
  }
  return out;
}

function townItems(p, floor) {
  if (!revealed('items') || (p.id === 1 && floor !== 0)) return [];
  return items.filter((it) => it.loc === p.id);
}

async function openTown(p) {
  if (townView.place !== p.id) { townView.floor = 0; townView.person = null; }
  townView.place = p.id;
  await renderTown();
  if (!$('#town-dialog').open) $('#town-dialog').showModal();
}

async function renderTown() {
  const p = findPlace(townView.place);
  if (!p) return;
  const u = gameFiles[p.ult[townView.floor]];
  const showPeople = revealed('people');
  // Talk files are fetched on demand, so this is the one thing here that can fail once the page has loaded.
  let talk = null, talkFailed = false;
  if (showPeople && p.tlk) {
    try { talk = parseTalk(await fetchBytes(p.tlk)); } catch { talkFailed = true; }
  }
  const people = townPeople(u);
  const here = townItems(p, townView.floor);

  $('#town-title').textContent = p.name;
  $('#town-floors').replaceChildren(...(p.ult.length > 1 ? p.ult.map((_, i) => el('button', {
    class: i === townView.floor ? 'current' : '', title: `Floor ${i + 1} (key ${i + 1})`,
    onclick: () => { townView.floor = i; townView.person = null; renderTown(); },
  }, `Floor ${i + 1}`)) : []));

  const person = people.find((n) => n.slot === townView.person);
  const marks = here.map((it) => ({ x: it.x, y: it.y, color: '#ff7be0' }));
  if (person) marks.push({ x: person.x, y: person.y, color: '#ffffff' });
  const c = $('#town-big');
  drawTown(c, u, marks);
  const k = Math.max(1, Math.floor(Math.min(window.innerWidth - 420, window.innerHeight - 110) / (TOWN * TILE) * 8) / 8);
  c.style.width = c.style.height = `${TOWN * TILE * k}px`;

  const side = [];
  if (!showPeople) side.push(el('p', { class: 'hint' }, 'Turn on Townsfolk under Reveals to read what people here will say.'));
  if (here.length) {
    side.push(el('ul', { class: 'list' }, here.map((it) => el('li', { onclick: () => select({ type: 'item', id: it.n }) },
      itemName(it), el('span', { class: 'sub' }, `${it.x}, ${it.y}`)))));
    side.push(el('p', { class: 'hint' }, 'Pink boxes mark where to search.'));
  }
  if (talkFailed) side.push(el('p', { class: 'hint' }, `Couldn't load what people here say. Is the map server still running? Start it again with "Ultima 4 Map.bat", then reopen this town.`));
  if (showPeople && talk) {
    // Several people can share one talk record (all the children, say), so list each record once.
    const records = new Map();
    for (const n of people) if (n.conv >= 1 && n.conv <= 16 && !records.has(n.conv)) records.set(n.conv, n);
    const named = [...records.values()].sort((a, b) => talk[a.conv - 1].name.localeCompare(talk[b.conv - 1].name));
    side.push(el('ul', { class: 'list person-list' }, named.map((n) => el('li', {
      class: person && person.conv === n.conv ? 'selected' : '',
      onclick: () => { townView.person = n.slot; renderTown(); },
    }, talk[n.conv - 1].name, el('span', { class: 'sub' }, talk[n.conv - 1].look)))));
    if (person) side.push(renderPerson(person, talk));
    else side.push(el('p', { class: 'hint' }, 'Click someone on the map or in the list.'));
  }
  $('#town-side').replaceChildren(...side);
}

function renderPerson(n, talk) {
  const moves = { 0: 'Stays put', 1: 'Wanders', 0x80: 'Comes after you', 0xFF: 'Attacks' };
  const move = moves[n.move];
  if (n.conv < 1 || n.conv > 16) {
    return el('div', { class: 'person' }, el('p', {}, 'Nothing in the talk file for this one.'), move && el('p', { class: 'hint' }, move));
  }
  const t = talk[n.conv - 1];
  const row = (word, text) => (text ? [el('dt', {}, word), el('dd', {}, text)] : []);
  return el('div', { class: 'person' },
    el('h3', {}, t.name),
    el('p', { class: 'look' }, `${t.look}${move ? ` · ${move}` : ''}`),
    el('dl', {}, row('JOB', t.job), row('HEAL', t.health), row(t.word1, t.answer1), row(t.word2, t.answer2)),
    t.question && el('p', { class: 'question' }, t.question),
    t.question && el('dl', {}, row('YES', t.yes), row('NO', t.no)));
}

// ------------------------------------------------------------ dungeons

// A .DNG file: 8 levels of 8 x 8 cells, one byte each, then rooms of 256 bytes. The high nibble
// says what a cell is and the low nibble which one.
function cellInfo(v, place) {
  const low = v & 15;
  switch (v & 0xF0) {
    case 0x00: return { name: 'Corridor' };
    case 0x10: return { name: 'Ladder up', glyph: '▲', color: '#7dff7d' };
    case 0x20: return { name: 'Ladder down', glyph: '▼', color: '#ff8a5c' };
    case 0x30: return { name: 'Ladder up and down', glyph: '◆', color: '#ffd23f' };
    case 0x40: return { name: 'Chest', glyph: '$', color: '#ffd23f' };
    case 0x50: return { name: 'Hole in the ceiling', glyph: '○', color: '#c9bb96' };
    case 0x60: return { name: 'Hole in the floor', glyph: '●', color: '#c9bb96' };
    case 0x70: return { name: 'Magic orb', glyph: '◉', color: '#55ffff' };
    case 0x80: {
      const trap = { 0: 'Wind trap', 1: 'Falling rocks', 14: 'Pit' }[low] || `Trap ${low}`;
      return { name: trap, glyph: '!', color: '#ff5555' };
    }
    case 0x90: {
      const kind = ['Fountain', 'Healing fountain', 'Acid fountain', 'Curing fountain', 'Poison fountain'][low] || 'Fountain';
      return { name: kind, glyph: '≈', color: ['#7fd0ff', '#7dff7d', '#ff5555', '#55ffff', '#c86dff'][low] || '#7fd0ff' };
    }
    case 0xA0: {
      const kind = ['Poison field', 'Energy field', 'Fire field', 'Sleep field'][low] || 'Field';
      return { name: kind, glyph: '▒', color: ['#55ff55', '#55ffff', '#ff8a5c', '#c86dff'][low] || '#ffffff' };
    }
    case 0xB0: {
      const stones = { 17: 'Blue', 18: 'Yellow', 19: 'Red', 20: 'Green', 21: 'Orange', 22: 'Purple' };
      const stone = stones[place.id];
      return { name: stone ? `Altar of the ${stone} Stone` : 'Altar', glyph: '†', color: '#ffffff' };
    }
    case 0xC0: return { name: 'Door', door: true };
    case 0xD0: return { name: 'Room', glyph: 'R', color: '#ffb6d9', room: low };
    case 0xE0: return { name: 'Secret door', secret: true };
    case 0xF0: return { name: 'Wall', wall: true };
    default: return { name: `Unknown ${v.toString(16)}` };
  }
}

// Rooms are numbered within a level, except in the Abyss, whose 64 rooms go up by 16 every two levels.
const roomNumber = (place, level, low) => (place.id === 24 ? (level >> 1) * 16 + low : low);

function drawDungeon(target, d, place, level, cell, marks = {}) {
  const dpr = window.devicePixelRatio || 1;
  const px = DNG * cell;
  target.width = target.height = Math.round(px * dpr);
  target.style.width = target.style.height = `${px}px`;
  const c = target.getContext('2d');
  c.setTransform(dpr, 0, 0, dpr, 0, 0);
  c.fillStyle = '#17130e';
  c.fillRect(0, 0, px, px);
  for (let y = 0; y < DNG; y++) {
    for (let x = 0; x < DNG; x++) {
      const info = cellInfo(d[level * 64 + y * DNG + x], place), x0 = x * cell, y0 = y * cell;
      if (info.wall || info.secret) {
        c.fillStyle = '#6e665a';
        c.fillRect(x0, y0, cell, cell);
        c.fillStyle = '#857c6e';
        c.fillRect(x0, y0, cell, 3);
      }
      if (info.secret) {
        c.strokeStyle = '#ffd23f'; c.lineWidth = 2; c.setLineDash([4, 3]);
        c.strokeRect(x0 + cell * 0.2, y0 + cell * 0.12, cell * 0.6, cell * 0.8);
        c.setLineDash([]);
      }
      if (info.door) {
        c.fillStyle = '#7a4a1e';
        c.fillRect(x0 + cell * 0.18, y0 + cell * 0.08, cell * 0.64, cell * 0.84);
        c.strokeStyle = '#c98a45'; c.lineWidth = 2;
        c.strokeRect(x0 + cell * 0.18, y0 + cell * 0.08, cell * 0.64, cell * 0.84);
      }
      if (info.glyph) {
        c.font = `700 ${Math.round(cell * 0.58)}px "Segoe UI", "Segoe UI Symbol", system-ui, sans-serif`;
        c.textAlign = 'center'; c.textBaseline = 'middle';
        c.fillStyle = info.color;
        c.fillText(info.glyph, (x + 0.5) * cell, (y + 0.54) * cell);
      }
    }
  }
  c.strokeStyle = 'rgba(255,255,255,0.08)'; c.lineWidth = 1;
  c.beginPath();
  for (let i = 1; i < DNG; i++) {
    c.moveTo(i * cell + 0.5, 0); c.lineTo(i * cell + 0.5, px);
    c.moveTo(0, i * cell + 0.5); c.lineTo(px, i * cell + 0.5);
  }
  c.stroke();
  if (marks.party) {
    c.strokeStyle = '#ffd23f'; c.lineWidth = 3;
    c.strokeRect(marks.party.x * cell + 2, marks.party.y * cell + 2, cell - 4, cell - 4);
  }
  if (marks.selected) {
    c.strokeStyle = '#ffffff'; c.lineWidth = 2; c.setLineDash([5, 4]);
    c.strokeRect(marks.selected.x * cell + 1, marks.selected.y * cell + 1, cell - 2, cell - 2);
    c.setLineDash([]);
  }
}

function drawRoom(target, d, n) {
  const o = DNG * DNG * 8 + n * 256;
  target.width = target.height = ROOM * TILE;
  const g = target.getContext('2d');
  for (let y = 0; y < ROOM; y++) {
    for (let x = 0; x < ROOM; x++) g.drawImage(shapes[d[o + 128 + y * ROOM + x]], x * TILE, y * TILE);
  }
  for (let i = 0; i < 16; i++) {
    const tile = d[o + 16 + i];
    if (tile) g.drawImage(sprites[tile], d[o + 32 + i] * TILE, d[o + 48 + i] * TILE);
  }
  // Up to four floor triggers: a tile, then its position with x in the high nibble.
  g.strokeStyle = '#ffd23f'; g.lineWidth = 2;
  for (let i = 0; i < 4; i++) {
    const pos = d[o + i * 4 + 1];
    if (!d[o + i * 4] && !pos) continue;
    g.strokeRect((pos >> 4) * TILE + 1, (pos & 15) * TILE + 1, TILE - 2, TILE - 2);
  }
}

function openDungeon(p) {
  if (dungeonView.place !== p.id) {
    dungeonView.place = p.id; dungeonView.room = null;
    // start on the party's level if they're down there
    dungeonView.level = hasParty() && party.loc === p.id && party.level < 8 ? party.level : 0;
  }
  renderDungeon();
  if (!$('#dungeon-dialog').open) $('#dungeon-dialog').showModal();
}

function renderDungeon() {
  const p = findPlace(dungeonView.place);
  if (!p) return;
  const d = gameFiles[p.dng], level = dungeonView.level;
  $('#dungeon-title').textContent = p.name;
  $('#dungeon-levels').replaceChildren(...Array.from({ length: 8 }, (_, i) => el('button', {
    class: i === level ? 'current' : '', title: `Level ${i + 1} (key ${i + 1})`,
    onclick: () => { dungeonView.level = i; dungeonView.room = null; renderDungeon(); },
  }, String(i + 1))));

  const cell = dungeonCellSize();
  const here = hasParty() && party.loc === p.id && party.level === level;
  drawDungeon($('#dungeon-big'), d, p, level, cell, {
    party: here ? { x: party.dx, y: party.dy } : null,
    selected: dungeonView.room ? dungeonView.room.at : null,
  });

  // legend: what's on this level
  const seen = new Map();
  for (let i = 0; i < 64; i++) {
    const info = cellInfo(d[level * 64 + i], p);
    const key = info.room !== undefined ? 'Room' : info.name;
    if (!info.wall && key !== 'Corridor' && !seen.has(key)) seen.set(key, info);
  }
  $('#dungeon-legend').replaceChildren(...[...seen].map(([key, info]) => {
    const sw = el('span', { class: 'sw' }, info.glyph || '');
    if (info.color) sw.style.color = info.color;
    if (info.door) sw.style.background = '#7a4a1e';
    if (info.secret) sw.style.background = '#6e665a';
    return el('li', {}, sw, el('span', {}, key));
  }));

  const room = $('#dungeon-room');
  if (dungeonView.room) {
    const c = el('canvas');
    drawRoom(c, d, dungeonView.room.n);
    room.replaceChildren(el('h3', {}, `Room ${dungeonView.room.n + 1}`), c,
      el('p', { class: 'hint' }, 'As you enter it, with its monsters. Stepping on a yellow box changes other tiles in the room, such as opening a wall.'));
  } else {
    room.replaceChildren();
  }
}

const dungeonCellSize = () => Math.max(40, Math.min(84, Math.floor(Math.min(window.innerWidth - 420, window.innerHeight - 170) / DNG)));

function dungeonCellAt(e) {
  const r = $('#dungeon-big').getBoundingClientRect(), cell = r.width / DNG;
  const x = Math.floor((e.clientX - r.left) / cell), y = Math.floor((e.clientY - r.top) / cell);
  return x >= 0 && y >= 0 && x < DNG && y < DNG ? { x, y } : null;
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
  return x >= 0 && y >= 0 && x < WORLD && y < WORLD ? { x, y } : null;
}

function computeFit() {
  const { w, h } = size();
  fitScale = Math.min(w, h) / WORLD * 0.98;
}
function clampView() {
  view.s = Math.min(64, Math.max(fitScale * 0.75, view.s));
  view.cx = Math.min(WORLD, Math.max(0, view.cx));
  view.cy = Math.min(WORLD, Math.max(0, view.cy));
}
function fit() {
  computeFit();
  view = { cx: WORLD / 2, cy: WORLD / 2, s: fitScale };
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
  const here = visiblePlaces().filter((p) => onMap(p) && layerOn(KINDS[p.kind].layer));

  // The game's tiles are dithered, so shrunk below about half size they turn to noise;
  // zoomed out, draw flat terrain colors with a dot for each place instead.
  const tiles = s >= 10;
  ctx.imageSmoothingEnabled = tiles && s < TILE;
  ctx.imageSmoothingQuality = 'high';
  const k = tiles ? TILE : 1;
  ctx.drawImage(tiles ? world : overview, 0, 0, WORLD * k, WORLD * k, ox, oy, WORLD * s, WORLD * s);
  if (!tiles) drawPlaceDots(here, ox, oy, s);

  if (layerOn('grid') && s >= 8) {
    ctx.strokeStyle = 'rgba(255,255,255,0.14)'; ctx.lineWidth = 1;
    ctx.beginPath();
    const x0 = Math.max(0, Math.floor(-ox / s)), x1 = Math.min(WORLD, Math.ceil((w - ox) / s));
    const y0 = Math.max(0, Math.floor(-oy / s)), y1 = Math.min(WORLD, Math.ceil((h - oy) / s));
    for (let x = x0; x <= x1; x++) { ctx.moveTo(Math.round(ox + x * s) + 0.5, oy + y0 * s); ctx.lineTo(Math.round(ox + x * s) + 0.5, oy + y1 * s); }
    for (let y = y0; y <= y1; y++) { ctx.moveTo(ox + x0 * s, Math.round(oy + y * s) + 0.5); ctx.lineTo(ox + x1 * s, Math.round(oy + y * s) + 0.5); }
    ctx.stroke();
  }

  if (layerOn('visited')) {
    ctx.strokeStyle = getCss('--visited'); ctx.lineWidth = 2;
    for (const p of here) {
      if (isVisited(p)) ctx.strokeRect(ox + p.x * s - 1, oy + p.y * s - 1, s + 2, s + 2);
    }
  }

  if (revealed('gates')) drawGates(ox, oy, s);
  if (revealed('items')) drawItems(ox, oy, s);
  drawLabels(here, ox, oy, s);

  if (selection && selection.type !== 'party') {
    const t = selectionTarget();
    if (t && t.x !== null && !(selection.type === 'item' && t.loc !== 0)) {
      const pad = Math.max(3, s * 0.25);
      ctx.strokeStyle = getCss('--select'); ctx.lineWidth = 2;
      ctx.setLineDash([5, 4]);
      ctx.strokeRect(ox + t.x * s - pad, oy + t.y * s - pad, s + 2 * pad, s + 2 * pad);
      ctx.setLineDash([]);
    }
  }

  if (layerOn('party') && hasParty()) drawParty(ox, oy, s);
}

const cssCache = {};
function getCss(name) {
  return cssCache[name] ??= getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

function selectionTarget() {
  if (!selection) return null;
  if (selection.type === 'place') return findPlace(selection.id);
  if (selection.type === 'gate') return gates[selection.id];
  if (selection.type === 'item') return items[selection.id];
  return party;
}

function drawPlaceDots(list, ox, oy, s) {
  const r = Math.max(2, s * 0.45);
  ctx.lineWidth = 1; ctx.strokeStyle = '#000';
  for (const p of list) {
    ctx.fillStyle = KINDS[p.kind].color;
    ctx.beginPath();
    const x = ox + (p.x + 0.5) * s, y = oy + (p.y + 0.5) * s;
    if (p.kind === 'castle' || p.kind === 'keep') ctx.rect(x - r * 1.2, y - r * 1.2, r * 2.4, r * 2.4);
    else ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fill(); ctx.stroke();
  }
}

function drawGates(ox, oy, s) {
  const r = Math.max(3, s * 0.42);
  for (const g of gates) {
    const x = ox + (g.x + 0.5) * s, y = oy + (g.y + 0.5) * s;
    const open = hasParty() && party.trammel === g.phase, leads = hasParty() && party.felucca === g.phase;
    ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.lineWidth = 4; ctx.strokeStyle = '#000'; ctx.stroke();
    ctx.lineWidth = 2; ctx.strokeStyle = getCss('--gate'); ctx.stroke();
    if (open) { ctx.fillStyle = getCss('--gate'); ctx.fill(); }
    if (leads && !open) { ctx.beginPath(); ctx.arc(x, y, r * 0.4, 0, Math.PI * 2); ctx.fillStyle = getCss('--gate'); ctx.fill(); }
  }
}

function drawItems(ox, oy, s) {
  const r = Math.max(3, s * 0.42);
  ctx.lineWidth = 2;
  for (const it of items) {
    if (it.loc !== 0) continue;
    const x = ox + (it.x + 0.5) * s, y = oy + (it.y + 0.5) * s;
    ctx.beginPath();
    ctx.moveTo(x, y - r); ctx.lineTo(x + r, y); ctx.lineTo(x, y + r); ctx.lineTo(x - r, y); ctx.closePath();
    ctx.strokeStyle = '#000'; ctx.lineWidth = 4; ctx.stroke();
    ctx.strokeStyle = getCss('--item'); ctx.lineWidth = 2; ctx.stroke();
    if (!itemFound(it)) { ctx.fillStyle = getCss('--item'); ctx.fill(); }
  }
}

function drawLabels(here, ox, oy, s) {
  const { w, h } = size();
  const font = Math.round(Math.max(11, Math.min(15, 8 + s * 0.35)));
  ctx.font = `600 ${font}px "Segoe UI", system-ui, sans-serif`;
  ctx.textAlign = 'center'; ctx.textBaseline = 'top';
  ctx.lineJoin = 'round'; ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(0,0,0,0.85)';
  const taken = [];
  const sel = selection && selection.type === 'place' ? selection.id : null;
  const list = here
    .filter((p) => s >= KINDS[p.kind].min || p.id === sel)
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

function drawParty(ox, oy, s) {
  const { x, y } = party;
  const px = ox + x * s, py = oy + y * s, box = Math.max(s, 8), off = (box - s) / 2;
  ctx.save();
  ctx.strokeStyle = '#000'; ctx.lineWidth = 4;
  ctx.strokeRect(px - off, py - off, box, box);
  ctx.strokeStyle = getCss('--char'); ctx.lineWidth = 2;
  ctx.strokeRect(px - off, py - off, box, box);
  // a flag above the tile with the Avatar's name
  ctx.font = '700 13px "Segoe UI", system-ui, sans-serif';
  ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
  const text = party.members[0].name;
  const tw = ctx.measureText(text).width;
  const fx = px + s / 2, fy = py - off - 26;
  ctx.fillStyle = getCss('--char');
  ctx.fillRect(fx - 1, fy, 2, 26 - 1);
  ctx.fillRect(fx, fy, tw + 12, 18);
  ctx.fillStyle = '#1a1206';
  ctx.fillText(text, fx + 6, fy + 9.5);
  ctx.restore();
}

// ------------------------------------------------------------ sidebar

function itemFound(it) {
  const have = ITEMS[it.key].have;
  return !!(have && hasParty() && have(party, it));
}

function renderReveals() {
  $('#reveal-toggles').replaceChildren(...REVEALS.map(([id, label, text]) => el('label', { class: revealed(id) ? 'on' : '' },
    el('input', { type: 'checkbox', checked: revealed(id), onchange: (e) => setReveal(id, e.target.checked) }),
    el('span', {}, label), el('small', {}, text))));
  $('#gates-panel').hidden = !revealed('gates');
  $('#items-panel').hidden = !revealed('items');
}

function setReveal(id, on) {
  prefs.reveals[id] = on;
  savePrefs();
  // anything selected that's now hidden goes away
  const t = selection && selectionTarget();
  if (selection && ((selection.type === 'gate' && !revealed('gates')) || (selection.type === 'item' && !revealed('items'))
      || (selection.type === 'place' && t && t.secret && !revealed('secrets')))) selection = null;
  renderAll();
}

function renderAll() {
  renderReveals(); renderLayers(); renderParty(); renderGates(); renderItems(); renderPlaces(); renderInspector(); requestDraw();
  if ($('#town-dialog').open) renderTown();
  if ($('#dungeon-dialog').open) renderDungeon();
}

function renderLayers() {
  $('#layer-toggles').replaceChildren(...LAYERS.map(([id, label]) => el('label', {},
    el('input', { type: 'checkbox', checked: layerOn(id), onchange: (e) => {
      prefs.layers[id] = e.target.checked; savePrefs(); requestDraw();
    } }), label)));
}

function renderParty() {
  const box = $('#party');
  if (!hasParty()) {
    box.replaceChildren(el('p', { class: 'hint' }, 'No saved game yet. Start one in Ultima and press Q to save.'));
    return;
  }
  const a = party.members[0];
  const n = party.members.length;
  box.replaceChildren(
    el('div', { class: 'who', title: 'Show on the map', onclick: () => select({ type: 'party', id: 0 }, true) },
      el('b', {}, a.name), el('span', { class: 'sub' }, n === 1 ? 'alone' : `party of ${n}`)),
    el('span', { class: 'stats' }, partyWhere()),
    el('span', { class: 'stats' }, `${party.moves.toLocaleString()} moves · saved ${new Date(party.saved).toLocaleString()}`),
    el('div', { class: 'moons' },
      el('span', {}, 'Trammel ', el('b', {}, MOONS[party.trammel])),
      el('span', {}, 'Felucca ', el('b', {}, MOONS[party.felucca]))));
}

function renderGates() {
  $('#gates').replaceChildren(...gates.map((g, i) => {
    const open = hasParty() && party.trammel === g.phase, leads = hasParty() && party.felucca === g.phase;
    return el('li', {
      class: `${selection && selection.type === 'gate' && selection.id === i ? 'selected' : ''} ${open || leads ? 'open-now' : ''}`,
      onclick: () => select({ type: 'gate', id: i }, true),
    }, g.name, el('span', { class: 'sub' }, open && leads ? 'open, to itself' : open ? 'open at last save' : leads ? 'leads here' : MOONS[g.phase]));
  }));
}

function renderItems() {
  const rows = [];
  for (const it of items) {
    const where = it.loc === 0 ? `${it.x}, ${it.y}` : findPlace(it.loc).name;
    rows.push(el('li', {
      class: selection && selection.type === 'item' && selection.id === it.n ? 'selected' : '',
      onclick: () => select({ type: 'item', id: it.n }, true),
    }, el('span', { class: 'tick', title: itemFound(it) ? 'You have this' : '' }, itemFound(it) ? '✓' : ''),
    itemName(it), el('span', { class: 'sub' }, where)));
  }
  $('#items').replaceChildren(...rows);
}

function renderPlaces() {
  const q = $('#search').value.trim().toLowerCase();
  const rows = [];
  for (const group of GROUPS) {
    const list = visiblePlaces()
      .filter((p) => KINDS[p.kind].group === group && (!q || p.name.toLowerCase().includes(q) || p.kind.includes(q)))
      .sort((a, b) => KINDS[a.kind].order - KINDS[b.kind].order || a.name.localeCompare(b.name));
    if (!list.length) continue;
    rows.push(el('li', { class: 'group' }, group));
    for (const p of list) {
      rows.push(el('li', {
        class: selection && selection.type === 'place' && selection.id === p.id ? 'selected' : '',
        onclick: () => select({ type: 'place', id: p.id }, true),
      }, el('span', { class: 'tick', title: isVisited(p) ? 'Visited' : '' }, isVisited(p) ? '✓' : ''),
      p.name, el('span', { class: 'sub' }, KINDS[p.kind].label)));
    }
  }
  if (!rows.length) rows.push(el('li', { class: 'none' }, 'No places match.'));
  $('#places').replaceChildren(...rows);
}

function renderInspector() {
  const box = $('#inspector');
  if (!selection) {
    box.replaceChildren(el('p', { class: 'empty' }, 'Click a place on the map. Drag to move, scroll to zoom.'));
    return;
  }
  if (selection.type === 'party') {
    if (!hasParty()) { selection = null; renderInspector(); return; }
    box.replaceChildren(
      el('h3', {}, party.members[0].name),
      el('p', { class: 'kind' }, partyWhere()),
      el('p', { class: 'hint' }, `Sextant reading ${sextant(party.x, party.y)}`),
      el('ul', { class: 'list' }, party.members.map((m) => el('li', { class: 'none' }, m.name,
        el('span', { class: 'sub' }, `${m.class} · ${m.hp}/${m.maxHp}${m.status !== 'G' ? ` · ${m.status}` : ''}`)))));
    return;
  }
  if (selection.type === 'gate') { box.replaceChildren(...gateInspector(gates[selection.id])); return; }
  if (selection.type === 'item') { box.replaceChildren(...itemInspector(items[selection.id])); return; }

  const p = findPlace(selection.id);
  const n = placeNote(p.id) || {};
  const parts = [
    el('h3', {}, p.name),
    el('p', { class: 'kind' }, KINDS[p.kind].label),
    el('div', { class: 'row' },
      el('span', { class: 'hint' }, onMap(p) ? `${p.x}, ${p.y} · ${sextant(p.x, p.y)}` : 'Not on the map'),
      el('label', { class: 'check' }, el('input', { type: 'checkbox', checked: !!n.visited, onchange: (e) => {
        placeNote(p.id, true).visited = e.target.checked;
        prune(p.id); notesChanged(); renderPlaces(); requestDraw();
      } }), 'Visited')),
  ];
  if (!onMap(p)) parts.push(el('p', { class: 'hint' }, 'A moongate brings you here when both moons are full.'));
  if (p.ult.length) {
    const c = el('canvas', { class: 'thumb', title: 'Click to enlarge', onclick: () => openTown(p) });
    drawTown(c, gameFiles[p.ult[0]]);
    parts.push(c);
    const here = townItems(p, 0);
    if (here.length) parts.push(el('p', { class: 'hint' }, `Hidden here: ${here.map(itemName).join(', ')}.`));
  }
  if (p.dng) {
    if (revealed('dungeons')) {
      const c = el('canvas', { class: 'dungeon-thumb', title: 'Click for all 8 levels', onclick: () => openDungeon(p) });
      drawDungeon(c, gameFiles[p.dng], p, 0, 37);
      c.style.cursor = 'zoom-in';
      parts.push(c, el('button', { onclick: () => openDungeon(p) }, 'All 8 levels'));
    } else {
      parts.push(el('p', { class: 'hint' }, 'Turn on Dungeon maps under Reveals to see inside.'));
    }
  }
  parts.push(el('textarea', {
    rows: 5, placeholder: 'Notes: quests, shops, what you found...', value: n.note || '',
    oninput: (e) => { placeNote(p.id, true).note = e.target.value; prune(p.id); notesChanged(); },
  }));
  box.replaceChildren(...parts);
}

function gateInspector(g) {
  const parts = [
    el('h3', {}, `${g.name} moongate`),
    el('p', { class: 'kind' }, `${g.x}, ${g.y} · ${sextant(g.x, g.y)}`),
    el('p', {}, `Opens when Trammel is ${MOONS[g.phase].toLowerCase()}.`),
    el('p', {}, `The open gate leads here when Felucca is ${MOONS[g.phase].toLowerCase()}.`),
  ];
  if (hasParty()) {
    const open = gates[party.trammel], to = gates[party.felucca];
    const special = party.trammel === 4 && party.felucca === 4;
    const dest = special ? (revealed('secrets') ? 'the Shrine of Spirituality' : 'somewhere special') : to.name;
    parts.push(el('p', { class: 'hint' }, `At your last save: the ${open.name} gate was open, leading to ${dest}. The moons have moved on since, if you've played.`));
  }
  return parts;
}

function itemInspector(it) {
  const info = ITEMS[it.key];
  const place = it.loc === 0 ? null : findPlace(it.loc);
  const parts = [
    el('h3', {}, itemName(it)),
    el('p', { class: 'kind' }, place ? `In ${place.name}${place.ult.length > 1 ? ', floor 1' : ''}` : terrainName(worldTile(it.x, it.y))),
    el('p', {}, `Search at ${it.x}, ${it.y}${place ? '' : ` · ${sextant(it.x, it.y)}`}.`),
  ];
  if (info.note) parts.push(el('p', { class: 'hint' }, info.note));
  if (itemFound(it)) parts.push(el('p', { class: 'hint' }, 'You have this.'));
  if (place) parts.push(el('button', { onclick: () => openTown(place) }, `Open ${place.name}`));
  return parts;
}

function prune(id) {
  const n = notes.places[id];
  if (n && !n.visited && !n.note) delete notes.places[id];
}

function select(sel, fly = false) {
  selection = sel;
  renderInspector(); renderPlaces(); renderGates(); renderItems(); requestDraw();
  if (sel && fly) {
    const t = selectionTarget();
    const target = sel.type === 'item' && t.loc !== 0 ? findPlace(t.loc) : t;
    if (target && target.x !== null) flyTo(target.x, target.y);
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
let notesUnsaved = false;
let serverDown = false;
function notesChanged() {
  $('#save-status').textContent = 'Unsaved changes...';
  notesUnsaved = true;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNotes, 600);
}
async function saveNotes() {
  try {
    const r = await fetch('/api/notes', { method: 'PUT', body: JSON.stringify(notes, null, 1) });
    if (!r.ok) throw new Error(await r.text());
    notesUnsaved = false;
    $('#save-status').textContent = 'Notes saved';
  } catch (e) {
    $('#save-status').textContent = `Save failed: ${e.message}`;
  }
}
// Runs on each ping. When the server comes back, anything typed while it was gone gets saved.
async function checkServer() {
  try {
    await fetch('/api/ping');
    if (!serverDown) return;
    serverDown = false;
    if (notesUnsaved) await saveNotes();
    else $('#save-status').textContent = '';
  } catch {
    serverDown = true;
    $('#save-status').textContent = 'Map server stopped - notes are not being saved';
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
    if (drag && !drag.moved) select(hitTest(e.offsetX, e.offsetY));
    drag = null;
  });
  canvas.addEventListener('pointerleave', () => { $('#tooltip').hidden = true; $('#cursor-pos').innerHTML = '&nbsp;'; });
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
    if ($('#dungeon-dialog').open) {
      const lv = dungeonView.level;
      if (e.key >= '1' && e.key <= '8') dungeonView.level = +e.key - 1;
      else if (e.key === 'ArrowLeft' || e.key === 'PageUp') dungeonView.level = Math.max(0, lv - 1);
      else if (e.key === 'ArrowRight' || e.key === 'PageDown') dungeonView.level = Math.min(7, lv + 1);
      else return;
      e.preventDefault();
      dungeonView.room = null;
      renderDungeon();
      return;
    }
    if ($('#town-dialog').open) {
      const p = findPlace(townView.place);
      if (p && p.ult.length > 1 && (e.key === '1' || e.key === '2')) { townView.floor = +e.key - 1; townView.person = null; renderTown(); }
      return;
    }
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
    const list = visiblePlaces();
    const hit = list.find((p) => p.name.toLowerCase() === q) || list.find((p) => p.name.toLowerCase().includes(q));
    if (hit) select({ type: 'place', id: hit.id }, true);
  });

  $('#general-notes').addEventListener('input', (e) => { notes.general = e.target.value; notesChanged(); });
  $('#refresh-party').onclick = loadParty;
  for (const id of ['town', 'dungeon']) {
    $(`#${id}-close`).onclick = () => $(`#${id}-dialog`).close();
    $(`#${id}-dialog`).addEventListener('click', (e) => { if (e.target === e.currentTarget) e.currentTarget.close(); });
  }

  $('#town-big').addEventListener('click', (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    const x = Math.floor((e.clientX - r.left) / r.width * TOWN), y = Math.floor((e.clientY - r.top) / r.height * TOWN);
    const p = findPlace(townView.place);
    const hit = townPeople(gameFiles[p.ult[townView.floor]]).find((n) => n.x === x && n.y === y);
    townView.person = hit ? hit.slot : null;
    renderTown();
  });

  const big = $('#dungeon-big');
  big.addEventListener('pointermove', (e) => {
    const at = dungeonCellAt(e), p = findPlace(dungeonView.place);
    if (!at || !p) return;
    const info = cellInfo(gameFiles[p.dng][dungeonView.level * 64 + at.y * DNG + at.x], p);
    const n = info.room !== undefined ? ` ${roomNumber(p, dungeonView.level, info.room) + 1}` : '';
    $('#dungeon-cell').textContent = `${at.x}, ${at.y}: ${info.name}${n}`;
  });
  big.addEventListener('click', (e) => {
    const at = dungeonCellAt(e), p = findPlace(dungeonView.place);
    if (!at || !p) return;
    const info = cellInfo(gameFiles[p.dng][dungeonView.level * 64 + at.y * DNG + at.x], p);
    dungeonView.room = info.room !== undefined ? { n: roomNumber(p, dungeonView.level, info.room), at } : null;
    renderDungeon();
  });

  $('#export').onclick = () => {
    const a = el('a', {
      href: URL.createObjectURL(new Blob([JSON.stringify(notes, null, 1)], { type: 'application/json' })),
      download: `ultima4-map-notes-${new Date().toISOString().slice(0, 10)}.json`,
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
  window.addEventListener('focus', loadParty);
}

function hitTest(mx, my) {
  const t = tileAt(mx, my);
  if (!t) return null;
  const p = byPos.get(`${t.x},${t.y}`);
  if (p && layerOn(KINDS[p.kind].layer) && (!p.secret || revealed('secrets'))) return { type: 'place', id: p.id };
  if (revealed('gates')) {
    const g = gates.findIndex((o) => o.x === t.x && o.y === t.y);
    if (g >= 0) return { type: 'gate', id: g };
  }
  if (revealed('items')) {
    const it = items.find((o) => o.loc === 0 && o.x === t.x && o.y === t.y);
    if (it) return { type: 'item', id: it.n };
  }
  if (layerOn('party') && hasParty() && party.x === t.x && party.y === t.y) return { type: 'party', id: 0 };
  return null;
}

function updateHover(mx, my) {
  const t = tileAt(mx, my);
  const tip = $('#tooltip');
  if (!t) { tip.hidden = true; $('#cursor-pos').innerHTML = '&nbsp;'; canvas.classList.remove('over-place'); return; }
  $('#cursor-pos').textContent = `${t.x}, ${t.y} · ${sextant(t.x, t.y)} · ${terrainName(worldTile(t.x, t.y))}`;
  const hit = hitTest(mx, my);
  canvas.classList.toggle('over-place', !!hit);
  if (!hit) { tip.hidden = true; return; }
  let title, sub;
  if (hit.type === 'place') {
    const p = findPlace(hit.id);
    title = p.name; sub = `${KINDS[p.kind].label} · ${p.x}, ${p.y}${isVisited(p) ? ' · visited' : ''}`;
  } else if (hit.type === 'gate') {
    title = `${gates[hit.id].name} moongate`; sub = `Opens when Trammel is ${MOONS[gates[hit.id].phase].toLowerCase()}`;
  } else if (hit.type === 'item') {
    title = itemName(items[hit.id]); sub = itemFound(items[hit.id]) ? 'You have this' : 'Search here';
  } else {
    title = party.members[0].name; sub = 'Where you last saved';
  }
  tip.replaceChildren(el('b', {}, title), el('br'), el('span', { class: 'dim' }, sub));
  tip.hidden = false;
  const wrap = $('#map-area').getBoundingClientRect();
  tip.style.left = `${Math.min(mx + 14, wrap.width - tip.offsetWidth - 6)}px`;
  tip.style.top = `${my + 16}px`;
}

// ------------------------------------------------------------ startup

async function loadParty() {
  try {
    const r = await fetch('/api/party');
    if (!r.ok) return;
    party = await r.json();
    if (selection && selection.type === 'party' && !hasParty()) selection = null;
    renderParty(); renderGates(); renderItems(); renderInspector(); requestDraw();
    if ($('#dungeon-dialog').open) renderDungeon();
  } catch { /* server gone; the ping will say so */ }
}

async function start() {
  setupInput();
  renderLayers();
  renderReveals();
  computeFit();
  view = prefs.view ? { ...prefs.view } : { cx: WORLD / 2, cy: WORLD / 2, s: fitScale };
  clampView();
  requestDraw();

  try {
    const json = (url) => fetch(url).then((r) => { if (!r.ok) return r.text().then((m) => { throw new Error(m); }); return r.json(); });
    const data = await json('/api/world');
    places = data.places; gates = data.gates; items = data.items;
    worldBytes = await fetchBytes('WORLD.MAP');
    const sh = await fetchBytes('SHAPES.EGA');
    shapes = decodeShapes(sh, false);
    sprites = decodeShapes(sh, true);
    // Town and dungeon files are small, and the page only draws from them once you ask. Talk files
    // wait until Townsfolk is turned on.
    for (const p of places) {
      for (const f of p.ult) await fetchBytes(f);
      if (p.dng) await fetchBytes(p.dng);
    }
    buildWorld();
    byPos = new Map(places.filter(onMap).map((p) => [`${p.x},${p.y}`, p]));
    adoptNotes(await fetch('/api/notes').then((r) => r.json()));
  } catch (e) {
    const box = $('#load-error');
    box.textContent = `Couldn't load the map.\n\n${e.message}\n\nIs the map server still running? Start it again with "Ultima 4 Map.bat".`;
    box.hidden = false;
    return;
  }
  renderPlaces(); renderInspector();
  await loadParty();
  renderAll();

  // keep the server alive while the page is open
  setInterval(checkServer, 30000);
}

start();

import Foundation

extension WebApp {
    /// The page script (kept separate so the HTML stays readable).
    static let script = #"""
'use strict';
const $ = s => document.querySelector(s);

// Builds elements without parsing HTML: el('a', {className:'x', href:'/'}, 'text', child)
function el(tag, props, ...children){
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'dataset') Object.assign(node.dataset, v); else if (k in node) node[k] = v; else node.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null && c !== false) node.append(c instanceof Node ? c : String(c));
  return node;
}
// replaceChildren without the gaps: null and false leave nothing (replaceChildren itself would write "null").
const fill = (node, ...kids) => node.replaceChildren(...kids.flat().filter(k => k != null && k !== false));
// Only links to this Mac are followed: same-server paths, or a full address on this page's own host.
function safeURL(u){
  if (typeof u !== 'string' || u.includes('\\')) return '#';
  if (u.startsWith('/') && !u.startsWith('//')) return u;
  try { const x = new URL(u); if ((x.protocol === 'http:' || x.protocol === 'https:') && x.hostname === location.hostname) return x.href; } catch (e) {}
  return '#';
}
const reduceMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
const standalone = () => navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
const count = (n, word) => `${n} ${n === 1 ? word : word + 's'}`;
const clamp01 = v => Math.min(1, Math.max(0, Number(v) || 0));
const mt = s => { s = Math.max(0, Math.floor(Number.isFinite(s) ? s : 0)); return s >= 3600 ? `${Math.floor(s/3600)}:${String(Math.floor(s/60)%60).padStart(2,'0')}:${String(s%60).padStart(2,'0')}` : `${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}`; };
const store = {
  get(k, d){ try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v){ try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
};

// ---- Icons (inline SVG paths, built with DOM methods) ----
const NS = 'http://www.w3.org/2000/svg';
const ICON = {
  home:'M3.5 10.2 12 3.5l8.5 6.7V19a1.5 1.5 0 0 1-1.5 1.5h-4.2v-6h-5.6v6H5A1.5 1.5 0 0 1 3.5 19z',
  watch:'M5 4.5h14A2.5 2.5 0 0 1 21.5 7v8a2.5 2.5 0 0 1-2.5 2.5H5A2.5 2.5 0 0 1 2.5 15V7A2.5 2.5 0 0 1 5 4.5zM8 21h8M10 8.3v5.4l4.6-2.7z',
  listen:'M4 15v-3a8 8 0 0 1 16 0v3M4.5 14H6a1.5 1.5 0 0 1 1.5 1.5v4A1.5 1.5 0 0 1 6 21H4.5A1.5 1.5 0 0 1 3 19.5v-4A1.5 1.5 0 0 1 4.5 14zM18 14h1.5a1.5 1.5 0 0 1 1.5 1.5v4a1.5 1.5 0 0 1-1.5 1.5H18a1.5 1.5 0 0 1-1.5-1.5v-4A1.5 1.5 0 0 1 18 14z',
  read:'M12 6.5C10 5 7 4.5 3.5 5v13c3.5-.5 6.5 0 8.5 1.5 2-1.5 5-2 8.5-1.5V5C17 4.5 14 5 12 6.5zM12 6.5v13',
  play:'M7.5 7.5h9a4.5 4.5 0 0 1 4.4 5.5l-.8 3.6a2.3 2.3 0 0 1-3.9 1.1l-2-2.2H9.8l-2 2.2a2.3 2.3 0 0 1-3.9-1.1L3.1 13a4.5 4.5 0 0 1 4.4-5.5zM8.5 10.5v3.5M6.75 12.25h3.5M15.5 11.5h.01M17.5 13.5h.01',
  ask:'M5 4.5h14A1.5 1.5 0 0 1 20.5 6v9.5A1.5 1.5 0 0 1 19 17h-7l-4.5 3.5V17H5a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 5 4.5zM9.6 8.9a2.4 2.4 0 1 1 3.2 2.3c-.5.2-.8.6-.8 1.1v.4M12 14.6h.01',
  back:'M15 4.5 7.5 12l7.5 7.5', chev:'M9 5l7 7-7 7', left:'M15 5l-7 7 7 7', right:'M9 5l7 7-7 7', down:'M5 9l7 7 7-7', up:'M5 15l7-7 7 7',
  search:'M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM20 20l-4.6-4.6', close:'M6 6l12 12M18 6 6 18',
  list:'M8.5 6.5h12M8.5 12h12M8.5 17.5h12M4 6.5h.01M4 12h.01M4 17.5h.01',
  share:'M12 3.5v11M8 7.5l4-4 4 4M7.5 10.5H6A1.5 1.5 0 0 0 4.5 12v7A1.5 1.5 0 0 0 6 20.5h12a1.5 1.5 0 0 0 1.5-1.5v-7a1.5 1.5 0 0 0-1.5-1.5h-1.5',
  globe:'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3.5 9h17M3.5 15h17M12 3c2.4 2.5 3.6 5.5 3.6 9s-1.2 6.5-3.6 9c-2.4-2.5-3.6-5.5-3.6-9S9.6 5.5 12 3z',
  playfill:'M8 5.3v13.4L18.8 12z', pausefill:'M7 5h3.5v14H7zM13.5 5H17v14h-3.5z', send:'M12 19V5M6 11l6-6 6 6',
  doc:'M7 3.5h7l4.5 4.5v11A1.5 1.5 0 0 1 17 20.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5zM14 3.5V8h4.5',
  restart:'M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4v4h4', shuffle:'M4 7h3.5c3.5 0 5.5 10 9 10H20M4 17h3.5c1.4 0 2.6-1.6 3.6-3.5M14 9.5c.8-1.4 1.8-2.5 2.5-2.5H20M17.5 4.5 20 7l-2.5 2.5M17.5 14.5 20 17l-2.5 2.5',
  check:'M5 12.5l4.5 4.5L19 7.5'
};
function icon(name, cls){
  const s = document.createElementNS(NS, 'svg');
  s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('class', 'i' + (cls ? ' ' + cls : '')); s.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS(NS, 'path'); p.setAttribute('d', ICON[name] || ''); s.append(p);
  return s;
}
// The Mac's genre symbols (SF Symbols), drawn here as emoji.
const GENRE_EMOJI = {'sparkles':'✨','wand.and.stars':'🪄','magnifyingglass':'🔍','moon.stars':'🌙','map':'🗺️','pawprint':'🐾','teddybear':'🧸','leaf':'🍃','heart':'❤️','theatermasks':'🎭','globe.americas':'🌎','building.columns':'🏛️','text.quote':'📜','lightbulb':'💡','atom':'⚛️','function':'📐','paintpalette':'🎨','flame':'🔥','graduationcap':'🎓','fork.knife':'🍴','cross.case':'🩺','figure.run':'🏃','music.note':'🎵','music.quarternote.3':'🎻','music.mic':'🎤','waveform':'🎛️','guitars':'🎸','bolt':'⚡','star':'⭐','headphones':'🎧','film':'🎬','book.closed':'📕','video':'📹','mic':'🎙️','tag':'🏷️'};
const TILE_COLORS = ['#2E7F60','#3a6b8c','#6f5a96','#a35f3a','#5b7d3a','#8c4a5c','#36706b','#7a6a2e','#4a5f8c','#8a5a2b'];
function hash(text){ let h = 2166136261; for (const c of text || '') h = Math.imul(h ^ c.charCodeAt(0), 16777619); return Math.abs(h); }
const poster = t => { const h = hash(t); return `linear-gradient(135deg,hsl(${h%360} 32% 32%),hsl(${(h+50)%360} 38% 13%))`; };

// ---- Data ----
const S = {status:null, media:null, byId:new Map(), read:null, books:new Map(), games:undefined, archives:null, shelves:{}};
const ready = {media:false, read:false, archives:false};
const inflight = {};
const once = (key, fn) => inflight[key] || (inflight[key] = fn().finally(() => { delete inflight[key]; }));

async function api(path, opts){
  const r = await fetch(path, opts);
  if (r.status === 401) { needPin(); throw new Error('pin'); }
  return r;
}
async function getJSON(path){
  const r = await api(path);
  if (!r.ok) { const j = await r.json().catch(() => ({})); const e = new Error(j.error || 'The Mac could not load this.'); e.status = r.status; throw e; }
  return r.json();
}
const loadMedia = () => once('media', async () => { const d = await getJSON('/api/media'); S.media = d; S.byId = new Map(d.items.map(i => [i.id, i])); ready.media = true; return d; });
const loadRead = () => once('read', async () => { const d = await getJSON('/api/read'); S.read = d; S.books = new Map(d.books.map(b => [b.id, b])); ready.read = true; return d; });
const loadArchives = () => once('archives', async () => { S.archives = await getJSON('/api/books'); ready.archives = true; return S.archives; });
// Games come from a later update (another part of the app adds /api/games and /assets/play.js).
const loadGames = () => once('games', async () => {
  try {
    const r = await api('/api/games');
    const d = r.ok ? await r.json() : null;
    S.games = d && Array.isArray(d.games) ? d.games : null;
  } catch (e) { if (e.message === 'pin') throw e; S.games = null; }
  return S.games;
});
const shelfKey = (filter, genre) => filter + '|' + (genre || '');
const loadShelves = (filter, genre) => once('sh' + shelfKey(filter, genre), async () => {
  const q = new URLSearchParams({items:'0', filter});
  if (genre) q.set('genre', genre);
  const d = await getJSON('/api/media?' + q);
  S.shelves[shelfKey(filter, genre)] = d;
  return d;
});

async function loadAll(){
  const jobs = [[loadMedia, 'media'], [loadRead, 'read'], [loadArchives, 'archives'], [loadGames, null]];
  await Promise.allSettled(jobs.map(([fn, key]) => fn().catch(e => { if (key && e.message !== 'pin') ready[key] = 'error'; }).finally(rerender)));
}
async function reloadAll(){
  S.shelves = {};
  detailCache.clear();
  await Promise.allSettled([loadAll(), getJSON('/api/status').then(s => { S.status = s; })]);
  rerender();
}

// ---- Progress ----
function fraction(it){
  const p = it.progress; if (!p || p.finished || (p.seconds <= 5 && p.track === 0)) return null;
  const durations = it.tracks.map(t => t.duration || 0);
  if (durations.every(d => d > 0)) return Math.min(1, (durations.slice(0, p.track).reduce((a, b) => a + b, 0) + p.seconds) / durations.reduce((a, b) => a + b, 0));
  return it.tracks.length > 1 ? p.track / it.tracks.length : it.duration ? Math.min(1, p.seconds / it.duration) : null;
}
const bookStarted = b => { const p = b.progress; return !!p && !p.finished && (p.track > 0 || p.seconds > 0.01); };
function bookPlace(b){
  const p = b.progress;
  if (p?.finished) return 'Finished';
  if (!bookStarted(b)) return '';
  if (b.format === 'pdf') return `Page ${p.track + 1}${b.parts ? ' of ' + b.parts : ''}`;
  return `Chapter ${p.track + 1}${b.parts ? ' of ' + b.parts : ''}` + (b.fraction != null ? ` · ${Math.round(b.fraction * 100)}%` : '');
}

// ---- Pieces ----
// Artwork from the Mac comes in phone-sized copies (?w=, see ShareArtwork): `sizes` is the tile's width on screen, so the
// browser picks the copy that fills it at this screen's pixel density instead of the full-size cover.
const ART_WIDTHS = [160, 320, 480, 640, 960, 1280];
const SZ = {card:'(min-width:768px) 280px, 248px', square:'(min-width:768px) 190px, 160px', cover:'(min-width:768px) 156px, 136px',
  game:'150px', round:'(min-width:768px) 190px, 160px', wide:'112px', tall:'60px', thumb:'72px', upnext:'120px',
  pcover:'min(70vw, 300px)', coverhead:'min(52vw, 220px)', coversq:'min(64vw, 280px)', hero:'calc(100vw - 40px)', back:'100vw'};
function setArt(img, url, sizes){
  const u = safeURL(url);
  if (sizes && /^\/(media\/[^?#]+\/(thumb|cover)|api\/games\/art\/)/.test(u)) {
    const join = u.includes('?') ? '&' : '?';
    img.sizes = sizes;
    img.srcset = ART_WIDTHS.map(w => `${u}${join}w=${w} ${w}w`).join(', ');
  }
  img.src = u;
  return img;
}
function art(item, url, extra, sizes){
  const box = el('div', {className:'art' + (extra ? ' ' + extra : '')});
  box.style.background = poster(item.title);
  const ph = el('span', {className:'ph'}, item.title || '');
  box.append(ph);
  if (url && safeURL(url) !== '#') {
    const img = el('img', {alt:'', loading:'lazy', decoding:'async'});
    img.onload = () => ph.remove();
    img.onerror = () => img.remove();
    setArt(img, url, sizes || SZ[extra] || SZ.card);
    box.append(img);
  }
  return box;
}
const bar = f => el('div', {className:'bar'}, el('i', {style:`width:${(clamp01(f) * 100).toFixed(1)}%`}));

function mediaCard(it){
  const audio = it.kind === 'audio';
  const a = art(it, it.thumb || it.cover, null, audio ? SZ.square : SZ.card);
  const f = fraction(it);
  if (f != null) a.append(bar(f));
  else if (it.progress?.finished) a.append(el('span', {className:'tag r'}, audio ? '✓ Played' : '✓ Watched'));
  else if (it.kind === 'video' && it.duration) a.append(el('span', {className:'tag r'}, mt(it.duration)));
  return el('button', {className:'card' + (audio ? ' square' : ''), onclick:() => push(mediaDetailPage(it)),
      'aria-label':`${it.title}${it.meta ? ', ' + it.meta : ''}${f != null ? ', ' + Math.round(f * 100) + ' percent done' : ''}`},
    a, el('b', {}, it.title), el('small', {}, audio ? (it.artist || it.meta || '') : (it.meta || '')));
}
function bookCard(b){
  const a = art(b, b.thumb, null, SZ.cover);
  if (b.fraction != null && bookStarted(b)) a.append(bar(b.fraction));
  if (b.progress?.finished) a.append(el('span', {className:'tag r'}, '✓'));
  if (b.format === 'pdf') a.append(el('span', {className:'tag'}, 'PDF'));
  return el('button', {className:'card cover', onclick:() => push(bookDetailPage(b)), 'aria-label':`${b.title}${b.author ? ', by ' + b.author : ''}`},
    a, el('b', {}, b.title), el('small', {}, b.author || (b.format === 'pdf' ? 'PDF' : 'Book')));
}
// "NES", "Game Boy Advance": /api/games sends the system's id ("nes") and its name.
const systemName = g => g.systemName || g.system || '';
function refreshGames(){ delete inflight.games; loadGames().then(rerender).catch(() => {}); }
function gameCard(g, resume){
  const a = art(g, g.art, null, SZ.game);
  if (g.canResume) a.append(el('span', {className:'tag'}, 'Resume'));
  return el('button', {className:'card game', onclick:() => openGame(g, resume ?? !!g.canResume), 'aria-label':`${g.title}, ${systemName(g) || 'game'}`},
    a, el('b', {}, g.title), el('small', {}, systemName(g)));
}
function archiveRow(a){
  return el('a', {className:'row', href:'/book/' + encodeURIComponent(a.id), target:'_blank', rel:'noopener'},
    el('span', {className:'ic'}, icon('globe')),
    el('span', {className:'tx'}, el('b', {}, a.title), el('small', {}, `${a.kind} · ${Number(a.articles).toLocaleString()} articles · ${a.size}`)),
    icon('chev', 'chev'));
}
// "Continue" mixes kinds, so its cards are one shape: artwork beside the title and how far along.
function continueCard(entry){
  const {type, it} = entry;
  let label, place, f, onclick, url;
  if (type === 'media') {
    f = fraction(it); url = it.thumb || it.cover;
    label = it.kind === 'video' ? 'WATCHING' : 'LISTENING';
    const p = it.progress; place = it.tracks.length > 1 ? `${it.category === 'music' ? 'Song' : 'Chapter'} ${p.track + 1} of ${it.tracks.length}` : (it.duration ? `${mt(Math.max(0, it.duration - p.seconds))} left` : '');
    onclick = () => openPlayer(it, false);
  } else if (type === 'book') {
    f = it.fraction; url = it.thumb; label = 'READING'; place = bookPlace(it);
    onclick = () => it.format === 'epub' ? openReader(it) : push(bookDetailPage(it));
  } else {
    url = it.art; label = 'PLAYING'; place = systemName(it);
    onclick = () => openGame(it, !!it.canResume);
  }
  const shape = type === 'media' && it.kind === 'video' ? 'wide' : type === 'book' ? 'tall' : '';
  const a = art(it, url, shape, SZ[shape || 'thumb']);
  return el('button', {className:'ccard', onclick, 'aria-label':`Continue ${it.title}`}, a,
    el('span', {className:'tx'}, el('small', {}, label), el('b', {}, it.title), el('span', {className:'pl'}, place),
      f != null ? el('span', {className:'mbar'}, el('i', {style:`width:${(clamp01(f) * 100).toFixed(1)}%`})) : null));
}
function shelf(title, cards, more, cls){
  cards = cards.filter(Boolean);
  if (!cards.length) return null;
  return el('section', {className:'section'},
    el('div', {className:'shead'}, el('h2', {}, title), more ? el('button', {onclick:more}, 'See All') : null),
    el('div', {className:'shelf' + (cls ? ' ' + cls : '')}, cards));
}
function skShelf(kind){
  return el('section', {className:'section', 'aria-hidden':'true'}, el('div', {className:'sk sktitle'}),
    el('div', {className:'shelf'}, Array.from({length:4}, () => el('div', {className:'card ' + (kind || '')}, el('div', {className:'art sk'}), el('div', {className:'sk skline'})))));
}
function empty(emoji, title, text, action){
  return el('div', {className:'empty'}, el('div', {className:'big', 'aria-hidden':'true'}, emoji), el('h3', {}, title), el('p', {}, text), action || null);
}
function genreTiles(list, onPick){
  return el('div', {className:'genres'}, list.map(g => {
    const color = TILE_COLORS[hash(g.name) % TILE_COLORS.length];
    const tile = el('button', {className:'gtile', onclick:() => onPick(g.name), 'aria-label':`${g.name}, ${count(g.count, 'item')}`},
      el('span', {className:'e', 'aria-hidden':'true'}, GENRE_EMOJI[g.icon] || '🏷️'), el('span', {}, el('b', {}, g.name), el('br'), el('small', {}, count(g.count, 'item'))));
    tile.style.background = `linear-gradient(140deg,${color},color-mix(in srgb,${color} 55%,#000))`;
    return tile;
  }));
}
function genreChips(genres, icons, selected, pick){
  if (!genres || !genres.length) return null;
  return el('div', {className:'chips', role:'toolbar', 'aria-label':'Genres'},
    el('button', {className:'chip' + (selected ? '' : ' on'), 'aria-pressed':String(!selected), onclick:() => pick('')}, 'All'),
    genres.map(g => el('button', {className:'chip' + (selected === g ? ' on' : ''), 'aria-pressed':String(selected === g), onclick:() => pick(selected === g ? '' : g)},
      el('span', {'aria-hidden':'true'}, GENRE_EMOJI[icons?.[g]] || '🏷️'), g)));
}
function toast(text){
  const t = el('div', {className:'toast', role:'status'}, text);
  document.body.append(t);
  setTimeout(() => t.classList.add('out'), 2600);
  setTimeout(() => t.remove(), 3000);
}
const searchButton = () => el('button', {className:'navbtn round', 'aria-label':'Search everything', onclick:() => openSearch()}, icon('search'));

// ---- Pages and navigation: a stack of pages per tab, pushed and popped like a native app ----
const TABS = [['home', 'Home'], ['watch', 'Watch'], ['listen', 'Listen'], ['read', 'Read'], ['play', 'Play'], ['ask', 'Ask']];
const stacks = {}, tabEls = {};
let current = null, skipAnimation = false;
const topPage = () => stacks[current]?.[stacks[current].length - 1];

function makePage({title, large = true, back, actions = [], room = false, refresh, solidAt}){
  const page = el('div', {className:'page' + (room ? ' room' : '') + (large ? '' : ' small')});
  const nav = el('div', {className:'nav'},
    el('div', {className:'l'}, back ? el('button', {className:'navbtn', onclick:goBack, 'aria-label':'Back to ' + back}, icon('back'), el('span', {}, back)) : null),
    el('div', {className:'t', 'aria-hidden':large ? 'true' : null}, title || ''),
    el('div', {className:'r'}, actions));
  const scroll = el('div', {className:'scroll'});
  const largeTitle = large && title ? el('h1', {className:'large'}, title) : null;
  const body = el('div', {className:'body'});
  scroll.append(...[largeTitle, body].filter(Boolean));
  const ptr = el('div', {className:'ptr', 'aria-hidden':'true'}, el('i'));
  page.append(scroll, nav, ptr, el('div', {className:'shade'}));
  const threshold = solidAt ?? (large ? 38 : 4);
  let ticking = false;
  scroll.addEventListener('scroll', () => {
    if (ticking) return; ticking = true;
    requestAnimationFrame(() => { ticking = false; page.classList.toggle('scrolled', scroll.scrollTop > threshold); });
  }, {passive:true});
  const P = {el:page, scroll, body, nav, large:largeTitle, title, refresh, ptr, dirty:false};
  if (refresh) pullToRefresh(P);
  return P;
}

function pullToRefresh(P){
  let startY = null, pulled = 0, busy = false;
  const s = P.scroll, spinner = P.ptr.firstChild;
  s.addEventListener('touchstart', e => { startY = !busy && s.scrollTop <= 0 && e.touches.length === 1 ? e.touches[0].clientY : null; pulled = 0; }, {passive:true});
  s.addEventListener('touchmove', e => {
    if (startY == null) return;
    pulled = Math.max(0, e.touches[0].clientY - startY);
    if (s.scrollTop > 0) { startY = null; pulled = 0; P.ptr.style.opacity = ''; return; }
    const d = Math.min(pulled / 2, 70);
    P.ptr.style.opacity = String(Math.min(1, d / 45));
    P.ptr.style.transform = `translateY(${d / 2}px)`;
    spinner.style.transform = `rotate(${pulled * 2}deg)`;
  }, {passive:true});
  s.addEventListener('touchend', async () => {
    if (startY == null) return;
    startY = null;
    const go = pulled / 2 >= 55;
    P.ptr.style.transform = ''; spinner.style.transform = '';
    if (!go) { P.ptr.style.opacity = ''; return; }
    busy = true; P.ptr.classList.add('go');
    try { await P.refresh(); } catch (e) {}
    busy = false; P.ptr.classList.remove('go'); P.ptr.style.opacity = '';
  });
}

function push(P){
  const stack = stacks[current], prev = stack[stack.length - 1];
  P.back = prev?.title;
  stack.push(P);
  tabEls[current].append(P.el);
  history.pushState({tab:current, depth:stack.length}, '');
  slide(prev, P, true);
  return P;
}
function goBack(){ if (stacks[current]?.length > 1) history.back(); }
function popTop(animate){
  const stack = stacks[current];
  if (!stack || stack.length < 2) return;
  const top = stack.pop(), under = stack[stack.length - 1];
  top.onLeave?.();
  slide(top, under, false, animate === false, () => top.el.remove());
  showPage(under);
}
function showPage(P){ if (P?.dirty && P.render) { P.dirty = false; P.render(); } }
function slide(from, to, forward, instant, done){
  to.el.classList.remove('gone');
  if (!from || instant || skipAnimation || reduceMotion()) {
    if (forward && from) from.el.classList.add('gone');
    skipAnimation = false; done?.(); return;
  }
  const top = forward ? to.el : from.el, under = forward ? from.el : to.el, w = innerWidth;
  under.classList.remove('gone');
  const timing = {duration:400, easing:'cubic-bezier(.32,.72,0,1)'};
  const a = top.animate([{transform:`translateX(${forward ? w : 0}px)`, boxShadow:'0 0 30px rgba(0,0,0,.2)'}, {transform:`translateX(${forward ? 0 : w}px)`, boxShadow:'0 0 30px rgba(0,0,0,.2)'}], timing);
  under.animate([{transform:`translateX(${forward ? 0 : -w * .28}px)`}, {transform:`translateX(${forward ? -w * .28 : 0}px)`}], timing);
  under.querySelector(':scope > .shade').animate([{opacity:forward ? 0 : .14}, {opacity:forward ? .14 : 0}], timing);
  a.onfinish = () => { if (forward) under.classList.add('gone'); done?.(); };
}
window.addEventListener('popstate', e => {
  if (readerOpen() && e.state?.overlay !== 'reader') closeReaderNow();
  const depth = Math.max(1, e.state?.depth || 1);
  const stack = stacks[current];
  const animate = !e.hasUAVisualTransition;
  while (stack && stack.length > depth) popTop(animate && stack.length === depth + 1);
});
// In a Home Screen app there is no browser swipe-back, so swiping from the left edge pops the page.
function edgeSwipe(){
  let sx = null, dx = 0, t0 = 0, P, under;
  document.addEventListener('touchstart', e => {
    sx = null;
    if (!standalone() || e.touches.length !== 1 || e.touches[0].clientX > 22) return;
    if (readerOpen() || ($('#player').className === '')) return;
    const st = stacks[current]; if (!st || st.length < 2) return;
    P = st[st.length - 1]; under = st[st.length - 2];
    sx = e.touches[0].clientX; dx = 0; t0 = Date.now();
    under.el.classList.remove('gone');
  }, {passive:true});
  document.addEventListener('touchmove', e => {
    if (sx == null) return;
    dx = Math.max(0, e.touches[0].clientX - sx);
    P.el.style.transform = `translateX(${dx}px)`;
    under.el.style.transform = `translateX(${-innerWidth * .28 + dx * .28}px)`;
  }, {passive:true});
  document.addEventListener('touchend', () => {
    if (sx == null) return;
    sx = null;
    const go = dx > innerWidth * .35 || dx / Math.max(1, Date.now() - t0) > .5;
    const w = innerWidth, timing = {duration:220, easing:'ease-out'};
    const a = P.el.animate([{transform:`translateX(${dx}px)`}, {transform:`translateX(${go ? w : 0}px)`}], timing);
    under.el.animate([{transform:`translateX(${-w * .28 + dx * .28}px)`}, {transform:`translateX(${go ? 0 : -w * .28}px)`}], timing);
    const top = P, below = under;
    a.onfinish = () => {
      top.el.style.transform = ''; below.el.style.transform = '';
      if (go) { top.el.style.visibility = 'hidden'; skipAnimation = true; history.back(); }
      else below.el.classList.add('gone');
    };
  });
}

function buildTabbar(){
  $('#tabbar').replaceChildren(...TABS.map(([id, label]) =>
    el('button', {dataset:{tab:id}, onclick:() => selectTab(id)}, icon(id), el('span', {}, label))));
}
const ROOTS = {home:homePage, watch:watchPage, listen:listenPage, read:readPage, play:playPage, ask:askPage};
function selectTab(id){
  if (current === id) {
    // Tapping the open tab again goes back to its first page, or to the top of it.
    const st = stacks[id];
    if (st.length > 1) { while (st.length > 1) st.pop().el.remove(); st[0].el.classList.remove('gone'); showPage(st[0]); history.replaceState({tab:id, depth:1}, ''); }
    else st[0].scroll.scrollTo({top:0, behavior:reduceMotion() ? 'auto' : 'smooth'});
    return;
  }
  current = id;
  for (const b of $('#tabbar').children) { const on = b.dataset.tab === id; b.classList.toggle('on', on); b.setAttribute('aria-current', on ? 'page' : 'false'); }
  if (!tabEls[id]) {
    tabEls[id] = el('div', {className:'tab', dataset:{tab:id}});
    $('#app').append(tabEls[id]);
    const root = ROOTS[id]();
    stacks[id] = [root];
    tabEls[id].append(root.el);
  }
  for (const [k, v] of Object.entries(tabEls)) v.classList.toggle('on', k === id);
  $('#composer').classList.toggle('hidden', id !== 'ask');
  history.replaceState({tab:id, depth:stacks[id].length}, '', id === 'home' ? location.pathname : '#' + id);
  showPage(topPage());
}
// Data changed: the open page redraws now, the others when they are next shown.
function rerender(){
  for (const st of Object.values(stacks)) for (const P of st) if (P.render) P.dirty = true;
  showPage(topPage());
}

// ---- Home ----
function continueItems(){
  const out = [];
  for (const it of S.media?.items || []) if (fraction(it) != null) out.push({type:'media', it, t:it.progress.updated || 0});
  for (const b of S.books.values()) if (bookStarted(b)) out.push({type:'book', it:b, t:b.progress.updated || 0});
  for (const g of S.games || []) if (g.canResume && g.lastPlayed) out.push({type:'game', it:g, t:g.lastPlayed || 0});
  return out.sort((a, b) => b.t - a.t).slice(0, 20);
}
function allGenres(){
  const counts = new Map(), icons = {...(S.media?.genreIcons || {}), ...(S.read?.genreIcons || {})};
  for (const it of S.media?.items || []) if (it.genre) counts.set(it.genre, (counts.get(it.genre) || 0) + 1);
  for (const b of S.books.values()) if (b.genre) counts.set(b.genre, (counts.get(b.genre) || 0) + 1);
  return [...counts].map(([name, n]) => ({name, count:n, icon:icons[name] || 'tag'})).sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
}
const byAdded = (a, b) => (b.added || 0) - (a.added || 0);
function greeting(){
  const h = new Date().getHours();
  return h < 5 ? 'Good night' : h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
}
function homePage(){
  const P = makePage({title:'Home', refresh:reloadAll, actions:[searchButton()]});
  P.large.textContent = greeting();
  P.render = () => {
    const items = S.media?.items || [], books = [...S.books.values()], games = S.games || [], archives = S.archives || [];
    const nodes = [
      el('p', {className:'subtitle'}, `${S.status?.name || 'Your Mac'} · works without the internet`),
      el('button', {className:'searchbox', onclick:() => openSearch()}, icon('search'), 'Movies, music, books and articles'),
    ];
    if (!ready.media || !ready.read) nodes.push(skShelf());
    else {
      const cont = continueItems();
      nodes.push(shelf('Continue', cont.map(continueCard), null, 'cshelf'));
    }
    if (!ready.media) nodes.push(skShelf());
    else {
      const videos = items.filter(i => i.category === 'video').sort(byAdded);
      const audio = items.filter(i => i.category !== 'video').sort(byAdded);
      nodes.push(shelf('Watch', videos.slice(0, 16).map(mediaCard), () => selectTab('watch')));
      nodes.push(shelf('Listen', audio.slice(0, 16).map(mediaCard), () => selectTab('listen')));
    }
    if (ready.read === true) nodes.push(shelf('Read', books.sort(byAdded).slice(0, 16).map(bookCard), () => selectTab('read')));
    if (games.length) nodes.push(shelf('Play', games.slice(0, 16).map(g => gameCard(g)), () => selectTab('play')));
    const genres = allGenres();
    if (genres.length) nodes.push(el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, 'Browse by Genre'),
      genres.length > 8 ? el('button', {onclick:() => push(genresPage(genres))}, 'See All') : null), genreTiles(genres.slice(0, 8), name => push(genrePage(name)))));
    if (archives.length) nodes.push(el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, 'Reference Library'),
      archives.length > 4 ? el('button', {onclick:() => push(archivesPage())}, 'See All') : null), el('div', {className:'list'}, sortArchives(archives).slice(0, 4).map(archiveRow))));
    if (ready.media === 'error' && ready.read === 'error') nodes.push(empty('📡', 'Can’t reach the Mac', 'Check that this device is on the same Wi-Fi as the Mac and that Share on Wi-Fi is on.', el('button', {className:'btn primary', onclick:reloadAll}, 'Try Again')));
    else if (ready.media === true && ready.read === true && !items.length && !books.length && !games.length && !archives.length)
      nodes.push(empty('🌲', 'Nothing here yet', 'Add movies, music, audiobooks, books and archives in Offline Kit on the Mac. They show up here.'));
    P.body.replaceChildren(...nodes.filter(Boolean));
  };
  P.render();
  return P;
}
const sortArchives = list => [...list].sort((a, b) => a.kindOrder - b.kindOrder || a.title.localeCompare(b.title));
function archivesPage(){
  const P = makePage({title:'Reference Library', back:topPage()?.title});
  P.render = () => {
    const nodes = []; let kind = '', group = null;
    for (const a of sortArchives(S.archives || [])) {
      if (a.kind !== kind) { kind = a.kind; nodes.push(el('div', {className:'shead'}, el('h2', {className:'small'}, kind))); group = el('div', {className:'list'}); nodes.push(group); }
      group.append(archiveRow(a));
    }
    P.body.replaceChildren(...nodes);
  };
  P.render();
  return P;
}
function genresPage(list){
  const P = makePage({title:'Genres', back:topPage()?.title});
  P.body.append(genreTiles(list, name => push(genrePage(name))));
  return P;
}
function genrePage(name){
  const P = makePage({title:name, back:topPage()?.title});
  P.render = () => {
    const items = (S.media?.items || []).filter(i => i.genre === name);
    const books = [...S.books.values()].filter(b => b.genre === name);
    const sec = (title, list, card, cls) => list.length ? el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, title)), el('div', {className:'grid' + (cls ? ' ' + cls : '')}, list.map(card))) : null;
    P.body.replaceChildren(...[
      sec('Watch', items.filter(i => i.category === 'video'), mediaCard),
      sec('Listen', items.filter(i => i.category !== 'video'), mediaCard),
      sec('Read', books, bookCard, 'covers'),
    ].filter(Boolean));
  };
  P.render();
  return P;
}
function gridPage(title, list, card, cls){
  const P = makePage({title, back:topPage()?.title});
  P.body.append(el('div', {className:'grid' + (cls ? ' ' + cls : '')}, list.map(card)));
  return P;
}

// ---- Watch and Listen ----
function mediaShelves(d, cardsFor){
  return (d.shelves || []).map(s => {
    const list = s.items.map(id => S.byId.get(id)).filter(Boolean);
    return shelf(s.title, list.slice(0, 20).map(cardsFor), list.length > 20 ? () => push(gridPage(s.title, list, mediaCard)) : null);
  });
}
function hero(it){
  const f = fraction(it), resuming = f != null;
  const img = it.thumb || it.cover;
  return el('button', {className:'hero', onclick:() => push(mediaDetailPage(it)), 'aria-label':`${resuming ? 'Resume' : 'Play'} ${it.title}`},
    img ? setArt(el('img', {alt:'', decoding:'async'}), img, SZ.hero) : null,
    el('div', {className:'in'}, el('div', {className:'eb'}, resuming ? 'PICK UP WHERE YOU LEFT OFF' : 'READY WHEN YOU ARE'),
      el('h3', {}, it.title), el('p', {}, it.meta || ''), resuming ? el('div', {className:'bar'}, el('i', {style:`width:${(f * 100).toFixed(1)}%`})) : null,
      el('span', {className:'go'}, icon('playfill', 'fill'), resuming ? 'Resume' : 'Play')));
}
function forest(P){
  const f = el('div', {className:'forest'});
  P.large.replaceWith(f);
  f.append(P.large);
  return f;
}
// What a shelf page needs from the Mac for one filter and genre: the item list plus that filter's shelves.
function need(P, filter, genre){
  const key = shelfKey(filter, genre);
  if (key in S.shelves) return S.shelves[key];
  P.wait ??= new Set();
  if (!P.wait.has(key)) {
    P.wait.add(key);
    loadShelves(filter, genre).catch(e => { if (e.message !== 'pin') S.shelves[key] = null; }).finally(() => { P.wait.delete(key); P.render(); });
  }
  return undefined;
}
function watchPage(){
  const P = makePage({title:'Watch', room:true, refresh:reloadAll, actions:[searchButton()]});
  const head = forest(P);
  P.genre = '';
  P.render = () => {
    const d = need(P, 'video', P.genre);
    const nodes = [];
    if (d === undefined || !ready.media) { head.replaceChildren(P.large, el('div', {className:'hero sk'})); P.body.replaceChildren(skShelf(), skShelf()); return; }
    if (d === null || ready.media === 'error') { head.replaceChildren(P.large); P.body.replaceChildren(empty('📡', 'Couldn’t load your videos', 'Check the connection to the Mac.', el('button', {className:'btn primary', onclick:reloadAll}, 'Try Again'))); return; }
    const all = need(P, 'video', '');
    const genres = all?.genres || d.genres;
    const featured = !P.genre && S.byId.get(d.featured);
    fill(head, P.large, featured ? hero(featured) : null);
    nodes.push(genreChips(genres, all?.genreIcons || d.genreIcons, P.genre, g => { P.genre = g; P.render(); }));
    const results = (d.results || []).map(id => S.byId.get(id)).filter(Boolean);
    if (P.genre) nodes.push(el('div', {className:'shead'}, el('h2', {}, P.genre), el('small', {className:'note'}, count(results.length, 'video'))), el('div', {className:'grid'}, results.map(mediaCard)));
    else nodes.push(...mediaShelves(d, mediaCard));
    if (!results.length) nodes.push(empty('🎬', 'Your next favorite belongs here', 'On the Mac, open Watch and use Add, or drag video files onto the window.'));
    P.body.replaceChildren(...nodes.filter(Boolean));
  };
  P.render();
  return P;
}
function listenPage(){
  const P = makePage({title:'Listen', room:true, refresh:reloadAll, actions:[searchButton()]});
  const head = forest(P);
  P.kind = store.get('ok.listen', 'all'); P.genre = '';
  const seg = () => el('div', {className:'seg', role:'tablist'}, [['all', 'All'], ['audiobooks', 'Audiobooks'], ['music', 'Music']].map(([v, t]) =>
    el('button', {className:P.kind === v ? 'on' : '', role:'tab', 'aria-selected':String(P.kind === v), onclick:() => { P.kind = v; P.genre = ''; store.set('ok.listen', v); P.render(); }}, t)));
  P.render = () => {
    head.replaceChildren(P.large, seg());
    const kinds = P.kind === 'all' ? ['audiobooks', 'music'] : [P.kind];
    const data = kinds.map(k => need(P, k, P.kind === 'all' ? '' : P.genre));
    if (data.includes(undefined) || !ready.media) { P.body.replaceChildren(skShelf('square'), skShelf('square')); return; }
    if (data.includes(null) || ready.media === 'error') { P.body.replaceChildren(empty('📡', 'Couldn’t load your audio', 'Check the connection to the Mac.', el('button', {className:'btn primary', onclick:reloadAll}, 'Try Again'))); return; }
    const nodes = [];
    if (P.kind !== 'all') {
      const base = need(P, P.kind, '') || data[0];
      nodes.push(genreChips(base.genres, base.genreIcons, P.genre, g => { P.genre = g; P.render(); }));
    }
    data.forEach((d, i) => {
      const kind = kinds[i];
      const results = (d.results || []).map(id => S.byId.get(id)).filter(Boolean);
      if (P.kind === 'all' && results.length) nodes.push(el('h2', {className:'group'}, kind === 'music' ? 'Music' : 'Audiobooks'));
      if (P.genre) nodes.push(el('div', {className:'grid'}, results.map(mediaCard)));
      else {
        nodes.push(...mediaShelves(d, mediaCard).slice(0, P.kind === 'all' ? 4 : 99));
        if (kind === 'music' && (d.artists || []).length > 1) nodes.push(shelf('Artists', d.artists.slice(0, 30).map(artistCard)));
      }
    });
    if (nodes.every(n => !n)) nodes.push(empty('🎧', 'Nothing to listen to yet', 'On the Mac, open Audiobooks or Music and use Add. Free LibriVox audiobooks can be added there too.'));
    P.body.replaceChildren(...nodes.filter(Boolean));
  };
  P.render();
  return P;
}
function artistCard(a){
  const first = S.byId.get(a.items[0]) || {title:a.name};
  const box = art({title:a.name}, first.thumb || first.cover, 'round');
  const list = a.items.map(id => S.byId.get(id)).filter(Boolean);
  return el('button', {className:'card square artist', onclick:() => push(gridPage(a.name, list, mediaCard))}, box, el('b', {}, a.name), el('small', {}, count(list.length, 'album')));
}

// "More like this" and "Up next" are worked out by the Mac only for the item that is opened.
const detailCache = new Map();
function detailFor(it){
  if (!detailCache.has(it.id)) detailCache.set(it.id, api('/api/media/detail?id=' + encodeURIComponent(it.id)).then(r => r.ok ? r.json() : {}).catch(() => { detailCache.delete(it.id); return {}; }));
  return detailCache.get(it.id);
}
function mediaDetailPage(item){
  const isVideo = item.kind === 'video';
  const P = makePage({title:item.title, large:false, back:topPage()?.title, room:true, solidAt:isVideo ? 160 : 220});
  P.el.classList.add('detail');
  P.render = () => {
    const it = S.byId.get(item.id) || item;
    const f = fraction(it), music = it.category === 'music';
    const header = isVideo
      ? el('div', {className:'dhead'}, el('div', {className:'back'}, it.thumb || it.cover ? setArt(el('img', {alt:'', decoding:'async'}), it.thumb || it.cover, SZ.back) : null))
      : el('div', {className:'dhead coverhead sq'}, art(it, it.thumb || it.cover, null, SZ.coversq));
    if (isVideo && !(it.thumb || it.cover)) header.firstChild.style.background = poster(it.title);
    const info = el('div', {className:'dinfo'},
      el('div', {className:'k'}, music ? 'ALBUM' : it.category === 'audiobooks' ? 'AUDIOBOOK' : 'VIDEO'),
      el('h1', {}, it.title), it.kind === 'audio' ? el('p', {}, it.artist || 'Unknown artist') : null, el('p', {}, it.meta || ''),
      f != null ? el('div', {className:'prog'}, `${Math.round(f * 100)}% done`) : it.progress?.finished ? el('div', {className:'prog'}, isVideo ? 'Watched' : 'Finished') : null);
    const buttons = el('div', {className:'btns'},
      el('button', {className:'btn primary', onclick:() => openPlayer(it, false)}, icon('playfill', 'fill'), f != null ? 'Resume' : 'Play'),
      f != null ? el('button', {className:'btn', onclick:() => openPlayer(it, true)}, icon('restart'), 'Start Over') : null,
      music && it.tracks.length > 1 ? el('button', {className:'btn', onclick:() => openPlayer(it, false, -1)}, icon('shuffle'), 'Shuffle') : null);
    const nodes = [header, info, buttons];
    if (it.summary) nodes.push(el('p', {className:'summary'}, it.summary));
    if (it.kind === 'audio' && it.tracks.length > 1) {
      nodes.push(el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, music ? 'Songs' : 'Chapters')),
        el('div', {className:'list'}, it.tracks.map((t, i) => {
          const here = it.progress && !it.progress.finished && it.progress.track === i;
          return el('button', {className:'row' + (here ? ' on' : ''), onclick:() => openPlayer(it, false, i)},
            el('span', {className:'num'}, here ? '▶' : String(i + 1)),
            el('span', {className:'tx'}, el('b', {}, t.title), here ? el('small', {}, 'Your place') : null),
            el('small', {className:'num', style:'width:auto'}, t.duration ? mt(t.duration) : ''));
        }))));
    }
    const upNext = el('div'), related = el('div');
    nodes.push(upNext, related);
    P.body.replaceChildren(...nodes);
    detailFor(it).then(d => {
      const next = S.byId.get(d.upNext);
      if (next) upNext.replaceChildren(el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, 'Up Next')),
        el('button', {className:'upnext', onclick:() => push(mediaDetailPage(next))}, art(next, next.thumb || next.cover, null, SZ.upnext),
          el('span', {}, el('small', {}, 'PLAYS NEXT'), el('b', {style:'display:block'}, next.title), el('small', {style:'display:block;letter-spacing:0;font-weight:400'}, next.meta || '')))));
      const more = (d.related || []).map(id => S.byId.get(id)).filter(Boolean);
      fill(related, shelf('More Like This', more.map(mediaCard)));
    });
  };
  P.render();
  return P;
}

// ---- Read ----
function readPage(){
  const P = makePage({title:'Read', refresh:reloadAll, actions:[searchButton()]});
  P.genre = '';
  P.render = () => {
    const nodes = [];
    if (!ready.read) nodes.push(skShelf('cover'), skShelf('cover'));
    else if (ready.read === 'error') nodes.push(empty('📡', 'Couldn’t load your books', 'Check the connection to the Mac.', el('button', {className:'btn primary', onclick:reloadAll}, 'Try Again')));
    else {
      const books = [...S.books.values()];
      if (!books.length) nodes.push(empty('📚', 'No books yet', 'Add EPUB or PDF books in Offline Kit on the Mac (Watch & Listen, then Books). They open right here.'));
      else {
        nodes.push(genreChips(S.read.genres, S.read.genreIcons, P.genre, g => { P.genre = g; P.render(); }));
        if (P.genre) {
          const list = books.filter(b => b.genre === P.genre).sort((a, b) => a.title.localeCompare(b.title));
          nodes.push(el('div', {className:'grid covers'}, list.map(bookCard)));
        } else {
          for (const s of S.read.shelves || []) {
            const list = s.items.map(id => S.books.get(id)).filter(Boolean);
            nodes.push(shelf(s.title, list.slice(0, 20).map(bookCard), list.length > 20 ? () => push(gridPage(s.title, list, bookCard, 'covers')) : null));
          }
        }
      }
    }
    if (ready.archives === true && (S.archives || []).length) nodes.push(el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, 'Reference Library')),
      el('div', {className:'list'}, sortArchives(S.archives).map(archiveRow))));
    P.body.replaceChildren(...nodes.filter(Boolean));
  };
  P.render();
  return P;
}
const bookInfo = new Map();
function getBookInfo(id){
  if (!bookInfo.has(id)) bookInfo.set(id, getJSON('/api/read/book?id=' + encodeURIComponent(id)).catch(e => { bookInfo.delete(id); throw e; }));
  return bookInfo.get(id);
}
function saveBookProgress(b, track, seconds, finished){
  b.progress = {track, seconds, finished, updated:Date.now() / 1000};
  const parts = b.parts || R.info?.chapters?.length || 0;
  b.fraction = finished || !parts ? null : clamp01((track + (b.format === 'pdf' ? 0 : seconds)) / parts);
  for (const st of Object.values(stacks)) for (const P of st) if (P.render) P.dirty = true;
  return api('/api/media/progress', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({id:b.id, track, seconds, finished})}).catch(() => {});
}
function bookDetailPage(book){
  const P = makePage({title:book.title, large:false, back:topPage()?.title, solidAt:200});
  P.el.classList.add('detail');
  P.render = () => {
    const b = S.books.get(book.id) || book;
    const pdf = b.format === 'pdf', started = bookStarted(b);
    const place = bookPlace(b);
    const actions = el('div', {className:'btns'}, el('div', {className:'btn sk', style:'flex:1'}));
    const chapters = el('div');
    const nodes = [
      el('div', {className:'dhead coverhead'}, art(b, b.thumb, null, SZ.coverhead)),
      el('div', {className:'dinfo'}, el('div', {className:'k'}, pdf ? 'PDF' : 'BOOK'), el('h1', {}, b.title),
        b.author ? el('p', {}, b.author) : null, el('p', {}, [b.genre, b.parts ? (pdf ? count(b.parts, 'page') : count(b.parts, 'chapter')) : null, b.year].filter(Boolean).join(' · ')),
        place ? el('div', {className:'prog'}, place) : null),
      actions,
      b.summary ? el('p', {className:'summary'}, b.summary) : null,
      chapters,
    ];
    const same = b.genre ? [...S.books.values()].filter(x => x.genre === b.genre && x.id !== b.id) : [];
    nodes.push(shelf(b.genre ? `More ${b.genre}` : 'More Books', same.slice(0, 16).map(bookCard)));
    P.body.replaceChildren(...nodes.filter(Boolean));
    getBookInfo(b.id).then(info => {
      if (pdf) {
        // The browser's own PDF viewer; it opens at the saved page where it supports #page.
        const page = started ? b.progress.track + 1 : 1;
        fill(actions,
          el('a', {className:'btn primary', href:safeURL(info.file) + (page > 1 ? '#page=' + page : ''), target:'_blank', rel:'noopener'}, icon('doc'), 'Open PDF'),
          el('button', {className:'btn', onclick:async () => { await saveBookProgress(b, 0, 0, !b.progress?.finished); P.render(); }}, icon('check'), b.progress?.finished ? 'Unread' : 'Mark Read'));
        return;
      }
      fill(actions,
        el('button', {className:'btn primary', onclick:() => openReader(b)}, icon('read'), started ? 'Continue' : 'Read'),
        started || b.progress?.finished ? el('button', {className:'btn', onclick:() => openReader(b, 0)}, icon('restart'), 'Start Over') : null);
      const here = started ? b.progress.track : -1;
      chapters.replaceChildren(el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, 'Contents')),
        el('div', {className:'list'}, info.chapters.map((c, i) => el('button', {className:'row' + (i === here ? ' on' : ''), onclick:() => openReader(b, i)},
          el('span', {className:'num'}, String(i + 1)), el('span', {className:'tx'}, el('b', {}, c.title), i === here ? el('small', {}, 'Your place') : null))))));
    }).catch(e => {
      if (e.message === 'pin') return;
      actions.replaceChildren(el('p', {className:'err', style:'margin:0'}, e.message));
    });
  };
  P.render();
  return P;
}

// ---- Reader (EPUB): pages load from the Mac's archive port in a sandboxed frame ----
const R = {book:null, info:null, chapter:0, fraction:0, pending:0, loading:false, frame:null, ui:null, timer:null, basePath:''};
const readerOpen = () => !$('#reader').classList.contains('hidden');
const readerPrefs = () => {
  const p = store.get('ok.reader', {});
  return {theme:['light', 'sepia', 'dark'].includes(p.theme) ? p.theme : (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'),
    size:Math.min(220, Math.max(80, Number(p.size) || 110))};
};
function buildReader(){
  const r = $('#reader');
  const title = el('div', {className:'rtitle'});
  const chapterName = el('b'), where = el('small'), prog = el('i');
  const prev = el('button', {className:'rbtn', 'aria-label':'Previous chapter', onclick:() => goChapter(R.chapter - 1)}, icon('left'));
  const next = el('button', {className:'rbtn', 'aria-label':'Next chapter', onclick:() => goChapter(R.chapter + 1)}, icon('right'));
  const top = el('div', {className:'rtop'},
    el('button', {className:'rbtn', 'aria-label':'Close book', onclick:closeReader}, icon('close')), title,
    el('button', {className:'rbtn', 'aria-label':'Contents', onclick:() => openSheet('contents')}, icon('list')),
    el('button', {className:'rbtn', 'aria-label':'Text and page color', onclick:() => openSheet('settings'), style:'font-family:Georgia,serif;font-size:19px'}, 'Aa'));
  const bottom = el('div', {className:'rbot'}, prev, el('div', {className:'rmid'}, chapterName, el('div', {className:'rprog'}, prog), where), next);
  const scrim = el('div', {className:'scrim closed', onclick:closeSheets});
  const contents = sheet('Contents'), settings = sheet('Text & Page');
  r.replaceChildren(top, bottom, scrim, contents.el, settings.el);
  R.ui = {title, chapterName, where, prog, prev, next, scrim, contents, settings};
}
// A fresh frame per open book, navigated with location.replace: changing a frame's src would add entries to the
// page's history, and Back would then turn the book's pages instead of closing it. Removing the frame drops them.
function newFrame(){
  R.frame?.remove();
  const frame = el('iframe', {title:'Book page'});
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.setAttribute('referrerpolicy', 'no-referrer');
  $('#reader').prepend(frame);
  R.frame = frame; R.frameUsed = false;
}
function frameGo(url){
  R.loading = true;
  if (R.frameUsed) R.frame.contentWindow.location.replace(url);
  else { R.frame.src = url; R.frameUsed = true; }
}
function sheet(name){
  const body = el('div', {className:'body'});
  const s = el('div', {className:'sheet closed', role:'dialog', 'aria-label':name},
    el('div', {className:'grab'}), el('div', {className:'sh'}, el('h3', {}, name), el('button', {className:'rbtn', 'aria-label':'Close', onclick:closeSheets}, icon('close'))), body);
  return {el:s, body};
}
function openSheet(which){
  const u = R.ui, prefs = readerPrefs();
  if (which === 'contents') {
    u.contents.body.replaceChildren(el('div', {className:'list', style:'background:none;margin:0'}, R.info.chapters.map((c, i) =>
      el('button', {className:'row' + (i === R.chapter ? ' on' : ''), onclick:() => { closeSheets(); goChapter(i); }},
        el('span', {className:'num'}, String(i + 1)), el('span', {className:'tx'}, el('b', {}, c.title))))));
    u.contents.el.classList.remove('closed');
    requestAnimationFrame(() => u.contents.body.querySelector('.on')?.scrollIntoView({block:'center'}));
  } else {
    const setPref = (k, v) => { const p = readerPrefs(); p[k] = v; store.set('ok.reader', p); applyReaderPrefs(); openSheet('settings'); };
    u.settings.body.replaceChildren(el('div', {className:'rset'},
      el('div', {className:'line'}, el('span', {}, `Text size ${prefs.size}%`), el('div', {className:'sizes'},
        el('button', {'aria-label':'Smaller text', disabled:prefs.size <= 80, onclick:() => setPref('size', prefs.size - 10)}, el('span', {style:'font-size:15px'}, 'A')),
        el('button', {'aria-label':'Larger text', disabled:prefs.size >= 220, onclick:() => setPref('size', prefs.size + 10)}, el('span', {style:'font-size:24px'}, 'A')))),
      el('div', {className:'line'}, el('span', {}, 'Page'), el('div', {className:'themes'}, [['light', 'Light', '#fff', '#1c1f1d'], ['sepia', 'Sepia', '#f4ecd8', '#4b3a2a'], ['dark', 'Dark', '#141615', '#e4e8e5']].map(([v, t, bg, fg]) =>
        el('button', {className:prefs.theme === v ? 'on' : '', 'aria-pressed':String(prefs.theme === v), style:`background:${bg};color:${fg}`, onclick:() => setPref('theme', v)}, t))))));
    u.settings.el.classList.remove('closed');
  }
  u.scrim.classList.remove('closed');
}
function closeSheets(){ if (!R.ui) return; for (const s of [R.ui.contents, R.ui.settings]) s.el.classList.add('closed'); R.ui.scrim.classList.add('closed'); }
function applyReaderPrefs(){
  const p = readerPrefs();
  $('#reader').dataset.theme = p.theme;
  R.frame?.contentWindow?.postMessage({ok:'style', theme:p.theme, size:p.size}, '*');
}
async function openReader(b, startChapter){
  let info;
  try { info = await getBookInfo(b.id); } catch (e) { if (e.message !== 'pin') toast(e.message); return; }
  if (info.format !== 'epub' || !info.chapters?.length) { toast('This book can’t be opened here.'); return; }
  if (!R.ui) buildReader();
  newFrame();
  R.book = S.books.get(b.id) || b; R.info = info; R.basePath = new URL(info.base).pathname;
  const p = R.book.progress;
  if (startChapter != null) { R.chapter = startChapter; R.pending = 0; }
  else if (!p || p.finished) { R.chapter = 0; R.pending = 0; }
  else { R.chapter = Math.min(Math.max(0, p.track || 0), info.chapters.length - 1); R.pending = clamp01(p.seconds); }
  R.fraction = R.pending;
  R.ui.title.textContent = info.title || b.title;
  applyReaderPrefs();
  $('#reader').classList.remove('hidden', 'bare');
  document.body.classList.add('reading');
  if (playing && !$('#player').classList.contains('mini')) setMini(true);
  if (history.state?.overlay !== 'reader') history.pushState({...(history.state || {}), overlay:'reader'}, '');
  loadChapter();
  if (startChapter === 0) saveReading(true);
}
function chapterURL(path){
  const p = readerPrefs();
  return R.info.base + path.split('/').map(encodeURIComponent).join('/') + `?t=${p.theme}&s=${p.size}`;
}
function loadChapter(){
  frameGo(chapterURL(R.info.chapters[R.chapter].path));
  renderReaderBar();
}
function goChapter(i, at = 0){
  if (!R.info || i < 0 || i >= R.info.chapters.length) return;
  R.chapter = i; R.pending = at; R.fraction = at;
  loadChapter();
  saveReading();
}
function renderReaderBar(){
  const u = R.ui, n = R.info.chapters.length;
  u.chapterName.textContent = R.info.chapters[R.chapter].title;
  u.where.textContent = `Section ${R.chapter + 1} of ${n}`;
  u.prog.style.width = `${((R.chapter + R.fraction) / n * 100).toFixed(1)}%`;
  u.prev.disabled = R.chapter === 0;
  u.next.disabled = R.chapter >= n - 1;
}
// Saves the chapter and how far down it (the same fields the Mac's reader uses). Waits for scrolling to settle.
function saveReading(now){
  clearTimeout(R.timer);
  const write = () => {
    if (!R.book) return;
    const done = R.chapter === R.info.chapters.length - 1 && R.fraction > 0.97;
    saveBookProgress(R.book, done ? 0 : R.chapter, done ? 0 : R.fraction, done);
  };
  if (now) write(); else R.timer = setTimeout(write, 800);
}
function closeReader(){ if (history.state?.overlay === 'reader') history.back(); else closeReaderNow(); }
function closeReaderNow(){
  if (!readerOpen()) return;
  if (R.timer) { clearTimeout(R.timer); R.timer = null; saveReading(true); }
  closeSheets();
  $('#reader').classList.add('hidden');
  document.body.classList.remove('reading');
  R.frame?.remove(); R.frame = null;
  R.book = null;
  showPage(topPage());
}
window.addEventListener('message', e => {
  if (!R.frame || e.source !== R.frame.contentWindow || !readerOpen()) return;
  const d = e.data;
  if (!d || typeof d !== 'object') return;
  if (d.ok === 'ready') {
    R.loading = false;
    if (R.pending > 0) R.frame.contentWindow.postMessage({ok:'scroll', f:R.pending}, '*');
    R.fraction = R.pending; R.pending = 0;
    renderReaderBar();
  } else if (d.ok === 'progress' && !R.loading) {
    R.fraction = clamp01(d.f); renderReaderBar(); saveReading();
  } else if (d.ok === 'edge') {
    if (d.dir > 0) goChapter(R.chapter + 1); else goChapter(R.chapter - 1, 1);
  } else if (d.ok === 'chrome') {
    $('#reader').classList.toggle('bare');
  } else if (d.ok === 'close') {
    closeReader();
  } else if (d.ok === 'link' && typeof d.path === 'string' && d.path.startsWith(R.basePath)) {
    let rel; try { rel = decodeURIComponent(d.path.slice(R.basePath.length)); } catch (x) { return; }
    const i = R.info.chapters.findIndex(c => c.path === rel);
    if (i >= 0) goChapter(i);
    else frameGo(chapterURL(rel) + (typeof d.hash === 'string' ? d.hash.replace(/[^\w#.:-]/g, '') : ''));
  }
});
document.addEventListener('keydown', e => {
  if (!readerOpen() || e.target.closest?.('input,textarea,select')) return;
  if (e.key === 'Escape') { if (!R.ui.scrim.classList.contains('closed')) closeSheets(); else closeReader(); }
  else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft' || e.key === ' ') { e.preventDefault(); R.frame.contentWindow?.postMessage({ok:'page', dir:e.key === 'ArrowLeft' || e.shiftKey ? -1 : 1}, '*'); }
});

// ---- Play: games stream from the Mac (the player itself comes from /assets/play.js in a later update) ----
function openGame(g, resume){
  // When the player closes, the game list is asked for again: the game now has a saved place, new artwork and a
  // last-played time, for Continue and the Resume tag.
  if (window.OKPlay && typeof window.OKPlay.open === 'function') window.OKPlay.open(g.id, {resume:!!resume, title:g.title, onClose:refreshGames});
  else toast('Games come to the web page in a later update.');
}
function playPage(){
  const P = makePage({title:'Play', refresh:async () => { delete inflight.games; S.games = undefined; P.render(); await loadGames(); rerender(); }, actions:[searchButton()]});
  P.render = () => {
    if (S.games === undefined) { P.body.replaceChildren(skShelf('game'), skShelf('game')); loadGames().then(() => P.render()).catch(() => {}); return; }
    if (S.games === null || !window.OKPlay) { P.body.replaceChildren(empty('🎮', 'Games come to the web page in a later update', 'For now, play them in Offline Kit on the Mac or the Apple TV.')); return; }
    if (!S.games.length) { P.body.replaceChildren(empty('🎮', 'No games yet', 'Add games in Offline Kit on the Mac. They show up here.')); return; }
    const recent = S.games.filter(g => g.canResume || g.lastPlayed).sort((a, b) => (b.lastPlayed || 0) - (a.lastPlayed || 0));
    const systems = new Map();
    for (const g of [...S.games].sort((a, b) => String(a.title).localeCompare(String(b.title)))) {
      const s = systemName(g) || 'Games'; if (!systems.has(s)) systems.set(s, []); systems.get(s).push(g);
    }
    P.body.replaceChildren(...[shelf('Continue Playing', recent.map(g => gameCard(g, true))),
      ...[...systems].sort((a, b) => a[0].localeCompare(b[0])).map(([s, list]) => shelf(s, list.map(g => gameCard(g))))].filter(Boolean));
  };
  P.render();
  window.addEventListener('load', () => P.render());
  return P;
}

// ---- Search across everything ----
function openSearch(){
  const P = push(searchPage());
  P.input.focus();
}
function searchPage(){
  const P = makePage({title:'Search', large:false, back:topPage()?.title, solidAt:-1});
  P.el.classList.add('scrolled');
  const input = el('input', {type:'search', placeholder:'Movies, music, books and articles', autocomplete:'off', enterkeyhint:'search', 'aria-label':'Search everything'});
  const results = el('div');
  P.input = input;
  P.body.append(el('label', {className:'searchbox'}, icon('search'), input), results);
  let timer, request = 0;
  const has = (q, ...values) => values.some(v => v != null && String(v).toLowerCase().includes(q));
  const run = () => {
    const raw = input.value.trim(), q = raw.toLowerCase(), mine = ++request;
    if (!q) { results.replaceChildren(el('p', {className:'note'}, 'Search titles, artists, authors and genres on the Mac, plus article titles in every archive.')); return; }
    const media = (S.media?.items || []).filter(i => has(q, i.title, i.artist, i.genre, i.series, i.studio));
    const books = [...S.books.values()].filter(b => has(q, b.title, b.author, b.genre, b.series));
    const games = (S.games || []).filter(g => has(q, g.title, g.system, g.systemName));
    const archives = (S.archives || []).filter(a => has(q, a.title, a.fullTitle, a.kind));
    const articles = el('div', {}, skShelf());
    const sec = (title, node) => el('section', {className:'section'}, el('div', {className:'shead'}, el('h2', {}, title)), node);
    const videos = media.filter(i => i.category === 'video'), audio = media.filter(i => i.category !== 'video');
    results.replaceChildren(...[
      videos.length ? sec('Watch', el('div', {className:'shelf'}, videos.slice(0, 20).map(mediaCard))) : null,
      audio.length ? sec('Listen', el('div', {className:'shelf'}, audio.slice(0, 20).map(mediaCard))) : null,
      books.length ? sec('Read', el('div', {className:'shelf'}, books.slice(0, 20).map(bookCard))) : null,
      games.length ? sec('Play', el('div', {className:'shelf'}, games.slice(0, 20).map(g => gameCard(g)))) : null,
      archives.length ? sec('Archives', el('div', {className:'list'}, archives.map(archiveRow))) : null,
      articles,
    ].filter(Boolean));
    api('/api/search?q=' + encodeURIComponent(raw)).then(r => r.json()).then(({results:hits}) => {
      if (mine !== request) return;
      const found = media.length + books.length + games.length + archives.length;
      if (hits.length) articles.replaceChildren(sec('Articles', el('div', {className:'list'}, hits.map(h =>
        el('a', {className:'row', href:safeURL(h.url), target:'_blank', rel:'noopener'}, el('span', {className:'ic'}, icon('doc')),
          el('span', {className:'tx'}, el('b', {}, h.title), el('small', {}, h.book)), icon('chev', 'chev'))))));
      else articles.replaceChildren(found ? '' : empty('🔍', 'No matches', 'Try fewer words, or ask the question on the Ask tab.'));
    }).catch(() => { if (mine === request) articles.replaceChildren(); });
  };
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(run, 220); });
  input.addEventListener('keydown', e => { if (e.key === 'Enter') { clearTimeout(timer); run(); input.blur(); } });
  run();
  return P;
}

// ---- Ask ----
const suggestions = [
  ['Water', 'How do I purify water without power?'],
  ['First aid', 'Signs of heat stroke in a child'],
  ['Home', 'How do I reset a tripped GFCI outlet?'],
  ['Food', 'How long does food last in a fridge without power?'],
  ['First aid', 'How do I treat a deep cut?'],
  ['Vehicles', "My car won't start and just clicks"]];
let askUI = null, busy = false;
const pill = (text, ok) => el('span', {className:ok ? 'pill ok' : 'pill'}, text);
function askPage(){
  const P = makePage({title:'Ask'});
  const pills = el('div', {className:'pills'});
  const welcome = el('div', {},
    el('p', {className:'subtitle'}, 'Answers come from the archives saved on the Mac, with numbered sources you can open. No internet needed.'),
    pills,
    el('div', {className:'suggest'}, suggestions.map(([t, q]) => el('button', {onclick:() => ask(q)}, el('small', {}, t), q))));
  const turns = el('div');
  P.body.append(welcome, turns, el('p', {className:'asknote'}, 'Answers come from your offline library where it covers the question, and anything else is labeled “Not from the library.” They can still be wrong. Check the sources for anything safety-critical.'));
  askUI = {welcome, turns, P};
  P.render = () => {
    const s = S.status;
    if (s) pills.replaceChildren(pill('Works offline', true), pill(count(s.archives, 'archive')), pill(`${Number(s.articles).toLocaleString()} articles`), pill(s.engine));
  };
  P.render();
  return P;
}
// Minimal markdown as DOM: paragraphs, lists, headings, **bold**, *italic* and [n] citations.
function inline(text, byNum){
  const out = [];
  for (const part of text.split(/(\*\*[^*]+\*\*|\*[^*\s][^*]*\*|\[\d{1,2}\])/)) {
    if (!part) continue;
    let m;
    if ((m = part.match(/^\*\*(.+)\*\*$/))) out.push(el('b', {}, m[1]));
    else if ((m = part.match(/^\*(.+)\*$/))) out.push(el('i', {}, m[1]));
    else if ((m = part.match(/^\[(\d{1,2})\]$/)) && byNum[m[1]])
      out.push(el('a', {className:'cite', href:safeURL(byNum[m[1]].url), target:'_blank'}, `[${m[1]}]`));
    else out.push(part);
  }
  return out;
}
function render(text, sources){
  const byNum = Object.fromEntries((sources || []).map(s => [s.n, s]));
  const frag = document.createDocumentFragment();
  let list = null, listTag = null;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    const ul = line.match(/^[-*•]\s+(.*)/), ol = line.match(/^\d+[.)]\s+(.*)/), h = line.match(/^#{1,4}\s+(.*)/);
    const want = ul ? 'ul' : ol ? 'ol' : null;
    if (list && want !== listTag) { list = null; listTag = null; }
    if (want) {
      if (!list) { list = el(want); listTag = want; frag.append(list); }
      list.append(el('li', {}, inline((ul || ol)[1], byNum)));
    } else if (h) frag.append(el('p', {}, el('b', {}, inline(h[1], byNum))));
    else if (line) frag.append(el('p', {}, inline(line, byNum)));
  }
  return frag;
}
function sourceCard(s){
  return el('a', {className:'src', href:safeURL(s.url), target:'_blank'}, el('span', {className:'n'}, String(s.n)), el('span', {}, el('b', {}, s.title), el('small', {}, s.book)));
}
async function ask(question){
  question = question.trim();
  if (!question || busy) return;
  if (current !== 'ask') selectTab('ask');
  busy = true; $('#send').disabled = true; $('#askinput').value = ''; resize();
  askUI.welcome.classList.add('hidden');
  const status = el('div', {className:'status'}, el('span', {className:'spin'}), 'Searching the library...');
  const answer = el('div', {className:'answer'}), meta = el('div', {className:'meta'}), srcBox = el('div', {className:'sources'});
  const turn = el('div', {className:'turn'}, el('div', {className:'q'}, question), el('div', {className:'a'}, status, answer, meta), srcBox);
  askUI.turns.append(turn); turn.scrollIntoView({behavior:reduceMotion() ? 'auto' : 'smooth'});
  let sources = [], engine = '';
  const t0 = performance.now();
  try {
    const r = await api('/api/ask', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({question})});
    if (!r.ok) { const j = await r.json().catch(() => ({})); throw new Error(j.error || 'The Mac could not answer.'); }
    const reader = r.body.getReader(), dec = new TextDecoder(); let buf = '';
    for (;;) {
      const {value, done} = await reader.read(); if (done) break;
      buf += dec.decode(value, {stream:true});
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const block = buf.slice(0, i); buf = buf.slice(i + 2);
        const ev = (block.match(/^event: (.*)$/m) || [])[1], data = JSON.parse((block.match(/^data: (.*)$/m) || [])[1] || 'null');
        if (ev === 'engine') engine = data;
        if (ev === 'sources') {
          sources = data;
          status.replaceChildren(el('span', {className:'spin'}), `Reading ${count(sources.length, 'source')}...`);
          srcBox.replaceChildren(...sources.map(sourceCard));
        }
        if (ev === 'answer') { status.classList.add('hidden'); answer.replaceChildren(render(data, sources)); }
        if (ev === 'error') throw new Error(data);
      }
    }
    status.classList.add('hidden');
    meta.replaceChildren(pill(engine), pill('Offline', true), el('small', {style:'color:var(--muted)'}, `${((performance.now() - t0) / 1000).toFixed(1)}s`));
  } catch (e) {
    if (e.message !== 'pin') { status.classList.add('hidden'); answer.append(el('p', {className:'err'}, e.message)); }
  }
  busy = false; $('#send').disabled = !$('#askinput').value.trim();
}
const askInput = $('#askinput');
function resize(){ askInput.style.height = 'auto'; askInput.style.height = Math.min(askInput.scrollHeight, 140) + 'px'; }
askInput.oninput = () => { resize(); $('#send').disabled = busy || !askInput.value.trim(); };
askInput.onkeydown = e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); ask(askInput.value); } };
$('#askform').onsubmit = e => { e.preventDefault(); ask(askInput.value); };

// ---- Player (video and audio) ----
let playing = null, saveTimer = null, sleepTimer = null, progressWrite = Promise.resolve();
function setMini(small){
  const player = $('#player');
  player.classList.toggle('mini', small);
  document.body.classList.toggle('mini', small && !!playing);
  const b = playing?.miniButton;
  if (b) { b.replaceChildren(icon(small ? 'up' : 'down')); b.setAttribute('aria-label', small ? 'Expand player' : 'Minimize player'); }
}
function selectControl(label, value, options, change){
  const select = el('select', {'aria-label':label, onchange:e => change(e.target.value)}, options.map(([v, t]) => el('option', {value:v, selected:v === value}, t)));
  return el('label', {}, el('span', {}, label), select);
}
function saveProgress(finished){
  if (!playing) return Promise.resolve();
  const p = playing;
  const value = {id:p.item.id, track:p.track, seconds:finished ? 0 : p.el.currentTime || 0, finished:!!finished};
  p.item.progress = {...value, updated:Date.now() / 1000};
  progressWrite = progressWrite.catch(() => {}).then(() => api('/api/media/progress', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(value)})).catch(() => {});
  return progressWrite;
}
async function closePlayer(){
  if (playing) { const p = playing; await saveProgress(p.completed); p.el.onpause = null; p.el.onended = null; p.el.pause(); p.el.removeAttribute('src'); p.el.load(); }
  clearInterval(saveTimer); clearTimeout(sleepTimer); playing = null;
  $('#player').className = 'hidden'; $('#player').replaceChildren(); document.body.classList.remove('mini');
  // Places changed: the shelves and Continue row come back fresh from the Mac.
  S.shelves = {}; detailCache.clear();
  loadMedia().then(rerender).catch(() => {});
}
async function openPlayer(it, fromStart, chosen){
  if (playing?.item.id === it.id && !fromStart && chosen == null) { setMini(false); return; }
  if (playing) await closePlayer();
  const p = it.progress || {}, isVideo = it.kind === 'video', music = it.category === 'music';
  const order = it.tracks.map((_, i) => i);
  if (chosen === -1) for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [order[i], order[j]] = [order[j], order[i]]; }
  const startTrack = chosen === -1 ? order[0] : chosen != null ? chosen : fromStart || p.finished ? 0 : Math.min(p.track || 0, it.tracks.length - 1);
  const startAt = chosen != null || fromStart || p.finished ? 0 : p.seconds || 0;
  const m = el(isVideo ? 'video' : 'audio', {controls:isVideo, playsInline:true, preload:'auto'});
  playing = {item:it, track:startTrack, el:m, completed:false, sleepAtEnd:false};
  const chapter = el('p', {}), seek = el('input', {type:'range', min:0, max:1, step:0.001, value:0, 'aria-label':'Playback position'}), time = el('div', {className:'times'}), progress = el('div', {className:'pprog'}, el('i'));
  const ppIcon = () => icon(m.paused ? 'playfill' : 'pausefill', 'fill');
  const toggle = el('button', {className:'pp', 'aria-label':'Play', onclick:() => m.paused ? m.play().catch(() => {}) : m.pause()}, icon('playfill', 'fill'));
  const miniToggle = el('button', {className:'minionly', 'aria-label':'Play', onclick:() => m.paused ? m.play().catch(() => {}) : m.pause()}, icon('playfill', 'fill'));
  const tracks = el('div', {className:'tracks'});
  function load(index, at = 0, autoplay = true){
    if (!playing || !it.tracks[index]) return;
    playing.track = index; playing.completed = false;
    m.onloadedmetadata = () => { m.currentTime = at; };
    m.src = safeURL(it.tracks[index].url); chapter.textContent = it.tracks.length > 1 ? it.tracks[index].title : '';
    if (autoplay) m.play().catch(() => {});
    if (it.tracks.length > 1) tracks.replaceChildren(...it.tracks.map((t, i) => el('button', {className:'row' + (i === index ? ' on' : ''), onclick:() => load(i)},
      el('span', {className:'num'}, i === index ? '▶' : String(i + 1)), el('span', {className:'tx'}, el('b', {}, t.title)), el('small', {className:'num', style:'width:auto'}, t.duration ? mt(t.duration) : ''))));
  }
  function next(){ const position = order.indexOf(playing.track); if (position + 1 < order.length) load(order[position + 1]); }
  const skip = n => { if (Number.isFinite(m.duration)) m.currentTime = Math.max(0, Math.min(m.duration, m.currentTime + n)); };
  seek.oninput = () => { if (Number.isFinite(m.duration)) m.currentTime = Number(seek.value) * m.duration; };
  const prevChapter = () => { const pos = order.indexOf(playing.track); if (m.currentTime > 5 || pos <= 0) m.currentTime = 0; else load(order[pos - 1]); };
  const chaptered = !music && it.tracks.length > 1;
  const controls = el('div', {className:'ctrls'},
    chaptered ? el('button', {'aria-label':'Previous chapter', onclick:prevChapter}, '⏮') : null,
    el('button', {'aria-label':music ? 'Previous song' : 'Back 15 seconds', onclick:() => { if (music && m.currentTime < 5) { const pos = order.indexOf(playing.track); if (pos > 0) load(order[pos - 1]); } else skip(music ? -m.currentTime : -15); }}, music ? '⏮' : '−15'),
    toggle,
    el('button', {'aria-label':music ? 'Next song' : 'Forward 30 seconds', onclick:() => music ? next() : skip(30)}, music ? '⏭' : '+30'),
    chaptered ? el('button', {'aria-label':'Next chapter', onclick:next}, '⏭') : null);
  const speed = selectControl('Speed', '1', [['0.75', '0.75×'], ['1', '1×'], ['1.25', '1.25×'], ['1.5', '1.5×'], ['1.75', '1.75×'], ['2', '2×']], v => { m.playbackRate = Number(v); });
  const sleep = selectControl('Sleep', 'off', [['off', 'Off'], ['15', '15 minutes'], ['30', '30 minutes'], ['60', '60 minutes'], ['chapter', 'End of chapter']], v => {
    clearTimeout(sleepTimer); playing.sleepAtEnd = v === 'chapter';
    if (v !== 'off' && v !== 'chapter') sleepTimer = setTimeout(() => { m.pause(); sleep.querySelector('select').value = 'off'; }, Number(v) * 60000);
  });
  const player = $('#player');
  const mini = el('button', {'aria-label':'Minimize player', onclick:() => setMini(!player.classList.contains('mini'))}, icon('down'));
  playing.miniButton = mini;
  const top = el('div', {className:'top'}, mini, el('b', {}, it.title), isVideo ? null : miniToggle, el('button', {onclick:closePlayer, 'aria-label':'Close player and save your place'}, icon('close')));
  const body = isVideo ? m : el('div', {className:'audiobox'}, art(it, it.thumb || it.cover, 'pcover'), el('h2', {}, it.title), el('p', {}, it.artist || ''), chapter, seek, time, controls,
    !music ? el('div', {className:'tools'}, speed, sleep) : null, it.tracks.length > 1 ? tracks : null);
  let cancelNext = false, nextItem = null, upNext = null;
  const nextLabel = el('span', {});
  player.replaceChildren(top, body, progress);
  if (!isVideo) player.append(m);
  player.className = '';
  // The video that plays next is looked up while this one starts; the card appears once it is known.
  detailFor(it).then(d => {
    const n = S.byId.get(d.upNext);
    if (!n || !playing || playing.el !== m) return;
    nextItem = n;
    upNext = el('div', {className:'upnext-card hidden'}, nextLabel, el('b', {}, n.title), el('button', {onclick:() => openPlayer(n, false)}, 'Play Now'), el('button', {onclick:() => { cancelNext = true; upNext.classList.add('hidden'); }}, 'Cancel'));
    player.append(upNext);
  });
  m.onplay = () => { toggle.replaceChildren(ppIcon()); miniToggle.replaceChildren(ppIcon()); toggle.setAttribute('aria-label', 'Pause'); miniToggle.setAttribute('aria-label', 'Pause'); };
  m.onpause = () => { toggle.replaceChildren(ppIcon()); miniToggle.replaceChildren(ppIcon()); toggle.setAttribute('aria-label', 'Play'); miniToggle.setAttribute('aria-label', 'Play'); if (!playing?.completed) saveProgress(false); };
  m.ontimeupdate = () => {
    const f = Number.isFinite(m.duration) && m.duration > 0 ? m.currentTime / m.duration : 0;
    seek.value = f; time.replaceChildren(el('span', {}, mt(m.currentTime)), el('span', {}, '−' + mt(m.duration - m.currentTime))); progress.firstChild.style.width = `${f * 100}%`;
    if (upNext && !cancelNext && m.duration - m.currentTime <= 20) { upNext.classList.remove('hidden'); nextLabel.textContent = `Up next in ${Math.max(0, Math.ceil(m.duration - m.currentTime))}s`; }
  };
  m.onended = async () => {
    const pos = order.indexOf(playing.track);
    if (pos + 1 < order.length) { const stop = playing.sleepAtEnd; load(order[pos + 1], 0, !stop); if (stop) { playing.sleepAtEnd = false; m.pause(); sleep.querySelector('select').value = 'off'; } }
    else { playing.completed = true; await closePlayer(); if (nextItem && !cancelNext) openPlayer(nextItem, false); }
  };
  load(startTrack, startAt);
  saveTimer = setInterval(() => { if (playing && !m.paused) saveProgress(false); }, 5000);
}

// ---- Sign in ----
let pinValue = '', booted = false;
function needPin(){
  document.body.classList.add('signedout');
  $('#pin').classList.remove('hidden');
  if (!$('#keys').childElementCount) buildKeys();
  drawDots();
}
function buildKeys(){
  const letters = ['', 'ABC', 'DEF', 'GHI', 'JKL', 'MNO', 'PQRS', 'TUV', 'WXYZ'];
  const keys = letters.map((l, i) => el('button', {type:'button', 'aria-label':String(i + 1), onclick:() => typeDigit(String(i + 1))}, el('span', {}, String(i + 1), l ? el('small', {}, l) : null)));
  keys.push(el('button', {type:'button', className:'plain', onclick:() => { pinValue = pinValue.slice(0, -1); drawDots(); }}, 'Delete'),
    el('button', {type:'button', 'aria-label':'0', onclick:() => typeDigit('0')}, '0'),
    el('button', {type:'button', className:'plain', onclick:submitPin}, 'OK'));
  $('#keys').replaceChildren(...keys);
}
function typeDigit(d){ if (pinValue.length < 8) { pinValue += d; drawDots(); $('#pinerr').textContent = ''; } }
function drawDots(){ $('#dots').replaceChildren(...Array.from({length:Math.max(4, pinValue.length)}, (_, i) => el('i', {className:i < pinValue.length ? 'f' : ''}))); }
document.addEventListener('keydown', e => {
  if ($('#pin').classList.contains('hidden')) return;
  if (/^[0-9]$/.test(e.key)) typeDigit(e.key);
  else if (e.key === 'Backspace') { pinValue = pinValue.slice(0, -1); drawDots(); }
  else if (e.key === 'Enter') submitPin();
});
async function submitPin(){
  if (!pinValue) return;
  const r = await fetch('/api/login', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({pin:pinValue})}).catch(() => null);
  pinValue = ''; drawDots();
  if (r && r.ok) { $('#pin').classList.add('hidden'); document.body.classList.remove('signedout'); if (booted) reloadAll(); else start(); return; }
  $('#dots').classList.remove('shake'); void $('#dots').offsetWidth; $('#dots').classList.add('shake');
  $('#pinerr').textContent = !r ? 'Can’t reach the Mac.' : r.status === 429 ? 'Too many wrong tries. Wait a few minutes, then try again.' : 'That PIN didn’t work.';
}

// ---- Add to Home Screen hint (iPhone and iPad Safari, once) ----
function maybeHint(){
  const ua = navigator.userAgent;
  const ios = /iPhone|iPad|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const forced = /[?&]a2hs=1/.test(location.search);
  if (!forced && (!ios || /CriOS|FxiOS|EdgiOS/.test(ua) || standalone() || store.get('ok.a2hs', false))) return;
  setTimeout(() => {
    if ($('#a2hs')) return;
    const box = el('div', {id:'a2hs', role:'note'}, el('img', {src:'/assets/icon-180.png', alt:''}),
      el('p', {}, el('b', {}, 'Add Offline Kit to your Home Screen'), el('br'), 'Tap ', icon('share'), ' Share, then “Add to Home Screen.”'),
      el('button', {'aria-label':'Dismiss', onclick:() => { store.set('ok.a2hs', true); box.remove(); }}, icon('close')));
    document.body.append(box);
  }, 1200);
}

// ---- Start ----
async function start(){
  try { S.status = await getJSON('/api/status'); }
  catch (e) {
    if (e.message === 'pin') return;
    $('#app').replaceChildren(el('div', {className:'page'}, el('div', {className:'scroll'}, empty('📡', 'Can’t reach the Mac', 'Check that this device is on the same Wi-Fi as the Mac and that Share on Wi-Fi is on.', el('button', {className:'btn primary', onclick:() => location.reload()}, 'Try Again')))));
    return;
  }
  booted = true;
  document.body.classList.remove('signedout');
  buildTabbar();
  const wanted = location.hash.slice(1);
  selectTab(ROOTS[wanted] ? wanted : 'home');
  loadAll();
  maybeHint();
  edgeSwipe();
}
start();
"""#

    /// Served at /epub-reader.js on the archive port and loaded (by nonce) into every EPUB page the reader shows.
    static let bookFrameScript = #"""
(function () {
  'use strict';
  // Runs inside a book page (a sandboxed frame on the archive port). It styles the page, reports how far down it the
  // reader is, turns taps, swipes and keys into page turns, and hands links to Offline Kit's page. The book's own
  // scripts never run (the page's policy only allows this one).
  var themes = {light: ['#ffffff', '#1c1f1d', '#2E7F60'], sepia: ['#f4ecd8', '#4b3a2a', '#2E7F60'], dark: ['#141615', '#e4e8e5', '#5FC398']};
  var query = new URLSearchParams(location.search);
  var style = document.createElement('style');
  function css(theme, size) {
    var c = themes[theme] || themes.light;
    size = Math.min(220, Math.max(80, parseInt(size, 10) || 110));
    return 'html{font-size:' + size + '% !important;-webkit-text-size-adjust:none;text-size-adjust:none}' +
      'html,body{background:' + c[0] + ' !important;color:' + c[1] + ' !important}' +
      'body{max-width:38em;margin:0 auto !important;padding:60px 22px 100px !important;line-height:1.6 !important;' +
      'font-family:"New York","Iowan Old Style",Georgia,serif;overflow-wrap:break-word}' +
      'a{color:' + c[2] + ' !important}' +
      'img,svg,video{max-width:100% !important;height:auto !important}' +
      (theme === 'light' ? '' : 'body *:not(a){color:inherit !important;background-color:transparent !important}') +
      '::selection{background:rgba(95,195,152,.35)}';
  }
  style.textContent = css(query.get('t'), query.get('s'));
  (document.head || document.documentElement).appendChild(style);

  var parentWindow = window.parent;
  function post(message) { try { parentWindow.postMessage(message, '*'); } catch (e) {} }
  function root() { return document.scrollingElement || document.documentElement; }
  function fraction() {
    var h = root().scrollHeight - window.innerHeight;
    return h > 0 ? Math.min(1, Math.max(0, window.scrollY / h)) : 1;
  }
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  function page(dir) {
    var h = root().scrollHeight - window.innerHeight, y = window.scrollY;
    if (dir > 0 && y >= h - 4) { post({ok: 'edge', dir: 1}); return; }
    if (dir < 0 && y <= 4) { post({ok: 'edge', dir: -1}); return; }
    window.scrollBy({top: dir * Math.max(120, window.innerHeight - 130), behavior: reduce ? 'auto' : 'smooth'});
  }

  var timer;
  window.addEventListener('scroll', function () {
    clearTimeout(timer);
    timer = setTimeout(function () { post({ok: 'progress', f: fraction()}); }, 250);
  }, {passive: true});

  window.addEventListener('message', function (e) {
    if (e.source !== parentWindow) return;
    var d = e.data || {};
    if (d.ok === 'style') style.textContent = css(d.theme, d.size);
    else if (d.ok === 'scroll') window.scrollTo(0, (root().scrollHeight - window.innerHeight) * Math.min(1, Math.max(0, +d.f || 0)));
    else if (d.ok === 'page') page(d.dir > 0 ? 1 : -1);
  });

  document.addEventListener('click', function (e) {
    var link = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (link) {
      var href = link.getAttribute('href') || '';
      e.preventDefault();
      if (href.charAt(0) === '#') {
        // A note or section on this page: scroll to it without a navigation (which would add to the page's history).
        var id = decodeURIComponent(href.slice(1)), target = document.getElementById(id) || document.getElementsByName(id)[0];
        if (target) target.scrollIntoView({behavior: reduce ? 'auto' : 'smooth'});
        return;
      }
      var url;
      try { url = new URL(href, location.href); } catch (x) { return; }
      if (url.protocol === location.protocol && url.host === location.host) post({ok: 'link', path: url.pathname, hash: url.hash});
      return;
    }
    if (window.getSelection && String(window.getSelection())) return;
    var x = e.clientX / window.innerWidth;
    if (x < 0.28) page(-1); else if (x > 0.72) page(1); else post({ok: 'chrome'});
  });

  var sx = 0, sy = 0, st = 0, multi = false;
  document.addEventListener('touchstart', function (e) {
    multi = e.touches.length > 1;
    sx = e.touches[0].clientX; sy = e.touches[0].clientY; st = Date.now();
  }, {passive: true});
  document.addEventListener('touchend', function (e) {
    if (multi) return;
    var t = e.changedTouches[0], dx = t.clientX - sx, dy = t.clientY - sy;
    if (Math.abs(dx) > 70 && Math.abs(dy) < 45 && Date.now() - st < 700) page(dx < 0 ? 1 : -1);
  }, {passive: true});

  document.addEventListener('keydown', function (e) {
    if (e.key === 'ArrowRight' || e.key === 'PageDown' || (e.key === ' ' && !e.shiftKey)) { e.preventDefault(); page(1); }
    else if (e.key === 'ArrowLeft' || e.key === 'PageUp' || (e.key === ' ' && e.shiftKey)) { e.preventDefault(); page(-1); }
    else if (e.key === 'Escape') post({ok: 'close'});
  });

  window.addEventListener('load', function () { post({ok: 'ready'}); });
})();
"""#
}

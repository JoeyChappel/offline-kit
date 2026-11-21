import Foundation

extension WebApp {
    /// The page script (kept separate so the HTML stays readable).
    static let script = #"""
const $ = s => document.querySelector(s);
let busy = false;

// Builds elements without parsing HTML: el('a', {className:'x', href:'/'}, 'text', child)
function el(tag, props, ...children){
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (k === 'dataset') Object.assign(node.dataset, v); else if (k in node) node[k] = v; else node.setAttribute(k, v);
  }
  for (const c of children.flat()) if (c != null && c !== false) node.append(c instanceof Node ? c : String(c));
  return node;
}
// Only same-server links are allowed in answers and lists.
const safeURL = u => (typeof u === 'string' && u.startsWith('/') && !u.startsWith('//') && !u.startsWith('/\\')) ? u : '#';

const suggestions = [
  ['Water','How do I purify water without power?'],
  ['First aid','Signs of heat stroke in a child'],
  ['Home','How do I reset a tripped GFCI outlet?'],
  ['Food','How long does food last in a fridge without power?'],
  ['First aid','How do I treat a deep cut?'],
  ['Vehicles',"My car won't start and just clicks"]];

function show(tab){
  for (const b of document.querySelectorAll('#tabs button')) b.classList.toggle('on', b.dataset.tab===tab);
  $('#ask').classList.toggle('hidden', tab!=='ask');
  $('#library').classList.toggle('hidden', tab!=='library');
  $('#watch').classList.toggle('hidden', tab!=='watch');
  $('#composer').classList.toggle('hidden', tab!=='ask');
  if (tab==='library') loadBooks();
  if (tab==='watch') loadWatch();
  history.replaceState(null,'', tab==='ask' ? '#' : '#'+tab);
}
document.querySelectorAll('#tabs button').forEach(b => b.onclick = () => show(b.dataset.tab));

async function api(path, opts){
  const r = await fetch(path, opts);
  if (r.status === 401) { needPin(); throw new Error('pin'); }
  return r;
}

function needPin(){
  for (const id of ['ask','library','watch']) $('#'+id).classList.add('hidden');
  $('#composer').classList.add('hidden'); $('#tabs').classList.add('hidden');
  $('#pin').classList.remove('hidden'); $('#pininput').focus();
}
$('#pinform').onsubmit = async e => {
  e.preventDefault();
  const r = await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pin:$('#pininput').value})});
  if (r.ok) location.reload(); else { $('#pinerr').textContent = r.status === 429 ? "Too many wrong tries. Wait a few minutes, then try again." : "That PIN didn't work."; $('#pininput').select(); }
};

const pill = (text, ok) => el('span', {className: ok ? 'pill ok' : 'pill'}, text);

async function init(){
  for (const [t, q] of suggestions) {
    $('#suggestions').append(el('button', {className:'card', onclick: () => ask(q)}, el('div', {className:'topic'}, t), el('div', {}, q)));
  }
  try {
    const s = await (await api('/api/status')).json();
    $('#macname').textContent = s.name;
    $('#pills').replaceChildren(pill('Works offline', true), pill(`${s.archives} archives`),
      pill(`${Number(s.articles).toLocaleString()} articles`), pill(s.engine));
  } catch(e) { return; }
  if (location.hash === '#library') show('library');
  if (location.hash === '#watch') show('watch');
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
      out.push(el('a', {className:'cite', href: safeURL(byNum[m[1]].url), target:'_blank'}, `[${m[1]}]`));
    else out.push(part);
  }
  return out;
}
function render(text, sources){
  const byNum = Object.fromEntries((sources||[]).map(s => [s.n, s]));
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
  return el('a', {className:'card src', href: safeURL(s.url), target:'_blank'},
    el('span', {className:'num'}, String(s.n)),
    el('span', {}, el('b', {}, s.title), el('small', {}, s.book)));
}

async function ask(question){
  question = question.trim();
  if (!question || busy) return;
  busy = true; $('#send').disabled = true; $('#input').value = ''; resize();
  $('#welcome').classList.add('hidden');
  const status = el('div', {className:'status'}, el('span', {className:'spin'}), 'Searching the library...');
  const answer = el('div', {className:'answer'}), meta = el('div', {className:'meta'}), srcBox = el('div', {className:'sources'});
  const turn = el('div', {}, el('div', {className:'q'}, question), el('div', {className:'card'}, status, answer, meta), srcBox);
  $('#turns').append(turn); turn.scrollIntoView({behavior:'smooth'});
  let sources = [], engine = '';
  const t0 = performance.now();
  try {
    const r = await api('/api/ask', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({question})});
    if (!r.ok) { const j = await r.json().catch(()=>({})); throw new Error(j.error || 'The Mac could not answer.'); }
    const reader = r.body.getReader(), dec = new TextDecoder(); let buf = '';
    for (;;) {
      const {value, done} = await reader.read(); if (done) break;
      buf += dec.decode(value, {stream:true});
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const block = buf.slice(0,i); buf = buf.slice(i+2);
        const ev = (block.match(/^event: (.*)$/m)||[])[1], data = JSON.parse((block.match(/^data: (.*)$/m)||[])[1] || 'null');
        if (ev === 'engine') engine = data;
        if (ev === 'sources') {
          sources = data;
          status.replaceChildren(el('span', {className:'spin'}), `Reading ${sources.length} source${sources.length===1?'':'s'}...`);
          srcBox.replaceChildren(...sources.map(sourceCard));
        }
        if (ev === 'answer') { status.classList.add('hidden'); answer.replaceChildren(render(data, sources)); }
        if (ev === 'error') throw new Error(data);
      }
    }
    status.classList.add('hidden');
    meta.replaceChildren(pill(engine), pill('Offline', true),
      el('small', {style:'color:var(--muted)'}, `${((performance.now()-t0)/1000).toFixed(1)}s`));
  } catch (e) {
    if (e.message !== 'pin') { status.classList.add('hidden'); answer.append(el('p', {className:'err'}, e.message)); }
  }
  busy = false; $('#send').disabled = !$('#input').value.trim();
}

const input = $('#input');
function resize(){ input.style.height='auto'; input.style.height=Math.min(input.scrollHeight,140)+'px'; }
input.oninput = () => { resize(); $('#send').disabled = busy || !input.value.trim(); };
input.onkeydown = e => { if (e.key==='Enter' && !e.shiftKey) { e.preventDefault(); ask(input.value); } };
$('#askform').onsubmit = e => { e.preventDefault(); ask(input.value); };

let booksLoaded = false;
async function loadBooks(){
  if (booksLoaded) return;
  const books = await (await api('/api/books')).json();
  booksLoaded = true;
  books.sort((a,b) => a.kindOrder-b.kindOrder || a.title.localeCompare(b.title));
  const nodes = []; let kind = '';
  for (const b of books) {
    if (b.kind !== kind) { kind = b.kind; nodes.push(el('div', {className:'group'}, kind)); }
    nodes.push(el('a', {className:'card book', href: '/book/' + encodeURIComponent(b.id)},
      el('span', {}, el('b', {}, b.title), el('br'), el('small', {}, `${Number(b.articles).toLocaleString()} articles · ${b.size}`)),
      el('span', {'aria-hidden':'true'}, '›')));
  }
  $('#books').replaceChildren(...(nodes.length ? nodes : [el('p', {className:'sub'}, 'No archives on the Mac yet.')]));
}

let timer;
$('#q').oninput = () => {
  clearTimeout(timer);
  const q = $('#q').value.trim();
  if (!q) { $('#results').replaceChildren(); $('#books').classList.remove('hidden'); return; }
  timer = setTimeout(async () => {
    const {results} = await (await api('/api/search?q='+encodeURIComponent(q))).json();
    $('#books').classList.add('hidden');
    $('#results').replaceChildren(...(results.length
      ? results.map(r => el('a', {className:'card hit', href: safeURL(r.url)}, el('b', {}, r.title), el('br'), el('small', {}, r.book)))
      : [el('p', {className:'sub'}, 'No titles match. Try fewer words, or ask the question on the Ask tab.')]));
  }, 220);
};

// ---- Watch & Listen: category → genre → collection, using the Mac's shared catalog ----
let catalog = null, watchRequest = 0;
const count = (n, word) => `${n} ${n === 1 ? word : word + 's'}`;
let watchFilter = 'all', watchGenre = '', watchSort = 'title', watchQuery = '', watchUnfinished = false, musicTab = 'albums', artistName = '';
const byId = id => catalog?.items.find(i => i.id === id);
const mediaURL = u => typeof u === 'string' && /^\/(?!\/)/.test(u) && !u.includes('\\') ? safeURL(u) : '#';
const mt = s => { s = Math.max(0, Math.floor(Number.isFinite(s) ? s : 0)); return s >= 3600 ? `${Math.floor(s/3600)}:${String(Math.floor(s/60)%60).padStart(2,'0')}:${String(s%60).padStart(2,'0')}` : `${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}`; };
function fraction(it){
  const p = it.progress; if (!p || p.finished || (p.seconds <= 5 && p.track === 0)) return null;
  const durations = it.tracks.map(t => t.duration || 0);
  if (durations.every(d => d > 0)) return Math.min(1, (durations.slice(0,p.track).reduce((a,b)=>a+b,0) + p.seconds) / durations.reduce((a,b)=>a+b,0));
  return it.tracks.length > 1 ? p.track / it.tracks.length : it.duration ? Math.min(1,p.seconds/it.duration) : null;
}
function poster(it){
  let h = 2166136261; for (const c of it.title) h = Math.imul(h ^ c.charCodeAt(0),16777619);
  return `linear-gradient(135deg,hsl(${Math.abs(h)%360} 36% 28%),hsl(${(Math.abs(h)+44)%360} 42% 12%))`;
}
function artwork(it, cls=''){
  return el('div',{className:'media-art '+cls,style:`background:${poster(it)}`},
    el('span',{className:'poster-title'},it.title),it.thumb || it.cover ? el('img',{src:mediaURL(it.thumb || it.cover),alt:'',loading:'lazy',onerror:e=>e.target.remove()}) : null);
}
function selectControl(label, value, options, change){
  const select = el('select',{'aria-label':label,onchange:e=>change(e.target.value)},options.map(([v,t])=>el('option',{value:v,selected:v===value},t)));
  return el('label',{className:'media-select'},el('span',{},label),select);
}
async function loadWatch(){
  const request = ++watchRequest;
  try {
    const params = new URLSearchParams({filter:watchFilter,sort:watchSort,genre:watchGenre,q:watchQuery,unfinished:String(watchUnfinished)});
    const response = await api('/api/media?'+params);
    if (!response.ok) throw new Error('The Mac could not load this collection.');
    const data = await response.json(); if(request !== watchRequest) return; catalog = data; renderWatch();
  } catch(e) { if(e.message !== 'pin') $('#watch').replaceChildren(el('p',{className:'media-empty'},'Couldn’t load your media. Check the connection to your Mac.',el('button',{onclick:loadWatch},'Try again'))); }
}
function renderWatch(){
  const nodes = [];
  const search = el('input',{type:'search',placeholder:'Search titles, artists and genres',value:watchQuery,'aria-label':'Search your media'});
  let searchDelay;
  search.oninput=()=>{watchQuery=search.value; clearTimeout(searchDelay);searchDelay=setTimeout(async()=>{const start=search.selectionStart;await loadWatch();const fresh=$('#media-search');fresh?.focus();try{fresh?.setSelectionRange(start,start);}catch{}},220);};
  search.id='media-search';
  nodes.push(el('div',{className:'media-heading'},el('h1',{},{all:'Watch',video:'Videos',audiobooks:'Audiobooks',music:'Music'}[watchFilter]||'Watch'),el('p',{},'A little time for yourself. Saved here, ready whenever.'),el('p',{className:'media-note'},'Books aren’t available here yet. Read them in Offline Kit on the Mac or iPhone.'),search,
    el('nav',{className:'media-chips','aria-label':'Media categories'},[['all','All'],['video','Videos'],['audiobooks','Audiobooks'],['music','Music']].map(([v,t])=>el('button',{className:v===watchFilter?'on':'','aria-pressed':v===watchFilter,onclick:()=>{watchFilter=v;watchGenre='';artistName='';loadWatch();}},t)))));
  if(watchFilter==='music') nodes.push(el('nav',{className:'media-music-tabs','aria-label':'Browse music'},['albums','artists','genres','songs'].map(t=>el('button',{className:musicTab===t?'on':'','aria-pressed':musicTab===t,onclick:()=>{musicTab=t;artistName='';renderWatch();}},t[0].toUpperCase()+t.slice(1)))));
  nodes.push(el('div',{className:'media-tools'},
    selectControl('Genre',watchGenre,[['','All genres'],...(catalog.genres||[]).map(g=>[g,g])],v=>{watchGenre=v;loadWatch();}),
    selectControl('Sort by',watchSort,[['title','Title A–Z'],['titleDescending','Title Z–A'],['added','Recently added'],['played','Recently played'],['year','Release year'],['duration','Duration'],['artist','Artist, then album']],v=>{watchSort=v;loadWatch();}),
    watchFilter!=='music'?el('label',{className:'media-toggle'},el('input',{type:'checkbox',checked:watchUnfinished,onchange:e=>{watchUnfinished=e.target.checked;loadWatch();}}),'Unfinished'):null));
  if((catalog.genres||[]).length) nodes.push(el('section',{className:'media-genres'},el('h2',{},'Browse genres'),el('div',{className:'strip'},catalog.genres.map(g=>{
    const matching=catalog.items.filter(i=>(watchFilter==='all'||i.category===watchFilter)&&i.genre===g);
    const first=matching[0];
    return el('button',{className:'genre-tile '+(watchGenre===g?'on':''),'aria-pressed':watchGenre===g,onclick:()=>{watchGenre=watchGenre===g?'':g;loadWatch();}}, first?artwork(first):null,el('strong',{},g),el('small',{},count(matching.length,'item')));
  }))));
  const results = (catalog.results || catalog.items.map(i=>i.id)).map(byId).filter(Boolean);
  if(watchFilter==='music' && musicTab==='artists' && !artistName){
    nodes.push(el('section',{className:'media-collection'},el('h2',{},'Artists'),el('div',{className:'artist-grid'},(catalog.artists||[]).map(a=>el('button',{className:'artist-card',onclick:()=>{artistName=a.name;renderWatch();}},artwork(byId(a.items[0])),el('b',{},a.name),el('small',{},count(a.items.length,'album')))))));
  } else if(watchFilter==='music' && musicTab==='songs') {
    const songs=catalog.songs?catalog.songs.map(s=>({it:byId(s.item),t:byId(s.item)?.tracks[s.index],index:s.index})).filter(s=>s.it&&s.t):results.flatMap(it=>it.tracks.map((t,index)=>({it,t,index})));
    nodes.push(el('section',{className:'media-collection'},el('h2',{},'Songs'),songs.map(({it,t,index})=>el('button',{className:'track-row',onclick:()=>openPlayer(it,false,index)},artwork(it),el('span',{},el('b',{},t.title),el('small',{},`${it.artist||'Unknown artist'} · ${it.title}`)),el('span',{},t.duration?mt(t.duration):'▶')))));
  } else if(watchFilter==='music' && musicTab==='genres' && !watchGenre){
    nodes.push(el('p',{className:'media-empty'},'Choose a genre above to browse your albums.'));
  } else if(watchGenre || watchQuery || watchSort!=='title' || watchUnfinished || watchFilter==='music' || artistName){
    const list=artistName?results.filter(i=>i.artist===artistName):results;
    nodes.push(el('section',{className:'media-collection'},artistName?el('button',{className:'media-back',onclick:()=>{artistName='';renderWatch();}},'‹ Artists'):null,
      el('h2',{},artistName||watchGenre||(watchQuery?'Search results':watchFilter==='music'?'Albums':'Your collection')),el('p',{},count(list.length,'item')),el('div',{className:'media-grid'},list.map(card))));
  } else {
    const f=byId(catalog.featured);
    if(f){
      const fr=fraction(f),resuming=fr!=null;
      const hero=el('section',{className:'hero'},artwork(f,'hero-art'),el('div',{className:'in'},el('div',{className:'eyebrow'},resuming?'PICK UP WHERE YOU LEFT OFF':'READY WHEN YOU ARE'),el('h2',{},f.title),el('p',{className:'meta2'},f.meta||''),fr!=null?el('div',{className:'bar2'},el('i',{style:`width:${fr*100}%`})) : null,
        el('button',{className:'btn play',onclick:()=>openPlayer(f,false)},resuming?'▶ Resume':'▶ Play'),resuming?el('button',{className:'btn ghost',onclick:()=>openPlayer(f,true)},'↺ Start Over'):null,el('button',{className:'btn ghost',onclick:()=>openDetail(f)},f.tracks.length>1?'Chapters & details':'Details')));
      nodes.push(hero);
    }
    for(const shelf of catalog.shelves){
      const strip=el('div',{className:'strip'},shelf.items.map(byId).filter(Boolean).map(card));
      nodes.push(el('section',{className:'row'},el('div',{className:'row-heading'},el('h2',{},shelf.title),el('small',{},count(shelf.items.length,'item')),el('button',{'aria-label':`Scroll ${shelf.title} left`,onclick:()=>strip.scrollBy({left:-560,behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'})},'‹'),el('button',{'aria-label':`Scroll ${shelf.title} right`,onclick:()=>strip.scrollBy({left:560,behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'})},'›')),strip));
    }
  }
  if(!results.length) nodes.push(el('div',{className:'media-empty'},el('h2',{},catalog.items.length?'No matches in this collection':'Your next favorite belongs here.'),el('p',{},catalog.items.length?'Try another genre or clear your search.':'On your Mac, open Watch, Audiobooks or Music and use Add, or drag files onto the window. Free LibriVox audiobooks can be added there too.')));
  $('#watch').replaceChildren(...nodes);
}
function card(it){
  const fr=fraction(it),art=artwork(it,'thumb '+(it.category==='audiobooks'?'book-cover':it.category==='music'?'album-cover':''));
  if(fr!=null) art.append(el('div',{className:'pbar'},el('i',{style:`width:${fr*100}%`})));
  if(it.progress?.finished) art.append(el('span',{className:'done'},'✓ Finished'));
  if(it.kind==='video'&&it.duration) art.append(el('span',{className:'length'},mt(it.duration)));
  return el('button',{className:'wcard '+(it.category==='audiobooks'?'book-card':it.category==='music'?'album-card':''),onclick:()=>openDetail(it),'aria-label':`${it.title}, ${it.meta||''}${fr!=null?', '+Math.round(fr*100)+' percent completed':''}. Open details.`},art,el('b',{},it.title),it.kind==='audio'?el('small',{},it.artist||'Unknown artist'):null,el('small',{},it.meta||''));
}
let mediaDialog;
function openDetail(it){
  if(mediaDialog){mediaDialog.close();mediaDialog.remove();}
  mediaDialog=el('dialog',{className:'media-detail','aria-label':it.title});
  const launch=(start,index)=>{mediaDialog.close();openPlayer(it,start,index);};
  const info=el('div',{className:'detail-info'},el('small',{},it.category==='music'?'ALBUM':it.category==='audiobooks'?'AUDIOBOOK':'VIDEO'),el('h2',{},it.title),it.kind==='audio'?el('p',{},it.artist||'Unknown artist'):null,el('p',{},it.meta||''),fraction(it)!=null?el('p',{},`${Math.round(fraction(it)*100)}% completed`):null,
    el('button',{className:'btn play',onclick:()=>launch(false)},fraction(it)!=null?'▶ Resume':'▶ Play'),el('button',{className:'btn ghost',onclick:()=>launch(true)},'↺ Start Over'),it.category==='music'?el('button',{className:'btn ghost',onclick:()=>launch(false,-1)},'Shuffle'):null);
  const list=it.kind==='audio'?el('section',{},el('h3',{},it.category==='music'?'Songs':'Chapters'),it.tracks.map((t,i)=>el('button',{className:'track-row',onclick:()=>launch(false,i)},el('span',{},`${i+1}`),el('span',{},el('b',{},t.title),it.progress?.track===i&&!it.progress.finished?el('small',{},'Your place'):null),el('span',{},t.duration?mt(t.duration):''),it.category==='audiobooks'&&(it.progress?.finished||i<(it.progress?.track||0))?el('span',{},'✓'):null))):null;
  const related=(it.related||[]).map(byId).filter(Boolean).slice(0,6);
  mediaDialog.append(el('div',{},el('button',{className:'detail-close',onclick:()=>mediaDialog.close()},'Close'),el('div',{className:'detail-header'},artwork(it,it.category==='audiobooks'?'book-cover':''),info),list,related.length?el('section',{className:'row'},el('h3',{},'More like this'),el('div',{className:'strip'},related.map(card))):null));
  document.body.append(mediaDialog);mediaDialog.showModal();
}

let playing=null,saveTimer=null,sleepTimer=null,progressWrite=Promise.resolve();
function saveProgress(finished){
  if(!playing)return Promise.resolve();
  const p=playing;
  const value={id:p.item.id,track:p.track,seconds:finished?0:p.el.currentTime||0,finished:!!finished};
  p.item.progress={...value,updated:Date.now()/1000};
  progressWrite=progressWrite.catch(()=>{}).then(()=>api('/api/media/progress',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(value)})).catch(()=>{});
  return progressWrite;
}
async function closePlayer(){
  if(playing){const p=playing;await saveProgress(p.completed);p.el.onpause=null;p.el.onended=null;p.el.pause();}
  clearInterval(saveTimer);clearTimeout(sleepTimer);playing=null;
  $('#player').className='hidden';$('#player').replaceChildren();
  if(!$('#watch').classList.contains('hidden'))loadWatch();
}
async function openPlayer(it,fromStart,chosen){
  if(playing?.item.id===it.id&&!fromStart&&chosen==null){$('#player').classList.remove('mini');return;}
  if(playing)await closePlayer();
  const p=it.progress||{},isVideo=it.kind==='video',music=it.category==='music';
  const order=it.tracks.map((_,i)=>i);
  if(chosen===-1)for(let i=order.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[order[i],order[j]]=[order[j],order[i]];}
  const startTrack=chosen===-1?order[0]:chosen!=null?chosen:fromStart||p.finished?0:Math.min(p.track||0,it.tracks.length-1);
  const startAt=chosen!=null||fromStart||p.finished?0:p.seconds||0;
  const m=el(isVideo?'video':'audio',{controls:isVideo,playsInline:true,preload:'auto'});
  playing={item:it,track:startTrack,el:m,completed:false,sleepAtEnd:false};
  const title=el('h2',{},it.title),chapter=el('p',{}),seek=el('input',{type:'range',min:0,max:1,step:0.001,value:0,'aria-label':'Playback position'}),time=el('div',{className:'media-times'}),progress=el('div',{className:'player-progress'},el('i'));
  const toggle=el('button',{className:'round-play','aria-label':'Play',onclick:()=>m.paused?m.play().catch(()=>{}):m.pause()},'▶');
  function load(index,at=0,autoplay=true){
    if(!playing||!it.tracks[index])return;
    playing.track=index;playing.completed=false;
    m.onloadedmetadata=()=>{m.currentTime=at;};
    m.src=mediaURL(it.tracks[index].url);chapter.textContent=it.tracks[index].title;
    if(autoplay)m.play().catch(()=>{toggle.textContent='▶';toggle.setAttribute('aria-label','Play');});
    chapters.replaceChildren(...it.tracks.map((t,i)=>el('button',{className:'track-row '+(i===index?'on':''),onclick:()=>load(i)},el('span',{},String(i+1)),el('span',{},t.title),el('span',{},t.duration?mt(t.duration):''))));
  }
  function next(){const position=order.indexOf(playing.track);if(position+1<order.length)load(order[position+1]);}
  const chapters=el('div',{className:'chapters'});
  const skip=(n)=>{if(Number.isFinite(m.duration))m.currentTime=Math.max(0,Math.min(m.duration,m.currentTime+n));};
  seek.oninput=()=>{if(Number.isFinite(m.duration))m.currentTime=Number(seek.value)*m.duration;};
  const prevChapter=()=>{const pos=order.indexOf(playing.track);if(m.currentTime>5||pos<=0)m.currentTime=0;else load(order[pos-1]);};
  const chaptered=!music&&it.tracks.length>1;
  const controls=el('div',{className:'audio-controls'},chaptered?el('button',{'aria-label':'Previous chapter',onclick:prevChapter},'⏮'):null,el('button',{'aria-label':music?'Previous song':'Back 15 seconds',onclick:()=>{if(music&&m.currentTime<5){const pos=order.indexOf(playing.track);if(pos>0)load(order[pos-1]);}else skip(music?-m.currentTime:-15);}},music?'⏮':'↶ 15'),toggle,el('button',{'aria-label':music?'Next song':'Forward 30 seconds',onclick:()=>music?next():skip(30)},music?'⏭':'30 ↷'),chaptered?el('button',{'aria-label':'Next chapter',onclick:next},'⏭'):null);
  const speed=selectControl('Speed','1',[['0.75','0.75×'],['1','1×'],['1.25','1.25×'],['1.5','1.5×'],['1.75','1.75×'],['2','2×']],v=>m.playbackRate=Number(v));
  const sleep=selectControl('Sleep','off',[['off','Off'],['15','15 minutes'],['30','30 minutes'],['60','60 minutes'],['chapter','End of chapter']],v=>{clearTimeout(sleepTimer);playing.sleepAtEnd=v==='chapter';if(v!=='off'&&v!=='chapter')sleepTimer=setTimeout(()=>{m.pause();sleep.querySelector('select').value='off';},Number(v)*60000);});
  const mini=el('button',{onclick:()=>{$('#player').classList.toggle('mini');mini.textContent=$('#player').classList.contains('mini')?'Expand':'Minimize';}},'Minimize');
  const top=el('div',{className:'top'},el('b',{},it.title),mini,el('button',{onclick:closePlayer,'aria-label':'Close player and save your place'},'Close'));
  const body=isVideo?m:el('div',{className:'audiobox'},artwork(it,'player-cover '+(music?'album-cover':'book-cover')),title,el('p',{},it.artist||'Unknown artist'),chapter,seek,time,controls,!music?el('div',{className:'listening-tools'},speed,sleep):null,chapters);
  let cancelNext=false;
  const nextItem=byId(it.upNext),nextLabel=el('span',{}),upNext=nextItem?el('div',{className:'up-next hidden'},nextLabel,el('b',{},nextItem.title),el('button',{onclick:()=>openPlayer(nextItem,false)},'Play now'),el('button',{onclick:()=>{cancelNext=true;upNext.classList.add('hidden');}},'Cancel')):null;
  $('#player').replaceChildren(top,body,progress);if(upNext)$('#player').append(upNext);$('#player').className='';
  m.onplay=()=>{toggle.textContent='Ⅱ';toggle.setAttribute('aria-label','Pause');};
  m.onpause=()=>{toggle.textContent='▶';toggle.setAttribute('aria-label','Play');if(!playing?.completed)saveProgress(false);};
  m.ontimeupdate=()=>{const f=Number.isFinite(m.duration)&&m.duration>0?m.currentTime/m.duration:0;seek.value=f;time.replaceChildren(el('span',{},mt(m.currentTime)),el('span',{},'−'+mt(m.duration-m.currentTime)));progress.firstChild.style.width=`${f*100}%`;if(upNext&&!cancelNext&&m.duration-m.currentTime<=20){upNext.classList.remove('hidden');nextLabel.textContent=`Up next in ${Math.max(0,Math.ceil(m.duration-m.currentTime))}s`;}};
  m.onended=async()=>{const pos=order.indexOf(playing.track);if(pos+1<order.length){const stop=playing.sleepAtEnd;load(order[pos+1],0,!stop);if(stop){playing.sleepAtEnd=false;m.pause();sleep.querySelector('select').value='off';}}else{playing.completed=true;await closePlayer();if(nextItem&&!cancelNext)openPlayer(nextItem,false);}};
  load(startTrack,startAt);saveTimer=setInterval(()=>{if(playing&&!m.paused)saveProgress(false);},5000);
}

init();

"""#
}

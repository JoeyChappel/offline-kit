import Foundation

/// The browser version of Offline Kit served by Share on Wi-Fi: Ask and Library in one self-contained page.
/// The script builds every element with DOM methods (no HTML parsing of server or answer text).
enum WebApp {
    /// Inserted at the top of every archive page so people can get back.
    /// The bar at the top of shared articles. Articles live on their own port, so "Offline Kit" links back by full address.
    static func articleBar(home: String) -> String {
        articleBarTemplate.replacingOccurrences(of: "HOME_URL", with: home)
    }
    private static let articleBarTemplate = #"<div style="position:sticky;top:0;z-index:2147483647;background:#2E7F60;padding:10px 14px;font:600 15px -apple-system,system-ui,sans-serif"><a href="HOME_URL" style="color:#fff;text-decoration:none">&#8592; Offline Kit</a><a href="javascript:history.back()" style="color:#fff;opacity:.85;text-decoration:none;float:right;font-weight:500">Back</a></div>"#

    static var html: String { page.replacingOccurrences(of: "/*SCRIPT*/", with: script) }

    private static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#2E7F60">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>Offline Kit</title>
<style>
:root{--accent:#2E7F60;--accent-soft:rgba(46,127,96,.12);--bg:#f6f7f6;--card:#fff;--text:#1c1f1d;--muted:#5f6a64;--line:rgba(0,0,0,.09);--warn:#b35c00}
@media (prefers-color-scheme:dark){:root{--accent:#5FC398;--accent-soft:rgba(95,195,152,.14);--bg:#111413;--card:#1b1f1d;--text:#eef2ef;--muted:#9aa6a0;--line:rgba(255,255,255,.1);--warn:#f0a050}}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font:17px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,system-ui,sans-serif;-webkit-text-size-adjust:100%}
a{color:var(--accent)}
header{position:sticky;top:0;z-index:10;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-bottom:1px solid var(--line);padding:max(10px,env(safe-area-inset-top)) 16px 10px}
.bar{max-width:760px;margin:0 auto;display:flex;align-items:center;gap:10px}
.logo{width:30px;height:30px;border-radius:8px;background:var(--accent);display:grid;place-items:center;flex:none}
.brand{font-weight:700;font-size:17px;margin-right:auto}
.tabs{display:flex;background:var(--line);border-radius:10px;padding:3px}
.tabs button{border:0;background:none;color:var(--text);font-family:inherit;font-weight:600;font-size:14px;padding:6px 14px;border-radius:8px;cursor:pointer}
.tabs button.on{background:var(--card);box-shadow:0 1px 3px rgba(0,0,0,.12)}
main{max-width:760px;margin:0 auto;padding:20px 16px 150px}
h1{font-size:30px;line-height:1.15;margin:8px 0 8px;letter-spacing:-.01em}
.sub{color:var(--muted);margin:0 0 14px}
.pills{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 22px}
.pill{font-size:13px;font-weight:600;color:var(--muted);background:var(--line);padding:4px 10px;border-radius:99px}
.pill.ok{color:var(--accent);background:var(--accent-soft)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px}
button.card{text-align:left;font:inherit;color:inherit;cursor:pointer;width:100%}
button.card:active{border-color:var(--accent)}
.topic{font-size:11px;font-weight:700;letter-spacing:.04em;color:var(--muted);text-transform:uppercase}
.q{font-size:22px;font-weight:650;margin:30px 0 10px;line-height:1.25}
.answer p{margin:0 0 .7em}.answer ul,.answer ol{margin:0 0 .7em;padding-left:1.3em}
.answer a.cite{font-weight:700;text-decoration:none;font-size:.85em;vertical-align:1px}
.status{color:var(--muted);display:flex;align-items:center;gap:8px}
.spin{width:14px;height:14px;border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:s .8s linear infinite}
@keyframes s{to{transform:rotate(360deg)}}
.meta{display:flex;gap:8px;align-items:center;margin-top:10px;flex-wrap:wrap}
.sources{margin-top:12px;display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:8px}
.src{display:flex;gap:10px;align-items:flex-start;text-decoration:none;color:inherit;padding:10px 12px}
.num{flex:none;width:22px;height:22px;border-radius:50%;background:var(--accent);color:#fff;font-size:12px;font-weight:700;display:grid;place-items:center}
.src b{display:block;font-weight:600;font-size:15px;line-height:1.3}.src small{color:var(--muted)}
.err{color:var(--warn)}
.composer{position:fixed;left:0;right:0;bottom:0;background:color-mix(in srgb,var(--bg) 92%,transparent);backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px);border-top:1px solid var(--line);padding:10px 16px max(12px,env(safe-area-inset-bottom))}
.composer form{max-width:760px;margin:0 auto;display:flex;gap:8px;align-items:flex-end;background:var(--card);border:1px solid var(--line);border-radius:22px;padding:6px 6px 6px 16px}
.composer textarea{flex:1;border:0;background:none;color:var(--text);font:inherit;resize:none;max-height:140px;padding:6px 0;outline:none}
.send{flex:none;width:34px;height:34px;border-radius:50%;border:0;background:var(--accent);color:#fff;font-size:18px;font-weight:700;cursor:pointer}
.send:disabled{opacity:.35}
.note{max-width:760px;margin:6px auto 0;text-align:center;font-size:11px;color:var(--muted)}
.search{width:100%;font:inherit;color:var(--text);background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:6px 0 16px;outline:none}
.search:focus{border-color:var(--accent)}
.group{margin:22px 0 8px;font-size:13px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
.book{display:flex;justify-content:space-between;gap:12px;align-items:center;text-decoration:none;color:inherit;margin-bottom:8px}
.book small,.hit small{color:var(--muted)}
.hit{display:block;text-decoration:none;color:inherit;margin-bottom:8px}
.hidden{display:none !important}
.pin{max-width:340px;margin:12vh auto;text-align:center}
.watchmain{max-width:none;padding:0 0 150px}
.hero{position:relative;min-height:56vh;display:flex;align-items:flex-end;background:#000 center/cover no-repeat;color:#fff}
.hero::after{content:"";position:absolute;inset:0;background:linear-gradient(180deg,transparent 20%,rgba(0,0,0,.35) 55%,rgba(0,0,0,.9))}
.hero .in{position:relative;z-index:1;padding:28px 24px;max-width:760px}
.hero .eyebrow{font-size:12px;font-weight:700;letter-spacing:.12em;opacity:.8}
.hero h1{font-size:40px;margin:6px 0}
.hero .meta2{opacity:.85;margin:0 0 12px}
.hero .bar2{height:4px;width:240px;background:rgba(255,255,255,.3);border-radius:2px;margin:0 0 14px}
.hero .bar2 i{display:block;height:100%;background:#fff;border-radius:2px}
.btn{font:inherit;font-weight:700;border:0;border-radius:99px;padding:10px 20px;cursor:pointer;margin-right:8px}
.btn.play{background:#fff;color:#000}.btn.ghost{background:rgba(255,255,255,.22);color:#fff}
.row{margin:26px 0 0}
.row h2{font-size:20px;margin:0 0 10px;padding:0 24px}
.strip{display:flex;gap:14px;overflow-x:auto;padding:4px 24px 10px;scroll-snap-type:x proximity;-webkit-overflow-scrolling:touch}
.wcard{flex:none;width:260px;scroll-snap-align:start;background:none;border:0;padding:0;text-align:left;color:inherit;font:inherit;cursor:pointer}
.thumb{position:relative;width:260px;height:146px;border-radius:10px;overflow:hidden;background:linear-gradient(135deg,#4b3cc4,#8a3fb8)}
.thumb.audio{background:linear-gradient(135deg,#e07a2f,#d6457a)}
.thumb img{width:100%;height:100%;object-fit:cover;display:block}
.thumb .pbar{position:absolute;left:0;right:0;bottom:0;height:4px;background:rgba(255,255,255,.3)}
.thumb .pbar i{display:block;height:100%;background:#e50914}
.thumb .done{position:absolute;top:8px;right:8px;background:var(--accent);color:#fff;border-radius:50%;width:22px;height:22px;display:grid;place-items:center;font-size:13px}
.wcard b{display:block;margin-top:6px;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.wcard small{color:var(--muted)}
.wcard:hover .thumb,.wcard:focus .thumb{outline:2px solid var(--accent);outline-offset:2px}
#player{position:fixed;inset:0;z-index:50;background:#000;color:#fff;display:flex;flex-direction:column}
#player .top{display:flex;align-items:center;gap:10px;padding:max(10px,env(safe-area-inset-top)) 14px 10px}
#player .top b{margin-right:auto;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#player .top button{background:rgba(255,255,255,.18);color:#fff;border:0;border-radius:99px;padding:6px 12px;font:inherit;font-weight:600;cursor:pointer}
#player video{flex:1;min-height:0;width:100%;background:#000}
#player .audiobox{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;padding:20px}
#player .audiobox img{width:min(60vw,320px);border-radius:14px}
#player audio{width:min(90vw,520px)}
#player .chapters{max-height:30vh;overflow:auto;width:min(90vw,520px)}
#player .chapters button{display:block;width:100%;text-align:left;background:none;border:0;color:#fff;font:inherit;padding:6px 4px;opacity:.75;cursor:pointer}
#player .chapters button.on{opacity:1;font-weight:700}
#player.mini{inset:auto 12px max(12px,env(safe-area-inset-bottom)) auto;width:min(360px,calc(100vw - 24px));height:auto;border-radius:14px;overflow:hidden;box-shadow:0 10px 30px rgba(0,0,0,.45)}
#player.mini video{flex:none;height:200px}
#player.mini .audiobox{padding:10px;gap:8px}#player.mini .audiobox img,#player.mini .chapters{display:none}
.pin input{font-family:inherit;font-weight:600;font-size:28px;letter-spacing:.4em;text-align:center;width:100%;padding:12px;border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--text)}
/* Watch & Listen only: evergreen media room. Shared Ask and Library styles stay unchanged. */
#watch,.media-detail,#player{--media-bg:#0c1b16;--media-surface:#172d24;--media-ink:#f5f5e8;--media-muted:#b8c8b8;--media-accent:#b3d68c;color:var(--media-ink);background:var(--media-bg);color-scheme:dark}
#watch{min-height:calc(100vh - 70px);padding-bottom:180px}#watch h1,#watch h2,#watch h3,.media-detail h2{color:var(--media-ink)}
#watch button,.media-detail button,#player button{font:inherit;cursor:pointer}#watch button:focus-visible,.media-detail button:focus-visible,#player button:focus-visible{outline:3px solid var(--media-accent);outline-offset:4px}
.media-heading{padding:28px 24px 12px}.media-heading h1{margin:0 0 8px;font-size:clamp(28px,3vw,40px)}.media-heading p{color:var(--media-muted);margin:0 0 20px}.media-heading p.media-note{font-size:13px;margin:-12px 0 16px}
.media-heading input{width:100%;max-width:600px;padding:12px 16px;background:var(--media-surface);color:var(--media-ink);border:1px solid #52665a;border-radius:12px;font:inherit}
.media-chips,.media-music-tabs{display:flex;gap:10px;overflow-x:auto;padding:18px 0 8px}.media-chips button,.media-music-tabs button,.media-back{flex-shrink:0;min-height:44px;padding:8px 20px;border:1px solid #52665a;border-radius:24px;color:var(--media-ink);background:var(--media-surface)}
.media-chips .on,.media-music-tabs .on{background:var(--media-accent);color:var(--media-bg);border-color:var(--media-accent);font-weight:700}.media-music-tabs{padding:8px 24px}.media-music-tabs button{border-radius:8px}
.media-tools{display:flex;gap:16px;align-items:center;flex-wrap:wrap;padding:12px 24px 20px}.media-select{display:flex;gap:8px;align-items:center;font-size:14px;color:var(--media-muted)}.media-select select{font:inherit;max-width:200px;padding:10px;border:1px solid #52665a;border-radius:10px;background:var(--media-surface);color:var(--media-ink);min-height:44px}.media-toggle{font-size:14px}
#watch .hero{margin:12px 24px 30px;border-radius:18px;overflow:hidden;min-height:330px}#watch .hero h2{font-size:clamp(28px,3vw,44px);line-height:1.15;margin:10px 0}#watch .hero .in{padding:80px 28px 28px;max-width:800px}#watch .hero::after{background:linear-gradient(90deg,rgba(0,0,0,.8),rgba(0,0,0,.15)),linear-gradient(0deg,rgba(0,0,0,.8),transparent)}
.media-art{position:relative;overflow:hidden;display:grid;align-items:end;isolation:isolate}.media-art img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}.poster-title{padding:16px;font:600 22px/1.25 Georgia,serif;color:#fff;text-shadow:0 2px 4px #000}.hero-art{position:absolute;inset:0}.hero-art .poster-title{display:none}
#watch .btn,.media-detail .btn{margin-top:8px;min-height:44px}#watch .btn.play,.media-detail .btn.play{background:var(--media-accent);color:var(--media-bg)}.media-genres h2{font-size:20px;padding:0 24px}.genre-tile{position:relative;isolation:isolate;flex:0 0 156px;min-height:112px;padding:16px;overflow:hidden;border:1px solid #52665a;border-radius:12px;text-align:left;color:#fff;background:#203b2e}.genre-tile>.media-art{position:absolute;inset:0;z-index:-2}.genre-tile::before{content:"";position:absolute;inset:0;background:linear-gradient(0deg,rgba(0,0,0,.95),rgba(0,0,0,.15));z-index:-1}.genre-tile strong{display:block;margin-top:30px}.genre-tile small{display:block}.genre-tile.on{outline:3px solid var(--media-accent);outline-offset:-3px}
.row-heading{display:flex;align-items:center;gap:12px;padding:0 24px 12px}.row-heading h2{padding:0;margin:0 auto 0 0}.row-heading small{color:var(--media-muted)}.row-heading button{border:1px solid #52665a;border-radius:50%;width:40px;height:40px;background:var(--media-surface);color:var(--media-ink);font-size:24px}
#watch .strip{gap:18px;padding-top:8px;padding-bottom:16px;scroll-padding:24px}.wcard{width:272px}.wcard.book-card{width:152px}.wcard.album-card{width:180px}.wcard .thumb{width:100%;height:auto;aspect-ratio:16/9;border:1px solid rgba(255,255,255,.12);background:none}.wcard .book-cover{aspect-ratio:2/3}.wcard .album-cover{aspect-ratio:1}.wcard small{display:block;color:var(--media-muted);font-size:12px;line-height:1.45}.wcard b{white-space:normal;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}.wcard .pbar i{background:var(--media-accent)}.wcard .done{width:auto;height:auto;padding:3px 7px;background:#10241c;color:var(--media-ink);font-size:11px}.length{position:absolute;top:8px;right:8px;padding:3px 7px;border-radius:20px;background:#000d;color:#fff;font-size:11px}.wcard:hover .thumb{transform:translateY(-3px);box-shadow:0 8px 14px #0005}.wcard .thumb{transition:transform .15s}
.media-collection{padding:16px 24px}.media-collection>p{color:var(--media-muted)}.media-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(240px,100%),1fr));gap:24px 18px}.media-grid .wcard{width:100%}.media-grid:has(.album-card){grid-template-columns:repeat(auto-fill,minmax(150px,1fr))}.media-grid:has(.book-card){grid-template-columns:repeat(auto-fill,minmax(140px,1fr))}.artist-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:20px}.artist-card{background:var(--media-surface);border:0;border-radius:14px;padding:18px;color:var(--media-ink);text-align:left}.artist-card .media-art{aspect-ratio:1;border-radius:50%;margin-bottom:14px}.artist-card small{display:block;color:var(--media-muted)}.media-empty{padding:36px 24px;color:var(--media-muted)}
.media-detail{border:1px solid #52665a;border-radius:20px;width:min(900px,calc(100vw - 24px));max-height:90dvh;padding:24px}.media-detail::backdrop{background:#000b}.detail-close{display:block;margin-left:auto;padding:10px 18px;border:1px solid #52665a;border-radius:20px;background:var(--media-surface);color:var(--media-ink)}.detail-header{display:grid;grid-template-columns:minmax(140px,260px) 1fr;gap:24px;margin:20px 0 28px}.detail-header>.media-art{aspect-ratio:1;border-radius:14px}.detail-header>.book-cover{aspect-ratio:2/3}.detail-info h2{font-size:30px;line-height:1.2}.detail-info p,.detail-info>small{color:var(--media-muted)}.track-row{display:flex;align-items:center;gap:14px;width:100%;padding:14px 4px;min-height:52px;text-align:left;border:0;border-bottom:1px solid #405446;background:none;color:var(--media-ink);font:inherit}.track-row>span:nth-child(2){flex:1}.track-row small{display:block;color:var(--media-muted);font-size:12px}.track-row>.media-art{width:48px;height:48px;border-radius:6px;flex:none}.track-row.on{background:var(--media-surface);color:var(--media-accent)}
#player{overflow:auto}#player .top{position:sticky;top:0;z-index:2;background:var(--media-bg)}#player .audiobox{justify-content:flex-start;flex:none;width:min(680px,100%);margin:auto}.player-cover{width:min(65vw,260px);aspect-ratio:1;border-radius:14px;flex-shrink:0}.player-cover.book-cover{width:min(50vw,210px);aspect-ratio:2/3}#player .audiobox h2,#player .audiobox p{margin:0;text-align:center}#player .audiobox>p{color:var(--media-muted)}#player .audiobox input[type=range]{width:100%;accent-color:var(--media-accent)}.media-times{width:100%;display:flex;justify-content:space-between;color:var(--media-muted);font-size:13px;font-variant-numeric:tabular-nums}.audio-controls{display:flex;align-items:center;gap:28px}.audio-controls button{border:0;border-radius:50%;background:none;color:var(--media-accent);min-width:48px;min-height:48px}.audio-controls .round-play{width:64px;height:64px;background:var(--media-accent);color:var(--media-bg);font-size:28px}.listening-tools{display:flex;flex-wrap:wrap;justify-content:center;gap:16px}#player .chapters{max-height:none;width:100%;padding-top:20px}#player .chapters button{opacity:1}.player-progress{height:3px;background:#52665a;flex:none}.player-progress i{display:block;height:100%;background:var(--media-accent);width:0}
#player.mini{width:min(520px,calc(100vw - 24px));max-height:220px;background:var(--media-bg);border:1px solid #52665a}#player.mini .top{padding:10px;font-size:13px}#player.mini video{height:120px}#player.mini .audiobox{display:grid;grid-template-columns:50px 1fr auto;gap:10px;padding:10px}#player.mini .player-cover{display:block;width:50px;height:50px;aspect-ratio:1;grid-row:1 / 3}#player.mini .audiobox>h2{font-size:14px;text-align:left}#player.mini .audiobox>p{display:none}#player.mini .audiobox>input,#player.mini .media-times,#player.mini .chapters,#player.mini .listening-tools{display:none}#player.mini .audio-controls{grid-column:3;grid-row:1 / 3;gap:4px}#player.mini .audio-controls button{min-width:32px;font-size:14px}#player.mini .audio-controls .round-play{width:40px;height:40px}
@media(max-width:600px){.media-heading{padding:22px 16px 8px}.media-heading p{font-size:14px}.media-tools{padding:8px 16px;gap:10px}.media-select{font-size:12px;flex-direction:column;align-items:start;gap:4px}#watch .hero{margin:16px;min-height:300px}#watch .hero .in{padding:70px 18px 20px}.row-heading{padding-left:16px;padding-right:16px}.row-heading button{display:none}.row-heading h2{font-size:20px}#watch .strip{padding-left:16px;padding-right:16px}.media-collection{padding:16px}.media-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:20px 12px}.media-grid:has(.album-card),.media-grid:has(.book-card){grid-template-columns:repeat(2,minmax(0,1fr))}.detail-header{grid-template-columns:1fr}.detail-header>.media-art{max-width:220px;width:100%;margin:auto}.detail-info h2{font-size:26px}.media-detail{padding:18px}.wcard{width:250px}.media-heading input{font-size:16px}#player.mini{bottom:max(12px,env(safe-area-inset-bottom))}}
@media(prefers-reduced-motion:reduce){#watch *,#player *,.media-detail *{transition:none!important;scroll-behavior:auto!important;animation:none!important}}
@media(prefers-reduced-transparency:reduce){.media-detail::backdrop{background:#000}.genre-tile::before{background:linear-gradient(0deg,#000 10%,transparent)}#watch .hero::after{background:linear-gradient(0deg,#000 30%,#0008)}}

.up-next{position:absolute;bottom:100px;right:24px;max-width:300px;background:#172d24;color:#f5f5e8;padding:18px;border-radius:14px;display:flex;flex-wrap:wrap;gap:12px}.up-next span,.up-next b{width:100%}#player.mini .up-next{display:none}
/* A bundled forest backdrop, confined to the media screens. */
#watch,.media-detail{background-image:linear-gradient(rgba(12,27,22,.28),rgba(12,27,22,.28)),url('/assets/watch-forest.jpg');background-position:left bottom;background-size:cover;background-attachment:fixed}
@media(prefers-reduced-transparency:reduce){#watch,.media-detail{background-image:linear-gradient(rgba(12,27,22,.48),rgba(12,27,22,.48)),url('/assets/watch-forest.jpg')}}
</style>
</head>
<body>
<header><div class="bar">
  <div class="logo"><svg width="18" height="18" viewBox="0 0 24 24" fill="#fff"><path d="M6 3h9a3 3 0 0 1 3 3v13a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zm2 4v2h8V7H8zm0 4v2h8v-2H8zm0 4v2h5v-2H8z"/></svg></div>
  <div class="brand">Offline Kit</div>
  <div class="tabs" id="tabs"><button class="on" data-tab="ask">Ask</button><button data-tab="library">Library</button><button data-tab="watch">Watch</button></div>
</div></header>

<main id="pin" class="hidden"><div class="pin">
  <h1>Enter PIN</h1><p class="sub">The person who set up Offline Kit can tell you the PIN.</p>
  <form id="pinform"><input id="pininput" inputmode="numeric" maxlength="8" autocomplete="off"></form>
  <p id="pinerr" class="err"></p>
</div></main>

<main id="ask">
  <section id="welcome">
    <h1>Ask your offline library</h1>
    <p class="sub">Answers come from the archives saved on <span id="macname">the Mac</span>, with numbered sources you can open. No internet needed.</p>
    <div class="pills" id="pills"></div>
    <div class="grid" id="suggestions"></div>
  </section>
  <section id="turns"></section>
</main>

<main id="library" class="hidden">
  <h1>Library</h1>
  <input class="search" id="q" type="search" placeholder="Search article titles in every archive" autocomplete="off">
  <div id="results"></div>
  <div id="books"></div>
</main>

<main id="watch" class="watchmain hidden"></main>
<div id="player" class="hidden"></div>

<div class="composer" id="composer">
  <form id="askform"><textarea id="input" rows="1" placeholder="Ask a question"></textarea><button class="send" id="send" disabled aria-label="Ask">&#8593;</button></form>
  <div class="note">Answers come from your offline library where it covers the question, and anything else is labeled “Not from the library.” They can still be wrong. Check the sources for anything safety-critical.</div>
</div>
<script>
/*SCRIPT*/
</script>
</body>
</html>
"""#
}

import Foundation

/// The browser version of Offline Kit served by Share on Wi-Fi: one self-contained page that feels like a phone app
/// (Home, Watch, Listen, Read, Play and Ask tabs, pages that push and pop, a reader for EPUB books).
/// The script builds every element with DOM methods (no HTML parsing of server or answer text).
enum WebApp {
    /// Inserted at the top of every archive page so people can get back.
    /// The bar at the top of shared articles. Articles live on their own port, so "Offline Kit" links back by full address.
    static func articleBar(home: String) -> String {
        articleBarTemplate.replacingOccurrences(of: "HOME_URL", with: home)
    }
    private static let articleBarTemplate = #"<div style="position:sticky;top:0;z-index:2147483647;background:#2E7F60;padding:10px 14px;font:600 15px -apple-system,system-ui,sans-serif"><a href="HOME_URL" style="color:#fff;text-decoration:none">&#8592; Offline Kit</a><a href="javascript:history.back()" style="color:#fff;opacity:.85;text-decoration:none;float:right;font-weight:500">Back</a></div>"#

    static var html: String { page.replacingOccurrences(of: "/*SCRIPT*/", with: script) }

    /// The web app manifest: the name, icons and colors a phone uses when the page is added to its Home Screen.
    static let manifest = #"""
{
  "name": "Offline Kit",
  "short_name": "Offline Kit",
  "id": "/",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#0c1b16",
  "theme_color": "#2E7F60",
  "description": "Your offline library from the Mac: watch, listen, read, play and ask.",
  "icons": [
    {
      "src": "/assets/icon-192.png",
      "sizes": "192x192",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "/assets/icon-512.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "/apple-touch-icon.png",
      "sizes": "180x180",
      "type": "image/png",
      "purpose": "any"
    }
  ]
}
"""#

    private static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#f4f6f4" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0c1512" media="(prefers-color-scheme: dark)">
<meta name="color-scheme" content="light dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Offline Kit">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="application-name" content="Offline Kit">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
<link rel="icon" type="image/png" sizes="192x192" href="/assets/icon-192.png">
<title>Offline Kit</title>
<style>
:root{--accent:#2E7F60;--accent-ink:#fff;--accent-soft:rgba(46,127,96,.13);--bg:#f4f6f4;--surface:#fff;--surface2:#e8eee9;--text:#16201b;--muted:#5b6a62;--line:rgba(20,45,32,.11);--bar:rgba(247,249,247,.78);--warn:#b35c00;--shadow:0 8px 24px rgba(16,40,28,.14);--tabh:64px;--st:env(safe-area-inset-top);--sb:env(safe-area-inset-bottom);--sl:env(safe-area-inset-left);--sr:env(safe-area-inset-right);color-scheme:light}
@media (prefers-color-scheme:dark){:root{--accent:#5FC398;--accent-ink:#05251a;--accent-soft:rgba(95,195,152,.15);--bg:#0c1512;--surface:#16211c;--surface2:#1e2b25;--text:#edf3ef;--muted:#97a89f;--line:rgba(255,255,255,.09);--bar:rgba(18,28,24,.74);--warn:#f0a050;--shadow:0 10px 28px rgba(0,0,0,.45);color-scheme:dark}}
.room,#player{--accent:#b3d68c;--accent-ink:#0c1b16;--accent-soft:rgba(179,214,140,.16);--bg:#0c1b16;--surface:#172d24;--surface2:#1f3a2e;--text:#f5f5e8;--muted:#b3c4b4;--line:rgba(245,245,232,.12);--bar:rgba(12,27,22,.72);color-scheme:dark}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:17px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,system-ui,sans-serif;-webkit-text-size-adjust:100%;overflow:hidden;overscroll-behavior:none}
button{font:inherit;color:inherit;cursor:pointer}
a{color:var(--accent)}
img{color:transparent}
.hidden{display:none!important}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
svg.i{width:24px;height:24px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round;flex:none}
/* Status bar strip in a Home Screen app (white status text on light pages needs something under it). */
@media (display-mode:standalone) and (prefers-color-scheme:light){body::before{content:"";position:fixed;z-index:90;top:0;left:0;right:0;height:var(--st);background:#1f5d45}}

/* Tabs and pages */
#app{position:fixed;inset:0}
.tab{position:absolute;inset:0;display:none;overflow:hidden}
.tab.on{display:block}
.page{position:absolute;inset:0;background:var(--bg);color:var(--text);overflow:hidden;contain:strict}
.page.under{pointer-events:none}
.page .shade{position:absolute;inset:0;background:#000;opacity:0;pointer-events:none;z-index:20}
.scroll{position:absolute;inset:0;overflow-x:hidden;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior-y:contain;padding:calc(var(--st) + 44px) var(--sr) calc(var(--tabh) + var(--sb) + 40px) var(--sl)}
.nav{position:absolute;z-index:10;top:0;left:0;right:0;height:calc(var(--st) + 44px);padding:var(--st) calc(var(--sr) + 8px) 0 calc(var(--sl) + 8px);display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr);align-items:center;border-bottom:.5px solid transparent;transition:background-color .2s,border-color .2s}
.page.scrolled .nav{background:var(--bar);-webkit-backdrop-filter:saturate(180%) blur(20px);backdrop-filter:saturate(180%) blur(20px);border-bottom-color:var(--line)}
.nav .t{font-weight:650;font-size:17px;opacity:0;transform:translateY(4px);transition:opacity .2s,transform .2s;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:60vw;text-align:center}
.page.scrolled .nav .t,.page.small .nav .t{opacity:1;transform:none}
.nav .l{justify-self:start;display:flex}.nav .r{justify-self:end;display:flex;gap:4px}
.navbtn{min-width:44px;min-height:44px;border:0;background:none;color:var(--accent);display:flex;align-items:center;gap:2px;padding:0 6px;font-size:17px;border-radius:22px}
.navbtn span{max-width:28vw;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.navbtn.round{background:var(--surface2);color:var(--text);width:36px;min-width:36px;height:36px;min-height:36px;justify-content:center;padding:0;margin:4px}
.navbtn.round svg{width:20px;height:20px}
.large{font-size:34px;font-weight:750;letter-spacing:-.01em;line-height:1.15;margin:2px 0 0;padding:4px 20px 6px;transform-origin:left center}
.subtitle{color:var(--muted);margin:0;padding:0 20px 14px;font-size:15px}
.ptr{position:absolute;z-index:9;top:calc(var(--st) + 50px);left:50%;margin-left:-14px;width:28px;height:28px;opacity:0;pointer-events:none}
.ptr i{display:block;width:28px;height:28px;border-radius:50%;border:2.5px solid var(--line);border-top-color:var(--accent)}
.ptr.go{opacity:1!important;transform:translateY(10px)}.ptr.go i{animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}

/* Tab bar: a floating glass pill */
#tabbar{position:fixed;z-index:40;left:calc(var(--sl) + 10px);right:calc(var(--sr) + 10px);bottom:max(10px,var(--sb));margin:0 auto;max-width:600px;height:var(--tabh);display:flex;align-items:stretch;padding:5px;border-radius:32px;background:var(--bar);-webkit-backdrop-filter:saturate(180%) blur(22px);backdrop-filter:saturate(180%) blur(22px);border:.5px solid var(--line);box-shadow:var(--shadow)}
#tabbar button{flex:1;min-width:0;border:0;background:none;border-radius:27px;color:var(--muted);display:flex;flex-direction:column;align-items:center;justify-content:center;gap:1px;font-size:10.5px;font-weight:650;letter-spacing:.01em;transition:color .15s,background-color .15s}
#tabbar button svg{width:25px;height:25px}
#tabbar button.on{color:var(--accent);background:var(--accent-soft)}
#tabbar button.on svg{fill:currentColor;fill-opacity:.18}
#tabbar button:active{transform:scale(.94)}
@media (max-width:359px){#tabbar{left:6px;right:6px;padding:4px}#tabbar button span{display:none}#tabbar button svg{width:24px;height:24px}}
body.signedout #tabbar,body.reading #tabbar,body.signedout #composer,body.reading #composer,body.signedout #app{display:none}
body.mini #composer{bottom:calc(max(10px,var(--sb)) + var(--tabh) + 78px)}

/* Content blocks */
.section{margin:20px 0 4px}
.shead{display:flex;align-items:baseline;justify-content:space-between;gap:12px;padding:0 20px 10px}
.shead h2{font-size:22px;font-weight:720;margin:0;letter-spacing:-.005em;line-height:1.2}
.shead button{border:0;background:none;color:var(--accent);font-size:15px;padding:8px 0;min-height:44px}
.shelf{display:flex;gap:14px;overflow-x:auto;overflow-y:hidden;padding:2px 20px 8px;scroll-snap-type:x mandatory;scroll-padding:0 20px;-webkit-overflow-scrolling:touch;scrollbar-width:none;overscroll-behavior-x:contain}
.shelf::-webkit-scrollbar{display:none}
.card{flex:none;width:248px;scroll-snap-align:start;border:0;background:none;padding:0;text-align:left;color:inherit;display:block;text-decoration:none}
.card.cover{width:136px}.card.square{width:160px}.card.game{width:150px}
.art{position:relative;border-radius:12px;overflow:hidden;aspect-ratio:16/9;background:var(--surface2);box-shadow:0 1px 0 var(--line) inset}
.cover .art{aspect-ratio:2/3;border-radius:8px;box-shadow:var(--shadow)}
.square .art,.game .art{aspect-ratio:1}
.art img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;display:block}
.art .ph{position:absolute;inset:0;display:flex;align-items:flex-end;padding:12px;font:600 17px/1.2 Georgia,"New York",serif;color:#fff;text-shadow:0 1px 3px rgba(0,0,0,.5)}
.cover .art .ph{font-size:15px;align-items:center;text-align:center;justify-content:center}
.art .bar{position:absolute;left:8px;right:8px;bottom:8px;height:4px;border-radius:2px;background:rgba(255,255,255,.35);overflow:hidden}
.art .bar i{display:block;height:100%;background:#fff;border-radius:2px}
.art .tag{position:absolute;top:8px;left:8px;padding:2px 8px;border-radius:10px;background:rgba(0,0,0,.6);color:#fff;font-size:11px;font-weight:650;letter-spacing:.02em;-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px)}
.art .tag.r{left:auto;right:8px}
.card b{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;margin-top:8px;font-size:15px;font-weight:600;line-height:1.3}
.card small{display:block;color:var(--muted);font-size:13px;line-height:1.35;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card:active .art{transform:scale(.97)}.art{transition:transform .15s}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:18px 14px;padding:4px 20px}
.grid.covers{grid-template-columns:repeat(auto-fill,minmax(112px,1fr))}
.grid .card{width:auto}
.genres{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px;padding:0 20px}
.gtile{position:relative;min-height:84px;border:0;border-radius:14px;padding:12px 14px;text-align:left;color:#fff;overflow:hidden;display:flex;flex-direction:column;justify-content:space-between}
.gtile .e{font-size:26px;line-height:1;filter:saturate(.85)}
.gtile b{font-size:15px;font-weight:650;line-height:1.2;text-shadow:0 1px 2px rgba(0,0,0,.25)}
.gtile small{font-size:12px;opacity:.85}
.gtile:active{transform:scale(.97)}
.chips{display:flex;gap:8px;overflow-x:auto;padding:4px 20px 10px;scrollbar-width:none}.chips::-webkit-scrollbar{display:none}
.chip{flex:none;min-height:36px;padding:6px 14px;border-radius:18px;border:.5px solid var(--line);background:var(--surface);color:var(--text);font-size:15px;font-weight:550;display:flex;align-items:center;gap:6px;white-space:nowrap}
.chip.on{background:var(--accent);color:var(--accent-ink);border-color:var(--accent)}
.seg{display:flex;margin:4px 20px 12px;padding:2px;border-radius:10px;background:var(--surface2)}
.seg button{flex:1;min-height:34px;border:0;border-radius:8px;background:none;font-size:14px;font-weight:600;color:var(--text)}
.seg button.on{background:var(--surface);box-shadow:0 1px 4px rgba(0,0,0,.15)}
.room .seg button.on{background:var(--accent);color:var(--accent-ink)}
.list{margin:0 20px;background:var(--surface);border-radius:14px;overflow:hidden}
.row{display:flex;align-items:center;gap:12px;width:100%;min-height:56px;padding:10px 14px;border:0;background:none;text-align:left;color:inherit;text-decoration:none;position:relative}
.row+.row::before{content:"";position:absolute;top:0;left:14px;right:0;border-top:.5px solid var(--line)}
.row .ic{flex:none;width:40px;height:40px;border-radius:10px;background:var(--accent-soft);color:var(--accent);display:grid;place-items:center;overflow:hidden;position:relative}
.row .ic img{width:100%;height:100%;object-fit:cover}
.row .tx{flex:1;min-width:0}
.row .tx b{display:block;font-weight:600;font-size:16px;line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row .tx small{display:block;color:var(--muted);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row .chev{color:var(--muted);opacity:.6;width:18px;height:18px}
.row .num{flex:none;width:28px;text-align:center;color:var(--muted);font-variant-numeric:tabular-nums;font-size:15px}
.row.on b{color:var(--accent)}
.row:active{background:var(--surface2)}
.empty{margin:18px 20px;padding:28px 22px;border-radius:18px;background:var(--surface);text-align:center}
.empty .big{font-size:40px;line-height:1;margin-bottom:10px}
.empty h3{margin:0 0 6px;font-size:19px}
.empty p{margin:0;color:var(--muted);font-size:15px}
.empty button{margin-top:14px}
.btn{min-height:50px;border:0;border-radius:14px;padding:0 20px;font-weight:650;font-size:17px;display:inline-flex;align-items:center;justify-content:center;gap:8px;text-decoration:none;background:var(--surface2);color:var(--text)}
.btn.primary{background:var(--accent);color:var(--accent-ink)}
.btn svg{width:20px;height:20px}
.btns{display:flex;gap:10px;padding:0 20px;margin:14px 0}
.btns .btn{flex:1;white-space:nowrap;padding:0 14px}
.searchbox{display:flex;align-items:center;gap:8px;margin:2px 20px 12px;padding:0 12px;min-height:40px;border-radius:12px;background:var(--surface2);color:var(--muted)}
.searchbox input{flex:1;min-width:0;border:0;background:none;color:var(--text);font:inherit;font-size:17px;padding:8px 0;outline:none}
.searchbox svg{width:19px;height:19px}
button.searchbox{width:calc(100% - 40px);border:0;text-align:left;font-size:17px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pills{display:flex;flex-wrap:wrap;gap:6px;padding:0 20px 8px}
.pill{font-size:13px;font-weight:600;color:var(--muted);background:var(--surface2);padding:4px 10px;border-radius:99px}
.pill.ok{color:var(--accent);background:var(--accent-soft)}
.err{color:var(--warn)}
.note{color:var(--muted);font-size:13px;padding:0 20px}

/* Skeletons */
.sk{background:linear-gradient(100deg,var(--surface2) 30%,var(--surface) 50%,var(--surface2) 70%);background-size:300% 100%;animation:sk 1.3s ease-in-out infinite;border-radius:10px}
@keyframes sk{from{background-position:100% 0}to{background-position:0 0}}
.skline{height:14px;margin-top:8px;width:70%}
.sktitle{height:22px;width:40%;margin:0 20px 12px}

/* Hero (Watch, Listen) */
.forest{position:relative;margin-top:calc(-1 * (var(--st) + 44px));padding-top:calc(var(--st) + 44px);background:linear-gradient(180deg,rgba(12,27,22,.15),rgba(12,27,22,.55) 55%,var(--bg)),url('/assets/watch-forest.jpg') center 70%/cover no-repeat}
.hero{position:relative;display:block;margin:6px 20px 8px;border-radius:18px;overflow:hidden;aspect-ratio:16/10;max-height:420px;width:calc(100% - 40px);border:0;padding:0;text-align:left;color:#fff;background:#000;box-shadow:var(--shadow)}
.hero img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.hero::after{content:"";position:absolute;inset:0;background:linear-gradient(180deg,transparent 35%,rgba(0,0,0,.85))}
.hero .in{position:absolute;z-index:1;left:0;right:0;bottom:0;padding:16px 18px}
.hero .eb{font-size:11px;font-weight:750;letter-spacing:.12em;opacity:.85}
.hero h3{margin:4px 0 2px;font-size:24px;line-height:1.15}
.hero p{margin:0 0 10px;font-size:13px;opacity:.85}
.hero .bar{height:4px;width:160px;background:rgba(255,255,255,.3);border-radius:2px;margin-bottom:12px}.hero .bar i{display:block;height:100%;background:#fff;border-radius:2px}
.hero .go{display:inline-flex;align-items:center;gap:6px;background:#fff;color:#000;border-radius:20px;padding:8px 16px;font-weight:700;font-size:15px}
.hero .go svg{width:16px;height:16px;fill:currentColor;stroke:none}

/* Detail pages */
.dhead{position:relative;margin-top:calc(-1 * (var(--st) + 44px))}
.dhead .back{position:relative;aspect-ratio:16/9;max-height:56vh;width:100%;overflow:hidden;background:var(--surface2)}
.dhead .back img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.dhead .back::after{content:"";position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,.35),transparent 30%,transparent 55%,var(--bg))}
.dhead.coverhead{padding:calc(var(--st) + 60px) 20px 6px;display:flex;justify-content:center;background:linear-gradient(180deg,var(--accent-soft),transparent)}
.dhead.coverhead .art{width:min(52vw,220px);aspect-ratio:2/3;border-radius:10px;box-shadow:0 18px 40px rgba(0,0,0,.35)}
.dhead.coverhead.sq .art{aspect-ratio:1;width:min(64vw,280px)}
.dinfo{padding:10px 20px 0;text-align:left}
.coverhead+.dinfo{text-align:center}
.dinfo .k{font-size:12px;font-weight:750;letter-spacing:.1em;color:var(--muted)}
.dinfo h1{font-size:28px;line-height:1.15;margin:4px 0 4px;letter-spacing:-.01em}
.dinfo p{margin:0;color:var(--muted);font-size:15px}
.dinfo .prog{margin-top:6px;font-size:14px;color:var(--accent);font-weight:600}
.summary{padding:4px 20px 0;font-size:15px;line-height:1.5;color:var(--text);opacity:.9}
.upnext{display:flex;gap:12px;align-items:center;margin:0 20px;padding:10px;border-radius:14px;background:var(--surface);border:0;width:calc(100% - 40px);text-align:left;color:inherit}
.upnext .art{width:120px;flex:none}
.upnext small{color:var(--muted);font-size:12px;font-weight:700;letter-spacing:.06em}

/* Ask */
.suggest{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:10px;padding:0 20px}
.suggest button{border:0;background:var(--surface);border-radius:14px;padding:14px 16px;text-align:left;min-height:64px}
.suggest small{display:block;font-size:11px;font-weight:750;letter-spacing:.06em;color:var(--muted);text-transform:uppercase}
.turn{padding:0 20px;margin-top:22px}
.turn .q{font-size:21px;font-weight:680;line-height:1.25;margin:0 0 10px}
.turn .a{background:var(--surface);border-radius:16px;padding:14px 16px}
.answer p{margin:0 0 .7em}.answer ul,.answer ol{margin:0 0 .7em;padding-left:1.3em}
.answer a.cite{font-weight:700;text-decoration:none;font-size:.85em;vertical-align:1px}
.status{color:var(--muted);display:flex;align-items:center;gap:8px}
.spin{width:14px;height:14px;border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:spin .8s linear infinite}
.meta{display:flex;gap:8px;align-items:center;margin-top:10px;flex-wrap:wrap}
.sources{margin-top:10px;display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:8px}
.src{display:flex;gap:10px;align-items:flex-start;text-decoration:none;color:inherit;padding:10px 12px;background:var(--surface);border-radius:12px}
.src .n{flex:none;width:22px;height:22px;border-radius:50%;background:var(--accent);color:var(--accent-ink);font-size:12px;font-weight:700;display:grid;place-items:center}
.src b{display:block;font-weight:600;font-size:15px;line-height:1.3}.src small{color:var(--muted)}
#composer{position:fixed;z-index:35;left:calc(var(--sl) + 10px);right:calc(var(--sr) + 10px);bottom:calc(max(10px,var(--sb)) + var(--tabh) + 8px);margin:0 auto;max-width:600px}
#composer form{display:flex;gap:8px;align-items:flex-end;background:var(--surface);border:.5px solid var(--line);border-radius:24px;padding:6px 6px 6px 16px;box-shadow:var(--shadow)}
#composer textarea{flex:1;border:0;background:none;color:var(--text);font:inherit;resize:none;max-height:140px;padding:7px 0;outline:none}
#composer .send{flex:none;width:36px;height:36px;border-radius:50%;border:0;background:var(--accent);color:var(--accent-ink);display:grid;place-items:center}
#composer .send:disabled{opacity:.35}
#composer .send svg{width:20px;height:20px;stroke-width:2.4}
.asknote{font-size:12px;color:var(--muted);padding:12px 20px 0}
.tab[data-tab=ask] .scroll{padding-bottom:calc(var(--tabh) + var(--sb) + 120px)}

/* Player */
#player{position:fixed;inset:0;z-index:60;display:flex;flex-direction:column;background:var(--bg);color:var(--text);overflow-y:auto;-webkit-overflow-scrolling:touch}
#player .top{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:8px;padding:calc(var(--st) + 6px) calc(var(--sr) + 12px) 8px calc(var(--sl) + 12px);background:var(--bar);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px)}
#player .top b{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-align:center;font-size:15px}
#player .top button{border:0;background:var(--surface2);color:var(--text);border-radius:18px;min-height:36px;min-width:36px;padding:0 12px;font-size:15px;font-weight:600;display:grid;place-items:center}
#player video{flex:1;min-height:0;width:100%;background:#000;max-height:calc(100dvh - var(--st) - 60px)}
#player .audiobox{display:flex;flex-direction:column;align-items:center;gap:14px;padding:20px 24px calc(var(--sb) + 24px);width:min(560px,100%);margin:0 auto}
#player .pcover{width:min(70vw,300px);aspect-ratio:1;border-radius:14px;box-shadow:var(--shadow)}
#player .pcover.cover{aspect-ratio:2/3;width:min(56vw,230px)}
#player .audiobox h2,#player .audiobox p{margin:0;text-align:center}
#player .audiobox h2{font-size:22px}
#player .audiobox>p{color:var(--muted);font-size:15px}
#player input[type=range]{width:100%;accent-color:var(--accent);height:28px}
.times{width:100%;display:flex;justify-content:space-between;color:var(--muted);font-size:13px;font-variant-numeric:tabular-nums;margin-top:-8px}
.ctrls{display:flex;align-items:center;justify-content:center;gap:22px}
.ctrls button{border:0;border-radius:50%;background:none;color:var(--text);min-width:52px;min-height:52px;font-size:15px;font-weight:650}
.ctrls .pp{width:72px;height:72px;background:var(--accent);color:var(--accent-ink);font-size:28px}
.tools{display:flex;flex-wrap:wrap;justify-content:center;gap:12px}
.tools label{display:flex;gap:6px;align-items:center;font-size:14px;color:var(--muted)}
.tools select{font:inherit;font-size:15px;min-height:40px;padding:6px 10px;border-radius:10px;border:.5px solid var(--line);background:var(--surface);color:var(--text)}
#player .tracks{width:100%;background:var(--surface);border-radius:14px;overflow:hidden}
.pprog{height:3px;background:var(--line);flex:none}.pprog i{display:block;height:100%;width:0;background:var(--accent)}
#player.mini{inset:auto calc(var(--sr) + 10px) calc(max(10px,var(--sb)) + var(--tabh) + 8px) calc(var(--sl) + 10px);max-width:600px;margin:0 auto;height:auto;max-height:none;overflow:hidden;border-radius:18px;box-shadow:var(--shadow);background:var(--bar);-webkit-backdrop-filter:blur(22px);backdrop-filter:blur(22px);border:.5px solid var(--line)}
#player.mini .top{position:static;background:none;padding:8px 10px;backdrop-filter:none;-webkit-backdrop-filter:none}
#player.mini .audiobox,#player.mini .upnext-card{display:none}
.upnext-card{position:fixed;right:calc(var(--sr) + 16px);bottom:calc(var(--sb) + 90px);max-width:300px;background:var(--surface);color:var(--text);padding:14px;border-radius:16px;display:flex;flex-wrap:wrap;gap:10px;box-shadow:var(--shadow);z-index:3}
.upnext-card span,.upnext-card b{width:100%}
.upnext-card button{border:0;border-radius:12px;min-height:40px;padding:0 14px;background:var(--surface2);color:var(--text);font-weight:600}
.upnext-card button:first-of-type{background:var(--accent);color:var(--accent-ink)}

/* Reader */
#reader{position:fixed;inset:0;z-index:70;background:var(--rbg);color:var(--rtext);--rbg:#fff;--rtext:#1c1f1d;--rbar:rgba(255,255,255,.86);--rline:rgba(0,0,0,.1);--rlink:#2E7F60}
#reader[data-theme=sepia]{--rbg:#f4ecd8;--rtext:#4b3a2a;--rbar:rgba(244,236,216,.9);--rline:rgba(75,58,42,.15);--rlink:#2E7F60}
#reader[data-theme=dark]{--rbg:#141615;--rtext:#e4e8e5;--rbar:rgba(28,31,30,.88);--rline:rgba(255,255,255,.1);--rlink:#5FC398}
#reader iframe{position:absolute;left:var(--sl);right:var(--sr);top:var(--st);bottom:var(--sb);width:calc(100% - var(--sl) - var(--sr));height:calc(100% - var(--st) - var(--sb));border:0;background:var(--rbg)}
#reader .rtop,#reader .rbot{position:absolute;left:0;right:0;z-index:2;display:flex;align-items:center;gap:6px;background:var(--rbar);-webkit-backdrop-filter:saturate(160%) blur(18px);backdrop-filter:saturate(160%) blur(18px);transition:transform .25s ease,opacity .25s ease}
#reader .rtop{top:0;padding:calc(var(--st) + 4px) calc(var(--sr) + 8px) 4px calc(var(--sl) + 8px);border-bottom:.5px solid var(--rline)}
#reader .rbot{bottom:0;padding:6px calc(var(--sr) + 8px) calc(var(--sb) + 6px) calc(var(--sl) + 8px);border-top:.5px solid var(--rline)}
#reader.bare .rtop{transform:translateY(-100%);opacity:0;pointer-events:none}
#reader.bare .rbot{transform:translateY(100%);opacity:0;pointer-events:none}
#reader .rbtn{min-width:44px;min-height:44px;border:0;background:none;color:var(--rlink);border-radius:22px;display:grid;place-items:center;font-size:17px;font-weight:600}
#reader .rbtn:disabled{opacity:.3}
#reader .rtitle{flex:1;min-width:0;text-align:center;font-size:15px;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#reader .rmid{flex:1;min-width:0;text-align:center;font-size:13px}
#reader .rmid b{display:block;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:14px}
#reader .rmid small{opacity:.7}
#reader .rprog{height:3px;background:var(--rline);border-radius:2px;margin:4px auto 2px;max-width:320px;overflow:hidden}
#reader .rprog i{display:block;height:100%;background:var(--rlink);width:0}
.sheet{position:fixed;z-index:80;left:0;right:0;bottom:0;max-height:78dvh;display:flex;flex-direction:column;background:var(--surface);color:var(--text);border-radius:18px 18px 0 0;box-shadow:0 -10px 40px rgba(0,0,0,.3);padding-bottom:var(--sb);transform:translateY(0);transition:transform .3s cubic-bezier(.2,.8,.2,1)}
#reader .sheet{background:var(--rbg);color:var(--rtext)}
.sheet.closed{transform:translateY(105%);pointer-events:none;box-shadow:none;visibility:hidden;transition:transform .3s cubic-bezier(.2,.8,.2,1),visibility 0s .3s}
.sheet .grab{width:38px;height:5px;border-radius:3px;background:var(--line);margin:8px auto 2px;flex:none}
.sheet .sh{display:flex;align-items:center;justify-content:space-between;padding:4px 16px 8px 20px;flex:none}
.sheet .sh h3{margin:0;font-size:18px}
.sheet .body{overflow-y:auto;-webkit-overflow-scrolling:touch;padding:0 0 16px}
.scrim{position:fixed;inset:0;z-index:79;background:rgba(0,0,0,.35);transition:opacity .25s}
.scrim.closed{opacity:0;pointer-events:none}
.rset{padding:6px 20px 12px;display:grid;gap:16px}
.rset .line{display:flex;align-items:center;justify-content:space-between;gap:12px}
.rset .sizes{display:flex;gap:8px}
.rset .sizes button{width:56px;height:44px;border-radius:12px;border:.5px solid var(--rline);background:none;color:inherit;font-family:Georgia,serif}
.rset .themes{display:flex;gap:10px}
.rset .themes button{width:64px;height:44px;border-radius:12px;border:2px solid transparent;font-weight:600;font-size:14px}
.rset .themes button.on{border-color:var(--rlink)}
#reader .row{color:inherit}#reader .row+.row::before{border-color:var(--rline)}#reader .row.on b{color:var(--rlink)}

/* Sign in */
#pin{position:fixed;inset:0;z-index:95;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;padding:calc(var(--st) + 20px) 24px calc(var(--sb) + 20px);background:radial-gradient(120% 70% at 50% 0%,var(--accent-soft),transparent),var(--bg);text-align:center}
#pin img{width:76px;height:76px;border-radius:18px;box-shadow:var(--shadow);margin-bottom:10px}
#pin h1{margin:0;font-size:24px}
#pin p{margin:0;color:var(--muted);font-size:15px;max-width:300px}
.dots{display:flex;gap:14px;height:22px;align-items:center;margin:18px 0 6px}
.dots i{width:13px;height:13px;border-radius:50%;border:1.5px solid var(--text);opacity:.7}
.dots i.f{background:var(--text);opacity:1}
.dots.shake{animation:shake .4s}
@keyframes shake{20%,60%{transform:translateX(-10px)}40%,80%{transform:translateX(10px)}}
.keys{display:grid;grid-template-columns:repeat(3,76px);gap:14px 22px;margin-top:10px}
.keys button{width:76px;height:76px;border-radius:50%;border:0;background:var(--surface2);color:var(--text);font-size:30px;font-weight:400;display:grid;place-items:center}
.keys button small{display:block;font-size:9px;letter-spacing:.18em;font-weight:650;margin-top:-6px;color:var(--muted)}
.keys button.plain{background:none;font-size:16px;font-weight:600;color:var(--accent)}
.keys button:active{background:var(--line)}
#pinerr{min-height:22px;color:var(--warn);font-size:15px}
@media (max-height:620px){.keys{grid-template-columns:repeat(3,64px);gap:10px 20px}.keys button{width:64px;height:64px;font-size:26px}#pin img{width:56px;height:56px}}

/* Add to Home Screen hint */
#a2hs{position:fixed;z-index:45;left:calc(var(--sl) + 12px);right:calc(var(--sr) + 12px);bottom:calc(max(10px,var(--sb)) + var(--tabh) + 12px);margin:0 auto;max-width:420px;display:flex;gap:12px;align-items:center;padding:12px 8px 12px 12px;border-radius:18px;background:var(--surface);box-shadow:var(--shadow);border:.5px solid var(--line);animation:rise .35s cubic-bezier(.2,.8,.2,1)}
#a2hs img{width:44px;height:44px;border-radius:10px;flex:none}
#a2hs p{margin:0;font-size:14px;line-height:1.35;flex:1}
#a2hs svg{width:17px;height:17px;vertical-align:-3px;color:var(--accent)}
#a2hs button{border:0;background:none;color:var(--muted);min-width:40px;min-height:40px;display:grid;place-items:center}
@keyframes rise{from{transform:translateY(20px);opacity:0}}

.page.gone{visibility:hidden}
svg.fill{fill:currentColor;stroke:none}
.ccard{flex:none;width:300px;scroll-snap-align:start;display:flex;gap:12px;align-items:center;padding:10px;border:0;border-radius:16px;background:var(--surface);text-align:left;color:inherit;box-shadow:0 1px 0 var(--line)}
.ccard .art{width:72px;flex:none;aspect-ratio:1;border-radius:10px}
.ccard .art.wide{width:112px;aspect-ratio:16/9}
.ccard .art.tall{width:60px;aspect-ratio:2/3;border-radius:6px}
.ccard .art .ph{font-size:11px;padding:6px}
.ccard .tx{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px}
.ccard .tx small{font-size:11px;font-weight:750;letter-spacing:.08em;color:var(--accent)}
.ccard .tx b{font-size:15px;font-weight:600;line-height:1.25;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.ccard .pl{font-size:13px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ccard .mbar{display:block;height:4px;border-radius:2px;background:var(--surface2);overflow:hidden;margin-top:4px}
.ccard .mbar i{display:block;height:100%;background:var(--accent)}
.ccard:active{transform:scale(.98)}
.art.round{border-radius:50%}
.artist b,.artist small{text-align:center}
.group{font-size:13px;font-weight:750;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:22px 20px 0}
.shead h2.small{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);font-weight:700;margin-top:14px}
.shead .note{padding:0}
.toast{position:fixed;z-index:99;left:50%;bottom:calc(max(10px,var(--sb)) + var(--tabh) + 20px);transform:translateX(-50%);max-width:calc(100% - 40px);padding:12px 18px;border-radius:14px;background:rgba(20,28,24,.92);color:#fff;font-size:15px;box-shadow:var(--shadow);transition:opacity .3s;text-align:center}
.toast.out{opacity:0}
.minionly{display:none!important}
#player.mini .minionly{display:grid!important}
#player.mini .top b{text-align:left}
#player.mini video{height:auto;opacity:1;position:static;max-height:180px}
.page.detail:not(.scrolled) .nav .t{opacity:0}
.page.detail.room:not(.scrolled) .nav{background:linear-gradient(rgba(0,0,0,.45),transparent)}
.btn.sk{min-height:50px}
.hero.sk{background:none;box-shadow:none}

/* Motion */
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;transition-duration:.01ms!important;scroll-behavior:auto!important}.sk{animation:none}}
@media (min-width:768px){.card{width:280px}.card.cover{width:156px}.card.square{width:190px}.large{font-size:38px}.hero{aspect-ratio:21/9}.genres{grid-template-columns:repeat(auto-fill,minmax(190px,1fr))}}
@media (hover:hover){.card:hover .art{transform:translateY(-2px);box-shadow:var(--shadow)}.row:hover{background:var(--surface2)}}
</style>
</head>
<body class="signedout">
<div id="app" aria-live="off"></div>
<nav id="tabbar" aria-label="Sections"></nav>
<div id="composer" class="hidden">
  <form id="askform"><label class="sr" for="askinput">Ask a question</label><textarea id="askinput" rows="1" placeholder="Ask a question" enterkeyhint="send"></textarea><button class="send" id="send" disabled aria-label="Ask"><svg class="i" viewBox="0 0 24 24"><path d="M12 19V5M6 11l6-6 6 6"/></svg></button></form>
</div>
<div id="player" class="hidden"></div>
<div id="reader" class="hidden"></div>
<div id="pin" class="hidden" role="dialog" aria-labelledby="pintitle">
  <img src="/assets/icon-180.png" alt="" width="76" height="76">
  <h1 id="pintitle">Enter PIN</h1>
  <p>The person who set up Offline Kit can tell you the PIN.</p>
  <div class="dots" id="dots" aria-hidden="true"></div>
  <div id="pinerr" role="alert"></div>
  <div class="keys" id="keys"></div>
</div>
<script src="/assets/play.js" defer></script>
<script>
/*SCRIPT*/
</script>
</body>
</html>
"""#
}

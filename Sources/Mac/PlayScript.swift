import Foundation
import CryptoKit

/// The browser side of game streaming (see GameStream): `/assets/play.js`, which any Offline Kit page can load to get
/// `window.OKPlay.open(id, {resume})`, and a bare `/play-test` page for trying it without the main page.
///
/// play.js is self-contained: its styles are injected once and scoped under `.okplay-root`, every element it makes
/// has an `okp-` class, and it builds the DOM with DOM methods (no HTML parsing of anything from the server).
enum PlayScript {
    static let player: (data: Data, etag: String) = cached(WebApp.slim(js))
    static let testPage: (data: Data, etag: String) = cached(test)

    private static func cached(_ text: String) -> (data: Data, etag: String) {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return (data, "\"\(digest)\"")
    }

    // MARK: play.js

    private static let js = #"""
(function () {
'use strict';
if (window.OKPlay) return;

// Joypad buttons, numbered like libretro's (RetroButton on the Mac).
var B = { B: 0, Y: 1, SELECT: 2, START: 3, UP: 4, DOWN: 5, LEFT: 6, RIGHT: 7, A: 8, X: 9, L: 10, R: 11 };
var DIRS = [B.UP, B.DOWN, B.LEFT, B.RIGHT];

var CSS = [
'html.okp-open body>:not(.okplay-root){content-visibility:hidden}',
'.okplay-root{--ink:#f5e7c9;--pine:#163d30;--edge:#72917b;position:fixed;inset:0;z-index:2147483000;background:radial-gradient(ellipse at 35% 0,#335943,#13372c 70%);color:var(--ink);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,system-ui,sans-serif;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;touch-action:none;overflow:hidden;display:flex;flex-direction:column;padding:env(safe-area-inset-top,0) env(safe-area-inset-right,0) env(safe-area-inset-bottom,0) env(safe-area-inset-left,0);-webkit-tap-highlight-color:transparent;box-shadow:inset 0 0 0 3px #65866d,inset 0 0 0 7px #102c22}',
'.okplay-root *{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}',
'.okplay-root button{font:inherit;color:inherit;cursor:pointer;touch-action:none}',
'.okplay-root button:focus-visible,.okplay-root summary:focus-visible{outline:3px solid #ffbd5b;outline-offset:3px}',
'.okplay-root .okp-top{flex:none;display:flex;align-items:center;gap:8px;padding:12px 16px;min-height:64px;z-index:3}',
'.okplay-root .okp-compass{font-size:29px;color:#efb74f;text-shadow:0 2px 2px #061b13;flex:none}',
'.okplay-root .okp-title{flex:1;min-width:0;font-weight:750;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
'.okplay-root .okp-system{font-size:11px;font-weight:750;letter-spacing:.04em;border-radius:20px;padding:4px 9px;background:#eedfbd;color:#19392a;white-space:nowrap;flex:none}',
'.okplay-root .okp-icon{min-width:62px;height:44px;padding:0 12px;border-radius:22px;background:linear-gradient(#315940,#16362a);border:1px solid #80987b;box-shadow:0 3px 0 #081d16,inset 0 1px #b4c4a245;font-size:12px;font-weight:750;flex:none}',
'.okplay-root .okp-stage{flex:none;display:flex;align-items:center;justify-content:center;position:relative;min-height:0;padding:12px 16px;pointer-events:none}',
'.okplay-root canvas.okp-screen{pointer-events:auto;display:block;background:#080e09;image-rendering:pixelated;image-rendering:crisp-edges;touch-action:none;outline:7px solid #10291f;border-radius:3px;box-shadow:0 0 0 10px #688371,0 0 0 13px #0c241b,0 9px 20px #06160d99}',
'.okplay-root canvas.okp-screen.okp-clear{background:transparent;position:relative;z-index:1}',
'.okplay-root video.okp-video{position:absolute;pointer-events:none;background:#080e09;object-fit:fill;border-radius:3px;image-rendering:pixelated;image-rendering:crisp-edges}',
'.okplay-root .okp-pad{flex:1;position:relative;min-height:0}',
'.okplay-root .okp-pad:after{content:"✥";position:absolute;left:50%;top:24%;transform:translateX(-50%);font-size:32px;color:#e8ad46;text-shadow:0 2px 2px #071e15;pointer-events:none}',
'.okplay-root .okp-dpad{position:absolute;width:156px;height:156px;border-radius:50%;background:#0d2b21;box-shadow:inset 0 2px 6px #06160e,0 1px #83988066}',
'.okplay-root .okp-dpad i{position:absolute;background:linear-gradient(135deg,#45634b,#203c2e);border:1px solid #8d9a78;box-shadow:0 4px 3px #071a12}',
'.okplay-root .okp-dpad i.okp-h{left:0;right:0;top:52px;height:52px;border-radius:10px}',
'.okplay-root .okp-dpad i.okp-v{top:0;bottom:0;left:52px;width:52px;border-radius:10px}',
'.okplay-root .okp-dpad b{position:absolute;width:52px;height:52px;border-radius:10px;display:grid;place-items:center;font-size:19px;color:#f3e4bd;text-shadow:0 2px #071a12}',
'.okplay-root .okp-dpad b.okp-on{background:#e9c66b55}',
'.okplay-root .okp-btn{position:absolute;border-radius:50%;width:66px;height:66px;display:grid;place-items:center;font-weight:800;font-size:27px;color:#382712;border:2px solid #1c2a18;box-shadow:0 4px 0 #092319,0 0 0 3px #82947a,inset 0 3px 2px #ffffff80,inset 0 -5px 3px #713b2545}',
'.okplay-root .okp-btn.okp-a{background:linear-gradient(#ffc760,#e89424)}',
'.okplay-root .okp-btn.okp-b{background:linear-gradient(#ff9c77,#dc614c)}',
'.okplay-root .okp-pill{position:absolute;height:44px;min-width:72px;padding:0 12px;border-radius:18px;background:linear-gradient(#f8eaca,#d8c39a);color:#21382a;border:1px solid #a59d7c;box-shadow:0 3px 0 #081d16,inset 0 2px #fff7df;font-size:12px;font-weight:800;letter-spacing:.04em;display:grid;place-items:center;text-transform:uppercase}',
'.okplay-root .okp-on{filter:brightness(1.25);box-shadow:inset 0 3px 4px #071d1680!important}',
'.okplay-root .okp-keys{flex:none;display:flex;flex-wrap:wrap;gap:6px;justify-content:center;padding:8px 14px 14px}',
'.okplay-root .okp-key{height:44px;min-width:44px;padding:0 12px;border-radius:10px;background:linear-gradient(#f4e6c5,#d8c39c);color:#213a2a;border:1px solid #8e9679;box-shadow:0 3px 0 #0a241a;font-weight:750;font-size:13px}',
'.okplay-root .okp-extra{flex-basis:100%;text-align:center;max-height:150px;overflow:auto;touch-action:pan-y}',
'.okplay-root .okp-extra summary{padding:8px;cursor:pointer;font-size:12px;font-weight:650}',
'.okplay-root .okp-extra-row{display:flex;flex-wrap:wrap;justify-content:center;gap:6px;padding:4px}',
'.okplay-root .okp-hint{flex:none;text-align:center;font-size:12px;color:#d6dcc7;padding:6px 16px}',
'.okplay-root input.okp-type{position:absolute;left:0;bottom:0;width:1px;height:1px;opacity:0;border:0;font-size:16px}',
'.okplay-root .okp-veil{position:absolute;inset:0;background:#061a13b8;display:flex;align-items:flex-end;justify-content:center;z-index:5;padding:16px;padding-bottom:max(16px,env(safe-area-inset-bottom,0))}',
'.okplay-root .okp-veil.okp-center{align-items:center}',
'.okplay-root .okp-sheet{width:100%;max-width:420px;background:#f2e6cd;color:#203d2d;border:2px solid #8d9c7c;border-radius:22px;padding:22px;display:flex;flex-direction:column;gap:10px;box-shadow:0 12px 40px #00140999,inset 0 0 0 4px #fbf3df;max-height:100%;overflow:auto;touch-action:pan-y}',
'.okplay-root .okp-sheet h2{font-size:23px;font-weight:800;line-height:1.25}',
'.okplay-root .okp-sheet p{color:#56624b;font-size:14px}',
'.okplay-root .okp-row{display:flex;gap:10px}',
'.okplay-root .okp-act{flex:1;min-height:46px;border:1px solid #bac1a6;border-radius:12px;background:#e4ddc7;color:#203d2d;font-weight:700;font-size:15px;padding:10px 14px}',
'.okplay-root .okp-act.okp-main{background:#28553e;color:#fff0d0;border-color:#234b37;box-shadow:0 3px #163b29}',
'.okplay-root .okp-stats{font:11px/1.5 ui-monospace,Menlo,monospace;color:#56624b;text-align:left;padding:8px 0}',
'.okplay-root .okp-diagnostics summary{font-size:12px;color:#56624b;cursor:pointer;padding:8px 0}',
'.okplay-root .okp-toast{position:absolute;left:50%;top:calc(68px + env(safe-area-inset-top,0));transform:translateX(-50%);background:#f2e6cdef;color:#213d2c;padding:8px 16px;border-radius:18px;font-weight:650;font-size:14px;z-index:4;pointer-events:none;max-width:90%;text-align:center;transition:opacity .25s}',
'.okplay-root .okp-spin{width:34px;height:34px;border-radius:50%;border:3px solid #a2b29b;border-top-color:#28553e;animation:okp-spin .9s linear infinite;margin:6px auto}',
'.okplay-root .okp-link{flex:none;display:flex;align-items:center;gap:6px;height:24px;padding:0 9px;border-radius:20px;background:#0d2b21;border:1px solid #80987b;font-size:11px;font-weight:750;letter-spacing:.04em}',
'.okplay-root .okp-link i{width:9px;height:9px;border-radius:50%;background:#7fd38f;box-shadow:0 0 0 2px #0d2b21,0 0 6px #7fd38f99;display:block}',
'.okplay-root .okp-link.okp-ok i{background:#efb74f;box-shadow:0 0 0 2px #0d2b21,0 0 6px #efb74f99}',
'.okplay-root .okp-link.okp-weak i{background:#e8664f;box-shadow:0 0 0 2px #0d2b21,0 0 6px #e8664f99}',
'.okplay-root .okp-link[hidden]{display:none}',
'.okplay-root .okp-link span{display:none}',
'.okplay-root .okp-sheet .okp-link{align-self:flex-start;background:#e4ddc7;border-color:#bac1a6;color:#203d2d;height:28px}',
'.okplay-root .okp-sheet .okp-link i{box-shadow:none}',
'.okplay-root .okp-sheet .okp-link span{display:inline}',
'@keyframes okp-spin{to{transform:rotate(360deg)}}',
'.okplay-root.okp-land .okp-stage{position:absolute;top:calc(var(--okp-top-height,64px) + env(safe-area-inset-top,0));left:176px;right:176px;bottom:16px}',
'.okplay-root.okp-land .okp-pad{position:absolute;top:calc(var(--okp-top-height,64px) + env(safe-area-inset-top,0));left:env(safe-area-inset-left,0);right:env(safe-area-inset-right,0);bottom:env(safe-area-inset-bottom,0);z-index:2}',
'.okplay-root.okp-land .okp-pad:after{display:none}',
'.okplay-root.okp-pointer.okp-land .okp-stage{left:16px;right:16px}',
'.okplay-root.okp-computer.okp-land .okp-keys{position:absolute;left:0;right:0;bottom:env(safe-area-inset-bottom,0);z-index:3;padding-bottom:10px}',
'.okplay-root.okp-computer.okp-land .okp-hint{display:none}',
'.okplay-root.okp-ctl .okp-pad{flex:1}',
'.okplay-root.okp-computer .okp-pad{pointer-events:none}',
'.okplay-root.okp-computer .okp-pad>*{pointer-events:auto}',
'.okplay-root.okp-keydeck.okp-land .okp-pad{visibility:hidden}',
'@media(max-width:600px){.okplay-root .okp-top{display:grid;grid-template-columns:minmax(0,1fr) auto auto;gap:6px 8px;padding:10px 14px}.okplay-root .okp-compass{display:none}.okplay-root .okp-title{grid-column:1/-1;font-size:15px}.okplay-root .okp-system{justify-self:start}.okplay-root .okp-icon{min-width:62px}}',
'@media(max-width:380px){.okplay-root .okp-top{gap:5px;padding:10px}.okplay-root .okp-compass{display:none}.okplay-root .okp-icon{min-width:54px;padding:0 8px}.okplay-root .okp-system{padding:4px 6px;font-size:10px}.okplay-root .okp-title{font-size:15px}}',
'@media(prefers-reduced-motion:reduce){.okplay-root .okp-spin{animation:none}.okplay-root .okp-toast{transition:none}}',
".okplay-root{inset:8px;box-sizing:border-box;border:3px solid #759477;border-radius:34px;background-color:#1a4330;background-image:radial-gradient(ellipse at 25% 0,#42634866,transparent 65%),linear-gradient(145deg,#284e38,#173d2c 70%,#123423);box-shadow:inset 0 2px 1px #c6d4a966,inset 0 0 0 4px #284b34,inset 0 0 0 7px #112d20,inset 0 -9px 16px #061d13aa,0 12px 24px #001c1380}",
".okplay-root:before{content:\"\";position:absolute;inset:3px;border-radius:28px;background-image:url(\"data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%22128%22%20height%3D%22128%22%3E%3Cfilter%20id%3D%22n%22%3E%3CfeTurbulence%20type%3D%22fractalNoise%22%20baseFrequency%3D%22.8%22%20numOctaves%3D%223%22%20stitchTiles%3D%22stitch%22%2F%3E%3CfeColorMatrix%20type%3D%22saturate%22%20values%3D%220%22%2F%3E%3C%2Ffilter%3E%3Cpath%20fill%3D%22%23fff%22%20filter%3D%22url%28%23n%29%22%20d%3D%22M0%200h128v128H0z%22%20opacity%3D%22.5%22%2F%3E%3C%2Fsvg%3E\");background-size:128px 128px;opacity:.22;mix-blend-mode:soft-light;pointer-events:none;z-index:4}",
".okplay-root .okp-top{position:relative;padding:16px 22px;gap:12px;min-height:72px}",
".okplay-root .okp-nameplate{display:flex;align-items:center;gap:10px;flex:1;min-width:0;padding:7px 12px;background:linear-gradient(110deg,#e7cf9d,#f5e4b7 50%,#d9c08a);color:#183c29;border:1px solid #baaa76;border-radius:5px;box-shadow:0 3px 0 #081f14,inset 0 1px #fff2cc;font-family:\"Avenir Next\",system-ui,sans-serif}",
".okplay-root .okp-title{font-size:16px;font-weight:850;opacity:1}",
".okplay-root .okp-title:before{content:\"\u2660\";font-size:15px;padding-right:7px;color:#285039}",
".okplay-root .okp-system{background:#254a32;color:#f4e4b8;border:1px solid #617958;font-size:10px;padding:3px 8px;max-width:112px;overflow:hidden;text-overflow:ellipsis}",
".okplay-root .okp-compass{display:block;width:54px;height:54px;background:url(\"data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20viewBox%3D%220%200%2064%2064%22%3E%3Cdefs%3E%3ClinearGradient%20id%3D%22g%22%20x2%3D%221%22%20y2%3D%221%22%3E%3Cstop%20stop-color%3D%22%23ffdc80%22%2F%3E%3Cstop%20offset%3D%221%22%20stop-color%3D%22%23ac6d1f%22%2F%3E%3C%2FlinearGradient%3E%3C%2Fdefs%3E%3Cpath%20d%3D%22M32%202l7%2018%2016-11-11%2017%2018%206-18%207%2011%2016-17-11-6%2018-7-18L9%2055l11-17L2%2032l18-7L9%209l17%2011z%22%20fill%3D%22url%28%23g%29%22%20stroke%3D%22%230a2118%22%20stroke-width%3D%223%22%20stroke-linejoin%3D%22round%22%2F%3E%3Cpath%20d%3D%22M32%207v25L20%2025zm25%2025H32l7-12zM32%2057V32l12%207zM7%2032h25l-7%2012z%22%20fill%3D%22%23f4d88b%22%20opacity%3D%22.75%22%2F%3E%3Ccircle%20cx%3D%2232%22%20cy%3D%2232%22%20r%3D%225%22%20fill%3D%22%2316382a%22%20stroke%3D%22%23e6bb64%22%20stroke-width%3D%222%22%2F%3E%3C%2Fsvg%3E\") center/contain no-repeat;filter:drop-shadow(0 3px 1px #05170e);font-size:0}",
".okplay-root .okp-icon{height:44px;border:2px solid #0b2418;border-radius:25px;background:linear-gradient(#3f6144,#21432e);box-shadow:0 3px 1px #061c12,0 0 0 2px #698361,inset 0 2px 2px #b6c6a378,inset 0 -3px 4px #102719;color:#f1e2b7;font-size:12px;font-weight:800;text-transform:uppercase}",
".okplay-root .okp-stage{padding:0;z-index:1}",
".okplay-root .okp-bezel{flex:none;padding:15px;border-radius:17px;background:linear-gradient(140deg,#3c6147,#102f20 30%,#244f35 80%,#5b7853);box-shadow:0 0 0 2px #0a2518,0 0 0 4px #6c8e66,0 0 0 7px #123723,0 5px 2px #071e14,inset 0 0 0 3px #476d4c,inset 0 0 0 6px #0b2417,inset 0 4px 9px #041a10}",
".okplay-root canvas.okp-screen{outline:0;border:0;border-radius:5px;box-shadow:0 0 0 3px #061c12,inset 0 2px 4px #000;flex:none}",
".okplay-root .okp-pad{pointer-events:none;z-index:2}",
".okplay-root .okp-pad>*{pointer-events:auto}",
".okplay-root .okp-pad:after{display:none}",
".okplay-root .okp-dpad{border-radius:0;background:url(\"data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20viewBox%3D%220%200%20156%20156%22%3E%3Cdefs%3E%3ClinearGradient%20id%3D%22d%22%20x2%3D%220%22%20y2%3D%221%22%3E%3Cstop%20stop-color%3D%22%2347664a%22%2F%3E%3Cstop%20offset%3D%22.48%22%20stop-color%3D%22%23294936%22%2F%3E%3Cstop%20offset%3D%221%22%20stop-color%3D%22%23173527%22%2F%3E%3C%2FlinearGradient%3E%3C%2Fdefs%3E%3Ccircle%20cx%3D%2278%22%20cy%3D%2278%22%20r%3D%2276%22%20fill%3D%22%23112c20%22%2F%3E%3Cpath%20d%3D%22M57%205h42q7%200%207%208v37h37q8%200%208%208v40q0%208-8%208h-37v37q0%208-8%208H58q-8%200-8-8v-37H13q-8%200-8-8V58q0-8%208-8h37V13q0-8%207-8z%22%20fill%3D%22%23071d13%22%20transform%3D%22translate%280%203%29%22%20stroke%3D%22%2306170f%22%20stroke-width%3D%227%22%2F%3E%3Cpath%20d%3D%22M57%205h42q7%200%207%208v37h37q8%200%208%208v40q0%208-8%208h-37v37q0%208-8%208H58q-8%200-8-8v-37H13q-8%200-8-8V58q0-8%208-8h37V13q0-8%207-8z%22%20fill%3D%22url%28%23d%29%22%20stroke%3D%22%2381977a%22%20stroke-width%3D%221.6%22%2F%3E%3Cpath%20d%3D%22M58%209h39q5%200%205%205v40h40q5%200%205%205%22%20fill%3D%22none%22%20stroke%3D%22%23b8c5a0%22%20opacity%3D%22.35%22%20stroke-width%3D%222%22%2F%3E%3C%2Fsvg%3E\") center/contain no-repeat;box-shadow:none}",
".okplay-root .okp-dpad i{display:none}",
".okplay-root .okp-dpad b{width:33.3333%;height:33.3333%;font-size:20px;text-shadow:0 2px 0 #071b11;color:#f7e6b9}",
".okplay-root .okp-btn{border:3px solid #502b13;box-shadow:0 5px 1px #061e12,0 0 0 3px #0e2b1b,0 0 0 5px #71835b,inset 0 3px 2px #fff0bc,inset 0 -6px 3px #8f401c80;font-size:32px;font-weight:900;color:#38220d}",
".okplay-root .okp-btn.okp-a{background:linear-gradient(145deg,#ffc754,#f5a222 58%,#d27a16)}",
".okplay-root .okp-btn.okp-b{background:linear-gradient(145deg,#ffa47b,#ef7356 58%,#c94835);border-color:#552317}",
".okplay-root .okp-pill{background:linear-gradient(#f8e8ba,#dbc391);border:2px solid #152d1b;box-shadow:0 4px 0 #071c11,0 0 0 2px #70805a,inset 0 2px #fff7d2,inset 0 -3px 2px #b3965d;color:#193623;font-size:12px;font-weight:850;border-radius:24px}",
".okplay-root .okp-vent{position:absolute;bottom:16px;width:42px;height:23px;z-index:1;pointer-events:none;background:repeating-linear-gradient(132deg,transparent 0 7px,#0b2a1b 7px 11px,#74926a77 11px 12px,transparent 12px 17px);border-radius:5px;opacity:.8}",
".okplay-root .okp-vent-left{left:20px}.okplay-root .okp-vent-right{right:20px}",
".okplay-root.okp-console .okp-top{position:absolute;inset:0;padding:0;min-height:0;display:block;pointer-events:none;z-index:3}",
".okplay-root.okp-console .okp-top>*{position:absolute}.okplay-root.okp-console .okp-top button{pointer-events:auto}",
".okplay-root.okp-console .okp-nameplate{height:36px;gap:8px;display:flex;min-width:0}",
".okplay-root.okp-console .okp-pad{position:absolute;inset:0;min-height:0}",
".okplay-root.okp-console .okp-stage{position:absolute;inset:auto;min-height:0;display:flex;align-items:center;justify-content:center}",
"@media(max-width:600px){.okplay-root:not(.okp-console) .okp-top{display:flex;flex-wrap:wrap;gap:10px;padding:14px}.okplay-root:not(.okp-console) .okp-nameplate{flex-basis:100%}.okplay-root:not(.okp-console) .okp-compass{display:none}.okplay-root .okp-title{font-size:15px}.okplay-root .okp-system{max-width:100px}}",
"@media(max-height:420px){.okplay-root{inset:5px;border-radius:28px}.okplay-root .okp-vent{bottom:10px;width:33px;height:18px}}",
".okplay-root.okp-console:not(.okp-land){max-height:calc((100vw - 16px) * 1.8);margin:auto}",
".okplay-root:not(.okp-console) .okp-nameplate{position:relative}",,
".okplay-root .okp-bezel{position:relative;display:flex;align-items:center;justify-content:center}",
".okplay-root .okp-bezel:before{content:\"\";position:absolute;inset:15px;border-radius:5px;background:#06190f;box-shadow:inset 0 3px 8px #000;pointer-events:none}",
".okplay-root canvas.okp-screen{position:relative;z-index:1}",
".okplay-root .okp-title:before{content:\"\";display:inline-block;vertical-align:-1px;width:11px;height:16px;margin-right:7px;padding:0;background:#254a32;clip-path:polygon(50% 0,80% 32%,65% 32%,95% 65%,74% 65%,100% 90%,60% 90%,60% 100%,40% 100%,40% 90%,0 90%,26% 65%,5% 65%,35% 32%,20% 32%)}",
".okplay-root .okp-sound:before{content:\"\u266a\";display:inline-block;margin-right:8px;font-size:17px;vertical-align:-1px}",
".okplay-root:not(.okp-console) .okp-bezel{width:auto!important;height:auto!important}",
"html.okp-open body{background:radial-gradient(ellipse at 30% 10%,#fcf6e9,#e5d9bf)}",
".okplay-root .okp-vent{bottom:12px}",
".okplay-root.okp-console .okp-hint{position:absolute;z-index:1;padding:0;pointer-events:none}",
].join('\n');

function el(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

// The core's sound, resampled to the device's rate, with a small buffer that steers itself back to ~70 ms.
// Used inside an AudioWorklet where the page is a secure context, else on the page (ScriptProcessor): plain
// http:// addresses on a home network aren't secure contexts, and AudioWorklet is only offered in those.
class OKRing {
  constructor(srcRate, dstRate, target) {
    this.cap = 1 << 16; this.buf = new Float32Array(this.cap * 2);
    this.r = 0; this.w = 0; this.n = 0; this.pos = 0; this.primed = false;
    this.srcRate = srcRate; this.base = srcRate / dstRate; this.target = Math.round(target * srcRate);
  }
  push(s) {
    var frames = s.length >> 1;
    for (var i = 0; i < frames; i++) {
      if (this.n >= this.cap) { this.r = (this.r + 1) % this.cap; this.n--; }
      var j = this.w * 2;
      this.buf[j] = s[2 * i] / 32768; this.buf[j + 1] = s[2 * i + 1] / 32768;
      this.w = (this.w + 1) % this.cap; this.n++;
    }
    if (this.n > this.target * 4) { var drop = this.n - this.target; this.r = (this.r + drop) % this.cap; this.n -= drop; }
  }
  clear() { this.r = this.w = this.n = 0; this.pos = 0; this.primed = false; }
  pull(L, R) {
    var len = L.length;
    if (!this.primed) {
      if (this.n >= this.target) this.primed = true;
      else { L.fill(0); if (R !== L) R.fill(0); return; }
    }
    var adjust = Math.max(-0.01, Math.min(0.01, (this.n - this.target) / this.target * 0.01));
    var step = this.base * (1 + adjust), buf = this.buf, cap = this.cap;
    for (var i = 0; i < len; i++) {
      if (this.n < 2) { this.primed = false; L.fill(0, i); if (R !== L) R.fill(0, i); return; }
      var j = this.r * 2, k = ((this.r + 1) % cap) * 2, f = this.pos;
      L[i] = buf[j] + (buf[k] - buf[j]) * f;
      if (R !== L) R[i] = buf[j + 1] + (buf[k + 1] - buf[j + 1]) * f;
      this.pos += step;
      while (this.pos >= 1) { this.pos -= 1; this.r = (this.r + 1) % cap; this.n--; }
    }
  }
  get ms() { return this.n / this.srcRate * 1000; }
}

var WORKLET = OKRing.toString() + '\n' +
  'class OKPlayProcessor extends AudioWorkletProcessor{constructor(o){super();var p=o.processorOptions;' +
  'this.ring=new OKRing(p.srcRate,sampleRate,p.target);this.t=0;' +
  'this.port.onmessage=e=>{if(e.data==="clear")this.ring.clear();else this.ring.push(new Int16Array(e.data));};}' +
  'process(i,o){var c=o[0];this.ring.pull(c[0],c[1]||c[0]);if((this.t++&63)===0)this.port.postMessage(this.ring.ms);return true;}}' +
  'registerProcessor("okplay-audio",OKPlayProcessor);';

function Sound() {
  var AC = window.AudioContext || window.webkitAudioContext;
  this.ctx = null; this.node = null; this.ring = null; this.port = null; this.ms = 0; this.muted = false; this.ready = false;
  if (!AC) return;
  try {
    // iPhone: play even with the ring/silent switch set to silent, like a game app does.
    if (navigator.audioSession) navigator.audioSession.type = 'playback';
  } catch (e) {}
  try { this.ctx = new AC({ latencyHint: 'interactive' }); } catch (e) { try { this.ctx = new AC(); } catch (e2) {} }
  if (this.ctx && this.ctx.resume) this.ctx.resume();   // open() runs from a tap, which is what Safari needs
}
Sound.prototype.start = function (srcRate) {
  var self = this, ctx = this.ctx;
  if (!ctx || !srcRate || this.ready) return;
  this.gain = ctx.createGain();
  this.gain.connect(ctx.destination);
  this.gain.gain.value = this.muted ? 0 : 1;
  var fallback = function () {
    var sp = ctx.createScriptProcessor(1024, 1, 2);
    self.ring = new OKRing(srcRate, ctx.sampleRate, 0.08);
    sp.onaudioprocess = function (e) {
      self.ring.pull(e.outputBuffer.getChannelData(0), e.outputBuffer.getChannelData(1));
      self.ms = self.ring.ms;
    };
    sp.connect(self.gain);
    self.node = sp; self.ready = true;
  };
  if (ctx.audioWorklet && window.isSecureContext) {
    var url = URL.createObjectURL(new Blob([WORKLET], { type: 'text/javascript' }));
    ctx.audioWorklet.addModule(url).then(function () {
      var node = new AudioWorkletNode(ctx, 'okplay-audio', { numberOfInputs: 0, outputChannelCount: [2],
        processorOptions: { srcRate: srcRate, target: 0.07 } });
      node.port.onmessage = function (e) { self.ms = e.data; };
      node.connect(self.gain);
      self.node = node; self.port = node.port; self.ready = true;
    }).catch(fallback);
  } else {
    fallback();
  }
};
Sound.prototype.push = function (buffer) {
  if (!this.ready || this.muted) return;
  if (this.port) this.port.postMessage(buffer, [buffer]);
  else this.ring.push(new Int16Array(buffer));
};
Sound.prototype.clear = function () {
  if (this.port) this.port.postMessage('clear'); else if (this.ring) this.ring.clear();
};
Sound.prototype.setMuted = function (m) {
  this.muted = m;
  if (this.gain) this.gain.gain.value = m ? 0 : 1;
  if (m) this.clear();
};
Sound.prototype.wake = function () { if (this.ctx && this.ctx.state !== 'running' && this.ctx.resume) this.ctx.resume(); };
Sound.prototype.close = function () {
  try { if (this.node) this.node.disconnect(); } catch (e) {}
  try { if (this.ctx && this.ctx.close) this.ctx.close(); } catch (e) {}
};

// libretro key codes (RETROK_*) for KeyboardEvent.code, then for KeyboardEvent.key (on-screen keyboards often send no code).
var CODE_KEYS = { Enter: 13, NumpadEnter: 271, Escape: 27, Backspace: 8, Tab: 9, Space: 32, Delete: 127,
  NumpadDecimal: 266, NumpadDivide: 267, NumpadMultiply: 268, NumpadSubtract: 269, NumpadAdd: 270, NumpadEqual: 272,
  NumLock: 300, ScrollLock: 302, Pause: 19, PrintScreen: 316,
  ArrowUp: 273, ArrowDown: 274, ArrowRight: 275, ArrowLeft: 276, Insert: 277, Home: 278, End: 279, PageUp: 280, PageDown: 281,
  ShiftLeft: 304, ShiftRight: 303, ControlLeft: 306, ControlRight: 305, AltLeft: 308, AltRight: 307, CapsLock: 301,
  Minus: 45, Equal: 61, BracketLeft: 91, BracketRight: 93, Backslash: 92, Semicolon: 59, Quote: 39, Comma: 44,
  Period: 46, Slash: 47, Backquote: 96 };
for (var f = 1; f <= 12; f++) CODE_KEYS['F' + f] = 281 + f;
var NAME_KEYS = { Enter: 13, Escape: 27, Backspace: 8, Tab: 9, ' ': 32, Delete: 127, ArrowUp: 273, ArrowDown: 274,
  ArrowRight: 275, ArrowLeft: 276, Shift: 304, Control: 306, Alt: 308 };
var SHIFTED = { '!': 49, '@': 50, '#': 51, '$': 52, '%': 53, '^': 54, '&': 55, '*': 56, '(': 57, ')': 48, '_': 45, '+': 61,
  '{': 91, '}': 93, '|': 92, ':': 59, '"': 39, '<': 44, '>': 46, '?': 47, '~': 96 };
function retroKey(e) {
  var c = e.code || '';
  if (/^Key[A-Z]$/.test(c)) return c.charCodeAt(3) + 32;
  if (/^Digit[0-9]$/.test(c)) return c.charCodeAt(5);
  if (/^Numpad[0-9]$/.test(c)) return 256 + (c.charCodeAt(6) - 48);
  if (CODE_KEYS[c]) return CODE_KEYS[c];
  return keyForText(e.key);
}
function keyForText(k) {
  if (!k) return 0;
  if (NAME_KEYS[k]) return NAME_KEYS[k];
  if (k.length === 1) {
    var lower = k.toLowerCase(), code = lower.charCodeAt(0);
    if (code >= 32 && code < 127) return SHIFTED[k] || code;
  }
  return 0;
}
function charFor(k) {
  if (!k) return 0;
  if (k.length === 1 || (k.length === 2 && k.codePointAt(0) > 0xFFFF)) return k.codePointAt(0);
  return { Enter: 13, Backspace: 8, Tab: 9, Escape: 27 }[k] || 0;
}
function mods(e) { return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0); }

// Pad games on a keyboard, by physical key: arrows move, X = A, Z = B, S = X, A = Y, Q/W = shoulders,
// Return = Start, Space = Select (as in the Mac's game window).
var PAD_KEYS = { ArrowUp: B.UP, ArrowDown: B.DOWN, ArrowLeft: B.LEFT, ArrowRight: B.RIGHT, KeyX: B.A, KeyZ: B.B,
  KeyS: B.X, KeyA: B.Y, KeyQ: B.L, KeyW: B.R, Enter: B.START, NumpadEnter: B.START, Space: B.SELECT };

function deviceName() {
  var ua = navigator.userAgent || '';
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'iPad';
  if (/Android/.test(ua)) return /Mobile/.test(ua) ? 'Android phone' : 'Android tablet';
  if (/Macintosh/.test(ua)) return 'Mac';
  if (/Windows/.test(ua)) return 'Windows PC';
  return 'device';
}

function systemBadge(info) {
  return ({gameBoy:'GB', gameBoyColor:'GBC', gameBoyAdvance:'GBA', nes:'NES', pcEngine:'PCE', dos:'DOS', scummvm:'ScummVM'})[info.system] || info.systemName || '';
}

// H.264 through WebCodecs: the hardware decoder, frames drawn as soon as they're out. Only offered where the browser
// has it (Chrome: secure contexts only, so https or this Mac's own browser; Safari: also plain http://) and says it
// can decode these profiles; otherwise Media Source Extensions (below), else PNG/JPEG pictures as before. Level 4.0 covers every game screen at 60-70 fps and the top bitrates.
var H264_TESTS = { high: 'avc1.640028', main: 'avc1.4D4028', baseline: 'avc1.42E028' };
var videoCaps = null;
function mediaSource() { return window.ManagedMediaSource || window.MediaSource || null; }
function detectVideo(allowMSE) {
  if (videoCaps) return videoCaps;
  if (typeof VideoDecoder === 'undefined' || typeof EncodedVideoChunk === 'undefined' || !VideoDecoder.isConfigSupported) {
    // No WebCodecs (Chrome keeps it to secure contexts, and phones open the Mac over plain http://): H.264 through
    // Media Source Extensions instead. Not in Safari or any iPhone/iPad browser (all WebKit): there a <video> showed
    // about 14 of 60 frames a second this way (measured on macOS Safari 27), while Safari offers WebCodecs even
    // over http://, so it gets WebCodecs or pictures.
    var MS = mediaSource(), list = [], webkit = navigator.vendor === 'Apple Computer, Inc.';
    if (allowMSE && !webkit && MS && MS.isTypeSupported) {
      Object.keys(H264_TESTS).forEach(function (n) {
        try { if (MS.isTypeSupported('video/mp4; codecs="' + H264_TESTS[n] + '"')) list.push(n); } catch (e) {}
      });
    }
    videoCaps = Promise.resolve(list.length ? { h264: list, via: 'mse' } : null);
    return videoCaps;
  }
  var names = Object.keys(H264_TESTS);
  videoCaps = Promise.all(names.map(function (n) {
    return VideoDecoder.isConfigSupported({ codec: H264_TESTS[n], optimizeForLatency: true })
      .then(function (r) { return r && r.supported ? n : null; }, function () { return null; });
  })).then(function (list) {
    list = list.filter(Boolean);
    return list.length ? { h264: list } : null;
  }, function () { return null; });
  return videoCaps;
}

var current = null;

function Player(id, opts) {
  this.id = id;
  this.opts = opts || {};
  this.mode = this.opts.mode === 'controller' ? 'controller' : 'play';
  this.title = this.opts.title || '';
  this.info = null;
  this.ws = null;
  this.closing = false;
  this.state = 'connecting';
  this.sources = { touch: new Set(), key: new Set(), pad: new Set() };
  this.sent = new Set();
  this.pointers = new Map();
  this.zones = [];
  this.listeners = [];
  this.seen = 0; this.drawn = 0; this.lastDrawn = 0; this.decodeMs = 0; this.fps = 0; this.rtt = 0;
  this.server = null; this.decoding = 0; this.menuOpen = false; this.rightClick = false;
  this.everStarted = false; this.retryUntil = 0;
  // Pictures: 'image' (PNG/JPEG) or 'h264' (WebCodecs), as the Mac chose from what the hello offered.
  this.videoPath = 'image'; this.vdec = null; this.needKey = true; this.keyAsked = 0; this.decodeStart = new Map();
  this.gameH = 0; this.recvTotal = 0; this.drawnTotal = 0; this.skipped = 0;
  this.caps = this.mode === 'play' && this.opts.video !== 'image' ? detectVideo(this.opts.video !== 'webcodecs') : Promise.resolve(null);
  this.sound = this.mode === 'play' ? new Sound() : null;
  this.build();
  this.connect(false);
}

Player.prototype.on = function (target, type, fn, options) {
  target.addEventListener(type, fn, options);
  this.listeners.push([target, type, fn, options]);
};

// MARK: Screen

Player.prototype.build = function () {
  if (!document.getElementById('okplay-style')) {
    var style = el('style'); style.id = 'okplay-style'; style.textContent = CSS;
    document.head.appendChild(style);
  }
  var root = this.root = el('div', 'okplay-root' + (this.mode === 'controller' ? ' okp-ctl' : ''));
  root.setAttribute('role', 'application');
  var top = el('div', 'okp-top');
  var menu = el('button', 'okp-icon', this.mode === 'controller' ? 'Menu' : 'Ⅱ Pause');
  menu.setAttribute('aria-label', this.mode === 'controller' ? 'Controller menu' : 'Pause game');
  var self = this;
  menu.addEventListener('click', function () { self.openMenu(); });
  this.titleEl = el('div', 'okp-title', this.title || (this.mode === 'controller' ? 'Controller' : 'Starting…'));
  this.compass = el('span', 'okp-compass');
  this.compass.setAttribute('aria-hidden', 'true'); top.appendChild(this.compass);
  this.nameplate = el('div', 'okp-nameplate');
  this.nameplate.appendChild(this.titleEl);
  this.systemEl = el('span', 'okp-system'); this.systemEl.hidden = true; this.nameplate.appendChild(this.systemEl);
  top.appendChild(this.nameplate);
  this.menuButton = menu;
  if (this.mode === 'play') {
    // The connection indicator (good / OK / weak), from the Mac's adaptive quality; shown once the first stats come.
    this.linkEl = el('div', 'okp-link');
    this.linkEl.appendChild(el('i')); this.linkEl.appendChild(el('span'));
    this.linkEl.setAttribute('role', 'status');
    this.linkEl.hidden = true;
    top.appendChild(this.linkEl);
  }
  top.appendChild(menu);
  if (this.sound) {
    this.soundButton = el('button', 'okp-icon okp-sound', 'Mute');
    this.soundButton.setAttribute('aria-label', 'Mute sound');
    this.soundButton.addEventListener('click', function () { self.toggleSound(); });
    top.appendChild(this.soundButton);
  }
  this.top = top;
  root.appendChild(top);
  if (this.mode === 'play') {
    this.stage = el('div', 'okp-stage');
    this.canvas = el('canvas', 'okp-screen');
    this.canvas.width = 256; this.canvas.height = 240;
    this.g = this.canvas.getContext('2d');
    this.bezel = el('div', 'okp-bezel');
    this.bezel.appendChild(this.canvas); this.stage.appendChild(this.bezel);
    root.appendChild(this.stage);
  }
  this.pad = el('div', 'okp-pad');
  root.appendChild(this.pad);
  ['left', 'right'].forEach(function (side) { var vent = el('span', 'okp-vent okp-vent-' + side); vent.setAttribute('aria-hidden', 'true'); root.appendChild(vent); });
  this.saved = { overflow: document.documentElement.style.overflow };
  document.documentElement.style.overflow = 'hidden';
  // The page underneath isn't drawn while the player covers it: its lazy pictures' visibility checks otherwise ran on
  // every frame the game drew (over half the player's main-thread time on a slow phone). Scroll places are kept.
  document.documentElement.classList.add('okp-open');
  document.body.appendChild(root);
  this.on(window, 'resize', function () { self.layout(); });
  this.on(window, 'orientationchange', function () { setTimeout(function () { self.layout(); }, 250); });
  this.on(document, 'keydown', function (e) { self.key(e, true); }, true);
  this.on(document, 'keyup', function (e) { self.key(e, false); }, true);
  this.on(document, 'visibilitychange', function () { self.visibility(); });
  this.on(window, 'blur', function () { self.blurred = true; self.releaseKeys(); });
  this.on(window, 'focus', function () { self.blurred = false; });
  this.on(root, 'contextmenu', function (e) { e.preventDefault(); });
  this.on(root, 'touchmove', function (e) { if (!e.target.closest || !e.target.closest('.okp-sheet,.okp-extra')) e.preventDefault(); }, { passive: false });
  this.on(root, 'pointerdown', function () { if (self.sound) self.sound.wake(); });
  // No zooming while playing: Safari zooms on a quick second tap or a pinch, even over the controls' gaps.
  // Game buttons use pointer events, so cancelling the second tap's touchend never loses a button press.
  var lastTap = 0;
  this.on(root, 'touchend', function (e) {
    var now = Date.now();
    if (now - lastTap < 350 && (!e.target.closest || !e.target.closest('.okp-sheet'))) e.preventDefault();
    lastTap = now;
  }, { passive: false });
  this.on(document, 'dblclick', function (e) { e.preventDefault(); }, { passive: false });
  ['gesturestart', 'gesturechange', 'gestureend'].forEach(function (name) {
    self.on(document, name, function (e) { e.preventDefault(); }, { passive: false });
  });
  this.buildControls('pad');
  this.showVeil({ title: this.mode === 'controller' ? 'Connecting…' : 'Starting ' + (this.title || 'the game') + '…', spin: true,
                  actions: [{ label: 'Cancel', fn: function () { self.close(); } }] });
  this.raf = requestAnimationFrame(function loop() { self.tick(); self.raf = requestAnimationFrame(loop); });
  this.fpsTimer = setInterval(function () { self.countFrames(); }, 1000);
  this.layout();
};

Player.prototype.buildControls = function (layout) {
  var self = this, pad = this.pad;
  this.releaseKeys();
  this.layoutKind = layout;
  [this.stage, this.nameplate, this.compass, this.menuButton, this.soundButton].forEach(function (node) {
    if (node) node.style.cssText = '';
  });
  this.root.classList.toggle('okp-console', layout !== 'pointer');
  this.joystickPad = !!(layout === 'pointer' && this.info && this.info.joystick && this.joystickPad);
  this.root.classList.toggle('okp-pointer', layout === 'pointer' && !this.joystickPad);
  this.root.classList.toggle('okp-computer', layout === 'pointer');
  this.root.classList.remove('okp-keydeck');
  while (pad.firstChild) pad.removeChild(pad.firstChild);
  if (this.keysBar) { this.keysBar.remove(); this.keysBar = null; }
  if (this.hint) { this.hint.remove(); this.hint = null; }
  if (this.typer) { this.typer.remove(); this.typer = null; }
  this.softModifiers = new Set(); this.quickHeld = new Map(); this.quickButtons = [];
  this.zones = [];
  if (layout === 'pointer') {
    // DOS and ScummVM: the picture is the mouse; a row of keys (and the phone's keyboard) below.
    var bar = this.keysBar = el('div', 'okp-keys');
    var keyBtn = function (label, code, ch, container) {
      var b = el('button', 'okp-key', label);
      b.addEventListener('pointerdown', function (e) { e.preventDefault(); if (self.menuOpen) return; try { b.setPointerCapture(e.pointerId); } catch (x) {} self.quickHeld.set(code, b); self.sendKey(code, true, ch, self.softMods()); b.classList.add('okp-on'); });
      var up = function () { if (b.classList.contains('okp-on')) { b.classList.remove('okp-on'); self.quickHeld.delete(code); self.sendKey(code, false, 0, self.softMods()); } };
      b.addEventListener('pointerup', up); b.addEventListener('pointercancel', up); b.addEventListener('pointerleave', up);
      (container || bar).appendChild(b); self.quickButtons.push(b); return b;
    };
    var kb = el('button', 'okp-key', 'Keyboard');
    this.typer = el('input', 'okp-type');
    this.typer.setAttribute('aria-label', 'Game keyboard');
    this.typer.setAttribute('autocapitalize', 'off'); this.typer.setAttribute('autocomplete', 'off');
    this.typer.setAttribute('autocorrect', 'off'); this.typer.setAttribute('spellcheck', 'false');
    this.typer.addEventListener('input', function () { self.typed(); });
    kb.addEventListener('click', function () { self.typer.focus(); });
    bar.appendChild(kb);
    keyBtn('Esc', 27, 27); keyBtn('Enter', 13, 13); keyBtn('Space', 32, 32);
    keyBtn('←', 276, 0); keyBtn('↑', 273, 0); keyBtn('↓', 274, 0); keyBtn('→', 275, 0);
    var rc = el('button', 'okp-key', 'Right-click');
    rc.addEventListener('click', function () { self.rightClick = !self.rightClick; rc.classList.toggle('okp-on', self.rightClick); rc.setAttribute('aria-pressed', String(self.rightClick)); });
    rc.setAttribute('aria-pressed', 'false');
    this.rcButton = rc;
    bar.appendChild(rc);
    if (this.info && this.info.system === 'scummvm') keyBtn('Game menu · F5', 286, 0);
    var extra = el('details', 'okp-extra'); extra.appendChild(el('summary', null, 'More keys & mouse wheel'));
    var extraRow = el('div', 'okp-extra-row'); extra.appendChild(extraRow);
    ['Shift', 'Ctrl', 'Alt'].forEach(function (label, i) {
      var code = [304, 306, 308][i], b = el('button', 'okp-key', label); b.setAttribute('aria-pressed', 'false');
      b.addEventListener('click', function () { if (self.menuOpen) return; var down = !self.softModifiers.has(code);
        if (down) self.softModifiers.add(code); else self.softModifiers.delete(code);
        self.sendKey(code, down, 0, self.softMods()); b.classList.toggle('okp-on', down); b.setAttribute('aria-pressed', String(down)); });
      extraRow.appendChild(b); self.quickButtons.push(b);
    });
    [['Tab', 9], ['Backspace', 8], ['Delete', 127], ['Home', 278], ['End', 279], ['PgUp', 280], ['PgDn', 281]].forEach(function (k) { keyBtn(k[0], k[1], 0, extraRow); });
    for (var f = 1; f <= 12; f++) keyBtn('F' + f, 281 + f, 0, extraRow);
    [-1, 1].forEach(function (n) { var b = el('button', 'okp-key', n < 0 ? 'Wheel ↑' : 'Wheel ↓');
      b.addEventListener('click', function () { if (!self.menuOpen) self.sendBytes([8, n & 255]); }); extraRow.appendChild(b); });
    extra.addEventListener('toggle', function () {
      if (extra.open) self.releaseKeys();
      self.root.classList.toggle('okp-keydeck', extra.open); self.layout();
    }); bar.appendChild(extra);
    if (this.info && this.info.joystick) {
      var joy = el('button', 'okp-key', this.joystickPad ? 'Mouse & keys' : 'Joystick');
      joy.addEventListener('click', function () { self.joystickPad = !self.joystickPad; self.buildControls('pointer'); });
      bar.insertBefore(joy, bar.firstChild);
    }
    this.root.appendChild(bar);
    this.root.appendChild(this.typer);
    this.hint = el('div', 'okp-hint', this.pointerMode === 'relative'
      ? 'Drag on the picture to move the mouse. Tap to click; tap with two fingers to right-click.'
      : 'Tap the picture to click there. Turn on Right-click for the next tap.');
    this.root.insertBefore(this.hint, bar);
    this.pad.style.display = 'none';
    this.bindCanvasPointer();
    this.layout();
    if (!this.joystickPad) return;
  }
  this.pad.style.display = '';
  var dpad = el('div', 'okp-dpad');
  dpad.appendChild(el('i', 'okp-h')); dpad.appendChild(el('i', 'okp-v'));
  var arrows = {};
  [[B.UP, 52, 0], [B.DOWN, 52, 104], [B.LEFT, 0, 52], [B.RIGHT, 104, 52]].forEach(function (a) {
    var b = el('b', null, ({4:'▲',5:'▼',6:'◀',7:'▶'})[a[0]]); b.style.left = a[1] + 'px'; b.style.top = a[2] + 'px'; dpad.appendChild(b); arrows[a[0]] = b;
  });
  pad.appendChild(dpad);
  this.zones.push({ kind: 'dpad', el: dpad, parts: arrows });
  var face = function (label, button, cls) {
    var b = el('div', 'okp-btn ' + cls, label); pad.appendChild(b);
    self.zones.push({ kind: 'btn', el: b, button: button });
    return b;
  };
  var pce = this.info && this.info.system === 'pcEngine';
  var atari = this.info && this.info.system === 'atari2600';
  this.btnA = face(pce ? 'I' : atari ? 'Fire' : 'A', atari ? B.B : B.A, 'okp-a');
  this.btnB = atari ? null : face(pce ? 'II' : 'B', B.B, 'okp-b');
  var pill = function (label, button) {
    var b = el('div', 'okp-pill', label); pad.appendChild(b);
    self.zones.push({ kind: 'btn', el: b, button: button, pill: true });
    return b;
  };
  this.btnSelect = pill('Select', B.SELECT);
  this.btnStart = pill(pce ? 'Run' : 'Start', B.START);
  if (layout === 'pad-shoulders') { this.btnL = pill('L', B.L); this.btnR = pill('R', B.R); } else { this.btnL = this.btnR = null; }
  if (!this.padBound) {
    this.padBound = true;
    var handler = function (e) { self.padPointer(e); };
    ['pointerdown', 'pointermove', 'pointerup', 'pointercancel'].forEach(function (t) { self.on(self.pad, t, handler); });
  }
  this.layout();
};

Player.prototype.layout = function () {
  var root = this.root; if (!root) return;
  if (this.layoutKind !== 'pointer') { this.layoutConsole(); return; }
  var style = getComputedStyle(root), insetX = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight),
    insetY = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
  var W = root.clientWidth - insetX, H = root.clientHeight - insetY;
  var land = W > H * 1.1;
  root.classList.toggle('okp-land', land);
  var keysH = this.keysBar ? this.keysBar.offsetHeight : 0;
  var hintH = this.hint && !land ? this.hint.offsetHeight : 0;
  var topH = this.top.offsetHeight;
  root.style.setProperty('--okp-top-height', topH + 'px');
  if (this.canvas) {
    var aspect = (this.info && this.info.aspect) || (this.canvas.width / this.canvas.height);
    // Keep the actual system shape and reserve separate thumb rails in landscape.
    var usesPad = this.layoutKind !== 'pointer' || this.joystickPad;
    var availW = land && usesPad ? W - 376 : W - 48;
    var availH = land ? H - topH - keysH - 40 : this.layoutKind === 'pointer'
      ? (usesPad ? Math.min(H * 0.42, H - topH - keysH - hintH - 260) : H - topH - keysH - hintH - 32)
      : Math.min(H * 0.50, H - topH - (this.layoutKind === 'pad-shoulders' ? 300 : 260));
    availW = Math.max(60, availW); availH = Math.max(40, availH);
    var h = Math.min(availH, availW / aspect);
    // Whole-number scaling keeps every game pixel the same size, when that costs little of the space (counted in
    // game pixels: an H.264 picture may be doubled).
    var dpr = window.devicePixelRatio || 1, fh = this.gameH || this.canvas.height;
    var k = Math.floor(h * dpr / fh);
    if (k >= 1 && (k * fh / dpr) >= h * 0.86) h = k * fh / dpr;
    this.canvas.style.width = Math.round(h * aspect) + 'px';
    this.canvas.style.height = Math.round(h) + 'px';
    this.stage.style.height = land ? '' : Math.round(h + 32) + 'px';
    if (land) this.stage.style.bottom = (keysH + 16) + 'px'; else this.stage.style.bottom = '';
    if (this.mse) this.mse.place();
  }
  if ((this.layoutKind === 'pointer' && !this.joystickPad) || !this.zones.length) return;
  var pw = this.pad.clientWidth, ph = this.pad.clientHeight;
  if (land && this.joystickPad) ph -= keysH;
  var place = function (e, x, y) { if (e) { e.style.left = Math.round(x) + 'px'; e.style.top = Math.round(y) + 'px'; } };
  var dpad = this.zones[0].el;
  var side = land ? 14 : Math.max(12, Math.min(28, (pw - 320) / 2));
  var padScale = land && this.joystickPad ? Math.max(0.7, Math.min(1, (ph - 58) / 156)) : 1;
  var radius = 78 * padScale;
  dpad.style.transformOrigin = 'top left'; dpad.style.transform = 'scale(' + padScale + ')';
  var cy = land ? Math.max(radius, Math.min(ph - 58 - radius, ph * 0.48))
    : Math.max(this.btnL ? 130 : 90, Math.min(ph - 82, ph * 0.45));
  place(dpad, side, cy - radius);
  place(this.btnA, pw - side - 66, cy - 66);
  place(this.btnB, pw - side - 140, cy - 4);
  var pillY = Math.min(ph - 44, cy + 92);
  if (land) {
    place(this.btnSelect, side + 4, pillY);
    place(this.btnStart, pw - side - 76, pillY);
  } else {
    place(this.btnSelect, pw / 2 - 84, pillY);
    place(this.btnStart, pw / 2 + 12, pillY);
  }
  if (this.btnL) {
    var shoulderY = Math.max(0, cy - 130);
    place(this.btnL, side, shoulderY); place(this.btnR, pw - side - 72, shoulderY);
  }
  for (var i = 0; i < this.zones.length; i++) this.zones[i].rect = this.zones[i].el.getBoundingClientRect();
};

// The console silhouette follows the approved Field Console: nameplate above the bezel,
// directional rail on the left, stacked utility buttons and staggered action buttons on the right.
// All game buttons remain children of pad, keeping pointer capture and multi-touch unchanged.
Player.prototype.layoutConsole = function () {
  var root = this.root, style = getComputedStyle(root);
  var ix = parseFloat(style.paddingLeft) || 0, iy = parseFloat(style.paddingTop) || 0;
  var W = root.clientWidth - ix - (parseFloat(style.paddingRight) || 0);
  var H = root.clientHeight - iy - (parseFloat(style.paddingBottom) || 0);
  var land = W > H * 1.1;
  root.classList.toggle('okp-land', land);
  // max-height centers a compact portrait enclosure rather than stretching its controller deck.
  H = root.clientHeight - iy - (parseFloat(getComputedStyle(root).paddingBottom) || 0);
  var shoulder = !!this.btnL, compactLand = land && H < 350, utilityBelow = shoulder || compactLand;
  var dp = land ? (utilityBelow ? 132 : 148) : (W < 330 ? 132 : 148);
  var face = land ? (compactLand ? 68 : 80) : (W < 330 ? 66 : 78), rail = land ? Math.max(166, dp + 34) : 0;
  var self = this;
  function put(e, x, y, w, h) {
    if (!e) return;
    e.style.left = Math.round(ix + x) + 'px'; e.style.top = Math.round(iy + y) + 'px';
    if (w != null) e.style.width = Math.round(w) + 'px';
    if (h != null) e.style.height = Math.round(h) + 'px';
  }
  function screen(maxW, maxH, top) {
    var aspect = (self.info && self.info.aspect) || (self.canvas.width / self.canvas.height);
    // The enclosure has a broad display well; each system keeps its own picture shape inside it.
    var displayAspect = Math.max(4 / 3, aspect);
    var h = Math.max(40, Math.min(maxH, maxW / displayAspect));
    var dpr = window.devicePixelRatio || 1, pixels = self.canvas.height;
    var scale = Math.floor(h * dpr / pixels);
    if (scale >= 1 && scale * pixels / dpr >= h * .92) h = scale * pixels / dpr;
    var w = Math.round(h * aspect); h = Math.round(h);
    self.canvas.style.width = w + 'px'; self.canvas.style.height = h + 'px';
    var displayWidth = Math.round(h * displayAspect);
    put(self.stage, (W - displayWidth - 30) / 2, top, displayWidth + 30, h + 30);
    self.bezel.style.width = displayWidth + 30 + 'px'; self.bezel.style.height = h + 30 + 'px';
    return h + 30;
  }
  if (this.canvas) {
    if (land) {
      screen(W - rail * 2 - 44, H - (utilityBelow ? 166 : 104), 66);
      var bezelWidth = this.stage.offsetWidth;
      put(this.nameplate, (W - bezelWidth) / 2 + 3, 16, bezelWidth - 6, 35);
    } else {
      put(this.nameplate, 20, 16, W - 40, 36);
    }
  } else { put(this.nameplate, land ? rail + 10 : 20, 18, land ? W - rail * 2 - 20 : W - 40, 36); }
  var dx, dy, actionY, selectY, utilityY;
  if (land) {
    dx = (rail - dp) / 2;
    dy = utilityBelow ? H - dp - 76 : H - dp - 138;
    actionY = utilityBelow ? dy + 4 : Math.max(154, H - face * 2 - 40);
    put(this.compass, rail / 2 - (compactLand ? 20 : 27), 18, compactLand ? 40 : 54, compactLand ? 40 : 54);
    if (utilityBelow) {
      var utilityWidth = Math.max(66, Math.min(110, (W - rail * 2 - 18) / 2));
      put(this.menuButton, W / 2 - utilityWidth - 6, H - 56, utilityWidth, 44);
      put(this.soundButton, W / 2 + 6, H - 56, utilityWidth, 44);
    } else {
      put(this.menuButton, W - rail + 22, 20, rail - 44, 44);
      put(this.soundButton, W - rail + 22, 74, rail - 44, 44);
    }
    put(this.btnA, W - 22 - face, actionY, face, face);
    put(this.btnB, W - rail + 12, actionY + face * .78, face, face);
    if (utilityBelow) {
      if (shoulder) {
        put(this.btnL, rail / 2 - 42, dy - 52, 84, 44);
        put(this.btnR, W - rail / 2 - 42, dy - 52, 84, 44);
      }
      selectY = dy + dp + 16;
      put(this.btnSelect, 10, selectY, (rail - 28) / 2, 44);
      put(this.btnStart, rail / 2 + 4, selectY, (rail - 28) / 2, 44);
    } else {
      put(this.btnSelect, rail / 2 - 48, dy + dp + 18, 96, 44);
      put(this.btnStart, rail / 2 - 48, dy + dp + 72, 96, 44);
    }
  } else {
    var deckHeight = dp + 44 + 44 + 78 + (shoulder ? 50 : 0);
    var bottom = this.canvas ? 72 + screen(W - 62, H - 72 - deckHeight - 30, 72)
      : Math.max(82 + (this.ctlHint ? this.ctlHint.offsetHeight : 0), H * .36);
    dy = bottom + 22 + (shoulder ? 50 : 0); dx = 18;
    var maxDeckY = H - dp - 44 - 44 - 64;
    dy = Math.min(dy, maxDeckY);
    actionY = dy + 10;
    put(this.btnA, W - 18 - face, actionY, face, face);
    put(this.btnB, W - 18 - face * 1.92, actionY + face * .76, face, face);
    selectY = dy + dp + 18; utilityY = selectY + 56;
    put(this.btnSelect, 24, selectY, (W - 62) / 2, 44);
    put(this.btnStart, W / 2 + 7, selectY, (W - 62) / 2, 44);
    put(this.menuButton, 24, utilityY, (W - 62) / 2, 44);
    put(this.soundButton, W / 2 + 7, utilityY, (W - 62) / 2, 44);
    put(this.compass, W / 2 - 20, dy + dp / 2 - 22, 40, 40);
    if (shoulder) { put(this.btnL, 20, dy - 52, 82, 44); put(this.btnR, W - 102, dy - 52, 82, 44); }
  }
  if (this.ctlHint) {
    put(this.ctlHint, land ? rail + 16 : 24, land ? 58 : 64, land ? W - rail * 2 - 32 : W - 48);
  }
  if (this.zones.length) {
    var dpad = this.zones[0].el;
    dpad.style.transform = ''; put(dpad, dx, dy, dp, dp);
    [[B.UP, 1, 0], [B.DOWN, 1, 2], [B.LEFT, 0, 1], [B.RIGHT, 2, 1]].forEach(function (a) {
      var part = self.zones[0].parts[a[0]];
      part.style.left = a[1] * dp / 3 + 'px'; part.style.top = a[2] * dp / 3 + 'px';
    });
  }
  this.zones.forEach(function (z) { z.rect = z.el.getBoundingClientRect(); });
};

// MARK: Touch controls

Player.prototype.padPointer = function (e) {
  if (this.menuOpen) return;
  e.preventDefault();
  if (e.type === 'pointerdown') { try { this.pad.setPointerCapture(e.pointerId); } catch (x) {} }
  if (e.type === 'pointerup' || e.type === 'pointercancel') this.pointers.delete(e.pointerId);
  else if (e.type === 'pointerdown' || this.pointers.has(e.pointerId)) this.pointers.set(e.pointerId, this.hit(e.clientX, e.clientY));
  var pressed = new Set();
  this.pointers.forEach(function (set) { set.forEach(function (b) { pressed.add(b); }); });
  this.sources.touch = pressed;
  this.sync();
};

// The buttons under a finger: the nearest button within a generous margin, or the d-pad's direction(s).
Player.prototype.hit = function (x, y) {
  var out = new Set();
  // A real button wins over the d-pad's generous surrounding touch margin (notably L/R and Select).
  for (var n = 0; n < this.zones.length; n++) {
    var direct = this.zones[n], box = direct.rect;
    if (direct.kind === 'btn' && box && x >= box.left && x <= box.right && y >= box.top && y <= box.bottom) {
      out.add(direct.button); return out;
    }
  }
  for (var i = 0; i < this.zones.length; i++) {
    var z = this.zones[i], r = z.rect; if (!r) continue;
    if (z.kind === 'dpad') {
      var cx = r.left + r.width / 2, cy = r.top + r.height / 2, dx = x - cx, dy = y - cy;
      var dist = Math.hypot(dx, dy);
      if (dist > r.width * 0.75 || dist < 10) continue;
      var angle = Math.atan2(-dy, dx) * 180 / Math.PI;
      if (angle > 22.5 && angle < 157.5) out.add(B.UP);
      if (angle < -22.5 && angle > -157.5) out.add(B.DOWN);
      if (Math.abs(angle) > 112.5) out.add(B.LEFT);
      if (Math.abs(angle) < 67.5) out.add(B.RIGHT);
      return out;
    }
  }
  var best = null, bestD = 1e9;
  for (var j = 0; j < this.zones.length; j++) {
    var zz = this.zones[j], rr = zz.rect; if (!rr || zz.kind !== 'btn') continue;
    var margin = zz.pill ? 10 : 18;
    if (x < rr.left - margin || x > rr.right + margin || y < rr.top - margin || y > rr.bottom + margin) continue;
    var d = Math.hypot(x - (rr.left + rr.width / 2), y - (rr.top + rr.height / 2));
    if (d < bestD) { bestD = d; best = zz; }
  }
  if (best) out.add(best.button);
  return out;
};

// Sends the difference between what's held (touch, keyboard and game controller together) and what was sent.
Player.prototype.sync = function () {
  var want = new Set(), s = this.sources, self = this;
  [s.touch, s.key, s.pad].forEach(function (set) { set.forEach(function (b) { want.add(b); }); });
  want.forEach(function (b) { if (!self.sent.has(b)) self.sendButton(b, true); });
  this.sent.forEach(function (b) { if (!want.has(b)) self.sendButton(b, false); });
  this.sent = want;
  this.zones.forEach(function (z) {
    if (z.kind === 'dpad') DIRS.forEach(function (d) { z.parts[d].classList.toggle('okp-on', want.has(d)); });
    else z.el.classList.toggle('okp-on', want.has(z.button));
  });
};

Player.prototype.releaseKeys = function () {
  this.sources.key = new Set(); this.sources.touch = new Set(); this.sources.pad = new Set(); this.pointers.clear();
  this.sync();
  if (this.quickHeld) this.quickHeld.clear();
  if (this.softModifiers) this.softModifiers.clear();
  (this.quickButtons || []).forEach(function (b) { b.classList.remove('okp-on'); if (b.hasAttribute('aria-pressed')) b.setAttribute('aria-pressed', 'false'); });
  this.rightClick = false;
  if (this.rcButton) { this.rcButton.classList.remove('okp-on'); this.rcButton.setAttribute('aria-pressed', 'false'); }
  if (this.releasePointer) this.releasePointer();
  this.sendBytes([6]);
};

// MARK: Pointer (DOS and ScummVM)

Player.prototype.bindCanvasPointer = function () {
  if (this.canvasBound) return;
  this.canvasBound = true;
  var self = this, c = this.canvas, touches = new Map(), maxTouches = 0, start = 0, moved = 0, last = null, mouseDown = 0;
  this.releasePointer = function () { touches.clear(); maxTouches = 0; start = moved = mouseDown = 0; last = null; };
  var scale = function () {
    var r = c.getBoundingClientRect();
    return { r: r, sx: c.width / r.width, sy: c.height / r.height };
  };
  var abs = function (e) {
    var r = c.getBoundingClientRect();
    self.sendFloats(4, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
  };
  var click = function (button) {
    self.sendBytes([5, button, 1]);
    setTimeout(function () { self.sendBytes([5, button, 0]); }, 70);
  };
  this.on(c, 'pointerdown', function (e) {
    e.preventDefault();
    if (self.menuOpen) return;
    try { c.setPointerCapture(e.pointerId); } catch (x) {}
    if (e.pointerType === 'mouse') {
      var button = e.button === 2 ? 1 : e.button === 1 ? 2 : 0;
      if (self.pointerMode === 'absolute') abs(e);
      self.sendBytes([5, button, 1]); mouseDown |= 1 << button;
      last = { x: e.clientX, y: e.clientY };
      return;
    }
    touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (touches.size === 1) { start = performance.now(); moved = 0; maxTouches = 1; last = { x: e.clientX, y: e.clientY }; }
    maxTouches = Math.max(maxTouches, touches.size);
    if (self.pointerMode === 'absolute' && touches.size === 1) {
      abs(e);
      if (!self.rightClick) { self.sendBytes([5, 0, 1]); mouseDown |= 1; }
    }
  });
  this.on(c, 'pointermove', function (e) {
    if (self.menuOpen) return;
    if (e.pointerType === 'mouse') {
      if (self.pointerMode === 'absolute') abs(e);
      else if (last) {
        var s1 = scale();
        self.sendFloats(3, (e.clientX - last.x) * s1.sx, (e.clientY - last.y) * s1.sy);
      }
      last = { x: e.clientX, y: e.clientY };
      return;
    }
    var t = touches.get(e.pointerId); if (!t) return;
    var first = touches.keys().next().value === e.pointerId;
    if (first) {
      moved += Math.hypot(e.clientX - t.x, e.clientY - t.y);
      if (self.pointerMode === 'absolute') abs(e);
      else {
        // A touchpad: finger movement, a little faster than the picture, moves the mouse.
        var s2 = scale();
        self.sendFloats(3, (e.clientX - t.x) * s2.sx * 1.6, (e.clientY - t.y) * s2.sy * 1.6);
      }
    }
    t.x = e.clientX; t.y = e.clientY;
  });
  var end = function (e) {
    if (e.pointerType === 'mouse') {
      var button = e.button === 2 ? 1 : e.button === 1 ? 2 : 0;
      if (mouseDown & (1 << button)) { self.sendBytes([5, button, 0]); mouseDown &= ~(1 << button); }
      return;
    }
    if (!touches.has(e.pointerId)) return;
    touches.delete(e.pointerId);
    if (touches.size > 0) return;
    var quick = performance.now() - start < 300 && moved < 12;
    if (self.pointerMode === 'absolute') {
      if (mouseDown & 1) { self.sendBytes([5, 0, 0]); mouseDown &= ~1; }
      else if (self.rightClick && e.type !== 'pointercancel') { click(1); self.rightClick = false; if (self.rcButton) { self.rcButton.classList.remove('okp-on'); self.rcButton.setAttribute('aria-pressed', 'false'); } }
    } else if (quick && e.type !== 'pointercancel') {
      var right = maxTouches >= 2 || self.rightClick;
      click(right ? 1 : 0);
      if (self.rightClick) { self.rightClick = false; if (self.rcButton) { self.rcButton.classList.remove('okp-on'); self.rcButton.setAttribute('aria-pressed', 'false'); } }
    }
  };
  this.on(c, 'pointerup', end);
  this.on(c, 'pointercancel', end);
  this.on(c, 'wheel', function (e) { e.preventDefault(); var n = Math.max(-5, Math.min(5, Math.round(e.deltaY / 50))); if (n) self.sendBytes([8, n & 255]); }, { passive: false });
};

// Letters typed on the phone's own keyboard (the hidden field), sent as key presses.
Player.prototype.typed = function () {
  var text = this.typer.value; this.typer.value = '';
  for (var i = 0; i < text.length; i++) {
    var ch = text[i], code = keyForText(ch);
    if (!code) continue;
    var shift = ch !== ch.toLowerCase() || !!SHIFTED[ch];
    var flags = this.softMods() | (shift ? 1 : 0), ownShift = shift && !(this.softModifiers && this.softModifiers.has(304));
    if (ownShift) this.sendKey(304, true, 0, flags);
    this.sendKey(code, true, ch.codePointAt(0), flags);
    this.sendKey(code, false, 0, flags);
    if (ownShift) this.sendKey(304, false, 0, this.softMods());
  }
};

Player.prototype.key = function (e, down) {
  if (!this.root || this.menuOpen) return;
  if (e.target && e.target.closest && e.target.closest('.okp-sheet')) return;
  if (e.metaKey && !(this.layoutKind === 'pointer')) return;   // ⌘-shortcuts stay with the browser
  if (this.mode === 'play' && this.layoutKind === 'pointer' && this.state === 'playing') {
    var code = retroKey(e);
    if (!code) return;
    e.preventDefault(); e.stopPropagation();
    if (e.repeat && down) return;
    this.sendKey(code, down, down ? charFor(e.key) : 0, mods(e) | this.softMods());
    return;
  }
  if (down && e.code === 'Escape' && this.mode === 'play') { e.preventDefault(); this.openMenu(); return; }
  var button = PAD_KEYS[e.code];
  if (this.info && this.info.system === 'atari2600' && button === B.A) button = B.B;
  if (button == null) return;
  e.preventDefault(); e.stopPropagation();
  if (down) this.sources.key.add(button); else this.sources.key.delete(button);
  this.sync();
};

// MARK: Game controllers

Player.prototype.countFrames = function () {
  var now = performance.now();
  if (this.fpsAt && !this.menuOpen) this.fps = this.drawn * 1000 / (now - this.fpsAt);
  this.drawn = 0; this.fpsAt = now;
  if (this.menuOpen) this.updateStats();
};

Player.prototype.tick = function () {
  if (!navigator.getGamepads || this.menuOpen || this.blurred || document.hidden) return;
  var pads; try { pads = navigator.getGamepads(); } catch (e) { return; }
  var held = new Set(), menu = false;
  for (var i = 0; i < (pads ? pads.length : 0); i++) {
    var p = pads[i]; if (!p || !p.connected) continue;
    var b = p.buttons, pr = function (n) { return b[n] && (b[n].pressed || b[n].value > 0.5); };
    // Nintendo layout, as on the Mac: the bottom face button is B, the right one A.
    if (pr(0)) held.add(B.B); if (pr(1)) held.add(B.A); if (pr(2)) held.add(B.Y); if (pr(3)) held.add(B.X);
    if (pr(4) || pr(6)) held.add(B.L); if (pr(5) || pr(7)) held.add(B.R);
    if (pr(8)) held.add(B.SELECT); if (pr(9)) held.add(B.START);
    if (pr(12)) held.add(B.UP); if (pr(13)) held.add(B.DOWN); if (pr(14)) held.add(B.LEFT); if (pr(15)) held.add(B.RIGHT);
    if (pr(16)) menu = true;
    var x = p.axes[0] || 0, y = p.axes[1] || 0;
    if (Math.hypot(x, y) > 0.4) {
      var angle = Math.atan2(-y, x) * 180 / Math.PI;
      if (angle > 22.5 && angle < 157.5) held.add(B.UP);
      if (angle < -22.5 && angle > -157.5) held.add(B.DOWN);
      if (Math.abs(angle) > 112.5) held.add(B.LEFT);
      if (Math.abs(angle) < 67.5) held.add(B.RIGHT);
    }
  }
  if (menu && this.mode === 'play') { this.openMenu(); return; }
  var changed = held.size !== this.sources.pad.size;
  if (!changed) held.forEach(function (v) { if (!this.sources.pad.has(v)) changed = true; }, this);
  if (changed) { this.sources.pad = held; this.sync(); }
};

// MARK: Connection

Player.prototype.connect = function (retry) {
  var self = this;
  var ws;
  try { ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/play/socket'); }
  catch (e) { this.fail('Couldn’t connect', 'This browser can’t open a connection to the Mac.'); return; }
  ws.binaryType = 'arraybuffer';
  this.ws = ws;
  ws.onopen = function () {
    // What this browser can decode goes in the hello; the check takes a moment the first time (at most half a second).
    var timeout = new Promise(function (r) { setTimeout(function () { r(null); }, 500); });
    Promise.race([self.caps, timeout]).then(function (caps) {
      if (self.ws !== ws || ws.readyState !== 1) return;
      var hello = { t: 'hello', mode: self.mode, id: self.id, resume: !!self.opts.resume || retry, takeover: !!self.takeover, device: deviceName() };
      if (caps) hello.video = caps;
      self.takeover = false;
      ws.send(JSON.stringify(hello));
      clearInterval(self.pinger);
      self.pinger = setInterval(function () { self.ping(); }, 2000);
      self.ping();
    });
  };
  ws.onmessage = function (e) {
    if (typeof e.data === 'string') { var m; try { m = JSON.parse(e.data); } catch (x) { return; } self.message(m); }
    else self.binary(e.data);
  };
  ws.onclose = function (e) {
    clearInterval(self.pinger);
    if (self.ws !== ws || self.closing) return;
    self.ws = null;
    // Signed out: the Mac usually says why just before closing ("Signed out", "The PIN was changed"); keep that.
    if (e.code === 4401 || e.code === 1008) {
      if (self.state !== 'ended') self.fail('Sign in again', 'Open Offline Kit on this device and enter the PIN, then try again.');
      return;
    }
    // Dropped (Wi-Fi blip, the phone slept): the Mac pauses and saves, and waits a few minutes for us.
    if ((self.state === 'playing' || self.state === 'reconnecting' || (self.mode === 'controller' && self.everStarted))) {
      if (self.state !== 'reconnecting') { self.state = 'reconnecting'; self.retryUntil = Date.now() + 170000; }
      if (Date.now() > self.retryUntil) { self.fail('Lost the connection', 'The Mac stopped waiting. Your place was saved; open the game again to carry on.'); return; }
      self.showVeil({ title: 'Reconnecting to the Mac…', text: 'The game is paused and saved meanwhile.', spin: true,
                      actions: [{ label: 'Close', fn: function () { self.close(); } }] });
      self.retryTimer = setTimeout(function () { self.connect(true); }, 1500);
    } else if (self.state === 'connecting') {
      self.fail('Couldn’t reach the Mac', 'Check that this device is on the same Wi-Fi as the Mac and sharing is on.');
    }
  };
};

// The check-in every 2 seconds: also how long this device takes to decode a frame, for the Mac's quality choice.
Player.prototype.ping = function () {
  // Not through a <video>: there it's arrival to shown, mostly the wait for the screen's next refresh.
  this.sendJSON({ t: 'ping', ts: performance.now(), dec: this.mse ? null : Math.round(this.decodeMs * 100) / 100 });
};
Player.prototype.sendJSON = function (o) { if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(o)); };
Player.prototype.sendBytes = function (arr) { if (this.ws && this.ws.readyState === 1) this.ws.send(new Uint8Array(arr)); };
Player.prototype.sendButton = function (b, down) { this.sendBytes([1, b, down ? 1 : 0]); };
Player.prototype.sendFloats = function (kind, a, b) {
  if (!this.ws || this.ws.readyState !== 1) return;
  var buf = new ArrayBuffer(9), v = new DataView(buf);
  v.setUint8(0, kind); v.setFloat32(1, a, true); v.setFloat32(5, b, true);
  this.ws.send(buf);
};
Player.prototype.sendKey = function (code, down, ch, m) {
  if (!this.ws || this.ws.readyState !== 1) return;
  var buf = new ArrayBuffer(10), v = new DataView(buf);
  v.setUint8(0, 2); v.setUint8(1, down ? 1 : 0); v.setUint16(2, code, true); v.setUint32(4, ch || 0, true); v.setUint16(8, m || 0, true);
  this.ws.send(buf);
};

Player.prototype.message = function (m) {
  var self = this;
  switch (m.t) {
  case 'started':
    this.info = m; this.state = 'playing'; this.everStarted = true;
    this.title = m.title; this.titleEl.textContent = m.title;
    this.systemEl.textContent = systemBadge(m); this.systemEl.title = m.systemName || ''; this.systemEl.hidden = !m.systemName;
    this.pointerMode = m.pointer;
    var layout = m.layout || 'pad';
    this.buildControls(layout);
    if (this.sound) { this.sound.start(m.sampleRate); this.sound.clear(); }
    this.videoPath = m.video === 'h264' ? 'h264' : 'image';
    this.lastDrawn = 0;   // numbering starts again with each connection's first picture
    if (this.videoPath === 'image') this.closeDecoder();
    this.hideVeil();
    this.sent = new Set(); this.sync();
    this.layout();
    if (m.resumed && this.reconnected) this.toast('Back in the game');
    this.reconnected = true;
    break;
  case 'controller':
    this.state = 'playing'; this.everStarted = true;
    this.hideVeil();
    this.controllerInfo(m);
    break;
  case 'busy':
    this.state = 'busy';
    this.showVeil({ title: m.text || ('The Mac is playing ' + m.title + '.'),
      text: m.where === 'mac' ? 'Take over to play here instead. The Mac saves its place and closes the game first.'
          : 'Take over to play here instead. The other device’s place is saved first.',
      actions: [{ label: 'Take over', main: true, fn: function () { self.takeOver(); } },
                { label: 'Cancel', fn: function () { self.close(); } }] });
    break;
  case 'ended':
    if (m.reason === 'quit') return;
    this.state = 'ended';
    this.showVeil({ title: m.reason === 'finished' ? 'The game has ended' : 'The game stopped', text: m.text || '',
                    actions: [{ label: 'Close', main: true, fn: function () { self.close(); } }] });
    break;
  case 'error':
    this.fail(m.title || 'Something went wrong', m.message || '');
    break;
  case 'toast':
    this.toast(m.text);
    break;
  case 'pong':
    if (typeof m.ts === 'number') this.rtt = performance.now() - m.ts;
    if (this.mode === 'controller') this.controllerInfo(m);
    break;
  case 'stats':
    if (!this.menuOpen) { this.server = m; this.showLink(m); }   // while paused nothing is sent; keep the numbers from playing
    break;
  case 'nogame':
    this.controllerInfo({ title: null });
    break;
  }
};

Player.prototype.ack = function (seq) {
  this.sendBytes([7, seq & 255, (seq >> 8) & 255, (seq >> 16) & 255, (seq >>> 24) & 255]);
};

Player.prototype.binary = function (buf) {
  var v = new DataView(buf), type = v.getUint8(0), self = this;
  if (type === 2) { if (this.sound && !this.menuOpen) this.sound.push(buf.slice(1)); return; }
  if (type === 5) { this.videoConfig(buf); return; }
  if (type === 4) { this.videoChunk(buf); return; }
  if (type !== 1 && type !== 3) return;
  var seq = v.getUint32(1, true), encode = v.getUint16(5, true) / 10, w = v.getUint16(7, true), h = v.getUint16(9, true);
  this.seen = seq; this.encodeMs = encode; this.recvTotal++;
  var blob = new Blob([new Uint8Array(buf, 11)], { type: type === 1 ? 'image/jpeg' : 'image/png' });
  var t0 = performance.now();
  var done = function () { self.ack(seq); };
  createImageBitmap(blob).then(function (bmp) {
    if (seq > self.lastDrawn && self.canvas) {
      self.lastDrawn = seq;
      if (self.canvas.width !== w || self.canvas.height !== h || self.gameH) {
        self.canvas.width = w; self.canvas.height = h; self.gameH = 0; self.layout();
      }
      self.g.imageSmoothingEnabled = false;
      self.g.drawImage(bmp, 0, 0);
      self.drawn++; self.drawnTotal++;
      self.decodeMs = self.decodeMs * 0.9 + (performance.now() - t0) * 0.1;
    } else self.skipped++;
    if (bmp.close) bmp.close();
    done();
  }, done);
};

// MARK: H.264 (WebCodecs)

// [5][u16 coded w][u16 coded h][u16 game w][u16 game h][u8 n][codec][avcC]: (re)configures the decoder. It comes just
// before the keyframe it describes.
Player.prototype.videoConfig = function (buf) {
  var v = new DataView(buf), self = this;
  if (buf.byteLength < 10) { this.videoFailed(); return; }
  var cw = v.getUint16(1, true), ch = v.getUint16(3, true), gh = v.getUint16(7, true), n = v.getUint8(9);
  var codec = String.fromCharCode.apply(null, new Uint8Array(buf, 10, n));
  if (typeof VideoDecoder === 'undefined') {
    if (!mediaSource()) { this.videoFailed(); return; }
    if (!this.mse) this.mse = new MSEVideo(this);
    this.mse.configure(codec, new Uint8Array(buf.slice(10 + n)), cw, ch);
    this.videoPath = 'h264'; this.needKey = true; this.gameH = gh;
    if (this.canvas.width !== cw || this.canvas.height !== ch) { this.canvas.width = cw; this.canvas.height = ch; }
    this.layout();
    return;
  }
  var config = { codec: codec, description: new Uint8Array(buf.slice(10 + n)), codedWidth: cw, codedHeight: ch,
                 optimizeForLatency: true };
  try {
    if (!this.vdec || this.vdec.state === 'closed') {
      this.vdec = new VideoDecoder({ output: function (f) { self.videoFrame(f); }, error: function (e) { self.videoError(e); } });
    }
    this.vdec.configure(config);
  } catch (e) { this.videoFailed(); return; }
  this.videoPath = 'h264'; this.needKey = true; this.decodeStart.clear();
  this.gameH = gh;
};

// [4][u32 seq][u16 encode][u16 w][u16 h][u8 flags: 1 = keyframe][AVCC]. Every chunk is decoded (each frame builds on
// the one before); a frame is acknowledged once drawn, or right away when it can't be used.
Player.prototype.videoChunk = function (buf) {
  var v = new DataView(buf);
  var seq = v.getUint32(1, true), key = (v.getUint8(11) & 1) !== 0;
  this.seen = seq; this.encodeMs = v.getUint16(5, true) / 10; this.recvTotal++;
  if (this.videoPath === 'image') { this.ack(seq); return; }   // gave up on H.264: the last few still on their way
  if (this.mse) {
    if (this.needKey && !key) { this.askKeyframe(); this.ack(seq); return; }
    this.needKey = false;
    this.mse.frame(seq, key, new Uint8Array(buf, 12));
    return;
  }
  var dec = this.vdec;
  if (!dec || dec.state !== 'configured' || (this.needKey && !key)) {
    // No setup yet, or the decoder lost its place: ask for a fresh start (at most once a second).
    var now = performance.now();
    if (now - this.keyAsked > 1000) { this.keyAsked = now; this.sendJSON({ t: 'keyframe' }); }
    this.ack(seq);
    return;
  }
  this.needKey = false;
  this.decodeStart.set(seq, performance.now());
  try {
    dec.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: seq, data: new Uint8Array(buf, 12) }));
  } catch (e) { this.decodeStart.delete(seq); this.ack(seq); this.videoError(e); }
};

Player.prototype.videoFrame = function (frame) {
  var seq = frame.timestamp, t0 = this.decodeStart.get(seq), c = this.canvas;
  this.decodeStart.delete(seq);
  // Frames that came out late (two newer ones already waiting behind them) aren't drawn: the newest is what counts.
  if (!c || seq <= this.lastDrawn || (this.vdec && this.vdec.decodeQueueSize > 1)) {
    frame.close(); this.skipped++; this.ack(seq); return;
  }
  this.lastDrawn = seq;
  var w = frame.displayWidth, h = frame.displayHeight;
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; this.layout(); }
  this.g.imageSmoothingEnabled = false;
  this.g.drawImage(frame, 0, 0, w, h);
  frame.close();
  this.drawn++; this.drawnTotal++;
  if (t0) this.decodeMs = this.decodeMs * 0.9 + (performance.now() - t0) * 0.1;
  this.ack(seq);
};

// The browser took the decoder back (a page left in the background) or a frame didn't decode: a new decoder from the
// next keyframe. If that keeps failing, pictures instead.
Player.prototype.videoError = function (e) {
  var now = performance.now();
  this.closeDecoder();
  this.videoErrors = (this.videoErrors || []).filter(function (t) { return now - t < 10000; });
  this.videoErrors.push(now);
  if (this.videoErrors.length >= 3 || (e && e.name === 'NotSupportedError')) { this.videoFailed(); return; }
  this.keyAsked = now;
  this.sendJSON({ t: 'keyframe' });
};

Player.prototype.videoFailed = function () {
  this.closeDecoder();
  this.videoPath = 'image';
  this.caps = Promise.resolve(null);   // and a reconnect doesn't offer it again
  this.sendJSON({ t: 'video', use: 'image' });
};

Player.prototype.closeDecoder = function () {
  if (this.vdec) { try { if (this.vdec.state !== 'closed') this.vdec.close(); } catch (e) {} }
  if (this.mse) { this.mse.close(); this.mse = null; }
  this.vdec = null; this.needKey = true; this.decodeStart.clear();
};

Player.prototype.askKeyframe = function () {
  var now = performance.now();
  if (now - this.keyAsked > 1000) { this.keyAsked = now; this.sendJSON({ t: 'keyframe' }); }
};

// The connection indicator: good / OK / weak, from the Mac's adaptive quality (see StreamQuality).
Player.prototype.showLink = function (m) {
  var link = m.link || 'good', label = link === 'good' ? 'Good connection' : link === 'ok' ? 'OK connection' : 'Weak connection';
  [this.linkEl, this.menuLink].forEach(function (e) {
    if (!e) return;
    e.className = 'okp-link' + (link === 'good' ? '' : link === 'ok' ? ' okp-ok' : ' okp-weak');
    e.lastChild.textContent = label;
    e.setAttribute('aria-label', label);
    e.hidden = false;
  });
};

Player.prototype.takeOver = function () {
  this.takeover = true; this.state = 'connecting';
  this.showVeil({ title: 'Taking over…', spin: true });
  if (this.ws) { var old = this.ws; this.ws = null; try { old.close(); } catch (e) {} }
  this.connect(false);
};

Player.prototype.visibility = function () {
  if (document.hidden) this.releaseKeys();
  if (this.mode !== 'play') return;
  if (document.hidden) { this.sendJSON({ t: 'pause' }); }
  else if (!this.menuOpen && this.state === 'playing') {
    this.sendJSON({ t: 'resume' });
    if (this.sound) { this.sound.wake(); this.sound.clear(); }
    // The browser may have taken the decoder back while the page was hidden: start again from a keyframe.
    if (this.videoPath === 'h264' && !this.mse && (!this.vdec || this.vdec.state !== 'configured')) this.askKeyframe();
  }
};

// MARK: Controller mode

Player.prototype.controllerInfo = function (m) {
  var title = m.title;
  var changedSystem = m.system && (!this.info || this.info.system !== m.system);
  if (m.system) this.info = m;
  this.systemEl.textContent = systemBadge(m); this.systemEl.title = m.systemName || ''; this.systemEl.hidden = !m.systemName;
  this.ctlPlayer = m.player || this.ctlPlayer || 1;
  this.ctlTwo = !!m.twoPlayers;
  this.titleEl.textContent = title ? ('Player ' + this.ctlPlayer + ' · ' + title) : 'Controller · nothing playing on the Mac';
  var layout = m.layout || 'pad';
  if (title && (layout !== this.layoutKind || changedSystem)) this.buildControls(layout);
  if (!this.ctlHint) { this.ctlHint = el('div', 'okp-hint'); this.root.appendChild(this.ctlHint); }
  this.ctlHint.textContent = !title ? 'Start a game on the Mac, then use this as its controller.'
    : m.keyboardGame ? 'This game is played with the Mac’s keyboard and mouse; these buttons work only if it uses a joystick.'
    : 'Buttons here control the game the Mac is playing.';
  this.layout();
};

// MARK: Menus and messages

Player.prototype.showVeil = function (o) {
  this.hideVeil();
  var veil = this.veil = el('div', 'okp-veil' + (o.center === false ? '' : ' okp-center'));
  var sheet = el('div', 'okp-sheet');
  if (o.spin) sheet.appendChild(el('div', 'okp-spin'));
  if (o.title) sheet.appendChild(el('h2', null, o.title));
  if (o.text) sheet.appendChild(el('p', null, o.text));
  (o.items || []).forEach(function (n) { sheet.appendChild(n); });
  (o.actions || []).forEach(function (a) {
    var b = el('button', 'okp-act' + (a.main ? ' okp-main' : ''), a.label);
    b.addEventListener('click', a.fn);
    sheet.appendChild(b);
  });
  veil.appendChild(sheet);
  this.root.appendChild(veil);
};
Player.prototype.hideVeil = function () { if (this.veil) { this.veil.remove(); this.veil = null; } this.menuOpen = false; };

Player.prototype.openMenu = function () {
  var self = this;
  if (this.menuOpen) return;
  if (this.state !== 'playing') { if (this.state === 'connecting' || this.state === 'reconnecting') return; this.close(); return; }
  this.releaseKeys();
  this.soundMs = this.sound ? this.sound.ms : 0;
  this.statsEl = el('div', 'okp-stats', '');
  var actions;
  if (this.mode === 'controller') {
    actions = [];
    if (this.ctlTwo) actions.push({ label: this.ctlPlayer === 2 ? 'Be player 1 instead' : 'Be player 2 instead', fn: function () {
      self.sendJSON({ t: 'slot', player: self.ctlPlayer === 2 ? 1 : 2 }); self.closeMenu(); } });
    actions.push({ label: 'Stop being a controller', fn: function () { self.close(); } });
    actions.push({ label: 'Back', main: true, fn: function () { self.closeMenu(); } });
    this.showVeil({ title: 'Controller', items: [], actions: actions });
    this.menuOpen = true;
    return;
  }
  this.sendJSON({ t: 'pause' });
  var saves = this.info && this.info.saveStates;
  actions = [{ label: 'Resume', main: true, fn: function () { self.closeMenu(); } }];
  if (saves) {
    actions.push({ label: 'Save your place', fn: function () { self.sendJSON({ t: 'save' }); self.closeMenu(); } });
    actions.push({ label: 'Go back to saved place', fn: function () { self.sendJSON({ t: 'load' }); self.closeMenu(); } });
  }
  actions.push({ label: this.sound && this.sound.muted ? 'Sound: Off' : 'Sound: On', fn: function () {
    self.toggleSound(); this.textContent = self.sound.muted ? 'Sound: Off' : 'Sound: On'; } });
  actions.push({ label: 'Quit game', fn: function () { self.quit(); } });
  this.menuLink = el('div', 'okp-link');
  this.menuLink.appendChild(el('i')); this.menuLink.appendChild(el('span'));
  this.showVeil({ title: 'Paused', text: this.title || '', actions: actions, items: [] });
  this.veil.firstChild.appendChild(this.menuLink);
  var diagnostics = el('details', 'okp-diagnostics'); diagnostics.appendChild(el('summary', null, 'Connection details'));
  diagnostics.appendChild(this.statsEl); this.veil.firstChild.appendChild(diagnostics);
  if (this.server) this.showLink(this.server); else this.menuLink.hidden = true;
  this.menuOpen = true;
  this.updateStats();
};

Player.prototype.updateStats = function () {
  if (!this.statsEl) return;
  // Measured while playing: frames shown here and sent by the Mac each second, network round trip, and a frame's
  // round trip (Mac sends it, this device decodes and draws it, the Mac hears back).
  var s = this.server || {};
  var kind = s.video === 'h264' ? 'H.264' : s.video === 'jpeg' ? 'JPEG' : s.video === 'png' ? 'PNG' : '';
  var target = s.targetKbps ? ' (target ' + (s.targetKbps / 1000).toFixed(1) + ')' : s.jpegQuality ? ' (quality ' + Math.round(s.jpegQuality * 100) + ')' : '';
  this.statsEl.textContent = 'fps ' + Math.round(this.fps) + ' (Mac sent ' + Math.round(s.fps || 0) + ') · ping ' + Math.round(this.rtt) + ' ms' +
    '\nframe round trip ' + (s.frameRTT || 0).toFixed(1) + ' ms · encode ' + (s.encodeMs || 0).toFixed(1) + ' ms · decode ' +
    this.decodeMs.toFixed(1) + ' ms\n' + kind + ' ' + ((s.kbps || 0) / 1000).toFixed(1) + ' Mbit/s' + target +
    (s.scale && s.scale !== 1 ? ' · size ×' + s.scale : '') + (s.halfRate ? ' · half rate' : '') +
    ' · sound buffer ' + Math.round(this.soundMs || 0) + ' ms';
  this.statsEl.style.whiteSpace = 'pre-line';
};

Player.prototype.softMods = function () {
  var s = this.softModifiers || new Set(); return (s.has(304) ? 1 : 0) | (s.has(306) ? 2 : 0) | (s.has(308) ? 4 : 0);
};

Player.prototype.toggleSound = function () {
  if (!this.sound) return;
  this.sound.setMuted(!this.sound.muted); this.sendJSON({ t: 'mute', on: this.sound.muted });
  if (this.soundButton) {
    this.soundButton.textContent = this.sound.muted ? 'Unmute' : 'Mute';
    this.soundButton.setAttribute('aria-label', this.sound.muted ? 'Unmute sound' : 'Mute sound');
  }
};

Player.prototype.closeMenu = function () {
  this.hideVeil();
  if (this.mode === 'play' && this.state === 'playing') {
    this.sendJSON({ t: 'resume' });
    if (this.sound) { this.sound.wake(); this.sound.clear(); }
  }
};

Player.prototype.toast = function (text) {
  if (!text || !this.root) return;
  if (this.toastEl) this.toastEl.remove();
  var t = this.toastEl = el('div', 'okp-toast', text);
  this.root.appendChild(t);
  var self = this;
  clearTimeout(this.toastTimer);
  this.toastTimer = setTimeout(function () { t.style.opacity = '0'; setTimeout(function () { t.remove(); if (self.toastEl === t) self.toastEl = null; }, 300); }, text.length > 40 ? 3000 : 1800);
};

Player.prototype.fail = function (title, text) {
  var self = this;
  this.state = 'ended';
  this.showVeil({ title: title, text: text, actions: [{ label: 'Close', main: true, fn: function () { self.close(); } }] });
};

Player.prototype.quit = function () {
  var self = this;
  this.state = 'ended';
  this.sendJSON({ t: 'quit' });
  this.showVeil({ title: 'Saving…', spin: true });
  setTimeout(function () { self.close(); }, 400);
};

Player.prototype.close = function () {
  if (this.closing) return;
  this.closing = true;
  clearInterval(this.pinger); clearInterval(this.fpsTimer); clearTimeout(this.retryTimer); clearTimeout(this.toastTimer);
  cancelAnimationFrame(this.raf);
  if (this.ws) { try { this.releaseKeys(); this.ws.close(1000); } catch (e) {} this.ws = null; }
  this.listeners.forEach(function (l) { l[0].removeEventListener(l[1], l[2], l[3]); });
  this.listeners = [];
  if (this.sound) this.sound.close();
  this.closeDecoder();
  if (this.root) this.root.remove();
  this.root = null;
  document.documentElement.style.overflow = this.saved.overflow;
  document.documentElement.classList.remove('okp-open');
  if (current === this) current = null;
  if (typeof this.opts.onClose === 'function') { try { this.opts.onClose(); } catch (e) {} }
};

// MARK: H.264 through Media Source Extensions

// MP4 boxes for a one-track fragmented stream: an init segment from the avcC record, then one moof+mdat per frame.
function mp4u32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]; }
function mp4u16(n) { return [(n >>> 8) & 255, n & 255]; }
function mp4str(t) { var a = []; for (var i = 0; i < t.length; i++) a.push(t.charCodeAt(i)); return a; }
function mp4zero(n) { return new Array(n).fill(0); }
function mp4box(type) {
  var parts = Array.prototype.slice.call(arguments, 1), size = 8, i;
  for (i = 0; i < parts.length; i++) size += parts[i].length;
  var out = new Uint8Array(size), o = 8;
  out.set(mp4u32(size), 0); out.set(mp4str(type), 4);
  for (i = 0; i < parts.length; i++) { out.set(parts[i], o); o += parts[i].length; }
  return out;
}
var MP4_MATRIX = [].concat(mp4u32(0x10000), mp4zero(12), mp4u32(0x10000), mp4zero(12), mp4u32(0x40000000));
function mp4init(avcC, w, h) {
  var B = mp4box;
  var ftyp = B('ftyp', mp4str('isom'), mp4u32(0x200), mp4str('isomiso6avc1mp41'));
  var mvhd = B('mvhd', mp4zero(12), mp4u32(1000), mp4u32(0), mp4u32(0x10000), mp4u16(0x100), mp4zero(10), MP4_MATRIX, mp4zero(24), mp4u32(2));
  var tkhd = B('tkhd', mp4u32(3), mp4zero(8), mp4u32(1), mp4zero(4), mp4u32(0), mp4zero(8), mp4zero(8), MP4_MATRIX, mp4u32(w * 65536), mp4u32(h * 65536));
  var mdhd = B('mdhd', mp4zero(12), mp4u32(90000), mp4u32(0), mp4u16(0x55C4), mp4zero(2));
  var hdlr = B('hdlr', mp4zero(8), mp4str('vide'), mp4zero(12), mp4str('Video'), [0]);
  var avc1 = B('avc1', mp4zero(6), mp4u16(1), mp4zero(16), mp4u16(w), mp4u16(h), mp4u32(0x480000), mp4u32(0x480000), mp4zero(4),
               mp4u16(1), mp4zero(32), mp4u16(0x18), mp4u16(0xFFFF), B('avcC', avcC));
  var stbl = B('stbl', B('stsd', mp4zero(4), mp4u32(1), avc1), B('stts', mp4zero(8)), B('stsc', mp4zero(8)), B('stsz', mp4zero(12)), B('stco', mp4zero(8)));
  var minf = B('minf', B('vmhd', mp4u32(1), mp4zero(8)), B('dinf', B('dref', mp4zero(4), mp4u32(1), B('url ', mp4u32(1)))), stbl);
  var moov = B('moov', mvhd, B('trak', tkhd, B('mdia', mdhd, hdlr, minf)), B('mvex', B('trex', mp4zero(4), mp4u32(1), mp4u32(1), mp4zero(12))));
  var out = new Uint8Array(ftyp.length + moov.length);
  out.set(ftyp, 0); out.set(moov, ftyp.length);
  return out;
}
function mp4fragment(n, time, duration, key, data) {
  var B = mp4box;
  var trun = B('trun', mp4u32(0x000701), mp4u32(1), mp4u32(0), mp4u32(duration), mp4u32(data.length), mp4u32(key ? 0x02000000 : 0x01010000));
  var tfdt = B('tfdt', mp4u32(0x01000000), mp4u32(Math.floor(time / 4294967296)), mp4u32(time >>> 0));
  var moof = B('moof', B('mfhd', mp4zero(4), mp4u32(n)), B('traf', B('tfhd', mp4u32(0x020000), mp4u32(1)), tfdt, trun));
  moof.set(mp4u32(moof.length + 8), moof.length - trun.length + 16);   // trun's data offset: just past mdat's header
  var out = new Uint8Array(moof.length + 8 + data.length);
  out.set(moof, 0); out.set(mp4u32(8 + data.length), moof.length); out.set(mp4str('mdat'), moof.length + 4);
  out.set(data, moof.length + 8);
  return out;
}

// Where WebCodecs isn't offered, a <video> under the canvas plays the stream. Each frame is timed at the video's own
// playhead (plus a hair), so it's shown as soon as it's decoded rather than waiting its turn in a buffer, and lasts a
// second unless the next one replaces it, so a still screen (no frames sent) never runs the video dry. Frames are
// acknowledged as the video presents them.
function MSEVideo(player) {
  var self = this, MS = mediaSource();
  this.p = player; this.queue = []; this.sb = null; this.codec = null; this.n = 0; this.last = 0; this.pending = [];
  this.started = performance.now(); this.lastShown = 0;
  this.ms = new MS();
  var v = this.video = el('video', 'okp-video');
  v.muted = true; v.playsInline = true; v.autoplay = true; v.disableRemotePlayback = true;
  v.setAttribute('playsinline', ''); v.setAttribute('muted', '');
  this.url = URL.createObjectURL(this.ms);
  v.src = this.url;
  this.ms.addEventListener('sourceopen', function () { self.open(); });
  player.stage.insertBefore(v, player.canvas);
  player.canvas.classList.add('okp-clear');
  player.g.clearRect(0, 0, player.canvas.width, player.canvas.height);
  if (v.requestVideoFrameCallback) {
    var shown = function (now, meta) { if (self.video) { self.presented(meta.mediaTime); v.requestVideoFrameCallback(shown); } };
    v.requestVideoFrameCallback(shown);
  }
  this.place();
}
MSEVideo.prototype.place = function () {
  var c = this.p.canvas, v = this.video;
  v.style.left = c.offsetLeft + 'px'; v.style.top = c.offsetTop + 'px';
  v.style.width = c.style.width; v.style.height = c.style.height;
};
MSEVideo.prototype.open = function () {
  if (!this.codec || this.sb || this.ms.readyState !== 'open') return;
  var self = this;
  try {
    this.sb = this.ms.addSourceBuffer('video/mp4; codecs="' + this.codec + '"');
  } catch (e) { this.p.videoFailed(); return; }
  this.sb.addEventListener('updateend', function () {
    // Without frame callbacks (older browsers), a frame counts as shown once it's in the buffer.
    var done = self.appending; self.appending = null;
    if (done && done.seq != null && !self.video.requestVideoFrameCallback) self.shownUpTo(done.t);
    self.pump();
  });
  this.sb.addEventListener('error', function () { self.p.videoError({ name: 'MSE' }); });
  this.pump();
};
MSEVideo.prototype.configure = function (codec, avcC, w, h) {
  this.codec = codec;
  this.queue.push({ init: mp4init(avcC, w, h) });
  if (!this.sb) this.open(); else this.pump();
};
MSEVideo.prototype.frame = function (seq, key, data) {
  var v = this.video, now = Math.round(v.currentTime * 90000), wall = performance.now();
  // Frames keep coming but the video shows none (autoplay refused, Low Power Mode, a browser quirk): pictures instead.
  if (this.pending.length > 30 && wall - (this.lastShown || this.started) > 2500) { this.p.videoFailed(); return; }
  // A hair past the playhead (4 ms), never before the previous frame.
  var t = Math.max(this.last + 1, now + 360);
  this.last = t;
  this.pending.push([t, seq, wall]);
  if (this.pending.length > 600) this.pending.shift();
  this.queue.push({ seq: seq, data: mp4fragment(++this.n, t, 90000, key, data), t: t });
  this.pump();
};
MSEVideo.prototype.pump = function () {
  var sb = this.sb, v = this.video;
  if (!sb || sb.updating || !this.queue.length) return;
  // Behind (frames waiting to be appended): keep the newest init and the frames from the last keyframe on.
  var item = this.appending = this.queue.shift();
  try { sb.appendBuffer(item.init || item.data); } catch (e) { this.p.videoError({ name: 'MSE' }); return; }
  if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function () {}); }
  // Old frames go, so the buffer doesn't grow for the whole game (only ever behind the playhead).
  if (!item.init && v.currentTime > 30 && v.currentTime - (this.trimmed || 0) > 10 && !this.queue.length) {
    this.trimmed = v.currentTime - 5;
    var self = this;
    setTimeout(function () { if (self.sb && !self.sb.updating) { try { self.sb.remove(0, self.trimmed); } catch (e) {} } }, 0);
  }
};
// The video showed the frame timed at `mediaTime`: it and everything before it are acknowledged.
MSEVideo.prototype.presented = function (mediaTime) { this.shownUpTo(Math.round(mediaTime * 90000)); };
MSEVideo.prototype.shownUpTo = function (t) {
  var p = this.p, done = null;
  while (this.pending.length && this.pending[0][0] <= t + 45) done = this.pending.shift();
  if (!done) return;
  this.lastShown = performance.now();
  p.lastDrawn = done[1]; p.drawn++; p.drawnTotal++;
  // Arrival to shown, as this path's decode time.
  p.decodeMs = p.decodeMs * 0.9 + (performance.now() - done[2]) * 0.1;
  p.ack(done[1]);
};
MSEVideo.prototype.close = function () {
  try { if (this.video) { this.video.removeAttribute('src'); this.video.load(); this.video.remove(); } } catch (e) {}
  try { URL.revokeObjectURL(this.url); } catch (e) {}
  if (this.p.canvas) this.p.canvas.classList.remove('okp-clear');
  this.video = null; this.sb = null;
};

window.OKPlay = {
  // Opens the full-screen player for game `id` (from /api/games). Call it from a tap: browsers only start sound then.
  // options: {resume: true} picks up at the saved place; {mode: 'controller'} sends buttons to the game on the Mac's
  // own screen instead; {title} shows while connecting; {onClose} is called when the player closes; {video: 'image'}
  // never offers H.264 (PNG/JPEG pictures only); {video: 'webcodecs'} offers it only through WebCodecs, not a <video>.
  open: function (id, options) {
    if (current) current.close();
    current = new Player(id, options || {});
    return current;
  },
  close: function () { if (current) current.close(); },
  // The open player (state, fps, rtt and so on), for pages that want to show more; null when closed.
  get player() { return current; },
  get isOpen() { return !!current; }
};
})();
"""#

    // MARK: /play-test

    private static let test = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Play test · Offline Kit</title>
<style>
body{margin:0;background:#111413;color:#eef2ef;font:16px/1.45 -apple-system,system-ui,sans-serif;padding:max(16px,env(safe-area-inset-top)) 16px 40px;touch-action:manipulation}
h1{font-size:22px;margin:0 0 4px}
p{color:#9aa6a0;margin:0 0 16px}
ul{list-style:none;margin:0;padding:0;display:grid;gap:10px}
li{background:#1b1f1d;border-radius:14px;padding:12px;display:flex;flex-wrap:wrap;gap:12px;align-items:center}
img,.art{width:64px;height:58px;border-radius:8px;object-fit:cover;background:#2a302d;flex:none;image-rendering:pixelated}
.t{flex:1;min-width:0}
.t b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.t small{color:#9aa6a0}
button{font:inherit;font-weight:600;border:0;border-radius:10px;padding:9px 12px;background:#2E7F60;color:#fff;margin-left:4px}
button.alt{background:#2a302d}
.row{display:flex;flex-wrap:wrap;justify-content:flex-end;gap:6px;flex-basis:100%}
</style>
</head>
<body>
<h1>Play test</h1>
<p>Games on the Mac, for trying the game player without the main page.</p>
<ul id="list"></ul>
<script src="/assets/play.js"></script>
<script>
(function () {
  var list = document.getElementById('list');
  // ?video=image tries the PNG/JPEG pictures even where H.264 would work.
  var video = new URLSearchParams(location.search).get('video') || undefined;
  function add(tag, parent, text, cls) { var e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; parent.appendChild(e); return e; }
  fetch('/api/games', { credentials: 'same-origin' }).then(function (r) {
    if (r.status === 401) { location.href = '/'; return null; }
    return r.json();
  }).then(function (data) {
    if (!data) return;
    if (!data.games.length) { add('li', list, 'No games on the Mac yet.'); return; }
    data.games.forEach(function (g) {
      var li = add('li', list);
      if (g.art) { var img = add('img', li); img.src = g.art; img.alt = ''; } else add('div', li, null, 'art');
      var t = add('div', li, null, 't');
      add('b', t, g.title);
      add('small', t, g.systemName + (g.lastPlayed ? ' · played ' + new Date(g.lastPlayed * 1000).toLocaleDateString() : ''));
      var row = add('div', li, null, 'row');
      var play = add('button', row, g.canResume ? 'Continue' : 'Play');
      play.onclick = function () { OKPlay.open(g.id, { resume: g.canResume, title: g.title, video: video }); };
      if (g.canResume) { var fresh = add('button', row, 'From start', 'alt'); fresh.onclick = function () { OKPlay.open(g.id, { title: g.title, video: video }); }; }
      var ctl = add('button', row, 'Controller', 'alt');
      ctl.onclick = function () { OKPlay.open(g.id, { mode: 'controller', title: g.title }); };
    });
  });
})();
</script>
</body>
</html>
"""#
}

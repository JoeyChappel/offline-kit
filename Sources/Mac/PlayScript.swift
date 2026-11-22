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
'html.okp-open body>:not(.okplay-root){content-visibility:hidden}' +
'.okplay-root{position:fixed;inset:0;z-index:2147483000;background:#0b0d0c;color:#f2f5f3;font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,system-ui,sans-serif;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;touch-action:none;overflow:hidden;display:flex;flex-direction:column;padding:env(safe-area-inset-top,0) env(safe-area-inset-right,0) env(safe-area-inset-bottom,0) env(safe-area-inset-left,0);-webkit-tap-highlight-color:transparent}',
'.okplay-root *{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}',
'.okplay-root button{font:inherit;color:inherit;border:0;background:none;cursor:pointer;touch-action:none}',
'.okplay-root .okp-top{flex:none;display:flex;align-items:center;gap:10px;padding:8px 12px;min-height:44px}',
'.okplay-root .okp-title{flex:1;min-width:0;font-weight:600;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;opacity:.85}',
'.okplay-root .okp-icon{width:40px;height:40px;border-radius:12px;background:rgba(255,255,255,.1);display:grid;place-items:center;font-size:18px;font-weight:700;flex:none}',
'.okplay-root .okp-stage{flex:none;display:flex;align-items:center;justify-content:center;position:relative;min-height:0}',
'.okplay-root canvas.okp-screen{display:block;background:#000;image-rendering:pixelated;image-rendering:crisp-edges;touch-action:none}',
'.okplay-root .okp-pad{flex:1;position:relative;min-height:0}',
'.okplay-root .okp-dpad{position:absolute;width:156px;height:156px}',
'.okplay-root .okp-dpad i{position:absolute;background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.18)}',
'.okplay-root .okp-dpad i.okp-h{left:0;right:0;top:52px;height:52px;border-radius:12px}',
'.okplay-root .okp-dpad i.okp-v{top:0;bottom:0;left:52px;width:52px;border-radius:12px}',
'.okplay-root .okp-dpad b{position:absolute;width:52px;height:52px;border-radius:12px}',
'.okplay-root .okp-dpad b.okp-on{background:rgba(255,255,255,.32)}',
'.okplay-root .okp-btn{position:absolute;border-radius:50%;width:66px;height:66px;background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.2);display:grid;place-items:center;font-weight:700;font-size:20px}',
'.okplay-root .okp-btn.okp-a{background:rgba(214,72,72,.55)}',
'.okplay-root .okp-btn.okp-b{background:rgba(214,170,60,.5)}',
'.okplay-root .okp-pill{position:absolute;height:30px;min-width:72px;padding:0 12px;border-radius:15px;background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.18);display:grid;place-items:center;font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase}',
'.okplay-root .okp-on{background:rgba(255,255,255,.4)!important}',
'.okplay-root .okp-keys{flex:none;display:flex;flex-wrap:wrap;gap:8px;justify-content:center;padding:10px 12px 14px}',
'.okplay-root .okp-key{height:44px;min-width:56px;padding:0 14px;border-radius:12px;background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.18);font-weight:600;font-size:14px}',
'.okplay-root .okp-hint{flex:none;text-align:center;font-size:13px;opacity:.6;padding:4px 16px}',
'.okplay-root input.okp-type{position:absolute;left:0;bottom:0;width:1px;height:1px;opacity:0;border:0;font-size:16px}',
'.okplay-root .okp-veil{position:absolute;inset:0;background:rgba(0,0,0,.62);display:flex;align-items:flex-end;justify-content:center;z-index:5;padding:16px;padding-bottom:max(16px,env(safe-area-inset-bottom,0))}',
'.okplay-root .okp-veil.okp-center{align-items:center}',
'.okplay-root .okp-sheet{width:100%;max-width:420px;background:#1c201e;border-radius:20px;padding:18px;display:flex;flex-direction:column;gap:10px;box-shadow:0 10px 40px rgba(0,0,0,.5);max-height:100%;overflow:auto;touch-action:pan-y}',
'.okplay-root .okp-sheet h2{font-size:19px;font-weight:700;line-height:1.25}',
'.okplay-root .okp-sheet p{opacity:.75;font-size:15px}',
'.okplay-root .okp-row{display:flex;gap:10px}',
'.okplay-root .okp-act{flex:1;min-height:48px;border-radius:14px;background:rgba(255,255,255,.1);font-weight:600;font-size:16px;padding:0 14px}',
'.okplay-root .okp-act.okp-main{background:#2E7F60;color:#fff}',
'.okplay-root .okp-stats{font:12px/1.5 ui-monospace,Menlo,monospace;opacity:.55;text-align:center}',
'.okplay-root .okp-toast{position:absolute;left:50%;top:calc(56px + env(safe-area-inset-top,0));transform:translateX(-50%);background:rgba(28,32,30,.92);padding:8px 16px;border-radius:18px;font-weight:600;font-size:14px;z-index:4;pointer-events:none;max-width:90%;text-align:center;transition:opacity .25s}',
'.okplay-root .okp-spin{width:34px;height:34px;border-radius:50%;border:3px solid rgba(255,255,255,.2);border-top-color:#fff;animation:okp-spin 0.9s linear infinite;margin:6px auto}',
'@keyframes okp-spin{to{transform:rotate(360deg)}}',
// Landscape: the picture fills the screen and the controls float over its sides.
'.okplay-root.okp-land .okp-top{position:absolute;top:env(safe-area-inset-top,0);left:env(safe-area-inset-left,0);z-index:3;padding:8px}',
'.okplay-root.okp-land .okp-title{display:none}',
'.okplay-root.okp-land .okp-stage{position:absolute;inset:0}',
'.okplay-root.okp-land .okp-pad{position:absolute;inset:0;z-index:2}',
'.okplay-root.okp-land .okp-dpad i,.okplay-root.okp-land .okp-btn,.okplay-root.okp-land .okp-pill{opacity:.55}',
'.okplay-root.okp-land .okp-keys{position:absolute;left:0;right:0;bottom:0;z-index:3;padding-bottom:max(10px,env(safe-area-inset-bottom,0))}',
'.okplay-root.okp-land .okp-key{opacity:.7}',
'.okplay-root.okp-land .okp-hint{display:none}',
'.okplay-root.okp-ctl .okp-pad{flex:1}'
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
  var menu = el('button', 'okp-icon', 'II');
  menu.setAttribute('aria-label', 'Menu');
  var self = this;
  menu.addEventListener('click', function () { self.openMenu(); });
  this.titleEl = el('div', 'okp-title', this.title || (this.mode === 'controller' ? 'Controller' : 'Starting…'));
  top.appendChild(menu); top.appendChild(this.titleEl);
  root.appendChild(top);
  if (this.mode === 'play') {
    this.stage = el('div', 'okp-stage');
    this.canvas = el('canvas', 'okp-screen');
    this.canvas.width = 256; this.canvas.height = 240;
    this.g = this.canvas.getContext('2d');
    this.stage.appendChild(this.canvas);
    root.appendChild(this.stage);
  }
  this.pad = el('div', 'okp-pad');
  root.appendChild(this.pad);
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
  this.on(window, 'blur', function () { self.releaseKeys(); });
  this.on(root, 'contextmenu', function (e) { e.preventDefault(); });
  this.on(root, 'touchmove', function (e) { if (!e.target.closest || !e.target.closest('.okp-sheet')) e.preventDefault(); }, { passive: false });
  this.on(root, 'pointerdown', function () { if (self.sound) self.sound.wake(); });
  this.buildControls('pad');
  this.showVeil({ title: this.mode === 'controller' ? 'Connecting…' : 'Starting ' + (this.title || 'the game') + '…', spin: true,
                  actions: [{ label: 'Cancel', fn: function () { self.close(); } }] });
  this.raf = requestAnimationFrame(function loop() { self.tick(); self.raf = requestAnimationFrame(loop); });
  this.fpsTimer = setInterval(function () { self.countFrames(); }, 1000);
  this.layout();
};

Player.prototype.buildControls = function (layout) {
  var self = this, pad = this.pad;
  this.layoutKind = layout;
  while (pad.firstChild) pad.removeChild(pad.firstChild);
  if (this.keysBar) { this.keysBar.remove(); this.keysBar = null; }
  if (this.hint) { this.hint.remove(); this.hint = null; }
  this.zones = [];
  if (layout === 'pointer') {
    // DOS and ScummVM: the picture is the mouse; a row of keys (and the phone's keyboard) below.
    var bar = this.keysBar = el('div', 'okp-keys');
    var keyBtn = function (label, code, ch) {
      var b = el('button', 'okp-key', label);
      b.addEventListener('pointerdown', function (e) { e.preventDefault(); self.sendKey(code, true, ch, 0); b.classList.add('okp-on'); });
      var up = function () { if (b.classList.contains('okp-on')) { b.classList.remove('okp-on'); self.sendKey(code, false, 0, 0); } };
      b.addEventListener('pointerup', up); b.addEventListener('pointercancel', up); b.addEventListener('pointerleave', up);
      bar.appendChild(b);
    };
    var kb = el('button', 'okp-key', 'Keyboard');
    this.typer = el('input', 'okp-type');
    this.typer.setAttribute('autocapitalize', 'off'); this.typer.setAttribute('autocomplete', 'off');
    this.typer.setAttribute('autocorrect', 'off'); this.typer.setAttribute('spellcheck', 'false');
    this.typer.addEventListener('input', function () { self.typed(); });
    kb.addEventListener('click', function () { self.typer.focus(); });
    bar.appendChild(kb);
    keyBtn('Esc', 27, 27); keyBtn('Enter', 13, 13); keyBtn('Space', 32, 32);
    keyBtn('←', 276, 0); keyBtn('↑', 273, 0); keyBtn('↓', 274, 0); keyBtn('→', 275, 0);
    var rc = el('button', 'okp-key', 'Right-click');
    rc.addEventListener('click', function () { self.rightClick = !self.rightClick; rc.classList.toggle('okp-on', self.rightClick); });
    this.rcButton = rc;
    bar.appendChild(rc);
    this.root.appendChild(bar);
    this.root.appendChild(this.typer);
    this.hint = el('div', 'okp-hint', this.pointerMode === 'relative'
      ? 'Drag on the picture to move the mouse. Tap to click; tap with two fingers to right-click.'
      : 'Tap the picture to click there. Turn on Right-click for the next tap.');
    this.root.insertBefore(this.hint, bar);
    this.pad.style.display = 'none';
    this.bindCanvasPointer();
    return;
  }
  this.pad.style.display = '';
  var dpad = el('div', 'okp-dpad');
  dpad.appendChild(el('i', 'okp-h')); dpad.appendChild(el('i', 'okp-v'));
  var arrows = {};
  [[B.UP, 52, 0], [B.DOWN, 52, 104], [B.LEFT, 0, 52], [B.RIGHT, 104, 52]].forEach(function (a) {
    var b = el('b'); b.style.left = a[1] + 'px'; b.style.top = a[2] + 'px'; dpad.appendChild(b); arrows[a[0]] = b;
  });
  pad.appendChild(dpad);
  this.zones.push({ kind: 'dpad', el: dpad, parts: arrows });
  var face = function (label, button, cls) {
    var b = el('div', 'okp-btn ' + cls, label); pad.appendChild(b);
    self.zones.push({ kind: 'btn', el: b, button: button });
    return b;
  };
  this.btnA = face('A', B.A, 'okp-a');
  this.btnB = face('B', B.B, 'okp-b');
  var pill = function (label, button) {
    var b = el('div', 'okp-pill', label); pad.appendChild(b);
    self.zones.push({ kind: 'btn', el: b, button: button, pill: true });
    return b;
  };
  this.btnSelect = pill('Select', B.SELECT);
  this.btnStart = pill('Start', B.START);
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
  var W = root.clientWidth, H = root.clientHeight;
  var land = W > H * 1.1;
  root.classList.toggle('okp-land', land);
  var keysH = this.keysBar ? this.keysBar.offsetHeight : 0;
  var hintH = this.hint && !land ? this.hint.offsetHeight : 0;
  var topH = land ? 0 : 52;
  if (this.canvas) {
    var aspect = (this.info && this.info.aspect) || (this.canvas.width / this.canvas.height);
    // Landscape with a pad: leave the sides for the thumbs, unless that would shrink the picture too much.
    var availW = land && this.layoutKind !== 'pointer' ? Math.max(W * 0.5, W - 2 * 196) : W - 8, availH;
    if (land) availH = H - (this.layoutKind === 'pointer' ? keysH : 0);
    else if (this.layoutKind === 'pointer') availH = H - topH - keysH - hintH - 8;
    else availH = Math.min(H * 0.52, H - topH - 250);
    availH = Math.max(80, availH);
    var h = Math.min(availH, availW / aspect);
    // Whole-number scaling keeps every game pixel the same size, when that costs little of the space.
    var dpr = window.devicePixelRatio || 1, fh = this.canvas.height;
    var k = Math.floor(h * dpr / fh);
    if (k >= 1 && (k * fh / dpr) >= h * 0.86) h = k * fh / dpr;
    var w = h * aspect;
    this.canvas.style.width = Math.round(w) + 'px';
    this.canvas.style.height = Math.round(h) + 'px';
    this.stage.style.height = land ? '' : Math.round(h + 8) + 'px';
  }
  if (this.layoutKind === 'pointer' || !this.zones.length) return;
  // Pad positions: relative to the pad area (below the picture in portrait, the whole screen in landscape).
  var pw = this.pad.clientWidth, ph = this.pad.clientHeight;
  var place = function (e, x, y) { e.style.left = Math.round(x) + 'px'; e.style.top = Math.round(y) + 'px'; };
  var dpad = this.zones[0].el;
  var cy = land ? ph * 0.58 : Math.max(90, ph * 0.46);
  var side = land ? Math.max(24, pw * 0.04) : 20;
  place(dpad, side, cy - 78);
  place(this.btnA, pw - side - 66, cy - 66);
  place(this.btnB, pw - side - 66 - 78, cy - 10);
  if (land) {
    // Under the d-pad and the face buttons, clear of the picture.
    place(this.btnSelect, side + 4, Math.min(ph - 42, cy + 92));
    place(this.btnStart, pw - side - 76, Math.min(ph - 42, cy + 92));
  } else {
    var pillY = Math.min(ph - 44, cy + 104);
    place(this.btnSelect, pw / 2 - 84, pillY);
    place(this.btnStart, pw / 2 + 12, pillY);
  }
  if (this.btnL) {
    var shoulderY = land ? Math.max(56, cy - 150) : Math.max(4, cy - 128);
    place(this.btnL, side, shoulderY); place(this.btnR, pw - side - 72, shoulderY);
  }
  for (var i = 0; i < this.zones.length; i++) this.zones[i].rect = this.zones[i].el.getBoundingClientRect();
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
  this.sources.key = new Set(); this.sources.touch = new Set(); this.pointers.clear();
  this.sync();
  this.sendBytes([6]);
};

// MARK: Pointer (DOS and ScummVM)

Player.prototype.bindCanvasPointer = function () {
  if (this.canvasBound) return;
  this.canvasBound = true;
  var self = this, c = this.canvas, touches = new Map(), maxTouches = 0, start = 0, moved = 0, last = null, mouseDown = 0;
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
      else if (self.rightClick && e.type !== 'pointercancel') { click(1); self.rightClick = false; if (self.rcButton) self.rcButton.classList.remove('okp-on'); }
    } else if (quick && e.type !== 'pointercancel') {
      var right = maxTouches >= 2 || self.rightClick;
      click(right ? 1 : 0);
      if (self.rightClick) { self.rightClick = false; if (self.rcButton) self.rcButton.classList.remove('okp-on'); }
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
    if (shift) this.sendKey(304, true, 0, 1);
    this.sendKey(code, true, ch.codePointAt(0), shift ? 1 : 0);
    this.sendKey(code, false, 0, shift ? 1 : 0);
    if (shift) this.sendKey(304, false, 0, 0);
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
    this.sendKey(code, down, down ? charFor(e.key) : 0, mods(e));
    return;
  }
  if (down && e.code === 'Escape' && this.mode === 'play') { e.preventDefault(); this.openMenu(); return; }
  var button = PAD_KEYS[e.code];
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
  if (!navigator.getGamepads || this.menuOpen) return;
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
    var hello = { t: 'hello', mode: self.mode, id: self.id, resume: !!self.opts.resume || retry, takeover: !!self.takeover, device: deviceName() };
    self.takeover = false;
    ws.send(JSON.stringify(hello));
    clearInterval(self.pinger);
    self.pinger = setInterval(function () { self.sendJSON({ t: 'ping', ts: performance.now() }); }, 2000);
    self.sendJSON({ t: 'ping', ts: performance.now() });
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
    this.pointerMode = m.pointer;
    var layout = m.layout || 'pad';
    if (layout !== this.layoutKind) this.buildControls(layout);
    if (this.sound) { this.sound.start(m.sampleRate); this.sound.clear(); }
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
    if (!this.menuOpen) this.server = m;   // while paused nothing is sent; keep the numbers from playing
    break;
  case 'nogame':
    this.controllerInfo({ title: null });
    break;
  }
};

Player.prototype.binary = function (buf) {
  var v = new DataView(buf), type = v.getUint8(0), self = this;
  if (type === 2) { if (this.sound && !this.menuOpen) this.sound.push(buf.slice(1)); return; }
  if (type !== 1 && type !== 3) return;
  var seq = v.getUint32(1, true), encode = v.getUint16(5, true) / 10, w = v.getUint16(7, true), h = v.getUint16(9, true);
  this.seen = seq; this.encodeMs = encode;
  var blob = new Blob([new Uint8Array(buf, 11)], { type: type === 1 ? 'image/jpeg' : 'image/png' });
  var t0 = performance.now();
  var done = function () { self.sendBytes([7, seq & 255, (seq >> 8) & 255, (seq >> 16) & 255, (seq >>> 24) & 255]); };
  createImageBitmap(blob).then(function (bmp) {
    if (seq > self.lastDrawn && self.canvas) {
      self.lastDrawn = seq;
      if (self.canvas.width !== w || self.canvas.height !== h) {
        self.canvas.width = w; self.canvas.height = h; self.layout();
      }
      self.g.imageSmoothingEnabled = false;
      self.g.drawImage(bmp, 0, 0);
      self.drawn++;
      self.decodeMs = self.decodeMs * 0.9 + (performance.now() - t0) * 0.1;
    }
    if (bmp.close) bmp.close();
    done();
  }, done);
};

Player.prototype.takeOver = function () {
  this.takeover = true; this.state = 'connecting';
  this.showVeil({ title: 'Taking over…', spin: true });
  if (this.ws) { var old = this.ws; this.ws = null; try { old.close(); } catch (e) {} }
  this.connect(false);
};

Player.prototype.visibility = function () {
  if (this.mode !== 'play') return;
  if (document.hidden) { this.releaseKeys(); this.sendJSON({ t: 'pause' }); }
  else if (!this.menuOpen && this.state === 'playing') { this.sendJSON({ t: 'resume' }); if (this.sound) { this.sound.wake(); this.sound.clear(); } }
};

// MARK: Controller mode

Player.prototype.controllerInfo = function (m) {
  var title = m.title;
  this.ctlPlayer = m.player || this.ctlPlayer || 1;
  this.ctlTwo = !!m.twoPlayers;
  this.titleEl.textContent = title ? ('Player ' + this.ctlPlayer + ' · ' + title) : 'Controller · nothing playing on the Mac';
  var layout = m.layout || 'pad';
  if (title && layout !== this.layoutKind) this.buildControls(layout);
  if (!this.ctlHint) { this.ctlHint = el('div', 'okp-hint'); this.root.appendChild(this.ctlHint); }
  this.ctlHint.textContent = !title ? 'Start a game on the Mac, then use this as its controller.'
    : m.keyboardGame ? 'This game is played with the Mac’s keyboard and mouse; these buttons work only if it uses a joystick.'
    : 'Buttons here control the game the Mac is playing.';
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
    self.sound.setMuted(!self.sound.muted); self.sendJSON({ t: 'mute', on: self.sound.muted });
    this.textContent = self.sound.muted ? 'Sound: Off' : 'Sound: On'; } });
  actions.push({ label: 'Quit game', fn: function () { self.quit(); } });
  this.showVeil({ title: 'Paused', text: this.title || '', actions: actions, items: [] });
  this.veil.firstChild.appendChild(this.statsEl);
  this.menuOpen = true;
  this.updateStats();
};

Player.prototype.updateStats = function () {
  if (!this.statsEl) return;
  // Measured while playing: frames shown here and sent by the Mac each second, network round trip, and a frame's
  // round trip (Mac sends it, this device decodes and draws it, the Mac hears back).
  var s = this.server || {};
  this.statsEl.textContent = 'fps ' + Math.round(this.fps) + ' (Mac sent ' + Math.round(s.fps || 0) + ') · ping ' + Math.round(this.rtt) + ' ms' +
    '\nframe round trip ' + (s.frameRTT || 0).toFixed(1) + ' ms · encode ' + (s.encodeMs || 0).toFixed(1) + ' ms · decode ' +
    this.decodeMs.toFixed(1) + ' ms\nsound buffer ' + Math.round(this.soundMs || 0) + ' ms · ' + Math.round(s.kbps || 0) + ' kbit/s';
  this.statsEl.style.whiteSpace = 'pre-line';
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
  if (this.root) this.root.remove();
  this.root = null;
  document.documentElement.style.overflow = this.saved.overflow;
  document.documentElement.classList.remove('okp-open');
  if (current === this) current = null;
  if (typeof this.opts.onClose === 'function') { try { this.opts.onClose(); } catch (e) {} }
};

window.OKPlay = {
  // Opens the full-screen player for game `id` (from /api/games). Call it from a tap: browsers only start sound then.
  // options: {resume: true} picks up at the saved place; {mode: 'controller'} sends buttons to the game on the Mac's
  // own screen instead; {title} shows while connecting; {onClose} is called when the player closes.
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
body{margin:0;background:#111413;color:#eef2ef;font:16px/1.45 -apple-system,system-ui,sans-serif;padding:max(16px,env(safe-area-inset-top)) 16px 40px}
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
      play.onclick = function () { OKPlay.open(g.id, { resume: g.canResume, title: g.title }); };
      if (g.canResume) { var fresh = add('button', row, 'From start', 'alt'); fresh.onclick = function () { OKPlay.open(g.id, { title: g.title }); }; }
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
